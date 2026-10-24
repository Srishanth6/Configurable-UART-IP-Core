# Configurable UART IP Core

A UART IP core in Verilog that I wrote from scratch, with full verification:
self-checking randomized SystemVerilog testbenches, SVA assertions that run in
Verilator and include negative tests, and Yosys synthesis. Four optional features
are enabled through parameters. All results below are copied from the logs in
[`logs/`](logs).

📄 **Full report:** [report/UART_IP_Core_Report.pdf](report/UART_IP_Core_Report.pdf)

## Features

**Core**
- 16x oversampling baud generator with a runtime-programmable divisor (`DIV_W` bits)
- TX with no, even or odd parity, plus `tx_busy` and a `tx_done` pulse
- RX with a 2-flop synchronizer, mid-bit sampling, start-bit glitch rejection,
  `parity_err`, `frame_err` and a one-cycle `rx_valid`

**Optional features** (`*_EN` parameters; a disabled feature is not synthesized at all)

| Parameter | Feature |
|---|---|
| `AUTOBAUD_EN` | Auto-baud. Measures 8 bit-times of a 0x55 sync character and sets the divisor to `(T+64)>>7` |
| `ECC_EN` | Hamming SECDED(13,8) sent over two frames. Corrects 1-bit errors and detects 2-bit errors |
| `LOWPWR_EN` | Clock-enable gating of the baud counters, waking on the start edge |
| `LINEMON_EN` | Line-quality monitor: error counters, bit-timing drift (1/16 bit), health score 0-100 |

## Architecture

![Block diagram](report/figs/block.png)

![UART frame](report/figs/frame.png)

### TX FSM
![TX FSM](report/figs/fsm_tx.png)

### RX FSM
![RX FSM](report/figs/fsm_rx.png)

### Auto-baud FSM
![Auto-baud FSM](report/figs/fsm_abd.png)

## Verification

![Testbench architecture](report/figs/tb_arch.png)

| Test | Result | Log |
|---|---|---|
| Baud generator tick period (divisors 4/27/163/326, plus clr) | 201 checks, 0 errors | `logs/baud_gen.log` |
| Loopback: 256 bytes × none/even/odd parity | **772/772 PASS** | `logs/loopback.log` |
| Random TB, seeds 1, 42, 2026 (base config) | **12/12 groups PASS** for each seed | `logs/rand_seed*.log` |
| Random TB, same seeds, `LOWPWR_EN=1 LINEMON_EN=1` | **12/12 PASS** for each seed | `logs/rand_lp_mon_seed*.log` |
| Feature TB, 3 seeds × 50/100/133.3 MHz | **9/9 runs PASS** | `logs/features_seed*_clk*.log` |
| Negative tests (injected bugs) | Both caught by SVA, exit code 134 | `logs/negative_tests.log` |

The random TB (seed 1) covers:
- 3000 random frames;
- 500 back-to-back frames;
- parity and stop-bit error injection;
- ±2% and ±3% baud mismatch with 0 bad frames;
- ±8% baud mismatch, where 281 and 278 of 300 frames had errors, as expected;
- start-bit glitch rejection;
- 50 resets in the middle of a frame.

**Negative assertion tests**
- `+define+INJECT_BUG` stretches `rx_valid` to 2 cycles. It was caught by **A5** at 69.55 µs.
- `+define+INJECT_BUG_TX` makes the stop bit one tick short. It was caught by **A2**: "tx_busy length 2544, expected 2560".

### Waveforms (from `waves/tb_loopback.vcd`)
![Loopback](report/figs/wave_loopback.png)
![Start bit zoom](report/figs/wave_zoom.png)

## Feature results

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

## Synthesis (Yosys 0.52)

| Config | Generic cells | Flops | Logic depth | iCE40 LUT4 |
|---|---|---|---|---|
| Base, `DIV_W=16` | 889 | 88 | 25 | 174 |
| Base, `DIV_W=8` | 621 | 72 | 17 | 116 |
| Base, no parity | 809 | 82 | 25 | 167 |
| + auto-baud | 1327 | 139 | 31 | 286 |
| + ECC | 1426 | 151 | 28 | 276 |
| + low power | 814 | 88 | 28 | 198 |
| + line monitor | 1507 | 172 | 28 | 311 |
| All features | 2720 | 318 | 31 | 591 |

Notes on the table:
- The generic flow is `synth; abc -g cmos2`, and logic depth comes from `ltp -noff`.
- No timing library or STA was used.

![LUTs](report/figs/synth_luts.png)

## How to run

Requirements: Verilator 5.x, Icarus Verilog 12, Yosys 0.5x, Python 3 with matplotlib and
python-docx, Graphviz, and LibreOffice (the last one only for the PDF).

```bash
make baud loopback        # iverilog tests
make rand rand_feat       # randomized TB (SEEDS="1 42 2026" by default)
make neg                  # injected-bug tests; the assertions must fire
make features             # auto-baud / ECC / monitor at 3 clocks
make power                # VCD toggle-count proxy
make synth                # Yosys table -> logs/synth_summary.log
make report               # figures + PDF
```

## Folder structure

```
rtl/      Verilog design (uart_core.v is the top)
sva/      SystemVerilog assertions A1-A12
tb/       testbenches (tb_baud, tb_loopback, tb_power: iverilog; tb_uart_rand, tb_features: Verilator)
scripts/  vbuild.sh, neg_tests.sh, synth_all.sh, vcd_toggles.py
logs/     every log the results above come from
waves/    small VCDs (tb_baud, tb_loopback); power VCDs are regenerated by `make power`
syn/out/  Yosys stats per configuration
report/   report source (.md/.docx), PDF, figures and their generator scripts
```

## Limitations

- Supports 8 data bits and 1 stop bit only, with no FIFO or flow control.
- Auto-baud accuracy is limited by the integer divisor at high baud-to-clock ratios.
- ECC halves the throughput, and a lost frame drops the byte (it is flagged, not recovered).
- The power numbers are an RTL toggle-count proxy, not a real power estimate.
- Verification is simulation only: no formal proofs, gate-level simulation or hardware test.
- The health score formula is my own heuristic.
