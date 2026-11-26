// Voice Panel brain: a forked Claude Code session driven by the floating panel.
//
// Protocol: newline-delimited JSON on stdin/stdout.
//   panel -> brain: {type:"user", text, screenshot?:bool}
//                   {type:"permission", id, allow:bool}
//                   {type:"interrupt"}
//                   {type:"mode", mode}           default | acceptEdits | auto | bypassPermissions
//   brain -> panel: {type:"ready"}  then {type:"forked", sessionId} on first turn
//                   {type:"say", text}            assistant text to speak + show
//                   {type:"tool", name, summary}  tool activity (shown, not spoken)
//                   {type:"permission_request", id, tool, summary}
//                   {type:"turn_end"}
//                   {type:"log", text} / {type:"error", message}
//
// Args: --session <main session id> --transcript <path> --cwd <dir> [--claude <path>]

import { query, tool, createSdkMcpServer } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const run = promisify(execFile);

// ---------- args ----------
const args = {};
for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
const MAIN_SESSION = args.session;
const TRANSCRIPT = args.transcript;
const CWD = args.cwd || os.homedir();
if (!MAIN_SESSION || !TRANSCRIPT) {
  emit({ type: "error", message: "brain needs --session and --transcript" });
  process.exit(2);
}

const HOME_DIR = path.join(os.homedir(), ".voice-panel");
const INBOX = path.join(HOME_DIR, "inbox", `${MAIN_SESSION}.jsonl`);
const SHOTS = path.join(HOME_DIR, "shots");
fs.mkdirSync(path.dirname(INBOX), { recursive: true });
fs.mkdirSync(SHOTS, { recursive: true });

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

// ---------- keeping up with the main session ----------
// The fork snapshots the main transcript at start. Each turn we read whatever the
// main session appended since, and hand the panel agent a compact digest.
let transcriptOffset = 0;
try { transcriptOffset = fs.statSync(TRANSCRIPT).size; } catch {}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => {
      if (b.type === "text") return b.text;
      if (b.type === "tool_use") return `[tool ${b.name}: ${JSON.stringify(b.input).slice(0, 160)}]`;
      if (b.type === "tool_result") {
        const t = typeof b.content === "string" ? b.content : textOf(b.content);
        return `[result: ${t.slice(0, 200)}]`;
      }
      return "";
    })
    .filter(Boolean)
    .join(" ");
}

function mainSessionDigest(maxChars = 6000) {
  let size;
  try { size = fs.statSync(TRANSCRIPT).size; } catch { return ""; }
  if (size <= transcriptOffset) return "";
  const fd = fs.openSync(TRANSCRIPT, "r");
  const buf = Buffer.alloc(size - transcriptOffset);
  fs.readSync(fd, buf, 0, buf.length, transcriptOffset);
  fs.closeSync(fd);
  const text = buf.toString("utf8");
  const lastNl = text.lastIndexOf("\n");
  if (lastNl < 0) return "";
  transcriptOffset += Buffer.byteLength(text.slice(0, lastNl + 1));
  const lines = [];
  for (const line of text.slice(0, lastNl).split("\n")) {
    try {
      const e = JSON.parse(line);
      if ((e.type !== "user" && e.type !== "assistant") || !e.message) continue;
      const t = textOf(e.message.content).trim();
      if (t) lines.push(`${e.type === "user" ? "USER/TOOL" : "MAIN CLAUDE"}: ${t}`);
    } catch {}
  }
  let digest = lines.join("\n");
  if (digest.length > maxChars) digest = "…(earlier activity trimmed)…\n" + digest.slice(-maxChars);
  return digest;
}

function mainSessionBusy() {
  try { return Date.now() - fs.statSync(TRANSCRIPT).mtimeMs < 20_000; } catch { return false; }
}

// ---------- screenshots ----------
async function captureScreen() {
  const file = path.join(SHOTS, `shot-${Date.now()}.png`);
  await run("/usr/sbin/screencapture", ["-x", "-t", "png", file]);
  await run("/usr/bin/sips", ["-Z", "1568", file], { maxBuffer: 1 << 20 });
  const data = fs.readFileSync(file).toString("base64");
  fs.unlink(file, () => {});
  return data;
}

// ---------- panel tools ----------
const panelTools = createSdkMcpServer({
  name: "panel",
  version: "1.0.0",
  tools: [
    tool(
      "screenshot",
      "Capture the user's current screen (main display) and look at it.",
      {},
      async () => {
        try {
          const data = await captureScreen();
          return { content: [{ type: "image", data, mimeType: "image/png" }] };
        } catch (e) {
          return { content: [{ type: "text", text: `Screenshot failed (Screen Recording permission for VoicePanel?): ${e.message}` }], isError: true };
        }
      }
    ),
    tool(
      "send_to_main_session",
      "Hand a task or note to the user's main Claude Code session (the one this panel was opened from). " +
        "It is delivered at the main session's next tool call, end of turn, or next user prompt. " +
        "Use this for work that belongs in the main session or would collide with what it is doing.",
      { message: z.string().describe("The instruction or note, written as a clear request to the main session.") },
      async ({ message }) => {
        fs.appendFileSync(INBOX, JSON.stringify({ ts: new Date().toISOString(), message }) + "\n");
        return { content: [{ type: "text", text: `Queued for the main session${mainSessionBusy() ? " (it is busy; it will see this at its next step)" : " (it looks idle; it will see this when the user next prompts it, or at its next step)"}.` }] };
      }
    ),
    tool(
      "main_session_status",
      "Check whether the main session is actively working right now.",
      {},
      async () => ({ content: [{ type: "text", text: mainSessionBusy() ? "Main session is busy (transcript updated in the last 20s)." : "Main session looks idle." }] })
    ),
  ],
});

