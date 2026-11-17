# Tool output

Every tool result stays in context and is re-read on every later turn, so one oversized result costs again each turn.

- Keep a single tool result under about 10 KB. Before running a command whose output size is unknown, bound it.
- Send build, test, lint, profiler and other verbose output to a log file (`cmd > "$log" 2>&1; echo "exit=$?"`), then read only what you need with `tail -n 80`, `grep -n -m 40 -E 'error|FAIL|panicked'` or `sed -n 'A,Bp'`. A request to keep full logs means keep the file and cite its path, not paste it into context.
- Read large files in ranges, not whole. Check size first (`wc -c`, `wc -l`) when unsure.
- For broad searches, list matching files first (`rg -l`, `rg -c`) or cap matches (`rg -m 5`), then narrow.
- Filter JSON, API and MCP responses to the needed fields (`jq`) instead of dumping them; avoid printing base64, binary, minified or generated data.
- In Codex code-mode cells, bound a value before returning it with `text()` (for example `text(out.slice(-4000))`); never `text(await ...)` an unbounded command, file or tool result.
- Don't re-run a command just to see its output again; reread the log file.
