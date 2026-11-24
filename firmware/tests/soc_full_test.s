# =============================================================================
# Firmware Tu Kiem Tra Toan Dien SoC (RV32I + Dual-SRAM + DMA + Mini-NPU
#   + Timer + UART + GPIO + SPI 4-mode + HW CRC32 + Boot-Lock + WDT + Perf)
# Dia chi goc: 0x0000_0000 (I-SRAM)
# =============================================================================

.globl _start
_start:
    # Base registers (global)
    li   s0, 0x20000200        # GPIO
    li   s1, 0x20000500        # SysCtrl
    li   s2, 0x00001000        # D-SRAM
    li   s3, 0x10000000        # Mini-NPU
    li   s4, 0x10000100        # DMA
    li   s5, 0x20000300        # HW CRC32
    li   s6, 0x20000400        # SPI Master
    li   s7, 0x20000000        # Timer
    li   s8, 0x20000100        # UART

    # Kiem tra xem day la lan khoi dong sau Watchdog Reset hay Cold Boot
    lw   t0, 4(s1)             # WDT_CTRL
    andi t0, t0, 2             # bit[1] = wdt_expired
    bne  t0, zero, post_wdt_reboot

# =============================================================================
# TEST 1: RV32I ISA, Forwarding/Hazards, JAL-after-SW, D-SRAM RMW, GPIO_IN
# =============================================================================
    li   t6, 0xDE01

    # 1a. Arithmetic, signed/unsigned compare & arithmetic shift
    li   t0, -16
    srai t1, t0, 2             # -4
    li   t2, -4
    bne  t1, t2, test_fail
    srli t1, t0, 2             # 0x3FFFFFFC
    li   t2, 0x3FFFFFFC
    bne  t1, t2, test_fail
    li   t3, 3
    slt  t1, t0, t3            # -16 < 3 -> 1
    addi t2, zero, 1
    bne  t1, t2, test_fail
    sltu t1, t0, t3            # 0xFFFFFFF0 < 3 -> 0
    bne  t1, zero, test_fail
    auipc t0, 0
    beq  t0, zero, test_fail

    # 1b. Distance-3 RAW hazard (WB-to-ID bypass in regfile)
    addi t3, zero, 42
    nop
    nop
    addi t4, t3, 8
    addi t2, zero, 50
    bne  t4, t2, test_fail

    # 1c. SW followed immediately by JAL (regression check for ra preservation)
    li   t0, 0x11223344
    sw   t0, 0(s2)
    jal  ra, fn_check_ra
    li   t2, 0x1357
    bne  t1, t2, test_fail

    # 1d. Load-use hazard + D-SRAM RMW (sb / sh / lb / lbu / lh / lhu / lw)
    lw   t1, 0(s2)
    addi t1, t1, 1             # load-use stall right after lw
    li   t2, 0x11223345
    bne  t1, t2, test_fail

    addi t0, zero, 0xAA
    sb   t0, 1(s2)             # -> 0x1122AA44
    li   t0, 0xCCDD
    sh   t0, 2(s2)             # -> 0xCCDDAA44
    lw   t1, 0(s2)
    li   t2, 0xCCDDAA44
    bne  t1, t2, test_fail

    lb   t1, 1(s2)
    li   t2, -86               # 0xFFFFFFAA
    bne  t1, t2, test_fail
    lbu  t1, 1(s2)
    li   t2, 0xAA
    bne  t1, t2, test_fail
    lh   t1, 2(s2)
    li   t2, -13091            # 0xFFFFCCDD
    bne  t1, t2, test_fail
    lhu  t1, 2(s2)
    li   t2, 0xCCDD
    bne  t1, t2, test_fail

    # 1e. GPIO_IN check (TB drives 16'h1234)
    lw   t1, 0(s0)
    li   t2, 0x1234
    bne  t1, t2, test_fail

