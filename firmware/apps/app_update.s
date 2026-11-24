# =============================================================================
# User Application Firmware v2 (Nap qua UART Secure Bootloader)
# Dia chi goc: 0x0000_0200
# Muc tieu: Chung minh Firmware moi duoc xac thuc CRC32, nap thanh cong,
#           bat GPIO OE + xuat 0xCAFE ra GPIO_DATA_OUT (offset 0x04),
#           va gui "OK!" qua UART TX.
# =============================================================================

.globl _start
_start:
    # 1. Khoi tao GPIO Base = 0x2000_0200
    lui   a0, 0x20000
    addi  a0, a0, 0x200        # a0 = 0x2000_0200

    # Bat Output Enable = 0xFFFF tai offset 0x08 (GPIO_OE)
    lui   t0, 0x00010          # 0x0001_0000
    addi  t0, t0, -1           # t0 = 0x0000_FFFF
    sw    t0, 8(a0)            # GPIO_OE = 0xFFFF

    # Xuat gia tri 0xCAFE (51966) tai offset 0x04 (GPIO_DATA_OUT)
    # 0x0000D000 (53248) - 1282 = 51966 = 0xCAFE
    lui   t0, 0x0000D
    addi  t0, t0, -1282
    sw    t0, 4(a0)            # GPIO_DATA_OUT = 0xCAFE

    # 2. Gui ky tu 'O' 'K' '!' (0x4F, 0x4B, 0x21) qua UART TX (0x2000_0100)
    lui   a1, 0x20000
    addi  a1, a1, 0x100        # a1 = UART Base

tx_o:
    lw    t1, 8(a1)            # UART_STATUS
    andi  t1, t1, 1            # bit 0: tx_busy
    bne   t1, zero, tx_o
    addi  t2, zero, 79         # 'O' = 0x4F
    sw    t2, 0(a1)

tx_k:
    lw    t1, 8(a1)
    andi  t1, t1, 1
    bne   t1, zero, tx_k
    addi  t2, zero, 75         # 'K' = 0x4B
    sw    t2, 0(a1)

tx_excl:
    lw    t1, 8(a1)
    andi  t1, t1, 1
    bne   t1, zero, tx_excl
    addi  t2, zero, 33         # '!' = 0x21
    sw    t2, 0(a1)

    # 3. Vong lap vo tan
inf_loop:
    jal   zero, inf_loop
