# UART IP core - run everything from here. Logs go to logs/.
SEEDS ?= 1 42 2026
SHELL := /bin/bash
RTL := $(wildcard rtl/*.v)

.PHONY: all baud loopback rand rand_feat neg features power synth report clean
all: baud loopback rand rand_feat neg features power synth

baud:
	iverilog -g2012 -o build/tb_baud tb/tb_baud.v $(RTL) && vvp -n build/tb_baud 2>&1 | tee logs/baud_gen.log
loopback:
	iverilog -g2012 -o build/tb_loopback tb/tb_loopback.v $(RTL) && vvp -n build/tb_loopback 2>&1 | tee logs/loopback.log
rand:
	scripts/vbuild.sh tb_uart_rand build/rand
	set -o pipefail; for s in $(SEEDS); do build/rand/sim +SEED=$$s 2>&1 | tee logs/rand_seed$$s.log || exit 1; done
rand_feat:
	scripts/vbuild.sh tb_uart_rand build/rand_lp -GLOWPWR_EN=1 -GLINEMON_EN=1
	set -o pipefail; for s in $(SEEDS); do build/rand_lp/sim +SEED=$$s 2>&1 | tee logs/rand_lp_mon_seed$$s.log || exit 1; done
# negative tests: these MUST fail, the script checks that they do
neg:
	mkdir -p build
	scripts/neg_tests.sh 2>&1 | tee logs/negative_tests.log
features:
	scripts/vbuild.sh tb_features build/feat
	set -o pipefail; for s in $(SEEDS); do for c in 20 10 7.5; do build/feat/sim +SEED=$$s +CLK_NS=$$c 2>&1 | tee logs/features_seed$${s}_clk$${c}ns.log || exit 1; done; done
power:
	for lp in 0 1; do iverilog -g2012 -P tb_power.LP=$$lp -o build/tbp$$lp tb/tb_power.v $(RTL) && vvp -n build/tbp$$lp; done 2>&1 | tee logs/power_sim.log
	python3 scripts/vcd_toggles.py waves/power_lp0.vcd waves/power_lp1.vcd 2>&1 | tee logs/power_toggles.log
	gzip -f waves/power_lp*.vcd
synth:
	scripts/synth_all.sh 2>&1 | tee logs/synth_summary.log
report:
	python3 report/make_figs.py && report/build_report.sh
clean:
	rm -rf build/*
