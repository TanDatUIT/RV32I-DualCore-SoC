#!/usr/bin/env python3
"""
uart_flasher.py - Host PC Tool nap Firmware qua UART cho Secure Bootloader RV32I
Giao thuc khop 100% firmware/bootloader/bootloader.s + soc_crc32 (IEEE 802.3):
  1. Host gui 0x7F (Sync) -> Bootloader xoa HW CRC32, tra 'y' (0x79)
  2. Host gui N (1 byte, 1..255 so word 32-bit)
  3. Moi word gui 4 byte little-endian -> Bootloader nap I-SRAM & CRC32 -> tra ACK (0x06)
  4. Host gui 4 byte CRC32 IEEE 802.3 (little-endian)
  5. Bootloader so sanh voi CRC32.RESULT:
       - Sai -> tra NAK (0x15) va cho nap lai
       - Dung -> tra EOT (0x04), bat BOOT_LOCK=1 va nhay toi 0x0000_0200
"""

import argparse
import sys
import zlib


def load_hex_words(hex_path):
    words = []
    with open(hex_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and not line.startswith("//"):
                words.append(int(line, 16))
    return words


def words_to_bytes(words):
    byte_stream = bytearray()
    for w in words:
        byte_stream.append(w & 0xFF)
        byte_stream.append((w >> 8) & 0xFF)
        byte_stream.append((w >> 16) & 0xFF)
        byte_stream.append((w >> 24) & 0xFF)
    return bytes(byte_stream)


def run_dry(hex_file, words, payload, crc_val, corrupt_crc):
    print("==============================================================")
    print("  RISC-V SoC Secure UART Bootloader Flasher (Dry-Run Mode)    ")
    print("==============================================================")
    print(f"[*] Firmware file : {hex_file}")
    print(f"[*] Total words   : {len(words)} (32-bit words)")
    print(f"[*] Total payload : {len(payload)} bytes")
    print(f"[*] CRC-32 (IEEE) : 0x{crc_val:08x}" + (" [CORRUPTED]" if corrupt_crc else ""))
    print(f"[*] Target addr   : 0x0000_0200")
    print("--------------------------------------------------------------")
    print("[1] Handshake     : TX 0x7F (Sync) -> expect RX 0x79 ('y')")
    print(f"[2] Header        : TX N = {len(words)} words (0x{len(words):02x})")
    print("[3] Streaming     : TX 4B/word (LE) -> expect RX 0x06 (ACK)")
    for i, w in enumerate(words):
        b = payload[i * 4 : i * 4 + 4]
        print(
            f"    Word [{i:02d}]: 0x{w:08x} -> "
            f"[{b[0]:02x} {b[1]:02x} {b[2]:02x} {b[3]:02x}] -> ACK (0x06)"
        )
    cb = crc_val.to_bytes(4, "little")
    print(f"[4] CRC-32 Footer : TX [{cb[0]:02x} {cb[1]:02x} {cb[2]:02x} {cb[3]:02x}]")
    if corrupt_crc:
        print("[5] Security Resp : expect RX 0x15 (NAK - Reject & stay in Bootloader)")
    else:
        print("[5] Security Resp : expect RX 0x04 (EOT - Engage BOOT_LOCK=1 & jump 0x0000_0200)")
    print("==============================================================")


def run_serial(port, baud, words, payload, crc_val):
    try:
        import serial  # type: ignore
    except ImportError:
        print("[!] PySerial chua duoc cai (pip install pyserial). Dung dry-run bo --port.", file=sys.stderr)
        sys.exit(2)

    with serial.Serial(port, baudrate=baud, timeout=2.0) as ser:
        ser.reset_input_buffer()
        ser.write(b"\x7f")
        sync = ser.read(1)
        if sync != b"\x79":
            raise RuntimeError(f"Handshake failed: expected 0x79, got {sync!r}")
        print("[+] Bootloader ready ('y')")

        ser.write(bytes([len(words)]))
        for i in range(len(words)):
            ser.write(payload[i * 4 : i * 4 + 4])
            ack = ser.read(1)
            if ack != b"\x06":
                raise RuntimeError(f"Word {i} ACK failed: expected 0x06, got {ack!r}")

        ser.write(crc_val.to_bytes(4, "little"))
        status = ser.read(1)
        if status == b"\x04":
            print("[+] EOT (0x04) received! CRC verified, BOOT_LOCK engaged, app booted.")
        elif status == b"\x15":
            raise RuntimeError("NAK (0x15) received! Bootloader rejected CRC32 mismatch.")
        else:
            raise RuntimeError(f"Unexpected status byte after CRC32: {status!r}")


def main():
    parser = argparse.ArgumentParser(
        description="Flasher UART kem xac thuc CRC-32 cho RV32I SoC Bootloader"
    )
    parser.add_argument("hex_file", help="Duong dan file .hex")
    parser.add_argument("--port", default=None, help="Cong UART (bo trong de chay dry-run)")
    parser.add_argument("--baud", type=int, default=115200, help="Baudrate (mac dinh 115200)")
    parser.add_argument(
        "--corrupt-crc",
        action="store_true",
        help="Co tinh lam sai 1 bit CRC32 de kiem tra phan hoi NAK (0x15)",
    )
    args = parser.parse_args()

    words = load_hex_words(args.hex_file)
    if not words or len(words) > 255:
        print(f"[!] So luong word phai trong khoang 1..255 (hien co {len(words)})", file=sys.stderr)
        sys.exit(1)

    payload = words_to_bytes(words)
    crc_val = zlib.crc32(payload) & 0xFFFFFFFF
    if args.corrupt_crc:
        crc_val ^= 0x00000001

    if args.port:
        run_serial(args.port, args.baud, words, payload, crc_val)
    else:
        run_dry(args.hex_file, words, payload, crc_val, args.corrupt_crc)


if __name__ == "__main__":
    main()
