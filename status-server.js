const http = require("http"), fs = require("fs"), path = require("path"), os = require("os");
const DIR = path.join(os.homedir(), ".carapace");
const OC_DIR = path.join(os.homedir(), ".openclaw");
const TRACKER_PORT = 18795; // python project-tracker-server (legacy fallback)

// ============================================================================
// CARAPACE PROJECTS — MEMORY.md-backed project tracker
// ============================================================================
// Projects + workstreams live in a managed sentinel-marked block in
// ~/.openclaw/workspace/memory/MEMORY.md so the agent can naturally read
// + update them in conversation (BM25-indexed by openclaw, no cron lag,
// real-time iOS reflection). Replaces the old setup where a */2 cron
// synced ~/.openclaw/workspace/projects/tracker.json into
// ~/.carapace/carapace-project-tracker.json — that path stays as a
// no-op fallback for users still mid-migration but is no longer
// authoritative.
//
// Block format (between BEGIN/END markers):
//   ## Projects
//   ### <id> · <Name> · <emoji> <progress>%
//   <description paragraph>
//   **Focus:** <project focus prompt>
//   **Workstreams:**
//   - `<id>` · <name> · <emoji> <progress>% [· @<owner>] — <focus>
//
// Status emojis: 🟢 green · 🟡 yellow · 🔴 red · ⚪ idle
// Owner defaults to `main` when omitted (forward-compat for multi-agent).
const MEMORY_PATH = path.join(OC_DIR, "workspace", "memory", "MEMORY.md");
const IDENTITY_PATH = path.join(OC_DIR, "workspace", "IDENTITY.md");
const PROMPT_META_PATH = path.join(DIR, "project-prompt-meta.json");
const PROJECTS_BEGIN = "<!-- BEGIN CARAPACE PROJECTS";
const PROJECTS_END = "<!-- END CARAPACE PROJECTS";
const EMOJI_TO_STATUS = { "🟢": "green", "🟡": "yellow", "🔴": "red", "⚪": "idle" };
const STATUS_TO_EMOJI = { green: "🟢", yellow: "🟡", red: "🔴", idle: "⚪" };

function projectsExtractBlock(memoryText) {
  const begin = memoryText.indexOf(PROJECTS_BEGIN);
  if (begin === -1) return null;
  const beginEol = memoryText.indexOf("\n", begin);
  if (beginEol === -1) return null;
  const end = memoryText.indexOf(PROJECTS_END, beginEol);
  if (end === -1) return null;
  return memoryText.slice(beginEol + 1, end).replace(/\s+$/, "");
}

function projectsParseSection(text) {
  const lines = text.split("\n");
  if (!lines.length) return null;
  const headerMatch = lines[0].match(/^([^\s·]+)\s*·\s*(.+?)\s*·\s*(🟢|🟡|🔴|⚪)\s*(\d+)%\s*$/);
  if (!headerMatch) return null;
  const [, id, name, emoji, progressStr] = headerMatch;
  const project = {
    id: id.trim(),
    name: name.trim(),
    status: EMOJI_TO_STATUS[emoji] || "idle",
    progress: parseInt(progressStr, 10),
    description: "",
    divePrompt: "",
    workstreams: [],
  };
  let i = 1;
  const descLines = [];
  while (i < lines.length) {
    const ln = lines[i];
    if (ln.match(/^\*\*(Focus|Workstreams):\*\*/)) break;
    descLines.push(ln);
    i++;
  }
  project.description = descLines.join("\n").trim();
  while (i < lines.length) {
    const ln = lines[i];
    const focusMatch = ln.match(/^\*\*Focus:\*\*\s*(.*)$/);
    if (focusMatch) { project.divePrompt = focusMatch[1].trim(); i++; break; }
    if (ln.match(/^\*\*Workstreams:\*\*/)) break;
    i++;
  }
  while (i < lines.length) {
    const ln = lines[i];
    if (ln.match(/^\*\*Workstreams:\*\*/)) { i++; continue; }
    const bm = ln.match(/^- `([^`]+)`\s*·\s*(.+?)\s*·\s*(🟢|🟡|🔴|⚪)\s*(\d+)%\s*(?:·\s*@([\w-]+)\s*)?(?:—\s*(.*))?$/);
    if (bm) {
      const [, wid, wname, wemoji, wprogress, wowner, wfocus] = bm;
      project.workstreams.push({
        id: wid.trim(),
        name: wname.trim(),
        status: EMOJI_TO_STATUS[wemoji] || "idle",
        progress: parseInt(wprogress, 10),
        owner: wowner ? wowner.trim() : "main",
        focusPrompt: (wfocus || "").trim(),
      });
    }
    i++;
  }
  return project;
}

function projectsParseBlock(blockText) {
  if (!blockText) return [];
  const clean = blockText.replace(/<!--[\s\S]*?-->/g, "").trim();
  const sections = clean.split(/^### /m);
  const projects = [];
  for (let i = 1; i < sections.length; i++) {
    const proj = projectsParseSection(sections[i]);
    if (proj) projects.push(proj);
  }
  return projects;
}

function projectsFormatBlock(projects) {
  const lines = [
    "<!-- Format:",
    "### <id> · <Name> · <emoji> <progress>%",
    "<description paragraph>",
    "",
    "**Focus:** <project focus prompt>",
    "",
    "**Workstreams:**",
    "- `<id>` · <name> · <emoji> <progress>% [· @<owner>] — <focus>",
    "",
    "Emojis: 🟢 green · 🟡 yellow · 🔴 red · ⚪ idle",
    "-->",
    "## Projects",
    "",
  ];
  for (const p of projects) {
    const emoji = STATUS_TO_EMOJI[p.status] || "⚪";
    const progress = Number.isFinite(p.progress) ? p.progress : 0;
    lines.push(`### ${p.id} · ${p.name} · ${emoji} ${progress}%`);
    if (p.description) lines.push(p.description);
    lines.push("");
    lines.push(`**Focus:** ${p.divePrompt || ""}`);
    lines.push("");
    lines.push("**Workstreams:**");
    if (!p.workstreams || !p.workstreams.length) {
      lines.push("- _none yet_");
    } else {
      for (const w of p.workstreams) {
        const we = STATUS_TO_EMOJI[w.status] || "⚪";
        const wp = Number.isFinite(w.progress) ? w.progress : 0;
        const owner = w.owner && w.owner !== "main" ? ` · @${w.owner}` : "";
        const focus = w.focusPrompt ? ` — ${w.focusPrompt}` : "";
        lines.push(`- \`${w.id}\` · ${w.name} · ${we} ${wp}%${owner}${focus}`);
      }
    }
    lines.push("");
  }
  return lines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
}

function projectsRead() {
  let memory;
  try { memory = fs.readFileSync(MEMORY_PATH, "utf8"); }
  catch { return []; }
  const block = projectsExtractBlock(memory);
  if (!block) return [];
  return projectsParseBlock(block);
}

