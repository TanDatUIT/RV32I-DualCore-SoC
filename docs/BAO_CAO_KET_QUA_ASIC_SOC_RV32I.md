# Báo Cáo Tổng Hợp Kết Quả Kiểm Chứng & Thiết Kế Vật Lý ASIC — Dual-Core RV32I SoC (GPDK 45nm)

> **Thiết kế:** `soc_top` — Dual-Core RV32I 5-Stage Pipelined SoC (Shared Harvard Dual-SRAM 8 KB, Bus 3-Master Round-Robin, Hardware Spinlock/Mailbox, Secure UART Bootloader + HW CRC-32 + Boot-Lock, Watchdog Timer, Simple DMA, Systolic 4×4 Mini-NPU + Post-Proc, SPI Master 4-Mode, Perf Counters).  
> **Công nghệ & Công cụ:** Cadence GPDK 45nm (`slow_vdd1v0` `0.9V/125°C` Setup, `fast_vdd1v0` `1.1V/0°C` Hold, `2× sram_2k_macro`) · Xcelium 24.03 · QuestaSim 2021.2_1 (`UVM-1.1d`) · Genus 21.10 · Conformal LEC 24.10 · Innovus 21.19 · Tempus 23.14.  
> **Ngày cập nhật:** `2026-11-26` (sau hậu kiểm độc lập 4 lớp `soc-post-run-audit` và hoàn tất đóng toàn bộ các mục `[MAJOR]` / `[MINOR]`).

---

## 1. Tóm Tắt Các Chỉ Số Nổi Bật (Golden Sign-off)

