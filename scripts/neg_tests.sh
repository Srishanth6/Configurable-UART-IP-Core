#!/bin/bash
# Build with a deliberately injected RTL bug; the SVA must catch it (nonzero exit).
cd "$(dirname "$0")/.."
fail=0
for bug in INJECT_BUG INJECT_BUG_TX; do
  scripts/vbuild.sh tb_uart_rand build/neg_$bug +define+$bug >/dev/null 2>&1 || { echo "build failed $bug"; fail=1; continue; }
  build/neg_$bug/sim +SEED=1 > logs/neg_$bug.log 2>&1; rc=$?
  echo "=== $bug: exit code $rc"; grep -m2 -iE "assertion failed|error" logs/neg_$bug.log
  if [ $rc -eq 0 ]; then echo "NEG $bug: NOT CAUGHT (bad)"; fail=1; else echo "NEG $bug: caught by assertion (expected)"; fi
done
exit $fail