# =============================================================================
# TEST 2: DMA Copy + DMA->Mini-NPU (Skewed 4x4 Systolic + Post-Proc)
# =============================================================================
    li   t6, 0xDE02

    # Store Matrix A at D-SRAM 0x1100..0x110C
    # Row 0: [  1,  2, -3,  4] -> 0x04FD0201
    # Row 1: [ -5,  6,  7, -8] -> 0xF80706FB
    # Row 2: [  9,-10, 11, 12] -> 0x0C0BF609
    # Row 3: [-13, 14,-15, 16] -> 0x10F10EF3
    li   t0, 0x04FD0201
    sw   t0, 0x100(s2)
    li   t0, 0xF80706FB
    sw   t0, 0x104(s2)
    li   t0, 0x0C0BF609
    sw   t0, 0x108(s2)
    li   t0, 0x10F10EF3
    sw   t0, 0x10C(s2)

    # Store Matrix B at D-SRAM 0x1110..0x111C
    # Row 0: [  2, -1,  0,  3] -> 0x0300FF02
    # Row 1: [  1,  4, -2,  5] -> 0x05FE0401
    # Row 2: [ -3,  2,  6, -1] -> 0xFF0602FD
    # Row 3: [  4,  0,  1,  7] -> 0x07010004
    li   t0, 0x0300FF02
    sw   t0, 0x110(s2)
    li   t0, 0x05FE0401
    sw   t0, 0x114(s2)
    li   t0, 0xFF0602FD
    sw   t0, 0x118(s2)
    li   t0, 0x07010004
    sw   t0, 0x11C(s2)

    # 2a. DMA Copy: 0x1100 -> 0x1200 (4 words, src_inc=1, dst_inc=1 -> CTRL=0x7)
    li   t0, 0x00001100
    sw   t0, 8(s4)             # SRC_ADDR
    li   t0, 0x00001200
    sw   t0, 12(s4)            # DST_ADDR
    addi t0, zero, 4
    sw   t0, 16(s4)            # LEN_WORDS
    addi t0, zero, 7
    sw   t0, 0(s4)             # CTRL: start + src_inc + dst_inc
dma_wait_1:
    lw   t1, 4(s4)             # DMA_STATUS
    andi t2, t1, 2
    beq  t2, zero, dma_wait_1

    lw   t1, 0x208(s2)         # verify copied word 2
    li   t2, 0x0C0BF609
    bne  t1, t2, test_fail

    # 2b. DMA stream Matrix A (0x1200) -> NPU A_PACK (0x1000_0028, dst_inc=0 -> CTRL=0x3)
    sw   zero, 0x08(s3)        # A_IDX = 0
    sw   zero, 0x10(s3)        # B_IDX = 0
    li   t0, 0x00001200
    sw   t0, 8(s4)
    li   t0, 0x10000028
    sw   t0, 12(s4)
    addi t0, zero, 4
    sw   t0, 16(s4)
    addi t0, zero, 3
    sw   t0, 0(s4)
dma_wait_2:
    lw   t1, 4(s4)
    andi t2, t1, 2
    beq  t2, zero, dma_wait_2

    # 2c. DMA stream Matrix B (0x1110) -> NPU B_PACK (0x1000_002C, CTRL=0x3)
    li   t0, 0x00001110
    sw   t0, 8(s4)
    li   t0, 0x1000002C
    sw   t0, 12(s4)
    addi t0, zero, 4
    sw   t0, 16(s4)
    addi t0, zero, 3
    sw   t0, 0(s4)
dma_wait_3:
    lw   t1, 4(s4)
    andi t2, t1, 2
    beq  t2, zero, dma_wait_3

    # 2d. Start NPU and wait for done
    addi t0, zero, 1
    sw   t0, 0(s3)             # CTRL.start = 1
