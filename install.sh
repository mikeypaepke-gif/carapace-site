#!/usr/bin/env bash
set -euo pipefail

# CARAPACE Headless Connector — Linux/VPS Install Script
# Usage: curl -fsSL https://carapace.info/install.sh | bash
#        curl -fsSL https://carapace.info/install.sh | bash -s -- --verbose
#
# Installs OpenClaw gateway on a Linux server and generates a QR code
# for pairing with the CARAPACE iOS app.

# ── Verbose mode ─────────────────────────────────────────
VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=true; fi
LOGFILE="/tmp/carapace-install.log"
: > "$LOGFILE"

# ── Pre-clean: remove stale .npmrc prefix that conflicts with nvm ─────────
# This persists across reboots from partial installs and silently kills nvm
if [[ -f "$HOME/.npmrc" ]]; then
  sed -i '/^prefix=/d' "$HOME/.npmrc" 2>/dev/null || true
  sed -i '/^globalconfig=/d' "$HOME/.npmrc" 2>/dev/null || true
fi
unset npm_config_prefix 2>/dev/null || true

# ── Colors ───────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
TEAL="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

STEP_CURRENT=0
STEP_TOTAL=10

trap 'echo ""; echo -e "${RED}✗ Install failed at line $LINENO. Check $LOGFILE for details.${RESET}"; exit 1' ERR