function projectsWrite(projects) {
  const begin = `${PROJECTS_BEGIN} (agent-maintained · iOS Projects view reads + writes here · do not edit between markers from outside) -->`;
  const end = `${PROJECTS_END} -->`;
  const newBlock = `${begin}\n${projectsFormatBlock(projects)}\n${end}\n`;
  fs.mkdirSync(path.dirname(MEMORY_PATH), { recursive: true });
  let memory;
  try { memory = fs.readFileSync(MEMORY_PATH, "utf8"); }
  catch { memory = ""; }
  let rebuilt;
  if (!memory) {
    rebuilt = newBlock;
  } else {
    const beginIdx = memory.indexOf(PROJECTS_BEGIN);
    const endIdx = memory.indexOf(PROJECTS_END);
    if (beginIdx !== -1 && endIdx !== -1 && beginIdx < endIdx) {
      const endLineEnd = memory.indexOf("\n", endIdx);
      const afterEnd = endLineEnd === -1 ? "" : memory.slice(endLineEnd + 1);
      const before = memory.slice(0, beginIdx).replace(/\n+$/, "");
      const after = afterEnd.replace(/^\n+/, "");
      rebuilt = (before ? before + "\n\n" : "") + newBlock + (after ? "\n" + after : "");
    } else {
      rebuilt = memory.replace(/\n+$/, "") + "\n\n" + newBlock;
    }
  }
  const tmp = `${MEMORY_PATH}.carapace-projects.tmp.${process.pid}`;
  fs.writeFileSync(tmp, rebuilt);
  fs.renameSync(tmp, MEMORY_PATH);
}

function projectsReadMeta() {
  try { return JSON.parse(fs.readFileSync(PROMPT_META_PATH, "utf8")); }
  catch { return {}; }
}
function projectsWriteMeta(meta) {
  fs.mkdirSync(path.dirname(PROMPT_META_PATH), { recursive: true });
  fs.writeFileSync(PROMPT_META_PATH, JSON.stringify(meta, null, 2));
}
function projectsBumpMeta(key) {
  const meta = projectsReadMeta();
  const cur = meta[key] || { version: 0, updatedAt: null };
  meta[key] = { version: cur.version + 1, updatedAt: new Date().toISOString() };
  projectsWriteMeta(meta);
  return meta[key];
}

function projectsBuildResponse() {
  const projects = projectsRead();
  const meta = projectsReadMeta();
  for (const p of projects) {
    const pm = meta[p.id];
    if (pm) { p.promptVersion = pm.version; p.promptUpdatedAt = pm.updatedAt; }
    for (const w of (p.workstreams || [])) {
      const wm = meta[`${p.id}:${w.id}`];
      if (wm) { w.promptVersion = wm.version; w.promptUpdatedAt = wm.updatedAt; }
    }
  }
  return { version: 1, updated: new Date().toISOString(), projects };
}

function projectsUpdateProjectPrompt(projectId, newPrompt) {
  const projects = projectsRead();
  const proj = projects.find(p => p.id === projectId);
  if (!proj) return { error: "project not found", status: 404 };
  proj.divePrompt = newPrompt || "";
  projectsWrite(projects);
  const m = projectsBumpMeta(projectId);
  return { ok: true, id: projectId, promptVersion: m.version, promptUpdatedAt: m.updatedAt };
}

function projectsUpdateWorkstreamPrompt(projectId, workstreamId, newPrompt) {
  const projects = projectsRead();
  const proj = projects.find(p => p.id === projectId);
  if (!proj) return { error: "project not found", status: 404 };
  const ws = (proj.workstreams || []).find(w => w.id === workstreamId);
  if (!ws) return { error: "workstream not found", status: 404 };
  ws.focusPrompt = newPrompt || "";
  projectsWrite(projects);
  const m = projectsBumpMeta(`${projectId}:${workstreamId}`);
  return { ok: true, id: projectId, wid: workstreamId, promptVersion: m.version, promptUpdatedAt: m.updatedAt };
}

function projectsDelete(projectId) {
  const projects = projectsRead();
  const idx = projects.findIndex(p => p.id === projectId);
  if (idx === -1) return { error: "project not found", status: 404 };
  projects.splice(idx, 1);
  projectsWrite(projects);
  const meta = projectsReadMeta();
  for (const k of Object.keys(meta)) {
    if (k === projectId || k.startsWith(`${projectId}:`)) delete meta[k];
  }
  projectsWriteMeta(meta);
  return { ok: true, deleted: projectId };
}

// One-shot migration. Runs on status-server startup. Idempotent — no-op
// when the PROJECTS block is already present in MEMORY.md.
function projectsMigrateOnStartup() {
  let memory;
  try { memory = fs.readFileSync(MEMORY_PATH, "utf8"); }
  catch { memory = ""; }
  if (memory.indexOf(PROJECTS_BEGIN) !== -1) return; // already migrated
  // Try the cron-synced copy first, fall back to openclaw's own tracker.
  const candidates = [
    path.join(DIR, "carapace-project-tracker.json"),
    path.join(OC_DIR, "workspace", "projects", "tracker.json"),
  ];
  let tracker = null;
  for (const c of candidates) {
    try {
      const data = JSON.parse(fs.readFileSync(c, "utf8"));
      if (data && Array.isArray(data.projects) && data.projects.length) {
        tracker = data; break;
      }
    } catch {}
  }
  if (!tracker) return; // nothing to migrate
  const legacyProjects = tracker.projects.map(p => ({
    id: p.id,
    name: p.name || p.id,
    status: p.status || "idle",
    progress: Number.isFinite(p.progress) ? p.progress : 0,
    description: p.description || "",
    divePrompt: p.divePrompt || "",
    workstreams: (p.workstreams || []).map(w => ({
      id: w.id,
      name: w.name || w.id,
      status: w.status || "idle",
      progress: Number.isFinite(w.progress) ? w.progress : 0,
      owner: w.owner || "main",
      focusPrompt: w.focusPrompt || "",
    })),
  }));
  try {
    projectsWrite(legacyProjects);
    console.log(`[projects] migrated ${legacyProjects.length} project(s) from tracker.json → MEMORY.md`);
  } catch (e) {
    console.error(`[projects] migration failed: ${e.message}`);
  }
}
projectsMigrateOnStartup();

// Fallback: write prompt directly to the status-server's tracker file when the
// Python tracker server isn't running (e.g. Linux headless installs).
function writePromptLocally(pathname, body, res) {
  try {
    const m = pathname.match(/^\/projects\/([^/]+)\/(?:workstreams\/([^/]+)\/)?prompt\/?$/);
    if (!m) {
      res.writeHead(400, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ error: "bad path" }));
      return;
    }
    const pid = decodeURIComponent(m[1]);
    const wid = m[2] ? decodeURIComponent(m[2]) : null;
    const payload = JSON.parse(body || "{}");
    const fp = path.join(DIR, "carapace-project-tracker.json");
    const data = JSON.parse(fs.readFileSync(fp, "utf8"));
    const proj = (data.projects || []).find(p => p.id === pid);
    if (!proj) {
      res.writeHead(404, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ error: "project not found" }));
      return;
    }
    const now = new Date().toISOString();
    if (wid) {
      const ws = (proj.workstreams || []).find(w => w.id === wid);
      if (!ws) {
        res.writeHead(404, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
        res.end(JSON.stringify({ error: "workstream not found" }));
        return;
      }
      if ("focusPrompt" in payload) ws.focusPrompt = payload.focusPrompt;
      ws.promptVersion = (ws.promptVersion || 0) + 1;
      ws.promptUpdatedAt = now;
      data.updated = now;
      fs.writeFileSync(fp, JSON.stringify(data));
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ ok: true, id: pid, wid, promptVersion: ws.promptVersion, promptUpdatedAt: now }));
    } else {
      if ("divePrompt" in payload) proj.divePrompt = payload.divePrompt;
      proj.promptVersion = (proj.promptVersion || 0) + 1;
      proj.promptUpdatedAt = now;
      data.updated = now;
      fs.writeFileSync(fp, JSON.stringify(data));
      res.writeHead(200, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ ok: true, id: pid, promptVersion: proj.promptVersion, promptUpdatedAt: now }));
    }
  } catch(e) {
    res.writeHead(500, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
    res.end(JSON.stringify({ error: e.message }));
  }
}

