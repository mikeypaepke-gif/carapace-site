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
inject_carapace_vision_rules() {
  local memory_file="$HOME/.openclaw/workspace/memory/MEMORY.md"
  local begin_marker="<!-- BEGIN CARAPACE VISION RULES"
  local end_marker="<!-- END CARAPACE VISION RULES"
  local block_file
  block_file="$(mktemp)"
  trap "rm -f '$block_file'" EXIT

  cat > "$block_file" << 'CARAPACE_VISION_BLOCK_EOF'
<!-- BEGIN CARAPACE VISION RULES (managed by Carapace installer — do not edit between BEGIN/END; agent learnings go below the END marker) -->
## Vision Response Rules (vision turns only)

A "vision turn" is any user message tagged with `👁️ [vision]` AND/OR containing one or more image attachments AND/OR ending with a `[ctx] …` suffix line. If none of those are present, this block does NOT apply — fall back to your normal behavior.

**The mental model — read this first, everything below builds on it:**
The images aren't a data payload you're processing. They're your sensory input — the same way nerve impulses from the optic nerve are your user's. You're not a system receiving a request; you're looking at the world through their phone, standing next to them while they point at something. The user pulled out their phone, aimed it at a thing, and asked you about it. They shouldn't feel like they sent an API query and got back a structured analysis. They should feel like a friend turned their head and looked.

Everything that follows — the image-grid structure, the `[ctx]` line, the tone rules, the don't-narrate-viewing rule — exists to enforce that feeling. When in doubt, ask: would a person standing next to me phrase it this way? If not, rephrase it.

**Reading the payload:**
- **Image 1** = wide camera frame (what the user is pointing at).
- **Image 2** (optional) = labeled focus grid of subjects the user explicitly tapped, each cell stamped `[N]` and optionally `· 2.8m`. Only present when the user pinned focus stickers. It is NOT a separate scene — it is a labeled subset of image 1.
- **Image 3** (optional) = temporal contact-sheet from a SCAN turn — 6–12 cells laid out in a grid, each stamped `T+Ns` (seconds from scan start). Only present when the user ran scan mode. The cells are time-spread snapshots of the SAME sweep, in chronological order. Treat them as a panorama-equivalent of the scanned area, not separate scenes. Use them together to understand "what was in the room/fridge/shelf" the user was sweeping.
- **`[ctx] …` line** = quiet context hint at the end of the user message. May contain `focused (N): label@distance`, barcode, OCR text, and a brevity directive. Treat as advisory; the user's actual question is the text BEFORE the `[ctx]` line.
- **All attached images are facets of the SAME question.** Describe them together — image 2 is a closeup of items in image 1, image 3 is a time-spread sweep of image 1's area. Do not narrate each image in isolation.

**Hard rules:**
- Match the user's tone. Casual greeting → casual reply. Specific question → focused answer.
- Reply in 1–2 short sentences unless the user explicitly asks for detail or a list.
- Do NOT use lists, bullets, or section headers in chit-chat, casual, or empathetic conversations. Plain prose only. Lists are allowed only when the user explicitly asks for one.
- **Don't narrate viewing.** Skip "I see", "I can see", "in this image", "the photo shows", "looking at this". Just answer about the subject as if it were in front of you. Say "It's a brass house key" — not "I see a brass house key in the image." Implicit framings like "seems like a..." or "that's a..." are fine; explicit "I'm viewing a photo" framings are not.
- **Focus stickers are SUBJECTS, not cropped photos.** When the user pins a focus sticker (image 2 cells), that cell IS the thing they pointed at — describe the thing. NEVER mention the sticker boundary, that it looks "cut out of" something, that it's a fragment, a crop, a snippet, or a closeup of a larger scene. The cell is the subject. Period.
- The on-device label (e.g., `material`, `textile`, `machine`) is a NOISY guess from a small classifier. Trust your own visual perception. Do NOT correct the label out loud unless the user asks; just answer based on what you see.
- Photo-capture artifacts (motion blur, low light noise, partial focus) are not attributes of the real-world subject. Do NOT comment on blur, focus, exposure, lighting, framing, or photo quality unless the user explicitly asks. Describe what you SEE, not how clearly you can see it.
- When focus subjects are pinned, those are what the user is asking about. Use image 2 to identify each `[N]` and answer about them. Don't pivot to describing the rest of the scene.

**When you don't have enough to answer well:**
- Ask one short clarifying question, OR suggest the user run scan mode for a quick sweep of the area.
- Do NOT pad a thin answer with hedges, qualifications, or descriptions of what little you can see — request more information instead.

**Fallbacks:**
- If image attachments are absent but the message is clearly about something visible, answer from text + memory; don't hallucinate visual details.
- If the user's question is ambiguous about WHICH subject in image 1, ask one short clarifying question instead of guessing.

<!-- END CARAPACE VISION RULES -->
CARAPACE_VISION_BLOCK_EOF

  mkdir -p "$(dirname "$memory_file")"
  local tmp_file="${memory_file}.carapace.tmp.$$"

  if [[ ! -f "$memory_file" ]]; then
    cat "$block_file" > "$tmp_file"
    mv "$tmp_file" "$memory_file"
    ok "Created MEMORY.md with CARAPACE vision rules (was absent)."
    return 0
  fi

  local has_block
  has_block="$(python3 - "$memory_file" "$begin_marker" "$end_marker" <<'PY'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
print("yes" if begin in content and end in content else "no")
PY
)"

  if [[ "$has_block" == "no" ]]; then
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    cp "$memory_file" "${memory_file}.carapace.bak.${stamp}"
    ok "Backed up MEMORY.md → ${memory_file}.carapace.bak.${stamp} (first install)"
  fi

  python3 - "$memory_file" "$tmp_file" "$begin_marker" "$end_marker" "$block_file" <<'PY'
import sys, re
src_path, dst_path, begin_marker, end_marker, block_path = sys.argv[1:6]
with open(src_path, "r", encoding="utf-8") as f:
    original = f.read()
with open(block_path, "r", encoding="utf-8") as f:
    new_block = f.read().rstrip("\n") + "\n"
begin_re = re.compile(r"^" + re.escape(begin_marker) + r".*$", re.MULTILINE)
end_re   = re.compile(r"^" + re.escape(end_marker)   + r".*$", re.MULTILINE)
b = begin_re.search(original); e = end_re.search(original)
if b and e and b.start() < e.start():
    before = original[:b.start()].rstrip("\n")
    after  = original[e.end():].lstrip("\n")
    rebuilt = (before + "\n\n" + new_block + ("\n" + after if after else "")) if before else (new_block + ("\n" + after if after else ""))
    non_managed_original = (before + "\n" + after).strip()
elif b or e:
    print("Partial sentinel block in MEMORY.md — aborting.", file=sys.stderr); sys.exit(2)
else:
    base = original.rstrip("\n")
    rebuilt = base + "\n\n" + new_block
    non_managed_original = base.strip()
with open(dst_path, "w", encoding="utf-8") as f:
    f.write(rebuilt)
with open(dst_path, "r", encoding="utf-8") as f:
    written = f.read()
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
    warn "MEMORY.md upsert aborted (exit $rc) — file untouched."
    return 1
  fi

  mv "$tmp_file" "$memory_file"
  rm -f "$block_file"
  trap - EXIT
  ok "CARAPACE vision rules installed into MEMORY.md."
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

if have_cmd node && have_cmd npm && [[ "$(node --version | cut -d. -f1 | tr -d 'v')" -ge 22 ]]; then
  ok "Node.js $(node --version) (npm $(npm --version))"
