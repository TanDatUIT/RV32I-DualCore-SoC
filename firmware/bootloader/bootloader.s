# =============================================================================
# RISC-V RV32I Secure In-Field UART Bootloader (voi HW CRC32 + Boot Write-Lock)
# Dia chi goc: 0x0000_0000 (nam trong Boot Region 0x0000_0000..0x0000_01FF)
# Vung ung dung dich: 0x0000_0200
# Ngoai vi su dung:
#   * UART    : 0x2000_0100
#   * HW CRC32: 0x2000_0300 (CTRL=+0x00, DATA_WORD=+0x08, RESULT=+0x0C)
#   * SysCtrl : 0x2000_0500 (BOOT_LOCK=+0x00)
# Giao thuc:
#   1. Host gui 0x7F -> Bootloader tra 'y' (0x79) va reset CRC32
#   2. Host gui 1 byte N (so word 32-bit)
#   3. Host gui N x 4 bytes (little-endian) -> ghi 0x0000_0200 + nap CRC32 -> ACK 0x06
#   4. Host gui 4 bytes expected_crc (little-endian)
#   5. Neu expected_crc == HW CRC32.RESULT:
#        - Gui EOT (0x04), bat BOOT_LOCK = 1, nhay toi 0x0000_0200
#      Neu sai:
#        - Gui NAK (0x15) va quay lai cho Sync 0x7F (TU CHOI BOOT!)
# =============================================================================

.globl _start
_start:
    lui   a0, 0x20000
    addi  a0, a0, 0x100        # a0 = UART Base (0x2000_0100)
    lui   s2, 0x20000
    addi  s2, s2, 0x300        # s2 = CRC32 Base (0x2000_0300)
    lui   s3, 0x20000
    addi  s3, s3, 0x500        # s3 = SysCtrl Base (0x2000_0500)

    # Bat UART Controller (CTRL = 1)
    addi  t0, zero, 1
    sw    t0, 12(a0)

wait_sync:
    lui   t2, 0x00001          # t2 = 4096 vong cho Sync byte
poll_trigger:
    lw    t1, 8(a0)
    andi  t1, t1, 2            # rx_valid
    bne   t1, zero, check_sync
    addi  t2, t2, -1
    bne   t2, zero, poll_trigger

    # Timeout -> khoa Boot region roi nhay toi App san co tai 0x0000_0200
    addi  t0, zero, 1
    sw    t0, 0(s3)            # BOOT_LOCK = 1
    lui   a1, 0x00000
    addi  a1, a1, 0x200
    jalr  zero, a1, 0

check_sync:
    lw    t3, 4(a0)            # UART_RXDATA
    andi  t3, t3, 0xFF
    addi  t0, zero, 0x7F
    bne   t3, t0, poll_trigger

    # Reset HW CRC32 (CTRL = 1)
    addi  t0, zero, 1
    sw    t0, 0(s2)

    # Gui ACK 'y' (0x79)
    addi  a3, zero, 0x79
    jal   ra, uart_send_byte

    # Nhan so luong word N (1 byte)
    jal   ra, uart_recv_byte
    add   a2, a4, zero         # a2 = word count N

    # Con tro ghi dich = 0x0000_0200
    lui   a1, 0x00000
    addi  a1, a1, 0x200

rx_word_loop:
    beq   a2, zero, verify_crc
    jal   ra, uart_recv_word   # tra 32-bit word trong s0
    sw    s0, 0(a1)            # ghi vao I-SRAM
    sw    s0, 8(s2)            # nap vao HW CRC32.DATA_WORD
    addi  a1, a1, 4
    addi  a2, a2, -1

    # Gui ACK 0x06 sau moi word
    addi  a3, zero, 0x06
    jal   ra, uart_send_byte
    jal   zero, rx_word_loop

verify_crc:
    # Nhan 4 bytes expected_crc (little-endian) vao s0
    jal   ra, uart_recv_word
    lw    t5, 12(s2)           # Doc HW CRC32.RESULT
    bne   s0, t5, crc_mismatch

    # CRC khop -> gui EOT (0x04)
    addi  a3, zero, 0x04
    jal   ra, uart_send_byte

    # Bat khoa bao ve vung Boot (BOOT_LOCK = 1) va chay App moi
    addi  t0, zero, 1
    sw    t0, 0(s3)
    lui   a1, 0x00000
    addi  a1, a1, 0x200
    jalr  zero, a1, 0

crc_mismatch:
    # Tu choi firmware loi: gui NAK (0x15) va cho dot nap lai (khong timeout)
    addi  a3, zero, 0x15
    jal   ra, uart_send_byte
wait_sync_no_to:
    jal   ra, uart_recv_byte
    addi  t0, zero, 0x7F
    bne   a4, t0, wait_sync_no_to
    addi  t0, zero, 1
    sw    t0, 0(s2)            # reset CRC32
    addi  a3, zero, 0x79       # 'y'
    jal   ra, uart_send_byte
    jal   ra, uart_recv_byte
    add   a2, a4, zero
    lui   a1, 0x00000
    addi  a1, a1, 0x200
    jal   zero, rx_word_loop

# --- Subroutine: uart_send_byte (input: a3[7:0]) ---
uart_send_byte:
    lw    t1, 8(a0)
    andi  t1, t1, 1            # tx_busy
    bne   t1, zero, uart_send_byte
    sw    a3, 0(a0)
    jalr  zero, ra, 0

# --- Subroutine: uart_recv_byte (output: a4[7:0]) ---
uart_recv_byte:
    lw    t1, 8(a0)
    andi  t1, t1, 2            # rx_valid
    beq   t1, zero, uart_recv_byte
    lw    a4, 4(a0)
    andi  a4, a4, 0xFF
    jalr  zero, ra, 0

# --- Subroutine: uart_recv_word (output: s0 = 32-bit word LE, preserves ra in t6) ---
uart_recv_word:
    add   t6, ra, zero
    addi  s0, zero, 0
    addi  s1, zero, 0          # shift amount = 0, 8, 16, 24
rx_w_next:
    jal   ra, uart_recv_byte
    sll   t4, a4, s1
    or    s0, s0, t4
    addi  s1, s1, 8
    addi  t0, zero, 32
    bne   s1, t0, rx_w_next
    jalr  zero, t6, 0