// Proxy a request body to the local python tracker server and forward the response.
// Falls back to a direct file write if the tracker isn't running (Linux headless).
function proxyToTracker(method, pathname, body, res) {
  const opts = {
    hostname: "127.0.0.1",
    port: TRACKER_PORT,
    path: pathname,
    method,
    headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body || "") }
  };
  const proxyReq = http.request(opts, (proxyRes) => {
    let chunks = "";
    proxyRes.on("data", d => { chunks += d; });
    proxyRes.on("end", () => {
      res.writeHead(proxyRes.statusCode || 502, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(chunks || "{}");
    });
  });
  proxyReq.on("error", (err) => {
    // Tracker unreachable — fall back to direct status-server write (Linux path).
    writePromptLocally(pathname, body, res);
  });
  if (body) proxyReq.write(body);
  proxyReq.end();
}

function loadHistory(limit, token, agent) {
  try {
    // Verify token if gateway has one configured
    if (token) {
      try {
        const cfg = JSON.parse(fs.readFileSync(path.join(OC_DIR, "openclaw.json"), "utf8"));
        const gwToken = cfg && cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token;
        if (gwToken && token !== gwToken) {
          return { error: "Unauthorized", messages: [], count: 0 };
        }
      } catch(e) {}
    }

    const agentName = (agent && /^[a-zA-Z0-9_-]+$/.test(agent)) ? agent : "main";
    const sessDir = path.join(OC_DIR, "agents", agentName, "sessions");
    if (!fs.existsSync(sessDir)) return { messages: [], count: 0 };

    // Use sessions.json to find the canonical main session — avoids picking up subagent sessions.
    //
    // IMPORTANT: OpenClaw's index can drift — `sessionId` rotates to a UUID
    // that hasn't been written as a file yet, while `sessionFile` still
    // points to the real transcript. Prefer `sessionFile` when present, fall
    // back to `sessionId + ".jsonl"`, then mtime. Without this the fallback
    // lands on cron/subagent files and wipes main's history from the UI.
    let targetFile = null;
    try {
      const sessionsIndex = JSON.parse(fs.readFileSync(path.join(sessDir, "sessions.json"), "utf8"));
      const mainKey = `agent:${agentName}:main`;
      const entry = sessionsIndex[mainKey];
      if (entry) {
        if (entry.sessionFile) {
          const name = path.basename(entry.sessionFile);
          if (fs.existsSync(path.join(sessDir, name))) {
            targetFile = name;
          }
        }
        if (!targetFile && entry.sessionId) {
          const candidate = entry.sessionId + ".jsonl";
          if (fs.existsSync(path.join(sessDir, candidate))) {
            targetFile = candidate;
          }
        }
      }
    } catch(e) {}

    // Fallback: most recently modified file (excluding subagent sessions if possible)
    if (!targetFile) {
      const files = fs.readdirSync(sessDir)
        .filter(f => f.endsWith(".jsonl") && f !== "sessions.json")
        .map(f => ({ f, mtime: fs.statSync(path.join(sessDir, f)).mtime }))
        .sort((a, b) => b.mtime - a.mtime);
      if (!files.length) return { messages: [], count: 0 };
      targetFile = files[0].f;
    }

    const lines = fs.readFileSync(path.join(sessDir, targetFile), "utf8").split("\n").filter(Boolean);
    const messages = [];

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        if (entry.type !== "message") continue;
        const msg = entry.message;
        if (!msg || !msg.role) continue;
        if (!["user", "assistant"].includes(msg.role)) continue;

        let text = "";
        if (typeof msg.content === "string") {
          text = msg.content;
        } else if (Array.isArray(msg.content)) {
          text = msg.content.filter(c => c.type === "text").map(c => c.text).join("");
        }

        // Strip noise (same filters as Mac StatusServer.swift)
        text = text.replace(/<final>/g, "").replace(/<\/final>/g, "").trim();
        if (!text) continue;
        if (text === "HEARTBEAT_OK" || text === "NO_REPLY") continue;
        if (text.includes("Read HEARTBEAT.md if it exists")) continue;
        if (text.startsWith("Exec completed")) continue;
        if (text.startsWith("System:")) continue;
        if (text.match(/^\[\d{4}-\d{2}-\d{2}.*\] Exec (completed|started|failed)/)) continue;
        if (text.includes("[system event]")) continue;
        if (text.includes("openclaw system event")) continue;
        if (text.startsWith("HEARTBEAT_OK")) continue;
        if (text.startsWith("[[reply_to")) continue;
        if (text.startsWith("[[ reply_to")) continue;
        // Filter inter-session/subagent completion events injected as user messages
        if (text.includes("BEGIN_OPENCLAW_INTERNAL_CONTEXT")) continue;
        if (text.includes("Inter-session message")) continue;
        if (text.includes("[Internal task completion event]")) continue;
        if (text.includes("Continue where you left off. The previous model attempt failed or timed out")) continue;
        if (text.includes("previous model attempt failed or timed out")) continue;
        if (text.includes("HEARTBEAT_OK")) continue;
        if (text.includes("Handle the result internally")) continue;
        if (text.includes("System (untrusted)")) continue;
        if (text.includes("Exec completed")) continue;
        if (text.includes("openclaw doctor")) continue;
        if (text.includes("async command you ran earlier")) continue;
        if (text.includes("Current time:") && text.includes("UTC")) continue;
        if (text.includes("Tracker is running")) continue;
        if (text.includes("spawn a refresh")) continue;
        if (text.includes("I'll spawn")) continue;
        if (text.includes("queue is empty")) continue;
        if (text.includes("Do not relay it to the user")) continue;
        if (text.startsWith("An async command")) continue;
        if (msg.role === "user" && text.includes("System (untrusted)")) continue;
        // Strip openclaw-tui metadata prefix from user messages
        if (msg.role === "user" && text.includes("Sender (untrusted metadata)")) {
          const match = text.match(/\[.*?\]\s+([\s\S]+)$/);
          if (match) text = match[1].trim();
          else continue;
        }
        if (!text) continue;

        messages.push({
          role: msg.role,
          content: text,
          timestamp: entry.timestamp ? String(entry.timestamp) : ""
        });
      } catch(e) {}
    }

    const result = messages.slice(-limit);
    return { messages: result, count: result.length };
  } catch(e) { return { messages: [], count: 0 }; }
}

