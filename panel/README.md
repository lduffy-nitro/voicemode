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

Hotkeys: ⌃⌥Space mic · ⌃⌥V show/hide · ⌃⌥, stop reading · ⌃⌥. stop + interrupt.

## Setup

```bash
uv sync                                  # VoiceMode venv (repo root)
(cd panel/brain && npm install)          # Agent SDK
panel/build.sh                           # → panel/build/VoicePanel.app (ad-hoc signed)
```

`~/.claude/commands/voice.md`:

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
