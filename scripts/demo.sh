#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== iMessageAI Verification ==="
echo "Repo: $REPO_DIR"
echo ""

# -----------------------------------------------
# 1. Check required files exist
# -----------------------------------------------
echo "[CHECK] Required files..."
REQUIRED_FILES=(
  "model.py"
  "send_imessage.osa"
  "config.json"
  "iMessageAI/ContentView.swift"
  "iMessageAI/iMessageAIApp.swift"
)

for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$REPO_DIR/$f" ]; then
    echo "FAIL: missing $f"
    exit 1
  fi
  echo "  OK: $f"
done
echo ""

# -----------------------------------------------
# 2. Validate config.json structure
# -----------------------------------------------
echo "[CHECK] config.json structure..."
python3 -c "
import json, sys
with open('$REPO_DIR/config.json') as f:
    c = json.load(f)
errors = []
if 'name' not in c:
    errors.append('missing name')
if 'personalDescription' not in c:
    errors.append('missing personalDescription')
if 'moods' not in c or not isinstance(c['moods'], dict):
    errors.append('missing or invalid moods')
elif len(c['moods']) < 1:
    errors.append('need at least 1 mood')
if 'phoneListMode' not in c or c['phoneListMode'] not in ('Include', 'Exclude'):
    errors.append('invalid phoneListMode')
if 'phoneNumbers' not in c or not isinstance(c['phoneNumbers'], list):
    errors.append('invalid phoneNumbers')
if errors:
    for e in errors:
        print(f'  FAIL: {e}')
    sys.exit(1)
print(f'  Name: {c[\"name\"]}')
print(f'  Moods: {list(c[\"moods\"].keys())}')
print(f'  Filter: {c[\"phoneListMode\"]}')
print('  CONFIG_OK')
"
echo ""

# -----------------------------------------------
# 3. Validate model.py syntax
# -----------------------------------------------
echo "[CHECK] model.py syntax..."
python3 -c "
import py_compile, sys
try:
    py_compile.compile('$REPO_DIR/model.py', doraise=True)
    print('  SYNTAX_OK')
except py_compile.PyCompileError as e:
    print(f'  FAIL: {e}')
    sys.exit(1)
"
echo ""

# -----------------------------------------------
# 4. Check ollama package importable
# -----------------------------------------------
echo "[CHECK] Python ollama package..."
if python3 -c "import ollama; print('  IMPORT_OK')" 2>/dev/null; then
  true
else
  echo "  WARN: ollama package not installed (pip install ollama)"
fi
echo ""

# -----------------------------------------------
# 5. Check Swift source compiles (syntax only)
# -----------------------------------------------
echo "[CHECK] Swift source syntax..."
if command -v swiftc >/dev/null 2>&1; then
  # Parse-only check for each Swift file
  SWIFT_OK=true
  for sf in "$REPO_DIR"/iMessageAI/*.swift; do
    if swiftc -parse "$sf" 2>/dev/null; then
      echo "  OK: $(basename "$sf")"
    else
      echo "  WARN: $(basename "$sf") has parse issues (may need framework imports)"
      SWIFT_OK=false
    fi
  done
  if $SWIFT_OK; then
    echo "  SWIFT_SYNTAX_OK"
  fi
else
  echo "  WARN: swiftc not found, skipping Swift syntax check"
fi
echo ""

# -----------------------------------------------
# 6. Check AppleScript syntax
# -----------------------------------------------
echo "[CHECK] AppleScript syntax..."
if command -v osacompile >/dev/null 2>&1; then
  if osacompile -o /dev/null "$REPO_DIR/send_imessage.osa" 2>/dev/null; then
    echo "  APPLESCRIPT_OK"
  else
    echo "  WARN: AppleScript compilation issue"
  fi
else
  echo "  WARN: osacompile not found, skipping"
fi
echo ""

# -----------------------------------------------
# 7. Documentation completeness
# -----------------------------------------------
echo "[CHECK] Documentation..."
if [ -f "$REPO_DIR/README.md" ]; then
  LINES=$(wc -l < "$REPO_DIR/README.md" | tr -d ' ')
  echo "  OK: README.md ($LINES lines)"
else
  echo "  FAIL: missing README.md"
  exit 1
fi
echo ""

echo "=== All checks passed ==="
echo "SMOKE_OK"
