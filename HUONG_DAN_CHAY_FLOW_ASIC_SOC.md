# Hướng Dẫn Chạy Flow ASIC Physical Design (RTL-to-GDSII) Cho Dual-Core RV32I SoC Trên Server EDA

> **Dành cho người dùng Windows (MobaXterm) — toàn bộ script chạy trực tiếp trên server Linux EDA, không phụ thuộc máy Linux cá nhân.**

---

## 1. Cấu trúc thư mục cần có trên Server EDA

Tải mã nguồn RTL + Firmware + Testbench từ repo GitHub sạch:
- Repo nguồn: `https://github.com/TanDatUIT/RV32I-DualCore-SoC` (chứa `rtl/`, `firmware/`, `sim/`, `docs/`)
- Toàn bộ `rtl/`, `firmware/`, `sim/`, `sdc/`, `scripts/` và file hướng dẫn này đều đã nằm sẵn trong cùng repo:

```text
<thu_muc_du_an>/
├── rtl/                        # 16 file RTL Verilog-2001 + filelist_soc.f
├── firmware/                   # bootloader.hex, app_update.hex, soc_full_test.hex
├── sim/                        # sram_2k_macro.v, tb_soc_full.v, tb_soc_bootloader.v
├── sdc/
│   └── soc.sdc                 # Ràng buộc timing (mặc định 100 MHz, đổi bằng SOC_CLK_PERIOD)
└── scripts/                    # Toàn bộ script chạy trực tiếp trên server EDA
    ├── run_all_server.sh       # Script tổng điều khiển từng bước hoặc toàn flow
    ├── run_sim.sh              # Cadence Xcelium (RTL sim & Post-PnR GLS)
    ├── run_genus_soc.tcl       # Cadence Genus (100 MHz Baseline hoặc + ICG Clock Gating)
    ├── sweep_frequencies.sh    # Quét 4 tần số: 250 / 200 / 150 / 100 MHz
    ├── run_lec.do              # Cadence Conformal LEC (RTL vs Netlist)
    ├── soc.view                # Cấu hình MMMC 2 góc (Slow 0.9V 125C / Fast 1.1V 0C)
    ├── run_innovus_soc.tcl     # Cadence Innovus PnR (Floorplan -> PDN -> Place -> CTS -> Route -> GDS)
    ├── sweep_area_ppa_100mhz.sh# Quét 6 mức Utilization (50%->85% + ICG 65%) @ 100 MHz (bảng PPA)
    └── run_tempus_soc.tcl      # Cadence Tempus 2-Corner STA Sign-off
```

---

## 2. Kết nối Server EDA bằng MobaXterm (Windows)

### Bước 2.1 — Tạo SSH Session trên MobaXterm
1. Mở **MobaXterm** → bấm nút **Session** (góc trên bên trái) → chọn **SSH**.
2. Điền thông tin kết nối server EDA của trường:
   - **Remote host:** `<điền IP server EDA>`
   - **Specify username:** tích chọn và điền `<tài khoản sinh viên của bạn>`
   - **Port:** `22`
   - **Advanced SSH settings:** giữ bật **X11-Forwarding** (để mở giao diện GUI Innovus nếu cần xem layout).
3. Nếu đăng nhập bằng dòng lệnh terminal:
   ```bash
   ssh <username>@<server_ip>
   ```
   *(Điền username và IP server trường cấp, sau đó nhập mật khẩu).*

### Bước 2.2 — Đưa code lên server bằng thanh SFTP của MobaXterm
1. Sau khi đăng nhập SSH thành công, cột bên trái MobaXterm tự hiện **SFTP File Browser**.
2. Tạo thư mục dự án trên server (hoặc gõ lệnh):
   ```bash
   git clone https://github.com/TanDatUIT/RV32I-DualCore-SoC.git ~/RV32I_SoC
   cd ~/RV32I_SoC
   ```
3. Nếu server không có Internet để `git clone`, hãy tải file ZIP repo trên máy Windows rồi kéo thả vào `~/RV32I_SoC` qua cột SFTP bên trái của MobaXterm.

### Bước 2.3 — Chuẩn hóa ký tự xuống dòng Windows (`\r\n`) & cấp quyền chạy (BẮT BUỘC)
File kéo từ Windows lên Linux dễ dính lỗi xuống dòng CRLF (`^M`) khiến script bash báo lỗi `bad interpreter`. Chạy 1 lần lệnh sau trên server:
```bash
cd ~/RV32I_SoC
sed -i 's/\r$//' scripts/*.sh scripts/*.tcl scripts/*.do scripts/*.view sdc/*.sdc
chmod +x scripts/*.sh
```

