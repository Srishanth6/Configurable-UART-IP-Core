# UART IP core - run everything from here. Logs go to logs/.
SEEDS ?= 1 42 2026
SHELL := /bin/bash
PYTHON ?= python3
.SHELLFLAGS := -o pipefail -c
RTL := $(wildcard rtl/*.v)

.PHONY: all baud loopback rand rand_feat neg features power synth edge waves_err report clean
all: baud loopback rand rand_feat neg features power synth edge waves_err

baud:
	mkdir -p build logs waves
	iverilog -g2012 -o build/tb_baud tb/tb_baud.v $(RTL) && vvp -n build/tb_baud 2>&1 | tee logs/baud_gen.log
loopback:
	mkdir -p build logs waves
	iverilog -g2012 -o build/tb_loopback tb/tb_loopback.v $(RTL) && vvp -n build/tb_loopback 2>&1 | tee logs/loopback.log
rand:
	mkdir -p build logs waves syn/out
	scripts/vbuild.sh tb_uart_rand build/rand
	set -o pipefail; for s in $(SEEDS); do build/rand/sim +SEED=$$s 2>&1 | tee logs/rand_seed$$s.log || exit 1; done
rand_feat:
	mkdir -p build logs waves syn/out
	scripts/vbuild.sh tb_uart_rand build/rand_lp -GLOWPWR_EN=1 -GLINEMON_EN=1
	set -o pipefail; for s in $(SEEDS); do build/rand_lp/sim +SEED=$$s 2>&1 | tee logs/rand_lp_mon_seed$$s.log || exit 1; done
# directed edge cases (divisor boundaries, reset in every state, all parity
# codes back-to-back, malformed frames) + extra SVA in sva/uart_sva_ext.sv
EDGE_DIVS ?= 1 2 3 16 255
edge:
	mkdir -p build logs
	for d in $(EDGE_DIVS); do scripts/vbuild.sh tb_edge build/edge$$d -GDIV=$$d sva/uart_sva_ext.sv >/dev/null || exit 1; \
	  build/edge$$d/sim 2>&1 | tee logs/edge_div$$d.log || exit 1; done
	scripts/vbuild.sh tb_edge build/edge_max -GDIV=65535 -GFRAMES=1 -GFULL=0 sva/uart_sva_ext.sv >/dev/null
	build/edge_max/sim 2>&1 | tee logs/edge_div65535.log
# waveform evidence: traced tb_edge run (DIV=4), plots TX/RX timing,
# parity error and framing error windows into report/figs/
waves_err:
	mkdir -p build logs waves report/figs
	scripts/vbuild.sh tb_edge build/edge_tr -GDIV=4 -GFRAMES=4 --trace +define+DUMP sva/uart_sva_ext.sv >/dev/null
	build/edge_tr/sim 2>&1 | tee logs/edge_waves.log
	$(PYTHON) scripts/err_waves.py
# injected-bug demo: RX samples 3/16 bit late, B2 must fire; keeps a VCD for GTKWave
bug_demo:
	mkdir -p build logs waves
	scripts/vbuild.sh tb_edge build/edge_bug -GDIV=4 -GFRAMES=4 --trace +define+DUMP +define+INJECT_BUG_RXMID sva/uart_sva_ext.sv >/dev/null
	build/edge_bug/sim +vcd=waves/tb_edge_bug_rxmid.vcd 2>&1 | tee logs/bug_demo.log; \
	  grep -q "B2 start bit sampled" logs/bug_demo.log && echo "bug_demo: injected bug caught by B2 (expected)"
# real GTKWave window screenshots -> report/figs/gtkwave_*.png (needs an X display)
gtkwave_shots: waves_err bug_demo
	scripts/gtkwave_shots.sh
# negative tests: these MUST fail, the script checks that they do
neg:
	mkdir -p build logs
	scripts/neg_tests.sh 2>&1 | tee logs/negative_tests.log
features:
	mkdir -p build logs waves syn/out
	scripts/vbuild.sh tb_features build/feat
	set -o pipefail; for s in $(SEEDS); do for c in 20 10 7.5; do build/feat/sim +SEED=$$s +CLK_NS=$$c 2>&1 | tee logs/features_seed$${s}_clk$${c}ns.log || exit 1; done; done
power:
	mkdir -p build logs waves syn/out
	for lp in 0 1; do iverilog -g2012 -P tb_power.LP=$$lp -o build/tbp$$lp tb/tb_power.v $(RTL) && vvp -n build/tbp$$lp; done 2>&1 | tee logs/power_sim.log
	$(PYTHON) scripts/vcd_toggles.py waves/power_lp0.vcd waves/power_lp1.vcd 2>&1 | tee logs/power_toggles.log
	gzip -f waves/power_lp*.vcd
synth:
	mkdir -p build logs waves syn/out
	scripts/synth_all.sh 2>&1 | tee logs/synth_summary.log
report:
	$(PYTHON) report/make_figs.py && report/build_report.sh
clean:
	rm -rf build/*
