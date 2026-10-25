#!/usr/bin/env python3
"""Generate all report figures from real data (VCDs, logs, synth stats)."""
import re, glob, gzip, subprocess, os
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
R = os.path.dirname(os.path.abspath(__file__)); TOP = os.path.dirname(R)
F = os.path.join(R, "figs"); os.makedirs(F, exist_ok=True)

def dot(name, src):
    open(f"{F}/{name}.dot", "w").write(src)
    subprocess.run(["dot", "-Tpng", "-Gdpi=150", f"{F}/{name}.dot", "-o", f"{F}/{name}.png"], check=True)

# ---------------- graphviz diagrams ----------------
dot("block", r'''digraph G { rankdir=LR; node[shape=box,style="rounded,filled",fillcolor="#eef3fb",fontname=Helvetica];
 subgraph cluster_core { label="uart_core"; style=dashed;
  bgt[label="uart_baud_gen\n(TX, 16x tick)"]; bgr[label="uart_baud_gen\n(RX, 16x tick)"];
  tx[label="uart_tx FSM"]; rx[label="uart_rx FSM\n2-FF sync + mid-bit"];
  ecct[label="uart_ecc_tx\n(SECDED enc, 2 frames)",fillcolor="#fdf2e0"]; eccr[label="uart_ecc_rx\n(pair + SECDED dec)",fillcolor="#fdf2e0"];
  abd[label="uart_autobaud\n(0x55 measure)",fillcolor="#fdf2e0"]; mon[label="uart_linemon\ncounters/drift/health",fillcolor="#fdf2e0"];
  mux[label="divisor\nselect",shape=diamond];
 }
 host[label="host / bus",shape=plaintext]; line_out[label="tx pin",shape=plaintext]; line_in[label="rx pin",shape=plaintext];
 host->ecct[label="tx_data, tx_start"]; ecct->tx; tx->line_out; bgt->tx[label="tick"];
 line_in->rx; line_in->abd; bgr->rx[label="tick"]; rx->eccr; eccr->host[label="rx_data, rx_valid,\nerrors"];
 abd->mux[label="div_out"]; host->mux[label="divisor"]; mux->bgt; mux->bgr;
 rx->mon[label="valid/errs/drift"]; eccr->mon[label="corr/uncorr"]; mon->host[label="mon_*"];
 note[shape=note,label="orange = optional (parameter-enabled)",fillcolor=white];
}''')
dot("fsm_tx", r'''digraph T { rankdir=LR; node[shape=circle,fontname=Helvetica,width=0.9];
 IDLE->START[label="tx_start"]; START->DATA[label="16 ticks"]; DATA->DATA[label="bit<7"];
 DATA->PAR[label="8 bits & parity on"]; DATA->STOP[label="8 bits & no parity"]; PAR->STOP[label="16 ticks"];
 STOP->IDLE[label="16 ticks / tx_done"]; }''')
dot("fsm_rx", r'''digraph R { rankdir=LR; node[shape=circle,fontname=Helvetica,width=0.9];
 IDLE->START[label="rx_s=0 (wake)"]; START->IDLE[label="line high at\nmid-start (glitch)"]; START->DATA[label="still low\nat tick 8"];
 DATA->DATA[label="sample @ mid"]; DATA->PAR[label="parity on"]; DATA->STOP[label="no parity"]; PAR->STOP;
 STOP->IDLE[label="stop=1: rx_valid\n(+parity_err)"]; STOP->BREAK[label="stop=0: frame_err"]; BREAK->IDLE[label="line back high"]; }''')
dot("fsm_abd", r'''digraph A { rankdir=LR; node[shape=circle,fontname=Helvetica,width=0.9];
 AB_IDLE->HIGH[label="abd_start"]; HIGH->FALL[label="line idle high"]; FALL->MEAS[label="1st falling edge"];
 MEAS->MEAS[label="count clocks"]; MEAS->POST[label="5th falling edge\ndiv=(T+64)>>7"]; POST->AB_IDLE[label="stop bit seen / locked"];
 MEAS->AB_IDLE[label="overflow: lock_err"]; }''')
dot("tb_arch", r'''digraph B { rankdir=LR; node[shape=box,style="rounded,filled",fillcolor="#eefbef",fontname=Helvetica];
 gen[label="stimulus generator\nxorshift32(+SEED)"]; bfm[label="line BFM\nreal-ns bit timing\n(baud scale, glitches,\nparity/stop corruption)"];
 drv[label="DUT TX driver"]; dut[label="uart_core (DUT)",fillcolor="#eef3fb"]; sb[label="scoreboard\n(expected queue)"];
 sva[label="uart_sva (bind)\nA1..A12",fillcolor="#fbeeee"]; rep[label="report / RESULT line\n$fatal on fail"];
 gen->bfm; gen->drv; bfm->dut[label="rx"]; drv->dut[label="tx_start"]; dut->bfm[label="tx (loopback)"];
 dut->sb[label="rx_data, flags"]; gen->sb[label="expected"]; dut->sva; sb->rep; sva->rep; }''')

