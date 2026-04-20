const http = require("http"), fs = require("fs"), path = require("path"), os = require("os");
const DIR = path.join(os.homedir(), ".carapace");
const OC_DIR = path.join(os.homedir(), ".openclaw");
const TRACKER_PORT = 18795; // python project-tracker-server

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

/// Build live agent status from OpenClaw session files
function getLiveAgentStatus() {
  try {
    const agentsRoot = path.join(OC_DIR, "agents");
    if (!fs.existsSync(agentsRoot)) return buildFallbackStatus("idle", "No agents directory");

    const agents = {};
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
          const agentLabel = agent === "main" ? "Main" :
            agent.replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase());
          const agentKey = agent === "main" ? "main" : agent;
          agents[agentKey] = {
            name: agentLabel,
            status: isRunning ? "active" : "idle",
            detail: isRunning ? "Processing" : "Ready",
            updated: new Date(updatedAt).toLocaleTimeString()
          };
        } else if (isSubagent) {
          // Subagents: only show if running AND updated within last 2 hours (stale ghost filter)
          // Show subagents while running OR within 20 seconds of completion
          if (ageMs > twoHours) continue;
          if (!isRunning && ageMs > 20000) continue;
          agents[agentId] = {
            name: `Subagent ${agentId}`,
            status: "active",
            detail: entry.lastChannel || "isolated task",
            parent: "main",
            updated: new Date(updatedAt).toLocaleTimeString()
          };
        }
      }
    }

    if (!agents["main"]) {
      agents["main"] = { name: "Main", status: "idle", detail: "Ready", updated: new Date().toLocaleTimeString() };
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

    if (p === "/history") {
      const agent = qs.get("agent") || "main";
      res.end(JSON.stringify(loadHistory(Math.min(limit, 200), token, agent)));
      return;
    }

    if (p === "/sessions") {
      const agentsRoot = path.join(OC_DIR, "agents");
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

    // PUT /projects/:id/prompt and PUT /projects/:id/workstreams/:wid/prompt
    // — proxy to python tracker at :18795 which owns the canonical tracker.json
    if (req.method === "PUT" && /^\/projects\/[^/]+\/(prompt|workstreams\/[^/]+\/prompt)\/?$/.test(p)) {
      proxyToTracker("PUT", p, body, res);
      return;
    }

    // DELETE /projects/:id — delete a project
    if (req.method === "DELETE" && p.startsWith("/projects/")) {
      const id = decodeURIComponent(p.slice("/projects/".length));
      if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; }
      const fp = path.join(DIR, "carapace-project-tracker.json");
      try {
        const data = JSON.parse(fs.readFileSync(fp, "utf8"));
        const before = data.projects.length;
        data.projects = data.projects.filter(proj => proj.id !== id);
        if (data.projects.length === before) { res.writeHead(404); res.end(JSON.stringify({ error: "project not found" })); return; }
        data.updated = new Date().toISOString();
        fs.writeFileSync(fp, JSON.stringify(data));
        res.end(JSON.stringify({ ok: true, deleted: id }));
      } catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
      return;
    }

    // Live agent status — built from OpenClaw session files
    if (p === "/status" || p === "/agents") {
      res.end(JSON.stringify(getLiveAgentStatus()));
      return;
    }

    const filePath = fileMap[p] ? path.join(DIR, fileMap[p]) : null;
    if (filePath) {
      // Gate tracking endpoints behind paid tier
      if (!isTierPaid()) {
        if (p === "/projects" || p === "/tracker") { res.end(EMPTY_PROJECTS); return; }
        if (p === "/cron") { res.end(EMPTY_CRON); return; }
      }
      try { res.end(fs.readFileSync(filePath, "utf8")); }
      catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); }
      return;
    }

    res.writeHead(404); res.end(JSON.stringify({ error: "not found" }));
  });
}).listen(18794, "127.0.0.1", () => console.log("CARAPACE Status Server on :18794"));
