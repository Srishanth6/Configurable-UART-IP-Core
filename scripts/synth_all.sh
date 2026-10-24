#!/bin/bash
# Yosys generic synthesis (gate-level internal cells) + ice40 mapping for several configs.
cd "$(dirname "$0")/.."
mkdir -p syn/out
printf "%-14s %-44s %8s %8s %6s %8s %8s\n" config params cells dff depth ice_LC ice_DFF
run() {
  name=$1; params=$2
  cp=""; for kv in $params; do cp="$cp chparam -set ${kv%=*} ${kv#*=} uart_core;"; done
  yosys -q -l syn/out/$name.log -p "read_verilog rtl/*.v; $cp synth -top uart_core -flatten; abc -g cmos2; opt_clean; tee -o syn/out/$name.stat stat; tee -o syn/out/$name.ltp ltp -noff" >/dev/null 2>&1 || { echo "$name FAILED"; return; }
  yosys -q -p "read_verilog rtl/*.v; $cp synth_ice40 -top uart_core; tee -o syn/out/${name}_ice40.stat stat" >/dev/null 2>&1
  cells=$(grep -m1 -E "Number of cells:" syn/out/$name.stat | awk '{print $NF}')
  dff=$(grep -E '\$_.*DFF.*_' syn/out/$name.stat | awk '{s+=$NF} END{print s+0}')
  depth=$(grep -oE "length=[0-9]+" syn/out/$name.ltp | tail -1 | cut -d= -f2)
  lc=$(grep -E "SB_LUT4" syn/out/${name}_ice40.stat | awk '{print $NF}' | head -1)
  idff=$(grep -E "SB_DFF" syn/out/${name}_ice40.stat | awk '{s+=$NF} END{print s+0}')
  printf "%-14s %-44s %8s %8s %6s %8s %8s\n" $name "${params:-default}" $cells $dff $depth ${lc:-?} $idff
}
B="AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=0"
run base16      "$B DIV_W=16 PARITY_SUPPORT=1"
run base8       "$B DIV_W=8 PARITY_SUPPORT=1"
run noparity16  "$B DIV_W=16 PARITY_SUPPORT=0"
run autobaud    "AUTOBAUD_EN=1 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=0"
run ecc         "AUTOBAUD_EN=0 ECC_EN=1 LOWPWR_EN=0 LINEMON_EN=0"
run lowpwr      "AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=1 LINEMON_EN=0"
run linemon     "AUTOBAUD_EN=0 ECC_EN=0 LOWPWR_EN=0 LINEMON_EN=1"
run all_feat    "AUTOBAUD_EN=1 ECC_EN=1 LOWPWR_EN=1 LINEMON_EN=1"