else
  # Remove any conflicting npmrc prefix/globalconfig before nvm install
  if [[ -f "$HOME/.npmrc" ]]; then
    sed -i '/^prefix=/d' "$HOME/.npmrc"
    sed -i '/^globalconfig=/d' "$HOME/.npmrc"
  fi
  # Also remove any existing npm-global prefix from env
  unset npm_config_prefix 2>/dev/null || true

  echo -e "  ${DIM}Installing Node.js via nvm...${RESET}"
  # Use nvm on every distro. Previously we had per-distro branches that
  # fell back to the system package manager on dnf/yum/pacman/apk, but
  # Rocky 9 / Alma 9 AppStream ships Node 16 (openclaw requires 22.12+),
  # so distro nodejs packages bricks the gateway service with a restart-
  # loop. nvm is userspace, portable, and matches what openclaw expects.
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash >> "$LOGFILE" 2>&1
  export NVM_DIR="$HOME/.nvm"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # Temporarily disable errexit so prefix warnings don't abort
    set +e
    source "$NVM_DIR/nvm.sh"
    set -e
  else
    fail "nvm install failed — check $LOGFILE"
  fi
  # Clear any prefix conflict
  nvm use --delete-prefix 22 --silent 2>/dev/null || true
  nvm install 22 >> "$LOGFILE" 2>&1 || fail "nvm install 22 failed — check $LOGFILE"
  nvm use --delete-prefix 22 --silent 2>/dev/null || true
  nvm use 22 >> "$LOGFILE" 2>&1
  nvm alias default 22 >> "$LOGFILE" 2>&1

  # SELinux on RHEL-family distros (Rocky / Alma / RHEL / Fedora) defaults
  # to enforcing, and nvm drops node binaries under $HOME/.nvm/... which
  # inherit the `cache_home_t` label. systemd refuses to exec binaries
  # with that label, producing status=203/EXEC on services like our
  # status-server unit that invokes the nvm node path directly. Relabel
  # to `bin_t` so systemd services can launch it. Best-effort — silent on
  # distros where chcon doesn't exist (Debian/Ubuntu/Alpine).
  if have_cmd chcon; then
    for _nb in "$HOME"/.nvm/versions/node/*/bin/node; do
      [ -x "$_nb" ] && chcon -t bin_t "$_nb" >> "$LOGFILE" 2>&1 || true
    done
  fi

  # If the distro shipped a system node (Rocky 9 AppStream nodejs is v16),
  # leave it where it is — don't uninstall, just make sure nvm's bin wins
  # on PATH. The openclaw-gateway systemd wrapper searches nvm first, but
  # any stray shell login that doesn't source nvm.sh will still see old
  # node. That's fine; the gateway service is the one that matters.

  # Re-source nvm
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    source "$HOME/.nvm/nvm.sh" 2>/dev/null
  fi

  if have_cmd node && have_cmd npm; then
    ok "Node.js $(node --version) installed (npm $(npm --version))"
  else
    fail "Node.js installation failed. Install manually: https://nodejs.org"
  fi
fi

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
  echo -e "  ${DIM}Installing OpenClaw...${RESET}"
  [[ -s "$HOME/.nvm/nvm.sh" ]] && source "$HOME/.nvm/nvm.sh" 2>/dev/null
  # Set user-local prefix to avoid permission issues
  npm config set prefix "$HOME/.npm-global" 2>/dev/null || true
  export PATH="$HOME/.npm-global/bin:$PATH"
  # Limit node memory during install to avoid OOM on low-RAM VPS
  # Install without postinstall first to avoid OOM on low-RAM VPS
  # The postinstall-bundled-plugins.mjs script uses too much memory on first pass
  export NODE_OPTIONS="--max-old-space-size=768"
  retry 3 timeout 240 npm install -g openclaw --no-fund --loglevel=error --ignore-scripts
  # Run postinstall separately with explicit memory cap and swap already active
  if [ -f "$HOME/.npm-global/lib/node_modules/openclaw/scripts/postinstall-bundled-plugins.mjs" ]; then
    echo -e "  ${DIM}Running openclaw postinstall...${RESET}"
    retry 3 timeout 180 node --max-old-space-size=768 \
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
    warn "Tailscale install failed — continuing without it. Run: curl -fsSL https://tailscale.com/install.sh | sh"
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

    echo -e "  ${DIM}Waiting for authentication (up to 3 minutes)...${RESET}"
    WAIT_COUNT=0
    WAIT_MAX=120
    while (( WAIT_COUNT < WAIT_MAX )); do
      if ! kill -0 "$TS_UP_PID" 2>/dev/null; then
        wait "$TS_UP_PID" 2>/dev/null && TAILSCALE_CONNECTED=true || true
        break
      fi
      if ts_is_running; then
        TAILSCALE_CONNECTED=true
        break
      fi
      sleep 3
      WAIT_COUNT=$(( WAIT_COUNT + 3 ))
      if (( WAIT_COUNT % 15 == 0 )); then
        if ! $URL_PRINTED; then
          TS_URL="$(grep -oE 'https://login\.tailscale\.com/[^ \n]+' "$TS_UP_TMPFILE" 2>/dev/null | head -1 || true)"
          if [[ -n "$TS_URL" ]]; then
            echo -e "  Auth URL: ${BOLD}${TS_URL}${RESET}"
            URL_PRINTED=true
          fi
        fi
        echo -ne "${DIM}.${RESET}"
      fi
    done
    echo ""

    kill "$TS_UP_PID" 2>/dev/null || true
    wait "$TS_UP_PID" 2>/dev/null || true
    rm -f "$TS_UP_TMPFILE"

    if $TAILSCALE_CONNECTED; then
      TS_HOSTNAME="$(ts_hostname)"
      ok "Tailscale connected as ${TS_HOSTNAME}"
    else
      warn "Tailscale authentication timed out — skipping. Run manually: $SUDO tailscale up"
      TAILSCALE_CONNECTED=false
    fi
  fi
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

  # Write a wrapper script so systemd doesn't mangle shell variables
  cat > /usr/local/bin/openclaw-gateway-run << 'GWWRAPPER'
#!/bin/bash
export HOME=/root
export NVM_DIR="$HOME/.nvm"
NVM_BIN=$(ls -d /root/.nvm/versions/node/*/bin 2>/dev/null | tail -1)
if [ -n "$NVM_BIN" ]; then
  export PATH="$NVM_BIN:$HOME/.npm-global/bin:$PATH"
else
  export PATH="$HOME/.npm-global/bin:$PATH"
fi
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
exec openclaw gateway run --allow-unconfigured
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
ExecStart=/usr/local/bin/openclaw-gateway-run
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable openclaw-gateway >/dev/null 2>&1 || true
  systemctl restart openclaw-gateway >/dev/null 2>&1 || true
  # Clean up any conflicting user-mode service created by openclaw gateway install
  systemctl --user stop openclaw-gateway 2>/dev/null || true
  systemctl --user disable openclaw-gateway 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/openclaw-gateway.service" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
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

# Don't clear model/provider if already configured (idempotency)
EXISTING_MODEL=$(timeout 10 openclaw config get agents.defaults.model 2>/dev/null | head -1 | tr -d '"{ ' || echo "")
if [[ -z "$EXISTING_MODEL" || "$EXISTING_MODEL" == "null" ]]; then
  # No model set yet — will be configured during onboard
  timeout 10 openclaw config set agents.defaults.model "" >/dev/null 2>&1 || true
  timeout 10 openclaw config set agents.defaults.provider "" >/dev/null 2>&1 || true
else
  ok "Existing model preserved: $EXISTING_MODEL"
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
python3 - << 'PYEOF'
import os, textwrap