### Bước 2.4 — Khai báo đường dẫn thư viện PDK GPDK45
Kiểm tra đường dẫn thư mục `PDK_GPDK45` trong tài khoản server của bạn (cần có `lib/` và `lef/` bên trong):
```bash
export PDK=$HOME/PDK_GPDK45
ls -la "$PDK/lib" "$PDK/lef"
```
> **Lưu ý:** Nếu thư mục PDK của bạn đặt tên/vị trí khác, chỉ cần đổi biến `export PDK=/duong/dan/toi/PDK_GPDK45`. Tất cả script đều tự đọc biến `$PDK`.
> Ngoài ra, nếu server yêu cầu `source` file môi trường Cadence trước khi gọi `xrun`/`genus`/`innovus`/`tempus`/`lec`, hãy chạy lệnh `source` của môn học trước.

---

## 3. Sơ đồ Flow ASIC & Ý nghĩa từng Script

```text
[1] RTL Sim (Xcelium)     : run_sim.sh all rtl
        │
        ▼
[2] Synthesis (Genus)     : run_genus_soc.tcl (Baseline & ICG Clock Gating)
                            sweep_frequencies.sh (250 / 200 / 150 / 100 MHz)
        │
        ▼
[3] Formal Check (LEC)    : run_lec.do (đối chiếu RTL vs Gate-level Netlist)
        │
        ▼
[4] Place & Route         : run_innovus_soc.tcl + soc.view (2-Corner MMMC)
    (Innovus)               (Floorplan 2x SRAM -> PDN -> Place -> CTS -> Route -> SPEF/SDF/GDS)
        │
        ├──▶ [5] Sign-off STA (Tempus) : run_tempus_soc.tcl
        ├──▶ [6] Post-PnR GLS (Xcelium): run_sim.sh all pnr
        └──▶ [7] Bảng PPA Area-vs-Power: sweep_area_ppa_100mhz.sh (6 mức Util @ 100 MHz)
```

---

## 4. Các lệnh chạy trực tiếp trên Server (dùng `run_all_server.sh`)

> **Mẹo chống đứt mạng / tắt máy tính Windows mà job không chết (`screen`):**
> Trước khi chạy các bước nặng (`syn`, `sweep`, `pnr`, `area_ppa`), hãy mở một phiên `screen` trên server:
> ```bash
> screen -S soc_flow
> ```
> - Muốn **tạm thoát ra ngoài** để tắt MobaXterm/tắt máy mà server vẫn chạy tiếp: bấm **`Ctrl + A`**, thả ra rồi bấm **`D`** (Detach).
> - Khi mở MobaXterm lại, muốn **vào xem lại tiến độ**:
>   ```bash
>   screen -ls
>   screen -r soc_flow
>   ```

### Cách 1 — Chạy từng bước riêng lẻ (khuyên dùng để dễ quan sát & debug)

```bash
cd ~/RV32I_SoC
export PDK=$HOME/PDK_GPDK45

# Bước 1: Mô phỏng RTL bằng Cadence Xcelium (2 testbench: tb_soc_full + tb_soc_bootloader)
./scripts/run_all_server.sh sim

# Bước 2A: Tổng hợp Logic 100 MHz + ICG Clock Gating (tiết kiệm Dynamic Power)
./scripts/run_all_server.sh syn_icg

# Bước 2B: Tổng hợp 100 MHz Baseline (hoặc bỏ qua nếu chạy luôn Bước 2C vì sweep chạy 100 MHz cuối cùng)
./scripts/run_all_server.sh syn

# Bước 2C: Quét 4 tần số (250 / 200 / 150 / 100 MHz) -> tự sinh bảng reports/syn/frequency_sweep_summary.md
./scripts/run_all_server.sh sweep

# Bước 3: Kiểm tra tương đương logic Conformal LEC (RTL vs Netlist)
./scripts/run_all_server.sh lec

# Bước 4: Physical Design RTL-to-GDSII bằng Cadence Innovus (2-Corner MMMC, 2x SRAM Macro)
./scripts/run_all_server.sh pnr

# Bước 5: Sign-off Timing độc lập bằng Cadence Tempus (Slow Setup + Fast Hold + SPEF)
./scripts/run_all_server.sh tempus

# Bước 6: Mô phỏng sau PnR (Gate-Level Simulation - Post-PnR)
./scripts/run_all_server.sh gls

# Bước 7 (Tùy chọn nâng cao PPA): Quét 6 mức Utilization (50%->85% + ICG 65%) @ 100 MHz
# Tự xuất bảng đánh đổi Area vs Power vs Congestion vs DRC tại reports/pnr/area_ppa_tradeoff_100mhz.md
./scripts/run_all_server.sh area_ppa
```

### Cách 2 — Chạy tự động trọn bộ từ đầu đến cuối (nên chạy trong `screen`)

```bash
cd ~/RV32I_SoC
export PDK=$HOME/PDK_GPDK45
./scripts/run_all_server.sh all
```

### Kiểm tra nhanh trạng thái & kết quả bất cứ lúc nào