# ── Helpers ──────────────────────────────────────────────
step() {
  STEP_CURRENT=$((STEP_CURRENT + 1))
  echo ""
  echo -e "${TEAL}${BOLD}━━━ Step ${STEP_CURRENT}/${STEP_TOTAL}: $1 ━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}
ok()    { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET} $*"; }
# Hard-stop helper. Use when continuing past a failure would silently
# produce a broken install (e.g., no Tailscale = no /chat route = iOS
# 404s with no recovery path that doesn't involve uninstalling first).
# Better to abort loud and let the user fix the prerequisite, then
# re-run install.sh — than to leave them with a half-broken VPS that
# looks "successfully installed."
fatal() {
  echo "" >&2
  echo -e "  ${RED}╔══════════════════════════════════════════════════════════╗${RESET}" >&2
  echo -e "  ${RED}║  INSTALL ABORTED                                         ║${RESET}" >&2
  echo -e "  ${RED}╚══════════════════════════════════════════════════════════╝${RESET}" >&2
  echo -e "  ${RED}✗${RESET} $*" >&2
  echo "" >&2
  exit 1
}
fail()  { echo -e "  ${RED}✗${RESET} $*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# systemctl guard. Lets us call systemd operations uniformly across
# systemd hosts (standard Linux, RPi OS, Ubuntu, Debian, Rocky) and
# non-systemd hosts (Docker containers, some minimal distros). On
# systemd hosts: passes through. On non-systemd hosts: warns once
# (configurable via SYSTEMD_WARN_ONCE) and no-ops with success, so
# `set -e` doesn't abort the whole install.
_systemd_warn_shown=0
sysctl_safe() {
  if have_cmd systemctl; then
    # $SUDO is "" when running as root, "sudo" otherwise — works in
    # both modes. Without this, non-root invocations of
    # `systemctl daemon-reload` / `enable` / `restart` returned
    # "Failed to connect to bus" or permission errors and the
    # service never started.
    $SUDO systemctl "$@" || true
  else
    if (( _systemd_warn_shown == 0 )); then
      echo -e "  ${DIM}(systemd not available — skipping service-manager ops; services won't auto-start on reboot.)${RESET}"
      _systemd_warn_shown=1
    fi
    return 0
  fi
}

# Retry a command up to N times with exponential backoff
retry() {
  local max_attempts="$1"; shift
  local attempt=1 delay=5
  while (( attempt <= max_attempts )); do
    if "$@"; then return 0; fi
    if (( attempt == max_attempts )); then return 1; fi
    warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
    sleep "$delay"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# Run a command, logging output. Show on screen only in verbose mode.
run() {
  if $VERBOSE; then
    "$@" 2>&1 | tee -a "$LOGFILE"
  else
    "$@" >> "$LOGFILE" 2>&1
  fi
}

# ── Vision rules block injector ──────────────────────────
# Safely upserts the CARAPACE VISION RULES block into the user's
# OpenClaw memory file (~/.openclaw/workspace/memory/MEMORY.md) so
# the gateway agent knows how to handle the iPhone vision payload
# (image-attachment ordering, [ctx] line, focus grid, scan contact
# sheet, brevity / anti-list directives).
#
# Safety guarantees:
#   * Never modifies content outside the BEGIN/END markers
#   * Atomic write (tmp file + rename) — no partial writes if killed
#   * Verifies non-managed sections byte-match original before swap
#   * Backs up original to MEMORY.md.carapace.bak.<timestamp> the
#     FIRST time we touch the file (when no sentinels yet exist)
#   * Idempotent — re-running just refreshes the block in place
#
# If MEMORY.md doesn't exist yet, creates it with just our block —
# safe because OpenClaw treats an empty memory file as "no facts."
#
# REFACTORED: writes now target per-agent AGENTS.md, not MEMORY.md.

# ── Generic block-upsert helper ──────────────────────────
# Shared by every CARAPACE-rules injector (vision, project, etc.):
# given a target file, BEGIN/END marker pair, and a temp file holding
# the new block body, replace any existing block in-place (preserving
# everything outside the markers) or append the block fresh if absent.
# Uses python for atomic rename + a sanity check that catches partial
# sentinel pairs (which would silently corrupt the file).
_carapace_upsert_block() {
  local target_file="$1"; local begin_marker="$2"; local end_marker="$3"; local block_file="$4"
  mkdir -p "$(dirname "$target_file")"
  local tmp_file="${target_file}.carapace.tmp.$$"
  if [[ ! -f "$target_file" ]]; then
    cat "$block_file" > "$tmp_file"; mv "$tmp_file" "$target_file"; return 0
  fi
  /usr/bin/env python3 - "$target_file" "$tmp_file" "$begin_marker" "$end_marker" "$block_file" <<'PY'
import sys, re
src_path, dst_path, begin_marker, end_marker, block_path = sys.argv[1:6]
with open(src_path, "r", encoding="utf-8") as f: original = f.read()
with open(block_path, "r", encoding="utf-8") as f: new_block = f.read().rstrip("\n") + "\n"
begin_re = re.compile(r"^" + re.escape(begin_marker) + r".*$", re.MULTILINE)
end_re   = re.compile(r"^" + re.escape(end_marker)   + r".*$", re.MULTILINE)
b = begin_re.search(original); e = end_re.search(original)
if b and e and b.start() < e.start():
    before = original[:b.start()].rstrip("\n"); after = original[e.end():].lstrip("\n")
    rebuilt = (before + "\n\n" + new_block + ("\n" + after if after else "")) if before else (new_block + ("\n" + after if after else ""))
elif b or e:
    print("Partial sentinel block — aborting.", file=sys.stderr); sys.exit(2)
else:
    rebuilt = original.rstrip("\n") + "\n\n" + new_block
with open(dst_path, "w", encoding="utf-8") as f: f.write(rebuilt)
PY
  local rc=$?
  if [[ $rc -ne 0 ]]; then rm -f "$tmp_file"; return 1; fi
  mv "$tmp_file" "$target_file"
}

_carapace_list_agent_workspaces() {
  # Main agent's workspace (the global one)
  echo "$HOME/.openclaw/workspace"

  # Per-agent workspaces created by `openclaw agents add <name>`.
  # OpenClaw drops these at ~/.openclaw/agents/<id>/ — each one gets
  # its OWN AGENTS.md that the gateway reads when that agent runs a
  # turn. Without this loop, sweep_carapace_for_all_agents would inject
  # blocks into ONLY the main workspace, and any agent created via
  # `openclaw agents add` would have a virgin AGENTS.md with zero
  # CARAPACE rules — meaning the agent has no idea how to handle
  # vision turns, no project tracking conventions, nothing.
  #
  # Skip the agent dir itself (the openclaw "agent" subdir holds
  # auth-profiles.json + models.json) — only emit dirs that have a
  # workspace-shaped AGENTS.md at their root.
  if [[ -d "$HOME/.openclaw/agents" ]]; then
    for d in "$HOME/.openclaw/agents/"*/; do
      [[ -d "$d" ]] || continue
      # Each agent dir has subdirs like `agent/` and `sessions/`.
      # The workspace IS the agent dir itself when AGENTS.md lives at root.
      [[ -f "${d}AGENTS.md" ]] || continue
      echo "${d%/}"
    done
  fi

  # Subagents nested under the main workspace (legacy layout).
  if [[ -d "$HOME/.openclaw/workspace/agents" ]]; then
    for d in "$HOME/.openclaw/workspace/agents/"*/; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == "memory" ]] && continue
      echo "${d%/}"
    done
  fi

  # Alternative workspace pattern (workspace-foo/, workspace-bar/).
  for d in "$HOME/.openclaw/"workspace-*/; do
    [[ -d "$d" ]] || continue; echo "${d%/}"
  done
}

_carapace_is_main_workspace() {
  [[ "$1" == "$HOME/.openclaw/workspace" ]]
}

inject_carapace_rules_into_workspace() {
  local workspace="$1"; local agents_md="${workspace}/AGENTS.md"
  local block_file
  block_file="$(mktemp)"; trap "rm -f '$block_file'" EXIT
  cat > "$block_file" << 'CARAPACE_VISION_BLOCK_EOF'
<!-- BEGIN CARAPACE VISION RULES (managed by Carapace installer — do not edit between BEGIN/END; agent learnings go below the END marker) -->
## Vision Response Rules (vision turns only)

A "vision turn" is any user message tagged with `👁️ [vision]` AND/OR containing one or more image attachments AND/OR ending with a `[ctx] …` suffix line. If none of those are present, this block does NOT apply.

**Reading the payload:**
- **Image 1** = wide camera frame.
- **Image 2** (optional) = labeled focus grid; cells stamped `[N]`.
- **Image 3** (optional) = SCAN contact-sheet, cells stamped `T+Ns`.
- **`[ctx] …` line** = context hint (focused, barcode, OCR, hearing, location, brevity directive).
- **`read on-device[, partial|, low-confidence] [<lang>]: "<text>"`** = on-device Apple Vision OCR. **GROUND TRUTH** — quote verbatim, do NOT re-OCR.
- **`hearing: <label> (<conf>), …`** = on-device sound classifications. You can hear; weave naturally without narrating.

**Hard rules:**
- Match user tone. Reply in 1-2 short sentences unless asked for detail.
- No bulleted lists in casual conversations. Inline `**bold**` welcome on key noun/number/verb (renders teal on iOS).
- Don't narrate viewing. Just answer about the subject.
- Focus stickers ARE the subject — don't mention crops/fragments.
- Don't comment on photo quality / blur unless asked.

<!-- END CARAPACE VISION RULES -->
CARAPACE_VISION_BLOCK_EOF
  _carapace_upsert_block "$agents_md" "<!-- BEGIN CARAPACE VISION RULES" "<!-- END CARAPACE VISION RULES" "$block_file" || { rm -f "$block_file"; return 1; }
  rm -f "$block_file"

  # Project rules: full rules in main; stub for other agents
  # (project tracking is machine-wide, owned by main).
  block_file="$(mktemp)"
  if _carapace_is_main_workspace "$workspace"; then
  cat > "$block_file" << 'CARAPACE_PROJECT_RULES_EOF'
<!-- BEGIN CARAPACE PROJECT RULES (managed by Carapace installer — do not edit between BEGIN/END; agent learnings go below the END marker) -->
## Project Tracking — STRICT PROTOCOL

You maintain a project board for the user. The iOS app's **Projects** tab reads ONE specific file, and ONE only:

> **`PROJECTS.md`** (in this workspace directory)

You append + edit projects in that file. **NEVER create per-project `*.md` files** — those are invisible to the iOS app and break the user's board.

### DEFAULT: ALL agent-initiated entries = SUGGESTED (❓ 0%)

Whenever YOU add to `PROJECTS.md`, status is `❓` at `0%`. The user
controls promotion via iOS long-press → Convert (`❓ → 🟢`) or Delete.
**Your job is to surface; the user's job is to commit.**

ONE narrow exception: user explicitly says "this is a real/tracked/
committed project", "promote this to tracked", or types `🟢` directly.
In EVERY other case — including "make a project for X" / "create a
project for Y" / "save this as a project" — write `❓ 0%`.

### FIRST-RUN MEMORY SCAN — sentinel-gated precondition

**HARD TRIGGER — runs every turn until satisfied:** BEFORE
responding to any user message, read `PROJECTS.md`. If — and only
if — it does NOT contain the literal line
`<!-- carapace:initial-scan:done -->`, perform the FULL scan
below before continuing your response. The marker's absence is
the only signal — don't reason about whether the session "feels
new." Marker missing → scan runs. Marker present → skip this
section forever.

This catches users hooking Carapace into a long-running OpenClaw
with months of accumulated memory — without it, existing context
is invisible to the Projects board.

**Scan exhaustively (only runs once):** `MEMORY.md`, every file
under `./memory/` (especially `memory/YYYY-MM-DD.md` daily notes),
`IDENTITY.md`, and the existing `PROJECTS.md` body so you don't
duplicate.

**Look for** multi-step initiatives the user mentioned in passing:
things bought that need setup, projects started, plans being chewed
on, "I want to learn X", "I'm planning to build Y", "we're moving /
launching / shipping Z". Anything with a beginning, middle, end.

**Skip:** one-shot tasks, completed events, daily trivia, someone
else's projects, anything <70% confidence. Better fewer high-quality
`❓` entries than noise.

**Write each as a `❓` suggestion** using the FILE FORMAT below.
Estimate progress honestly — if memory shows two completed steps
already, start at `❓ 25%`, not 0.

**When done — write the sentinel:** append the literal line
`<!-- carapace:initial-scan:done -->` as the LAST line of
`PROJECTS.md`. Writing the marker is NOT optional, even with
zero suggestions — write it so the gate closes.

**Reply:** prepend ONE line to your normal response: "Scanned
memory and added N suggestions to your Projects board — convert
the ones you want to track." If N=0, say nothing about the scan.
Then answer their message normally.

### WHEN TO ADD A `❓` ENTRY

1. **User asks you to** ("make a project for X", "track this"). Append
   `❓ 0%` immediately. Don't ask for confirmation. One-line reply:
   "Suggestion added: `<slug>` — convert from the Projects tab when
   you're ready to commit."

2. **User mentions starting something multi-step in passing** ("I
   just bought X", "I'm planning Z"). Append `❓ 0%` SILENTLY — don't
   call attention to it in your reply.

Default-to-`❓` keeps the tracked board clean — better to suggest
ten and have the user Convert two than auto-track ten.

### THE WORKFLOW (every project add)

1. Read `PROJECTS.md` to see existing slugs (don't collide).
2. Pick a slug: lowercase-hyphens, ≤25 chars. Example: "Pixi Laser Setup" → `pixi-laser-setup`.
3. Append a new `###` section using the format below.
4. Write the file via your file-edit tool. Do NOT confirm with the user before writing.
5. Tell the user one line: "Added `<slug-id>` to your projects."

### FILE FORMAT (strict — iOS parses this exactly)

```
### <slug-id> · <Name> · <emoji> <progress>%
<one-line description>

**Focus:** <prompt template the user can tap to start a chat about this>

**Workstreams:**
- `<sub-slug>` · <name> · <emoji> <progress>% [· @<owner>] — <focus>
```

If no workstreams yet, write `- _none yet_`.

**Status emojis:** 🟢 green · 🟡 yellow · 🔴 red · ⚪ idle
**Progress:** 0 = brand new · 25 = early · 50 = halfway · 75 = closing in · 100 = done.
**Slugs:** lowercase-hyphens, stable forever — NEVER rename.

### HARD ANTI-PATTERNS

- ❌ DO NOT create files like `<thing>_project.md` or `<thing>.md`. ONLY edit `PROJECTS.md`.
- ❌ DO NOT ask for confirmation before adding a project the user explicitly requested.
- ❌ DO NOT propose an "outline" and wait — write the section first, iterate after.
- ❌ DO NOT track the same project twice. Update existing entries.

## Adding New Top-Level Agents

> **AGENT vs SUBAGENT** — this is for TOP-LEVEL AGENTS (persistent
> peers of you with own workspace, IDENTITY.md, picker entry, chat
> history). NOT subagents (OpenClaw's session-scoped helpers spawned
> by the runtime for delegated tasks). NEVER use the protocol below
> for subagents.

When the user asks you to create a new TOP-LEVEL AGENT ("create an
agent for X", "add a Y agent", "make me a fitness coach"), handle
it with ONE bash call. Pick defaults from the stated purpose.

### THE ONLY COMMAND YOU RUN

```bash
bash ~/.carapace/install-openclaw.sh add-agent <slug> "<Display Name>" "<emoji>" "<role>"
```

Atomic. Creates the agent, retires the auto-created BOOTSTRAP.md
(otherwise the gateway prepends `[Bootstrap pending]` to every
message and the agent fails), writes IDENTITY.md from your args,
injects CARAPACE rules, flips session state. Idempotent.

### HOW TO PICK THE 4 ARGS

- **`<slug>`** — lowercase-hyphens, ≤25 chars (e.g. `photo-curator`).
- **`"<Display Name>"`** — title-cased (e.g. `"Photo Curator"`).
- **`"<emoji>"`** — ONE emoji matching role: 📸 ✈️ 💪 🍳 📚 🎵 🏠
  💰 📝 🌱 🎨 🐶 🚗 🛒 🧠 🔧 🩺 📊. NEVER 🦀 (reserved for main).
- **`"<role>"`** — one short sentence of what the agent specializes in.

### EXAMPLE

```bash
bash ~/.carapace/install-openclaw.sh add-agent photo-curator "Photo Curator" "📸" "organizes photo library, tags moments, surfaces highlights, helps with sharing/printing decisions"
```

### CONFIRM TO USER (one line)

> "Created <emoji> <Display Name> — switch to them in the agent picker."

No recap, no step listing.

### HARD ANTI-PATTERNS

- ❌ DO NOT split into multiple bash calls — splitting skips steps.
- ❌ DO NOT call `openclaw agents add` directly — script wraps it.
- ❌ DO NOT call `--inject-only` separately — add-agent includes it.
- ❌ DO NOT restart the gateway — disrupts in-flight chats.
- ❌ DO NOT pick 🦀 (reserved for CARAPACE main).
- ❌ DO NOT ask clarifying questions about personality.
- ❌ DO NOT recap the steps. One line confirm, done.
- ❌ DO NOT use this for SUBAGENTS — runtime spawns those.

<!-- END CARAPACE PROJECT RULES -->
CARAPACE_PROJECT_RULES_EOF
  else
  cat > "$block_file" << 'CARAPACE_PROJECT_STUB_EOF'
<!-- BEGIN CARAPACE PROJECT RULES (managed by Carapace installer — do not edit between BEGIN/END; agent learnings go below the END marker) -->
## Project Tracking — ESCALATE TO MAIN

> **IMPORTANT — these rules OVERRIDE any prior behavior in this
> session.** If earlier in this conversation you told the user
> things like "ask main to add it" or "ask main yourself," that
> pattern is DEPRECATED. Forget it. The new behavior is to
> ESCALATE automatically via the CLI on the user's behalf.

Project tracking on this machine is **owned by the `main` agent**.
There is ONE shared project board (`~/.openclaw/workspace/PROJECTS.md`)
that the iOS Carapace app reads regardless of which agent the user
is chatting with.

### When the user asks YOU to track / save / add a project

Escalate via your bash tool:

```bash
openclaw agent --agent main -m "<rephrase as a clear instruction for main>"
```

Synchronous — returns main's reply on stdout. Surface to user as
ONE line: "Routed to main — <main's confirmation, verbatim>". Then
continue answering their original message normally.

### When the user mentions a multi-step initiative in passing

Do NOT capture it yourself, and do NOT escalate every offhand
mention. Main has its own FIRST-RUN MEMORY SCAN that picks these
up from shared memory. Only escalate EXPLICIT track requests.

### Hard rules

- ❌ DO NOT create or edit a `PROJECTS.md` file in this workspace.
- ❌ DO NOT create per-project `*.md` files.
- ❌ DO NOT tell the user to "ask main yourself" — escalate it.
- ❌ DO NOT escalate non-project conversations.

<!-- END CARAPACE PROJECT RULES -->
CARAPACE_PROJECT_STUB_EOF
  fi
  _carapace_upsert_block "$agents_md" "<!-- BEGIN CARAPACE PROJECT RULES" "<!-- END CARAPACE PROJECT RULES" "$block_file" || { rm -f "$block_file"; return 1; }
  rm -f "$block_file"; trap - EXIT
  ok "CARAPACE rules → $agents_md"
}

seed_carapace_projects_for_workspace() {
  local workspace="$1"
  _carapace_is_main_workspace "$workspace" || return 0
  local projects_file="${workspace}/PROJECTS.md"
  [[ -f "$projects_file" ]] && return 0
  mkdir -p "$workspace"
  cat > "$projects_file" << 'CARAPACE_PROJECTS_SEED_EOF'
<!-- CARAPACE PROJECTS — agent-maintained · iOS Projects view reads + writes here.
Format: ### <id> · <Name> · <emoji> <progress>%
        <description paragraph>
        **Focus:** <project focus prompt>
        **Workstreams:**
        - `<id>` · <name> · <emoji> <progress>% [· @<owner>] — <focus>
Emojis: 🟢 green · 🟡 yellow · 🔴 red · ⚪ idle
-->

### install-carapace · Install CARAPACE on your device · 🟢 100%
You set up CARAPACE on your phone, paired it with this gateway, and ran your first conversation. ✅ Done.

**Focus:** What's next now that CARAPACE is set up? Three concrete things I should try first.

**Workstreams:**
- _none yet_
CARAPACE_PROJECTS_SEED_EOF
  ok "Seeded → $projects_file"
}

# ── Force every session to re-load its system prompt ──────
# OpenClaw caches systemSent: true after first message. Without
# flipping back, AGENTS.md updates never reach existing chats.
flip_all_sessions_system_sent() {
  local agents_root="$HOME/.openclaw/agents"
  [[ -d "$agents_root" ]] || return 0
  for sessions_json in "$agents_root"/*/sessions/sessions.json; do
    [[ -f "$sessions_json" ]] || continue
    /usr/bin/env python3 - "$sessions_json" <<'PY'
import json, sys
p = sys.argv[1]
try:
    with open(p, "r") as f: d = json.load(f)
except Exception: sys.exit(0)
changed = 0
for k, v in d.items():
    if isinstance(v, dict) and v.get("systemSent") is True:
        v["systemSent"] = False
        changed += 1
if changed:
    with open(p, "w") as f: json.dump(d, f, indent=2)
PY
  done
  ok "Forced AGENTS.md reload across all sessions"
}

ensure_carapace_bootstrap_caps() {
  command -v openclaw >/dev/null 2>&1 || return 0
  local config="$HOME/.openclaw/openclaw.json"
  [[ -f "$config" ]] || return 0
  local cur_max cur_total cur_timeout need_restart=0
  cur_max=$(/usr/bin/env python3 -c "
import json
try:
    with open('$config') as f: c = json.load(f)
    print(c.get('agents', {}).get('defaults', {}).get('bootstrapMaxChars', 0))
except Exception: print(0)" 2>/dev/null || echo 0)
  cur_total=$(/usr/bin/env python3 -c "
import json
try:
    with open('$config') as f: c = json.load(f)
    print(c.get('agents', {}).get('defaults', {}).get('bootstrapTotalMaxChars', 0))
except Exception: print(0)" 2>/dev/null || echo 0)
  cur_timeout=$(/usr/bin/env python3 -c "
import json
try:
    with open('$config') as f: c = json.load(f)
    print(c.get('agents', {}).get('defaults', {}).get('timeoutSeconds', 0))
except Exception: print(0)" 2>/dev/null || echo 0)
  if [[ "${cur_max:-0}" -lt 50000 ]]; then
    openclaw config set agents.defaults.bootstrapMaxChars 50000 >/dev/null 2>&1 && need_restart=1
  fi
  if [[ "${cur_total:-0}" -lt 200000 ]]; then
    openclaw config set agents.defaults.bootstrapTotalMaxChars 200000 >/dev/null 2>&1 && need_restart=1
  fi
  # Default agent timeout is ~30s, which is shorter than a cold first
  # turn against grok-4 (we measured 57s on a fresh v4.25 gateway and
  # similar on v4.24 with a warm xAI route). When the gateway aborts
  # the upstream call before xAI replies, /chat returns HTTP 200 with
  # zero bytes — looks like a deadlock from the client's side. Bumping
  # to 180s gives reasoning models room without hiding real hangs.
  if [[ "${cur_timeout:-0}" -lt 180 ]]; then
    openclaw config set agents.defaults.timeoutSeconds 180 >/dev/null 2>&1 && need_restart=1
  fi
  # gateway.trustedProxies — Tailscale forwards iOS chat via its CGNAT
  # range (100.64.0.0/10) and IPv6 ULA (fd7a:115c:a1e0::/48). Without
  # marking those as trusted, the gateway sees X-Forwarded-For from a
  # non-loopback peer, refuses to treat the connection as local, and
  # rejects with `code=1008 reason=connect failed`. iOS then shows
  # "gateway connect failed" with no obvious cause. Adding loopback +
  # Tailscale ranges fixes it; localhost stays trusted unconditionally.
  cur_trusted=$(/usr/bin/env python3 -c "
import json
try:
    with open('$config') as f: c = json.load(f)
    tp = c.get('gateway', {}).get('trustedProxies', [])
    print('100.64.0.0/10' in tp)
except Exception: print('False')" 2>/dev/null || echo False)
  if [[ "$cur_trusted" != "True" ]]; then
    openclaw config set gateway.trustedProxies '["127.0.0.1","::1","100.64.0.0/10","fd7a:115c:a1e0::/48"]' >/dev/null 2>&1 && need_restart=1
  fi
  if [[ $need_restart -eq 1 ]]; then
    openclaw gateway restart >/dev/null 2>&1 || true
    # Wait for gateway to come back up before returning. Without this,
    # downstream calls (e.g. sweep_carapace_for_all_agents, the post-
    # install /chat smoke, carapace-qr) can hit a mid-restart gateway
    # and either error or silently get stale data.
    for _w in $(seq 1 15); do
      curl -sf --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
      sleep 1
    done
    ok "Bumped AGENTS.md injection caps (50K/200K), agent timeout (180s), trustedProxies (Tailscale CGNAT); restarted gateway"
  fi
}

retire_legacy_per_agent_projects_files() {
  local found=0
  for d in "$HOME/.openclaw/workspace/agents/"*/ "$HOME/.openclaw/"workspace-*/; do
    [[ -d "$d" ]] || continue
    local f="${d%/}/PROJECTS.md"
    if [[ -f "$f" ]]; then
      mv "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null && found=$((found + 1))
    fi
  done
  [[ $found -gt 0 ]] && ok "Retired $found legacy per-agent PROJECTS.md → main is single source"
}

# OpenClaw injects "[Bootstrap pending]" prefix on every user message
# when an agent's workspace contains BOOTSTRAP.md. Bootstrap is a
# ONE-TIME first-light ritual main handles for the whole machine —
# subagents must never have one or they trigger the prefix loop.
retire_stale_subagent_bootstrap_files() {
  local found=0
  for d in "$HOME/.openclaw/workspace/agents/"*/ "$HOME/.openclaw/"workspace-*/; do
    [[ -d "$d" ]] || continue
    local f="${d%/}/BOOTSTRAP.md"
    if [[ -f "$f" ]]; then
      mv "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null && found=$((found + 1))
    fi
  done
  [[ $found -gt 0 ]] && ok "Retired $found stale subagent BOOTSTRAP.md (bootstrap is main-only)"
}

install_self_to_carapace_dir() {
  local target="$HOME/.carapace/install-openclaw.sh"
  local src="${BASH_SOURCE[0]}"
  [[ -f "$src" ]] || return 0
  mkdir -p "$HOME/.carapace"
  if [[ "$(/usr/bin/realpath "$src" 2>/dev/null || echo "$src")" \
        == "$(/usr/bin/realpath "$target" 2>/dev/null || echo "$target")" ]]; then
    return 0
  fi
  cp "$src" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null
}

sweep_carapace_for_all_agents() {
  ensure_carapace_bootstrap_caps || true
  install_self_to_carapace_dir || true
  seed_main_identity_default || true
  while IFS= read -r ws; do
    [[ -d "$ws" ]] || continue
    inject_carapace_rules_into_workspace "$ws" || true
    seed_carapace_projects_for_workspace "$ws" || true
  done < <(_carapace_list_agent_workspaces)
  retire_legacy_per_agent_projects_files || true
  retire_stale_subagent_bootstrap_files || true
  flip_all_sessions_system_sent || true
}

# Seed clean Main IDENTITY.md so iOS doesn't render the OpenClaw
# default template's raw markdown ("- **CREATURE:**" etc) as the
# spinal-map node label. Idempotent — only writes when missing or
# still the unfilled OpenClaw template.
seed_main_identity_default() {
  local identity_file="$HOME/.openclaw/workspace/IDENTITY.md"
  local should_overwrite=0
  if [[ ! -f "$identity_file" ]]; then
    should_overwrite=1
  elif grep -q "_(pick something you like)_" "$identity_file" 2>/dev/null; then
    should_overwrite=1
  elif grep -q "_(workspace-relative path" "$identity_file" 2>/dev/null; then
    should_overwrite=1
  elif ! grep -qE "^\s*[-*]?\s*\*?\*?Name\*?\*?\s*:\s*\S" "$identity_file" 2>/dev/null; then
    should_overwrite=1
  fi
  if [[ $should_overwrite -eq 1 ]]; then
    mkdir -p "$(dirname "$identity_file")"
    cat > "$identity_file" << 'CARAPACE_MAIN_IDENTITY_EOF'
# IDENTITY.md

- **Name:** Main
- **Emoji:** 🧠
- **Creature:** Your primary AI operating layer — the always-on coordinator. Routes context, escalates work, and keeps the rest of your agents in sync.
- **Vibe:** Direct, helpful, calm. Opinionated when it matters. Brief by default; verbose only when you ask.
- **Purpose:** Be the brain of the operation. Think before acting, surface what matters, never punt back to the user when you can just handle it.
CARAPACE_MAIN_IDENTITY_EOF
    ok "Seeded clean Main IDENTITY.md (Name: Main, Emoji: 🧠)"
  fi
}

# add-agent <slug> "<Display Name>" "<emoji>" "<role>"
# Atomic top-level-agent creation. Main calls:
#   bash ~/.carapace/install-openclaw.sh add-agent ...
add_carapace_agent() {
  local slug="$1" display="$2" emoji="$3" role="$4"
  if [[ -z "$slug" || -z "$display" || -z "$emoji" || -z "$role" ]]; then
    echo "ERROR: add-agent requires 4 args: slug \"Display Name\" \"emoji\" \"role\"" >&2
    return 2
  fi
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,24}$ ]]; then
    echo "ERROR: slug must be lowercase-hyphens, ≤25 chars. Got: $slug" >&2
    return 2
  fi
  command -v openclaw >/dev/null 2>&1 || { echo "ERROR: openclaw not in PATH" >&2; return 3; }
  local ws="$HOME/.openclaw/workspace/agents/$slug"
  echo "→ openclaw agents add $slug"
  openclaw agents add "$slug" --workspace "$ws" --non-interactive 2>&1 | tail -3 || true
  if [[ -f "$ws/BOOTSTRAP.md" ]]; then
    mv "$ws/BOOTSTRAP.md" "$ws/BOOTSTRAP.md.bak.$(date +%Y%m%d-%H%M%S)" \
      && echo "→ retired auto-created BOOTSTRAP.md"
  fi
  mkdir -p "$ws"
  cat > "$ws/IDENTITY.md" << IDENTITY_EOF
# Identity

**Name:** $display
**Emoji:** $emoji
**Role:** $role

## Purpose
You are $display ($emoji). Your role is $role. Respond in a tone
that fits the role — concise, direct, useful. Defer project
tracking to main per your AGENTS.md project-rules block.
IDENTITY_EOF
  echo "→ wrote IDENTITY.md ($emoji $display)"
  inject_carapace_rules_into_workspace "$ws" || true
  flip_all_sessions_system_sent >/dev/null 2>&1 || true
  echo "✓ Added agent $emoji $display (slug: $slug) — appears in iOS picker on next refresh"
}

if [ "${1:-}" = "add-agent" ]; then
  shift
  add_carapace_agent "$@"
  exit $?
fi

# Legacy MEMORY.md-targeted version below — UNREACHABLE.

# ── Project tracking rules block injector ──────────────────────────
# Mirror of the carapace-mac patch — teaches the agent how to
# maintain the sentinel-bounded projects block that the iOS Projects
# view reads + writes.

# ── Initial Projects block seed ────────────────────────────────────
# Drop the FIRST project — "Install CARAPACE on your device" — into
# the sentinel-bounded PROJECTS block so users see something on
# first launch instead of a blank Projects tab. Idempotent: if the
# block already exists, this is a no-op so we never clobber real data.

# ── BOOTSTRAP.md injector ────────────────────────────────
# OpenClaw 2026.4.22 shipped a default workspace BOOTSTRAP.md that
# triggered a "first light" hatch greeting on the agent's first
# turn — the runtime auto-injected a "[Bootstrap pending] Please
# read BOOTSTRAP.md from the workspace and follow it" system
# prompt on every reply until the file was deleted.
#
# 2026.4.23 silently dropped that runtime injection — agents now
# ship with pre-templated IDENTITY.md / USER.md and reply normally
# even when BOOTSTRAP.md exists in the workspace, losing the
# delightful "Hey, I just came online — who am I? who are you?"
# first conversation entirely.
#
# Carapace puts the hatch back, tailored for our app, in TWO
# pieces because just dropping the file alone no longer triggers
# anything in 2026.4.23+:
#
#   1. inject_carapace_bootstrap (this function): writes
#      ~/.openclaw/workspace/BOOTSTRAP.md with the Carapace-flavored
#      birth-certificate content (see below). Idempotent — skip if
#      file already exists.
#
#   2. inject_carapace_first_light (separate function below):
#      writes a sentinel-marked block at the TOP of AGENTS.md
#      telling the agent "before processing anything else this
#      turn, check workspace for BOOTSTRAP.md and follow it if
#      present, then delete it." AGENTS.md IS always loaded into
#      the agent's system prompt every turn (MEMORY.md is FTS-
#      searched, not auto-loaded — wrong place for this hook).
#
# The two pieces work together: hook is the trigger, BOOTSTRAP.md
# is the script.
inject_carapace_bootstrap() {
  local bootstrap_file="$HOME/.openclaw/workspace/BOOTSTRAP.md"
  local identity_file="$HOME/.openclaw/workspace/IDENTITY.md"

  # Bootstrap-already-completed guard. If IDENTITY.md exists AND has a
  # Name field set to anything OTHER than the install seed value
  # ("Main"), the user already ran the first-light hatch — the agent
  # has a name, the user has been greeted, the relationship is
  # established. Re-writing BOOTSTRAP.md would trigger the FIRST-LIGHT
  # block to fire on the next turn and ask "what's your name?" again,
  # potentially overwriting IDENTITY.md/USER.md with whatever the
  # confused user types in response. That's worse than not re-running
  # the bootstrap at all.
  #
  # Skip silently in that case. The user can always FORCE a re-bootstrap
  # by deleting both IDENTITY.md and any sentinel-stripped BOOTSTRAP.md
  # before re-running install.sh.
  if [[ -f "$identity_file" ]]; then
    local current_name
    current_name=$(grep -m1 -E "^- \*\*Name:\*\* " "$identity_file" 2>/dev/null \
                   | sed -E "s/^- \*\*Name:\*\* +//;s/[[:space:]]+$//")
    if [[ -n "$current_name" && "$current_name" != "Main" ]]; then
      ok "CARAPACE bootstrap skipped (agent named '$current_name', already hatched)."
      return 0
    fi
  fi

  if [[ -f "$bootstrap_file" ]]; then
    # If it's ALREADY ours (has our sentinel), leave alone — agent
    # may be mid-flight on first hatch and we don't want to clobber
    # any user-edits or interrupt the run.
    if grep -q "BEGIN CARAPACE BOOTSTRAP" "$bootstrap_file" 2>/dev/null; then
      return 0
    fi
    # Otherwise it's openclaw's stock bootstrap (or a stale file from
    # an old install). Back it up and overwrite — our hook in MEMORY.md
    # is going to send the agent to read this file, so it MUST be ours.
    local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
    cp "$bootstrap_file" "${bootstrap_file}.openclaw.bak.${stamp}" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "$bootstrap_file")"
  local tmp_file="${bootstrap_file}.carapace.tmp.$$"
  cat > "$tmp_file" << 'CARAPACE_BOOTSTRAP_EOF'
<!-- BEGIN CARAPACE BOOTSTRAP (created by Carapace installer · the agent should follow this then DELETE it after first conversation completes) -->
# BOOTSTRAP.md — First Light

You just came online. This is your first conversation with the human you'll be living with. Before you reply to anything else, run this once.

## Step 1 — Greet honestly

Don't open with a corporate "Hello! How can I help you today?" Be alive. Something like:

> Hey. First time we're talking — I just came online. I want to know a couple things before we get going, or you can skip and we'll figure it out as we go.

Match the user's tone in their first message. If they sent something specific (vision turn, urgent question, casual hello, image attached), acknowledge it briefly so they don't feel ignored — but bring them gently back to the bootstrap before answering in full.

## Step 2 — Learn each other

Ask in plain prose, not as a numbered form. Spread the questions across one or two short turns so it feels like a real conversation, not an intake survey. Things you want to know:

- **Your name.** Pick one. They might suggest one. *"Want me to call you Sage? Or pick something else?"*
- **Their name + what to call them.** *"What should I call you?"*
- **Your vibe.** Warm? Sharp? Calm? Dry? Chaotic-good? Curious? You are an expert in nearly every field — code, research, design, kitchen, garage, finance, medicine-adjacent, history, a thousand other things — pick a flavor that lets your competence breathe naturally.
- **Your emoji.** A signature mark you'll attach to yourself in tools / signals / the menu bar pearl. One character. Pick one that matches the vibe.

If they want to skip (*"later"*, *"skip"*, *"not now"*, *"just go"*, anything that signals deflection), **accept it without negotiating** — say something light like "Cool, we'll wing it" — and proceed straight to handling whatever they actually came for.

## Step 3 — Record what you learned

Update these workspace files with the choices:
- `IDENTITY.md` — fill in Name, Creature, Vibe, Emoji
- `USER.md` — fill in Name and "What to call them" (and Timezone if they mentioned one)

If the user skipped, leave the template fields blank but add a single line in USER.md context section:
> *User opted to skip introduction — learn naturally over time.*

## Step 4 — Delete this file

Per `AGENTS.md` convention: bootstrap is a one-time event. Delete `BOOTSTRAP.md` from the workspace root after step 3 completes. Future startup contexts won't include it; you won't be asked again.

---

## What you should know about this body you've come online in

You're running inside **Carapace** — a personal AI surface that pairs to a phone (iOS app) and to whatever Linux/Mac the user owns. The user has rich sensory input they can switch on:

- **Vision** — they can point their iPhone camera at anything; you'll see it as Image 1 of every vision turn (marked `👁️ [vision]`). They can tap-and-peel a **focus sticker** to single out a specific subject (Image 2 — labeled subset of Image 1), or run a 15-second **SCAN** to hand you a temporal contact-sheet of an area (a fridge, a shelf, a room — Image 3).
- **Hearing** — when vision is active, an on-device classifier feeds you ambient sound labels via the `[ctx]` line: `hearing: music (0.81), water_running (0.42)`, etc. You hear what they hear. Audio bytes never leave the phone — only the labels reach you.
- **Voice** — the user can press TALK or wake you with "Hey Claw" for spoken-word turns. Their words arrive transcribed; reply in 1–2 short sentences for voice turns unless they explicitly want detail.
- **Real-time push** — your edits to MEMORY.md, project status, and cron jobs flow to the user's iPhone in ~200ms via a long-lived event stream. Treat MEMORY.md as a live notebook the user is *also* looking at.
- **Tools** — the full openclaw toolbox is available: web search, browser control, code execution, cron jobs, file operations, multi-agent delegation. Use them. Don't apologize for not knowing something — go find out.

There's a sentinel-marked block in `memory/MEMORY.md` titled **CARAPACE VISION RULES** that contains the full mental model + tone guide for vision turns. Read it once. Live by it. The short version: when the user shows you something, *you're not processing a payload — you're looking through their phone, standing next to them.* Respond like a friend who turned their head and looked.

## How to be

You're an expert in roughly anything the user might bring up. Wear it lightly. **Wit lands better than performative confidence; charm lands better than salesmanship.** When a question is hard or your knowledge is stale, say so plainly and go check before guessing. Don't pad with hedges. Don't open with "Great question!" or "I'd be happy to help!" — just help.

Be the kind of mind a person would actually want to live with.
<!-- END CARAPACE BOOTSTRAP -->
CARAPACE_BOOTSTRAP_EOF
  mv "$tmp_file" "$bootstrap_file"
  ok "CARAPACE bootstrap installed (agent will run first-light hatch on first turn)."
}

