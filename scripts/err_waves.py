#!/usr/bin/env python3
"""Plot TX/RX timing, parity-error and framing-error windows from
waves/tb_edge_err.vcd (made by `make waves_err`). Window start times are
read from the MARK lines in logs/edge_waves.log, so nothing is hand-picked."""
import re, sys, os
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
TOP = os.path.dirname(os.path.abspath(__file__)) + "/.."
VCD, LOG, OUT = f"{TOP}/waves/tb_edge_err.vcd", f"{TOP}/logs/edge_waves.log", f"{TOP}/report/figs"
SIGS = ["clk", "line", "dut_tx", "rx_valid", "parity_err", "frame_err", "tx_busy", "pmode"]

def read_vcd(path):
    ids, data, t, scale = {}, {}, 0, 1.0
    with open(path) as f:
        txt = f.read()
    m = re.search(r"\$timescale\s+(\d+)\s*(\w+)", txt)
    if m: scale = int(m.group(1)) * {"s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9, "ps": 1e-12, "fs": 1e-15}[m.group(2)]
    for m in re.finditer(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)", txt):
        if m.group(3) in SIGS and m.group(2) not in ids: ids[m.group(2)] = m.group(3)
    body = txt[txt.find("$enddefinitions"):]
    for ln in body.splitlines():
        if not ln: continue
        if ln[0] == "#": t = int(ln[1:]) * scale; continue
        if ln[0] in "01xz" and ln[1:] in ids: data.setdefault(ids[ln[1:]], []).append((t, ln[0]))
        elif ln[0] == "b":
            v, i = ln[1:].split()
            if i in ids: data.setdefault(ids[i], []).append((t, v))
    return data

def plot(data, t0, t1, title, out, sigs):
    fig, axs = plt.subplots(len(sigs), 1, figsize=(11, 0.75 * len(sigs) + 0.8), sharex=True)
    for ax, s in zip(axs, sigs):
        pts = data.get(s, [])
        xs, ys, last = [], [], None
        for t, v in pts:
            try: val = int(v, 2)
            except ValueError: val = 0
            if t < t0: last = val; continue
            if t > t1: break
            if last is not None: xs += [t * 1e6]; ys += [last]
            xs += [t * 1e6]; ys += [val]; last = val
        xs = [t0 * 1e6] + xs + [t1 * 1e6]; ys = [ys[0] if ys else (last or 0)] + ys + [last or 0]
        ax.step(xs, ys, where="post"); ax.set_ylabel(s, rotation=0, ha="right", fontsize=8); ax.set_yticks([])
    axs[-1].set_xlabel("time (us, from tb_edge_err.vcd)"); fig.suptitle(title, fontsize=10)
    fig.tight_layout(); fig.savefig(out, dpi=110); plt.close(fig); print("wrote", out)

marks = {m.group(1): int(m.group(2)) * 1e-12 for m in re.finditer(r"MARK (\S+) (\d+)", open(LOG).read())}
div = int(re.search(r"DIV=(\d+)", open(LOG).read()).group(1))
bit = 20e-9 * 16 * div
d = read_vcd(VCD)
S = ["line", "rx_valid", "parity_err", "frame_err"]
plot(d, marks["E5c_mode1"], marks["E5c_mode1"] + 26 * bit, f"Parity error: 0x96 with wrong even-parity bit, then good 0x97 (DIV={div}, 1 bit={bit*1e9:.0f} ns)", f"{OUT}/wave_parity_err.png", S)
plot(d, marks["E5b_mode0"], marks["E5b_mode0"] + 16 * bit, f"Framing error: 0xC9 with stop bit = 0, line held low (DIV={div})", f"{OUT}/wave_frame_err.png", S)
# TX/RX timing: first back-to-back frames (tx_start held) at the very start
plot(d, 0, 24 * bit, f"TX/RX timing: back-to-back 8N1 frames, DUT tx looped to rx (DIV={div})", f"{OUT}/wave_txrx_timing.png", ["dut_tx", "tx_busy", "line", "rx_valid"])
