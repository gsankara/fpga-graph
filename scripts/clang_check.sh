#!/bin/bash
# clang_check.sh -- identify what the high-CPU clang process actually is.
echo "=== highest-CPU processes ==="
ps -eo pid,user,pcpu,stat,comm --sort=-pcpu --no-headers | head -4
echo
echo "=== every clang: pid, cpu, cwd, cmdline head ==="
for p in $(pgrep -x clang; pgrep -x clang-3.9); do
  echo "PID $p  cpu=$(ps -o pcpu= -p "$p" 2>/dev/null | tr -d ' ')  ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  echo "  cwd:  $(readlink /proc/$p/cwd 2>/dev/null)"
  echo "  cmd:  $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -oE '(top-function-name=[^ ]+|/home/coder/[^ ]*/(db|autopilot)[^ ]*|hls-top[^ ]*)' | head -1)"
  echo "  full: $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-160)"
done
echo
echo "=== is any of my fpga-routing-graph work running clang? ==="
pgrep -af clang | grep -c "fpga-routing-graph" | xargs echo "matches in build/{tree,ring16}:"