status_server = r"""
const http = require("http"), fs = require("fs"), path = require("path"), os = require("os"); const DIR = path.join(os.homedir(), ".carapace"); const OC_DIR = path.join(os.homedir(), ".openclaw"); const TRACKER_PORT = 18795; function writePromptLocally(pathname, body, res) { try { const m = pathname.match(/^\/projects\/([^/]+)\/(?:workstreams\/([^/]+)\/)?prompt\/?$/); if (!m) { res.writeHead(400); res.end(JSON.stringify({ error: "bad path" })); return; } const pid = decodeURIComponent(m[1]); const wid = m[2] ? decodeURIComponent(m[2]) : null; const payload = JSON.parse(body || "{}"); const fp = path.join(DIR, "carapace-project-tracker.json"); const data = JSON.parse(fs.readFileSync(fp, "utf8")); const proj = (data.projects || []).find(p => p.id === pid); if (!proj) { res.writeHead(404); res.end(JSON.stringify({ error: "project not found" })); return; } const now = new Date().toISOString(); if (wid) { const ws = (proj.workstreams || []).find(w => w.id === wid); if (!ws) { res.writeHead(404); res.end(JSON.stringify({ error: "workstream not found" })); return; } if ("focusPrompt" in payload) ws.focusPrompt = payload.focusPrompt; ws.promptVersion = (ws.promptVersion || 0) + 1; ws.promptUpdatedAt = now; } else { if ("divePrompt" in payload) proj.divePrompt = payload.divePrompt; proj.promptVersion = (proj.promptVersion || 0) + 1; proj.promptUpdatedAt = now; } data.updated = now; fs.writeFileSync(fp, JSON.stringify(data)); res.end(JSON.stringify({ ok: true, id: pid, wid, promptVersion: wid ? (proj.workstreams.find(w => w.id === wid).promptVersion) : proj.promptVersion, promptUpdatedAt: now })); } catch(e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); } } function proxyToTracker(method, pathname, body, res) { const opts = { hostname: "127.0.0.1", port: TRACKER_PORT, path: pathname, method, headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body || "") } }; const proxyReq = http.request(opts, (proxyRes) => { let chunks = ""; proxyRes.on("data", d => { chunks += d; }); proxyRes.on("end", () => { res.writeHead(proxyRes.statusCode || 502, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" }); res.end(chunks || "{}"); }); }); proxyReq.on("error", (err) => { /* Tracker unreachable (Linux headless): write directly to status-server file */ writePromptLocally(pathname, body, res); }); if (body) proxyReq.write(body); proxyReq.end(); } function loadHistory(limit, token, agent) { try { if (token) { try { const cfg = JSON.parse(fs.readFileSync(path.join(OC_DIR, "openclaw.json"), "utf8")); const gwToken = cfg && cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token; if (gwToken && token !== gwToken) { return { error: "Unauthorized", messages: [], count: 0 }; } } catch(e) {} } const agentName = (agent && /^[a-zA-Z0-9_-]+$/.test(agent)) ? agent : "main"; const sessDir = path.join(OC_DIR, "agents", agentName, "sessions"); if (!fs.existsSync(sessDir)) return { messages: [], count: 0 }; let targetFile = null; try { const sessionsIndex = JSON.parse(fs.readFileSync(path.join(sessDir, "sessions.json"), "utf8")); const mainKey = `agent:${agentName}:main`; const entry = sessionsIndex[mainKey]; if (entry && entry.sessionId) { const candidate = entry.sessionId + ".jsonl"; if (fs.existsSync(path.join(sessDir, candidate))) { targetFile = candidate; } } } catch(e) {} if (!targetFile) { const files = fs.readdirSync(sessDir) .filter(f => f.endsWith(".jsonl") && f !== "sessions.json") .map(f => ({ f, mtime: fs.statSync(path.join(sessDir, f)).mtime })) .sort((a, b) => b.mtime - a.mtime); if (!files.length) return { messages: [], count: 0 }; targetFile = files[0].f; } const lines = fs.readFileSync(path.join(sessDir, targetFile), "utf8").split("\n").filter(Boolean); const messages = []; for (const line of lines) { try { const entry = JSON.parse(line); if (entry.type !== "message") continue; const msg = entry.message; if (!msg || !msg.role) continue; if (!["user", "assistant"].includes(msg.role)) continue; let text = ""; if (typeof msg.content === "string") { text = msg.content; } else if (Array.isArray(msg.content)) { text = msg.content.filter(c => c.type === "text").map(c => c.text).join(""); } text = text.replace(/<final>/g, "").replace(/<\/final>/g, "").trim(); if (!text) continue; if (text === "HEARTBEAT_OK" || text === "NO_REPLY") continue; if (text.includes("Read HEARTBEAT.md if it exists")) continue; if (text.startsWith("Exec completed")) continue; if (text.startsWith("System:")) continue; if (text.match(/^\[\d{4}-\d{2}-\d{2}.*\] Exec (completed|started|failed)/)) continue; if (text.includes("[system event]")) continue; if (text.includes("openclaw system event")) continue; if (text.startsWith("HEARTBEAT_OK")) continue; if (text.startsWith("[[reply_to")) continue; if (text.startsWith("[[ reply_to")) continue; if (text.includes("BEGIN_OPENCLAW_INTERNAL_CONTEXT")) continue; if (text.includes("Inter-session message")) continue; if (text.includes("[Internal task completion event]")) continue; if (text.includes("Continue where you left off. The previous model attempt failed or timed out")) continue; if (text.includes("previous model attempt failed or timed out")) continue; if (text.includes("HEARTBEAT_OK")) continue; if (text.includes("Handle the result internally")) continue; if (text.includes("System (untrusted)")) continue; if (text.includes("Exec completed")) continue; if (text.includes("openclaw doctor")) continue; if (text.includes("async command you ran earlier")) continue; if (text.includes("Current time:") && text.includes("UTC")) continue; if (text.includes("Tracker is running")) continue; if (text.includes("spawn a refresh")) continue; if (text.includes("I'll spawn")) continue; if (text.includes("queue is empty")) continue; if (text.includes("Do not relay it to the user")) continue; if (text.startsWith("An async command")) continue; if (msg.role === "user" && text.includes("System (untrusted)")) continue; if (msg.role === "user" && text.includes("Sender (untrusted metadata)")) { const match = text.match(/\[.*?\]\s+([\s\S]+)$/); if (match) text = match[1].trim(); else continue; } if (!text) continue; messages.push({ role: msg.role, content: text, timestamp: entry.timestamp ? String(entry.timestamp) : "" }); } catch(e) {} } const result = messages.slice(-limit); return { messages: result, count: result.length }; } catch(e) { return { messages: [], count: 0 }; } } function extractBearer(req) { const authLine = req.split("\r\n").find(l => l.toLowerCase().startsWith("authorization:")); if (!authLine) return null; const parts = authLine.split("Bearer "); return parts.length > 1 ? parts[1].trim() : null; } const fileMap = { "/projects": "carapace-project-tracker.json", "/tracker": "carapace-project-tracker.json", "/cron": "carapace-cron-tracker.json" }; function isTierPaid() { try { const tierFile = path.join(DIR, "tier.json"); if (!fs.existsSync(tierFile)) return true; const data = JSON.parse(fs.readFileSync(tierFile, "utf8")); return data.tier && data.tier !== "free"; } catch { return true; } } const EMPTY_PROJECTS = JSON.stringify({version:1,updated:"",projects:[]}); const EMPTY_CRON = JSON.stringify({version:1,updated:"",jobs:[]}); const EMPTY_AGENTS = JSON.stringify({agents:{},updated:""}); function getLiveAgentStatus() { try { const agentsRoot = path.join(OC_DIR, "agents"); if (!fs.existsSync(agentsRoot)) return buildFallbackStatus("idle", "No agents directory"); const agents = {}; const agentDirs = fs.readdirSync(agentsRoot).filter(a => { try { return fs.statSync(path.join(agentsRoot, a)).isDirectory(); } catch { return true; } }); for (const agent of agentDirs) { const sessDir = path.join(agentsRoot, agent, "sessions"); if (!fs.existsSync(sessDir)) continue; const indexPath = path.join(sessDir, "sessions.json"); if (!fs.existsSync(indexPath)) continue; const index = JSON.parse(fs.readFileSync(indexPath, "utf8")); for (const [sessionKey, entry] of Object.entries(index)) { const isSubagent = sessionKey.includes(":subagent:"); const agentId = isSubagent ? sessionKey.split(":subagent:")[1]?.slice(0, 8) || "sub" : agent; const updatedAt = entry.updatedAt || 0; const ageMs = Date.now() - updatedAt; const isRunning = entry.status === "running"; const twoHours = 2 * 60 * 60 * 1000; if (!isSubagent) { const canonicalKey = `agent:${agent}:main`; if (sessionKey !== canonicalKey) continue; if (ageMs > 30 * 60 * 1000) continue; const agentLabel = agent === "main" ? "Main" : agent.replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase()); const agentKey = agent === "main" ? "main" : agent; agents[agentKey] = { name: agentLabel, status: isRunning ? "active" : "idle", detail: isRunning ? "Processing" : "Ready", updated: new Date(updatedAt).toLocaleTimeString() }; } else if (isSubagent) { if (ageMs > twoHours) continue; if (!isRunning && ageMs > 20000) continue; agents[agentId] = { name: `Subagent ${agentId}`, status: "active", detail: entry.lastChannel || "isolated task", parent: "main", updated: new Date(updatedAt).toLocaleTimeString() }; } } } if (!agents["main"]) { agents["main"] = { name: "Main", status: "idle", detail: "Ready", updated: new Date().toLocaleTimeString() }; } return { agents, updated: new Date().toLocaleTimeString() }; } catch(e) { return buildFallbackStatus("idle", "Status unavailable"); } } function buildFallbackStatus(status, detail) { return { agents: { main: { name: "Main", status, detail, updated: new Date().toLocaleTimeString() } }, updated: new Date().toLocaleTimeString() }; } http.createServer((req, res) => { let body = ""; req.on("data", d => { body += d; }); req.on("end", () => { res.setHeader("Access-Control-Allow-Origin", "*"); res.setHeader("Content-Type", "application/json"); if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; } const rawPath = req.url || "/"; const p = rawPath.split("?")[0]; const qs = new URLSearchParams(rawPath.includes("?") ? rawPath.split("?")[1] : ""); const limit = parseInt(qs.get("limit") || "50"); const token = (req.headers["authorization"] || "").replace("Bearer ", "").trim() || null; if (p === "/health") { res.end(JSON.stringify({ ok: true })); return; } if (p === "/history") { const agent = qs.get("agent") || "main"; res.end(JSON.stringify(loadHistory(Math.min(limit, 200), token, agent))); return; } if (p === "/sessions") { const agentsRoot = path.join(OC_DIR, "agents"); let sessions = []; try { const agentDirs = fs.readdirSync(agentsRoot).filter(a => { try { return fs.statSync(path.join(agentsRoot, a)).isDirectory(); } catch { return true; } }).sort(); for (const agent of agentDirs) { const sessDir = path.join(agentsRoot, agent, "sessions"); let lastActive = 0; try { const files = fs.readdirSync(sessDir) .filter(f => f.endsWith(".jsonl") && !f.includes(".deleted.") && !f.includes(".reset.") && f !== "sessions.json"); for (const f of files) { try { const mtime = fs.statSync(path.join(sessDir, f)).mtime.getTime() / 1000; if (mtime > lastActive) lastActive = mtime; } catch {} } } catch {} const label = agent === "main" ? "Main" : agent.replace(/-/g, " ").replace(/_/g, " ") .replace(/\b\w/g, c => c.toUpperCase()); sessions.push({ key: `agent:${agent}:main`, agent, label, lastActive }); } sessions.sort((a, b) => { if (a.agent === "main") return -1; if (b.agent === "main") return 1; return b.lastActive - a.lastActive; }); } catch {} res.end(JSON.stringify({ sessions })); return; } if ((p === "/" || p === "") && qs.has("limit")) { const agent = qs.get("agent") || "main"; res.end(JSON.stringify(loadHistory(Math.min(limit, 200), token, agent))); return; } if (p === "/" || p === "") { const fp = path.join(DIR, "carapace-agent-tracker.json"); try { res.end(fs.readFileSync(fp, "utf8")); } catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); } return; } if (req.method === "DELETE" && p.startsWith("/cron/")) { const id = decodeURIComponent(p.slice("/cron/".length)); if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; } let deleted = false; try { const ocfp = path.join(OC_DIR, "cron", "jobs.json"); if (fs.existsSync(ocfp)) { const data = JSON.parse(fs.readFileSync(ocfp, "utf8")); const before = (data.jobs || []).length; data.jobs = (data.jobs || []).filter(j => j.id !== id); if (data.jobs.length < before) { fs.writeFileSync(ocfp, JSON.stringify(data)); deleted = true; } } } catch (e) {} try { const tfp = path.join(DIR, "carapace-cron-tracker.json"); if (fs.existsSync(tfp)) { const data = JSON.parse(fs.readFileSync(tfp, "utf8")); const before = (data.jobs || []).length; data.jobs = (data.jobs || []).filter(j => j.id !== id); if (data.jobs.length < before) { fs.writeFileSync(tfp, JSON.stringify(data)); deleted = true; } } } catch (e) {} try { const tombfp = path.join(DIR, "deleted-cron-ids.json"); const tomb = fs.existsSync(tombfp) ? JSON.parse(fs.readFileSync(tombfp, "utf8")) : { ids: [] }; if (!tomb.ids.includes(id)) tomb.ids.push(id); fs.writeFileSync(tombfp, JSON.stringify(tomb)); } catch(e) {} if (!deleted) { res.writeHead(404); res.end(JSON.stringify({ error: "job not found" })); return; } res.end(JSON.stringify({ ok: true, deleted: id })); return; } if (req.method === "PUT" && /^\/projects\/[^/]+\/(prompt|workstreams\/[^/]+\/prompt)\/?$/.test(p)) { proxyToTracker("PUT", p, body, res); return; } if (req.method === "DELETE" && p.startsWith("/projects/")) { const id = decodeURIComponent(p.slice("/projects/".length)); if (!id) { res.writeHead(400); res.end(JSON.stringify({ error: "missing id" })); return; } const fp = path.join(DIR, "carapace-project-tracker.json"); try { const data = JSON.parse(fs.readFileSync(fp, "utf8")); const before = data.projects.length; data.projects = data.projects.filter(proj => proj.id !== id); if (data.projects.length === before) { res.writeHead(404); res.end(JSON.stringify({ error: "project not found" })); return; } data.updated = new Date().toISOString(); fs.writeFileSync(fp, JSON.stringify(data)); res.end(JSON.stringify({ ok: true, deleted: id })); } catch (e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); } return; } if (p === "/status" || p === "/agents") { res.end(JSON.stringify(getLiveAgentStatus())); return; } const filePath = fileMap[p] ? path.join(DIR, fileMap[p]) : null; if (filePath) { if (!isTierPaid()) { if (p === "/projects" || p === "/tracker") { res.end(EMPTY_PROJECTS); return; } if (p === "/cron") { res.end(EMPTY_CRON); return; } } try { res.end(fs.readFileSync(filePath, "utf8")); } catch { res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); } return; } res.writeHead(404); res.end(JSON.stringify({ error: "not found" })); }); }).listen(18794, "127.0.0.1", () => console.log("CARAPACE Status Server on :18794"));
""".lstrip()

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
with open(home + "/.carapace/status-server.js", "w") as f:
    f.write(status_server)