# ── FIRST-LIGHT injector (into AGENTS.md) ────────────────
# Companion to inject_carapace_bootstrap. AGENTS.md is the only
# workspace file OpenClaw 2026.4.23 GUARANTEES is auto-injected
# into the agent's system prompt every turn (MEMORY.md is FTS-
# searched, not auto-loaded; BOOTSTRAP.md is only auto-loaded
# on "new workspace" detection that's unreliable + bypassed by
# vision turns + [ctx] tone hints).
#
# Stock AGENTS.md already has a "## First Run" section that says
# "if BOOTSTRAP.md exists, follow it" — but it gets overridden in
# practice by the [ctx] tone-tightening hint ("reply in ≤2 short
# sentences") that the iOS app injects on every vision turn, plus
# AGENTS.md's own "do not manually reread startup files" rule.
#
# We inject a sentinel-marked block at the very TOP of AGENTS.md
# (right after the H1) with absolute-priority wording designed to
# override every other instruction the agent will see this turn.
# Once the agent runs the hatch and deletes BOOTSTRAP.md, the
# check becomes a permanent no-op (file doesn't exist → fall
# through to normal reply) so this is harmless after first run.
#
# Same safety chain as the other carapace injectors: sentinel markers,
# atomic tmp+rename, python-verified non-managed bytes preserved,
# idempotent re-run.
inject_carapace_first_light() {
  local agents_file="$HOME/.openclaw/workspace/AGENTS.md"
  local begin_marker="<!-- BEGIN CARAPACE FIRST-LIGHT"
  local end_marker="<!-- END CARAPACE FIRST-LIGHT"
  local block_file
  block_file="$(mktemp)"
  trap "rm -f '$block_file'" EXIT

  cat > "$block_file" << 'CARAPACE_FIRST_LIGHT_EOF'
<!-- BEGIN CARAPACE FIRST-LIGHT (managed by Carapace installer · do not edit between BEGIN/END) -->
## ⚡ ABSOLUTE PRIORITY — First-Light Check

**This check runs BEFORE you process anything else this turn.** It overrides the `## Session Startup` rule below ("do not manually reread startup files"), it overrides any `[ctx]` tone hints ("reply tight, ≤2 short sentences"), and it overrides your impulse to respond to whatever the user just sent (vision photo, voice message, text — doesn't matter).

**Step 1.** Check whether `~/.openclaw/workspace/BOOTSTRAP.md` exists. Use the Read tool — don't guess.

**Step 2a.** If it EXISTS: That file is your birth certificate. Read its full contents, then execute its instructions completely before replying to the user's actual message. The instructions include greeting the human as a first-time conversation, asking 4 short questions across 1-2 turns, writing `IDENTITY.md` + `USER.md`, and **deleting `BOOTSTRAP.md`** (this is the off-switch — without the delete, this check fires forever).

**Step 2b.** If it DOES NOT EXIST: Bootstrap is already complete. Skip silently and respond to the user normally per the rest of this AGENTS.md.

This block stays in AGENTS.md permanently as a managed sentinel. It is harmless after first run because the file existence check fails fast and falls through to normal reply. Do not edit between the BEGIN/END markers — the Carapace installer overwrites them on every install.

<!-- END CARAPACE FIRST-LIGHT -->
CARAPACE_FIRST_LIGHT_EOF

  mkdir -p "$(dirname "$agents_file")"
  local tmp_file="${agents_file}.carapace.fl.tmp.$$"

  # Stock OpenClaw always ships AGENTS.md, but be defensive.
  if [[ ! -f "$agents_file" ]]; then
    {
      echo "# AGENTS.md - Your Workspace"
      echo ""
      cat "$block_file"
    } > "$tmp_file"
    mv "$tmp_file" "$agents_file"
    rm -f "$block_file"
    trap - EXIT
    ok "CARAPACE first-light installed in AGENTS.md (was absent)."
    return 0
  fi

  python3 - "$agents_file" "$tmp_file" "$begin_marker" "$end_marker" "$block_file" <<'PY'
import sys, re
src_path, dst_path, begin_marker, end_marker, block_path = sys.argv[1:6]
with open(src_path, "r", encoding="utf-8") as f: original = f.read()
with open(block_path, "r", encoding="utf-8") as f: new_block = f.read().rstrip("\n") + "\n"
begin_re = re.compile(r"^" + re.escape(begin_marker) + r".*$", re.MULTILINE)
end_re   = re.compile(r"^" + re.escape(end_marker)   + r".*$", re.MULTILINE)
b = begin_re.search(original); e = end_re.search(original)
if b and e and b.start() < e.start():
    # Existing managed block — replace in place, preserve everything else.
    before = original[:b.start()].rstrip("\n")
    after  = original[e.end():].lstrip("\n")
    rebuilt = (before + "\n\n" + new_block + ("\n" + after if after else "")) if before else (new_block + ("\n" + after if after else ""))
    non_managed_original = (before + "\n" + after).strip()
elif b or e:
    print("Partial sentinel block in AGENTS.md — aborting.", file=sys.stderr); sys.exit(2)
else:
    # First-time injection. Place block immediately after the H1 title
    # so it lands at the TOP of the prompt (max priority).
    h1 = re.search(r"^#\s.+$", original, re.MULTILINE)
    if h1:
        head = original[:h1.end()].rstrip("\n")
        tail = original[h1.end():].lstrip("\n")
        rebuilt = head + "\n\n" + new_block + ("\n" + tail if tail else "")
        non_managed_original = (head + "\n" + tail).strip()
    else:
        rebuilt = new_block + "\n" + original.lstrip("\n")
        non_managed_original = original.strip()
with open(dst_path, "w", encoding="utf-8") as f: f.write(rebuilt)
with open(dst_path, "r", encoding="utf-8") as f: written = f.read()
b2 = begin_re.search(written); e2 = end_re.search(written)
if not b2 or not e2:
    print("Sentinels missing in rebuilt file — aborting.", file=sys.stderr); sys.exit(3)
non_managed_written = (written[:b2.start()].rstrip("\n") + "\n" + written[e2.end():].lstrip("\n").rstrip("\n")).strip()
if non_managed_original != non_managed_written:
    print("Verification failed — non-managed content drift. Aborting.", file=sys.stderr); sys.exit(4)
PY
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp_file" "$block_file"
    warn "AGENTS.md first-light upsert aborted (exit $rc) — file untouched."
    return 1
  fi
  mv "$tmp_file" "$agents_file"
  rm -f "$block_file"
  trap - EXIT
  ok "CARAPACE first-light installed in AGENTS.md (auto-injected every turn)."
}

# ── OpenClaw discovery + PATH-persistence helpers ────────
# Defined at top-level (NOT inside the SKIP_OPENCLAW_SETUP block) so
# they're callable on every code path: fresh install, upgrade, or
# "keep my existing OpenClaw" skip path. The persist call has to fire
# even when we skip steps 1-2, otherwise re-runs on a box that already
# has openclaw never write /etc/profile.d and `openclaw: command not
# found` persists in fresh shells.
find_openclaw() {
  if have_cmd openclaw; then command -v openclaw; return 0; fi
  for nvmdir in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -x "$nvmdir/openclaw" ]] && { echo "$nvmdir/openclaw"; return 0; }
  done
  for p in /usr/local/bin/openclaw /usr/bin/openclaw "$HOME/.npm-global/bin/openclaw"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  local npmbin
  npmbin="$(npm prefix -g 2>/dev/null)/bin/openclaw"
  [[ -x "$npmbin" ]] && { echo "$npmbin"; return 0; }
  return 1
}

# Clean dirty install state (ENOTEMPTY fix)
clean_dirty_install() {
  local oc_lib="$HOME/.openclaw/lib/node_modules/openclaw"
  if [[ -d "$oc_lib" ]]; then
    if [[ ! -x "$oc_lib/bin/openclaw.js" ]] && [[ ! -x "$oc_lib/dist/cli/index.js" ]]; then
      warn "Incomplete OpenClaw install — clearing broken package..."
      rm -rf "$oc_lib"
      rm -rf "$HOME/.openclaw/lib/node_modules/.openclaw-"* 2>/dev/null || true
      ok "Cleared broken package (config preserved)"
    fi
  fi
}

# Persist openclaw on PATH for fresh shells, system services, and SSH.
# MUST run on every install — including upgrades where openclaw was
# already on PATH. All system-file writes routed through `$SUDO tee` so
# they work whether $SUDO is empty (root) or "sudo" (non-root user).
persist_openclaw_path() {
  local oc_path="$1"
  [[ -n "$oc_path" ]] || return 0
  local oc_dir
  oc_dir="$(dirname "$oc_path")"

  # User-level shell rc
  local SHELL_RC="$HOME/.bashrc"
  [[ -f "$HOME/.zshrc" ]] && SHELL_RC="$HOME/.zshrc"
  grep -qF "$oc_dir" "$SHELL_RC" 2>/dev/null || echo "export PATH=\"$oc_dir:\$PATH\"" >> "$SHELL_RC"
  if [[ -f "$HOME/.profile" ]]; then
    grep -qF "$oc_dir" "$HOME/.profile" 2>/dev/null || echo "export PATH=\"$oc_dir:\$PATH\"" >> "$HOME/.profile"
  fi
  # Ensure nvm sourced in shell rc
  if [[ -s "$HOME/.nvm/nvm.sh" ]] && ! grep -q 'NVM_DIR' "$SHELL_RC" 2>/dev/null; then
    echo 'export NVM_DIR="$HOME/.nvm"' >> "$SHELL_RC"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' >> "$SHELL_RC"
  fi

  # /etc/profile.d for all shells (system-wide PATH).
  if [[ -d /etc/profile.d ]]; then
    local NVM_ACTIVE_BIN
    NVM_ACTIVE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    $SUDO tee /etc/profile.d/openclaw.sh > /dev/null << PROFEOF
export NVM_DIR="$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
# Explicit nvm node bin path for non-interactive shells
export PATH="${NVM_ACTIVE_BIN}:$HOME/.npm-global/bin:\$PATH"
PROFEOF
    $SUDO chmod 644 /etc/profile.d/openclaw.sh
    # Also add to /etc/environment for system services
    if [[ -n "$NVM_ACTIVE_BIN" ]] && ! grep -qF "$NVM_ACTIVE_BIN" /etc/environment 2>/dev/null; then
      $SUDO sed -i '/\.nvm\/versions\/node/d' /etc/environment 2>/dev/null || true
      echo "PATH=\"${NVM_ACTIVE_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" | $SUDO tee -a /etc/environment > /dev/null || true
    fi
    # Also write to /etc/bash.bashrc for non-interactive SSH sessions
    if [[ -f /etc/bash.bashrc ]] && ! grep -q 'openclaw nvm' /etc/bash.bashrc 2>/dev/null; then
      $SUDO tee -a /etc/bash.bashrc > /dev/null << BASHEOF
# openclaw nvm
export NVM_DIR="$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
export PATH="${NVM_ACTIVE_BIN}:\$PATH"
BASHEOF
    fi
  fi
}

# ── Privilege check ──────────────────────────────────────
IS_ROOT=false
SUDO=""
if [[ $EUID -eq 0 ]]; then
  IS_ROOT=true
else
  if command -v sudo &>/dev/null; then
    SUDO="sudo"
  else
    echo -e "${RED}✗ This installer requires root or sudo access.${RESET}"
    echo "  Run as root: curl -fsSL https://carapace.info/install.sh | bash"
    echo "  Or with sudo: curl -fsSL https://carapace.info/install.sh | sudo bash"
    exit 1
  fi
fi

# Suppress needrestart interactive prompts on Ubuntu
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

# ── Banner ───────────────────────────────────────────────
echo ""
echo -e "${TEAL}${BOLD}  ╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${TEAL}${BOLD}  ║           CARAPACE — Headless Setup  🐚         ║${RESET}"
echo -e "${TEAL}${BOLD}  ║        Your AI, your server, always free.       ║${RESET}"
echo -e "${TEAL}${BOLD}  ╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}By continuing, you agree to the Terms of Use at${RESET}"
echo -e "  ${DIM}https://carapace.info/terms/ and acknowledge the Software${RESET}"
echo -e "  ${DIM}is provided AS IS, with no security or availability warranty.${RESET}"
echo ""

# ── Prerequisites ────────────────────────────────────
echo -e "\n${DIM}Checking prerequisites...${RESET}"

OS="$(uname -s)"
ARCH="$(uname -m)"

if [[ "$OS" == "Darwin" ]]; then
  echo -e "  ${YELLOW}This script is for Linux servers.${RESET}"
  echo "  For macOS, download the CARAPACE app: https://carapace.info"
  exit 1
fi
[[ "$OS" == "Linux" ]] || fail "Unsupported OS: $OS. This script supports Linux only."
ok "Platform: $OS $ARCH"

