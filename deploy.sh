#!/usr/bin/env bash
# Deploy carapace.info to Cloudflare Pages.
#
# The "carapace" Pages project is NOT git-connected — `git push` alone
# does not publish. Run this script to push + deploy in one shot.
#
# Usage:
#   ./deploy.sh

set -euo pipefail
cd "$(dirname "$0")"

YELLOW='\033[33m'; GREEN='\033[32m'; DIM='\033[2m'; RESET='\033[0m'

# 1. Warn if there are uncommitted changes — they'll ship to Cloudflare
#    but won't be in git, which creates a "deployed but not committed"
#    drift that's painful to debug later.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo -e "${YELLOW}⚠  Uncommitted changes will be deployed but NOT committed.${RESET}"
  echo -e "${DIM}   Consider: git add . && git commit -m \"...\" first.${RESET}"
  echo ""
fi

# 2. Push unpushed commits so GitHub mirrors the live site.
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  if [[ "$AHEAD" -gt 0 ]]; then
    echo "→ Pushing $AHEAD commit(s) to origin..."
    git push || echo "  (push failed — continuing with Cloudflare deploy)"
    echo ""
  fi
fi

# 3. Deploy to Cloudflare Pages. Project name is fixed; branch=main
#    means this becomes the production deployment.
echo "→ Deploying to Cloudflare Pages (project: carapace)..."
npx -y wrangler@latest pages deploy . --project-name=carapace --branch=main

echo ""
echo -e "${GREEN}✓ Live at https://carapace.info/${RESET}"
