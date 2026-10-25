# Design and Verification of a Configurable UART IP Core

[![ci](https://github.com/Srishanth6/Configurable-UART-IP-Core/actions/workflows/ci.yml/badge.svg)](https://github.com/Srishanth6/Configurable-UART-IP-Core/actions/workflows/ci.yml)

Verilog UART core with optional auto-baud, SECDED, low-power and line-monitor features, verified with self-checking testbenches and SVA in Verilator and synthesized with Yosys and nextpnr-ice40. All numbers are copied from the logs in [`logs/`](logs). The full write-up is in [report/UART_IP_Core_Report.pdf](report/UART_IP_Core_Report.pdf).

## 1. Title of Problem

Design and verification of a configurable UART IP core in Verilog, with optional auto-baud, SECDED error correction, a low-power mode and a line-quality monitor, checked with SVA assertions and compared by Yosys/nextpnr synthesis.

## 2. Real-Life Application

Almost every microcontroller, FPGA board, GPS module and Bluetooth module has a UART, and it is usually the first link used to talk to a board (debug console, bootloader, sensor data). In practice the link has problems that a minimal UART does not handle: the two sides may not know each other's baud rate, long or noisy cables flip bits, a battery-powered device wastes power while the line sits idle, and there is no easy way to see that a link is getting worse before bytes are lost. This project builds a UART core where each of these problems is handled by a feature that can be switched on with a parameter, so a small design does not pay for features it does not use.

## 3. Problem Statement

Design a UART transmitter and receiver in synthesizable Verilog with a runtime-programmable baud rate and none/even/odd parity, and add four optional features: auto-baud detection from a 0x55 sync character (`AUTOBAUD_EN`), Hamming SECDED(13,8) protection (`ECC_EN`), clock-enable based low-power idle (`LOWPWR_EN`) and a line-quality monitor (`LINEMON_EN`). The core has to be verified with self-checking testbenches and SVA assertions, the assertions themselves have to be shown to fail on injected bugs, and the cost of each feature has to be measured with synthesis. There is no FPGA board in this project, so all results come from simulation and synthesis tools, and every number in this report is copied from a log in `logs/`.

## 4. Engineering Constraints

- **Frame format:** 1 start bit, 8 data bits (LSB first), optional parity bit, 1 stop bit; line idles high.
- **Clock and baud:** tested at 50, 100 and 133.3 MHz system clock and 2400 to 921600 baud. The tick is 16x the baud rate, so `divisor = f_clk / (16 * baud)`; divisors 1 to 65535 were tested (`DIV_W=16`).
- **Baud tolerance:** the receiver has to accept ±2% and ±3% baud mismatch with no bad frames (measured: 0 bad frames in 500 frames each, all three seeds).
- **Asynchronous input:** `rx` is not synchronous to `clk`, so it needs a synchronizer before any logic.
- **Area:** a disabled feature must not be synthesized at all.
- **Timing:** no fixed Fmax target was given. Fmax is reported from nextpnr-ice40 for iCE40 HX8K as an estimate.
- **Accuracy requirement:** every self-checking test must end with 0 errors, and every injected bug must be caught by an assertion.
- **Hardware/software limitation:** no FPGA board, so there is no hardware test. Verilator tests ran on Linux (the box and GitHub Actions, Ubuntu 24.04); the Icarus tests and GTKWave were also run on my Windows 11 laptop. No ASIC cell library, so no real area or power numbers.

## 5. RTL / Verification Concepts Required

☑ Finite state machines (TX, RX, auto-baud)  
☑ 16x oversampling and mid-bit sampling  
☑ Two-flop synchronizer for an asynchronous input  
☑ Parity and Hamming SECDED coding  
☑ Clock-enable based low-power design  
☑ Parameterized RTL with generate blocks  
☑ Self-checking testbenches with a scoreboard  
☑ Seeded randomized stimulus  
☑ SystemVerilog Assertions (SVA), including negative tests  
☑ Logic synthesis and FPGA place and route  
☐ Formal verification  
☐ Functional coverage (covergroups)  
☐ Gate-level simulation  
☐ Other: __________

## 6. Proposed Architecture

Input → Synchronization → Oversampling → FSM → Output

Implemented chain: `tx_start`/`tx_data` → [optional SECDED encoder, two frames] → TX baud generator + TX FSM → `tx` line → `rx` line → 2-flop synchronizer → [optional auto-baud measures 0x55 and sets the divisor] → RX baud generator + RX FSM (mid-bit sampling) → [optional SECDED decoder] → `rx_data`/`rx_valid`, `parity_err`, `frame_err`, with the optional line monitor watching the RX outputs.

![Block diagram](report/figs/block.png)

*Figure 1: Top-level block diagram of `uart_core` (generated with Graphviz from report/figs/block.dot).*

The TX and RX have separate baud generators. This lets the low-power mode stop one without the other, and it lets the receiver re-phase its counter on every start bit. Each optional block sits in a `generate if (X != 0)` section, so a disabled feature is not elaborated.

![UART frame](report/figs/frame.png)

*Figure 2: Frame format (0xA5, 8E1) with the mid-bit sample points used by my receiver.*

### 6.1 Features and parameters

**Core**
- 16x oversampling baud generator with a runtime-programmable divisor (`DIV_W` bits)
- TX with no, even or odd parity, plus `tx_busy` and a `tx_done` pulse
- RX with a 2-flop synchronizer, mid-bit sampling, start-bit glitch rejection, `parity_err`, `frame_err` and a one-cycle `rx_valid`

**Optional features** (`*_EN` parameters; a disabled feature is not synthesized at all)

| Parameter | Feature |
|---|---|
| `AUTOBAUD_EN` | Auto-baud. Measures 8 bit-times of a 0x55 sync character and sets the divisor to `(T+64)>>7` |
| `ECC_EN` | Hamming SECDED(13,8) sent over two frames. Corrects 1-bit errors and detects 2-bit errors |
| `LOWPWR_EN` | Clock-enable gating of the baud counters, waking on the start edge |
| `LINEMON_EN` | Line-quality monitor: error counters, bit-timing drift (1/16 bit), health score 0-100 |

#### Parameters and ports (`uart_core`)

| Parameter | Default | Range / meaning |
|---|---|---|
| `DIV_W` | 16 | divisor width; tested 8 and 16 (synthesis), divisor 1..65535 in sim (`make edge`) |
| `PARITY_SUPPORT` | 1 | 0 removes parity logic (`parity_mode` ignored) |
| `AUTOBAUD_EN`, `ECC_EN`, `LOWPWR_EN`, `LINEMON_EN` | 0 | 1 enables the feature |

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | clock, async active-low reset |
| `divisor` | in | `DIV_W` | clocks per 1/16 bit = f_clk/(16*baud), must be >= 1 (checked by SVA B4) |
| `parity_mode` | in | 2 | 00 none, 01 even, 10 odd, 11 none |
| `tx_start`, `tx_data` | in | 1, 8 | byte accepted when `tx_start` and TX idle |
| `tx`, `tx_busy`, `tx_done` | out | 1 | serial out (idle high), frame in progress, 1-clock end pulse |
| `rx` | in | 1 | serial in (2-flop synchronised) |
| `rx_data`, `rx_valid`, `parity_err`, `frame_err` | out | 8,1,1,1 | received byte, 1-clock pulses |
| `abd_start` / `abd_busy`, `abd_locked`, `abd_err` | in / out | 1 | auto-baud control/status |
| `div_active` | out | `DIV_W` | divisor in use (auto-baud result once locked) |
| `ecc_corr`, `ecc_uncorr` | out | 1 | SECDED corrected / uncorrectable flags |
| `mon_clr` / `mon_frames`, `mon_parity`, `mon_framing`, `mon_corr`, `mon_uncorr` | in / out | 1 / 16 | line-monitor clear and counters |
| `mon_drift_last`, `mon_drift_max`, `mon_health` | out | 5 (signed), 4, 7 | bit-edge drift (1/16 bit) and health 0-100 |

## 7. Design/Algorithm

- **Baud generator:** counter from 0 to `divisor-1` giving a 16x tick; `clr` re-phases it on a start edge, `en` freezes it in low-power mode.
- **TX:** IDLE, START, DATA, PAR, STOP; 16 ticks per bit; byte and parity mode latched on `tx_start`.
- **RX:** 2-flop synchronizer, start bit re-checked 8 ticks after the falling edge (glitch rejection), then one sample every 16 ticks at mid-bit; `frame_err` goes to BREAK until the line returns high.
- **Auto-baud:** counts clocks T from the 1st to the 5th falling edge of 0x55 (8 bit-times) and sets `divisor = (T + 64) >> 7`.
- **SECDED(13,8):** Hamming code plus overall parity, sent as two frames; corrects 1-bit and detects 2-bit errors.
- **Low power:** flop enables on the baud counters, RX wakes on the synchronized low level.
- **Line monitor:** saturating error counters, edge drift in 1/16 bit, health score 0-100 every 32 frames.

![TX FSM](report/figs/fsm_tx.png)

![RX FSM](report/figs/fsm_rx.png)

![Auto-baud FSM](report/figs/fsm_abd.png)

## 8. Implementation Tool

Verilog / SystemVerilog / FPGA / Other

Selected: Verilog-2005 RTL and SystemVerilog testbenches and assertions. Icarus Verilog 12 for the small directed tests (`tb_baud`, `tb_loopback`, `tb_power`); Verilator 5.032 with `--assert` for the randomized, feature and edge-case testbenches and all SVA; Yosys 0.52 for generic and iCE40 synthesis; nextpnr-ice40 for place and route and the Fmax estimate; GTKWave 3.3.121 for viewing waveforms; Python/matplotlib for plots and the toggle counter. Everything runs from the `Makefile` (`make all`), and GitHub Actions runs the same targets on every push.

### Run on Linux / macOS

Requirements: Verilator 5.032 (the version all logs were made with), Icarus Verilog 12, Yosys 0.5x, Python 3 with matplotlib and python-docx, Graphviz, and LibreOffice (only for the PDF). nextpnr-ice40 is optional (Fmax column).

Every target creates `build/`, `logs/` and `waves/` itself, so a fresh clone works with `make all`. If your `python3` has no matplotlib, use `make all PYTHON=/path/to/python3`.

```bash
make baud loopback        # iverilog tests
make rand rand_feat       # randomized TB (SEEDS="1 42 2026" by default)
make neg                  # injected-bug tests; the assertions must fire
make features             # auto-baud / ECC / monitor at 3 clocks
make power                # VCD toggle-count proxy
make edge                 # divisor limits, reset in every state, parity codes, bad frames
make waves_err            # traced run -> TX/RX, parity and framing error plots
make bug_demo             # injected RXMID bug, B2 must fire; writes waves/tb_edge_bug_rxmid.vcd
make gtkwave_shots        # GTKWave screenshots -> report/figs/gtkwave_*.png (needs X / xvfb-run)
make synth                # Yosys + nextpnr table -> logs/synth_summary.log
make all                  # everything above except report
make report               # figures + PDF
```

CI (`.github/workflows/ci.yml`) installs the tools on Ubuntu 24.04 and runs the same targets on every push. Ubuntu 24.04's apt Verilator is 5.020, so CI builds Verilator v5.032 from source once, caches it, and fails if `verilator --version` is not 5.032.

### Run on Windows

1. Install Icarus Verilog (which includes GTKWave) and make sure `iverilog`, `vvp` and `gtkwave` are on PATH.
2. From the repository root (Command Prompt or PowerShell):

   ```bat
   mkdir build logs
   iverilog -g2012 -o build/tb_loopback tb/tb_loopback.v rtl/*.v
   vvp -n build/tb_loopback
   gtkwave waves/tb_loopback.vcd waves/loopback.gtkw

   iverilog -g2012 -P tb_power.LP=1 -o build/tbp1 tb/tb_power.v rtl/*.v
   vvp -n build/tbp1
   gtkwave waves/power_lp1.vcd waves/lowpower.gtkw

   iverilog -g2012 -o build/tb_baud tb/tb_baud.v rtl/*.v
   vvp -n build/tb_baud
   ```

The loopback run should print `LOOPBACK_TEST frames_checked=772 pass=772 fail=0 -> PASS`. The Verilator testbenches (`tb_uart_rand`, `tb_features`, `tb_edge`) and the SVA files need Verilator 5.032 and the Makefile, so run them on Linux or WSL. Saved VCDs from those runs (for example `waves/tb_edge_bug_rxmid.vcd`) can still be opened in GTKWave on Windows.

## 9. Results

![Testbench architecture](report/figs/tb_arch.png)

| Test | Result | Log |
|---|---|---|
| Baud generator tick period (divisors 4/27/163/326, plus clr) | 201 checks, 0 errors | `logs/baud_gen.log` |
| Loopback: 256 bytes × none/even/odd parity | **772/772 PASS** | `logs/loopback.log` |
| Random TB, seeds 1, 42, 2026 (base config) | **12/12 groups PASS** for each seed | `logs/rand_seed*.log` |
| Random TB, same seeds, `LOWPWR_EN=1 LINEMON_EN=1` | **12/12 PASS** for each seed | `logs/rand_lp_mon_seed*.log` |
| Feature TB, 3 seeds × 50/100/133.3 MHz | **9/9 runs PASS** | `logs/features_seed*_clk*.log` |
| Edge cases, divisor = 1, 2, 3, 16, 255 (full set) and 65535 (back-to-back only) | **6/6 runs PASS** | `logs/edge_div*.log` |
| Negative tests (4 injected bugs) | **All 4 caught by SVA**, exit code 134 | `logs/negative_tests.log` |

Edge-case testbench `tb/tb_edge.sv` (added after review), groups per run:
- E1 divisor boundary values: 1, 2, 3, 16, 255, 65535 (the 16-bit maximum);
- E2 reset asserted in every TX state (START, DATA, PARITY, STOP), then a good frame must follow;
- E3 reset asserted in every RX state (START, DATA, PARITY, STOP, BREAK), no byte may come out, then recovery;
- E4 back-to-back frames (`tx_start` held) in all four `parity_mode` codes 00/01/10/11;
- E5 malformed frames: start glitches of 1 clock up to just under half a bit (rejected), bad stop bit in all four parity codes (`frame_err`, no `rx_valid`), wrong parity bit for even and odd.

#### Assertions

 `sva/uart_sva.sv` has A1-A12 (TX idle/frame length/done/start bit, RX pulses and error flags, low-power, ECC, auto-baud, monitor). `sva/uart_sva_ext.sv` adds:
- **B1** baud timing: every tick comes exactly `divisor` clocks after the previous one (B1b: never later);
- **B2** RX mid-bit sampling: start bit sampled 8 ticks after detection, data bit n at 8+16(n+1) ticks;
- **B3** reset: TX/RX FSMs idle, `tx`=1 and no `rx_valid`/`parity_err`/`frame_err` while reset is held and at release;
- **B4** parameter/divisor boundaries: `DIV_W` in 1..32 at elaboration, `divisor != 0` at run time.

Antecedent hit counts are printed in every log (e.g. DIV=16: B1 29,873, B2 start 160, B2 data 1,240, B3 13 reset cycles).

The random TB (seed 1) covers:
- 3000 random frames;
- 500 back-to-back frames;
- parity and stop-bit error injection;
- ±2% and ±3% baud mismatch with 0 bad frames;
- ±8% baud mismatch, where 281 and 278 of 300 frames had errors, as expected;
- start-bit glitch rejection;
- 50 resets in the middle of a frame.

#### Injected-bug (negative) tests
- `+define+INJECT_BUG` stretches `rx_valid` to 2 cycles. It was caught by **A5** at 69.55 µs.
- `+define+INJECT_BUG_TX` makes the stop bit one tick short. It was caught by **A2**: "tx_busy length 2544, expected 2560".
- `+define+INJECT_BUG_BAUD` makes the baud counter off by one. It was caught by **B1b** at 330 ns: "no baud tick for 5 clocks (divisor=4)".
- `+define+INJECT_BUG_RXMID` starts RX sampling 3/16 bit late. It was caught by **B2** at 1.11 µs: "start bit sampled at tick 11, expected 8".

### Waveforms

#### Waveforms (from `waves/tb_loopback.vcd`)
![Loopback](report/figs/wave_loopback.png)
![Start bit zoom](report/figs/wave_zoom.png)

#### Error waveforms (from `waves/tb_edge_err.vcd`, `make waves_err`, DIV=4)
![TX/RX timing](report/figs/wave_txrx_timing.png)
![Parity error](report/figs/wave_parity_err.png)
![Framing error](report/figs/wave_frame_err.png)

#### GTKWave screenshots

These are real screenshots of GTKWave 3.3.121 with the saved VCDs open, not plots. Each view has a save file in `waves/` (signals, hex radix for buses, zoom and marker), so it can be reopened with `gtkwave <vcd> <gtkw>`. `make gtkwave_shots` regenerates the VCDs and the screenshots (it needs an X display, or run it under `xvfb-run`). `waves/tb_edge_err.vcd` is not committed (8.7 MB); `make waves_err` recreates it.

| View | Open with | Window, marker |
|---|---|---|
| TX/RX loopback | `gtkwave waves/tb_loopback.vcd waves/loopback.gtkw` | 0-27 µs, marker 12.39 µs (first rx_valid) |
| Parity error | `gtkwave waves/tb_edge_err.vcd waves/parity_err.gtkw` | 832.51-865.80 µs, marker 846.05 µs (parity_err with rx_valid, rx_data=96) |
| Framing error | `gtkwave waves/tb_edge_err.vcd waves/frame_err.gtkw` | 642.91-663.40 µs, marker 655.17 µs (frame_err, no rx_valid) |
| Low power (LOWPWR_EN=1) | `gtkwave waves/power_lp1.vcd.gz waves/lowpower.gtkw` | 0-2.2 ms, marker 1995.98 µs (next frame starts) |
| Injected bug RXMID | `gtkwave waves/tb_edge_bug_rxmid.vcd waves/bug_rxmid.gtkw` | 0-1.12 µs, marker 1.10 µs |

The injected-bug run (`make bug_demo`, `logs/bug_demo.log`) stops at 1.11 µs with *"B2 start bit sampled at tick 11, expected 8"*. The VCD's last dumped time is 1.10 µs, so the marker is placed there. In the screenshot, `rx_tcnt` is loaded with 5 instead of 8 when the start bit is detected (see `rtl/uart_rx.v`), which is the injected bug.

![GTKWave loopback](report/figs/gtkwave_loopback.png)

*Figure G1: GTKWave on Windows 11, TX/RX loopback; simulated with Icarus Verilog 12 on Windows (tb_loopback.vcd).*

![GTKWave parity error](report/figs/gtkwave_parity_err.png)

*Figure G2: GTKWave on Windows 11, parity error (tb_edge_err.vcd, simulated with Verilator 5.032 on Linux).*

![GTKWave framing error](report/figs/gtkwave_frame_err.png)

*Figure G3: GTKWave on Windows 11, framing error (tb_edge_err.vcd, simulated with Verilator 5.032 on Linux).*

![GTKWave low power](report/figs/gtkwave_lowpower.png)

*Figure G4: GTKWave on Windows 11, low-power mode: baud counters stop between frames; simulated with Icarus Verilog 12 on Windows (power_lp1.vcd).*

![Terminal: make bug_demo](report/figs/gtkwave_bug_rxmid_terminal.png)

*Figure G5: terminal running `make bug_demo`; the SVA error from B2.*

![GTKWave injected bug](report/figs/gtkwave_bug_rxmid.png)

*Figure G6: GTKWave on Windows 11 at the B2 failure (tb_edge_bug_rxmid.vcd, simulated with Verilator 5.032 on Linux).*

### Feature results

**Auto-baud.** The test locks on 0x55 and then checks the bytes that follow. The locked divisor is always the nearest integer to the ideal value.

| Clock | Baud | Locked div | Rate error | Bytes OK |
|---|---|---|---|---|
| 50 MHz | 2400 | 1302 | +0.01% | 10/10 |
| 50 MHz | 115200 | 27 | +0.47% | 40/40 |
| 50 MHz | 460800 | 7 | -3.12% | 40/40 |
| 50 MHz | 921600 | 3 | +13.03% | 0/40 (divisor too coarse) |
| 133.3 MHz | 921600 | 9 | +0.47% | 40/40 |

![Auto-baud error](report/figs/autobaud_err.png)

**SECDED.** 1500 random bytes per seed, with random flips on the line.

| Seed | Clean | 1-bit corrected | 2-bit detected | Wrong data |
|---|---|---|---|---|
| 1 | 589/589 | 621/621 | 290/290 | 0 |
| 42 | 606/606 | 602/602 | 292/292 | 0 |
| 2026 | 607/607 | 609/609 | 284/284 | 0 |

**Low power.** VCD toggle count, used only as an activity proxy. This is not a power measurement, and the clock is excluded.

| Config | Idle toggles | Active toggles |
|---|---|---|
| `LOWPWR_EN=0` | 15,206,486 | 802,085 |
| `LOWPWR_EN=1` | 127 | 777,894 |

![Toggles](report/figs/toggles.png)

**Line monitor** (seed 1, 50 MHz)

| Scenario | Framing errors | Max drift (1/16 bit) | Health |
|---|---|---|---|
| Clean | 0 | 1 | 100 |
| +2% baud | 0 | 2 | 100 |
| +3% baud | 0 | 4 | 84 |
| +6% baud | 57 | 7 | 0 |

In the noise test, the monitor counters matched the injected errors exactly (45 parity and 26 framing errors for seed 1).

## 10. Quantitative Performance

| Parameter | Base core (all `*_EN=0`) | All features enabled |
|---|---|---|
| Fmax (nextpnr-ice40, HX8K) | 141.78 MHz | 73.87 MHz |
| iCE40 LUT4 / DFF | 174 / 88 | 585 / 318 |
| Generic cells / logic depth | 889 / 25 gates | 2698 / 31 gates |
| Random TB (3 seeds) | 12/12 groups PASS per seed | 12/12 PASS per seed with `LOWPWR_EN=1 LINEMON_EN=1` |
| Feature TB (auto-baud, ECC, monitor) | – | 9/9 runs PASS (3 seeds × 3 clocks) |
| Injected bugs caught by SVA | 4/4 | not run separately |

| Parameter | `LOWPWR_EN=0` | `LOWPWR_EN=1` |
|---|---|---|
| Idle toggles (VCD, clock excluded) | 15,206,486 | 127 |
| Active toggles | 802,085 | 777,894 |
| Bytes received | 40/40 | 40/40 |

Both configurations use `DIV_W=16` and parity support. Synthesis numbers are from `logs/synth_summary.log`. The negative tests ran on the testbenches' default (base) configuration. Toggle counts are an activity proxy, not a power measurement. Loopback (772/772) and the edge-case runs (6/6) were done on the base core.

### 10.1 Synthesis per feature

All feature configs use `DIV_W=16 PARITY_SUPPORT=1`, so each row differs from *Base, DIV_W=16* only by the feature(s) named.

| Config | Generic cells | Generic flops | Logic depth (gates) | iCE40 LUT4 | iCE40 DFF | Fmax (MHz, nextpnr) |
|---|---|---|---|---|---|---|
| Base, `DIV_W=16` | 889 | 88 | 25 | 174 | 88 | 141.78 |
| Base, `DIV_W=8` | 621 | 72 | 17 | 116 | 72 | 142.78 |
| Base, no parity | 809 | 82 | 25 | 167 | 82 | 124.60 |
| + auto-baud | 1327 | 139 | 31 | 286 | 139 | 73.92 |
| + ECC | 1426 | 151 | 28 | 271 | 151 | 128.52 |
| + low power | 814 | 88 | 28 | 198 | 88 | 126.25 |
| + line monitor | 1532 | 172 | 27 | 311 | 172 | 75.71 |
| All features | 2698 | 318 | 31 | 585 | 318 | 73.87 |

What each column is:
- **Generic cells / flops**: Yosys `synth -flatten; abc -g cmos2` internal gates. Not a real cell library, no area.
- **Logic depth**: longest combinational path counted in gates (`ltp -noff`). It is not a delay.
- **iCE40 LUT4 / DFF**: `synth_ice40` technology mapping.
- **Fmax**: nextpnr-ice40 post-place-and-route estimate for iCE40 HX8K (ct256), seed 1, I/O pins unconstrained. It is the only real timing number; no ASIC STA was done. If nextpnr is not installed the script prints `not_measured`.
- The ECC, line-monitor and all-features rows changed slightly from the first version (e.g. all features 2720 -> 2698 cells, ECC 276 -> 271 LUT4) after setting `DIV_W`/`PARITY_SUPPORT` explicitly with `chparam`; this table is the current `logs/synth_summary.log`. The report (md/docx/pdf) was regenerated with these numbers.

![LUTs](report/figs/synth_luts.png)

#### Interpretation

- The base core (`DIV_W=16`) maps to 174 LUT4 and 88 DFF on iCE40, with a nextpnr estimate of 141.78 MHz.
- Narrowing the divisor to `DIV_W=8` cuts generic cells from 889 to 621 and logic depth from 25 to 17 gates.
- Auto-baud and the line monitor are the most expensive features (286 and 311 LUT4) and lower the Fmax estimate to 73.92 and 75.71 MHz.
- With all features enabled the core uses 585 LUT4 and 318 DFF, with an Fmax estimate of 73.87 MHz.
- Cell counts and logic depth are generic Yosys statistics, not area or delay. Only the Fmax column is a timing number, and it is a place-and-route estimate.

## 11. Engineering Justification

**16x oversampling with mid-bit sampling.** Sampling once per bit at the middle gives about ±50% of a bit of margin, which is enough for the ±2-3% mismatch I tested. 16 ticks per bit lets the receiver find the middle within 1/16 bit and also gives the drift measurement used by the line monitor. A lower ratio (for example 8x) would make the counters smaller but would give coarser drift and less glitch rejection.

**Separate TX and RX baud generators.** One shared generator would be smaller, but the RX needs to re-phase its counter on every start edge, and the low-power mode needs to stop each side on its own.

**Parameters with generate blocks instead of always-on features.** The synthesis table shows why: all features together cost 585 LUT4 against 174 for the base core, and the Fmax estimate drops from 141.78 to 73.87 MHz. A user who only needs a plain UART should not pay for that.

**Auto-baud over 8 bit-times.** Measuring the 1st to 5th falling edge of 0x55 (128 ticks) instead of a single bit averages out the ±1 clock synchronizer jitter. The locked divisor was the nearest integer to the ideal value at all 24 baud/clock points.

**SECDED over two frames.** Keeping the 8-bit frame means the line stays a normal UART. The cost is half the throughput, which is acceptable for the noisy-line case this feature is for.

**Clock enables instead of gating the clock.** Gating the clock in RTL is unsafe on an FPGA. Using flop enables is safe and drops idle toggles from 15,206,486 to 127 in my test.

**Verilator for SVA, Icarus for small tests.** Verilator 5.032 runs the concurrent assertions with `--assert` and is fast enough for the long randomized runs. Icarus is kept for the simple tests because it also runs on Windows, so those can be checked on my laptop.

**Negative tests.** An assertion that never fails proves nothing. Each of the four injected bugs was caught by a different assertion (A5, A2, B1b, B2), which shows they are actually evaluated.

## 12. Limitations

- Only 8 data bits and 1 stop bit are supported, with no FIFO and no RTS/CTS flow control.
- Auto-baud needs exactly 0x55 as 8N1, and its accuracy is limited by integer divisors at high baud/clock ratios: 0/40 bytes at 921600 baud with a 50 MHz clock.
- ECC halves the throughput (two frames per byte), and pairing depends on a timeout, so a lost frame can drop a byte. That is reported as `dropped`, not corrected.
- The power result is a toggle count from RTL simulation only. It is not a power estimate.
- Fmax is a nextpnr estimate with unconstrained pins, not a board result.
- All verification is simulation. There was no formal verification, no gate-level simulation and no FPGA hardware test. Coverage is measured as test-case counts and assertion hit counts, not as tool-collected functional coverage.
- The health score formula is my own heuristic.

## 13. Proposed Improvement

- TX/RX FIFOs and a bus wrapper (APB or Wishbone).
- Fractional baud divisor, to fix the high-baud quantization problem.
- Formal proofs of the SVA with SymbiYosys.
- An FPGA demo on an iCE40 board.
- Proper functional covergroups.

## 14. Conclusion

A configurable UART core was written in Verilog and verified in simulation. The logs show 772/772 loopback bytes across three parity modes, 12/12 random test groups for three seeds in two configurations, 6/6 edge-case runs (divisor 1 to 65535, reset in every TX/RX state, malformed frames), auto-baud locking to the nearest divisor at every point tested, SECDED correcting every single flip and detecting every double flip, and line-monitor counters that matched the injected errors exactly. The assertions caught all four injected bugs. The low-power mode cut idle switching activity from 15,206,486 to 127 toggles. With every feature enabled the core takes 585 iCE40 LUT4 and reaches an estimated 73.87 MHz on iCE40 HX8K, compared with 174 LUT4 and 141.78 MHz for the base core. These results are from simulation and synthesis only; the core has not been tested on hardware.

## Project Structure

```text
Configurable-UART-IP-Core/
├── .github/workflows/ci.yml   # GitHub Actions: builds Verilator 5.032, runs make all
├── rtl/                       # Verilog design (uart_core.v is the top)
│   ├── uart_core.v
│   ├── uart_baud_gen.v
│   ├── uart_tx.v
│   ├── uart_rx.v
│   ├── uart_autobaud.v
│   ├── uart_ecc_tx.v / uart_ecc_rx.v
│   ├── uart_secded_enc.v / uart_secded_dec.v
│   └── uart_linemon.v
├── sva/
│   ├── uart_sva.sv            # A1-A12
│   └── uart_sva_ext.sv        # B1-B4
├── tb/
│   ├── tb_baud.v, tb_loopback.v, tb_power.v          # Icarus Verilog
│   └── tb_uart_rand.sv, tb_features.sv, tb_edge.sv   # Verilator
├── scripts/                   # vbuild.sh, neg_tests.sh, synth_all.sh, vcd_toggles.py, err_waves.py, gtkwave_shots.sh
├── waves/                     # small VCDs and GTKWave save files (*.gtkw)
├── syn/out/                   # Yosys stats per configuration
├── logs/                      # every log the results come from
├── report/                    # report (.md/.docx/.pdf), figures and generator scripts
├── Makefile
└── README.md
```

## Resume / LinkedIn Description

Designed a configurable UART IP core in Verilog with a 16x oversampling baud generator, parity, and optional auto-baud, Hamming SECDED, low-power and line-monitor features. Verified it with self-checking randomized SystemVerilog testbenches and SVA assertions in Verilator, including injected-bug tests, and compared feature cost with Yosys and nextpnr-ice40 synthesis.

## License

Student project for educational and portfolio demonstration. No licence specified.