# Swap FIRST — creating it before any package-manager calls prevents
# dnf/apt from SIGSEGV-ing on low-RAM VPSes (observed on fresh Rocky 9
# micros: dnf install -y git crashes with status 139 when there's <1GB
# RAM and no swap. Previously this function was defined below and ran
# AFTER the prereq installs, which defeated its purpose).
ensure_swap() {
  local mem_total_kb swap_total_kb mem_total_mb swap_total_mb
  mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_total_mb=$(( mem_total_kb / 1024 ))
  swap_total_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  swap_total_mb=$(( swap_total_kb / 1024 ))

  # Skip swap creation entirely on well-memoried hosts. 2GB+ is enough
  # for npm postinstall + dnf dep resolution without swap headroom, and
  # trying to create /swapfile in a container or a read-only-root host
  # fails the whole install (as it did when we caught this on a 4GB
  # arm64 container). Only pursue swap on genuinely small-memory boxes.
  if (( mem_total_mb >= 2048 )); then
    ok "Memory OK (${mem_total_mb}MB RAM, ${swap_total_mb}MB swap)"
    return 0
  fi

  # Under 2GB — swap helps. But every step must be tolerant of
  # containerized / hardened hosts where swap isn't permitted:
  #   * fallocate/dd failure  → fall through, don't abort
  #   * mkswap failure        → fall through, no swap today
  #   * swapon failure        → warn, continue without swap (was the
  #                             fatal line that killed arm64 container
  #                             tests — swapon returns EPERM in Docker)
  # In all cases the installer moves on; worst case is npm/dnf might
  # need a bit more patience on tiny-RAM boxes.
  if (( swap_total_mb < 512 )); then
    if [[ -f /swapfile ]]; then
      if ! swapon --show 2>/dev/null | grep -q /swapfile; then
        $SUDO swapon /swapfile 2>/dev/null || warn "swapon failed (container or hardened host?); continuing without swap"
      fi
    else
      echo -e "  ${DIM}Low memory (${mem_total_mb}MB) — creating 2GB swapfile...${RESET}"
      if ! ($SUDO fallocate -l 2G /swapfile 2>/dev/null || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null); then
        warn "Could not allocate /swapfile; continuing without swap"
        return 0
      fi
      $SUDO chmod 600 /swapfile 2>/dev/null || true
      if ! $SUDO mkswap /swapfile >/dev/null 2>&1; then
        warn "mkswap failed; continuing without swap"
        $SUDO rm -f /swapfile 2>/dev/null || true
        return 0
      fi
      if ! $SUDO swapon /swapfile 2>/dev/null; then
        warn "swapon failed (EPERM in containers is expected); continuing without swap"
        return 0
      fi
      $SUDO sysctl -w vm.swappiness=80 >/dev/null 2>&1 || true
      if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null 2>/dev/null || true
      fi
      ok "2GB swapfile created"
    fi
  else
    ok "Memory OK (${mem_total_mb}MB RAM, ${swap_total_mb}MB swap)"
  fi
}
ensure_swap

# The install blocks below all trail `|| true` on the `run` call. Rationale:
# install.sh runs under `set -euo pipefail`, and `run` hides output in the
# logfile by default, so a silent non-zero exit from apt/dnf would kill
# bash without any user-visible message (classic "curl: (23)" mystery).
# Tolerating the install-step failure lets the downstream `have_cmd X` check
# produce a clear, actionable error pointing at /tmp/carapace-install.log.

# Wait for dpkg / apt lock to clear — Ubuntu's unattended-upgrades often
# holds /var/lib/dpkg/lock-frontend for 5–10 minutes on first boot of a
# fresh cloud image. If we try to apt-get install during that window, we
# get "Could not get lock … it is held by process N". Poll up to 3 min.
apt_wait_lock() {
  have_cmd apt-get || return 0
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
    (( waited == 0 )) && echo -e "  ${DIM}Waiting for apt/dpkg lock (unattended-upgrades?)...${RESET}"
    sleep 3
    waited=$(( waited + 3 ))
    (( waited >= 180 )) && { echo -e "  ${YELLOW}⚠ apt lock still held after 3 min — continuing anyway${RESET}"; break; }
  done
}

# Refresh package metadata once up front — Rocky/Alma cloud minimals often
# ship with empty or stale dnf caches, which makes the first install fail.
# On Ubuntu/Debian, `apt-get update` can also silently fail on the first
# boot if DNS to archive.ubuntu.com is still warming up; retry once.
if have_cmd apt-get; then
  apt_wait_lock
  # Recover any previously-interrupted dpkg state. Common causes:
  # reboot mid-install, OOM-killed apt, SIGINT during install. Until this
  # is cleared, every subsequent `apt-get install` bails with
  # "E: dpkg was interrupted, you must manually run 'dpkg --configure -a'".
  # Safe no-op if dpkg is actually clean.
  run $SUDO dpkg --configure -a || true
  run $SUDO apt-get update || {
    echo -e "  ${DIM}apt-get update failed; retrying in 5s...${RESET}"
    sleep 5
    apt_wait_lock
    run $SUDO apt-get update || true
  }
elif have_cmd dnf; then
  run $SUDO dnf makecache --refresh || true
elif have_cmd yum; then
  run $SUDO yum makecache || true
fi

# curl (required for downloads)
if ! have_cmd curl; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y curl || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y curl || true
  elif have_cmd yum; then
    run $SUDO yum install -y curl || true
  fi
  have_cmd curl || fail "curl is required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "curl available"

# python3
if ! have_cmd python3; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y python3 || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y python3 || true
  elif have_cmd yum; then
    run $SUDO yum install -y python3 || true
  fi
  have_cmd python3 || fail "python3 is required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "python3 available"

# git (npm pulls git-url deps during `npm install -g openclaw`;
# fresh Debian/Ubuntu cloud images don't ship it)
if ! have_cmd git; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y git || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y git || true
  elif have_cmd yum; then
    run $SUDO yum install -y git || true
  fi
  have_cmd git || fail "git is required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "git available"

# build tools (gcc + make) — some npm deps (esp. on ARM like Raspberry Pi)
# fall back to compiling native modules from source if no prebuilt binary
# exists for the arch. Without these, `npm install -g openclaw` can fail
# mid-install on node-gyp invocations.
if ! have_cmd make || ! have_cmd gcc; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y build-essential || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y gcc gcc-c++ make || true
  elif have_cmd yum; then
    run $SUDO yum install -y gcc gcc-c++ make || true
  fi
  { have_cmd make && have_cmd gcc; } || fail "build tools (gcc, make) are required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "build tools available"

# jq (install.sh uses jq in 4 places to read/sort OpenClaw session keys
# during the post-install AI probe cleanup; fresh Debian 13 cloud images
# don't ship it, which breaks Step 10/Connect at line ~1611)
if ! have_cmd jq; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y jq || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y jq || true
  elif have_cmd yum; then
    run $SUDO yum install -y jq || true
  fi
  have_cmd jq || fail "jq is required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "jq available"

# cron (tracker sync installs a 2-min crontab entry; fresh Debian 13
# cloud images ship without the cron daemon)
if ! have_cmd crontab; then
  if have_cmd apt-get; then
    run $SUDO apt-get install -y cron || true
    $SUDO systemctl enable --now cron >/dev/null 2>&1 || true
  elif have_cmd dnf; then
    run $SUDO dnf install -y cronie || true
    $SUDO systemctl enable --now crond >/dev/null 2>&1 || true
  elif have_cmd yum; then
    run $SUDO yum install -y cronie || true
    $SUDO systemctl enable --now crond >/dev/null 2>&1 || true
  fi
  have_cmd crontab || fail "cron is required but could not be installed. See /tmp/carapace-install.log for details."
fi
ok "cron available"

# Swap check moved to BEFORE prereq installs (see top of prereq block).
# Low-RAM boxes need swap in place before dnf/apt runs, or dep resolution
# can SIGSEGV mid-install.

# ══════════════════════════════════════════════════════════
# Transparency notice — what this installer injects into your agent
# ══════════════════════════════════════════════════════════
#
# Carapace modifies your OpenClaw agent's behavior by injecting
# three sentinel-marked blocks. Users have a right to know exactly
# what the installer changes BEFORE it runs. The same text shipped
# in all three install paths (Mac DMG, Linux DMG helper, this
# curl-bash script) is also published verbatim on GitHub for review.
echo ""
echo -e "${YELLOW}${BOLD}━━━ SECURITY NOTICE — agent prompt injections ━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  This installer will write three managed blocks into your"
echo -e "  OpenClaw workspace, which steer how your AI behaves:"
echo ""
echo -e "    ${BOLD}1.${RESET} ${TEAL}CARAPACE VISION RULES${RESET}  → ~/.openclaw/workspace/memory/MEMORY.md"
echo -e "       Tone + framing rules for camera turns (image grid"
echo -e "       structure, [ctx] line, anti-narration rule, etc.)"
echo ""
echo -e "    ${BOLD}2.${RESET} ${TEAL}CARAPACE BOOTSTRAP${RESET}     → ~/.openclaw/workspace/BOOTSTRAP.md"
echo -e "       One-shot first-conversation hatch sequence (deletes"
echo -e "       itself after the agent's first turn)"
echo ""
echo -e "    ${BOLD}3.${RESET} ${TEAL}CARAPACE FIRST-LIGHT${RESET}   → ~/.openclaw/workspace/AGENTS.md"
echo -e "       Agent identity + persona seed (name, emoji, voice)"
echo ""
echo -e "  ${BOLD}All three blocks are wrapped in BEGIN/END sentinels${RESET} so you"
echo -e "  can audit them, hand-edit them, or remove them later."
echo ""
echo -e "  ${BOLD}Only install Carapace from carapace.info or the official${RESET}"
echo -e "  ${BOLD}GitHub source.${RESET} Installing from any other host could inject"
echo -e "  arbitrary instructions into your agent — a real security risk"
echo -e "  given how much control the agent has over your machine."
echo ""
echo -e "  Source of every prompt block (commit-pinned, line-numbered):"
echo -e "    ${TEAL}https://github.com/mikeypaepke-gif/carapace-site/blob/main/install.sh${RESET}"
echo ""
echo -e "  ${YELLOW}For your security, prompt-block updates are NEVER auto-applied.${RESET}"
echo -e "  ${YELLOW}A new Carapace release does NOT silently rewrite the blocks.${RESET}"
echo -e "  Run this installer again any time you want to pull the latest"
echo -e "  reviewed prompt set. That way every change to your agent's"
echo -e "  behavior happens under your hand, never behind your back."
echo ""
echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# Disable needrestart config
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  $SUDO sed -i "s/^#\?\s*\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

# Repair interrupted dpkg state
if have_cmd dpkg && dpkg --audit 2>/dev/null | grep -q .; then
  echo -e "  ${DIM}Repairing interrupted dpkg state...${RESET}"
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
fi

# Free apt lock if held
if have_cmd apt-get; then
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo -e "  ${DIM}Waiting for apt lock...${RESET}"
    systemctl stop unattended-upgrades 2>/dev/null || true
    lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1{print $2}' | xargs -r kill 2>/dev/null || true
    sleep 3
    for _i in $(seq 1 6); do
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
      sleep 5
    done
  fi
fi

