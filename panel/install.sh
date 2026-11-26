#!/bin/bash
# One-shot setup for VoiceMode + the floating voice panel (macOS).
#
#   git clone https://github.com/lduffy-nitro/voicemode ~/src/voicemode
#   ~/src/voicemode/panel/install.sh
#
# Then type /voice in any Claude Code session.
#
# Safe to re-run: it updates what's there and skips what's done. Run it again after `git pull`.
# Options:  --no-services   skip installing the local Whisper / Kokoro services
#           --uninstall     remove the /voice command and the panel's hooks (leaves VoiceMode installed)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # the voicemode checkout
PANEL="$ROOT/panel"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
COMMAND="$CLAUDE_DIR/commands/voice.md"
HOOK="$PANEL/bin/voice-inbox-hook"
SERVICES=1
UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --no-services) SERVICES=0 ;;
    --uninstall)   UNINSTALL=1 ;;
    -h|--help)     sed -n 2,12p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

backup() { [ -f "$1" ] && cp "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" || true; }

# Remove (or, with $1=add, add) the panel's hook on PostToolUse(*), Stop and UserPromptSubmit,
# leaving every other hook in settings.json alone.
edit_hooks() {
  local mode="$1" tmp
  mkdir -p "$CLAUDE_DIR"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS isn't valid JSON; fix it and re-run."
  tmp="$(mktemp)"
  jq --arg cmd "$HOOK" --arg mode "$mode" '
    def entry($ev): {hooks: [{type: "command", command: $cmd, timeout: 5}]}
                    + (if $ev == "PostToolUse" then {matcher: "*"} else {} end);
    def ours: (.command // "") | endswith("panel/bin/voice-inbox-hook");
    # drop copies of the hook matching $keep (stale checkout paths, or all of them), then empty groups
    def strip($keep): map(.hooks |= map(select((ours and .command != $keep) | not)))
                      | map(select((.hooks | length) > 0));
    def has_cmd: any(.[]; any(.hooks[]?; .command == $cmd));
    .hooks = (.hooks // {})
    | reduce ("PostToolUse", "Stop", "UserPromptSubmit") as $ev (.;
        .hooks[$ev] = ((.hooks[$ev] // [])
          | if $mode == "add" then strip($cmd) | (if has_cmd then . else . + [entry($ev)] end)
            else strip("") end)
        | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end)
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS" > "$tmp"
  if [ "$(jq -S -c . "$tmp")" = "$(jq -S -c . "$SETTINGS")" ]; then rm -f "$tmp"; return 1; fi
  backup "$SETTINGS"
  mv "$tmp" "$SETTINGS"
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  command -v jq >/dev/null || die "jq is needed to edit $SETTINGS (brew install jq)."
  bold "Removing the voice panel from Claude Code"
  if grep -qs "panel/bin/voice-panel" "$COMMAND"; then rm -f "$COMMAND"; ok "removed /voice ($COMMAND)"; else ok "/voice wasn't installed"; fi
  if edit_hooks remove; then ok "removed the hooks from $SETTINGS (backup saved next to it)"; else ok "no panel hooks in $SETTINGS"; fi
  echo; echo "VoiceMode itself, its services and this checkout are untouched."
  echo "To remove those too: uv tool uninstall voice-mode; voicemode service uninstall …; rm -rf $ROOT"
  exit 0
fi

# ---------------------------------------------------------------- prerequisites
bold "Checking prerequisites"
[ "$(uname -s)" = Darwin ] || die "The voice panel is macOS-only."
[ "$(uname -m)" = arm64 ] || warn "Not Apple Silicon: Kokoro/Whisper will be slow on Intel."
xcode-select -p >/dev/null 2>&1 || { xcode-select --install 2>/dev/null || true
  die "Xcode Command Line Tools are needed to build the panel. Finish the install dialog, then re-run this script."; }
ok "Xcode Command Line Tools"
command -v brew >/dev/null || die "Homebrew is needed: install it from https://brew.sh, then re-run this script."
need=()
for t in uv node jq ffmpeg; do command -v "$t" >/dev/null || need+=("$t"); done
if [ ${#need[@]} -gt 0 ]; then
  echo "    installing with Homebrew: ${need[*]}"
  brew install "${need[@]}"
fi
ok "uv, node, jq, ffmpeg"
command -v claude >/dev/null || die "Claude Code ('claude') isn't on PATH. Install it (https://claude.com/claude-code), log in once, then re-run."
ok "Claude Code ($(claude --version 2>/dev/null | head -1))"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node $NODE_MAJOR is too old; the panel needs Node 18+ (brew upgrade node)."

# ---------------------------------------------------------------- VoiceMode
bold "Installing VoiceMode from this checkout ($ROOT)"
uv tool install --force --editable "$ROOT" >/dev/null 2>&1 || uv tool install --force --editable "$ROOT"
BIN="$(uv tool dir --bin)"
export PATH="$BIN:$PATH"
command -v voicemode >/dev/null || die "voicemode didn't land on PATH ($BIN)."
ok "voicemode $(voicemode --version 2>/dev/null | awk '{print $NF}') (editable: 'git pull' updates it)"
uv tool update-shell >/dev/null 2>&1 || true   # makes sure $BIN is on PATH in new shells

# Register the MCP server for every project so the inline voice tools (converse) work too.
# (Checked from $HOME so a project-level .mcp.json, like this repo's, doesn't shadow the user entry.)
if (cd "$HOME" && claude mcp get voicemode 2>/dev/null) | grep -q "voicemode-mcp-launcher"; then
  ok "MCP server 'voicemode' already registered"
else
  claude mcp remove -s user voicemode >/dev/null 2>&1 || true
  claude mcp add -s user voicemode -- "$BIN/voicemode-mcp-launcher" >/dev/null
  ok "registered MCP server 'voicemode' (user scope)"
fi

# ---------------------------------------------------------------- voice services
if [ "$SERVICES" = 1 ]; then
  bold "Local voice services (Whisper = ears, Kokoro = voice)"
  up() { curl -s -m 2 -o /dev/null "$1"; }
  if up http://127.0.0.1:2022/; then ok "Whisper already running on :2022"
  else
    echo "    installing Whisper (downloads a speech model; a few minutes the first time)…"
    voicemode service install whisper
    voicemode service enable whisper >/dev/null 2>&1 || true
    voicemode service start whisper >/dev/null 2>&1 || true
    ok "Whisper installed"
  fi
  if up http://127.0.0.1:8880/v1/audio/voices; then ok "Kokoro already running on :8880"
  else
    echo "    installing Kokoro (downloads a voice model; a few minutes the first time)…"
    voicemode service install kokoro
    voicemode service enable kokoro >/dev/null 2>&1 || true
    voicemode service start kokoro >/dev/null 2>&1 || true
    ok "Kokoro installed (it can take ~30 s to come up after a start)"
  fi
else
  warn "skipped Whisper/Kokoro (--no-services); the panel expects them on :2022 and :8880"
fi

# ---------------------------------------------------------------- panel
bold "Building the voice panel"
( cd "$PANEL/brain" && npm ci --no-audit --no-fund --loglevel=error )
ok "brain dependencies (Claude Agent SDK)"
"$PANEL/build.sh" 2>&1 | sed 's/^/    /' | grep -v '^    \[' || true
[ -d "$PANEL/build/VoicePanel.app" ] || die "Build failed — see the output above."
ok "VoicePanel.app"

# ---------------------------------------------------------------- Claude Code wiring
bold "Wiring it into Claude Code"
mkdir -p "$(dirname "$COMMAND")"
NEW_CMD="$(cat <<EOF
---
description: Open the floating voice panel (forked from this session)
allowed-tools: Bash($PANEL/bin/voice-panel:*)
---
!\`$PANEL/bin/voice-panel \${CLAUDE_SESSION_ID}\`

Reply with one short line relaying the launcher output above. Do not do anything else.
EOF
)"
if [ -f "$COMMAND" ] && [ "$(cat "$COMMAND")" = "$NEW_CMD" ]; then ok "/voice command already up to date"
else
  backup "$COMMAND"
  printf '%s\n' "$NEW_CMD" > "$COMMAND"
  ok "/voice command → $COMMAND"
fi
if edit_hooks add; then ok "hooks added to $SETTINGS (previous version backed up next to it)"
else ok "hooks already in $SETTINGS"; fi

# ---------------------------------------------------------------- done
bold "Done"
cat <<EOF
    1. Start (or restart) Claude Code, then type:   /voice
    2. Allow the microphone when macOS asks. For "look at my screen", also allow
       VoicePanel under System Settings › Privacy & Security › Screen Recording.

    Hotkeys:  ⌃⌥Space mic · ⌃⌥M minimise · ⌃⌥V show/hide · ⌃⌥, stop reading · ⌃⌥. stop + interrupt
    Voice in the terminal instead:  ask Claude to "talk to me by voice" (the converse tool).

    Update:     cd $ROOT && git pull && panel/install.sh
    Check:      voicemode service status
    Uninstall:  panel/install.sh --uninstall
EOF
