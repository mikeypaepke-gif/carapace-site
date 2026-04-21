#!/usr/bin/env bash
# Submit a signed Carapace DMG to Apple for notarization, wait for the
# verdict, and staple the ticket so Gatekeeper passes even offline.
#
# ─── ONE-TIME SETUP (not committed, not scripted) ──────────────────────
# Store Apple credentials securely in macOS Keychain. This is the ONLY
# place the app-specific password lives — after this runs, only the
# profile name ("carapace-notary") appears in any script.
#
#   xcrun notarytool store-credentials "carapace-notary" \
#     --apple-id "YOUR-APPLE-ID@example.com" \
#     --team-id  "YOURTEAMID" \
#     --password "xxxx-xxxx-xxxx-xxxx"
#
# Generate the app-specific password at https://account.apple.com →
# Sign-In and Security → App-Specific Passwords. Rotate it if it ever
# leaves your machine.
#
# ─── USAGE ─────────────────────────────────────────────────────────────
#   ./notarize.sh                    # newest Carapace-*.dmg in repo root
#   ./notarize.sh path/to.dmg        # specific file
#   PROFILE=my-profile ./notarize.sh # override keychain profile name
#
# ─── WHAT IT DOES ──────────────────────────────────────────────────────
#   1. Locates the DMG (arg or newest match)
#   2. Verifies xcrun + notarytool are installed
#   3. Verifies the keychain profile exists
#   4. Verifies the DMG is signed with a Developer ID Application cert
#   5. Submits to Apple and waits for the verdict
#   6. On success: staples the ticket and validates
#   7. On failure: fetches and prints Apple's rejection log

set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-carapace-notary}"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'