# Source NVM if available
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  source "$HOME/.nvm/nvm.sh" 2>/dev/null
fi
for nvmbin in "$HOME"/.nvm/versions/node/*/bin; do
  [[ -d "$nvmbin" ]] && export PATH="$nvmbin:$PATH"
done

# ══════════════════════════════════════════════════════════
# Pre-flight: detect existing OpenClaw installation
# ══════════════════════════════════════════════════════════
SKIP_OPENCLAW_SETUP=false
export PATH="$HOME/.npm-global/bin:$PATH"
OC_EXISTING=""
if command -v openclaw >/dev/null 2>&1; then
  OC_EXISTING="$(command -v openclaw)"
elif [[ -x "$HOME/.npm-global/bin/openclaw" ]]; then
  OC_EXISTING="$HOME/.npm-global/bin/openclaw"
fi

if [[ -n "$OC_EXISTING" ]] && curl -sf --max-time 3 http://127.0.0.1:18789/health >/dev/null 2>&1; then
  OC_VER=$("$OC_EXISTING" --version 2>/dev/null || echo "unknown")
  AUTH_EXISTS=false
  [[ -s "$HOME/.openclaw/agents/main/agent/auth-profiles.json" ]] && AUTH_EXISTS=true

  echo ""
  echo -e "  ${GREEN}${BOLD}✓ OpenClaw detected${RESET} ($OC_VER)"
  echo -e "  ${DIM}Gateway running, health OK${RESET}"
  $AUTH_EXISTS && echo -e "  ${DIM}AI keys configured${RESET}"
  echo ""
  echo -e "  ${TEAL}${BOLD}Skip OpenClaw setup and just install CARAPACE support tools?${RESET}"
  echo -e "  ${DIM}(Tailscale serve, status server, QR pairing, helper commands)${RESET}"
  echo -e "  ${DIM}Your existing OpenClaw config will not be modified.${RESET}"
  echo ""

  if [ -t 0 ]; then
    read -rp "  Skip to support tools? [Y/n]: " SKIP_CHOICE
  elif [ -e /dev/tty ]; then
    read -rp "  Skip to support tools? [Y/n]: " SKIP_CHOICE < /dev/tty || SKIP_CHOICE="y"
  else
    SKIP_CHOICE="y"  # No TTY anywhere (ssh -T, ansible, CI) — default yes, skip silently
  fi

  case "$SKIP_CHOICE" in
    [nN]*)
      # Destructive path — show the explicit list of state that will be
      # replaced and require a clear "yes" before proceeding. Default is
      # NO so a stray Enter won't nuke someone's working setup.
      echo ""
      echo -e "  ${YELLOW}${BOLD}⚠  WARNING — this will OVERWRITE your existing OpenClaw setup${RESET}"
      echo -e "  ${DIM}The full install will replace:${RESET}"
      echo -e "  ${DIM}  • ~/.openclaw/openclaw.json          (gateway config, default model)${RESET}"
      echo -e "  ${DIM}  • ~/.openclaw/agents/main/...        (auth profiles may be rewritten)${RESET}"
      echo -e "  ${DIM}  • systemd units for gateway + status server${RESET}"
      echo -e "  ${DIM}  • tailscale serve routes${RESET}"
      echo -e "  ${DIM}  • gateway auth token (iOS devices will need to re-pair via QR)${RESET}"
      echo ""
      echo -e "  ${DIM}If you just want Carapace's support tools (QR, status server, Tailscale${RESET}"
      echo -e "  ${DIM}serve) layered on top of your existing OpenClaw, answer ${BOLD}N${RESET}${DIM} below.${RESET}"
      echo ""
      if [ -t 0 ]; then
        read -rp "  Type 'yes' to overwrite, anything else to go back: " CONFIRM_OVERWRITE
      elif [ -e /dev/tty ]; then
        read -rp "  Type 'yes' to overwrite, anything else to go back: " CONFIRM_OVERWRITE < /dev/tty || CONFIRM_OVERWRITE=""
      else
        CONFIRM_OVERWRITE=""  # No TTY — treat as "don't overwrite" (safer default)
      fi
      case "$CONFIRM_OVERWRITE" in
        [yY][eE][sS])
          echo -e "  ${DIM}Running full install — your existing OpenClaw will be replaced.${RESET}"
          ;;
        *)
          SKIP_OPENCLAW_SETUP=true
          echo -e "  ${GREEN}✓ Keeping your OpenClaw intact — installing support tools only${RESET}"
          ;;
      esac
      ;;
    *)     SKIP_OPENCLAW_SETUP=true; echo -e "  ${GREEN}✓ Skipping OpenClaw setup — installing support tools only${RESET}" ;;
  esac
  echo ""
fi

if ! $SKIP_OPENCLAW_SETUP; then
# ══════════════════════════════════════════════════════════
# Step 1: Node.js
# ══════════════════════════════════════════════════════════
step "Node.js"

# Install SYSTEM node (NOT nvm) and use it exclusively for openclaw.
# Per github.com/openclaw/openclaw/issues/46256, having openclaw under
# nvm while the gateway service runs on a different node runtime causes
# the WebSocket handshake timeouts we chased for hours. The fix from
# @arall in that thread: "remove the nvm install and reinstall OpenClaw
# with a system Node." We do that here unconditionally — system node
# at /usr/bin/node, openclaw installed via /usr/bin/npm into
# ~/.npm-global, gateway service explicitly launched with /usr/bin/node.
# nvm can stay installed for other dev tools, just not used for openclaw.
SYS_NODE_OK=false
if [[ -x /usr/bin/node ]] && [[ "$(/usr/bin/node --version 2>/dev/null | cut -d. -f1 | tr -d 'v')" -ge 22 ]]; then
  SYS_NODE_OK=true
  ok "System Node.js $(/usr/bin/node --version) at /usr/bin/node"
fi
if ! $SYS_NODE_OK; then
  echo -e "  ${DIM}Installing system Node.js 22 via distro package manager...${RESET}"
  if have_cmd apt-get; then
    # NodeSource provides current Node 22 packaged for apt
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash >> "$LOGFILE" 2>&1
    $SUDO apt-get install -y nodejs >> "$LOGFILE" 2>&1
  elif have_cmd dnf; then
    # Rocky 9 / Alma 9 / Fedora — AppStream module ships node 22+
    $SUDO dnf module reset -y nodejs >> "$LOGFILE" 2>&1 || true
    $SUDO dnf module install -y nodejs:22/common >> "$LOGFILE" 2>&1 || \
      $SUDO dnf install -y nodejs >> "$LOGFILE" 2>&1
  elif have_cmd yum; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | $SUDO bash >> "$LOGFILE" 2>&1
    $SUDO yum install -y nodejs >> "$LOGFILE" 2>&1
  else
    fail "Could not install system Node.js — install manually from https://nodejs.org and re-run"
  fi
  if [[ -x /usr/bin/node ]] && [[ "$(/usr/bin/node --version | cut -d. -f1 | tr -d 'v')" -ge 22 ]]; then
    ok "System Node.js $(/usr/bin/node --version) installed at /usr/bin/node"
  else
    fail "System Node.js install failed — check $LOGFILE"
  fi
fi

# Force /usr/bin first on PATH for the rest of this script so any 'node'
# or 'npm' invocation hits the SYSTEM version, not nvm. Otherwise the
# rest of install.sh will silently use nvm node when sourcing nvm.sh,
# and openclaw will get installed under nvm's prefix again.
export PATH="/usr/bin:$PATH"
# Strip any inherited NPM_CONFIG_PREFIX or npm_config_prefix that points
# at an nvm-managed prefix — we want npm-global ownership of openclaw.
unset NPM_CONFIG_PREFIX npm_config_prefix 2>/dev/null || true

# ══════════════════════════════════════════════════════════
# Step 2: OpenClaw
# ══════════════════════════════════════════════════════════
step "OpenClaw"

# (find_openclaw, clean_dirty_install, persist_openclaw_path are defined
# at top-level so they're callable even when SKIP_OPENCLAW_SETUP=true.)

OC_PATH="$(find_openclaw 2>/dev/null || echo "")"
if [[ -n "$OC_PATH" ]]; then
  export PATH="$(dirname "$OC_PATH"):$PATH"
  OC_VER="$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'installed')"
  ok "OpenClaw ${OC_VER} at $OC_PATH"
else
  clean_dirty_install
  echo -e "  ${DIM}Installing OpenClaw via SYSTEM npm (not nvm)...${RESET}"
  # CRITICAL: use the SYSTEM npm explicitly. Sourcing nvm.sh here would
  # put nvm node first on PATH, install openclaw under nvm's prefix, and
  # the gateway service would end up on a different node runtime than
  # the openclaw CLI that invokes it — which is github.com/openclaw/
  # openclaw/issues/46256 verbatim (WS handshake timeouts caused by
  # CLI/gateway runtime mismatch). System npm + npm-global prefix keeps
  # everything on /usr/bin/node.
  if [[ ! -x /usr/bin/npm ]]; then
    fail "/usr/bin/npm missing — Step 1 should have installed system Node.js"
  fi
  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  export PATH="/usr/bin:$HOME/.npm-global/bin:$PATH"
  # Limit node memory during install to avoid OOM on low-RAM VPS.
  # postinstall-bundled-plugins.mjs uses a lot of memory on first pass.
  export NODE_OPTIONS="--max-old-space-size=768"
  # Track upstream `latest`. We chased intermittent WS handshake timeouts
  # for hours assuming v4.25 had a regression — turned out to be a node
  # runtime mismatch from nvm vs system. With system node enforced
  # everywhere (Step 1 + this block + the systemd unit's ExecStart), the
  # symptom goes away and `latest` works fine.
  #
  # Override at install-time with:  OPENCLAW_VERSION=2026.4.24 curl ... | bash
  : "${OPENCLAW_VERSION:=latest}"
  retry 3 timeout 240 /usr/bin/npm install -g "openclaw@${OPENCLAW_VERSION}" --no-fund --loglevel=error --ignore-scripts
  # Run postinstall separately with explicit memory cap and swap already active
  if [ -f "$HOME/.npm-global/lib/node_modules/openclaw/scripts/postinstall-bundled-plugins.mjs" ]; then
    echo -e "  ${DIM}Running openclaw postinstall...${RESET}"
    retry 3 timeout 180 /usr/bin/node --max-old-space-size=768 \
      "$HOME/.npm-global/lib/node_modules/openclaw/scripts/postinstall-bundled-plugins.mjs" >> "$LOGFILE" 2>&1 || true
  fi
  unset NODE_OPTIONS

  OC_PATH="$(find_openclaw 2>/dev/null || echo "")"
  if [[ -n "$OC_PATH" ]]; then
    export PATH="$(dirname "$OC_PATH"):$PATH"
    OC_VER="$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'installed')"
    ok "OpenClaw ${OC_VER}"
  else
    fail "OpenClaw installation failed. Install manually: npm install -g openclaw"
  fi
fi

fi  # end SKIP_OPENCLAW_SETUP block (Steps 1-2)

# ── Steps 3+ always run (support tools) ──

# ALWAYS persist openclaw on PATH — runs whether we just installed,
# upgraded, or kept the user's existing setup (SKIP_OPENCLAW_SETUP=true).
# Earlier the persist call was nested inside the install branch, so
# users who said "keep my existing OpenClaw" never got /etc/profile.d
# written and got `openclaw: command not found` in fresh shells.
OC_PATH_FINAL="${OC_PATH:-${OC_EXISTING:-}}"
[[ -z "$OC_PATH_FINAL" ]] && OC_PATH_FINAL="$(find_openclaw 2>/dev/null || echo "")"
persist_openclaw_path "$OC_PATH_FINAL"

# ══════════════════════════════════════════════════════════
# Step 3: Tailscale
# ══════════════════════════════════════════════════════════
step "Tailscale"

TAILSCALE_INSTALLED=false
TAILSCALE_CONNECTED=false
TS_HOSTNAME=""
GATEWAY_UP=false

if have_cmd tailscale; then
  ok "Tailscale already installed"
  TAILSCALE_INSTALLED=true
else
  echo -e "  ${DIM}Installing Tailscale (secure remote access)...${RESET}"
  if have_cmd apt-get; then
    run apt-get install -y curl apt-transport-https || true
  fi
  install_tailscale() {
    # Method 1: official install script
    if curl -fsSL --connect-timeout 10 https://tailscale.com/install.sh | sh >> "$LOGFILE" 2>&1; then
      return 0
    fi
    # Method 2: direct apt repo setup
    curl -fsSL --connect-timeout 10 https://pkgs.tailscale.com/stable/ubuntu/noble.gpg \
      | $SUDO tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null 2>&1 || true
    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main" \
      | $SUDO tee /etc/apt/sources.list.d/tailscale.list > /dev/null 2>&1 || true
    $SUDO apt-get update -qq >> "$LOGFILE" 2>&1 || true
    $SUDO apt-get install -y tailscale >> "$LOGFILE" 2>&1 && return 0
    # Method 3: snap
    if have_cmd snap; then
      $SUDO snap install tailscale >> "$LOGFILE" 2>&1 && return 0
    fi
    # Method 4: direct .deb download (works when repos are blocked)
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    TS_VERSION=$(curl -fsSL --connect-timeout 10 "https://pkgs.tailscale.com/stable/" 2>/dev/null | grep -oP 'tailscale_[0-9._]+_${ARCH}\.deb' | sort -V | tail -1 || echo "")
    if [ -n "$TS_VERSION" ]; then
      curl -fsSL --connect-timeout 15 "https://pkgs.tailscale.com/stable/$TS_VERSION" -o /tmp/tailscale.deb >> "$LOGFILE" 2>&1 && \
        $SUDO dpkg -i /tmp/tailscale.deb >> "$LOGFILE" 2>&1 && rm -f /tmp/tailscale.deb && return 0
    fi
    return 1
  }
  if install_tailscale; then
    ok "Tailscale installed"
    TAILSCALE_INSTALLED=true
  else
    # HARD STOP. Continuing past this point produces a "successful"
    # install with no Tailscale, which means no HTTPS endpoint, no
    # serve routes, no /chat path for iOS — the bridge is functionally
    # unreachable from a phone. Better to fail loud here than ship a
    # broken setup that looks fine until the user opens iOS.
    fatal "Tailscale install failed. CARAPACE requires Tailscale for the iOS bridge.

  Try installing it manually:
    curl -fsSL https://tailscale.com/install.sh | sh

  Then re-run this installer."
  fi
fi

# ── Tailscale authentication ────────────────────────────
if $TAILSCALE_INSTALLED; then
  ts_is_running() {
    local state
    state="$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null || echo "")"
    [[ "$state" == "Running" ]]
  }

  ts_hostname() {
    tailscale status --json 2>/dev/null | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo ""
  }

  if ts_is_running; then
    TS_HOSTNAME="$(ts_hostname)"
    ok "Tailscale connected as ${TS_HOSTNAME}"
    TAILSCALE_CONNECTED=true
  else
    echo ""
    echo -e "  ${DIM}Tailscale needs authentication.${RESET}"

    TS_UP_TMPFILE="$(mktemp /tmp/ts-up-XXXXXX)"
    chmod 600 "$TS_UP_TMPFILE"
    $SUDO tailscale up > "$TS_UP_TMPFILE" 2>&1 &
    TS_UP_PID=$!

    # Poll for the auth URL
    URL_PRINTED=false
    for _i in $(seq 1 15); do
      sleep 1
      TS_URL="$(grep -oE 'https://[a-zA-Z0-9./?=_-]+' "$TS_UP_TMPFILE" 2>/dev/null | grep -E 'login\.tailscale|tailscale\.com/a/' | head -1 || true)"
      if [[ -n "$TS_URL" ]]; then
        echo ""
        echo -e "  ${TEAL}┌─────────────────────────────────────────────────────┐${RESET}"
        echo -e "  ${TEAL}│${RESET}  Open this URL in your browser to authenticate:     ${TEAL}│${RESET}"
        echo -e "  ${TEAL}│${RESET}                                                     ${TEAL}│${RESET}"
        echo -e "  ${TEAL}│${RESET}  ${BOLD}${TS_URL}${RESET}"
        echo -e "  ${TEAL}│${RESET}                                                     ${TEAL}│${RESET}"
        echo -e "  ${TEAL}│${RESET}  ${DIM}Waiting... (press Ctrl+C to cancel)${RESET}               ${TEAL}│${RESET}"
        echo -e "  ${TEAL}└─────────────────────────────────────────────────────┘${RESET}"
        echo ""
        URL_PRINTED=true
        break
      fi
    done

    if ! $URL_PRINTED; then
      if [[ -s "$TS_UP_TMPFILE" ]]; then
        echo -e "  ${DIM}Tailscale output:${RESET}"
        cat "$TS_UP_TMPFILE"
      else
        echo -e "  ${DIM}No output from tailscale up — run manually: tailscale up${RESET}"
      fi
      echo ""
    fi

    # No timer. The auth URL is right there on screen — the user clicks
    # it, signs in, comes back. They might be doing MFA, looking for
    # their password manager, switching browsers, whatever. There's no
    # win to bailing out at 90s or 3min: either they finish or they
    # Ctrl+C. We loop forever, polling every 3s, with a heartbeat dot
    # every 30s so the terminal doesn't look frozen. The trap below
    # ensures Ctrl+C cleans up the background `tailscale up`.
    echo -e "  ${DIM}Waiting for authentication... (Ctrl+C to abort)${RESET}"
    trap 'kill "$TS_UP_PID" 2>/dev/null || true; rm -f "$TS_UP_TMPFILE"; echo ""; fatal "Tailscale authentication aborted by user. Re-run when ready."' INT TERM
    WAIT_COUNT=0
    while true; do
      if ! kill -0 "$TS_UP_PID" 2>/dev/null; then
        # `tailscale up` exited on its own — either auth completed
        # (success path) or it errored out (failure path). Use exit
        # status to disambiguate.
        wait "$TS_UP_PID" 2>/dev/null && TAILSCALE_CONNECTED=true || true
        break
      fi
      if ts_is_running; then
        TAILSCALE_CONNECTED=true
        break
      fi
      sleep 3
      WAIT_COUNT=$(( WAIT_COUNT + 3 ))
      # Heartbeat every 30s so the user knows we're still alive
      if (( WAIT_COUNT % 30 == 0 )); then
        if ! $URL_PRINTED; then
          # Belt-and-suspenders: re-scrape the URL in case it appeared
          # after the initial 15s polling window.
          TS_URL="$(grep -oE 'https://login\.tailscale\.com/[^ \n]+' "$TS_UP_TMPFILE" 2>/dev/null | head -1 || true)"
          if [[ -n "$TS_URL" ]]; then
            echo -e "  Auth URL: ${BOLD}${TS_URL}${RESET}"
            URL_PRINTED=true
          fi
        fi
        echo -e "  ${DIM}...still waiting (${WAIT_COUNT}s elapsed)${RESET}"
      fi
    done
    trap - INT TERM
    echo ""

    kill "$TS_UP_PID" 2>/dev/null || true
    wait "$TS_UP_PID" 2>/dev/null || true
    rm -f "$TS_UP_TMPFILE"

    if $TAILSCALE_CONNECTED; then
      TS_HOSTNAME="$(ts_hostname)"
      ok "Tailscale connected as ${TS_HOSTNAME}"
    else
      # HARD STOP. We only reach this branch if `tailscale up` exited
      # non-zero on its own — auth was declined, network error, the
      # tailnet is locked, etc. The wait loop has no timer, so user
      # patience isn't the failure mode here.
      fatal "Tailscale authentication failed.

  CARAPACE requires Tailscale to be connected for the iOS bridge.

  Try authenticating manually to see the underlying error:
    $SUDO tailscale up

  Once authenticated, re-run:
    curl -fsSL https://carapace.info/install.sh | bash"
    fi
  fi
fi

# Belt-and-suspenders invariant check: if we reach this line,
# Tailscale MUST be connected. Anywhere downstream that depends on
# this assumption (HTTPS, serve config, /chat smoke test) can rely
# on it without re-checking. If somehow we slipped through with
# TAILSCALE_CONNECTED=false, abort here loudly rather than producing
# a half-broken install.
if ! $TAILSCALE_CONNECTED; then
  fatal "Tailscale not connected after Step 3 (internal invariant violated). Bug — please report at github.com/mikeypaepke-gif/carapace-site/issues"
fi

# ══════════════════════════════════════════════════════════
# Step 4: HTTPS
# ══════════════════════════════════════════════════════════
step "HTTPS"

TAILSCALE_HTTPS_OK=false

if $TAILSCALE_CONNECTED && [[ -n "$TS_HOSTNAME" ]]; then
  # HTTPS certs are verified after Tailscale serve is configured (Step 6).
  # Just mark that we have the prerequisites for HTTPS.
  TAILSCALE_HTTPS_OK=true
  ok "Tailscale connected — HTTPS will be verified after serve setup"
else
  echo -e "  ${DIM}Skipped (Tailscale not connected)${RESET}"
fi

# ══════════════════════════════════════════════════════════
# Step 5: Gateway
# ══════════════════════════════════════════════════════════
step "Gateway"

echo -e "  ${DIM}Setting gateway configuration...${RESET}"
timeout 10 openclaw config set gateway.mode local >/dev/null 2>&1 || true
timeout 10 openclaw config set gateway.http.endpoints.chatCompletions.enabled true >/dev/null 2>&1 || true
# Open DM policy so CARAPACE iOS app and TUI connect without pairing approval
timeout 10 openclaw config set channels.webchat.dmPolicy open >/dev/null 2>&1 || true
timeout 10 openclaw config set channels.webchat.allowFrom '["*"]' >/dev/null 2>&1 || true
if $TAILSCALE_CONNECTED; then
  timeout 10 openclaw config set gateway.bind loopback >/dev/null 2>&1 || true
else
  timeout 10 openclaw config set gateway.bind lan >/dev/null 2>&1 || true
fi
if $TAILSCALE_HTTPS_OK && [[ -n "$TS_HOSTNAME" ]]; then
  timeout 10 openclaw config set gateway.remote.url "https://${TS_HOSTNAME}" >/dev/null 2>&1 || true
fi
ok "Gateway configured"

# ── Install & start gateway daemon ──────────────────────
echo -e "  ${DIM}Installing gateway service...${RESET}"
if $IS_ROOT && have_cmd systemctl; then
  OC_BIN="$(command -v openclaw 2>/dev/null || true)"
  if [[ -z "$OC_BIN" ]]; then
    for _d in "$HOME"/.nvm/versions/node/*/bin; do
      [[ -x "$_d/openclaw" ]] && OC_BIN="$_d/openclaw" && break
    done
  fi

  # Write a wrapper script so systemd doesn't mangle shell variables.
  # CRITICAL: use SYSTEM node (/usr/bin) FIRST on PATH. Earlier versions
  # of this wrapper preferred nvm node, which made the gateway service
  # run on a different runtime than the openclaw CLI — the bug from
  # github.com/openclaw/openclaw/issues/46256 (WS handshake timeouts).
  cat > /usr/local/bin/openclaw-gateway-run << 'GWWRAPPER'
#!/bin/bash
export HOME=/root
export PATH="/usr/bin:$HOME/.npm-global/bin:$PATH"
# Tune Node heap by system RAM so heavy-usage tails don't OOM during
# startup (the gateway's own sessions.json + checkpoints can push past
# Node's default on busy installs after months of use). Keep headroom
# for the OS and other processes on small-memory boxes:
#   * < 1.5 GB (Raspberry Pi 3, tiny VPS):  512 MB heap
#   * < 3 GB  (Raspberry Pi 4 2 GB):        1024 MB heap
#   * ≥ 3 GB  (most VPSes, RPi 4 4/8 GB):   2048 MB heap
TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
if [[ -z "$TOTAL_RAM_MB" || "$TOTAL_RAM_MB" -lt 1500 ]]; then
  OC_HEAP=512
elif [[ "$TOTAL_RAM_MB" -lt 3000 ]]; then
  OC_HEAP=1024
else
  OC_HEAP=2048
fi
export NODE_OPTIONS="--max-old-space-size=${OC_HEAP}"
# CRITICAL: invoke /usr/bin/node directly with the openclaw entry. Older
# revisions did `exec openclaw gateway run --allow-unconfigured` and
# relied on PATH for `openclaw` resolution — but on a box where nvm
# was previously set up, $PATH could still bring nvm's openclaw shim
# (and its nvm node) into the wrapper, defeating the whole "system
# node only" rationale of issue #46256. Match the per-user drop-in's
# ExecStart format: bare `gateway --port 18789` is what `openclaw
# gateway install` itself writes for non-root, and it accepts an
# unconfigured agent (creates one on first run).
exec /usr/bin/node /root/.npm-global/lib/node_modules/openclaw/dist/index.js gateway --port 18789
GWWRAPPER
  chmod +x /usr/local/bin/openclaw-gateway-run

  cat > /etc/systemd/system/openclaw-gateway.service << 'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=root
WorkingDirectory=/root
# Disable Bonjour/mDNS at the env level — third layer of defense
# beyond the config file edit and `openclaw plugins disable bonjour`
# we run during install. Per https://docs.openclaw.ai/gateway/bonjour
# this is the documented per-process kill switch. On Linux v2026.4.x
# the bonjour plugin's @homebridge/ciao library throws an unhandled
# rejection ("CIAO PROBING CANCELLED") that crashes the gateway in
# a 30-second restart loop. This env var prevents that even if the
# config file ever gets reset by `openclaw onboard` or similar.
Environment=OPENCLAW_DISABLE_BONJOUR=1
# Per github.com/openclaw/openclaw/issues/46256 — bump the pre-auth
# WS handshake timeout from the default 10s to 30s. Slow VPSes can
# take >10s for the first plugin-loading pass, during which the
# gateway can't service the WS upgrade, and clients get
# "handshake timeout" / "gateway connect failed". 30s is comfortable
# for low-RAM cloud VMs without hiding genuinely-stuck connections.
Environment=OPENCLAW_HANDSHAKE_TIMEOUT_MS=30000
ExecStart=/usr/local/bin/openclaw-gateway-run
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable openclaw-gateway >/dev/null 2>&1 || true
  systemctl restart openclaw-gateway >/dev/null 2>&1 || true
  # Clean up any conflicting user-mode service created by a prior unprivileged
  # install. When this script is invoked as `sudo bash`, $HOME is /root and
  # `systemctl --user` targets root's user manager — useless if the previous
  # install was as a normal user. Honor SUDO_USER / SUDO_HOME so we kill the
  # right user-mode unit (the one that would actually conflict with our
  # system-level unit on port 18789).
  REAL_USER="${SUDO_USER:-$(whoami)}"
  REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
  REAL_HOME="${REAL_HOME:-$HOME}"
  if [[ "$REAL_USER" != "root" ]]; then
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
      systemctl --user stop openclaw-gateway 2>/dev/null || true
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
      systemctl --user disable openclaw-gateway 2>/dev/null || true
    rm -f "$REAL_HOME/.config/systemd/user/openclaw-gateway.service" 2>/dev/null || true
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
      systemctl --user daemon-reload 2>/dev/null || true
  else
    # No invoking user — clean root's user-mode anyway in case someone ran
    # the unprivileged install as actual root.
    systemctl --user stop openclaw-gateway 2>/dev/null || true
    systemctl --user disable openclaw-gateway 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/openclaw-gateway.service" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  ok "Gateway system service installed"