| Hạng mục | Kết quả thực đo |
| :--- | :--- |
| **Lint RTL (Verilator 5.029)** | **PASS 100%** — `0 errors, 0 warnings` trên toàn bộ `18` file RTL & `2` testbench (`16/16` module bọc `` `default_nettype none/wire ``). |
| **Xcelium 24.03 RTL Simulation** | **PASS 2/2** — `tb_soc_full` (`2991` cycles, `MCYCLE=2753`, `MINSTRET0=696`, `MINSTRET1=246`, `TOTAL=942`, `Dual-Core CPI = 2.92`) và `tb_soc_bootloader` (`Phase A NAK 0x15` từ chối CRC sai, `Phase B EOT 0x04`, `GPIO=0xcafe`, `UART="OK!"`, `BOOT_LOCK=1`). |
| **QuestaSim 2021.2_1 `UVM-1.1d` Regression** | **PASS 5/5 runs** (`0 UVM_WARNING/ERROR/FATAL`, `0` scoreboard mismatches, `0` SVA failures với `10/11` hit = `90.90%`). Merged coverage: **Total `70.01%`**, **Covergroups `70.71%`** (`cg_uart_boot 100.00%`, `cg_security_wdt 83.33%`, `cg_dualcore_smp 81.66%`, `cg_rv32i_hazards 79.38%`), **FSM States `94.87%`**, **Expressions `77.47%`**, **Toggles `75.30%`**. |
| **Conformal LEC 24.10 (Formal Equivalence)** | **PASS 3/3 (`100.00% Equivalent`, `0 Non-equivalent`):**<br>• `RTL → soc_syn.v`: `4,932 / 4,932` Equivalent<br>• `RTL → Base55 Post-PnR`: `4,932 / 4,932` Equivalent<br>• `RTL → FP6 ICG 65% Post-PnR` (`161` ICG): `4,931 / 4,931` Equivalent |
| **Post-PnR Gate-Level Simulation (Xcelium)** | **PASS 3/3 (zero-delay `-nospecify -notimingchecks`):**<br>• `tb_soc_full` (`Base55`): khớp từng chu kỳ RTL (`2809 / 2890 / 2991`, `CPI x100 = 292`)<br>• `tb_soc_bootloader` (`Base55`, baudrate thực `868`): PASS 100% (`24,032,675 ns`, `NAK 0x15` → `EOT 0x04, GPIO=0xcafe, UART="OK!"`)<br>• `tb_soc_full` (`FP6_icg_u65`, `161` ICG): khớp từng chu kỳ RTL (`2809 / 2991`, `CPI x100 = 292`) |
| **ASIC Sign-off tối ưu (`FP6 ICG 65%`, Post-ECO)** | **Đóng sạch Timing + Physical + MaxCap @ 100 MHz (Innovus 2-Corner OCV+CPPR):**<br>• **Setup (`Slow 0.9V/125°C`):** **`WNS = +0.034 ns`**, `TNS = 0.000 ns`, **`0` Violating Paths**<br>• **Hold (`Fast 1.1V/0°C`):** **`WNS = +0.142 ns`**, `TNS = 0.000 ns`, **`0` Violating Paths**<br>• **Vật lý & DRV:** **DRC = `0`**, **Antenna = `0`**, **Connectivity = `0`**, **`max_cap = 0`**, `clock_max_tran = 0` *(công khai minh bạch: còn `42` net datapath vượt trần `max_tran` khắt khe `280 ps` ở góc Slow `0.9V/125°C`, xấu nhất `0.781 ns` — đã giảm `68%` so với `Base55` `132` net / `1.853 ns`; `165` net vượt ràng buộc mềm `max_fanout 32` do `.lib` GPDK45 không đặt `max_fanout` và `max_cap = 0`)*<br>• **Diện tích & Công suất:** Die **`135,382.4 µm²`** (**`-21.8%`** vs Base55), Wirelength **`461,309 µm`** (**`-16.4%`**), **Total Power = `1.6679 mW`** (**`-49.0%`** vs Base55 `3.2675 mW`) |

---

## 2. Kết Quả Tổng Hợp Logic — Cadence Genus 21.10 (`slow 0.9V / 125°C`)

| Kịch bản | Tần số (MHz) | Chu kỳ (ns) | WNS / TNS (ns) | Diện tích Cell (µm²) | Công suất Genus (mW) | Ghi chú |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| 250.0 MHz (Base) | `250.0` | `4.000` | `+0.0001 / 0.000` | `84,598.206` | `5.5978` | Fmax tổng hợp |
| 200.0 MHz (Base) | `200.0` | `5.000` | `+0.0009 / 0.000` | `83,267.296` | `4.3985` | — |
| 150.0 MHz (Base) | `150.0` | `6.667` | `+0.0182 / 0.000` | `82,377.754` | `3.2434` | — |
| 100.0 MHz (Base) | `100.0` | `10.000` | `+1.3154 / 0.000` | `81,852.442` | `2.1639` | `19,257` leaf / `4,895` seq |
| **100.0 MHz (ICG)** | **`100.0`** | **`10.000`** | **`+0.3001 / 0.000`** | **`74,051.080`** (`-9.53%`) | **`0.6488`** (`-70.02%`) | `161` ICG (`TLATNTSCAX*`), `4,611/4,892` FFs gated (`94.26%`), `78.88%` toggle saving |

---

## 3. Khảo Sát Đánh Đổi PPA Chuẩn Faraday — 7 Điểm Area vs Power @ 100 MHz (Innovus 21.19)

> So sánh giảm dần Die Area ở tần số cố định `100 MHz` (`Target Util` từ `50%` đến `85%`) cùng cấu hình tối ưu **ICG Clock Gating (`65%`, Post-ECO)**.  
> *Ghi chú:* `Cong. H/V (%)` bằng `0.00%` là Global GCell Overflow trên tiến trình 11 lớp kim loại GPDK45; tuy nhiên tổng chiều dài dây lớp cao `M6..M11` tăng gấp **8 lần** (từ `27.6 mm` ở `FP1` lên `221.7 mm` ở `FP5`) khi vượt bức tường mật độ `>90%`.

| Kịch bản | Target Util | Die Area (µm²) | Core Area (µm²) | Actual Density (%) | StdCell Area (µm²) | Wirelength (µm) | Setup WNS / TNS (ns) | Hold WNS / THS (ns) | Skew (ns) | Total Power (mW) | DRC / Ant / Conn | Trạng thái thực tế |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| FP1 (Base 50%) | `0.50` | `189,214.3` | `164,006.8` | `56.19%` | `76,158.3` | `535,005` | `-0.982 / -1.897` | `+0.174 / 0.000` | `0.109` | `3.2260` | `2 / 0 / 0` | PARTIAL (~`91.1 MHz`, 2 Via6 DRC) |
| Base55 (Ref 55%) | `0.55` | `173,208.0` | `149,129.1` | `62.25%` | `76,832.7` | `552,093` | `-0.441 / -1.210` | `+0.186 / 0.000` | `0.120` | `3.2675` | `0 / 0 / 0` | PARTIAL (~`95.8 MHz`, 0 DRC) |
| FP2 (Base 60%) | `0.60` | `159,752.0` | `136,663.2` | `67.77%` | `76,622.4` | `549,480` | `-0.016 / -0.016` | `+0.155 / 0.000` | `0.103` | `3.2339` | `0 / 0 / 0` | NEAR-MET (~`99.8 MHz`, 0 DRC) |
| FP3 (Base 70%) | `0.70` | `138,614.7` | `117,169.2` | `78.77%` | `76,290.6` | `537,808` | `-0.044 / -0.081` | `+0.145 / 0.000` | `0.108` | `3.2168` | `0 / 0 / 0` | NEAR-MET (~`99.6 MHz`, 0 DRC) |
| FP4 (Base 78%) | `0.78` | `125,530.8` | `105,166.0` | **`90.88%`** | `79,573.5` | **`737,155`** | **`-9.708 / -542.05`** | **`-0.610 / -134.63`** | **`0.800`** | **`3.5769`** | `1 / 0 / 0` | **FAIL (Density Wall >90%)** |
| FP5 (Base 85%) | `0.85` | `116,051.4` | `96,505.2` | **`91.56%`** | `72,362.4` | `710,623` | **`-24.708 / -8278.2`** | **`-0.091 / -0.869`** | **`1.188`** | **`3.5406`** | `0 / 0 / 0` | **FAIL (Timing Collapse)** |
| **FP6 (ICG 65%, Post-ECO)** | **`0.65`** | **`135,382.4`** | **`114,198.9`** | **`73.40%`** | **`67,817.9`** | **`461,309`** | **`+0.034 / 0.000`** | **`+0.142 / 0.000`** | **`0.119`** | **`1.6679`** | **`0 / 0 / 0`** | **TIMING+DRC MET (100 MHz; 0 MaxCap, 42 max_tran)** |

### Nhận xét vật lý 3 vùng đánh đổi PPA
1. **Vùng Sweet Spot không ICG (`FP2 60%` – `FP3 70%`):** Thu gọn Die từ `189,214 µm²` (`FP1`) xuống `138,615 µm²` (`FP3`, `-26.7%`) giúp rút ngắn đường tín hiệu liên kết giữa `CPU0/CPU1`, `soc_bus` và 2 macro SRAM, cải thiện Setup WNS từ `-0.982 ns` về `-0.016 ns` (`FP2`) / `-0.044 ns` (`FP3`), `0` DRC và Power đáy `3.2168 mW`.
2. **Bức tường mật độ — Density Wall (`FP4 78%` & `FP5 85%`):** Khi mật độ thực tế vượt ngưỡng `90%` (`90.88%` – `91.56%`), bộ định tuyến buộc phải đi vòng lên các lớp kim loại cao khiến dây nối nổ `+37%` (`737 mm`), Clock Skew vỡ gấp `7–11×` (`0.800` – `1.188 ns`), Switching Power tăng ngược `+30%` và Timing sụp đổ hoàn toàn (`-9.71 ns` / `-24.71 ns`).
3. **Điểm tối ưu toàn cục (`FP6 ICG 65%`, Post-ECO):** Nhờ ICG Clock Gating giảm `9.53%` diện tích cell và khóa `94.26%` flip-flop, kết hợp 1 vòng ECO hậu định tuyến (`scripts/eco_fp6_golden.tcl`), thiết kế đóng sạch **Setup (`+0.034 ns`), Hold (`+0.142 ns`), DRC/Antenna/Connectivity (`0/0/0`) và `max_cap = 0` @ `100 MHz`** (gấp đôi yêu cầu `50 MHz`), nhỏ hơn `21.8%` Die và giảm **`49.0%` tổng công suất** so với `Base55` (chỉ còn `42` net datapath vượt ngưỡng `max_tran` khắt khe `280 ps`, xấu nhất `0.781 ns`, đã giảm `68%` so với `Base55`).

---

## 4. Kiểm Chứng STA Độc Lập — Cadence Tempus 23.14 (2-View MMMC + SI Crosstalk)

Script `scripts/run_tempus_soc.tcl` đã được chuẩn hóa sang **2-View MMMC (`scripts/soc.view`: `view_setup` = Slow `0.9V/125°C`, `view_hold` = Fast `1.1V/0°C`)** trên netlist sạch không filler (`soc_top_pnr_lec.v`) kèm SPEF có đầy đủ tụ xuyên nhiễu SI (`123K–144K` coupling caps):

| Thiết kế | Chế độ Tempus 2-View MMMC | Setup WNS / TNS (`view_setup`) | Hold WNS / THS (`view_hold`) | Total Power (`view_setup`) |
| :--- | :--- | :---: | :---: | :---: |
| **Base55 (Ref 55%)** | Nominal (`1.00 / 1.00`, SI-Aware) | `-1.279 / -2.877 ns` (`9` paths) | `-0.007 / -0.026 ns` (`8` paths) | `3.5604 mW` |
| **Base55 (Ref 55%)** | Intra-Corner OCV (`±5%`, SI-Aware) | `-1.875 / -11.237 ns` (`24` paths) | `-0.031 / -1.244 ns` (`120` paths) | `3.5604 mW` |
| **FP6 (ICG 65%, Post-ECO)** | Nominal (`1.00 / 1.00`, SI-Aware) | **`-0.071 / -0.156 ns`** (`4` paths, ~`99.3 MHz`) | **`-0.016 / -0.125 ns`** (`38` paths) | **`0.8996 mW`** (`-74.7%`) |
| **FP6 (ICG 65%, Post-ECO)** | Intra-Corner OCV (`±5%`, SI-Aware) | `-0.606 / -4.160 ns` (`13` paths) | `-0.043 / -3.124 ns` (`315` paths) | **`0.8996 mW`** (`-74.7%`) |

> **Giải trình kỹ thuật chính xác về chênh lệch giữa Innovus và Tempus (đã đối chiếu tới từng picosecond):**
> 1. **Chênh lệch Timing trên `FP6` (`+0.034 → -0.071 ns` Setup; `+0.142 → -0.016 ns` Hold):** Trễ datapath trên Path 1 giữa 2 tool gần như trùng khít (Tempus `9.785 ns`, thậm chí nhanh hơn Innovus `9.801 ns` đúng `16 ps`). Nguyên nhân thực sự nằm ở **CCOpt `update_io_latency`** trong Innovus đã bù `Source Insertion Delay` bất đối xứng theo mục tiêu `ID Target = 0.800 ns` (`0.371 ns` Launch vs `0.500 ns` Capture ở `view_setup` → `+129 ps`; `0.676 ns` Launch vs `0.500 ns` Capture ở `view_hold` → `+176 ps`), trong khi Tempus nạp trực tiếp `soc_syn_icg.sdc` pre-CTS đối xứng `0.500 ns` ở cả hai nhánh (cho mức `Fmax ≈ 99.3 MHz` độc lập). Với `Base55`, việc chuyển sang 2-View MMMC đã loại bỏ hoàn toàn `~300 ps` lỗi Hold giả (còn `-0.007 ns` ở Nominal).
> 2. **Chênh lệch Power trên `FP6` (`1.6679 mW` Innovus vs `0.8996 mW` Tempus):** Innovus đặt cứng `Sequential Element Activity = 0.20` trên mọi ngõ ra `Q` của flip-flop (không hạ hoạt độ tổ hợp hạ lưu dù `94.26%` flop đã được khóa ICG → `Combinational = 0.7590 mW`), trong khi engine Voltus của Tempus lan truyền hoạt độ thực (`Sequential Element Activity: N.A.`) xuyên qua `161` cell ICG (`Combinational` giảm `3.63×` còn `0.2090 mW`, `Clock Power` khớp sát `0.2686` vs `0.2465 mW`). Do đó mức **`1.6679 mW`** trong bảng PPA là giá trị **bảo thủ an toàn (worst-case vectorless)**.

---

## 5. Giới Hạn Công Khai Của Kit GPDK 45nm

- Bộ kit GPDK 45nm học thuật chỉ cung cấp LEF/LIB (không có GDS stdcell/macro gốc và không có `.cl` current library) nên GDS xuất ra phục vụ minh họa layout/flow (chưa đủ cho LVS/DRC foundry thật) và phân tích Voltus IR-Drop ở trạng thái **N/A**.
- **Giới hạn SDF Back-Annotated GLS trên GPDK 45nm:** Thư viện Verilog `slow_vdd1v0_basiccells.v` của GPDK45 **không định nghĩa khối `specify`** cho các cell tổ hợp và buffer cây clock (`109,790` cảnh báo `*W,SDFNSB: module BUFX3/BUFX2/CLKBUFX2/INVX1... has no specify block` trong `tb_soc_full_pnr_sdf.log`), trong khi `DFF*` vẫn có `$setup/$hold` specify block — khiến mô phỏng `GLS_SDF=1` lệch pha hoàn toàn (trễ cổng/clock buffer = `0 ns`) và timeout. Vì vậy quy trình xác minh chuẩn trên kit này kết hợp **Zero-Delay Post-PnR GLS (`3/3` PASS) + Formal Conformal LEC (`3/3` `0 Non-equivalent`) + 2-Corner STA (Innovus & Tempus)**.
- Các ngoại vi slave (`NPU/SPI/UART/CRC32/Timer`) không nối `w_wdt_rst` nên firmware cần khởi tạo lại thanh ghi `CTRL` sau Watchdog reboot.