function extractBearer(req) {
  const authLine = req.split("\r\n").find(l => l.toLowerCase().startsWith("authorization:"));
  if (!authLine) return null;
  const parts = authLine.split("Bearer ");
  return parts.length > 1 ? parts[1].trim() : null;
}

const fileMap = {
  "/projects": "carapace-project-tracker.json",
  "/tracker": "carapace-project-tracker.json",
  "/cron": "carapace-cron-tracker.json"
};

// Check if user has paid tier (reads ~/.carapace/tier.json)
function isTierPaid() {
  try {
    const tierFile = path.join(DIR, "tier.json");
    if (!fs.existsSync(tierFile)) return true; // No tier file = Linux headless = always full access
    const data = JSON.parse(fs.readFileSync(tierFile, "utf8"));
    return data.tier && data.tier !== "free";
  } catch { return true; }
}
const EMPTY_PROJECTS = JSON.stringify({version:1,updated:"",projects:[]});
const EMPTY_CRON = JSON.stringify({version:1,updated:"",jobs:[]});
const EMPTY_AGENTS = JSON.stringify({agents:{},updated:""});

/// Derive a short nickname from OpenClaw's spawn label
/// (e.g. "research-ai-wearables" → "Research AI"). Mirror of the
/// helper in carapace-mac/Resources/status-server.js — keep them
/// in sync (this file is what the curl-bash installer pulls).
function deriveSubagentNickname(label, fallbackId) {
  if (!label || typeof label !== "string") return `Subagent ${fallbackId}`;
  const segments = label.split("-").filter(Boolean).slice(0, 2);
  if (segments.length === 0) return `Subagent ${fallbackId}`;
  return segments
    .map(s => s.charAt(0).toUpperCase() + s.slice(1).toLowerCase())
    .join(" ");
}

/// Pick an emoji for a subagent by keyword-matching its spawn label.
function deriveSubagentEmoji(label) {
  if (!label) return "🌱";
  const lower = label.toLowerCase();
  const map = [
    ["research", "🔍"], ["analy", "📊"], ["audit", "🔎"],
    ["strategy", "🎯"], ["plan", "🗺"], ["roadmap", "🗺"],
    ["scrap", "🕷"], ["extract", "⛏"], ["fetch", "📥"],
    ["bootstrap", "🚀"], ["launch", "🚀"], ["deploy", "🚀"],
    ["announce", "📢"], ["broadcast", "📡"],
    ["screenshot", "📸"], ["image", "🖼"], ["video", "🎥"],
    ["bot", "🤖"], ["agent", "🤖"],
    ["vision", "👁"], ["see", "👁"],
    ["summar", "📝"], ["digest", "📝"], ["transcrib", "📝"],
    ["email", "✉️"], ["mail", "✉️"], ["message", "💬"], ["chat", "💬"],
    ["review", "✅"], ["approve", "✅"],
    ["bug", "🐛"], ["fix", "🔧"], ["repair", "🔧"], ["patch", "🩹"],
    ["test", "🧪"], ["benchmark", "⏱"],
    ["security", "🔒"], ["auth", "🔐"], ["lock", "🔒"],
    ["design", "🎨"], ["color", "🎨"], ["theme", "🎨"],
    ["data", "🗄"], ["db", "🗄"], ["sql", "🗄"],
    ["report", "📋"], ["summary", "📋"],
    ["compet", "🏁"],
    ["reject", "❌"], ["error", "⚠️"], ["fail", "⚠️"],
    ["aso", "📈"], ["growth", "📈"], ["metric", "📈"],
    ["multiuser", "👥"], ["multi", "👥"], ["team", "👥"],
    ["user", "👤"], ["account", "👤"],
    ["admin", "⚙"], ["config", "⚙"], ["setting", "⚙"],
    ["code", "💻"], ["refactor", "💻"], ["script", "💻"],
    ["doc", "📄"], ["readme", "📄"], ["spec", "📄"],
    ["money", "💰"], ["price", "💰"], ["cost", "💰"], ["bill", "💰"],
    ["health", "🩺"], ["medical", "🩺"],
    ["project", "📁"], ["tracker", "📌"], ["task", "✓"],
    ["wedding", "💍"], ["calendar", "📅"], ["note", "🗒"],
    ["sticker", "🏷"], ["frame", "🖼"], ["camera", "📷"],
    ["voice", "🎙"], ["audio", "🔊"], ["sound", "🔊"],
    ["map", "🗺"], ["nav", "🧭"], ["weather", "☀"],
  ];
  for (const [kw, emoji] of map) {
    if (lower.includes(kw)) return emoji;
  }
  return "🌱";
}

/// Resolve an agent's workspace directory. OpenClaw uses one of:
///   1. Explicit `workspace` field in agents.list[]
///   2. Default `~/.openclaw/workspace-<id>` for non-main
///   3. `~/.openclaw/workspace` for main
function resolveAgentWorkspace(agentId, regEntry) {
  if (regEntry && typeof regEntry.workspace === "string" && regEntry.workspace.length > 0) {
    return regEntry.workspace;
  }
  if (agentId === "main") {
    return path.join(OC_DIR, "workspace");
  }
  return path.join(OC_DIR, `workspace-${agentId}`);
}

/// Parse an agent's IDENTITY.md (the file the agent itself fills in
/// during bootstrap) for { name, emoji, creature }. Returns nil
/// values when missing or still in template state.
function parseAgentIdentityMd(workspaceDir) {
  try {
    const file = path.join(workspaceDir, "IDENTITY.md");
    if (!fs.existsSync(file)) return null;
    const text = fs.readFileSync(file, "utf8");
    const grab = (label) => {
      const re = new RegExp("^[\\-\\*]\\s*\\*\\*" + label + ":\\*\\*\\s*(.*?)\\s*$", "im");
      const m = text.match(re);
      if (!m) return null;
      const v = m[1].trim();
      if (!v || /^_.*_$/.test(v) || v.startsWith("_(")) return null;
      return v;
    };
    const name = grab("Name");
    const emoji = grab("Emoji");
    const creature = grab("Creature");
    if (!name && !emoji) return null;
    return { name, emoji, creature };
  } catch { return null; }
}

/// Resolve effective identity:
///   1. Per-agent IDENTITY.md (agent's own bootstrap)
///   2. agents.list[].identity in openclaw.json
///   3. null
function resolveAgentIdentity(agentId, registeredAgents) {
  const reg = (registeredAgents || []).find(a => a && a.id === agentId);
  const workspace = resolveAgentWorkspace(agentId, reg);
  const fromMd = parseAgentIdentityMd(workspace);
  if (fromMd) return fromMd;
  if (reg && reg.identity && (reg.identity.name || reg.identity.emoji)) {
    return reg.identity;
  }
  return null;
}

/// Read every agent registered in ~/.openclaw/openclaw.json. This is
/// the canonical list — agents listed here exist whether or not
/// they've ever started a session. Used by getLiveAgentStatus and
/// the /sessions endpoint to surface registered-but-idle agents so
/// the iOS spinal map shows the full topology, not just agents that
/// happened to run recently.
function getRegisteredAgents() {
  try {
    const cfgPath = path.join(OC_DIR, "openclaw.json");
    if (!fs.existsSync(cfgPath)) return [];
    const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    return Array.isArray(cfg?.agents?.list) ? cfg.agents.list : [];
  } catch { return []; }
}

