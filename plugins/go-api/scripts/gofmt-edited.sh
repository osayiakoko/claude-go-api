#!/usr/bin/env bash
# Formats a .go file right after Claude writes or edits it.
# Reads the hook payload (JSON) on stdin and pulls out tool_input.file_path.
# Always exits 0 so a missing formatter never blocks Claude.

payload=$(cat)
file=$(printf '%s' "$payload" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')

case "$file" in
  *.go) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0

if command -v goimports >/dev/null 2>&1; then
  goimports -w "$file" >/dev/null 2>&1
elif command -v gofmt >/dev/null 2>&1; then
  gofmt -w "$file" >/dev/null 2>&1
fi
exit 0
