const http = require("http"), fs = require("fs"), path = require("path"), os = require("os");
const DIR = path.join(os.homedir(), ".carapace");
const OC_DIR = path.join(os.homedir(), ".openclaw");

// ════════════════════════════════════════════════════════════════════
// COGNITIVE MEMORY MODULE
// Brain-region cognitive architecture: visual + auditory memory,
// place schemas, sub-areas, routine patterns, affect tags.
// Lazy-loaded since the modules are ESM and this file is CommonJS.
// ════════════════════════════════════════════════════════════════════
// MEMORY ARCHITECTURE
//
// As of Apr 2026 we delegate long-term memory to OpenClaw's built-in
// `memory-core` plugin (released in v2026.4.25). It indexes
// ~/.openclaw/workspace/memory/*.md into a per-agent SQLite FTS5
// store and exposes `memory.search` as a native agent tool.
//
// This file used to maintain a parallel "cognitive" SQLite layer
// (~/.carapace/cognitive/) with brain-region tables (hippocampus,
// place schemas, affect tags, etc.) — that's now retired in favor
// of letting memory-core own persistence + retrieval. The two
// systems were doubling memory work and racing on file watchers,
// pegging the gateway at 100% CPU on v2026.4.25.
//
// Carapace's job in /chat is now narrower:
//   1. Add a CURRENT-TURN context hint (lat/lon/scene/objects/mode)
//      as a system-message prefix — the agent can't see these
//      sensors otherwise.
//   2. Append a structured turn record to memory/turns-<date>.md
//      so memory-core indexes it and the agent can call
//      memory.search() to recall past turns by location/content.
//
// Old /cognitive/* endpoints below are kept as no-op stubs so iOS
// clients pinned to older builds don't 404 — they just return
// empty/static data.

// Build a compact "what's true right now" hint for the next agent
// turn. Returns null when there's nothing to add (lets us skip the
// system-message prepend entirely on plain text chats).
function buildContextHint({ lat, lon, scene, objects, mode }) {
  const bits = [];
  if (lat != null && lon != null && !isNaN(lat) && !isNaN(lon)) {
    bits.push(`location: ${Number(lat).toFixed(4)}, ${Number(lon).toFixed(4)}`);
  }
  if (scene) bits.push(`scene: ${String(scene).slice(0, 200)}`);
  if (Array.isArray(objects) && objects.length) {
    bits.push(`visible: ${objects.slice(0, 8).join(", ")}`);
  }
  if (mode && mode !== "chat") bits.push(`mode: ${mode}`);
  if (!bits.length) return null;
  return `[ctx] ${bits.join(" · ")}`;
}

// Multimodal messages from iOS arrive as content arrays. Extract
// just the text bits so we can write them to the turn record.
function extractText(c) {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return c.filter(p => p?.type === "text").map(p => p.text || "").join(" ");
  return "";
}

// Append a per-turn record to ~/.openclaw/workspace/memory/turns-YYYY-MM-DD.md.
// memory-core's file watcher picks this up on its 1.5s debounce and
// indexes it for FTS5 search. The format is structured-but-readable
// markdown so it's both grep-friendly and reads well to a human
// browsing memory/.
//
// Day-bucketed file (one .md per day) keeps individual files small
// while still being temporally ordered. The agent can search across
// all of them via memory.search.
function appendTurnRecord({ ts, lat, lon, scene, objects, mode, userText, agent_id }) {
  if (!userText || userText.length < 2) return; // skip empty / single-char turns
  const memoryDir = path.join(OC_DIR, "workspace", "memory");
  fs.mkdirSync(memoryDir, { recursive: true });
  const d = new Date(ts);
  const day = d.toISOString().slice(0, 10);     // YYYY-MM-DD
  const stamp = d.toISOString().slice(11, 19); // HH:MM:SS
  const file = path.join(memoryDir, `turns-${day}.md`);
  const lines = [`## ${day} ${stamp} UTC`];
  if (mode && mode !== "chat") lines.push(`**Mode:** ${mode}`);
  if (lat != null && lon != null && !isNaN(lat) && !isNaN(lon)) {
    lines.push(`**Loc:** ${Number(lat).toFixed(4)}, ${Number(lon).toFixed(4)}`);
  }
  if (scene) lines.push(`**Scene:** ${String(scene).slice(0, 300)}`);
  if (Array.isArray(objects) && objects.length) {
    lines.push(`**Visible:** ${objects.slice(0, 12).join(", ")}`);
  }
  if (agent_id && agent_id !== "main") lines.push(`**Agent:** ${agent_id}`);
  // Cap user text at 1000 chars per turn so a runaway dump doesn't
  // bloat memory files. Full text still lives in the agent's session
  // log; this is the searchable summary.
  lines.push(`**User:** ${userText.replace(/\s+/g, " ").trim().slice(0, 1000)}`);
  lines.push(""); // trailing blank for markdown breathing room
  fs.appendFileSync(file, lines.join("\n") + "\n");
}

// Forward chat request to local OpenClaw (port 18789), prepending visual
// memory injection as a system message. Returns the parsed response.
let _ocToken = null;
function getOcToken() {
  if (_ocToken !== null) return _ocToken;
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(OC_DIR, "openclaw.json"), "utf8"));
    _ocToken = cfg?.gateway?.auth?.token || "";
  } catch { _ocToken = ""; }
  return _ocToken;
}