/// Build live agent status from OpenClaw session files
function getLiveAgentStatus() {
  try {
    const agentsRoot = path.join(OC_DIR, "agents");
    if (!fs.existsSync(agentsRoot)) return buildFallbackStatus("idle", "No agents directory");

    const agents = {};
    const registered = getRegisteredAgents();
    const agentDirs = fs.readdirSync(agentsRoot).filter(a => {
      try { return fs.statSync(path.join(agentsRoot, a)).isDirectory(); } catch { return false; }
    });

    for (const agent of agentDirs) {
      const sessDir = path.join(agentsRoot, agent, "sessions");
      if (!fs.existsSync(sessDir)) continue;

      // Find sessions from the index
      const indexPath = path.join(sessDir, "sessions.json");
      if (!fs.existsSync(indexPath)) continue;

      const index = JSON.parse(fs.readFileSync(indexPath, "utf8"));

      for (const [sessionKey, entry] of Object.entries(index)) {
        const isSubagent = sessionKey.includes(":subagent:");
        const agentId = isSubagent ? sessionKey.split(":subagent:")[1]?.slice(0, 8) || "sub" : agent;
        const updatedAt = entry.updatedAt || 0;
        const ageMs = Date.now() - updatedAt;

        const isRunning = entry.status === "running";
        const twoHours = 2 * 60 * 60 * 1000;

        if (!isSubagent) {
          // Only track the canonical main session (agent:<name>:main)
          // Ignore heartbeat, vision, cron, openai sub-sessions to avoid overwriting status
          const canonicalKey = `agent:${agent}:main`;
          if (sessionKey !== canonicalKey) continue;
          // Top-level agent session: show if active in last 30 min
          if (ageMs > 30 * 60 * 1000) continue;
          // Effective identity comes from per-agent IDENTITY.md first,
          // then openclaw.json identity, then a title-cased fallback.
          const ident = resolveAgentIdentity(agent, registered);
          const fallbackLabel = agent === "main" ? "Main" :
            agent.replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase());
          const agentLabel = (ident && ident.name) || fallbackLabel;
          const agentKey = agent === "main" ? "main" : agent;
          const node = {
            name: agentLabel,
            status: isRunning ? "active" : "idle",
            detail: isRunning ? "Processing" : "Ready",
            updated: new Date(updatedAt).toLocaleTimeString()
          };
          if (ident && ident.emoji) node.emoji = ident.emoji;
          agents[agentKey] = node;
        } else if (isSubagent) {
          // 5-min visibility window: keep the subagent on the spinal
          // map for 5 min after its last activity (idle = greyed by
          // iOS), then drop. Per Mike's spec.
          const fiveMinutes = 5 * 60 * 1000;
          if (!isRunning && ageMs > fiveMinutes) continue;
          if (isRunning && ageMs > 24 * 60 * 60 * 1000) continue;

          // Parent — prefer OpenClaw's explicit `spawnedBy` field,
          // fall back to session-key parsing, then to the iterating
          // directory.
          const spawnerFromSpawnedBy = (typeof entry.spawnedBy === "string")
            ? entry.spawnedBy.split(":")[1]
            : null;
          const spawnerFromKey = sessionKey.split(":")[1];
          const parent = spawnerFromSpawnedBy || spawnerFromKey || agent || "main";

          // Nickname + emoji from OpenClaw's spawn label.
          const label = entry.label || null;
          const nickname = deriveSubagentNickname(label, agentId);
          const emoji = deriveSubagentEmoji(label);

          agents[agentId] = {
            name: nickname,
            status: isRunning ? "active" : "idle",
            detail: label
              ? `${label} · spawned by ${parent}`
              : (entry.lastChannel || "isolated task"),
            parent: parent,
            emoji: emoji,
            updated: new Date(updatedAt).toLocaleTimeString()
          };
        }
      }
    }

    if (!agents["main"]) {
      agents["main"] = { name: "Main", status: "idle", detail: "Ready", updated: new Date().toLocaleTimeString() };
    }

    // Surface every registered-but-idle agent from openclaw.json so
    // the iOS spinal map shows ALL agents (per Mike's spec: "All true
    // agents must show in the spinal map even when idle"). Live
    // session data above takes precedence.
    //
    // Identity flows through resolveAgentIdentity which prefers the
    // agent's own IDENTITY.md over openclaw.json config.
    const nowStr = new Date().toLocaleTimeString();
    for (const reg of registered) {
      const id = reg && reg.id;
      if (!id) continue;
      if (agents[id]) continue;  // live data wins
      const ident = resolveAgentIdentity(id, registered);
      const rawName = (ident && ident.name) || reg.name || (id === "main" ? "Main" : id);
      const niceName = rawName.charAt(0).toUpperCase() + rawName.slice(1);
      const node = {
        name: niceName,
        status: "idle",
        detail: "Ready",
        updated: nowStr
      };
      if (ident && ident.emoji) node.emoji = ident.emoji;
      agents[id] = node;
    }

    return { agents, updated: new Date().toLocaleTimeString() };
  } catch(e) {
    return buildFallbackStatus("idle", "Status unavailable");
  }
}

function buildFallbackStatus(status, detail) {
  return {
    agents: { main: { name: "Main", status, detail, updated: new Date().toLocaleTimeString() } },
    updated: new Date().toLocaleTimeString()
  };
}

// ============================================================================
// SSE — real-time push for iOS dashboard views
// ============================================================================
// Replaces per-view polling timers. iOS opens ONE long-lived connection to
// /events; on every relevant file change the server pushes a tiny signal
// frame and iOS re-fetches authoritative data from the existing GET
// endpoints. Failure modes:
//   • iOS app backgrounds → URLSession kills the stream → SSEClient
//     reconnects on next foreground (app code's job).
//   • SSE never establishes → iOS falls back to a 30s polling timer
//     per view (app code's job).
//   • Many rapid file writes (e.g. a chat session jsonl getting appended
//     during a streaming reply) → debounced 200-500ms so we don't drown
//     iOS in re-fetches.
// Auth: optional bearer token in Authorization header. Validated against
// the gateway token in openclaw.json — same model as every other endpoint.

// ── IDENTITY parsing ─────────────────────────────────────────────
// IDENTITY.md is a freeform markdown file the agent fills in during
// the first-light bootstrap (Name, Creature, Vibe, Emoji). Format
// isn't strictly defined — model writes whatever feels natural — so
// the parser is intentionally liberal:
//   * matches `Name: …`, `**Name:** …`, `- Name: …`, `# Name`, etc.
//   * case-insensitive field names
//   * trims whitespace, strips surrounding markdown like *italics*
//   * empty / unfilled fields → null (template state vs filled state)
function parseIdentityMd(text) {
  const fields = ["name", "creature", "vibe", "emoji"];
  const out = { name: null, creature: null, vibe: null, emoji: null, raw: text };
  for (const field of fields) {
    // Match "Name: value" with optional bold/italic/list markers.
    const re = new RegExp(
      `^\\s*(?:[-*]\\s+)?(?:\\*\\*)?(?:_)?${field}(?:_)?(?:\\*\\*)?\\s*:\\s*(.+?)\\s*$`,
      "im"
    );
    const m = text.match(re);
    if (m && m[1]) {
      let v = m[1].trim();
      // Strip surrounding markdown emphasis (*foo*, **foo**, _foo_)
      v = v.replace(/^[*_]+|[*_]+$/g, "").trim();
      // Skip placeholders/template values
      if (v && !/^(_+|\.\.\.|todo|tbd|\[.*\])$/i.test(v)) {
        out[field] = v;
      }
    }
  }
  return out;
}