npu_wait:
    lw   t1, 4(s3)             # STATUS
    andi t2, t1, 2             # done sticky
    beq  t2, zero, npu_wait

    # Check done flag cleared after reading STATUS
    lw   t1, 4(s3)
    andi t2, t1, 2
    bne  t2, zero, test_fail

    # 2e. Verify all 16 elements of C = A x B (R_IDX = (col<<2)|row)
    # Row 0: [29, 1, -18, 44]
    addi t0, zero, 0x00
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 29
    bne  t1, t2, test_fail

    addi t0, zero, 0x04
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 1
    bne  t1, t2, test_fail

    addi t0, zero, 0x08
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, -18
    bne  t1, t2, test_fail

    addi t0, zero, 0x0C
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 44
    bne  t1, t2, test_fail

    # Row 1: [-57, 43, 22, -48]
    addi t0, zero, 0x01
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, -57
    bne  t1, t2, test_fail

    addi t0, zero, 0x05
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 43
    bne  t1, t2, test_fail

    addi t0, zero, 0x09
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 22
    bne  t1, t2, test_fail

    addi t0, zero, 0x0D
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, -48
    bne  t1, t2, test_fail

    # Row 2: [23, -27, 98, 50]
    addi t0, zero, 0x02
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 23
    bne  t1, t2, test_fail

    addi t0, zero, 0x06
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, -27
    bne  t1, t2, test_fail

    addi t0, zero, 0x0A
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 98
    bne  t1, t2, test_fail

    addi t0, zero, 0x0E
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 50
    bne  t1, t2, test_fail

    # Row 3: [97, 39, -102, 158]
    addi t0, zero, 0x03
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 97
    bne  t1, t2, test_fail

    addi t0, zero, 0x07
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 39
    bne  t1, t2, test_fail

    addi t0, zero, 0x0B
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, -102
    bne  t1, t2, test_fail

    addi t0, zero, 0x0F
    sw   t0, 0x18(s3)
    lw   t1, 0x1C(s3)
    addi t2, zero, 158
    bne  t1, t2, test_fail

    # 2f. Post-processing check: ReLU + INT8 clamp (POST_CFG = 0x21)
    addi t0, zero, 0x21
    sw   t0, 0x20(s3)
    addi t0, zero, 0x08        # C[0][2] = -18 -> ReLU -> 0
    sw   t0, 0x18(s3)
    lw   t1, 0x24(s3)
    bne  t1, zero, test_fail
    addi t0, zero, 0x0F        # C[3][3] = 158 -> Clamp8 -> 127
    sw   t0, 0x18(s3)
    lw   t1, 0x24(s3)
    addi t2, zero, 127
    bne  t1, t2, test_fail
    addi t0, zero, 0x0A        # C[2][2] = 98 -> stays 98
    sw   t0, 0x18(s3)
    lw   t1, 0x24(s3)
    addi t2, zero, 98
    bne  t1, t2, test_fail

    # Arithmetic shift check: POST_CFG = 0x02 (shift=1, no relu/clamp)
    addi t0, zero, 0x02
    sw   t0, 0x20(s3)
    addi t0, zero, 0x01        # C[1][0] = -57 -> (-57 >>> 1) = -29
    sw   t0, 0x18(s3)
    lw   t1, 0x24(s3)
    addi t2, zero, -29
    bne  t1, t2, test_fail

# =============================================================================
# TEST 3: Timer + SPI Master (all 4 modes loopback) + UART TX smoke
# =============================================================================
    li   t6, 0xDE03

    # 3a. Timer one-shot countdown
    addi t0, zero, 20
    sw   t0, 4(s7)             # LOAD = 20
    addi t0, zero, 1
    sw   t0, 0(s7)             # CTRL: en=1, periodic=0
timer_wait:
    lw   t1, 0(s7)
    andi t1, t1, 1
    bne  t1, zero, timer_wait
    lw   t1, 8(s7)             # COUNT must be 0
    bne  t1, zero, test_fail

    # 3b. SPI Master all 4 (CPOL, CPHA) modes with loopback (clkdiv = 1)
    # Mode 0 (cpol=0, cpha=0): CTRL = 0x0109, send 0xA5
    li   t0, 0x0109
    addi t3, zero, 0xA5
    jal  ra, spi_xfer_check
    # Mode 1 (cpol=0, cpha=1): CTRL = 0x010D, send 0x3C
    li   t0, 0x010D
    addi t3, zero, 0x3C
    jal  ra, spi_xfer_check
    # Mode 2 (cpol=1, cpha=0): CTRL = 0x010B, send 0x5A
    li   t0, 0x010B
    addi t3, zero, 0x5A
    jal  ra, spi_xfer_check
    # Mode 3 (cpol=1, cpha=1): CTRL = 0x010F, send 0xF0
    li   t0, 0x010F
    addi t3, zero, 0xF0
    jal  ra, spi_xfer_check

    # 3c. UART TX quick byte ('T')
    addi t0, zero, 1
    sw   t0, 12(s8)            # UART CTRL = 1
    addi t0, zero, 0x54
    sw   t0, 0(s8)