// (buildThinkingSummary removed — was used to render the cognitive
// injection as a synthetic <think> block for iOS's brain toggle.
// memory-core handles memory now and we no longer build a synthetic
// per-turn injection, so there's nothing to summarize.)

// Streaming variant — pipes OpenClaw's SSE stream directly to the
// caller's response. Used when client requests stream:true.
function forwardToOpenClawStream(messages, agent_id, sessionKey, clientRes, mode = null, thinkingSummaryForChat = null) {
  const body = JSON.stringify({ model: "openclaw" + (agent_id ? "/" + agent_id : ""), messages, stream: true });
  const tok = getOcToken();
  const headers = { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) };
  if (tok) headers["Authorization"] = "Bearer " + tok;
  if (sessionKey) headers["x-openclaw-session-key"] = sessionKey;
  return new Promise((resolve, reject) => {
    const r = http.request({
      hostname: "127.0.0.1", port: 18789, path: "/v1/chat/completions", method: "POST", headers,
    }, ocRes => {
      // Forward status + SSE headers
      clientRes.statusCode = ocRes.statusCode;
      clientRes.setHeader("Content-Type", ocRes.headers["content-type"] || "text/event-stream");
      clientRes.setHeader("Cache-Control", "no-cache");
      clientRes.setHeader("Connection", "keep-alive");
      // For chat mode, pipe untouched so <think> blocks reach iOS for
      // brain-toggle display. For voice/vision, strip aggressively.
      if (mode === "chat") {
        // Chat mode pipes untouched — no synthetic thinking, no strip.
        ocRes.on("data", chunk => clientRes.write(chunk));
        ocRes.on("end", () => { clientRes.end(); resolve(); });
        return;
      }
      // Pipe with line-buffered <think>...</think> stripping. SSE chunks
      // arrive as 'data: {...json...}\n\n' lines. We accumulate, parse
      // each delta's content, drop any <think>...</think> region, then
      // forward. Belt-and-suspenders: even if model emits thinking
      // tags despite our instructions, they never reach iOS.
      let buf = "";
      let inThink = false;
      ocRes.on("data", chunk => {
        buf += chunk.toString();
        let nl;
        while ((nl = buf.indexOf("\n\n")) >= 0) {
          const line = buf.slice(0, nl + 2);
          buf = buf.slice(nl + 2);
          // Process SSE 'data: {...}' lines
          if (line.startsWith("data: ")) {
            const payload = line.slice(6).trim();
            if (payload === "[DONE]") { clientRes.write(line); continue; }
            try {
              const j = JSON.parse(payload);
              const delta = j?.choices?.[0]?.delta?.content;
              if (typeof delta === "string") {
                let cleaned = delta;
                // State machine across deltas — track if we're inside a think block
                if (inThink) {
                  const closeIdx = cleaned.indexOf("</think>");
                  if (closeIdx >= 0) {
                    cleaned = cleaned.slice(closeIdx + 8);
                    inThink = false;
                  } else {
                    cleaned = "";  // entire delta is inside think
                  }
                }
                // Strip complete <think>...</think> within this delta
                cleaned = cleaned.replace(/<think>[\s\S]*?<\/think>/gi, "");
                // Detect unclosed <think> opening
                const openIdx = cleaned.indexOf("<think>");
                if (openIdx >= 0) {
                  cleaned = cleaned.slice(0, openIdx);
                  inThink = true;
                }
                // Also drop bare leading '<' or '<t' / '<th' / '<thi' / '<thin' / '<think'
                // partial-tag fragments at start of cleaned (these stream through
                // before we know if it's a think tag).
                const partial = cleaned.match(/^<th?i?n?k?>?$/);
                if (partial) cleaned = "";
                if (cleaned !== delta) {
                  if (cleaned === "") continue;  // skip empty delta
                  j.choices[0].delta.content = cleaned;
                  clientRes.write("data: " + JSON.stringify(j) + "\n\n");
                  continue;
                }
              }
            } catch {}
          }
          clientRes.write(line);
        }
      });
      ocRes.on("end", () => {
        if (buf) clientRes.write(buf);
        clientRes.end();
        resolve();
      });
      ocRes.on("error", reject);
    });
    r.on("error", reject);
    r.write(body);
    r.end();
  });
}

async function forwardToOpenClaw(messages, agent_id) {
  const body = JSON.stringify({ model: "openclaw" + (agent_id ? "/" + agent_id : ""), messages });
  const tok = getOcToken();
  const ocReq = await new Promise((resolve, reject) => {
    const r = http.request({
      hostname: "127.0.0.1", port: 18789, path: "/v1/chat/completions", method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body),
        ...(tok ? { "Authorization": "Bearer " + tok } : {}) },
    }, res => {
      let d = "";
      res.on("data", c => d += c);
      res.on("end", () => { try { resolve(JSON.parse(d)); } catch(e) { resolve({ raw: d }); } });
    });
    r.on("error", reject);
    r.write(body);
    r.end();
  });
  return ocReq;
}

const TRACKER_PORT = 18795; // python project-tracker-server (legacy fallback)