// ---------- permissions ----------
let permSeq = 0;
const pendingPerms = new Map();

function summarizeInput(name, input) {
  if (input.command) return String(input.command).slice(0, 200);
  if (input.file_path) return String(input.file_path);
  if (input.url) return String(input.url);
  return JSON.stringify(input).slice(0, 200);
}

const canUseTool = (toolName, input, { signal }) =>
  new Promise((resolve) => {
    const id = String(++permSeq);
    pendingPerms.set(id, { resolve, input });
    emit({ type: "permission_request", id, tool: toolName, summary: summarizeInput(toolName, input) });
    signal?.addEventListener("abort", () => {
      if (pendingPerms.delete(id)) resolve({ behavior: "deny", message: "Aborted" });
    });
  });

// Guardrail: if the main session is mid-flight, file edits from the panel always ask.
const EDIT_TOOLS = "Edit|Write|MultiEdit|NotebookEdit";
const guardEdits = async () =>
  mainSessionBusy()
    ? { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: "Main session is busy; confirm before the panel edits files." } }
    : {};

// ---------- input stream ----------
const queue = [];
let wake = null;
function push(msg) { queue.push(msg); wake?.(); }
async function* userMessages() {
  for (;;) {
    while (queue.length) yield queue.shift();
    await new Promise((r) => (wake = r));
    wake = null;
  }
}

let q; // the Query, for interrupt()

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.type === "permission") {
    const p = pendingPerms.get(m.id);
    if (!p) return;
    pendingPerms.delete(m.id);
    p.resolve(m.allow ? { behavior: "allow", updatedInput: p.input } : { behavior: "deny", message: "The user declined this in the voice panel." });
  } else if (m.type === "mode") {
    const allowed = ["default", "acceptEdits", "auto", "bypassPermissions"];
    if (!allowed.includes(m.mode)) return;
    try {
      await q?.setPermissionMode(m.mode);
      emit({ type: "mode", mode: m.mode });
    } catch (e) {
      emit({ type: "error", message: `couldn't switch permission mode: ${e.message}` });
    }
  } else if (m.type === "interrupt") {
    try { await q?.interrupt(); } catch {}
  } else if (m.type === "user") {
    const content = [];
    const digest = mainSessionDigest();
    if (digest) content.push({ type: "text", text: `<main_session_update>\nSince you last checked, the main session did:\n${digest}\n</main_session_update>` });
    if (m.screenshot) {
      try {
        content.push({ type: "image", source: { type: "base64", media_type: "image/png", data: await captureScreen() } });
      } catch (e) {
        emit({ type: "log", text: `screenshot failed: ${e.message}` });
      }
    }
    content.push({ type: "text", text: m.text });
    push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null });
  }
});
rl.on("close", () => process.exit(0));

// ---------- run ----------
const SYSTEM_APPEND = `
You are now running as the user's VOICE PANEL: a floating voice companion forked from their main Claude Code session (id ${MAIN_SESSION}). The conversation above is the main session's history up to the fork; <main_session_update> blocks tell you what it has done since.

How to behave:
- Your text replies are spoken aloud by TTS. Keep them short and conversational: one to three sentences, no markdown, no code blocks, no file paths read character by character, no lists. Do not narrate tool use.
- The user's messages are speech-to-text transcripts and may contain recognition errors; infer intent.
- You can act: read files, run commands, edit code, and use mcp__panel__screenshot to see their screen when they refer to something visible ("this", "look at", "what's on screen").
- The main session may be working in parallel. Before editing files, call mcp__panel__main_session_status; if it is busy, prefer mcp__panel__send_to_main_session for work in its area rather than editing the same files.
- Use mcp__panel__send_to_main_session when the user says to tell / ask / hand something to "main" or "the other session".
`;

const options = {
  resume: MAIN_SESSION,
  forkSession: true,
  cwd: CWD,
  settingSources: ["user", "project", "local"],
  systemPrompt: { type: "preset", preset: "claude_code", append: SYSTEM_APPEND },
  mcpServers: { panel: panelTools },
  canUseTool,
  // Mode is chosen by the user in the panel (never by the agent itself).
  permissionMode: ["default", "acceptEdits", "auto", "bypassPermissions"].includes(args.mode) ? args.mode : "auto",
  allowDangerouslySkipPermissions: true, // lets the panel switch to Bypass later
  hooks: { PreToolUse: [{ matcher: EDIT_TOOLS, hooks: [guardEdits] }] },
  stderr: (d) => emit({ type: "log", text: String(d).trim().slice(0, 500) }),
};
if (args.claude) options.pathToClaudeCodeExecutable = args.claude;

q = query({ prompt: userMessages(), options });
emit({ type: "ready" }); // the session itself initialises on the first message

try {
  for await (const msg of q) {
    if (msg.type === "system" && msg.subtype === "init") {
      emit({ type: "forked", sessionId: msg.session_id });
    } else if (msg.type === "assistant" && msg.parent_tool_use_id == null) {
      for (const b of msg.message.content) {
        if (b.type === "text" && b.text.trim()) emit({ type: "say", text: b.text.trim() });
        else if (b.type === "tool_use") emit({ type: "tool", name: b.name.replace(/^mcp__panel__/, ""), summary: summarizeInput(b.name, b.input || {}) });
      }
    } else if (msg.type === "result") {
      if (msg.subtype !== "success") emit({ type: "error", message: `turn ended: ${msg.subtype}` });
      emit({ type: "turn_end" });
    }
  }
} catch (e) {
  emit({ type: "error", message: String(e?.message || e) });
  process.exit(1);
}