# ---------------- UART frame timing diagram ----------------
def frame_plot():
    bits = [1, 0] + [(0xA5 >> i) & 1 for i in range(8)] + [0, 1, 1]  # idle,start,d0..d7,even parity(0xA5 has 4 ones ->0),stop,idle
    labels = ["idle", "start"] + [f"d{i}" for i in range(8)] + ["par", "stop", "idle"]
    fig, ax = plt.subplots(figsize=(10, 2.2))
    xs, ys = [], []
    for i, b in enumerate(bits): xs += [i, i + 1]; ys += [b, b]
    ax.plot(xs, ys, lw=2)
    for i, l in enumerate(labels):
        ax.text(i + 0.5, 1.25, l, ha="center", fontsize=8); ax.axvline(i, color="#ccc", lw=0.5)
        if 1 <= i <= 11: ax.plot(i + 0.5, bits[i], "rv", ms=5)
    ax.set_ylim(-0.3, 1.5); ax.set_yticks([0, 1]); ax.set_xticks([])
    ax.set_title("UART frame for 0xA5, 8E1 (LSB first). Red marks = mid-bit sample points (tick 8 of 16)", fontsize=9)
    fig.tight_layout(); fig.savefig(f"{F}/frame.png", dpi=150); plt.close(fig)
frame_plot()

# ---------------- VCD waveform plots ----------------
def read_vcd(path, want, t0=None, t1=None):
    op = gzip.open if path.endswith(".gz") else open
    ids, scope, data = {}, [], {w: [] for w in want}; t = 0; defs = True
    with op(path, "rt") as f:
        for line in f:
            w = line.split()
            if not w: continue
            if defs:
                if w[0] == "$scope": scope.append(w[2])
                elif w[0] == "$upscope": scope.pop()
                elif w[0] == "$var":
                    full = ".".join(scope + [w[4]])
                    if full in want: ids.setdefault(w[3], []).append(full)
                elif w[0] == "$enddefinitions": defs = False
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
                if t1 is not None and t > t1: break
                continue
            if c in "01xz": v, i = c, line[1:].strip()
            elif c == "b": v, i = w[0][1:], w[1]
            else: continue
            for n in ids.get(i, []):
                try: val = int(v, 2)
                except ValueError: val = 0
                data[n].append((t, val))
    return data

def wave(path, sigs, t0, t1, out, title, scale=1e6, unit="us"):
    d = read_vcd(path, [s for s, _ in sigs], t0, t1)
    fig, axs = plt.subplots(len(sigs), 1, figsize=(11, 0.62 * len(sigs) + 0.8), sharex=True)
    for ax, (s, lab) in zip(axs, sigs):
        pts = d[s]; last = 0; xs, ys = [], []
        for t, v in pts:
            if t < t0: last = v; continue
            xs.append(t); ys.append(v)
        xs = [t0] + xs + [t1]; ys = [last] + ys + [ys[-1] if ys else last]
        xs = [x / scale for x in xs]
        mx = max(ys) if max(ys) > 0 else 1
        if mx <= 1: ax.step(xs, ys, where="post", lw=1.2)
        else:
            ax.step(xs, ys, where="post", lw=1.0)
            for a, b, v in zip(xs, xs[1:], ys):
                if (b - a) > (t1 - t0) / scale / 40: ax.text((a + b) / 2, v, f"{v:02X}", fontsize=6, ha="center", va="bottom")
        ax.set_ylabel(lab, rotation=0, ha="right", fontsize=8); ax.set_yticks([])
        for sp in ("top", "right"): ax.spines[sp].set_visible(False)
    axs[-1].set_xlabel(f"time ({unit})"); fig.suptitle(title, fontsize=9)
    fig.tight_layout(); fig.savefig(out, dpi=150); plt.close(fig)

lb = f"{TOP}/waves/tb_loopback.vcd"
# find first tx_start rise to place window
d = read_vcd(lb, ["tb_loopback.tx_start", "tb_loopback.pmode"], 0, None)
starts = [t for t, v in d["tb_loopback.tx_start"] if v == 1]
pm = d["tb_loopback.pmode"]
def pmode_at(t):
    v = 0
    for tt, vv in pm:
        if tt <= t: v = vv
    return v
sigs = [("tb_loopback.clk", "clk"), ("tb_loopback.tx_start", "tx_start"), ("tb_loopback.tx_data", "tx_data"),
        ("tb_loopback.line", "line"), ("tb_loopback.tx_busy", "tx_busy"), ("tb_loopback.tx_done", "tx_done"),
        ("tb_loopback.rx_valid", "rx_valid"), ("tb_loopback.rx_data", "rx_data"), ("tb_loopback.parity_err", "parity_err")]