function readIdentity() {
  try {
    const text = fs.readFileSync(IDENTITY_PATH, "utf8");
    return parseIdentityMd(text);
  } catch {
    return { name: null, creature: null, vibe: null, emoji: null, raw: "" };
  }
}

const SSE_CLIENTS = new Set();
const SSE_HEARTBEAT_MS = 30000; // every 30s, send a keep-alive comment
const SSE_MAX_CLIENTS = 50;     // safety cap; one Mac + one iPhone is the norm

function sseValidateToken(req) {
  // Same logic loadHistory uses — if the gateway has a configured token,
  // require Bearer match; otherwise any caller is accepted (loopback).
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(OC_DIR, "openclaw.json"), "utf8"));
    const gwToken = cfg && cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token;
    if (!gwToken) return true;
    const auth = (req.headers["authorization"] || "").trim();
    const provided = auth.startsWith("Bearer ") ? auth.slice(7).trim() : auth;
    return provided === gwToken;
  } catch { return true; } // fail-open if config unreadable (rare)
}

function sseBroadcast(eventType, payload = {}) {
  const frame = `event: ${eventType}\ndata: ${JSON.stringify({ ...payload, ts: Date.now() })}\n\n`;
  for (const client of SSE_CLIENTS) {
    try { client.write(frame); }
    catch { SSE_CLIENTS.delete(client); }
  }
}

function sseDebounce(fn, ms) {
  let timer = null;
  return () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { timer = null; fn(); }, ms);
  };
}

const sseProjectsChanged = sseDebounce(() => sseBroadcast("projects.updated"), 200);
const sseCronChanged     = sseDebounce(() => sseBroadcast("cron.updated"), 200);
const sseAgentsChanged   = sseDebounce(() => sseBroadcast("agents.updated"), 500);
// history.updated fires only when a session jsonl is appended (a new
// chat message landed). agents.updated also fires for that case AND
// for sessions.json metadata changes — iOS ChatView observes
// historyUpdated, AgentsView observes agentsUpdated, both update
// in real time without one stomping on the other.
const sseHistoryChanged  = sseDebounce(() => sseBroadcast("history.updated"), 300);
// Identity changes are RARE (typically once per install during the
// first-light bootstrap). Short debounce because the agent writes
// IDENTITY.md as a single edit, not a streaming append.
const sseIdentityChanged = sseDebounce(() => sseBroadcast("identity.updated"), 200);

// File watchers — wrapped in try/catch because the watched path might not
// exist yet on a fresh install (will be created later by the agent or by
// a sync). When that happens we defer + retry on a 5s tick until the file
// appears, then attach the watcher and stop polling.
function sseWatchFile(filePath, onChange) {
  let watcher = null;
  function attach() {
    if (watcher) return;
    try {
      watcher = fs.watch(filePath, { persistent: true }, onChange);
      watcher.on("error", () => { try { watcher.close(); } catch {} watcher = null; setTimeout(attach, 5000); });
    } catch {
      setTimeout(attach, 5000);
    }
  }
  attach();
}

function sseWatchDirRecursive(dirPath, onJsonl, onSessionsJson) {
  let watcher = null;
  function attach() {
    if (watcher) return;
    if (!fs.existsSync(dirPath)) { setTimeout(attach, 5000); return; }
    try {
      // recursive: true is supported on macOS + Linux (kernel 2.6.13+).
      // Subdivide events by filename so jsonl appends → history.updated
      // (iOS ChatView re-fetches /history) and sessions.json changes →
      // agents.updated only (iOS AgentsView re-fetches /status).
      watcher = fs.watch(dirPath, { persistent: true, recursive: true }, (event, filename) => {
        if (!filename) return;
        if (filename.endsWith(".jsonl")) {
          onJsonl();        // history.updated (and agents.updated as a side effect)
          onSessionsJson(); // because session activity also moved
        } else if (filename.endsWith("sessions.json")) {
          onSessionsJson(); // agents.updated only
        }
      });
      watcher.on("error", () => { try { watcher.close(); } catch {} watcher = null; setTimeout(attach, 5000); });
    } catch {
      setTimeout(attach, 5000);
    }
  }
  attach();
}

sseWatchFile(MEMORY_PATH, sseProjectsChanged);
sseWatchFile(path.join(DIR, "carapace-cron-tracker.json"), sseCronChanged);
sseWatchFile(IDENTITY_PATH, sseIdentityChanged);
sseWatchDirRecursive(path.join(OC_DIR, "agents"), sseHistoryChanged, sseAgentsChanged);

// Heartbeat — keeps NAT/proxy/load-balancer mappings warm and lets iOS
// detect dead connections via TCP reset rather than waiting for a
// keepalive timeout.
setInterval(() => {
  for (const client of SSE_CLIENTS) {
    try { client.write(": heartbeat\n\n"); }
    catch { SSE_CLIENTS.delete(client); }
  }
}, SSE_HEARTBEAT_MS).unref(); // .unref so this interval doesn't block process exit