# =============================================================================
# TEST 4: HW CRC32 ("123456789" -> 0xCBF43926)
# =============================================================================
    li   t6, 0xDE04

    addi t0, zero, 1
    sw   t0, 0(s5)             # CRC32.CTRL = INIT
    li   t0, 0x34333231        # "1234" little-endian
    sw   t0, 8(s5)             # DATA_WORD
    li   t0, 0x38373635        # "5678"
    sw   t0, 8(s5)             # DATA_WORD
    addi t0, zero, 0x39        # "9"
    sw   t0, 4(s5)             # DATA_BYTE
    lw   t1, 12(s5)            # RESULT
    li   t2, 0xCBF43926
    bne  t1, t2, test_fail

# =============================================================================
# TEST 5: Boot-Region Write-Lock Security Enforcement
# =============================================================================
    li   t6, 0xDE05

    lw   t3, 0(zero)           # Save I-SRAM[0]
    addi t0, zero, 1
    sw   t0, 0(s1)             # SysCtrl.BOOT_LOCK = 1
    sw   zero, 0(zero)         # Attempt illegal overwrite at 0x0000_0000
    lw   t4, 0(zero)
    bne  t3, t4, test_fail     # Must be unchanged!
    lw   t1, 0(s1)             # Check BOOT_LOCK[1] boot_viol == 1
    andi t1, t1, 2
    beq  t1, zero, test_fail

# =============================================================================
# TEST 5B: Dual-Core RV32I (HART_ID + Mailbox + Atomic Spinlock + MINSTRET1)
# =============================================================================
    li   t6, 0xDE06

    # Check Core 0 sees HART_ID == 0
    lw   t1, 0x24(s1)          # HART_ID
    bne  t1, zero, test_fail

    # Clear shared counter at D-SRAM 0x1320, post token to Mailbox 0->1, launch Core 1
    sw   zero, 0x320(s2)
    li   t0, 0x11223344
    sw   t0, 0x34(s1)          # MBOX_0TO1 = 0x11223344 (sets mbox_0to1_valid)
    la   t0, core1_entry
    sw   t0, 0x2C(s1)          # CORE1_BOOT_PC
    addi t0, zero, 1
    sw   t0, 0x28(s1)          # CORE1_CTRL = enable Core 1

    # Core 0 executes 16 atomic increments (+1 each) in parallel with Core 1
    addi t3, zero, 16
c0_loop:
c0_acquire:
    lw   t0, 0x30(s1)          # SPINLOCK atomic test-and-set
    bne  t0, zero, c0_acquire
    lw   t1, 0x320(s2)         # shared_counter += 1
    addi t1, t1, 1
    sw   t1, 0x320(s2)
    sw   zero, 0x30(s1)        # release SPINLOCK
    addi t3, t3, -1
    bne  t3, zero, c0_loop

    # Wait for Core 1 completion via MBOX_1TO0 valid flag (CORE1_CTRL[6])
c0_wait_c1:
    lw   t0, 0x28(s1)
    andi t0, t0, 0x40
    beq  t0, zero, c0_wait_c1

    # Read MBOX_1TO0 (clears valid) and verify reply token 0x11224455
    lw   t1, 0x38(s1)
    li   t2, 0x11224455
    bne  t1, t2, test_fail

    # Verify auto-ack cleared mbox_1to0_valid (bit 6)
    lw   t0, 0x28(s1)
    andi t0, t0, 0x40
    bne  t0, zero, test_fail

    # Verify shared counter == 16*1 + 16*16 == 272 (0x110)
    lw   t1, 0x320(s2)
    li   t2, 272
    bne  t1, t2, test_fail

    # Verify Core 1 retired instructions > 0
    lw   t0, 0x3C(s1)          # MINSTRET1_LO
    beq  t0, zero, test_fail