// ============================================================================
// CARAPACE PROJECTS — per-agent PROJECTS.md tracker
// ============================================================================
// Projects + workstreams live in a dedicated `PROJECTS.md` file in
// EACH agent's workspace (so different agents track their own boards).
// Layout:
//   ~/.openclaw/workspace/PROJECTS.md                     ← main's projects
//   ~/.openclaw/workspace/agents/<id>/PROJECTS.md         ← per-agent
//   ~/.openclaw/workspace-<id>/PROJECTS.md                ← VPS-style alt
//
// The whole FILE is the projects list — no sentinel markers, just an
// optional <!-- format reference --> comment at the top followed by
// `### slug · Name · emoji progress%` sections. The agent reads +
// writes this file directly using its file tools (instructions live
// in AGENTS.md per-agent via the install-script injection).
//
// History: this used to be a sentinel block inside MEMORY.md, which
// per OpenClaw's docs is "ONLY load in main session, contains
// personal context that shouldn't leak to strangers." Squatting in
// MEMORY.md made per-agent projects impossible AND polluted the
// agent's curated long-term memory with structured data. Splitting
// to PROJECTS.md keeps both stores clean.
//
// Format inside PROJECTS.md (one section per project):
//   ### <id> · <Name> · <emoji> <progress>%
//   <description paragraph>
//   **Focus:** <project focus prompt>
//   **Workstreams:**
//   - `<id>` · <name> · <emoji> <progress>% [· @<owner>] — <focus>
//
// Status emojis: 🟢 green · 🟡 yellow · 🔴 red · ⚪ idle
// Owner defaults to `main` when omitted.
const IDENTITY_PATH = path.join(OC_DIR, "workspace", "IDENTITY.md");
const PROMPT_META_PATH = path.join(DIR, "project-prompt-meta.json");
// "suggested" = the agent inferred a possible project from conversation
// but hasn't been told to commit it as a tracked project. iOS renders
// these with a teal `?` instead of a status dot so the user can long-
// press to either Convert (promote to a real status) or Delete.
const EMOJI_TO_STATUS = { "🟢": "green", "🟡": "yellow", "🔴": "red", "⚪": "idle", "❓": "suggested" };
const STATUS_TO_EMOJI = { green: "🟢", yellow: "🟡", red: "🔴", idle: "⚪", suggested: "❓" };

/// Resolve the PROJECTS.md path for a given agent id. Reuses the
/// Project tracking is MACHINE-WIDE owned by `main` — every agent's
/// Projects tab reads/writes the same file at ~/.openclaw/workspace/
/// PROJECTS.md. The agentId param is accepted for API compatibility
/// but is intentionally ignored: it stays in routes for client-side
/// context (which agent the user is currently chatting with), but the
/// resolved file is always main's.
function projectsFilePath(_agentId) {
  return path.join(OC_DIR, "workspace", "PROJECTS.md");
}

