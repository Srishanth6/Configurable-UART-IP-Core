#!/bin/bash
# usage: vbuild.sh <top> <outdir> [extra verilator args...]
top=$1; out=$2; shift 2
verilator --binary --timing --assert --timescale 1ns/1ps -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD \
  -O2 --top-module "$top" -Mdir "$out" "$@" rtl/*.v sva/uart_sva.sv tb/$top.sv -o sim