DIVNS = 4 * 16 * 20 * 1000  # one bit in ps at DIV=4, 50 MHz (20 ns clk)
s0 = starts[2]
wave(lb, [s for s in sigs if s[1] != "clk"], s0 - DIVNS // 2, s0 + 3 * 11 * DIVNS, f"{F}/wave_loopback.png",
     f"tb_loopback.vcd: three back-to-back frames, parity_mode={pmode_at(s0)} (DIV=4)", 1e3, "ns")
wave(lb, sigs + [("tb_loopback.dut.tx_tick", "tx_tick"), ("tb_loopback.dut.u_rx.tcnt", "rx tcnt")], s0 - 2000, s0 + int(1.6 * DIVNS),
     f"{F}/wave_zoom.png", "zoom: start bit, 16x ticks and RX tick counter (mid-bit sample at tcnt boundary)", 1e3, "ns")
s_par = next((t for t in starts if pmode_at(t) == 1), None)
if s_par:
    wave(lb, [s for s in sigs if s[1] != "clk"], s_par - DIVNS // 2, s_par + 12 * DIVNS, f"{F}/wave_even.png",
         "tb_loopback.vcd: one 8E1 frame (even parity)", 1e3, "ns")
pw = f"{TOP}/waves/power_lp1.vcd.gz"
wave(pw, [("tb_power.phase_active", "active"), ("tb_power.dut.tx", "tx"), ("tb_power.dut.tx_tick", "tx_tick"), ("tb_power.dut.rx_tick", "rx_tick")],
     0, 2_000_000_000, f"{F}/wave_lowpower.png", "power_lp1.vcd: ticks only toggle while a frame is active (LOWPWR_EN=1)", 1e6, "us")

# ---------------- data plots ----------------
rows = []
for p in sorted(glob.glob(f"{TOP}/logs/features_seed1_clk*ns.log")):
    for m in re.finditer(r"autobaud clk=([\d.]+)MHz baud=(\d+) ideal_div=([\d.]+) locked=(\d) div=(\d+) rate_err=([-\d.]+)% bytes_rx=(\d+)/(\d+)", open(p).read()):
        rows.append(tuple(float(x) for x in m.groups()))
fig, ax = plt.subplots(figsize=(8, 3.4))
for clk in sorted(set(r[0] for r in rows)):
    rr = [r for r in rows if r[0] == clk]
    ax.semilogx([r[1] for r in rr], [r[5] for r in rr], "o-", label=f"{clk:g} MHz")
ax.axhspan(-2, 2, color="g", alpha=0.1, label="+-2% window"); ax.set_xlabel("baud"); ax.set_ylabel("rate error after lock (%)")
ax.legend(fontsize=8); ax.grid(alpha=.3); ax.set_title("Auto-baud lock error (SEED=1)", fontsize=9)
fig.tight_layout(); fig.savefig(f"{F}/autobaud_err.png", dpi=150); plt.close(fig)

syn = []
for line in open(f"{TOP}/logs/synth_summary.log").read().splitlines()[1:]:
    w = line.split()
    if w and not w[-1].isdigit(): w = w[:-1]     # drop the fmax_MHz column
    if len(w) >= 6 and w[-1].isdigit(): syn.append((w[0], int(w[-5]), int(w[-4]), int(w[-3]), int(w[-2]), int(w[-1])))
assert syn, "no rows parsed from logs/synth_summary.log"
fig, ax = plt.subplots(figsize=(8, 3.2))
ax.bar([s[0] for s in syn], [s[4] for s in syn], color="#5b8bd0"); ax.set_ylabel("iCE40 SB_LUT4 count")
for i, s in enumerate(syn): ax.text(i, s[4], str(s[4]), ha="center", va="bottom", fontsize=7)
plt.xticks(rotation=30, fontsize=8); ax.set_title("Yosys synth_ice40 LUT count per configuration", fontsize=9)
fig.tight_layout(); fig.savefig(f"{F}/synth_luts.png", dpi=150); plt.close(fig)

tg = {}
for m in re.finditer(r"power_lp(\d)\.vcd: toggles idle=(\d+) active=(\d+)", open(f"{TOP}/logs/power_toggles.log").read()):
    tg[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
fig, ax = plt.subplots(figsize=(6, 3))
import numpy as np
x = np.arange(2); ax.bar(x - 0.2, [tg[0][0], tg[1][0]], 0.4, label="idle"); ax.bar(x + 0.2, [tg[0][1], tg[1][1]], 0.4, label="active")
ax.set_xticks(x); ax.set_xticklabels(["LOWPWR_EN=0", "LOWPWR_EN=1"]); ax.set_yscale("log"); ax.set_ylabel("bit toggles (log)")
ax.legend(); ax.set_title("VCD toggle count (activity proxy, not power)", fontsize=9)
fig.tight_layout(); fig.savefig(f"{F}/toggles.png", dpi=150); plt.close(fig)
print("figs:", sorted(os.listdir(F)))
