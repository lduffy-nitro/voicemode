# Voice Panel (experimental, macOS)

A floating, always-on-top voice window for a Claude Code session, built on VoiceMode's
own ears and mouth. Open it from any session with `/voice`; it runs alongside the session
instead of blocking it, can see the screen, and can act.

```
 VoicePanel.app (Swift, floating NSPanel)
   ├─ ears   python -m voice_mode.listen capture --source mic   → heard log (partial / turn)
   ├─ mouth  python -m voice_mode.mouth say | retract           → heard log (saying / said)
   ├─ follows ~/.voicemode/logs/conversations/heard_YYYY-MM-DD.jsonl
   └─ brain  node brain/brain.mjs  (Agent SDK: forks the session, tools, screenshots)
```

- **Context:** the brain resumes the session with `forkSession`, and each turn reads what the
  main session appended to its transcript since.
- **Acting:** full Claude Code tools. A permission picker in the header (Ask / Accept edits /
  Auto / Bypass); prompts show in the panel and can be answered by voice ("yes" / "no").
- **Screen:** the eye toggle attaches a screenshot to every message; "look at this",
  "on my screen" etc. attach one automatically; the agent can also call `screenshot`.
- **Hand-off:** `send_to_main_session` queues to `~/.voice-panel/inbox/<session>.jsonl`;
  `bin/voice-inbox-hook` (PostToolUse / Stop / UserPromptSubmit) delivers it.
- **Echo:** `listen` never mutes, so speech heard while `mouth` is speaking (and 0.8 s after)
  is dropped. Headphones avoid the problem entirely.

Hotkeys: ⌃⌥Space mic · ⌃⌥M minimise to the header bar · ⌃⌥V show/hide · ⌃⌥, stop reading · ⌃⌥. stop + interrupt.

## Setup

One command (macOS, Apple Silicon recommended; needs Homebrew and Claude Code):

```bash
git clone https://github.com/lduffy-nitro/voicemode ~/src/voicemode
~/src/voicemode/panel/install.sh
```

Then type `/voice` in any Claude Code session.

`install.sh` is safe to re-run (do it after `git pull`). It:

1. installs `uv`, `node`, `jq` and `ffmpeg` with Homebrew if they're missing;
2. installs VoiceMode from this checkout (`uv tool install -e`) and registers its MCP server
   for all projects, so the inline `converse` voice tools work too;
3. installs and starts the local Whisper (:2022) and Kokoro (:8880) services
   (skip with `--no-services`);
4. installs the brain's dependencies and builds `panel/build/VoicePanel.app`;
5. writes `~/.claude/commands/voice.md` (the `/voice` command) and adds
   `panel/bin/voice-inbox-hook` to `PostToolUse` (matcher `*`), `Stop` and `UserPromptSubmit`
   in `~/.claude/settings.json`, leaving your other hooks alone and backing the file up first.

`panel/install.sh --uninstall` removes the command and the hooks again.

On first use macOS asks for the microphone. For "look at my screen", also allow VoicePanel
under System Settings › Privacy & Security › Screen Recording. Builds are ad-hoc signed
unless a "Voice Panel Local Signing" code-signing identity exists, so macOS may ask again
after a rebuild.

### Manual steps (what the installer does)

```bash
uv tool install -e .                     # VoiceMode from this checkout (repo root)
voicemode service install whisper && voicemode service install kokoro
(cd panel/brain && npm ci)               # Agent SDK
panel/build.sh                           # → panel/build/VoicePanel.app
```

`~/.claude/commands/voice.md` (use your checkout's path):

```markdown
---
description: Open the floating voice panel (forked from this session)
allowed-tools: Bash(~/src/voicemode/panel/bin/voice-panel:*)
---
!`~/src/voicemode/panel/bin/voice-panel ${CLAUDE_SESSION_ID}`

Reply with one short line relaying the launcher output above. Do not do anything else.
```

Hooks in `~/.claude/settings.json`: run `panel/bin/voice-inbox-hook` on `PostToolUse`
(matcher `*`), `Stop` and `UserPromptSubmit`.

`mouth` defaults to an mlx-audio Kokoro on :8890; the panel points it at VoiceMode's Kokoro
service (`VOICEMODE_MOUTH_KOKORO_URL=http://127.0.0.1:8880/v1`,
`VOICEMODE_MOUTH_KOKORO_MODEL=kokoro`) unless `voicemode.env` sets them.