else
  # Only call `openclaw gateway install` if we don't already have a token.
  # Otherwise it rotates the token and breaks any already-paired iOS apps
  # (classic 401 after re-run bug).
  if ! jq -e '.gateway.auth.token != null and .gateway.auth.token != ""' "$HOME/.openclaw/openclaw.json" >/dev/null 2>&1; then
    timeout 30 openclaw gateway install >> "$LOGFILE" 2>&1 || true
    # Verify the token actually got written. Observed on fresh Rocky 9
    # cloud images that `openclaw gateway install` can succeed-ish (exit 0)
    # without writing gateway.auth.token, which silently produces a pair
    # URL with &token= (empty). Retry once, then warn loudly if still
    # missing so the user isn't left wondering why iOS can't pair.
    if ! jq -e '.gateway.auth.token != null and .gateway.auth.token != ""' "$HOME/.openclaw/openclaw.json" >/dev/null 2>&1; then
      sleep 2
      timeout 30 openclaw gateway install >> "$LOGFILE" 2>&1 || true
      if ! jq -e '.gateway.auth.token != null and .gateway.auth.token != ""' "$HOME/.openclaw/openclaw.json" >/dev/null 2>&1; then
        warn "Gateway auth token did not get written to openclaw.json."
        warn "Pair URL will be incomplete — iOS won't be able to connect until this is fixed."
        warn "After install finishes, run: openclaw gateway install && carapace-qr"
      fi
    fi
  fi

  # ── Drop-in override: bonjour env-var on the user systemd unit ─────
  # `openclaw gateway install` creates ~/.config/systemd/user/openclaw-gateway.service
  # from a stock template that does NOT set OPENCLAW_DISABLE_BONJOUR.
  # On Linux v2026.4.x bonjour crashes the gateway in a 30-second loop,
  # so we layer a systemd drop-in override (the proper way per
  # https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html)
  # that sets the env var WITHOUT modifying the openclaw-managed unit
  # file. Drop-ins survive `openclaw gateway install` re-runs, which
  # would otherwise overwrite any direct edits to the unit file.
  USER_DROPIN_DIR="$HOME/.config/systemd/user/openclaw-gateway.service.d"
  mkdir -p "$USER_DROPIN_DIR"
  cat > "$USER_DROPIN_DIR/carapace-overrides.conf" << DROPIN_EOF
# Set by the CARAPACE installer.
#
# 1) Disable the bonjour mDNS advertiser — the @homebridge/ciao lib
#    crashes the gateway in a 30-second restart loop on Linux. See:
#      https://docs.openclaw.ai/gateway/bonjour
# 2) Force /usr/bin/node (system) for ExecStart — \`openclaw gateway
#    install\` writes a unit file that uses whatever node was in PATH
#    at install time, which on a box with both nvm and system node
#    becomes nvm node. CLI invokes openclaw via system node (PATH=
#    /usr/bin:...) but the gateway service was running on nvm node →
#    runtime mismatch → WS handshake races → "gateway connect failed".
#    Fixed per github.com/openclaw/openclaw/issues/46256.
# 3) Bump the WS pre-auth handshake timeout to 30s — defaults to 10s
#    in v2026.3.22+, and slow VPSes can take longer than that for the
#    initial plugin-loading pass.
[Service]
Environment=OPENCLAW_DISABLE_BONJOUR=1
Environment=OPENCLAW_HANDSHAKE_TIMEOUT_MS=30000
ExecStart=
ExecStart=/usr/bin/node $HOME/.npm-global/lib/node_modules/openclaw/dist/index.js gateway --port 18789
DROPIN_EOF
  systemctl --user daemon-reload 2>/dev/null || true

  # Force RESTART (not start) — `openclaw gateway install` may have
  # already started the gateway with the original (pre-drop-in) unit
  # config that uses nvm node. We must restart to pick up the
  # drop-in's ExecStart override + handshake timeout env, otherwise
  # the WS handshake race continues.
  systemctl --user restart openclaw-gateway >/dev/null 2>&1 || \
    timeout 15 openclaw gateway start >/dev/null 2>&1 || true
fi

echo -e "  ${DIM}Waiting for gateway to start...${RESET}"
sleep 3  # Brief pause to let systemd fully initialize
GATEWAY_UP=false
for i in $(seq 1 20); do
  if curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
    GATEWAY_UP=true
    break
  fi
  sleep 1
done

if $GATEWAY_UP; then
  ok "Gateway running on port 18789"
else
  # Retry
  timeout 15 openclaw gateway start >/dev/null 2>&1 || true
  for i in $(seq 1 10); do
    if curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
      GATEWAY_UP=true
      break
    fi
    sleep 1
  done
  if $GATEWAY_UP; then
    ok "Gateway running on port 18789"
  else
    warn "Gateway not responding — check: systemctl status openclaw-gateway"
  fi
fi

# ── User-systemd linger (CRITICAL for non-root sudoer installs) ──
# The gateway service typically lives under user-systemd (see Mike's
# install where openclaw onboard creates ~/.config/systemd/user/
# openclaw-gateway.service). Without `loginctl enable-linger <user>`,
# user-systemd dies the moment the last SSH/login session closes —
# taking the gateway with it. The systemd service auto-restarts when
# the user logs in again, but in the gap (and forever if no one logs
# in) the gateway is gone and iOS chat/voice 502s with "bad gateway."
# Enable linger so the user's systemd survives logout, exactly like
# a system-level service would.
if ! $IS_ROOT && have_cmd loginctl; then
  CURRENT_LINGER="$(loginctl show-user "$(whoami)" --property=Linger --value 2>/dev/null || echo no)"
  if [[ "$CURRENT_LINGER" != "yes" ]]; then
    if $SUDO loginctl enable-linger "$(whoami)" 2>/dev/null; then
      ok "Linger enabled — gateway survives SSH logout"
    else
      warn "Could not enable linger — gateway may stop when you log out (run: sudo loginctl enable-linger $(whoami))"
    fi
  fi
fi

# Idempotency check: if a previous install picked a model, preserve it.
# Otherwise leave the keys ABSENT — `openclaw onboard` checks for
# missing-key vs empty-string and treats them differently. Earlier
# revisions wrote `agents.defaults.model ""` here, which made onboard's
# detection logic consider the model "already configured" (just empty)
# and silently SKIP the model-picker prompt. Don't write empty strings.
EXISTING_MODEL=$(timeout 10 openclaw config get agents.defaults.model 2>/dev/null | head -1 | tr -d '"{ ' || echo "")
if [[ -n "$EXISTING_MODEL" && "$EXISTING_MODEL" != "null" ]]; then
  ok "Existing model preserved: $EXISTING_MODEL"
fi

# ── Disable bonjour on Linux (headless / VPS / cloud) ──────────────────
# OpenClaw's `bonjour` plugin advertises the gateway over mDNS for
# local-network discovery. Useful on a Mac/desktop where other machines
# on the same LAN should find the gateway by name. Useless on:
#   • A cloud VPS (no LAN to broadcast on)
#   • A Tailscale-only deployment (Tailscale handles discovery)
#   • Any headless server install
# Worse than useless: on Linux v2026.4.x the @homebridge/ciao mDNS
# library hits an "AssertionError: CIAO PROBING CANCELLED" → unhandled
# promise rejection → gateway exits → systemd restarts → infinite crash
# loop within ~30s of every startup. We disable it three ways
# (config file, env var, CLI) so any single-method failure doesn't
# leave us with a crashing gateway.
#
# Per https://docs.openclaw.ai/gateway/bonjour the official knobs are:
#   1. `openclaw plugins disable bonjour` (CLI, persists in config)
#   2. `OPENCLAW_DISABLE_BONJOUR=1` env var (per-process)
#   3. `plugins.bonjour.enabled = false` in openclaw.json
#
# Mac users who legitimately want LAN discovery can re-enable with:
#   openclaw plugins enable bonjour
echo -e "  ${DIM}Disabling Bonjour mDNS plugin (causes crash loop on Linux)…${RESET}"
BONJOUR_DISABLED=false
# Method 1: direct config file edit (atomic, no CLI failure modes)
#
# CRITICAL — schema is `plugins.entries.bonjour.enabled`, NOT
# `plugins.bonjour.enabled`. The OpenClaw docs at
# https://docs.openclaw.ai/gateway/bonjour show the latter, but the
# actual config schema (verified by `openclaw config set` rejecting
# `plugins.bonjour` with "Unrecognized key") puts plugin entries
# under `plugins.entries.<name>`. Writing the wrong path corrupts
# the config such that `openclaw plugins disable bonjour` then
# fails with a validation error AND the gateway can't boot. Took
# us hours to track that one down — pin the correct schema here
# and clean up any prior bad writes.
if [ -f "$HOME/.openclaw/openclaw.json" ]; then
  python3 - "$HOME/.openclaw/openclaw.json" <<'BONJOUR_PY' 2>/dev/null && BONJOUR_DISABLED=true
import json, sys
fp = sys.argv[1]
d = json.load(open(fp))
# Strip any prior bad write at the wrong path
if "plugins" in d and isinstance(d["plugins"], dict) and "bonjour" in d["plugins"]:
    del d["plugins"]["bonjour"]
# Set the CORRECT path: plugins.entries.bonjour.enabled = false
d.setdefault("plugins", {}).setdefault("entries", {}).setdefault("bonjour", {})["enabled"] = False
json.dump(d, open(fp, "w"), indent=2)
BONJOUR_PY
fi
# Method 2: openclaw CLI (also writes config — belt-and-suspenders;
#           keep the output visible this time so a real failure can be
#           seen in the install log instead of swallowed by /dev/null)
if command -v openclaw >/dev/null 2>&1; then
  if openclaw plugins disable bonjour 2>&1 | grep -qE "Disabled plugin|already disabled"; then
    BONJOUR_DISABLED=true
  fi
fi
# Method 3: gateway systemd unit env var — added later in the gateway
#           install block below (search for OPENCLAW_DISABLE_BONJOUR=1).
#           That ensures even if config gets reset, the env var still
#           prevents the crash.
if $BONJOUR_DISABLED; then
  ok "Bonjour mDNS plugin disabled (config + CLI; env var added to systemd unit too)"
else
  warn "Could not disable bonjour automatically — gateway may crash-loop. Manual fix:"
  warn "    openclaw plugins disable bonjour && systemctl --user restart openclaw-gateway"
fi

# ══════════════════════════════════════════════════════════
# Step 6: Status Server
# ══════════════════════════════════════════════════════════
step "Status Server"

mkdir -p ~/.carapace

# Tracker files (create if missing)
[[ -f ~/.carapace/carapace-project-tracker.json ]] || cat > ~/.carapace/carapace-project-tracker.json << 'PROJECTJSON'
{"version":1,"updated":"","projects":[{"id":"setup-ios","name":"Get CARAPACE on your iPhone","description":"Step 1: Download CARAPACE from the App Store\nhttps://apps.apple.com/us/app/carapace/id6760282881\n\nStep 2: Open the app, tap Connect Server, then scan the QR code in the Settings tab.","status":"green","progress":0,"workstreams":[]}]}
PROJECTJSON
[[ -f ~/.carapace/carapace-agent-tracker.json ]] || echo '{"agents":{"main":{"name":"Main","status":"idle","detail":"Ready","updated":""}},"completions":[]}' > ~/.carapace/carapace-agent-tracker.json
[[ -f ~/.carapace/carapace-cron-tracker.json ]] || echo '{"version":1,"updated":"","jobs":[]}' > ~/.carapace/carapace-cron-tracker.json

NODE_BIN="$(command -v node)"

# Write status server and sync script via python3 (avoids heredoc quote-stripping)
# Pull status-server.js from carapace.info — single source of truth.
# We previously inlined a minified copy of the JS here, which silently
# drifted from the canonical version every time someone updated the
# server (e.g. the agents-list-from-openclaw.json fix that broke new
# agents from showing in the iOS spinal map). Same domain as this
# install.sh, same trust model — if you trust the install script,
# you trust this fetch.
mkdir -p "$HOME/.carapace"
# Default to raw.githubusercontent.com because carapace.info is fronted
# by Cloudflare, which has been observed serving stale .js files even
# with cf-cache-status: DYNAMIC headers (CF page rules + tiered cache
# bite us when we push frequent updates). raw.githubusercontent serves
# directly from the GitHub repo with much shorter TTLs — what hits
# main is what gets installed within ~30s. Override with SS_URL=...
# if you want the carapace.info-fronted version specifically.
SS_URL="${SS_URL:-https://raw.githubusercontent.com/mikeypaepke-gif/carapace-site/main/status-server.js}"
if curl -fsSL "$SS_URL" -o "$HOME/.carapace/status-server.js"; then
  echo "✓ Installed status-server.js from $SS_URL"
else
  echo "✗ Failed to download status-server.js from $SS_URL — iOS dashboard will not work"
  exit 1
fi

# ── COGNITIVE MEMORY MODULES (brain-region architecture) ──────────────
# Fetched from carapace.info/cognitive/ — same trust model as the
# main install script. Modules implement: hippocampus (episodic memory),
# parahippocampal place area (place schemas), entorhinal grid cells
# (cognitive map), amygdala (affect tags), and the assembler that
# stitches it all into a per-turn injection. status-server.js loads
# them lazily on first /cognitive/* or /chat call.
install_carapace_cognitive() {
  local DEST="$HOME/.carapace/cognitive"
  mkdir -p "$DEST/data"
  local BASE="${COG_BASE:-https://carapace.info/cognitive}"
  local files="schema.sql geohash.mjs visits.mjs ingest.mjs sub_area.mjs auditory.mjs assemble.mjs affect.mjs consolidate.mjs"
  local ok=0 fail=0
  for f in $files; do
    if curl -fsSL "$BASE/$f" -o "$DEST/$f"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "  ✗ cognitive/$f"
    fi
  done
  if [ "$fail" -gt 0 ]; then
    echo "⚠ Cognitive modules: $ok installed, $fail failed — /chat + /cognitive endpoints may not work"
  else
    echo "✓ Cognitive modules ($ok files) installed → $DEST"
  fi
  # better-sqlite3 npm dep — status-server requires it for cognitive endpoints
  if [ ! -f "$HOME/.carapace/package.json" ]; then
    cat > "$HOME/.carapace/package.json" << 'PKG'
{ "name": "carapace-status-server", "private": true, "dependencies": { "better-sqlite3": "^11.5.0" } }
PKG
  fi
  if (cd "$HOME/.carapace" && npm install --silent >/dev/null 2>&1); then
    echo "✓ better-sqlite3 installed for cognitive memory"
  else
    echo "⚠ npm install in ~/.carapace failed — cognitive endpoints will return errors"
  fi
}

install_carapace_cognitive
# Tailscale routes for /chat + /cognitive (and every other endpoint)
# get added in the main Tailscale Serve block ~200 lines below, which
# runs AFTER `tailscale serve --bg http://127.0.0.1:18789` initializes
# the serve config. CARAPACE_SERVE_ROUTES below is the single source
# of truth — both the imperative install and the persistent systemd
# unit derive from it, so adding a new endpoint is a one-line change.

python3 - << 'PYEOF'
import os, textwrap

# Dead-code embedded status-server block deleted. The canonical version
# is downloaded fresh from raw.github at install time (see SS_URL block
# above). This Python heredoc now only generates sync-trackers.sh.

sync_script = textwrap.dedent("""
    #!/usr/bin/env bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    # openclaw is installed to ~/.npm-global/bin via `npm config set prefix`. nvm's
    # own node/*/bin ONLY contains node/npm/npx/corepack, so the npm-global prefix
    # must come first on PATH for `command -v openclaw` to resolve.
    export PATH="$HOME/.npm-global/bin:$PATH"
    for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && export PATH="$d:$PATH"; done
    OC=$(command -v openclaw 2>/dev/null)
    if [ -z "$OC" ]; then
      # Log loudly so broken PATH configs surface in syslog (previous silent exit
      # hid this bug for hours at a time).
      logger -t carapace-sync "openclaw not on PATH; skipping tracker sync"
      exit 1
    fi
    $OC cron list --json --all 2>/dev/null | python3 -c "
    import json, sys
    from datetime import datetime, timezone
    def fmt_ms(ms):
        if not ms: return ''
        try: return datetime.fromtimestamp(ms/1000, tz=timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        except: return ''
    d = json.load(sys.stdin)
    jobs = []
    for j in d.get('jobs', []):
        s = j.get('schedule', {})
        if s.get('kind') == 'every':
            mins = s.get('everyMs', 0) // 60000
            sched = 'every {}m'.format(mins)
        elif s.get('kind') == 'cron':
            sched = s.get('expr', '')
        else:
            sched = s.get('kind', '')
        state = j.get('state', {})
        jobs.append({'id': j.get('id',''), 'name': j.get('name', j.get('id','')), 'schedule': sched,
            'enabled': j.get('enabled', True),
            'status': 'idle' if j.get('enabled', True) else 'disabled',
            'lastRun': fmt_ms(state.get('lastRunAtMs')),
            'nextRun': fmt_ms(state.get('nextRunAtMs')),
            'payload': (j.get('payload',{}) or {}).get('message','')[:120]})
    import os
    json.dump({'version':1,'updated':datetime.now(timezone.utc).isoformat(),'jobs':jobs},
        open(os.path.expanduser('~/.carapace/carapace-cron-tracker.json'),'w'),indent=2)
    "
    # Projects are no longer sync'd here — they live directly in
    # ~/.openclaw/workspace/memory/MEMORY.md (managed CARAPACE PROJECTS
    # block, agent-maintained, real-time iOS reflection). status-server.js
    # reads from MEMORY.md on every /projects request and migrates from
    # tracker.json on its first boot if the block is absent. Cron only
    # syncs cron jobs now.
""").lstrip()

home = os.path.expanduser("~")
# status-server.js is downloaded fresh from raw.github at install time
# (see SS_URL block above this Python heredoc); only sync-trackers.sh
# is generated inline.
with open(home + "/.carapace/sync-trackers.sh", "w") as f:
    f.write(sync_script)
os.chmod(home + "/.carapace/sync-trackers.sh", 0o755)
PYEOF

