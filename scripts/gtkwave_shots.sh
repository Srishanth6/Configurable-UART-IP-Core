#!/bin/bash
# Real GTKWave screenshots of the saved VCDs.
# For each view: waves/<name>.gtkw (signals, radix, marker) + a Tcl script that
# zooms to the window, sets the marker and re-writes the .gtkw with that zoom.
# Then the GTKWave window is captured with ImageMagick `import`.
# Needs: gtkwave, imagemagick, xdotool and an X display ($DISPLAY or Xvfb).
# Reproduce one view by hand:  gtkwave waves/<vcd> waves/<name>.gtkw
set -e
# DARK=1: reuse the existing waves/*.gtkw unchanged, dark GTK theme + waves/dark.gtkwaverc,
#         dark xterm, output report/figs/gtkwave_dark_*.png
PFX=""; GTKENV=""; GTKRC=""; XTC=""
if [ -n "$DARK" ]; then PFX="dark_"; GTKENV="env GTK_THEME=Adwaita:dark"; GTKRC="-r waves/dark.gtkwaverc"; XTC="-bg black -fg white"; fi
cd "$(dirname "$0")/.."
mkdir -p report/figs waves build
: "${DISPLAY:?need an X display (e.g. run under xvfb-run -s '-screen 0 1280x800x24')}"

# name | vcd | t0_ps | t1_ps | marker_ps | signals (fmt:path ...; fmt b=binary h=hex)
shot() {
  local name=$1 vcd=$2 t0=$3 t1=$4 mk=$5; shift 5
  local g=waves/$name.gtkw tcl=build/$name.tcl
  if [ -z "$DARK" ]; then {
    echo "[*] GTKWave save file for $vcd (scripts/gtkwave_shots.sh)"
    echo "[dumpfile] \"$PWD/$vcd\""
    echo "[savefile] \"$PWD/$g\""
    echo "[timestart] $t0"
    echo "[size] 1280 800"
    echo "[pos] 0 0"
    echo "*-20.000000 $mk -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1"
    echo "[sst_width] 220"
    echo "[signals_width] 230"
    echo "[sst_expanded] 1"
    for s in "$@"; do
      case ${s%%:*} in h) echo "@22";; b) echo "@28";; d) echo "@24";; esac
      echo "${s#*:}"
    done
  } > "$g"; fi
  cat > "$tcl" <<T
gtkwave::setZoomRangeTimes $t0 $t1
gtkwave::setMarker $mk
T
  [ -n "$DARK" ] || echo "gtkwave::/File/Write_Save_File" >> "$tcl"
  $GTKENV gtkwave $GTKRC -S "$tcl" "$vcd" "$g" >build/$name.gtkwave.log 2>&1 &
  local pid=$!
  local wid=""
  for i in $(seq 1 120); do
    wid=$(xdotool search --onlyvisible --pid $pid 2>/dev/null | tail -1) && [ -n "$wid" ] && break
    sleep 1
  done
  [ -n "$wid" ] || { echo "no GTKWave window for $name"; kill $pid; exit 1; }
  xdotool windowsize $wid 1280 800 windowmove $wid 40 40 windowactivate --sync $wid 2>/dev/null || true
  sleep ${SHOT_WAIT:-6}
  # -frame keeps the window-manager title bar, like a normal desktop screenshot
  import -window "$(xdotool getwindowfocus 2>/dev/null || echo $wid)" -frame report/figs/gtkwave_$PFX$name.png 2>/dev/null \
    || import -window $wid -frame report/figs/gtkwave_$PFX$name.png
  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  # fix the paths in the saved file so it works from the repo root on any machine
  [ -n "$DARK" ] || sed -i "s#\"$PWD/#\"#" "$g"
  echo "gtkwave_$PFX$name.png  <- $vcd  [$t0, $t1] ps, marker $mk ps"
}

E=tb_edge
shot loopback waves/tb_loopback.vcd 0 27000000 12390000 \
  b:tb_loopback.clk b:tb_loopback.rst_n b:tb_loopback.tx_start h:tb_loopback.tx_data[7:0] \
  b:tb_loopback.dut.tx_tick b:tb_loopback.dut.tx b:tb_loopback.tx_busy b:tb_loopback.tx_done \
  b:tb_loopback.line b:tb_loopback.dut.rx_tick b:tb_loopback.rx_valid h:tb_loopback.rx_data[7:0] \
  b:tb_loopback.parity_err b:tb_loopback.frame_err

shot parity_err waves/tb_edge_err.vcd 832510000 865800000 846050000 \
  b:$E.clk b:$E.rst_n h:$E.pmode[1:0] b:$E.bfm_sel b:$E.line b:$E.chk2.rx_tick h:$E.chk2.rx_state[2:0] \
  d:$E.chk2.rx_bit_no[2:0] b:$E.rx_valid h:$E.rx_data[7:0] b:$E.parity_err b:$E.frame_err

shot frame_err waves/tb_edge_err.vcd 642910000 663400000 655170000 \
  b:$E.clk b:$E.rst_n h:$E.pmode[1:0] b:$E.bfm_sel b:$E.line b:$E.chk2.rx_tick h:$E.chk2.rx_state[2:0] \
  d:$E.chk2.rx_bit_no[2:0] b:$E.rx_valid h:$E.rx_data[7:0] b:$E.parity_err b:$E.frame_err

shot lowpower waves/power_lp1.vcd.gz 0 2200000000 1995980000 \
  b:tb_power.phase_active b:tb_power.dut.tx_start h:tb_power.dut.tx_data[7:0] b:tb_power.dut.tx_bg_en \
  b:tb_power.dut.tx_tick h:tb_power.dut.u_bg_tx.cnt[15:0] b:tb_power.dut.tx b:tb_power.dut.tx_busy \
  b:tb_power.dut.rx_bg_en b:tb_power.dut.rx_tick h:tb_power.dut.u_bg_rx.cnt[15:0] b:tb_power.dut.rx_valid

# the sim aborts at 1.11 us on the B2 failure, so the VCD ends at 1.10 us: marker on the last dumped edge
shot bug_rxmid waves/tb_edge_bug_rxmid.vcd 0 1120000 1100000 \
  b:$E.clk b:$E.rst_n b:$E.line b:$E.chk2.bg_tick b:$E.chk2.rx_tick h:$E.chk2.rx_state[2:0] \
  h:$E.chk2.rx_tcnt[3:0] d:$E.chk2.rx_ticks[31:0] b:$E.chk2.rx_sample b:$E.rx_valid

# real terminal running the injected-bug make target
rm -f build/bug_demo.done
xterm $XTC -geometry 110x30+40+40 -fa Monospace -fs 11 -T "Terminal - make bug_demo" \
  -e bash -c 'echo "\$ make bug_demo"; make --no-print-directory bug_demo; echo; echo "[make bug_demo exited with status $?]"; touch build/bug_demo.done; sleep 600' &
xp=$!
for i in $(seq 1 180); do [ -f build/bug_demo.done ] && break; sleep 1; done
sleep 2
xw=$(xdotool search --onlyvisible --pid $xp | tail -1)
[ -n "$xw" ] || { echo "no xterm window"; kill $xp; exit 1; }
import -window $xw -frame report/figs/gtkwave_${PFX}bug_rxmid_terminal.png
kill $xp 2>/dev/null || true
echo "gtkwave_${PFX}bug_rxmid_terminal.png <- xterm running make bug_demo"
