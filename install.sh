#!/usr/bin/env bash
# claude-statusline-bar installer
# Downloads statusline.sh into ~/.claude and wires it into settings.json.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/arielonoriaga/claude-statusline-bar/main"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPT_PATH="$CLAUDE_DIR/statusline.sh"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

bold "claude-statusline-bar installer"

command -v jq  >/dev/null || die "jq is required. Install it and re-run."
command -v curl >/dev/null || die "curl is required."

mkdir -p "$CLAUDE_DIR"

info "Downloading statusline.sh to $SCRIPT_PATH"
curl -fsSL "$REPO_RAW/statusline.sh" -o "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

if [ ! -f "$SETTINGS_PATH" ]; then
  info "Creating fresh settings.json"
  printf '{\n  "statusLine": {\n    "type": "command",\n    "command": "bash %s"\n  }\n}\n' "$SCRIPT_PATH" > "$SETTINGS_PATH"
else
  info "Merging statusLine into existing settings.json"
  tmp=$(mktemp)
  jq --arg cmd "bash $SCRIPT_PATH" \
    '.statusLine = {type: "command", command: $cmd}' \
    "$SETTINGS_PATH" > "$tmp"
  mv "$tmp" "$SETTINGS_PATH"
fi

bold "Done."
info "Restart Claude Code to activate."
