#!/usr/bin/env bash
# Interactive arm64 sandbox for hand-testing install.sh
#
# Spins up an arm64 Debian container (same architecture as Raspberry
# Pi 4/5) and drops you into a root shell with curl/sudo already
# installed. Paste the install command and watch it run.
#
# Usage:
#   ./test-installer-arm64-interactive.sh
#
# When you exit the shell (Ctrl-D or `exit`), the container is
# discarded. Your Mac stays clean.

set -euo pipefail

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
RESET=$'\033[0m'

clear
echo "${BOLD}CARAPACE — arm64 sandbox (Raspberry Pi-class environment)${RESET}"
echo "${DIM}────────────────────────────────────────────────────────────${RESET}"
echo

# Colima VM up?
if ! colima status 2>/dev/null | grep -q "Running"; then
  echo "${DIM}→ Starting colima aarch64 VM (first run takes ~90s)...${RESET}"
  colima start --arch aarch64 --cpu 2 --memory 4 --disk 20 2>&1 | tail -3
fi

if ! docker ps >/dev/null 2>&1; then
  echo "docker can't reach colima. Try: colima stop && colima start --arch aarch64"
  exit 1
fi

echo "${DIM}→ Preparing debian:bookworm arm64 image...${RESET}"
docker pull --platform linux/arm64 debian:bookworm >/dev/null 2>&1
echo "${GREEN}✓${RESET} ready"
echo

echo "${BOLD}Dropping you into an arm64 Debian shell.${RESET}"
echo
echo "${CYAN}Paste this to run the installer:${RESET}"
echo "  ${BOLD}curl -fsSL https://carapace.info/install.sh | bash${RESET}"
echo
echo "${DIM}When done, type 'exit' or press Ctrl-D to tear down.${RESET}"
echo

# Interactive session. We pre-install curl+sudo+procps so the user can
# immediately run install.sh without bootstrapping first. Hostname set
# to hint "this is the RPi sim". `--tmpfs /tmp` for /tmp writability
# under openclaw's session lock behavior.
docker run --platform linux/arm64 -it --rm \
  --hostname carapace-rpi-sim \
  --tmpfs /tmp \
  debian:bookworm bash -c '
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq curl sudo procps ca-certificates apt-utils 2>/dev/null
    cat <<BANNER

 🐚  You are in an arm64 Debian container.
     Same CPU arch as Raspberry Pi 4/5.

     RAM:   $(free -m | awk "/^Mem:/ {print \$2}") MB
     Arch:  $(uname -m)
     OS:    $(cat /etc/debian_version)

     Try:  curl -fsSL https://carapace.info/install.sh | bash
     Exit: Ctrl-D or `exit`

BANNER
    exec bash
  '

echo
echo "${GREEN}✓${RESET} Container torn down. Your Mac is unchanged."
echo
echo "${DIM}Press Enter to close.${RESET}"
read -r _
