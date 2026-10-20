# Performance measurement methodology

Target Linux/Konsole measurements have not been completed, so no memory-saving claim is established. The package's `/proc/PID/smaps` sampler supports the Linux baseline without smaps_rollup or cgroup v2.

```bash
# In another terminal, use the actual Letty GUI PID, not the shell/workload PID.
./tools/memory-sample.sh PID 30 1 >letty-idle.csv
# Inside Letty, substitute the actual package path.
/path/to/package/tools/workload.sh 100000
```

Compare on the same GUI host/display path, whether local or SSH X11: equal window pixels/font/size/rows/columns/independent PTYs/shell/retained history. Letty defaults to both 10000 lines and 16 MiB, with Ghostty page-granularity pruning. Check actual retained rows and align both budgets rather than pruning early to gain an advantage.

Workloads: one/four idle sessions, ANSI/CJK logs, saturated history, scrolling/search, vim/less/tmux, simultaneous output/input/resize, repeated creation/close. Run at least three times; report PSS median/range and supporting RSS. Separate shell/workload costs; do not sum shared-library RSS. After closure, record FDs and stabilized memory.

Measure observable SSH/Xorg/Xwayland/desktop transport overhead separately, disclosing noise/unmeasured GPU resources. Assess echo/scroll response and X11 traffic with memory. CPU framebuffer/damage costs require target measurements; executable size is not runtime memory.
