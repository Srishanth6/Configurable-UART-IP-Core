#!/bin/bash
# Yosys generic synthesis (gate-level internal cells) + ice40 mapping for several configs.
cd "$(dirname "$0")/.."
mkdir -p syn/out
# Columns: cells/dff/depth = Yosys generic gates (abc -g cmos2, ltp -noff = longest
# combinational path in gates, NOT a time). ice_LUT4/ice_DFF = synth_ice40 mapping.
# fmax = nextpnr-ice40 post-place-and-route estimate (HX8K ct256, seed 1, IO
# unconstrained). Printed as "not_measured" when nextpnr-ice40 is not installed.
HAVE_PNR=0; command -v nextpnr-ice40 >/dev/null 2>&1 && HAVE_PNR=1
printf "%-14s %-44s %8s %8s %6s %8s %8s %10s\n" config params cells dff depth ice_LUT4 ice_DFF fmax_MHz
run() {
  name=$1; params=$2
  cp=""; for kv in $params; do cp="$cp chparam -set ${kv%=*} ${kv#*=} uart_core;"; done
  yosys -q -l syn/out/$name.log -p "read_verilog rtl/*.v; $cp synth -top uart_core -flatten; abc -g cmos2; opt_clean; tee -o syn/out/$name.stat stat; tee -o syn/out/$name.ltp ltp -noff" >/dev/null 2>&1 || { echo "$name FAILED"; return; }
  yosys -q -p "read_verilog rtl/*.v; $cp synth_ice40 -top uart_core; tee -o syn/out/${name}_ice40.stat stat; write_json syn/out/${name}_ice40.json" >/dev/null 2>&1
  fmax=not_measured
  if [ $HAVE_PNR = 1 ]; then
    nextpnr-ice40 --hx8k --package ct256 --seed 1 --json syn/out/${name}_ice40.json --pcf-allow-unconstrained --log syn/out/${name}_pnr.log >/dev/null 2>&1 \
      && fmax=$(grep -E "Max frequency for clock" syn/out/${name}_pnr.log | tail -1 | grep -oE "[0-9]+\.[0-9]+ MHz" | head -1 | cut -d" " -f1)
    [ -z "$fmax" ] && fmax=pnr_failed
  fi
  cells=$(grep -m1 -E "Number of cells:" syn/out/$name.stat | awk '{print $NF}')
  dff=$(grep -E '\$_.*DFF.*_' syn/out/$name.stat | awk '{s+=$NF} END{print s+0}')
  depth=$(grep -oE "length=[0-9]+" syn/out/$name.ltp | tail -1 | cut -d= -f2)
  lc=$(grep -E "SB_LUT4" syn/out/${name}_ice40.stat | awk '{print $NF}' | head -1)
  idff=$(grep -E "SB_DFF" syn/out/${name}_ice40.stat | awk '{s+=$NF} END{print s+0}')
  printf "%-14s %-44s %8s %8s %6s %8s %8s %10s\n" $name "${params:-default}" $cells $dff $depth ${lc:-?} $idff $fmax
}
C="DIV_W=16 PARITY_SUPPORT=1"   # same width/parity for every feature config
B="AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=0"
run base16      "$B DIV_W=16 PARITY_SUPPORT=1"
run base8       "$B DIV_W=8 PARITY_SUPPORT=1"
run noparity16  "$B DIV_W=16 PARITY_SUPPORT=0"
run autobaud    "$C AUTOBAUD_EN=1 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=0"
run ecc         "$C AUTOBAUD_EN=0 ECC_EN=1 LOWPWR_EN=0 LINEMON_EN=0"
run lowpwr      "$C AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=1 LINEMON_EN=0"
run linemon     "$C AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=1"
run all_feat    "$C AUTOBAUD_EN=1 ECC_EN=1 LOWPWR_EN=1 LINEMON_EN=1"