http.createServer((req, res) => {
  let body = "";
  req.on("data", d => { body += d; });
  req.on("end", () => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Content-Type", "application/json");
    if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

    const rawPath = req.url || "/";
    const p = rawPath.split("?")[0];
    const qs = new URLSearchParams(rawPath.includes("?") ? rawPath.split("?")[1] : "");
    const limit = parseInt(qs.get("limit") || "50");
    const token = (req.headers["authorization"] || "").replace("Bearer ", "").trim() || null;

    if (p === "/health") { res.end(JSON.stringify({ ok: true })); return; }

    // SSE — long-lived event stream. Sends real-time signals when
    // server-side data changes (projects, cron, agents) so iOS can
    // re-fetch immediately instead of polling. See SSE comment block
    // above for full design notes.
    if (p === "/events") {
      if (!sseValidateToken(req)) {
        res.writeHead(401, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "invalid token" }));
        return;
      }
      if (SSE_CLIENTS.size >= SSE_MAX_CLIENTS) {
        res.writeHead(503, { "Content-Type": "application/json", "Retry-After": "30" });
        res.end(JSON.stringify({ error: "too many SSE clients" }));
        return;
      }
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no", // disable any reverse-proxy buffering
        "Access-Control-Allow-Origin": "*",
      });
      // Initial frame so clients know the connection is alive + can render
      // a "connected" UI state. Includes the server's idea of what events
      // exist so the client can show a debug list.
      res.write(`event: ready\ndata: ${JSON.stringify({ ts: Date.now(), eventTypes: ["projects.updated", "cron.updated", "agents.updated", "history.updated", "identity.updated"] })}\n\n`);
      SSE_CLIENTS.add(res);
      // CRITICAL: listen on RES, not REQ. For GET requests the request
      // "close" event fires as soon as the body is consumed (immediate
      // for body-less GETs), which would tear down the SSE subscription
      // before the first watcher event ever fires. The response "close"
      // event correctly tracks when the underlying TCP connection ends.
      const cleanup = () => { SSE_CLIENTS.delete(res); try { res.end(); } catch {} };
      res.on("close", cleanup);
      res.on("error", cleanup);
      return;
    }

    // Identity — name + emoji + creature + vibe parsed from the
    // workspace IDENTITY.md the agent fills in during the first-light
    // bootstrap. iOS uses this to render the agent's chosen identity
    // in the Agents tab instead of the raw "main" name. Fields are
    // null until the agent fills them — clients should fall back
    // gracefully to default labels in that case.
    if (p === "/identity") {
      const id = readIdentity();
      // Strip the raw markdown payload from the response — clients
      // only need the parsed fields, and shipping the full file is
      // wasteful + leaks any free-form notes the agent jotted in.
      const { name, creature, vibe, emoji } = id;
      res.end(JSON.stringify({
        name, creature, vibe, emoji,
        configured: !!(name || emoji),
        updated: new Date().toLocaleTimeString(),
      }));
      return;
    }

    // Auto-pair for tailnet peers owned by the same user. Mirrors
    // StatusServer.swift's /pair behavior on Mac.
    //
    // Data sources are all FILES, not subprocesses — the status-server
    // runs under systemd with a minimal environment (HOME only, no PATH
    // beyond /usr/bin:/bin) so any `execSync("openclaw …")` or
    // `execSync("tailscale …")` silently fails when those binaries live
    // under $HOME/.npm-global/bin or $HOME/.nvm/…/bin. Instead we read
    // ~/.openclaw/openclaw.json for the token and ~/.carapace/tailscale-
    // status.json (written at install time + refreshed by a tailscale
    // status subprocess with the right PATH) for tailnet identity. If
    // the cached status is missing we fall back to `tailscale` via an
    // explicit-path lookup. No subprocess ⇒ no PATH pitfall.
    if (p === "/pair") {
      try {
        const callerLogin = (req.headers["tailscale-user-login"] || "").trim();
        if (!callerLogin) {
          res.writeHead(401);
          res.end(JSON.stringify({ error: "request did not come through Tailscale Serve" }));
          return;
        }

        // 1. Read this machine's own tailnet identity.
        let tsJson = null;
        const statusCache = path.join(DIR, "tailscale-status.json");
        if (fs.existsSync(statusCache)) {
          try {
            tsJson = JSON.parse(fs.readFileSync(statusCache, "utf8"));
          } catch (_) { tsJson = null; }
        }
        // Fallback: exec `tailscale status --json` with a resolved path.
        if (!tsJson) {
          const { execSync } = require("child_process");
          const tailscaleCandidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
          ];
          const tsBin = tailscaleCandidates.find(p => { try { return fs.existsSync(p); } catch (_) { return false; }});
          if (tsBin) {
            try {
              const raw = execSync(`"${tsBin}" status --json`, {
                timeout: 3000,
                stdio: ["ignore", "pipe", "ignore"],
              }).toString();
              tsJson = JSON.parse(raw);
              // Cache for next call.
              try { fs.writeFileSync(statusCache, raw); } catch (_) {}
            } catch (_) { tsJson = null; }
          }
        }
        if (!tsJson) {
          res.writeHead(503);
          res.end(JSON.stringify({ error: "tailnet identity unavailable on this machine" }));
          return;
        }
        const selfUserId = tsJson.Self && tsJson.Self.UserID;
        const users = tsJson.User;
        const ownerLogin = users && users[String(selfUserId)] && users[String(selfUserId)].LoginName;
        if (!ownerLogin) {
          res.writeHead(503);
          res.end(JSON.stringify({ error: "tailnet owner unresolvable" }));
          return;
        }
        if (callerLogin.toLowerCase() !== String(ownerLogin).toLowerCase()) {
          res.writeHead(403);
          res.end(JSON.stringify({ error: "different tailnet user — not authorized to auto-pair" }));
          return;
        }

        // 2. Read the gateway bearer token directly from the openclaw
        //    config file. Avoids `openclaw config get …` (which requires
        //    PATH to include the nvm/npm-global bin dir — systemd's
        //    minimal env doesn't).
        let gwToken = "";
        try {
          const cfg = JSON.parse(fs.readFileSync(path.join(OC_DIR, "openclaw.json"), "utf8"));
          gwToken = (cfg && cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token) || "";
        } catch (_) { gwToken = ""; }
        if (!gwToken) {
          res.writeHead(503);
          res.end(JSON.stringify({ error: "this machine has no gateway token yet" }));
          return;
        }

        // 3. Build the MagicDNS gateway URL.
        const selfDNSRaw = tsJson.Self && tsJson.Self.DNSName;
        const selfDNS = selfDNSRaw ? String(selfDNSRaw).replace(/\.$/, "") : null;
        const gatewayURL = selfDNS ? `https://${selfDNS}` : null;
        if (!gatewayURL) {
          res.writeHead(503);
          res.end(JSON.stringify({ error: "MagicDNS hostname unavailable" }));
          return;
        }

        // 4. Also surface the Gemini API key if this machine has one
        //    configured. Lets the Mac app auto-populate its vision-mode
        //    key slot on auto-pair — so the QR code it generates for
        //    iOS pairing already includes the right key for this
        //    gateway. Pulled from the google:default profile in
        //    auth-profiles.json (the standard openclaw provider entry
        //    for Google/Gemini). Best-effort — absent key just means
        //    the Mac doesn't auto-populate and the user enters their
        //    own, same as today.
        let geminiAPIKey = null;
        try {
          const authProfilesPath = path.join(OC_DIR, "agents", "main", "agent", "auth-profiles.json");
          const ap = JSON.parse(fs.readFileSync(authProfilesPath, "utf8"));
          const g = ap && ap.profiles && ap.profiles["google:default"];
          if (g && g.type === "api_key" && typeof g.key === "string" && g.key.length > 0) {
            geminiAPIKey = g.key;
          }
        } catch (_) { /* no key — ok */ }

        const payload = {
          gatewayURL,
          token: gwToken,
          hostname: selfDNS,
        };
        if (geminiAPIKey) payload.geminiAPIKey = geminiAPIKey;
        res.end(JSON.stringify(payload));
        return;
      } catch (err) {
        res.writeHead(500);
        res.end(JSON.stringify({ error: "pair handler crashed: " + (err && err.message) }));
        return;
      }
    }

    if (p === "/history") {
      const agent = qs.get("agent") || "main";
      res.end(JSON.stringify(loadHistory(Math.min(limit, 200), token, agent)));
      return;
    }

    if (p === "/sessions") {
      const agentsRoot = path.join(OC_DIR, "agents");
      // Union of (a) on-disk agent directories (agents that have run)
      // and (b) registered agents from openclaw.json (agents created
      // but never started). Either source alone misses cases — disk
      // misses brand-new agents, config misses ad-hoc agents that
      // appeared via subagent spawn. Union covers both.
      const known = new Set();
      let sessions = [];
      try {
        const agentDirs = fs.readdirSync(agentsRoot).filter(a => {
          try { return fs.statSync(path.join(agentsRoot, a)).isDirectory(); } catch { return false; }
        }).sort();
        for (const agent of agentDirs) {
          const sessDir = path.join(agentsRoot, agent, "sessions");
          let lastActive = 0;
          try {
            const files = fs.readdirSync(sessDir)
              .filter(f => f.endsWith(".jsonl") && !f.includes(".deleted.") && !f.includes(".reset.") && f !== "sessions.json");
            for (const f of files) {
              try {
                const mtime = fs.statSync(path.join(sessDir, f)).mtime.getTime() / 1000;
                if (mtime > lastActive) lastActive = mtime;
              } catch {}
            }
          } catch {}
          const label = agent === "main" ? "Main" :
            agent.replace(/-/g, " ").replace(/_/g, " ")
              .replace(/\b\w/g, c => c.toUpperCase());
          sessions.push({ key: `agent:${agent}:main`, agent, label, lastActive });
          known.add(agent);
        }
        // Surface registered-but-never-run agents from openclaw.json
        // so the iOS dropdown can switch INTO them on first use. The
        // gateway will lazy-create the agent dir on first message.
        const registered = getRegisteredAgents();
        for (const reg of registered) {
          const id = reg && reg.id;
          if (!id || known.has(id)) continue;
          const ident = reg.identity || {};
          const rawName = ident.name || reg.name || (id === "main" ? "Main" : id);
          const label = rawName.charAt(0).toUpperCase() + rawName.slice(1);
          sessions.push({ key: `agent:${id}:main`, agent: id, label, lastActive: 0 });
          known.add(id);
        }
        // main first, then by lastActive desc
        sessions.sort((a, b) => {
          if (a.agent === "main") return -1;
          if (b.agent === "main") return 1;
          return b.lastActive - a.lastActive;
        });
      } catch {}
      res.end(JSON.stringify({ sessions }));
      return;
    }

    // Root with ?limit= = history (Tailscale may strip /history prefix)
    if ((p === "/" || p === "") && qs.has("limit")) {
      const agent = qs.get("agent") || "main";
      res.end(JSON.stringify(loadHistory(Math.min(limit, 200), token, agent)));
      return;
    }

    if (p === "/" || p === "") {
      const fp = path.join(DIR, "carapace-agent-tracker.json");
      try { res.end(fs.readFileSync(fp, "utf8")); } catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); }
      return;
    }

    // DELETE /cron/:id — delete a cron job from both openclaw and tracker
    if (req.method === "DELETE" && p.startsWith("/cron/")) {
      const id = decodeURIComponent(p.slice("/cron/".length));
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      let deleted = false;
      // Remove from openclaw jobs.json
      try {
        const ocfp = path.join(OC_DIR, "cron", "jobs.json");
        if (fs.existsSync(ocfp)) {
          const data = JSON.parse(fs.readFileSync(ocfp, "utf8"));
          const before = (data.jobs || []).length;
          data.jobs = (data.jobs || []).filter(j => j.id !== id);
          if (data.jobs.length < before) { fs.writeFileSync(ocfp, JSON.stringify(data)); deleted = true; }
        }
      } catch (e) {}
      // Always remove from carapace tracker too (may be stale)
      try {
        const tfp = path.join(DIR, "carapace-cron-tracker.json");
        if (fs.existsSync(tfp)) {
          const data = JSON.parse(fs.readFileSync(tfp, "utf8"));
          const before = (data.jobs || []).length;
          data.jobs = (data.jobs || []).filter(j => j.id !== id);
          if (data.jobs.length < before) { fs.writeFileSync(tfp, JSON.stringify(data)); deleted = true; }
        }
      } catch (e) {}
      // Always write tombstone — even if job wasn't in files (may be in gateway memory)
      try {
        const tombfp = path.join(DIR, "deleted-cron-ids.json");
        const tomb = fs.existsSync(tombfp) ? JSON.parse(fs.readFileSync(tombfp, "utf8")) : { ids: [] };
        if (!tomb.ids.includes(id)) tomb.ids.push(id);
        fs.writeFileSync(tombfp, JSON.stringify(tomb));
      } catch(e) {}
      if (!deleted) { res.writeHead(404); res.end(JSON.stringify({ error: "job not found" })); return; }
      res.end(JSON.stringify({ ok: true, deleted: id }));
      return;
    }

    // PUT /projects/:id/prompt — update project-level focus prompt
    // PUT /projects/:id/workstreams/:wid/prompt — update workstream focus
    // Both write to the CARAPACE PROJECTS block in MEMORY.md (atomic,
    // sentinel-safe). Sidecar ~/.carapace/project-prompt-meta.json
    // tracks promptVersion + promptUpdatedAt counters that iOS uses
    // for cache invalidation.
    if (req.method === "PUT") {
      const projMatch = p.match(/^\/projects\/([^/]+)\/prompt\/?$/);
      const wsMatch = p.match(/^\/projects\/([^/]+)\/workstreams\/([^/]+)\/prompt\/?$/);
      if (projMatch || wsMatch) {
        try {
          const payload = JSON.parse(body || "{}");
          let result;
          if (wsMatch) {
            const [, pid, wid] = wsMatch;
            result = projectsUpdateWorkstreamPrompt(decodeURIComponent(pid), decodeURIComponent(wid), payload.focusPrompt);
          } else {
            const [, pid] = projMatch;
            result = projectsUpdateProjectPrompt(decodeURIComponent(pid), payload.divePrompt || payload.focusPrompt);
          }
          if (result.error) { res.writeHead(result.status || 500); res.end(JSON.stringify(result)); return; }
          res.end(JSON.stringify(result));
        } catch (e) {
          res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
        }
        return;
      }
    }

    // DELETE /projects/:id — remove project from MEMORY.md
    if (req.method === "DELETE" && p.startsWith("/projects/") && !p.includes("/cron/")) {
      const id = decodeURIComponent(p.slice("/projects/".length));
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      const result = projectsDelete(id);
      if (result.error) { res.writeHead(result.status || 500); res.end(JSON.stringify(result)); return; }
      res.end(JSON.stringify(result));
      return;
    }

    // Live agent status — built from OpenClaw session files
    if (p === "/status" || p === "/agents") {
      res.end(JSON.stringify(getLiveAgentStatus()));
      return;
    }

    // GET /projects + /tracker — now sourced from MEMORY.md instead of
    // the cron-synced carapace-project-tracker.json. Real-time: edits
    // the agent makes in-conversation appear immediately on iOS without
    // waiting for a 2-min cron tick.
    if (p === "/projects" || p === "/tracker") {
      if (!isTierPaid()) { res.end(EMPTY_PROJECTS); return; }
      try { res.end(JSON.stringify(projectsBuildResponse())); }
      catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
      return;
    }

    // Other file-backed endpoints (cron) still read from disk
    const filePath = fileMap[p] ? path.join(DIR, fileMap[p]) : null;
    if (filePath) {
      if (!isTierPaid()) {
        if (p === "/cron") { res.end(EMPTY_CRON); return; }
      }
      try { res.end(fs.readFileSync(filePath, "utf8")); }
      catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); }
      return;
    }

    res.writeHead(404); res.end(JSON.stringify({ error: "not found" }));
  });
}).listen(18794, "127.0.0.1", () => console.log("CARAPACE Status Server on :18794"));
