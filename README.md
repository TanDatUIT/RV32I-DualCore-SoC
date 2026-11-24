# Dual-Core RV32I SoC (Dual-SRAM + Mini-NPU + DMA + Security + SPI)

Hệ thống vi xử lý **Dual-Core RV32I SMP SoC** viết bằng Verilog-2001 chuẩn tổng hợp, đi kèm bộ firmware tự kiểm (RV32I assembler), testbench mức hệ thống, tài liệu đặc tả UVM và script tổng hợp/P&R FPGA (Vivado OOC).

---

## 1. Kiến trúc SoC (`rtl/soc_top.v`)

| Khối chức năng | File RTL | Mô tả chính |
|---|---|---|
| **CPU0 & CPU1 (Dual-Core RV32I)** | `rtl/rv32i/rv32i_core.v`, `rv32i_alu.v`, `rv32i_regfile.v` | 2 lõi RV32I 5 tầng pipeline độc lập (`u_cpu0` boot `0x0000_0000`, `u_cpu1` boot `CORE1_BOOT_PC`, soft-reset đồng bộ, forwarding & load-use stall, ALU tối ưu dùng chung adder/shifter). |
| **System Bus (Harvard 2 kênh)** | `rtl/bus/soc_bus.v` | Kênh 1 (I-SRAM): Round-Robin giữa CPU0/CPU1 I-Fetch + nhường D-Bus khi bootloader ghi code. Kênh 2 (Data/MMIO): Round-Robin 3-Master công bằng giữa **CPU0 (ID 0)**, **CPU1 (ID 1)** và **DMA (ID 2)**; bảo vệ `BOOT_LOCK`, chống DMA self-access và triệt tiêu xung `ready` mồ côi khi soft-reset. |
| **Dual-SRAM 8 KB (4 KB I + 4 KB D)** | `rtl/mem/sram_ctrl.v` + `sim/sram_2k_macro.v` | 2 bank SRAM độc lập (read/write 2 chu kỳ, byte/halfword RMW 4 chu kỳ). |
| **Mini-NPU Accelerator (4×4 INT8)** | `rtl/accel/accel_wrapper.v`, `accelerator_top.v`, `pe.v` | Mảng systolic 4×4 INT8 tích lũy 20-bit + hậu xử lý ReLU / Shift / Clamp8 + thanh ghi nạp nhanh `A_PACK`/`B_PACK` tương thích DMA. |
| **DMA Controller** | `rtl/dma/soc_dma.v` | Master thứ 3 trên D-Bus, copy word 32-bit SRAM ↔ SRAM / NPU / Ngoại vi, hỗ trợ hủy khẩn cấp khi Watchdog reset. |
| **Ngoại vi chuẩn** | `soc_timer.v`, `soc_uart.v`, `soc_gpio.v`, `soc_crc32.v`, `soc_spi.v` | Timer 32-bit, UART 8-N-1 (3-FF RX sync), GPIO 16-bit (2-FF input sync), HW CRC-32 (IEEE 802.3), SPI Master 4 mode `(CPOL, CPHA)`. |
| **SysCtrl, Security & Dual-Core SMP** | `rtl/periph/soc_sysctrl.v` | `BOOT_LOCK` (RW1S), Watchdog Timer (`0x5A5AA5A5`, tự park Core 1 & hủy DMA), Perf Counters (`MCYCLE`, `MINSTRET0`, `MINSTRET1`), `HART_ID`, `CORE1_CTRL`/`CORE1_BOOT_PC`, **Atomic `SPINLOCK`**, **`MBOX_0TO1`/`MBOX_1TO0`**, `SOC_ID`. |

---

## 2. Cấu trúc thư mục

- `rtl/` + `rtl/filelist_soc.f`: Toàn bộ 16 module RTL chuẩn Verilog-2001 (`default_nettype none`/`wire`).
- `sim/`: Mô hình hành vi SRAM (`sram_2k_macro.v`) và 2 testbench tự kiểm (`tb_soc_full.v`, `tb_soc_bootloader.v`).
- `firmware/`:
  - `bootloader/bootloader.{s,hex}`: UART Secure Bootloader kiểm tra HW CRC-32 + khóa `BOOT_LOCK`.
  - `apps/app_update.{s,hex}`: Ứng dụng mẫu nạp qua UART.
  - `tests/soc_full_test.{s,hex}`: Bài test hệ thống toàn diện gồm **TEST 5B Dual-Core SMP** (`HART_ID`, `MBOX`, tranh chấp `SPINLOCK`, `MINSTRET1_LO`, kiểm tra `CORE1_CTRL.en == 0` sau WDT reset).
- `docs/SOC_SPEC_FOR_UVM.md`: Đặc tả bàn giao đầy đủ (Memory Map, Register Map `0x00–0x3C`, 8 Covergroups, 5 SVA gợi ý).
- `scripts/`:
  - `rv32i_asm.py`: Trình hợp dịch RV32I nhẹ cho firmware.
  - `uart_flasher.py`: Công cụ gửi firmware qua giao thức UART Secure Bootloader.
  - `vivado_sram_2k_synth.v`, `run_vivado_synth.tcl`, `run_vivado_impl.tcl`: Flow tổng hợp & P&R FPGA OOC trên Vivado.

---

## 3. Kiểm tra nhanh

```bash
# 1. Verilator lint toàn bộ RTL (0 errors, 0 warnings)
./lint.sh

# 2. Biên dịch lại firmware nếu chỉnh sửa .s
python3 scripts/rv32i_asm.py firmware/bootloader/bootloader.s firmware/bootloader/bootloader.hex 0x00000000
python3 scripts/rv32i_asm.py firmware/apps/app_update.s firmware/apps/app_update.hex 0x00000200
python3 scripts/rv32i_asm.py firmware/tests/soc_full_test.s firmware/tests/soc_full_test.hex 0x00000000

# 3. Tổng hợp & P&R FPGA OOC (Vivado, tùy chọn)
vivado -mode batch -nojournal -nolog -source scripts/run_vivado_synth.tcl
vivado -mode batch -nojournal -nolog -source scripts/run_vivado_impl.tcl
```

---

## 4. Trạng thái xác minh hiện tại

- **Verilator lint (`./lint.sh` & strict Verilog-2001):** **0 errors, 0 warnings** trên toàn bộ 18 module (`soc_top` + 2 bank `sram_2k_macro`).
- **Vivado 2022.2 OOC Synth (`xck26-sfvc784-2LV-c` @ 100 MHz, gồm virtual I/O delays):** `6,540` LUTs, `4,928` FFs, `2 RAMB36E2`, `0` latches, `0` combinational loops, **`WNS = +4.277 ns`**, **`WHS = +0.026 ns`**.
- **Vivado 2022.2 OOC Post-Route P&R (100 MHz, register-to-register):** `6,433` LUTs, `4,928` FFs, `2 RAMB36E2`, **`WNS = +2.202 ns`**, **`WHS = +0.010 ns`**, `0` DRC, `0` routing errors (`0.305 W` on-chip power).
- **Mô phỏng động & UVM:** Testbench `tb_soc_full.v` (gồm `TEST 5B` Dual-Core) và `tb_soc_bootloader.v` sẵn sàng chạy trên simulator EDA / môi trường UVM.
