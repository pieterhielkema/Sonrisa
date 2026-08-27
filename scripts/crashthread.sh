#!/bin/bash
#
# crashthread.sh — print only the decisive part of a macOS crash report so a
# whole .ips (tens of thousands of tokens) never lands in an AI context.
#
# Prints: process/exception header + the faulting thread's backtrace only.
# Works for both the human-readable section and the JSON payload .ips files.
#
#   scripts/crashthread.sh ~/Library/Logs/DiagnosticReports/Sonrisa-*.ips
#   scripts/crashthread.sh            # newest Sonrisa* report if no arg

set -euo pipefail

FILE="${1:-}"
if [[ -z "$FILE" ]]; then
  FILE=$(ls -t ~/Library/Logs/DiagnosticReports/Sonrisa* 2>/dev/null | head -1)
fi
[[ -n "$FILE" && -f "$FILE" ]] || { echo "usage: crashthread.sh <file.ips>"; exit 1; }

python3 - "$FILE" <<'PY'
import json, sys, re

raw = open(sys.argv[1]).read()

# .ips files are two JSON objects (header line + body). Fall back to plain-text
# reports (older format) by just slicing the crashed-thread section.
try:
    body = json.loads(raw.split("\n", 1)[1])
except Exception:
    m = re.search(r"(Thread \d+ Crashed.*?)(\n\nThread \d+::|\nBinary Images:)",
                  raw, re.S)
    print(m.group(1).strip() if m else raw[:2000])
    sys.exit(0)

exc = body.get("exception", {})
print("proc:", body.get("procName"),
      "| exc:", exc.get("type"), exc.get("signal"), exc.get("subtype", ""))
imgs = body.get("usedImages", [])
for t in body.get("threads", []):
    if not t.get("triggered"):
        continue
    print("thread:", t.get("name"), t.get("queue", ""))
    for f in t.get("frames", []):
        nm = imgs[f["imageIndex"]].get("name", "?") if f.get("imageIndex") is not None else "?"
        sym = f.get("symbol") or hex(f.get("imageOffset", 0))
        src = f" ({f['sourceFile']}:{f.get('sourceLine','?')})" if f.get("sourceFile") else ""
        print(f"  {nm:28} {sym}{src}")
    break
PY
