#!/usr/bin/env bash
# Links the always-on Go rules into ~/.claude/rules so every Claude Code session sees them.
# Re-run after cloning on a new machine. `git pull` in this repo updates the rules everywhere.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="$HOME/.claude/rules"
mkdir -p "$target_dir"

for rule in "$repo_dir"/rules/*.md; do
  name="$(basename "$rule")"
  dest="$target_dir/$name"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "Skipping $name: $dest exists and is not a symlink (back it up or remove it first)."
    continue
  fi
  ln -sfn "$rule" "$dest"
  echo "Linked $dest -> $rule"
done

echo
echo "Next, inside Claude Code:"
echo "  /plugin marketplace add osayiakoko/claude-go-api"
echo "  /plugin install go-api@osayi-claude"
