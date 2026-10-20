# Fixed VT facade fixtures

`replay.json`, `n2.json`, and `protocol.json` retain the reviewed Apple Silicon
baseline. `n2-linux-x86_64.json` is the explicit Linux x86_64 N2 baseline, selected
only on that platform by `tools/verify-vt-goldens.py`.

The only platform difference is `history-budget-pruned`: Linux retains 96
`fresh` lines and a final empty row (total 97, viewport offset 94); the Apple
Silicon fixture retains 60 lines and a final empty row (total 61, offset 58).
Ghostty prunes complete terminal pages, whose layout depends on target page
and cache-line alignment. The old sentinel is removed on both platforms.
Visible cells, cursor, selection, search and the other 20 records are identical.
The Linux values were individually reviewed against CI run 39472660902,
attempt 2; the runner never updates expected values from its output.

These files are exact regression expectations, not a promise of identical
retained row counts across architectures. Changes require reviewing the full
record difference and preserving each platform's historical provenance.