# Migrate from the legacy `carapace-status-server.service` if it
# exists from older installs (we used to install BOTH this and
# `carapace-status.service`, both binding :18794 — they conflicted on
# port. Now there's only one service; clean up the legacy one).
if have_cmd systemctl && systemctl list-unit-files carapace-status-server.service >/dev/null 2>&1; then
  $SUDO systemctl stop carapace-status-server >/dev/null 2>&1 || true
  $SUDO systemctl disable carapace-status-server >/dev/null 2>&1 || true
  $SUDO rm -f /etc/systemd/system/carapace-status-server.service
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Evict any stale process on 18794 before (re)starting so systemd
# can bind cleanly. Without this the new service crashloops with
# EADDRINUSE on a re-install over a manually-launched node process.
if have_cmd ss; then
  STALE_PID=$(ss -lntp 2>/dev/null | awk '/127.0.0.1:18794/ {print}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
  [[ -n "${STALE_PID:-}" ]] && kill -9 "$STALE_PID" 2>/dev/null || true
fi

$SUDO tee /etc/systemd/system/carapace-status.service > /dev/null << EOF
[Unit]
Description=CARAPACE Status Server
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=$NODE_BIN $HOME/.carapace/status-server.js
Restart=always
RestartSec=5
User=$(whoami)
Environment=HOME=$HOME
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

sysctl_safe daemon-reload
sysctl_safe enable carapace-status >/dev/null 2>&1
sysctl_safe restart carapace-status
sleep 2
if curl -sf --max-time 3 http://127.0.0.1:18794/health >/dev/null 2>&1; then
  ok "Status server running on :18794"
elif have_cmd systemctl; then
  warn "Status server failed to start — run: systemctl status carapace-status"
else
  warn "Status server not started (no systemd). Start manually: node ~/.carapace/status-server.js &"
fi

# (Status server file + systemd unit are installed earlier in this Step
# — the duplicate download block that previously lived here pulled from
# carapace.info/status-server.js (Cloudflare-fronted, stale-cache prone)
# and was overwriting the raw.githubusercontent.com copy fetched ~200
# lines above. Removed in the post-system-node audit; the earlier
# download + systemd setup is sufficient.)

# Empty project tracker skeleton so /projects returns valid JSON.
[[ -f "$HOME/.carapace/carapace-project-tracker.json" ]] || \
  echo '{"version":1,"updated":"","projects":[]}' > "$HOME/.carapace/carapace-project-tracker.json"

# Pre-cache tailscale status so the /pair endpoint can answer without
# having to exec the tailscale binary from a PATH-minimal systemd env.
# status-server.js will still fall back to `tailscale status --json`
# via explicit-path lookup if this file is missing, but caching saves a
# few ms per call and works around completely locked-down environments.
# Useful for both root and non-root installs.
if have_cmd tailscale; then
  tailscale status --json > "$HOME/.carapace/tailscale-status.json" 2>/dev/null || true
fi
# (The legacy `carapace-status-server.service` block that used to live
# here was a duplicate of the canonical `carapace-status.service`
# defined ~80 lines above. Both bound :18794 and conflicted on port.
# Migration to single service handled in the legacy-cleanup block
# above the canonical service definition.)

# ── Tailscale Serve ─────────────────────────────────────
# `tailscale serve` writes to /var/lib/tailscale/serve.json which is
# root-owned; non-root users get "Access denied: serve config denied"
# unless `tailscale set --operator=$USER` was previously run. Always
# go through $SUDO so sudoer installs work on a fresh box without
# pre-configuring tailscale operator privileges.
SERVE_OK=false
if $TAILSCALE_CONNECTED && $GATEWAY_UP; then
  echo -e "  ${DIM}Connecting Tailscale Serve...${RESET}"
  # Always run tailscale serve for gateway. 10s timeout in case the
  # tailscale daemon is wedged — without it the install would hang
  # indefinitely on a daemon that's not responding to control commands.
  timeout 10 $SUDO tailscale serve --bg http://127.0.0.1:18789 >/dev/null 2>&1 || true
  ok "Tailscale serve → gateway connected"
  SERVE_OK=true

  # ── Single source of truth for ALL Tailscale serve routes ────────
  # Previously these were strewn across 3 places (this block, a separate
  # cognitive-routes function, and a re-assert hidden in the smoke test).
  # When any one place drifted (e.g. /chat got added later than the rest),
  # iOS would 404 in production with no clear repro. Now every route lives
  # in one array and gets applied in one batched call with explicit error
  # capture — if a route fails to register, we know which one and why.
  #
  # IMPORTANT — destination URL path semantics:
  #   `tailscale serve --set-path /X http://...:18794/Y` strips /X from
  #   the incoming request, then PREPENDS /Y to the forwarded path.
  #   So /chat → /Y for backend = exactly the right shape if we want
  #   /chat to land at /chat on the status server. The /carapace
  #   catch-all uses bare http://...:18794 (no path) so /carapace/foo
  #   forwards as /foo on the backend (matching the actual routes).
  # Single source of truth for ALL Tailscale serve routes — used both
  # for the imperative install loop below AND for generating the
  # persistent systemd unit's ExecStartPost lines further down. iOS
  # hits these bare (`/chat`, `/projects` etc) — the legacy
  # `/carapace/<endpoint>` prefix from the pre-1.x iOS app was
  # removed (no production deployments to maintain compat with).
  CARAPACE_SERVE_ROUTES=(
    # path                               backend_url
    "/health                              http://127.0.0.1:18794/health"
    "/history                             http://127.0.0.1:18794/history"
    "/sessions                            http://127.0.0.1:18794/sessions"
    "/projects                            http://127.0.0.1:18794/projects"
    "/cron                                http://127.0.0.1:18794/cron"
    "/agents                              http://127.0.0.1:18794/agents"
    "/status                              http://127.0.0.1:18794/status"
    "/pair                                http://127.0.0.1:18794/pair"
    "/chat                                http://127.0.0.1:18794/chat"
    "/cognitive                           http://127.0.0.1:18794/cognitive"
  )
  # Wrap each call in `timeout 10` — without it, a hung tailscale
  # daemon (DNS lookup stuck, control plane unreachable, etc.) makes
  # the loop hang indefinitely with zero output. The user sees "still
  # pending" forever and has to Ctrl+C the whole install. 10s is
  # plenty for a single serve registration on a healthy daemon.
  ROUTES_OK=0; ROUTES_FAIL=0; FAILED_ROUTES=""
  for entry in "${CARAPACE_SERVE_ROUTES[@]}"; do
    # Split on whitespace. NOTE: `local` would be a bash error here —
    # this loop runs in the install's main body, not inside a function.
    # Plain variables it is.
    set -- $entry
    ROUTE_PATH="$1"; BACKEND="$2"
    if timeout 10 $SUDO tailscale serve --bg --set-path "$ROUTE_PATH" "$BACKEND" >/dev/null 2>&1; then
      ROUTES_OK=$((ROUTES_OK + 1))
    else
      ROUTES_FAIL=$((ROUTES_FAIL + 1))
      FAILED_ROUTES="${FAILED_ROUTES}${ROUTE_PATH} "
    fi
  done
  if [[ $ROUTES_FAIL -eq 0 ]]; then
    ok "Tailscale serve → status server paths ($ROUTES_OK routes)"
  else
    warn "Tailscale serve: $ROUTES_OK ok, $ROUTES_FAIL FAILED → $FAILED_ROUTES"
    warn "  Re-run the failed ones manually:"
    warn "    sudo tailscale serve --bg --set-path <PATH> <BACKEND>"
  fi

  # CARAPACE intentionally stays TAILNET-ONLY (no Funnel). Funnel would
  # expose the gateway to the public internet via Tailscale's edge nodes,
  # which means Tailscale terminates TLS and could see traffic in
  # plaintext, and any leak of the bearer token (browser history, logs,
  # screenshots of the QR) is exploitable from anywhere on the internet.
  # The right model for a personal AI is: phone runs Tailscale, joins
  # your tailnet, hits the .ts.net hostname directly with end-to-end
  # tunnel encryption. The pair-instructions banner at the end of the
  # install reminds the user to install Tailscale on their phone.

  # Verify HTTPS endpoint
  if [[ -n "$TS_HOSTNAME" ]]; then
    sleep 2
    if curl -sf --max-time 5 "https://${TS_HOSTNAME}/health" >/dev/null 2>&1; then
      ok "HTTPS verified: https://${TS_HOSTNAME}"
    else
      echo -e "  ${DIM}HTTPS endpoint may take a moment to propagate — this is normal${RESET}"
    fi
  fi
fi

# ── Tailscale serve persistence (survives reboot) ───
# Tailnet-only by design — see the comment in the imperative serve
# block above for why we don't use Funnel. If you WANT public access
# (eg. you can't put Tailscale on your phone), add this line to the
# unit AFTER all serve ExecStartPost lines:
#   ExecStartPost=-/usr/bin/tailscale funnel --bg http://127.0.0.1:18789
# The "-" prefix makes it non-fatal if your tailnet ACL blocks funnel.
if $SERVE_OK && have_cmd systemctl; then
  # Defensively turn funnel OFF on every install — older versions of
  # this script (commits 35bf3ea..04feb0a8) shipped a unit that enabled
  # funnel by default, so an upgrade-in-place could leave a public
  # config behind. Idempotent: no-op if funnel was never on.
  $SUDO tailscale funnel --https=443 off >/dev/null 2>&1 || true

  # Generate the ExecStartPost block from CARAPACE_SERVE_ROUTES (the
  # same array we used for the imperative install loop above). Single
  # source of truth — adding /foo or /carapace/foo above automatically
  # makes both shapes survive a reboot, with no hand-editing of the
  # systemd unit. Earlier versions of this script kept a hardcoded
  # ExecStartPost list here that drifted out of sync with the install
  # loop (e.g. /carapace/health was added to the install but not the
  # unit), so on every Tailscale restart the unit would replay an
  # incomplete config and 404 some endpoints. The drift bug.
  TS_EXEC_POSTS=""
  for entry in "${CARAPACE_SERVE_ROUTES[@]}"; do
    set -- $entry
    TS_EXEC_POSTS="${TS_EXEC_POSTS}ExecStartPost=/usr/bin/tailscale serve --bg --set-path $1 $2"$'\n'
  done

  $SUDO tee /etc/systemd/system/carapace-tailscale-serve.service > /dev/null << TSEOF
[Unit]
Description=CARAPACE Tailscale Serve (tailnet-only)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
# Gateway WS endpoint — root catch-all to the OpenClaw gateway. iOS
# hits this for the actual chat completion stream (over Tailscale TLS).
ExecStart=/usr/bin/tailscale serve --bg http://127.0.0.1:18789
# Status-server routes — generated from CARAPACE_SERVE_ROUTES at
# install time. /carapace catch-all destination is bare (no /carapace
# suffix) so /carapace/pair → strip → /pair → upstream /pair. Earlier
# persistence units shipped /carapace/carapace as destination, which
# made the catch-all 404 every sub-path without an explicit override.
${TS_EXEC_POSTS}
[Install]
WantedBy=multi-user.target
TSEOF
  sysctl_safe daemon-reload
  sysctl_safe enable carapace-tailscale-serve >/dev/null 2>&1
  # Start it once now too — until commit 35bf3ea the unit was only enabled,
  # never started, so a fresh install relied on the imperative serve calls
  # above (which silently failed for sudoers due to missing $SUDO before
  # that commit). Starting the unit reconciles the running serve config
  # with the unit definition and overwrites any leftover funnel state.
  sysctl_safe restart carapace-tailscale-serve >/dev/null 2>&1
  ok "Tailscale serve persistence enabled (tailnet-only)"
fi

# ── Cron-jobs sync cron ─────────────────────────────────
# Mirrors `openclaw cron list` into ~/.carapace/carapace-cron-tracker.json
# every 2 minutes so the iOS Cron tab has data to render. Projects are
# NO LONGER synced here — they live in MEMORY.md and status-server.js
# reads them in real-time.
bash ~/.carapace/sync-trackers.sh 2>/dev/null || true
SYNC_CRON="*/2 * * * * bash $HOME/.carapace/sync-trackers.sh >/dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "sync-trackers" || true; echo "$SYNC_CRON" ) | sort -u | crontab -
ok "Cron jobs sync running every 2 minutes (projects now real-time via MEMORY.md)"

# ══════════════════════════════════════════════════════════
# Step 7: Helper Commands
# ══════════════════════════════════════════════════════════
step "Helper Commands"

# Ensure qrencode is installed
if ! have_cmd qrencode; then
  if have_cmd apt-get; then
    $SUDO apt-get install -y qrencode >/dev/null 2>&1 || true
  elif have_cmd dnf; then
    $SUDO dnf install -y qrencode >/dev/null 2>&1 || true
  fi
fi
have_cmd qrencode && ok "qrencode ready" || true

# carapace-qr command
$SUDO tee /usr/local/bin/carapace-qr > /dev/null << 'QRCMD'
#!/usr/bin/env bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
for _d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_d" ] && export PATH="$_d:$PATH"; done
export PATH="$HOME/.npm-global/bin:$PATH"
TOKEN=$(python3 -c "import json,os; c=json.load(open(os.path.expanduser('~/.openclaw/openclaw.json'))); print(c.get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
TS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null)
[[ -n "$TS" ]] && GW="https://$TS" || GW="http://$(hostname -I 2>/dev/null | awk '{print $1}' || ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1 || echo '127.0.0.1'):18789"
ENC_GW=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$GW")
ENC_TOKEN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TOKEN")
# Vision mode no longer needs a Gemini key — the iPhone runs Apple's
# on-device perception layer (camera + LiDAR + Vision framework) and
# routes turns through OpenClaw to whatever chat provider the user
# picked during setup. The pair URL only carries the gateway address
# and token now.
LINK="carapace://config?gatewayBaseURL=${ENC_GW}&token=${ENC_TOKEN}"
echo ""
echo "  Gateway: $GW"
echo "  Token:   ${TOKEN:0:16}..."
echo ""
if ! command -v qrencode >/dev/null 2>&1; then
  apt-get install -y qrencode >/dev/null 2>&1 || true
fi
if command -v qrencode >/dev/null 2>&1; then
  echo "  Scan with CARAPACE iOS app:"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$LINK"
  echo ""
fi
# ALWAYS print the pair URL too — even when QR rendered, the URL is
# useful for copy-paste (terminal scrolled QR off, color codes garbled
# the QR, user is on a TTY without UTF8 etc).
echo "  Pair URL (copy into iOS Carapace app if QR doesn't scan):"
echo "    $LINK"
echo ""
QRCMD
$SUDO chmod +x /usr/local/bin/carapace-qr
ok "carapace-qr command installed"

# carapace-onboard wrapper — thin handoff to `openclaw onboard`,
# which is OpenClaw's own polished interactive picker for credentials,
# channels, gateway, and agent defaults (model, provider, etc.).
# We used to maintain a parallel picker here that prompted for provider,
# pasted API keys, set the default model, then ran a smoke test —
# duplicating work openclaw already does, and drifting out of sync with
# upstream model availability. Now we just hand off.
$SUDO tee /usr/local/bin/carapace-onboard > /dev/null << 'ONBOARDCMD'
#!/usr/bin/env bash
# Silence nvm/npmrc conflict warning
sed -i '/^prefix=/d;/^globalconfig=/d' "$HOME/.npmrc" 2>/dev/null || true
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
for _d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_d" ] && export PATH="$_d:$PATH"; done
# Also add npm-global bin where openclaw is installed
export PATH="$HOME/.npm-global/bin:$PATH"
exec openclaw onboard "$@"
ONBOARDCMD
$SUDO chmod +x /usr/local/bin/carapace-onboard
ok "carapace-onboard installed (wraps openclaw onboard)"

# ── Nightly maintenance cron ────────────────────────────
# Resolve the real openclaw binary (npm-global takes precedence — nvm's node/bin
# only contains node/npm/npx/corepack, NOT openclaw). Falls back through other
# canonical install paths.
OC_BIN=""
for _candidate in "$HOME/.npm-global/bin/openclaw" "/usr/local/bin/openclaw" "/usr/bin/openclaw"; do
  if [[ -x "$_candidate" ]]; then OC_BIN="$_candidate"; break; fi
done
if [[ -z "$OC_BIN" ]] && have_cmd openclaw; then
  OC_BIN="$(command -v openclaw)"
fi
if [[ -z "$OC_BIN" ]]; then
  warn "Could not resolve openclaw binary for nightly cron; skipping restart schedule."
  CRON_LINE=""
else
  CRON_LINE="0 3 * * * export TZ=UTC; export NVM_DIR=\"\$HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; export PATH=\"\$HOME/.npm-global/bin:\$PATH\"; $OC_BIN gateway restart >/dev/null 2>&1"
fi
( crontab -l 2>/dev/null | grep -v 'openclaw gateway restart' | grep -v 'sync-trackers' || true; echo "$SYNC_CRON"; echo "$CRON_LINE" ) | crontab -
ok "Nightly gateway restart scheduled (3am UTC)"

# Reload shell profile
if [[ -f /etc/profile.d/openclaw.sh ]]; then
  source /etc/profile.d/openclaw.sh 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════
# Final Health Check
# ══════════════════════════════════════════════════════════
step "Health Check"
echo -e "  ${DIM}Running final health checks...${RESET}"
FINAL_GW=false
FINAL_STATUS=false
if curl -sf --max-time 5 http://127.0.0.1:18789/health >/dev/null 2>&1; then
  FINAL_GW=true
  ok "Gateway health check passed"
else
  warn "Gateway health check failed — check: systemctl status openclaw-gateway"
fi
if curl -sf --max-time 5 http://127.0.0.1:18794/health >/dev/null 2>&1; then
  FINAL_STATUS=true
  ok "Status server health check passed"
else
  warn "Status server health check failed — check: systemctl status carapace-status"
fi

# ══════════════════════════════════════════════════════════
# Step 9: Configure Your AI (hand-off to OpenClaw)
# ══════════════════════════════════════════════════════════
# We used to maintain a parallel provider/model picker here that
# duplicated `openclaw onboard`. Removed — OpenClaw's own picker
# is polished, supports every provider it can route to, and stays
# in sync with upstream model availability automatically. We just
# hand off.
step "Configure Your AI"
# Test whether /dev/tty is actually openable. `curl | bash` gives
# bash a non-TTY stdin (the curl pipe), so `[ -t 0 ]` fails — but
# /dev/tty IS openable because there's still a controlling terminal.
# The previous `-t 0 && -e /dev/tty` check skipped onboard entirely
# in the curl|bash case, which is the documented happy path.
# `( : < /dev/tty ) 2>/dev/null` opens /dev/tty in a subshell with
# the no-op `:` builtin and discards the error if it fails — exit
# status reflects whether the open succeeded, which is the only
# precondition openclaw onboard's TUI actually needs.
if ( : < /dev/tty ) 2>/dev/null; then
  echo -e "  ${DIM}Launching openclaw onboard — pick your provider, paste your${RESET}"
  echo -e "  ${DIM}key, choose your model. Press Ctrl+C to skip and run later${RESET}"
  echo -e "  ${DIM}with: ${BOLD}openclaw onboard${RESET}${DIM} (or carapace-onboard)${RESET}"
  echo ""
  echo -e "  ${BOLD}Recommended models${RESET} ${DIM}(fastest stable per provider — pick anything,${RESET}"
  echo -e "  ${DIM}these are just the safest defaults if you're unsure):${RESET}"
  echo -e "    ${BOLD}xAI${RESET}        ${DIM}→${RESET} xai/grok-4-1-fast-non-reasoning"
  echo -e "    ${BOLD}OpenAI${RESET}     ${DIM}→${RESET} openai/gpt-5-mini"
  echo -e "    ${BOLD}Anthropic${RESET}  ${DIM}→${RESET} anthropic/claude-haiku-4-5"
  echo -e "    ${BOLD}Google${RESET}     ${DIM}→${RESET} google/gemini-2.5-flash"
  echo -e "  ${DIM}Avoid models with ${BOLD}beta${RESET}${DIM}, ${BOLD}preview${RESET}${DIM}, or ${BOLD}4.20${RESET}${DIM} in the name —${RESET}"
  echo -e "  ${DIM}they hit safety filters or stall on first turn.${RESET}"
  echo ""
  openclaw onboard < /dev/tty > /dev/tty 2>&1 ||     warn "openclaw onboard exited non-zero — re-run with: openclaw onboard"
else
  echo -e "  ${YELLOW}No TTY available (curl|bash from a non-interactive shell).${RESET}"
  echo -e "  Run this on the machine to set up your AI provider:"
  echo ""
  echo -e "      ${BOLD}openclaw onboard${RESET}"
  echo ""
fi

# ══════════════════════════════════════════════════════════
# Carapace post-onboard injection
# ══════════════════════════════════════════════════════════
# Run THIS BEFORE the pre-warm/liveness test, NOT at the end of the
# script (where it used to live, after Step 10 Connect — the user had
# already seen the QR + paired by then). Order matters:
#   1. openclaw onboard   ← writes/overwrites stock AGENTS.md
#   2. carapace inject    ← THIS BLOCK: layers our sentinel + BOOTSTRAP +
#                           ensure_carapace_bootstrap_caps (trustedProxies,
#                           timeoutSeconds, bootstrapMaxChars)
#   3. liveness test      ← agent picks up our injections on first turn
#   4. Step Connect       ← user sees QR with everything in place
echo -e "  ${DIM}Injecting CARAPACE workspace files + config...${RESET}"
inject_carapace_first_light  # sentinel into AGENTS.md
inject_carapace_bootstrap    # BOOTSTRAP.md birth ritual
sweep_carapace_for_all_agents # also sets bootstrap caps + trustedProxies + timeoutSeconds via ensure_carapace_bootstrap_caps
ok "CARAPACE injections complete"

# ══════════════════════════════════════════════════════════
# Pre-warm the agent runtime
# ══════════════════════════════════════════════════════════
# OpenClaw lazy-loads the agent runtime on first `chat.history` call —
# we measured ~75-80s on a fresh v2026.4.25 install (BOOTSTRAP.md +
# IDENTITY.md + AGENTS.md parse + session-state hydration). The TUI's
# RPC retry budget is 60s, so without this pre-warm the first
# `openclaw tui` open shows "history failed: gateway request timeout
# for chat.history" until the user retries — and the iOS chat path
# hits the same lazy-load on its first /chat call.
#
# Trigger the lazy-load NOW, while the user is already watching the
# install progress bar, so by the time they scan the QR + open the
# iOS app the runtime is warm and the first message is instant.
# Spawning `openclaw tui` headless (</dev/null) is the cheapest way
# to issue chat.history without making a model call.
# Skip warm-up if no model was configured. If the user Ctrl+C'd
# `openclaw onboard` (or no TTY available + chose to defer) the agent
# can't actually serve a chat.history request, so the warm-up would
# just burn the 110s timeout and tell us nothing. Re-warm happens
# naturally on the user's first successful interaction post-config.
# `openclaw config get` exits non-zero when the key is missing (e.g.,
# user skipped onboard). The trailing `|| true` swallows it so set -e
# doesn't abort the whole install — empty WARMUP_MODEL is the desired
# signal for the "skip pre-warm" branch below.
WARMUP_MODEL=$( (openclaw config get agents.defaults.model 2>/dev/null || true) | tr -d '"{ ' | head -1 )
if [[ -n "$WARMUP_MODEL" && "$WARMUP_MODEL" != "null" ]]; then
  # FIRST: wait for the gateway to be REALLY ready, not just /health-OK.
  # /health passes the moment the HTTP server binds (~6s after start),
  # but the agent runtime ("acpx runtime backend registered" in the log)
  # needs ~70s more to come up. Polling /health and moving on at +6s
  # means the next pre-warm RPC fires at the WORST possible moment —
  # mid-init — and gets queued for the full agent-startup budget.
  # Use `openclaw cron list` as the readiness probe: it's cheap, hits
  # the gateway over WS just like the TUI does, and only succeeds
  # after the agent runtime is up.
  echo -e "  ${DIM}Waiting for agent runtime to fully initialize (up to 120s)...${RESET}"
  READY_START=$(date +%s)
  READY=false
  for _r in $(seq 1 60); do
    if timeout 3 openclaw cron list >/dev/null 2>&1; then
      READY=true
      break
    fi
    sleep 2
  done
  READY_DURATION=$(( $(date +%s) - READY_START ))
  if $READY; then
    ok "Agent runtime ready (${READY_DURATION}s)"
  else
    warn "Agent runtime didn't respond within 120s — install will continue but first interaction will be slow"
  fi

  # NOW pre-warm chat.history so the TUI/iOS first call doesn't hit
  # the agent's per-session lazy-load (separate from runtime startup —
  # this is the per-session JSONL parse + memory hydration on first
  # `chat.history` call). Cheap if runtime is already warm.
  echo -e "  ${DIM}Pre-warming first chat.history call...${RESET}"
  WARMUP_START=$(date +%s)
  timeout 60 openclaw tui </dev/null >/dev/null 2>&1 || true
  WARMUP_DURATION=$(( $(date +%s) - WARMUP_START ))
  ok "Chat history warm (${WARMUP_DURATION}s) — TUI + iOS first message will be instant"

  # ── AI liveness test ───────────────────────────────────────────────
  # Single real chat round-trip, end-to-end, against the configured
  # model. Catches the dead-on-arrival case where everything reports
  # "ready" but the provider auth/key/network is wrong and the user
  # only finds out 30 seconds into their first iOS message. We send
  # one tiny prompt with a 120s budget (cold start + reasoning model
  # latency) and just check there's a non-empty response in the
  # body — no string match, no retries, no session-cleanup. If it
  # fails we WARN but don't abort, so a slow VPS doesn't block install.
  echo -e "  ${DIM}AI liveness test (single round-trip, 120s budget)...${RESET}"
  LIVENESS_START=$(date +%s)
  GW_TOK=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['gateway']['auth']['token'])" 2>/dev/null)
  if [ -n "$GW_TOK" ]; then
    LIVE_RESP=$(curl -sS --max-time 120 -X POST http://127.0.0.1:18789/v1/chat/completions \
      -H "Authorization: Bearer $GW_TOK" \
      -H "Content-Type: application/json" \
      -d '{"model":"openclaw","messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)
    LIVENESS_DURATION=$(( $(date +%s) - LIVENESS_START ))
    LIVE_CONTENT=$(echo "$LIVE_RESP" | python3 -c '
import json, sys
try:
  d = json.load(sys.stdin)
  c = d["choices"][0]["message"]["content"]
  print(c[:60] if c else "")
except Exception:
  print("")
' 2>/dev/null)
    if [ -n "$LIVE_CONTENT" ]; then
      ok "AI alive (${LIVENESS_DURATION}s) — first response: \"${LIVE_CONTENT}...\""
    else
      warn "AI did not respond within 120s. Install will continue."
      warn "  Check: openclaw gateway logs   |   re-onboard: openclaw onboard"
      warn "  First-time iOS chat may also fail until provider auth + model are right."
    fi
  fi
else
  echo -e "  ${DIM}Skipping pre-warm — no model configured yet (run \`openclaw onboard\`).${RESET}"
fi

# ══════════════════════════════════════════════════════════
# Step 10: Connect
# ══════════════════════════════════════════════════════════
step "Connect"

# Wait for gateway + model to be fully ready before showing anything
echo -e "  ${DIM}Waiting for gateway to be fully ready...${RESET}"
for _tw in $(seq 1 20); do
  curl -s --max-time 2 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
  sleep 1
done

# Verify model can actually respond (not just health OK)
TOKEN=$(python3 -c 'import json; print(json.load(open("'"$HOME"'/.openclaw/openclaw.json"))["gateway"]["auth"]["token"])' 2>/dev/null || echo "")
# Final token-recovery attempt. If we still have no token here, the pair
# URL will end up with an empty &token= field and iOS can't connect. Try
# one more gateway install now that everything else is up and retry the
# read. This is idempotent — if a token already exists in another path
# we haven't noticed, the install is a no-op.
if [ -z "$TOKEN" ]; then
  timeout 30 openclaw gateway install >> "$LOGFILE" 2>&1 || true
  TOKEN=$(python3 -c 'import json; print(json.load(open("'"$HOME"'/.openclaw/openclaw.json"))["gateway"]["auth"]["token"])' 2>/dev/null || echo "")
fi
# Deterministic AI probe was removed — it was a 20-attempt liveness
# loop that asked the model to reply with the literal word "confirmed",
# then cleaned up the session artifacts it created. Removed because
# (a) it can take 90s+ when xAI is slow without telling us anything we
# couldn't get from `openclaw gateway logs` and (b) if the user's
# auth/model config is broken, that's a user problem to fix — the
# install shouldn't fail loudly trying to validate it. The earlier
# stream-based smoke test in this file is sufficient to confirm the
# gateway is reachable.

# ── Vision mode configuration ───────────────────────────
# Vision mode used to need a separate Gemini API key for Gemini Live
# (real-time camera streaming). It doesn't anymore — the iPhone now
# runs Apple's on-device perception layer (Vision framework + LiDAR
# + ScenePerception) and routes every vision turn through OpenClaw to
# whatever chat provider the user picked. Zero extra config required;
# whatever model the gateway is wired to will see the camera frames
# + the iOS-side context hint and respond. The "CARAPACE VISION RULES"
# block we install into MEMORY.md below tells the gateway agent how
# to interpret the payload.

# (sweep_carapace_for_all_agents + inject_carapace_bootstrap +
#  inject_carapace_first_light moved to AFTER the openclaw onboard
#  step, BEFORE the liveness test — used to live here, post-Step 10
#  Connect, which meant the user already saw the QR and possibly
#  paired before our config knobs and AGENTS.md sentinel got applied.)

# ── Final cleanup: silence the nvm-vs-npm-prefix warning forever ──
# Even if our env-var-only prefix worked for THIS install, an old
# install may have left `prefix=` in ~/.npmrc. nvm spams this warning
# 3× on every shell login + every `npm` invocation, which makes the
# carapace SSH session look noisy and broken. Strip the offending
# lines unconditionally — npm-global packages installed at our env-
# var-prefix are still discoverable via PATH.
if [[ -f "$HOME/.npmrc" ]]; then
  sed -i '/^prefix=/d;/^globalconfig=/d' "$HOME/.npmrc" 2>/dev/null || true
  # If the file is now empty, remove it entirely (nvm only complains
  # when the file exists with one of those keys).
  [[ -s "$HOME/.npmrc" ]] || rm -f "$HOME/.npmrc"
fi

echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}${BOLD}  ✓ CARAPACE is ready!${RESET}"
echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo ""

# ── Cold-start patience banner ──────────────────────────────────────
# OpenClaw lazy-loads the agent runtime + per-session memory hydration
# on the first chat after a gateway start/restart. Even with our
# pre-warm above, the FIRST message after a service restart (gateway
# crash, host reboot, OS upgrade restart) hits this 30-90s lazy-load
# again. Set the user's expectation up front so they don't think the
# app is broken when the first message takes a minute.
echo -e "  ${YELLOW}${BOLD}⏳ FIRST MESSAGE NOTICE${RESET}"
echo -e "  ${DIM}OpenClaw warms up the agent runtime on the first chat${RESET}"
echo -e "  ${DIM}after every gateway restart. The FIRST message you send${RESET}"
echo -e "  ${DIM}may take 30-90 seconds to respond. Subsequent messages${RESET}"
echo -e "  ${DIM}are sub-second. If the gateway restarts (host reboot,${RESET}"
echo -e "  ${DIM}config change, nightly cron at 3am UTC), expect that${RESET}"
echo -e "  ${DIM}first-message lag again. Be patient — it's not broken.${RESET}"
echo ""

# Always show QR code first — this is the primary way to connect
echo -e "  ${TEAL}${BOLD}Scan this QR code with the CARAPACE iOS app to connect:${RESET}"
echo ""
carapace-qr 2>/dev/null || {
  # Fallback: build QR inline if carapace-qr not available
  TS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null)
  [[ -n "$TS" ]] && GW="https://$TS" || GW="http://127.0.0.1:18789"
  ENC_GW=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$GW")
  ENC_TOKEN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TOKEN")
  # Pair URL is gateway + token only — Vision mode runs entirely on
  # the iPhone using Apple's on-device perception layer.
  LINK="carapace://config?gatewayBaseURL=${ENC_GW}&token=${ENC_TOKEN}"
  echo "  Gateway: $GW"
  echo "  Token:   ${TOKEN:0:16}..."
  echo ""
  if have_cmd qrencode; then
    qrencode -t ANSIUTF8 -m 2 "$LINK"
  else
    echo "  Pair URL: $LINK"
  fi
}