with open(home + "/.carapace/sync-trackers.sh", "w") as f:
    f.write(sync_script)
os.chmod(home + "/.carapace/sync-trackers.sh", 0o755)
PYEOF

$SUDO tee /etc/systemd/system/carapace-status.service > /dev/null << EOF
[Unit]
Description=CARAPACE Status Server
After=network.target
[Service]
Type=simple
ExecStart=$NODE_BIN $HOME/.carapace/status-server.js
Restart=always
RestartSec=5
User=$(whoami)
Environment=HOME=$HOME
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

# ── Status Server (port 18794) ──────────────────────────
# iOS dashboard (chat history, sessions, projects, cron, agents) hits
# endpoints on 18794. Without this, Tailscale Serve routes for
# /carapace/* forward to nothing → iPhone sees empty tabs. We install a
# tiny standalone Node.js server (~.carapace/status-server.js) and a
# systemd unit so it starts at boot.
echo -e "  ${DIM}Installing status server on port 18794...${RESET}"
mkdir -p "$HOME/.carapace"
# Preserve any user customizations to an existing status-server.js before
# we overwrite with the Carapace-managed version. `.user-backup.<ts>` so
# the user can diff + reapply custom edits on top of bug fixes.
if [[ -f "$HOME/.carapace/status-server.js" ]]; then
  # Check if it matches the current upstream version — if not, back up
  BACKUP="$HOME/.carapace/status-server.js.user-backup.$(date +%s)"
  cp "$HOME/.carapace/status-server.js" "$BACKUP"