die()  { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
step() { echo -e "${DIM}→${RESET} $*"; }

# ──────────────────────────────────────────────────────────────────────
# 1. Locate the DMG
# ──────────────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
  DMG="$1"
else
  # Newest Carapace-*.dmg by mtime. `ls -t` is fine here — filenames
  # contain no spaces / newlines (our DMGs are "Carapace-x.y.z.dmg").
  DMG=$(ls -t Carapace-*.dmg 2>/dev/null | head -1 || true)
fi

[[ -n "${DMG:-}" && -f "$DMG" ]] || die "No DMG found. Pass one explicitly: ./notarize.sh <path-to.dmg>"
ok "DMG: ${BOLD}${DMG}${RESET} ($(stat -f %z "$DMG" | awk '{printf "%.1f MB", $1/1024/1024}'))"

# ──────────────────────────────────────────────────────────────────────
# 2. Toolchain check
# ──────────────────────────────────────────────────────────────────────
command -v xcrun >/dev/null 2>&1 || die "xcrun not found. Install Xcode Command Line Tools: xcode-select --install"
xcrun notarytool --version >/dev/null 2>&1 || die "notarytool not available. Update Xcode or CLI Tools (requires Xcode 13+)."
# stapler has no --help at the top level; `xcrun -f` just resolves the path.
xcrun -f stapler >/dev/null 2>&1 || die "stapler not available. Reinstall Xcode CLI Tools."
ok "Xcode CLI Tools: notarytool + stapler present"

# ──────────────────────────────────────────────────────────────────────
# 3. Keychain profile check
# ──────────────────────────────────────────────────────────────────────
# notarytool doesn't have a dedicated "does this profile exist" command.
# Probing with `history` returns success fast if the profile works, and
# fails with a specific "No Keychain password item found" error otherwise.
# (notarytool history doesn't take --max-results — earlier attempt with
# that flag failed its usage parser.)
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo ""
  die "Keychain profile '${PROFILE}' not found or its credentials are invalid.

    Run this once, replacing the placeholders with your values:

      xcrun notarytool store-credentials \"${PROFILE}\" \\
        --apple-id YOUR-APPLE-ID@example.com \\
        --team-id  YOURTEAMID \\
        --password xxxx-xxxx-xxxx-xxxx

    Generate the app-specific password at https://account.apple.com
    (Sign-In and Security → App-Specific Passwords)."
fi
ok "Keychain profile: ${PROFILE}"

# ──────────────────────────────────────────────────────────────────────
# 4. Verify (or self-sign) DMG with Developer ID Application
# ──────────────────────────────────────────────────────────────────────
# Notarization requires the DMG container itself to carry a Developer ID
# signature (not just the .app inside). build.sh signs the .app but
# package.sh doesn't sign the DMG it creates. If we find an unsigned DMG
# and a Developer ID cert is present on this Mac, sign it here rather
# than making the human go fight codesign flags.
CODESIGN_OUT=$(codesign -dv --verbose=4 "$DMG" 2>&1 || true)
if echo "$CODESIGN_OUT" | grep -q "code object is not signed at all"; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')
  if [[ -n "$IDENTITY" ]]; then
    info "DMG was unsigned; auto-signing with: ${IDENTITY}"
    codesign --force --sign "$IDENTITY" "$DMG" 2>&1 | sed 's/^/    /'
    CODESIGN_OUT=$(codesign -dv --verbose=4 "$DMG" 2>&1 || true)
  fi
fi

if ! echo "$CODESIGN_OUT" | grep -q "Developer ID Application"; then
  echo ""
  echo "  Current signature:"
  echo "$CODESIGN_OUT" | grep -E "^(Authority|Identifier|TeamIdentifier)=" | sed 's/^/    /'
  echo ""
  die "DMG isn't signed with a Developer ID Application certificate and
     no Developer ID cert was found on this Mac. Install one in Keychain
     Access (Apple Developer → Certificates) and re-run."
fi
ok "Signed with Developer ID Application"

# ──────────────────────────────────────────────────────────────────────
# 5. Submit and wait
# ──────────────────────────────────────────────────────────────────────
echo ""
step "Submitting to Apple (this normally takes 1–5 minutes)..."
echo ""

# Capture and echo in one pass so the user watches progress live AND
# we can parse the UUID / final status afterwards.
LOG=$(mktemp -t carapace-notarize)
trap 'rm -f "$LOG"' EXIT

xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait 2>&1 | tee "$LOG"

UUID=$(grep -oE 'id: [a-f0-9-]{30,}' "$LOG" | head -1 | awk '{print $2}' || true)
STATUS=$(grep -oE 'status: [A-Za-z]+' "$LOG" | tail -1 | awk '{print $2}' || true)

if [[ "$STATUS" != "Accepted" ]]; then
  echo ""
  echo -e "${RED}${BOLD}✗ Notarization failed.${RESET} Apple returned status: ${STATUS:-unknown}"
  if [[ -n "${UUID:-}" ]]; then
    echo ""
    step "Fetching Apple's rejection log for submission ${UUID}..."
    echo ""
    xcrun notarytool log "$UUID" --keychain-profile "$PROFILE" 2>&1 || true
  fi
  exit 1
fi
echo ""
ok "Notarization accepted (submission UUID: ${UUID:-unknown})"

# ──────────────────────────────────────────────────────────────────────
# 6. Staple the ticket
# ──────────────────────────────────────────────────────────────────────
# Without this, Gatekeeper has to phone home on first launch to fetch
# the ticket. Stapling attaches it to the DMG so offline installs work.
step "Stapling ticket to DMG..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" >/dev/null
ok "Ticket stapled and validated"

# ──────────────────────────────────────────────────────────────────────
# 7. Summary + next steps
# ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Done.${RESET} ${DMG} is notarized, stapled, and ready to ship."
echo ""
echo -e "${DIM}Next steps:${RESET}"
echo -e "${DIM}  1. Spot-check on a Mac that's never seen the previous DMG:${RESET}"
echo -e "${DIM}       xattr -d com.apple.quarantine ${DMG}  # remove local quarantine bit${RESET}"
echo -e "${DIM}       open ${DMG}                           # should launch without Gatekeeper nag${RESET}"
echo -e "${DIM}  2. Commit the stapled DMG and deploy:${RESET}"
echo -e "${DIM}       git add ${DMG} && git commit -m \"${DMG}: notarized + stapled\"${RESET}"
echo -e "${DIM}       ./deploy.sh${RESET}"
echo -e "${DIM}  3. After verifying downloads work cleanly, remove the${RESET}"
echo -e "${DIM}     'Approve it once in System Settings' step from${RESET}"
echo -e "${DIM}     install/mac/index.html.${RESET}"