# =============================================================================
# TEST 6: Perf Counters -> D-SRAM, Signal Stage-1 Pass 0xA55A, Trigger WDT
# =============================================================================
    lw   t0, 0x18(s1)          # MCYCLE_LO
    sw   t0, 0x300(s2)         # D-SRAM 0x1300
    lw   t0, 0x1C(s1)          # MINSTRET_LO (CPU0)
    sw   t0, 0x304(s2)         # D-SRAM 0x1304
    lw   t0, 0x3C(s1)          # MINSTRET1_LO (CPU1)
    sw   t0, 0x308(s2)         # D-SRAM 0x1308

    li   t0, 0xFFFF
    sw   t0, 8(s0)             # GPIO_OE = 0xFFFF
    li   t0, 0xA55A
    sw   t0, 4(s0)             # GPIO_OUT = 0xA55A (Stage 1 Pass)

    # Trigger Watchdog Timer reset after ~64 cycles
    addi t0, zero, 64
    sw   t0, 8(s1)             # WDT_LOAD = 64
    addi t0, zero, 1
    sw   t0, 4(s1)             # WDT_CTRL: en = 1
wait_wdt_rst:
    jal  zero, wait_wdt_rst

# =============================================================================
# TEST 7 (Post-Watchdog Reboot): Verify WDT_CTRL[1], SOC_ID, signal 0xBEEF
# =============================================================================
post_wdt_reboot:
    li   t6, 0xDE07
    addi t0, zero, 2
    sw   t0, 4(s1)             # W1C wdt_expired
    lw   t1, 4(s1)
    andi t1, t1, 2
    bne  t1, zero, test_fail

    # Verify Watchdog reset parked Core 1 (CORE1_CTRL.en == 0)
    lw   t1, 0x28(s1)
    andi t1, t1, 1
    bne  t1, zero, test_fail

    lw   t1, 0x20(s1)          # SOC_ID
    li   t2, 0x564D3102
    bne  t1, t2, test_fail

    li   t0, 0xFFFF
    sw   t0, 8(s0)
    li   t0, 0xBEEF
    sw   t0, 4(s0)             # GPIO_OUT = 0xBEEF (Stage 2 Pass)

halt_ok:
    jal  zero, halt_ok

# --- Helper: fn_check_ra ---
fn_check_ra:
    li   t1, 0x1357
    jalr zero, ra, 0

# --- Helper: spi_xfer_check (t0 = CTRL, t3 = tx byte) ---
spi_xfer_check:
    sw   t0, 12(s6)            # SPI.CTRL
    sw   t3, 0(s6)             # SPI.TXDATA
spi_wait:
    lw   t1, 8(s6)             # SPI.STATUS
    andi t2, t1, 1             # busy
    bne  t2, zero, spi_wait
    andi t2, t1, 2             # rx_valid
    beq  t2, zero, test_fail
    lw   t4, 4(s6)             # SPI.RXDATA
    bne  t4, t3, test_fail
    jalr zero, ra, 0

# --- Failure handler: writes 0xDE0x to GPIO_OUT and halts ---
test_fail:
    li   t0, 0xFFFF
    sw   t0, 8(s0)
    sw   t6, 4(s0)
halt_fail:
    jal  zero, halt_fail

# =============================================================================
# CORE 1 WORKER ENTRY POINT (Hart 1)
# =============================================================================
core1_entry:
    li   s1, 0x20000500        # SysCtrl
    li   s2, 0x00001000        # D-SRAM

    # Verify Hart ID == 1
    lw   t1, 0x24(s1)
    addi t2, zero, 1
    bne  t1, t2, c1_fail

    # Verify MBOX_0TO1 valid bit (CORE1_CTRL[5])
    lw   t0, 0x28(s1)
    andi t0, t0, 0x20
    beq  t0, zero, c1_fail

    # Read token from MBOX_0TO1 (clears valid)
    lw   t4, 0x34(s1)

    # Execute 16 atomic increments (+16 each) in parallel with Core 0
    addi t3, zero, 16
c1_loop:
c1_acquire:
    lw   t0, 0x30(s1)          # SPINLOCK atomic test-and-set
    bne  t0, zero, c1_acquire
    lw   t1, 0x320(s2)         # shared_counter += 16
    addi t1, t1, 16
    sw   t1, 0x320(s2)
    sw   zero, 0x30(s1)        # release SPINLOCK
    addi t3, t3, -1
    bne  t3, zero, c1_loop

    # Post transformed token (token + 0x1111 = 0x11224455) back to Core 0
    li   t5, 0x1111
    add  t4, t4, t5
    sw   t4, 0x38(s1)          # MBOX_1TO0

c1_park:
    jal  zero, c1_park

c1_fail:
    li   t0, 0xDEADDEAD
    sw   t0, 0x38(s1)
    jal  zero, c1_park