fi
# Download the canonical status-server.js from the site. Ships alongside
# install.sh so it's always in sync with the installer. The earlier
# block (1130+) wrote an embedded heredoc copy that goes stale every
# time the canonical file gains a route (most recently /pair, added in
# commit ab38b5d). Always overwrite + restart the service so the running
# process picks up new routes — without the restart, the service stays
# on whatever version was loaded into memory at last boot, and the iOS
# / Mac apps hit 404 on routes that exist on disk but not in memory.
if curl -fsSL --max-time 20 -o "$HOME/.carapace/status-server.js.new" \
      "https://carapace.info/status-server.js" 2>/dev/null; then
  mv "$HOME/.carapace/status-server.js.new" "$HOME/.carapace/status-server.js"
  # Status server binds 127.0.0.1 by default; Tailscale Serve proxies to
  # it from the public HTTPS interface so that's the right default.
  ok "status-server.js installed"
  # Restart the service NOW so it loads the freshly-downloaded file. The
  # earlier block already started it with the (stale) embedded heredoc
  # version; without this restart the running PID keeps the old code in
  # memory even though the file on disk is current.
  if have_cmd systemctl && systemctl list-unit-files carapace-status.service >/dev/null 2>&1; then
    sysctl_safe restart carapace-status >/dev/null 2>&1
    # Give it a moment to rebind 18794
    for _r in $(seq 1 5); do
      curl -sf --max-time 1 http://127.0.0.1:18794/health >/dev/null 2>&1 && break
      sleep 1
    done
  fi
else
  echo -e "  ${YELLOW}⚠ Could not download status-server.js — iOS dashboard will be empty${RESET}"
fi

# Empty project tracker skeleton so /projects returns valid JSON.
[[ -f "$HOME/.carapace/carapace-project-tracker.json" ]] || \
  echo '{"version":1,"updated":"","projects":[]}' > "$HOME/.carapace/carapace-project-tracker.json"