```bash
./scripts/run_all_server.sh status
```

---

## 5. Cách xem Layout trên GUI Innovus bằng MobaXterm

MobaXterm có sẵn X-Server nên mở GUI rất dễ (chỉ cần bật X11-Forwarding ở Bước 2.1):

```bash
cd ~/RV32I_SoC
export PDK=$HOME/PDK_GPDK45

# Mở Innovus và nạp snapshot thiết kế sau khi chạy xong PnR
innovus -init work_pnr/DBS/signoff.enc
```
> Nếu cửa sổ GUI bị đen hoặc báo lỗi OpenGL/GLX, chạy kèm biến phần mềm:
> ```bash
> LIBGL_ALWAYS_SOFTWARE=1 innovus -init work_pnr/DBS/signoff.enc
> ```
> Các snapshot có sẵn trong `work_pnr/DBS/` để chụp hình báo cáo từng giai đoạn:
> `floorplan.enc` → `powerplan.enc` → `placement.enc` → `cts.enc` → `routed.enc` → `signoff.enc`.

---

## 6. Danh sách file Báo cáo & Sản phẩm đầu ra cần đọc/tải về

Sau khi chạy xong, có thể dùng thanh **SFTP bên trái MobaXterm** tải thư mục `reports/` và `outputs/` về Windows:

| Giai đoạn | File báo cáo quan trọng | Ý nghĩa chỉ số cần trích |
|---|---|---|
| **Xcelium RTL / GLS** | `reports/sim/tb_soc_full_{rtl,pnr}.log`<br>`reports/sim/tb_soc_bootloader_{rtl,pnr}.log` | Dòng `PASSED 100%`, `MCYCLE`, `MINSTRET0`, `MINSTRET1`, `Dual-Core CPI`, `UART="OK!"` |
| **Genus Synthesis** | `reports/syn/qor.rpt`<br>`reports/syn/power.rpt`<br>`reports/syn/run_100.0MHz_icg/clock_gating.rpt`<br>`reports/syn/frequency_sweep_summary.md` | `WNS`, `TNS`, `Total Area`, `Total Power`, `% Gated Flip-Flops`, bảng đánh đổi 4 tần số |
| **Conformal LEC** | `reports/lec/lec_soc.log` | Bảng `Equivalent / Non-equivalent` (PO, DFF, BBOX) |
| **Innovus PnR** | `reports/pnr/signoff/signoff_setup.summary`<br>`reports/pnr/signoff/signoff_hold.summary`<br>`reports/pnr/signoff/design_summary.rpt`<br>`reports/pnr/signoff/power.rpt`<br>`reports/pnr/route/drc_fixed.rpt`<br>`reports/pnr/route/antenna.rpt` | Post-Route Setup/Hold WNS & TNS, Die/Core Area, Wirelength, Power, số lỗi DRC/Antenna/Connectivity |
| **Tempus Sign-off** | `reports/pnr/tempus/tempus_timing.rpt`<br>`reports/pnr/tempus/tempus_timing_hold.rpt` | Xác nhận Setup (Slow 0.9V 125°C) & Hold (Fast 1.1V 0°C) độc lập với SPEF |
| **Bảng PPA Area @ 100 MHz** | `reports/pnr/area_ppa_tradeoff_100mhz.md` | Bảng so sánh 6 mức Area (`50%→85%` + `ICG 65%`) vs Power / Congestion / Timing / DRC |
| **Outputs vật lý** | `outputs/soc_top_final_pr.v`, `outputs/soc_top.spef`, `outputs/soc_top.sdf`, `outputs/soc_top_final.def`, `outputs/soc_top.gds` | Netlist sau PnR, ký sinh RC (SPEF), delay (SDF), layout (DEF/GDSII) |

---

## 7. Lưu ý giới hạn kỹ thuật của bộ kit GPDK45 (tránh hiểu nhầm khi báo cáo)

1. **License 1 CPU:** Script đặt `max_cpus 1` / `setMultiCpuUsage -localCpu 1` để phù hợp license phòng lab.
2. **Không dùng `python3` sau khi nạp môi trường Cadence:** Nếu môi trường Cadence làm lỗi locale `python3`, các script bash trong thư mục này đã dùng thuần `bash/awk/sed` nên không bị ảnh hưởng.
3. **Voltus IR-Drop:** Kit GPDK45 thiếu file thư viện dòng `.cl` nên phân tích rail/IR-drop trong `run_innovus_soc.tcl` được bọc `catch` và in cảnh báo `WARN` (không làm lỗi flow).
4. **GDSII:** Kit chỉ cung cấp LEF/LIB stdcell & macro (không kèm GDS gốc stdcell), nên file `.gds` xuất ra dùng minh họa cấu trúc layout chứ không chạy DRC/LVS foundry thực tế.
