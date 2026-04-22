#!/usr/bin/env bash
# test-installer-arm64.sh
#
# Spins up an arm64 Debian container (same architecture as Raspberry Pi
# 4/5) and runs the live carapace.info install.sh inside it. Catches any
# arm64-specific regressions in the installer before they reach real
# users. On Apple Silicon the container runs at native speed (no CPU
# emulation); on Intel it uses QEMU translation via Docker's binfmt and
# is ~5x slower but still usable.
#
# Usage:
#   ./test-installer-arm64.sh
#
# What this verifies:
#   * install.sh prereq detection + install on arm64 Debian
#   * nvm + Node.js install works on arm64
#   * openclaw npm install completes
#   * Carapace status-server.js copy works
#   * No hardcoded x86_64 paths in the installer
#
# What this does NOT verify:
#   * systemd service start (containers don't ship full systemd by
#     default — we fall back to `openclaw gateway run` in foreground)
#   * Tailscale network plumbing (no tailscaled inside a container)
#   * SD card / IO performance quirks real RPi hardware exhibits
#
# For full RPi-fidelity testing, see the UTM + Debian arm64 netinst
# path in the accompanying README.

set -euo pipefail

BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

ok()   { echo "${GREEN}✓${RESET} $1"; }
info() { echo "${DIM}→${RESET} $1"; }
warn() { echo "${YELLOW}⚠${RESET} $1"; }
fail() { echo "${RED}✗${RESET} $1"; }

clear
echo "${BOLD}CARAPACE — arm64 (Raspberry Pi 4/5) installer test${RESET}"
echo "${DIM}───────────────────────────────────────────────────────${RESET}"
echo

# Ensure colima VM is running (start it if not).
if ! colima status 2>/dev/null | grep -q "Running"; then
  info "colima VM not running — starting with aarch64 arch, 4 GB RAM, 2 CPU..."
  colima start --arch aarch64 --cpu 2 --memory 4 --disk 20 2>&1 | tail -5
  ok "colima started"
fi

# Sanity: docker CLI reaches the colima daemon.
if ! docker ps >/dev/null 2>&1; then
  fail "docker can't reach the colima daemon. Try: colima start"
  exit 1
fi

info "Pulling debian:bookworm arm64 image (first run downloads ~50 MB)..."
docker pull --platform linux/arm64 debian:bookworm >/dev/null 2>&1
ok "Image ready"

echo
echo "${BOLD}Running install.sh inside the container:${RESET}"
echo "${DIM}(this is the same command real users run on their RPi)${RESET}"
echo

# Run the installer inside the container. We inject:
#   * curl (not in the bare debian image)
#   * sudo (install.sh expects it)
#   * procps (for `free -m` the installer uses to size Node heap)
# Then pipe install.sh from the live site to bash. Exit code propagates.
docker run --platform linux/arm64 --rm -it \
  --hostname carapace-rpi-test \
  debian:bookworm bash -c '
    set -e
    apt-get update -qq >/dev/null
    apt-get install -y -qq curl sudo procps ca-certificates >/dev/null
    echo "debian $(cat /etc/debian_version) / $(uname -m) / $(free -m | awk "/^Mem:/ {print \$2}")MB RAM"
    echo
    curl -fsSL https://carapace.info/install.sh | bash
    INSTALL_EXIT=$?
    echo
    echo "=== POST-INSTALL VERIFICATION ==="
    echo -n "openclaw binary:  "
    command -v openclaw >/dev/null && echo "✓ $(command -v openclaw)" || echo "✗ not found"
    echo -n "status-server:    "
    [ -f "$HOME/.carapace/status-server.js" ] && echo "✓ $HOME/.carapace/status-server.js" || echo "✗ missing"
    echo -n "openclaw version: "
    openclaw --version 2>/dev/null | head -1 || echo "(could not run)"
    echo
    echo "=== DONE ==="
    echo "Exit code from install.sh: $INSTALL_EXIT"
    echo
    echo "Press Enter to leave the container..."
    read -r _
  ' 2>&1

echo
ok "Test complete. Container torn down."
echo
echo "${DIM}Press Enter to close this window.${RESET}"
read -r _