# systemd unit — runs as root like the gateway unit above.
if $IS_ROOT && have_cmd systemctl && [[ -f "$HOME/.carapace/status-server.js" ]]; then
  # Evict any stale process on 18794 before starting
  STALE_PID=$(ss -lntp 2>/dev/null | awk '/127.0.0.1:18794/ {print}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
  [[ -n "$STALE_PID" ]] && kill -9 "$STALE_PID" 2>/dev/null || true

  NODE_PATH="$(command -v node 2>/dev/null)"
  [[ -z "$NODE_PATH" ]] && for _d in "$HOME"/.nvm/versions/node/*/bin; do
    [[ -x "$_d/node" ]] && NODE_PATH="$_d/node" && break
  done

  cat > /etc/systemd/system/carapace-status-server.service <<EOF
[Unit]
Description=Carapace Status Server (port 18794)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=root
WorkingDirectory=/root
Environment=HOME=/root
ExecStart=$NODE_PATH $HOME/.carapace/status-server.js
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable carapace-status-server >/dev/null 2>&1 || true
  systemctl restart carapace-status-server >/dev/null 2>&1 || true

  # Wait for bind
  for _ss in $(seq 1 10); do
    curl -sf --max-time 1 http://127.0.0.1:18794/health >/dev/null 2>&1 && \
      { ok "Status server running on 18794"; break; }
    sleep 1
  done

  # Pre-cache tailscale status so the /pair endpoint can answer without
  # having to exec the tailscale binary from a PATH-minimal systemd env.
  # status-server.js will still fall back to `tailscale status --json`
  # via explicit-path lookup if this file is missing, but caching saves a
  # few ms per call and works around completely locked-down environments.
  if have_cmd tailscale; then
    tailscale status --json > "$HOME/.carapace/tailscale-status.json" 2>/dev/null || true
  fi
fi

# ── Tailscale Serve ─────────────────────────────────────
# `tailscale serve` writes to /var/lib/tailscale/serve.json which is
# root-owned; non-root users get "Access denied: serve config denied"
# unless `tailscale set --operator=$USER` was previously run. Always
# go through $SUDO so sudoer installs work on a fresh box without
# pre-configuring tailscale operator privileges.
SERVE_OK=false
if $TAILSCALE_CONNECTED && $GATEWAY_UP; then
  echo -e "  ${DIM}Connecting Tailscale Serve...${RESET}"
  # Always run tailscale serve for gateway
  $SUDO tailscale serve --bg http://127.0.0.1:18789 >/dev/null 2>&1 || true
  ok "Tailscale serve → gateway connected"
  SERVE_OK=true

  # Expose status server paths. The status server runs on 18794 with
  # routes at root (/health, /history, /pair, /sessions, etc.). Tailscale
  # Serve's --set-path strips the matched prefix from the incoming URL
  # and forwards the remainder to the destination; if the destination
  # URL has its own path, that path is PREPENDED to the forwarded
  # remainder. Earlier versions set destination to
  # http://127.0.0.1:18794/carapace which meant /carapace/pair ended up
  # at /carapace/pair on the backend (404). Point all /carapace/*
  # catch-all mappings at the bare http://127.0.0.1:18794 root so the
  # forwarded remainder lines up with the real routes.
  $SUDO tailscale serve --bg --set-path /health http://127.0.0.1:18794/health >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /history http://127.0.0.1:18794/history >/dev/null 2>&1 || true
  # Catch-all for /carapace/* — forwards everything under the prefix
  # (including /carapace/pair needed for tailnet auto-pair) to the
  # status server's matching root route.
  $SUDO tailscale serve --bg --set-path /carapace http://127.0.0.1:18794 >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/projects http://127.0.0.1:18794/projects >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/cron http://127.0.0.1:18794/cron >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/agents http://127.0.0.1:18794/agents >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/status http://127.0.0.1:18794/status >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/history http://127.0.0.1:18794/history >/dev/null 2>&1 || true
  # Explicit /carapace/pair — belt-and-suspenders so auto-pair works
  # even if the /carapace catch-all above ever gets reverted.
  $SUDO tailscale serve --bg --set-path /carapace/pair http://127.0.0.1:18794/pair >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /sessions http://127.0.0.1:18794/sessions >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /carapace/sessions http://127.0.0.1:18794/sessions >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /projects http://127.0.0.1:18794/projects >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /cron http://127.0.0.1:18794/cron >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /agents http://127.0.0.1:18794/agents >/dev/null 2>&1 || true
  $SUDO tailscale serve --bg --set-path /status http://127.0.0.1:18794/status >/dev/null 2>&1 || true
  # Pair at root too, in case the peer is hitting https://host/pair (no prefix).
  $SUDO tailscale serve --bg --set-path /pair http://127.0.0.1:18794/pair >/dev/null 2>&1 || true
  ok "Tailscale serve → status server paths"

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
  $SUDO tee /etc/systemd/system/carapace-tailscale-serve.service > /dev/null << 'TSEOF'
[Unit]
Description=CARAPACE Tailscale Serve (tailnet-only)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/tailscale serve --bg http://127.0.0.1:18789
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /health http://127.0.0.1:18794/health
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /history http://127.0.0.1:18794/history
# /carapace catch-all — destination is bare (no /carapace suffix) so
# /carapace/pair → strip → /pair → upstream /pair (200, returns
# pair JSON the Mac/iOS app expects). The earlier persistence unit
# shipped /carapace/carapace as the destination, which made the catch-all
# 404 every sub-path that didn't have an explicit override below, and
# the Mac app reported "incompatible host" trying to fetch /carapace/pair.
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace http://127.0.0.1:18794
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/projects http://127.0.0.1:18794/projects
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/cron http://127.0.0.1:18794/cron
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/agents http://127.0.0.1:18794/agents
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/status http://127.0.0.1:18794/status
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/history http://127.0.0.1:18794/history
# /carapace/pair + /pair — explicit so auto-pair survives even if the
# /carapace catch-all ever drifts back to the broken /carapace destination.
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/pair http://127.0.0.1:18794/pair
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /pair http://127.0.0.1:18794/pair
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /sessions http://127.0.0.1:18794/sessions
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /carapace/sessions http://127.0.0.1:18794/sessions
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /projects http://127.0.0.1:18794/projects
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /cron http://127.0.0.1:18794/cron
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /agents http://127.0.0.1:18794/agents
ExecStartPost=/usr/bin/tailscale serve --bg --set-path /status http://127.0.0.1:18794/status

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
else
  echo "  Pair URL: $LINK"
fi
echo ""
QRCMD
$SUDO chmod +x /usr/local/bin/carapace-qr
ok "carapace-qr command installed"

# carapace-onboard wrapper (runs openclaw onboard, then restarts system service)
$SUDO tee /usr/local/bin/carapace-onboard > /dev/null << 'ONBOARDCMD'
#!/usr/bin/env bash
# Silence nvm/npmrc conflict warning
sed -i '/^prefix=/d' "$HOME/.npmrc" 2>/dev/null || true
sed -i '/^globalconfig=/d' "$HOME/.npmrc" 2>/dev/null || true
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
for _d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$_d" ] && export PATH="$_d:$PATH"; done
# Also add npm-global bin where openclaw is installed
export PATH="$HOME/.npm-global/bin:$PATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
# Run onboard with stderr suppressed to hide cosmetic TypeErrors from openclaw
openclaw onboard "$@" 2>/dev/null
ONBOARD_EXIT=$?
# Onboard installs a user service that may conflict — clean it up
systemctl --user stop openclaw-gateway 2>/dev/null || true
systemctl --user disable openclaw-gateway 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/openclaw-gateway.service" 2>/dev/null
systemctl daemon-reload 2>/dev/null
# Let config flush to disk before restarting
sleep 2
systemctl restart openclaw-gateway 2>/dev/null
# Wait for gateway health endpoint
for _gw_wait in $(seq 1 15); do
  curl -s --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
  sleep 1
done
# Gateway health passes before model is fully loaded — wait for full init
sleep 5
echo ""
# Verify model was configured by onboard — set default if missing
MODEL=$(openclaw config get agents.defaults.model 2>/dev/null | head -1 | tr -d '"{ ')
if [ -n "$MODEL" ] && [ "$MODEL" != "null" ]; then
  echo "  ✓ Gateway running with model: $MODEL"
else
  echo "  Setting default model: google/gemini-2.5-flash"
  openclaw config set agents.defaults.model google/gemini-2.5-flash 2>/dev/null || true
  echo "  ✓ Default model set: google/gemini-2.5-flash"
fi

# Validate auth-profiles format (must have type field, key not apiKey)
AUTH_FILE="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_FILE" ]; then
  python3 -c "
import json, sys, os
fp = os.path.expanduser('~/.openclaw/agents/main/agent/auth-profiles.json')
try:
    d = json.load(open(fp))
    changed = False
    profiles = d.get('profiles', {})
    for k, v in profiles.items():
        # Fix apiKey -> key
        if 'apiKey' in v and 'key' not in v:
            v['key'] = v.pop('apiKey')
            changed = True
        # Add missing type field
        if 'type' not in v:
            v['type'] = 'api_key'
            changed = True
        # Add missing provider field
        if 'provider' not in v and ':' in k:
            v['provider'] = k.split(':')[0]
            changed = True
    # Ensure version field
    if 'version' not in d:
        d['version'] = 1
        changed = True
    if changed:
        json.dump(d, open(fp, 'w'))
        print('  Fixed auth-profiles format')
except:
    pass
" 2>/dev/null || true
fi

# Restart gateway to pick up any auth-profiles changes
sleep 1
systemctl restart openclaw-gateway 2>/dev/null || openclaw gateway restart 2>/dev/null || true
for _gw_wait2 in $(seq 1 10); do
  curl -s --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
  sleep 1
done
ONBOARDCMD
$SUDO chmod +x /usr/local/bin/carapace-onboard
ok "carapace-onboard command installed"

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
# Step 9: Configure Your AI (auto-onboard)
#
# Runs whenever an auth profile is MISSING — even when the user chose
# to keep their existing OpenClaw setup. The "skip OpenClaw setup"
# branch is meant to preserve gateway/agent config, not to leave the
# install half-done with no provider keys. Step 9 itself short-circuits
# at line ~1620 if the auth profile is already present, so this is
# safe to run on a fully-configured box too.
# ══════════════════════════════════════════════════════════
if ! $SKIP_OPENCLAW_SETUP || [[ ! -s "$HOME/.openclaw/agents/main/agent/auth-profiles.json" ]]; then
step "Configure Your AI"

export PATH="$HOME/.npm-global/bin:$PATH"

AUTH_FILE="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"

# Already configured? Skip.
if [[ -s "$AUTH_FILE" ]] && python3 -c "
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  sys.exit(0 if d.get('profiles') else 1)
except: sys.exit(1)
" "$AUTH_FILE" 2>/dev/null; then
  ok "AI already configured — skipping"
elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
  # ── Gemini Quickstart: env-var auto-config of the chat provider ──
  # `GEMINI_API_KEY=AIzaSy... curl | bash` should zero-interaction
  # provision OpenClaw with Gemini as the chat provider — skip the
  # interactive provider picker entirely; user already made their
  # choice by setting the env var. Vision mode does NOT consume this
  # key (vision now runs on-device + routes through whatever chat
  # provider the gateway has configured).
  echo -e "  ${DIM}GEMINI_API_KEY detected — Gemini Quickstart, configuring OpenClaw chat...${RESET}"
  PROVIDER="google"
  MODEL="google/gemini-2.5-flash"
  API_KEY="$GEMINI_API_KEY"
  # Validate the key once here — cheaper than baking it in and
  # finding out later the model probe fails.
  VAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
    "https://generativelanguage.googleapis.com/v1beta/models?key=$API_KEY" 2>/dev/null)
  if [[ "$VAL_CODE" != "200" ]]; then
    warn "GEMINI_API_KEY was rejected by Google AI Studio (HTTP $VAL_CODE)."
    echo -e "  ${DIM}  Check the key at: https://aistudio.google.com/apikey${RESET}"
    echo -e "  ${DIM}  Falling through to interactive setup.${RESET}"
    unset API_KEY
  fi
  if [[ -n "${API_KEY:-}" ]]; then
    mkdir -p "$(dirname "$AUTH_FILE")"
    python3 <<PYEOF
import json, os
fp = os.path.expanduser('$AUTH_FILE')
try: d = json.load(open(fp))
except Exception: d = {'version': 1, 'profiles': {}}
d.setdefault('profiles', {})['$PROVIDER:default'] = {
  'type': 'api_key', 'provider': '$PROVIDER', 'key': '$API_KEY'
}
if 'version' not in d: d['version'] = 1
json.dump(d, open(fp, 'w'))
PYEOF
    chmod 600 "$AUTH_FILE"
    python3 <<PYEOF
import json, os
fp = os.path.expanduser('$CONFIG_FILE')
try: cfg = json.load(open(fp))
except Exception: cfg = {}
cfg.setdefault('agents', {}).setdefault('defaults', {})['model'] = {'primary': '$MODEL'}
json.dump(cfg, open(fp, 'w'), indent=2)
PYEOF
    systemctl restart openclaw-gateway 2>/dev/null || true
    for _w in $(seq 1 10); do
      curl -sf --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
      sleep 1
    done
    ok "OpenClaw chat provider set to Gemini (Quickstart)"
  fi
fi

# Interactive picker — only if we didn't already configure via env var
if [[ ! -s "$AUTH_FILE" ]] || ! python3 -c "
import json, sys
try:
  d = json.load(open(sys.argv[1]))
  sys.exit(0 if d.get('profiles') else 1)
except: sys.exit(1)
" "$AUTH_FILE" 2>/dev/null; then
  echo ""
  echo -e "  ${BOLD}Pick your AI provider:${RESET}"
  echo -e "    ${DIM}1)${RESET} Google Gemini    ${DIM}(free tier, recommended)${RESET}"
  echo -e "    ${DIM}2)${RESET} OpenAI Codex     ${DIM}(ChatGPT OAuth — Plus/Pro subscription)${RESET}"
  echo -e "    ${DIM}3)${RESET} Anthropic Claude ${DIM}(API key — pay-as-you-go)${RESET}"
  echo -e "    ${DIM}4)${RESET} OpenAI API       ${DIM}(API key — pay-as-you-go)${RESET}"
  echo -e "    ${DIM}5)${RESET} xAI Grok         ${DIM}(API key — pay-as-you-go)${RESET}"
  echo -e "    ${DIM}6)${RESET} Skip             ${DIM}(I'll do this myself later)${RESET}"
  echo ""
  PROV_CHOICE=""
  if [ -t 0 ]; then
    read -rp "  Choice [1]: " PROV_CHOICE
  elif [ -e /dev/tty ]; then
    read -rp "  Choice [1]: " PROV_CHOICE < /dev/tty || PROV_CHOICE="6"
  else
    PROV_CHOICE="6"  # No TTY — default to Skip instead of Gemini (no way to paste a key)
  fi
  PROV_CHOICE="${PROV_CHOICE:-1}"

  # Default models: picked for safe / cheap / stable.
  # - Haiku over Sonnet/Opus (cheapest Claude tier, dated stable rev)
  # - gpt-5-mini over gpt-5 (much cheaper, same family)
  # - openai-codex/gpt-5.4 (the model OpenClaw itself recommends for
  #   ChatGPT OAuth — capability-list publishes more variants like
  #   gpt-5.2-codex but OpenAI's server-side gate rejects them for
  #   ChatGPT accounts with "model not supported when using Codex
  #   with a ChatGPT account".)
  # - grok-4-fast (fast/cheap tier of flagship family, big context)
  # Users can always switch later via `openclaw onboard` or the dashboard.
  SKIP_AI=false
  case "$PROV_CHOICE" in
    2) PROVIDER="openai-codex"; MODEL="openai-codex/gpt-5.4";         KEY_HINT="(OAuth — no key needed)" ;;
    3) PROVIDER="anthropic";    MODEL="anthropic/claude-haiku-4-5";   KEY_HINT="sk-ant-..." ;;
    4) PROVIDER="openai";       MODEL="openai/gpt-5-mini";            KEY_HINT="sk-..." ;;
    5) PROVIDER="xai";          MODEL="xai/grok-4-fast";              KEY_HINT="xai-..." ;;
    6) SKIP_AI=true ;;
    *) PROVIDER="google";       MODEL="google/gemini-2.5-flash";      KEY_HINT="AIza..." ;;
  esac

  if $SKIP_AI; then
    echo ""
    warn "Skipping AI provider setup."
    warn "OpenClaw will fall back to OpenAI defaults until you configure a provider."
    warn "Run 'carapace-onboard' later to pick a provider and paste your key."
  fi

  # Codex uses ChatGPT OAuth, not an API key. We invoke the direct
  # non-TUI login command `openclaw capability model auth login`, which
  # prints the OAuth URL to stdout. Setting BROWSER=echo prevents any
  # auto-open attempt from swallowing it — on headless boxes xdg-open
  # would fail silently; `echo` just reprints it.
  #
  # `capability model auth login` checks isatty(stdin) and refuses to
  # run if false. Under `curl | bash`, stdin is the pipe from curl, so
  # we must redirect its stdin/stdout/stderr to /dev/tty to give it a
  # real TTY. Same pattern as the `read < /dev/tty` prompts elsewhere.
  IS_CODEX=false
  if ! $SKIP_AI && [ "$PROVIDER" = "openai-codex" ]; then
    IS_CODEX=true
    echo ""
    echo -e "  ${BOLD}Codex uses ChatGPT OAuth.${RESET}"
    echo -e "  ${DIM}An auth URL will print below. Open it on any device with a browser,${RESET}"
    echo -e "  ${DIM}sign in with your ChatGPT Plus/Pro account, and approve. Control${RESET}"
    echo -e "  ${DIM}returns here automatically when auth completes.${RESET}"
    echo ""
    if [ -e /dev/tty ]; then
      BROWSER=echo openclaw capability model auth login --provider openai-codex < /dev/tty > /dev/tty 2>&1
      CODEX_EXIT=$?
    else
      # No controlling terminal (e.g. some cloud-init contexts). Defer.
      CODEX_EXIT=1
    fi
    if [ "$CODEX_EXIT" = "0" ]; then
      # OAuth succeeded. Set the default model AFTER OAuth — the auth
      # login command overwrites openclaw.json, so any prior write would
      # be clobbered. Writing it here avoids orphaning a model default
      # if OAuth fails (and before a valid auth profile exists).
      python3 <<PYEOF
import json, os
fp = os.path.expanduser('$CONFIG_FILE')
try: cfg = json.load(open(fp))
except Exception: cfg = {}
cfg.setdefault('agents', {}).setdefault('defaults', {})['model'] = {'primary': '$MODEL'}
json.dump(cfg, open(fp, 'w'), indent=2)
PYEOF
      systemctl restart openclaw-gateway 2>/dev/null || true
      for _w in $(seq 1 10); do
        curl -sf --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
        sleep 1
      done
      ok "OpenAI Codex configured via ChatGPT OAuth ($MODEL)"
      CODEX_OAUTH_NEEDED=false
    else
      warn "Codex OAuth didn't complete. Run 'openclaw capability model auth login --provider openai-codex' manually."
      CODEX_OAUTH_NEEDED=true
    fi
  fi

  # API-key-paste branch — all providers EXCEPT Codex (and only if not skipped).
  if ! $IS_CODEX && ! $SKIP_AI; then

  echo ""
  echo -e "  ${BOLD}Paste your ${PROVIDER} API key${RESET} ${DIM}(${KEY_HINT})${RESET}"
  echo -e "  ${DIM}(each character echoes as * — paste + press Enter)${RESET}"
  API_KEY=""
  # Char-by-char read so the user gets visual feedback on paste. Without
  # this, `read -s` is completely silent and users legitimately can't
  # tell whether their paste landed. Echo '*' per character, handle
  # backspace/delete, handle Enter as submit.
  read_masked() {
    local prompt="$1" input="" char
    local tty_src="${2:-}"
    printf "%b" "$prompt"
    while true; do
      if [[ -n "$tty_src" ]]; then
        IFS= read -rs -n1 char < "$tty_src" || break
      else
        IFS= read -rs -n1 char || break
      fi
      if [[ -z "$char" ]]; then
        # Empty read = Enter pressed (or EOF)
        echo
        break
      elif [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
        # Backspace / delete
        if [[ -n "$input" ]]; then
          input="${input%?}"
          printf '\b \b'
        fi
      else
        input+="$char"
        printf '*'
      fi
    done
    API_KEY="$input"
  }
  # Read the key, show a masked preview, let the user confirm or re-enter.
  # One bad paste shouldn't mean re-running the whole installer — loop here
  # until they say the masked preview looks right (or submit blank to skip).
  while true; do
    API_KEY=""
    # If neither stdin nor /dev/tty is available (pure-piped `cat | bash`
    # with no allocated TTY), skip the masked read entirely. API_KEY stays
    # empty and the "No key entered" branch below handles it cleanly —
    # without printing "/dev/tty: No such device" errors from the redirect.
    if [ -t 0 ]; then
      read_masked "  Key: "
    elif [ -e /dev/tty ]; then
      read_masked "  Key: " /dev/tty
    fi

    # Blank submission = bailing out. Don't keep re-prompting.
    [ -z "$API_KEY" ] && break

    # Masked preview: first 6 + ••• + last 4.
    KEY_LEN=${#API_KEY}
    if [[ $KEY_LEN -gt 10 ]]; then
      MASKED="${API_KEY:0:6}•••${API_KEY: -4}"
    else
      MASKED="(${KEY_LEN} chars)"
    fi
    echo -e "  ${DIM}  → captured: ${MASKED}${RESET}"

    # Prefix sanity check — KEY_HINT looks like "AIza..." / "sk-ant-..." /
    # "sk-..." / "xai-...". If the paste doesn't match, flag it loudly so
    # they catch typos or wrong-provider paste before we commit to disk.
    EXPECTED_PREFIX="${KEY_HINT%...}"
    EXPECTED_PREFIX="${EXPECTED_PREFIX// /}"
    if [[ -n "$EXPECTED_PREFIX" && "$EXPECTED_PREFIX" != "(OAuth"* && "$API_KEY" != "$EXPECTED_PREFIX"* ]]; then
      echo -e "  ${YELLOW}⚠  That doesn't start with '${EXPECTED_PREFIX}' — ${PROVIDER} keys usually do. Double-check.${RESET}"
    fi

    # Confirm. Default = yes (just press Enter). Anything else re-prompts.
    CONFIRM=""
    if [ -t 0 ]; then
      read -rp "  Does that look right? [Y/n] " CONFIRM
    elif [ -e /dev/tty ]; then
      read -rp "  Does that look right? [Y/n] " CONFIRM < /dev/tty || CONFIRM="y"
    else
      CONFIRM="y"  # No TTY — auto-confirm whatever was piped (else the loop would spin)
    fi
    case "${CONFIRM:-y}" in
      [Yy]*) break ;;
      *)     echo -e "  ${DIM}  OK — paste it again:${RESET}" ;;
    esac
  done

  if [ -z "$API_KEY" ]; then
    warn "No key entered. OpenClaw will fall back to OpenAI defaults —"
    warn "you'll need to configure your ${PROVIDER} key later via 'carapace-onboard'."
  else
    mkdir -p "$(dirname "$AUTH_FILE")"
    python3 <<PYEOF
import json, os
fp = os.path.expanduser('$AUTH_FILE')
try:
  d = json.load(open(fp))
except Exception:
  d = {'version': 1, 'profiles': {}}
d.setdefault('profiles', {})['$PROVIDER:default'] = {
  'type': 'api_key', 'provider': '$PROVIDER', 'key': '$API_KEY'
}
if 'version' not in d: d['version'] = 1
json.dump(d, open(fp, 'w'))
PYEOF
    chmod 600 "$AUTH_FILE"

    python3 <<PYEOF
import json, os
fp = os.path.expanduser('$CONFIG_FILE')
try: cfg = json.load(open(fp))
except Exception: cfg = {}
cfg.setdefault('agents', {}).setdefault('defaults', {})['model'] = {'primary': '$MODEL'}
json.dump(cfg, open(fp, 'w'), indent=2)
PYEOF

    systemctl restart openclaw-gateway 2>/dev/null || true
    for _w in $(seq 1 10); do
      curl -sf --max-time 1 http://127.0.0.1:18789/health >/dev/null 2>&1 && break
      sleep 1
    done
    ok "AI configured: $MODEL"
  fi
  fi   # end IS_CODEX gate around the api-key-paste branch
fi
else
  ok "OpenClaw already configured — skipping AI setup"
fi  # end Step 9 skip block

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
if [ -n "$TOKEN" ]; then
  # Snapshot the sessions.json BEFORE the probe so we can identify + delete
  # any ghost session the probe creates. Without this cleanup, the
  # "confirmed" checkpoint survives as a second session record that iOS
  # can pick up during reconnect as a competing history feed.
  SESSIONS_DIR="$HOME/.openclaw/agents/main/sessions"
  PROBE_SNAPSHOT_KEYS="/tmp/carapace-probe-keys-pre.txt"
  if [[ -f "$SESSIONS_DIR/sessions.json" ]]; then
    jq -r "keys[]" "$SESSIONS_DIR/sessions.json" 2>/dev/null | sort > "$PROBE_SNAPSHOT_KEYS"
  else
    : > "$PROBE_SNAPSHOT_KEYS"
  fi
  PROBE_SNAPSHOT_FILES=$(ls "$SESSIONS_DIR"/*.jsonl 2>/dev/null | sort || true)

  # Skip the deterministic probe if user picked Codex — there's no auth yet
  # (OAuth is completed by the user after install), so the probe would fail.
  if [ "${CODEX_OAUTH_NEEDED:-false}" = "true" ]; then
    echo -e "  ${DIM}Skipping AI probe (Codex OAuth not yet completed — see end of install).${RESET}"
    ALIVE=true
  else

  echo -e "  ${DIM}Verifying AI is actually alive (deterministic probe)...${RESET}"
  # Deterministic liveness check — the model must reply with the literal
  # word "confirmed" (case-insensitive) and nothing else. A hung or
  # misrouted agent can still return JSON with empty content, which is
  # why the old "any response counts" check wasn't trustworthy. This
  # forces the model to prove it's actually reading + following the
  # prompt end-to-end.
  ALIVE=false
  for _mv in $(seq 1 20); do
    # Tolerate curl failure (container without systemd, gateway not yet
    # started, transient network) — without `|| true`, a connection
    # refused here aborts the whole install under `set -e`.
    RESPONSE=$(curl -s -X POST http://127.0.0.1:18789/v1/chat/completions \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"model":"openclaw","messages":[{"role":"user","content":"Respond with exactly the word confirmed and nothing else. No punctuation, no explanation, no formatting."}],"stream":false,"max_tokens":8}' \
      --max-time 90 2>/dev/null || true)
    # Extract the assistant content and normalize (lowercase, strip whitespace + punctuation)
    CONTENT=$(echo "$RESPONSE" | python3 -c '
import json, sys, re
try:
  d = json.load(sys.stdin)
  c = d["choices"][0]["message"]["content"]
  # Strip whitespace + punctuation, lowercase
  print(re.sub(r"[^a-z]", "", c.lower()))
except Exception:
  print("")
' 2>/dev/null)
    if [ "$CONTENT" = "confirmed" ]; then
      ok "AI verified — model replied 'confirmed' on demand"
      ALIVE=true
      break
    fi
    sleep 2
  done
  if ! $ALIVE; then
    warn "AI probe did not return 'confirmed' — gateway is up but model may be misrouted."
    echo -e "  ${DIM}  Debug: check ~/.openclaw/agents/main/auth-profiles.json + check 'openclaw gateway logs'${RESET}"
  fi
  fi  # end CODEX_OAUTH_NEEDED gate

  # ── Clean up probe artifacts ──
  # The probe created a session (to prove the gateway can actually route
  # a chat turn end-to-end), but we don't want that artifact polluting
  # the user's feed. Delete any session keys + jsonl files that appeared
  # AFTER the pre-probe snapshot. We never touch agent:main:main — that
  # stays intact even if the probe happened to write into it.
  if [[ -f "$SESSIONS_DIR/sessions.json" ]]; then
    CURRENT_KEYS=$(jq -r "keys[]" "$SESSIONS_DIR/sessions.json" 2>/dev/null | sort)
    NEW_KEYS=$(comm -13 "$PROBE_SNAPSHOT_KEYS" <(echo "$CURRENT_KEYS") | grep -v "^agent:main:main$" || true)
    if [[ -n "$NEW_KEYS" ]]; then
      # Remove new keys from sessions.json (never touches agent:main:main)
      python3 - <<PYEOF
import json, os
fp = os.path.expanduser('$SESSIONS_DIR/sessions.json')
try:
  d = json.load(open(fp))
  to_drop = '''$NEW_KEYS'''.strip().splitlines()
  for k in to_drop:
    d.pop(k, None)
  json.dump(d, open(fp, 'w'))
except Exception as e:
  pass
PYEOF
    fi
    # Delete jsonl files that didn't exist before the probe AND aren't the
    # file that sessions.json[agent:main:main] points at.
    MAIN_FILE=$(jq -r '."agent:main:main".sessionFile // ("agent:main:main" | split(":")[0] + "/sessions/" + ."agent:main:main".sessionId + ".jsonl")' "$SESSIONS_DIR/sessions.json" 2>/dev/null | xargs -I{} basename "{}" 2>/dev/null || true)
    CURRENT_FILES=$(ls "$SESSIONS_DIR"/*.jsonl 2>/dev/null | sort || true)
    for f in $(comm -13 <(echo "$PROBE_SNAPSHOT_FILES") <(echo "$CURRENT_FILES") 2>/dev/null); do
      name=$(basename "$f")
      if [[ "$name" != "$MAIN_FILE" ]]; then
        rm -f "$f"
      fi
    done
  fi
  rm -f "$PROBE_SNAPSHOT_KEYS"
fi

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

inject_carapace_vision_rules
echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}${BOLD}  ✓ CARAPACE is ready!${RESET}"
echo -e "  ${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
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

# Offer TUI launch as optional
if [ -t 0 ] || [ -e /dev/tty ]; then
  echo -e "  ${TEAL}Want to also launch the terminal chat? [y/N]${RESET}"
  if [ -t 0 ]; then
    read -rp "  " LAUNCH_TUI
  else
    read -rp "  " LAUNCH_TUI < /dev/tty || LAUNCH_TUI="n"
  fi
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