function projectsParseSection(text) {
  const lines = text.split("\n");
  if (!lines.length) return null;
  const headerMatch = lines[0].match(/^([^\s·]+)\s*·\s*(.+?)\s*·\s*(🟢|🟡|🔴|⚪|❓)\s*(\d+)%\s*$/);
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
    const bm = ln.match(/^- `([^`]+)`\s*·\s*(.+?)\s*·\s*(🟢|🟡|🔴|⚪|❓)\s*(\d+)%\s*(?:·\s*@([\w-]+)\s*)?(?:—\s*(.*))?$/);
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
  // Strip ALL HTML comments (the file-header reference comment + any
  // ad-hoc agent comments) before parsing sections.
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

function projectsRead(agentId) {
  const file = projectsFilePath(agentId);
  let body;
  try { body = fs.readFileSync(file, "utf8"); }
  catch { return []; }
  return projectsParseBlock(body);
}

function projectsWrite(projects, agentId) {
  const file = projectsFilePath(agentId);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // The whole file is the projects list — wrap with a leading
  // <!-- format reference --> comment for self-documentation when
  // a human (or the agent) opens the file directly.
  const header = [
    "<!-- CARAPACE PROJECTS — agent-maintained · iOS Projects view reads + writes here. Format:",
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
    "",
  ].join("\n");
  const body = header + projectsFormatBlock(projects);
  const tmp = `${file}.carapace-projects.tmp.${process.pid}`;
  fs.writeFileSync(tmp, body);
  fs.renameSync(tmp, file);
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

function projectsBuildResponse(agentId) {
  const projects = projectsRead(agentId);
  // Meta keys are namespaced by agent so the prompt-version cursor
  // for main:install-carapace doesn't collide with orthobro:install-carapace.
  const meta = projectsReadMeta();
  const ns = (agentId && String(agentId).trim()) || "main";
  for (const p of projects) {
    const pm = meta[`${ns}:${p.id}`];
    if (pm) { p.promptVersion = pm.version; p.promptUpdatedAt = pm.updatedAt; }
    for (const w of (p.workstreams || [])) {
      const wm = meta[`${ns}:${p.id}:${w.id}`];
      if (wm) { w.promptVersion = wm.version; w.promptUpdatedAt = wm.updatedAt; }
    }
  }
  return { version: 1, agent: ns, updated: new Date().toISOString(), projects };
}

function projectsUpdateProjectPrompt(agentId, projectId, newPrompt) {
  const projects = projectsRead(agentId);
  const proj = projects.find(p => p.id === projectId);
  if (!proj) return { error: "project not found", status: 404 };
  proj.divePrompt = newPrompt || "";
  projectsWrite(projects, agentId);
  const ns = (agentId && String(agentId).trim()) || "main";
  const m = projectsBumpMeta(`${ns}:${projectId}`);
  return { ok: true, id: projectId, agent: ns, promptVersion: m.version, promptUpdatedAt: m.updatedAt };
}

function projectsUpdateWorkstreamPrompt(agentId, projectId, workstreamId, newPrompt) {
  const projects = projectsRead(agentId);
  const proj = projects.find(p => p.id === projectId);
  if (!proj) return { error: "project not found", status: 404 };
  const ws = (proj.workstreams || []).find(w => w.id === workstreamId);
  if (!ws) return { error: "workstream not found", status: 404 };
  ws.focusPrompt = newPrompt || "";
  projectsWrite(projects, agentId);
  const ns = (agentId && String(agentId).trim()) || "main";
  const m = projectsBumpMeta(`${ns}:${projectId}:${workstreamId}`);
  return { ok: true, id: projectId, wid: workstreamId, agent: ns, promptVersion: m.version, promptUpdatedAt: m.updatedAt };
}

/// Promote a "suggested" project to a normal tracked status (or
/// flip status freely between any of the known emojis). iOS calls
/// this when the user picks "Convert" on a suggested project's
/// long-press menu — typically newStatus = "green", optional
/// progress reset to 0.
function projectsUpdateStatus(agentId, projectId, newStatus, newProgress) {
  const validStatuses = Object.keys(STATUS_TO_EMOJI);
  if (!validStatuses.includes(newStatus)) {
    return { error: `invalid status (must be one of: ${validStatuses.join(", ")})`, status: 400 };
  }
  const projects = projectsRead(agentId);
  const proj = projects.find(p => p.id === projectId);
  if (!proj) return { error: "project not found", status: 404 };
  proj.status = newStatus;
  if (typeof newProgress === "number" && Number.isFinite(newProgress)) {
    proj.progress = Math.max(0, Math.min(100, Math.round(newProgress)));
  }
  projectsWrite(projects, agentId);
  const ns = (agentId && String(agentId).trim()) || "main";
  return { ok: true, id: projectId, agent: ns, status: newStatus, progress: proj.progress };
}

function projectsDelete(agentId, projectId) {
  const projects = projectsRead(agentId);
  const idx = projects.findIndex(p => p.id === projectId);
  if (idx === -1) return { error: "project not found", status: 404 };
  projects.splice(idx, 1);
  projectsWrite(projects, agentId);
  const ns = (agentId && String(agentId).trim()) || "main";
  const meta = projectsReadMeta();
  // Only purge meta keys for THIS agent's namespace.
  const projKey = `${ns}:${projectId}`;
  for (const k of Object.keys(meta)) {
    if (k === projKey || k.startsWith(`${projKey}:`)) delete meta[k];
  }
  projectsWriteMeta(meta);
  return { ok: true, deleted: projectId, agent: ns };
}

// ============================================================================
// CRON — live-query OpenClaw, no tracker.json dependency
// ============================================================================
// Was a file-backed endpoint sourced from the periodic sync-trackers.sh
// cron job. That sync was tied to the project-tracker cron, which we
// removed when projects moved into per-agent PROJECTS.md. Now we
// query openclaw directly each request — it's fast (<100ms locally)
// and the result is always live.
function buildCronPayload() {
  const { execSync } = require("child_process");
  let raw;
  try {
    // `--all` includes disabled jobs (per Mike: disabled should still
    // show on iOS, just visually subordinated).
    //
    // PATH extension: the openclaw bin is a shebang `#!/usr/bin/env node`
    // script. When LaunchAgent boots us with the restricted system PATH
    // (`/usr/bin:/bin:/usr/sbin:/sbin`), `env` can't find `node` and the
    // execSync fails with status 127. Three things must be reachable in
    // PATH for the shebang to resolve:
    //   1. `~/.npm-global/bin` — where `openclaw` itself lives
    //   2. The dir containing OUR running node (process.execPath) so the
    //      shebang's `env node` resolves to a working interpreter
    //   3. `/opt/homebrew/bin` + `/usr/local/bin` — common node install
    //      paths (homebrew on Mac arm64 + intel/Linux manual)
    // Without (2), execSync silently dies with 127 and the iOS app sees
    // an empty cron list even though `openclaw cron list` works fine
    // from the user's shell.
    const nodeDir = require("path").dirname(process.execPath);
    const extraPaths = [
      `${process.env.HOME}/.npm-global/bin`,
      nodeDir,
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ].join(":");
    raw = execSync("openclaw cron list --json --all 2>/dev/null", {
      encoding: "utf8",
      timeout: 5000,
      env: { ...process.env, PATH: `${extraPaths}:${process.env.PATH || "/usr/bin:/bin"}` },
    });
  } catch {
    return { version: 1, updated: new Date().toISOString(), jobs: [] };
  }

  let parsed;
  try { parsed = JSON.parse(raw); }
  catch { return { version: 1, updated: new Date().toISOString(), jobs: [] }; }

  const fmtMs = (ms) => {
    if (!ms) return "";
    try {
      const d = new Date(ms);
      return d.toISOString().replace("T", " ").slice(0, 16) + " UTC";
    } catch { return ""; }
  };

  const jobs = (parsed.jobs || []).map(j => {
    const sched = j.schedule || {};
    let scheduleStr = "";
    if (sched.kind === "every" && sched.everyMs) {
      const mins = Math.round(sched.everyMs / 60000);
      scheduleStr = `every ${mins}m`;
    } else if (sched.kind === "cron") {
      scheduleStr = sched.expr || "";
    } else {
      scheduleStr = sched.kind || "";
    }
    const state = j.state || {};
    const enabled = j.enabled !== false;
    return {
      id: j.id || "",
      name: j.name || j.id || "",
      schedule: scheduleStr,
      enabled: enabled,
      // Status: "idle" when enabled (not currently running — we don't
      // track running state from `cron list`), "disabled" otherwise.
      status: enabled ? "idle" : "disabled",
      lastRun: fmtMs(state.lastRunAtMs),
      // Sortable raw timestamp for iOS / clients that want it.
      lastRunAtMs: state.lastRunAtMs || 0,
      nextRun: fmtMs(state.nextRunAtMs),
      payload: ((j.payload || {}).message || "").slice(0, 240),
    };
  });

  // Sort: most-recently-run at the TOP. Jobs that have never run
  // sort to the bottom (lastRunAtMs = 0). Per Mike's spec.
  jobs.sort((a, b) => (b.lastRunAtMs || 0) - (a.lastRunAtMs || 0));

  return {
    version: 1,
    updated: new Date().toISOString(),
    jobs: jobs,
  };
}