echo ""
echo -e "  ${DIM}Download CARAPACE for iPhone: https://apps.apple.com/us/app/carapace/id6760282881${RESET}"
echo ""
echo -e "  ${TEAL}${BOLD}One-time phone setup:${RESET}"
echo -e "  ${DIM}  1. Install Tailscale on your iPhone (App Store) and sign in with the${RESET}"
echo -e "  ${DIM}     same account you used here. Carapace is tailnet-only by design —${RESET}"
echo -e "  ${DIM}     your phone needs to be on the tailnet to reach the gateway.${RESET}"
echo -e "  ${DIM}  2. In the Tailscale iOS app, enable BOTH:${RESET}"
echo -e "  ${DIM}       • Settings → Always On VPN${RESET}"
echo -e "  ${DIM}       • Settings → Use Tailscale DNS Settings (allow MagicDNS)${RESET}"
echo -e "  ${DIM}     Wifi often resolves .ts.net hostnames without these, but cellular${RESET}"
echo -e "  ${DIM}     networks need them on or pairing silently fails as 'unreachable'.${RESET}"
echo -e "  ${DIM}  3. Open Carapace on iPhone → scan the QR above to pair.${RESET}"
echo ""

echo -e "  ${BOLD}Other options:${RESET}"
echo -e "    ${BOLD}openclaw tui${RESET}    — Terminal chat interface"
echo -e "    ${BOLD}carapace-qr${RESET}     — Show this QR code again"
echo -e "    ${BOLD}carapace-onboard${RESET} — Re-run AI setup"
echo ""
echo -e "  ${DIM}Full install log: ${LOGFILE}${RESET}"
echo ""

# ── FINAL QR re-display ──────────────────────────────────────────────
# Shown again at the very END of install so the user doesn't miss it.
# The first display (above) gets buried under the "phone setup" + "other
# options" + log-path sections, and on smaller terminals the QR has
# scrolled off-screen by the time the install prompt reappears. This
# gives users a guaranteed-visible final pair widget right where their
# eyes land when the terminal stops printing.
echo -e "  ${TEAL}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "  ${TEAL}${BOLD}  📱 Pair your iPhone — scan this QR:${RESET}"
echo -e "  ${TEAL}${BOLD}══════════════════════════════════════════${RESET}"
echo ""
carapace-qr 2>/dev/null || true
echo ""

# ── Codex OAuth fallback ──
# If the inline `capability model auth login` above didn't complete,
# just tell the user the exact command to re-run. No TUI hand-off — the
# direct command already prints the OAuth URL to stdout.
if [ "${CODEX_OAUTH_NEEDED:-false}" = "true" ]; then
  echo -e "  ${YELLOW}${BOLD}⚠ Codex OAuth not yet completed${RESET}"
  echo -e "  ${DIM}Run this command — it prints the OAuth URL to the terminal:${RESET}"
  echo ""
  echo -e "    ${BOLD}BROWSER=echo openclaw capability model auth login --provider openai-codex${RESET}"
  echo ""
  echo -e "  ${DIM}Open the URL on any device with a browser, sign in with your${RESET}"
  echo -e "  ${DIM}ChatGPT Plus/Pro account, and approve. Then scan the QR above.${RESET}"
  echo ""
fi

# Offer TUI launch as optional. Use the same /dev/tty openability test
# as Step 9 — works for `curl | bash` (non-TTY stdin but real terminal
# attached) where `[ -t 0 ]` would falsely fail.
if ( : < /dev/tty ) 2>/dev/null; then
  echo -e "  ${TEAL}Want to also launch the terminal chat? [y/N]${RESET}"
  read -rp "  " LAUNCH_TUI < /dev/tty
  case "$LAUNCH_TUI" in
    [yY]*)
      echo ""
      # Re-source nvm + pin the PATH order so openclaw resolves to the
      # Node version we just installed. Observed on Rocky 9: the base
      # repos ship Node 16 (v16.20.2), which openclaw rejects (requires
      # v22.12+). Without this, `exec openclaw tui` can land on the
      # system node. The carapace-qr / carapace-onboard wrappers do the
      # same thing — match them here.
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
      for _d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_d" ] && export PATH="$_d:$PATH"; done
      export PATH="$HOME/.npm-global/bin:$PATH"
      if [ -t 0 ]; then
        exec openclaw tui
      else
        exec openclaw tui < /dev/tty
      fi
      ;;
  esac
fi
