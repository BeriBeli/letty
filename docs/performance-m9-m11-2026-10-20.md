# M9–M11 frozen performance review (2026-10-20)

Candidate source: `8e6a2f5691b5b59a0a87afe735b986d0db0050b79ce1f762cd1678b95ff4e107`; retained M8: `534a13035e129811af659cda9e08696f78c7c71aafce54fb4ef1e6f882e63fbc`. Same macOS host/1000×680 Tester/1-4-16 panes, three runs per version/size, eighteen interleaved runs. Raw-report SHA256: `45173f0e71ac91f3dff6166b8cef28e3e2d2ea84c00e768757acc7d5dccbaedf`; stdout/stderr/review accompany the evidence package.

| Median metric | 1 pane M8 → candidate | 4 panes M8 → candidate | 16 panes M8 → candidate |
|---|---|---|---|
| Frame-build mean µs | 337 → 337 | 557 → 551 | 649 → 638 |
| Frame-build P95 µs | 350 → 350 | 574 → 565 | 672 → 654 |
| Startup ms | 39 → 38 | 38 → 38 | 38 → 38 |
| CPU over 2s idle µs | 238 → 238 | 254 → 273 | 268 → 262 |
| Search total µs | 66815 → 65987 | 67846 → 67088 | 65369 → 67547 |
| Scroll 60 frames µs | 24483 → 24578 | 35580 → 35735 | 39407 → 39012 |
| Peak RSS MiB | 151.406 → 152.078 | 160.797 → 161.484 | 192.969 → 193.797 |
| Process CPU s | 0.240 → 0.240 | 0.330 → 0.330 | 0.680 → 0.690 |

All eighteen raw records had 88771 matches. Across nine candidate runs, search slice max was 6.029 ms (M8 7.161), idle max 309 µs, frame mean max 641 µs/P95 max 657. No median ratio exceeded 1.10. RSS medians rose 0.67/0.69/0.83 MiB (<0.5%). Unstripped executable size rose 15.53%, explicitly accepted as feature/check cost; overall resource reduction is not claimed.

Acceptance applies only to measured development workloads. GPU draw/present, OS/compositor, GTK/X11, Linux execution, PSS, end-to-end input, sidebar switching/continuous drag, and system clipboard were not measured. Smaller Tester trees do not substitute. Historical M8/unfrozen failures remain independent.