// One-shot migration. Runs on status-server startup. Pulls the
// legacy MEMORY.md sentinel block (or the older
// carapace-project-tracker.json) into the new per-agent
// PROJECTS.md format for `main`. Idempotent — no-op when main's
// PROJECTS.md already exists.
function projectsMigrateOnStartup() {
  const mainPath = projectsFilePath("main");
  if (fs.existsSync(mainPath)) return; // already migrated

  // 1) Try lifting from the legacy sentinel block in main's MEMORY.md.
  const memoryPath = path.join(OC_DIR, "workspace", "memory", "MEMORY.md");
  let migrated = null;
  try {
    const memory = fs.readFileSync(memoryPath, "utf8");
    const beginRe = /^<!-- BEGIN CARAPACE PROJECTS/m;
    const endRe = /^<!-- END CARAPACE PROJECTS/m;
    const b = memory.match(beginRe);
    if (b) {
      const beginEol = memory.indexOf("\n", b.index);
      const tail = memory.slice(beginEol + 1);
      const e = tail.match(endRe);
      if (e) {
        const blockText = tail.slice(0, e.index).replace(/\s+$/, "");
        migrated = projectsParseBlock(blockText);
      }
    }
  } catch {}

  // 2) Fallback: legacy tracker JSON copies.
  if (!migrated || !migrated.length) {
    const candidates = [
      path.join(DIR, "carapace-project-tracker.json"),
      path.join(OC_DIR, "workspace", "projects", "tracker.json"),
    ];
    for (const c of candidates) {
      try {
        const data = JSON.parse(fs.readFileSync(c, "utf8"));
        if (data && Array.isArray(data.projects) && data.projects.length) {
          migrated = data.projects.map(p => ({
            id: p.id,
            name: p.name || p.id,
            status: p.status || "idle",
            progress: Number.isFinite(p.progress) ? p.progress : 0,
            description: p.description || "",
            divePrompt: p.divePrompt || "",
            workstreams: (p.workstreams || []).map(w => ({
              id: w.id, name: w.name || w.id,
              status: w.status || "idle",
              progress: Number.isFinite(w.progress) ? w.progress : 0,
              owner: w.owner || "main",
              focusPrompt: w.focusPrompt || "",
            })),
          }));
          break;
        }
      } catch {}
    }
  }

  if (!migrated || !migrated.length) return; // nothing to migrate
  try {
    projectsWrite(migrated, "main");
    console.log(`[projects] migrated ${migrated.length} project(s) → ${mainPath}`);
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
        // Strip OpenClaw's "[Bootstrap pending]" auto-injection block
        // that prefixes user messages when an agent's workspace has
        // BOOTSTRAP.md. The block ends at either a "Sender (untrusted
        // metadata):" json fence (newer openclaw) or directly before
        // the user's actual content (older openclaw). The user's real
        // message is what follows — strip the system noise so the chat
        // bubble shows what the user actually typed.
        if (text.startsWith("[Bootstrap pending]")) {
          // Newer openclaw: bootstrap block + Sender json + user text
          const senderIdx = text.indexOf("Sender (untrusted metadata):");
          if (senderIdx !== -1) {
            // Skip past the sender JSON block (```json ... ```) to the
            // user's actual message that follows.
            const afterSender = text.slice(senderIdx);
            const fenceEnd = afterSender.indexOf("```\n", afterSender.indexOf("```json"));
            if (fenceEnd !== -1) {
              text = afterSender.slice(fenceEnd + 4).trim();
            } else {
              text = afterSender.replace(/^Sender \(untrusted metadata\):[\s\S]*?\n\n/, "").trim();
            }
          } else {
            // Older openclaw: bootstrap block then user text after a
            // blank line. Drop everything before the LAST blank line
            // since the bootstrap text itself contains blank lines.
            const lines = text.split("\n");
            // Find the last "[ctx ...]" / "[YYYY-MM-DD" timestamp
            // marker which delimits user content; if none, fall back
            // to the last line.
            let userStart = -1;
            for (let i = lines.length - 1; i >= 0; i--) {
              if (/^\[(ctx|\d{4}-\d{2}-\d{2}|🎙️|👁️|💬|Sat|Sun|Mon|Tue|Wed|Thu|Fri)\b/.test(lines[i].trim())) {
                userStart = i;
                break;
              }
            }
            text = userStart >= 0 ? lines.slice(userStart).join("\n").trim() : (lines[lines.length - 1] || "").trim();
          }
        }
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

// Tier gating REMOVED from Mac as of 2026-04 — Carapace macOS is no
// longer a paid app; every feature is unlocked. Function kept (always
// returns true) so we don't have to chase down every call site, and
// so we can re-introduce gating later for non-Mac surfaces if needed.
function isTierPaid() {
  return true;
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
  if (!label) return "👤";
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
  return "👤";
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
          // 90-second visibility window: keep the subagent on the
          // spinal map for 90 seconds after its last activity (idle
          // = greyed by iOS), then drop. Was 5 min, but stale ghosts
          // hung around too long in practice.
          const visibilityMs = 90 * 1000;
          if (!isRunning && ageMs > visibilityMs) continue;
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

// Project tracking is machine-wide → only one file to watch.
sseWatchFile(projectsFilePath(), sseProjectsChanged);
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
  req.on("end", async () => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Content-Type", "application/json");
    if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

    const rawPath = req.url || "/";
    const p = rawPath.split("?")[0];
    const qs = new URLSearchParams(rawPath.includes("?") ? rawPath.split("?")[1] : "");
    const limit = parseInt(qs.get("limit") || "50");
    const token = (req.headers["authorization"] || "").replace("Bearer ", "").trim() || null;

    if (p === "/health") { res.end(JSON.stringify({ ok: true })); return; }

    // ── COGNITIVE MEMORY endpoints (DEPRECATED — kept as no-ops) ────────
    // Memory is now owned by OpenClaw's memory-core plugin. These
    // endpoints stay around so iOS clients pinned to older builds
    // don't get 404s; they just return empty/static success payloads.
    // The next iOS major can drop the calls entirely.
    if (p === "/cognitive/health") {
      res.end(JSON.stringify({
        ok: true,
        ready: true,
        deprecated: true,
        replaced_by: "openclaw memory-core",
        stats: { episodic_memory: 0, sub_areas: 0, cognitive_map: 0, place_schemas: 0, routine_patterns: 0, affect_tags: 0 },
      }));
      return;
    }
    if (p === "/cognitive/ingest-frame" && req.method === "POST") {
      res.end(JSON.stringify({ ok: true, deprecated: true, ingested: false, note: "frame-level memory removed; per-turn context now flows through /chat" }));
      return;
    }
    if (p === "/cognitive/ingest-utterance" && req.method === "POST") {
      res.end(JSON.stringify({ ok: true, deprecated: true, ingested: false, note: "utterance-level memory removed; per-turn context now flows through /chat" }));
      return;
    }
    if (p === "/cognitive/correction" && req.method === "POST") {
      res.end(JSON.stringify({ ok: true, deprecated: true, ingested: false, note: "correction logging removed; agent learns via memory.search over turn records" }));
      return;
    }
    if (p === "/cognitive/injection") {
      res.end(JSON.stringify({ injection: null, deprecated: true, replaced_by: "openclaw memory-core via memory.search tool" }));
      return;
    }
    // Main chat endpoint — visual+auditory memory injection + forward to OpenClaw
    if (p === "/chat" && req.method === "POST") {
      try {
        const b = JSON.parse(body || "{}");
        const messages = b.messages || [];
        const lat = b.carapace_context?.lat ?? b.lat ?? null;
        const lon = b.carapace_context?.lon ?? b.lon ?? null;
        const scene = b.carapace_context?.scene ?? b.scene ?? null;
        const objects = b.carapace_context?.objects ?? b.objects ?? null;
        const mode = b.carapace_context?.mode || null;
        const agent_id = b.agent_id || null;
        const wantStream = b.stream === true;
        const sessionKey = req.headers["x-openclaw-session-key"] || null;
        const ts = Date.now();

        // Build a compact CURRENT-TURN context hint (lat/lon/scene/objects).
        // memory-core handles long-term recall via its own FTS5 index over
        // ~/.openclaw/workspace/memory/*.md — we no longer maintain a
        // parallel SQL memory layer. The agent can call memory.search()
        // when it needs to recall past turns; this hint just tells it
        // what's true RIGHT NOW that it can't see otherwise.
        const ctxHint = buildContextHint({ lat, lon, scene, objects, mode });

        // Append a structured per-turn record to memory/turns-<date>.md
        // so memory-core picks it up on its next debounced reindex (~1.5s).
        // Future agent.memory.search calls can find this turn by location,
        // scene, or content. Failure here is non-fatal — the chat still
        // runs even if disk write hiccups.
        const lastUser = [...messages].reverse().find(m => m.role === "user");
        const lastUserText = extractText(lastUser?.content);
        try {
          appendTurnRecord({ ts, lat, lon, scene, objects, mode, userText: lastUserText, agent_id });
        } catch (e) {
          console.warn("[chat] turn-record write failed:", e.message);
        }

        // Prepend the hint as a system message — only when we have one.
        // Empty hint = no enrichment, plain forward.
        const enrichedMessages = ctxHint
          ? [{ role: "system", content: ctxHint }, ...messages]
          : messages;

        if (wantStream) {
          console.log("[chat] stream ctx=" + (ctxHint ? ctxHint.length : 0) + "ch mode=" + (mode || "?"));
          await forwardToOpenClawStream(enrichedMessages, agent_id, sessionKey, res, mode, null);
          return;
        }
        const ocResp = await forwardToOpenClaw(enrichedMessages, agent_id);
        res.end(JSON.stringify({
          ...ocResp,
          _carapace: { ctx_chars: ctxHint?.length || 0 },
        }));
      } catch (e) { res.statusCode = 500; res.end(JSON.stringify({ error: e.message, stack: e.stack })); }
      return;
    }



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

    // POST /cron/:id/run — fire a cron job once, right now (debug + iOS button)
    if (req.method === "POST" && p.match(/^\/cron\/[^/]+\/run\/?$/)) {
      const id = decodeURIComponent(p.split("/")[2]);
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      const { execFileSync } = require("child_process");
      const ocCandidates = [
        path.join(os.homedir(), ".npm-global/bin/openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
      ];
      let ocBin = null;
      for (const c of ocCandidates) {
        try { fs.accessSync(c, fs.constants.X_OK); ocBin = c; break; } catch {}
      }
      if (!ocBin) {
        res.writeHead(500); res.end(JSON.stringify({ error: "openclaw binary not found" })); return;
      }
      try {
        const env = { ...process.env, PATH: path.dirname(process.execPath) + ":" + (process.env.PATH || "") };
        execFileSync(ocBin, ["cron", "run", id], { stdio: "pipe", timeout: 10000, env });
        res.end(JSON.stringify({ ok: true, ran: id }));
      } catch (e) {
        res.statusCode = 500;
        res.end(JSON.stringify({ error: e.stderr?.toString() || e.message }));
      }
      return;
    }

    // PATCH /cron/:id — toggle enabled OR reschedule.
    // Body: { "enabled": true | false } → enable/disable
    // Body: { "schedule": "0 9 * * *" }  → cron expression
    // Body: { "schedule": "every 30m" }  → interval
    if (req.method === "PATCH" && p.match(/^\/cron\/[^/]+\/?$/)) {
      const id = decodeURIComponent(p.split("/")[2]);
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      let parsed;
      try { parsed = JSON.parse(body || "{}"); }
      catch { res.writeHead(400); res.end(JSON.stringify({ error: "bad body" })); return; }
      const { execFileSync } = require("child_process");
      const ocCandidates = [
        path.join(os.homedir(), ".npm-global/bin/openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
      ];
      let ocBin = null;
      for (const c of ocCandidates) {
        try { fs.accessSync(c, fs.constants.X_OK); ocBin = c; break; } catch {}
      }
      if (!ocBin) {
        res.writeHead(500); res.end(JSON.stringify({ error: "openclaw binary not found" })); return;
      }
      const env = { ...process.env, PATH: path.dirname(process.execPath) + ":" + (process.env.PATH || "") };
      try {
        // 1) Reschedule branch
        if (typeof parsed.schedule === "string" && parsed.schedule.trim().length > 0) {
          const sched = parsed.schedule.trim();
          // Detect "every Xm" / "every Xh" / "every Xd" → --every flag
          const everyMatch = sched.toLowerCase().match(/^every\s+(\d+)\s*(m|min|minute|h|hr|hour|d|day)/);
          if (everyMatch) {
            const n = everyMatch[1];
            const unit = everyMatch[2].startsWith("m") ? "m"
                       : everyMatch[2].startsWith("h") ? "h" : "d";
            execFileSync(ocBin, ["cron", "edit", id, "--every", n + unit], { stdio: "pipe", timeout: 8000, env });
          } else {
            // Treat as cron expression
            const parts = sched.split(/\s+/);
            if (parts.length !== 5) {
              res.writeHead(400); res.end(JSON.stringify({ error: "schedule must be 5-field cron (e.g. '0 9 * * *') or 'every Xm/h/d'" }));
              return;
            }
            execFileSync(ocBin, ["cron", "edit", id, "--cron", sched], { stdio: "pipe", timeout: 8000, env });
          }
        }
        // 2) Enabled toggle branch (independent — can fire alongside schedule change)
        if (typeof parsed.enabled === "boolean") {
          execFileSync(ocBin, ["cron", parsed.enabled ? "enable" : "disable", id], { stdio: "pipe", timeout: 8000, env });
        }
        res.end(JSON.stringify({ ok: true, id, ...parsed }));
      } catch (e) {
        res.statusCode = 500;
        res.end(JSON.stringify({ error: e.stderr?.toString() || e.message }));
      }
      return;
    }

    // DELETE /cron/:id — delete a cron job
    //
    // BUG FIX: previously edited ~/.openclaw/cron/jobs.json directly.
    // OpenClaw's cron service holds the jobs in memory and writes its
    // state back to jobs.json on its own schedule, RESURRECTING any
    // job we deleted by file edit. The tombstone file existed but
    // didn't prevent the resurrection (deleted IDs were popping right
    // back into the iOS Cron tab a few seconds after delete).
    //
    // Now: shells out to `openclaw cron rm <id>` which goes through
    // the gateway's proper API and tells OpenClaw to actually drop
    // the job from its in-memory state. Then we mirror the change to
    // the carapace tracker file + tombstone for belt-and-suspenders.
    if (req.method === "DELETE" && p.startsWith("/cron/")) {
      const id = decodeURIComponent(p.slice("/cron/".length));
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      let deleted = false;
      const { execSync, execFileSync } = require("child_process");
      // 1) Tell OpenClaw to actually delete it (via the proper API).
      //    PATH must include common locations because the LaunchAgent /
      //    systemd unit gets a minimal env. Try common openclaw locations
      //    in order.
      const ocCandidates = [
        path.join(os.homedir(), ".npm-global/bin/openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
      ];
      let ocBin = null;
      for (const c of ocCandidates) {
        try { fs.accessSync(c, fs.constants.X_OK); ocBin = c; break; } catch {}
      }
      if (ocBin) {
        try {
          // Add the node binary's dir to PATH so openclaw's `#!/usr/bin/env node`
          // shebang resolves under restricted envs.
          const env = { ...process.env, PATH: path.dirname(process.execPath) + ":" + (process.env.PATH || "") };
          execFileSync(ocBin, ["cron", "rm", id], { stdio: "pipe", timeout: 8000, env });
          deleted = true;
        } catch (e) {
          // openclaw may complain if the id doesn't exist — that's fine
          // (we'll still write the tombstone). Capture stderr for debug.
          console.error("[cron rm] openclaw cron rm failed:", e.stderr?.toString() || e.message);
        }
      }
      // 2) Mirror the deletion to ~/.carapace/carapace-cron-tracker.json
      //    so the next iOS poll doesn't show the stale entry briefly.
      try {
        const tfp = path.join(DIR, "carapace-cron-tracker.json");
        if (fs.existsSync(tfp)) {
          const data = JSON.parse(fs.readFileSync(tfp, "utf8"));
          const before = (data.jobs || []).length;
          data.jobs = (data.jobs || []).filter(j => j.id !== id);
          if (data.jobs.length < before) { fs.writeFileSync(tfp, JSON.stringify(data)); deleted = true; }
        }
      } catch (e) {}
      // 3) Tombstone — sync-trackers.sh checks this list and won't
      //    re-add an ID that's been tombstoned, even if it briefly
      //    reappears in `openclaw cron list` output (race during
      //    OpenClaw's in-memory state propagation).
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
    // `?agent=<id>` selects which agent's PROJECTS.md to read/write.
    // Defaults to "main" when omitted (backward compat).
    const agentParam = qs.get("agent") || "main";

    if (req.method === "PUT") {
      const projMatch = p.match(/^\/projects\/([^/]+)\/prompt\/?$/);
      const wsMatch = p.match(/^\/projects\/([^/]+)\/workstreams\/([^/]+)\/prompt\/?$/);
      if (projMatch || wsMatch) {
        try {
          const payload = JSON.parse(body || "{}");
          let result;
          if (wsMatch) {
            const [, pid, wid] = wsMatch;
            result = projectsUpdateWorkstreamPrompt(agentParam, decodeURIComponent(pid), decodeURIComponent(wid), payload.focusPrompt);
          } else {
            const [, pid] = projMatch;
            result = projectsUpdateProjectPrompt(agentParam, decodeURIComponent(pid), payload.divePrompt || payload.focusPrompt);
          }
          if (result.error) { res.writeHead(result.status || 500); res.end(JSON.stringify(result)); return; }
          res.end(JSON.stringify(result));
        } catch (e) {
          res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
        }
        return;
      }
    }

    // PATCH /projects/:id/status?agent=<id> — flip status (e.g.
    // promote a "suggested" project to "green" when the user taps
    // Convert in the iOS long-press menu). Body: {status: "green"
    // [, progress: 0]}.
    if (req.method === "PATCH") {
      const statusMatch = p.match(/^\/projects\/([^/]+)\/status\/?$/);
      if (statusMatch) {
        try {
          const payload = JSON.parse(body || "{}");
          const result = projectsUpdateStatus(
            agentParam,
            decodeURIComponent(statusMatch[1]),
            payload.status,
            payload.progress
          );
          if (result.error) { res.writeHead(result.status || 500); res.end(JSON.stringify(result)); return; }
          res.end(JSON.stringify(result));
        } catch (e) {
          res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
        }
        return;
      }
    }

    // DELETE /projects/:id?agent=<id> — remove project from this
    // agent's PROJECTS.md.
    if (req.method === "DELETE" && p.startsWith("/projects/") && !p.includes("/cron/")) {
      const id = decodeURIComponent(p.slice("/projects/".length));
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      const result = projectsDelete(agentParam, id);
      if (result.error) { res.writeHead(result.status || 500); res.end(JSON.stringify(result)); return; }
      res.end(JSON.stringify(result));
      return;
    }

    // Live agent status — built from OpenClaw session files
    if (p === "/status" || p === "/agents") {
      res.end(JSON.stringify(getLiveAgentStatus()));
      return;
    }

    // GET /projects?agent=<id> + /tracker?agent=<id> — sourced from
    // <agent-workspace>/PROJECTS.md. Per-agent: each agent has its
    // own board. Default agent=main when omitted.
    if (p === "/projects" || p === "/tracker") {
      if (!isTierPaid()) { res.end(EMPTY_PROJECTS); return; }
      try { res.end(JSON.stringify(projectsBuildResponse(agentParam))); }
      catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
      return;
    }

    // /cron — live query against openclaw's cron list. Replaces the
    // old tracker.json fallback (which depended on a periodic sync
    // script that we've since dismantled). Always includes disabled
    // jobs and sorts by most-recently-ran first per Mike's spec.
    if (p === "/cron") {
      if (!isTierPaid()) { res.end(EMPTY_CRON); return; }
      try { res.end(JSON.stringify(buildCronPayload())); }
      catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
      return;
    }

    // Other file-backed endpoints still read from disk.
    const filePath = fileMap[p] ? path.join(DIR, fileMap[p]) : null;
    if (filePath) {
      try { res.end(fs.readFileSync(filePath, "utf8")); }
      catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); }
      return;
    }

    res.writeHead(404); res.end(JSON.stringify({ error: "not found" }));
  });
}).listen(18794, "127.0.0.1", () => console.log("CARAPACE Status Server on :18794"));
