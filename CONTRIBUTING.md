# Contributing

Thanks for considering a contribution. Before you start, please read the
scope notes below — they'll save us both time.

## What we accept PRs for

- **`install.sh`** — the headless Linux installer.
- **The marketing website** (`index.html`, `install/`, `assets/`,
  `manage.html`, and related files).
- **Deploy tooling** (`deploy.sh`) and repo docs (`README.md`,
  `SECURITY.md`, this file).

## What we don't accept PRs for

- **The macOS app** (`Carapace-*.dmg`). Source is closed and lives
  elsewhere. PRs that modify or try to reverse-engineer the DMG will be
  closed without review. If you have a bug report or feature request
  for the Mac app, file it from the app's `Help → Report an Issue`
  menu, or open a regular (non-PR) GitHub issue describing the behavior
  and I'll route it to the private tracker.
- **The iOS app** (Carapace on the App Store). Same — source is closed.
  Report bugs via the App Store listing or a regular GitHub issue.
- **OpenClaw itself.** That's upstream at
  [openclaw.ai](https://openclaw.ai/) — report there.

## How to contribute to the Linux installer

1. **Open an issue first** if your change is non-trivial. Describe the
   problem and your proposed fix. Saves you the risk of writing code
   against a different design direction than what lands.
2. **Keep bash portable.** The installer runs on Debian, Ubuntu,
   Raspberry Pi OS, Rocky, Alma, Fedora, and whatever else happens to
   have `apt-get` or `dnf`/`yum`. Avoid GNU-isms that don't work on BSD
   coreutils (think macOS users running it out of curiosity), and don't
   assume a specific Python or Node version — the installer bootstraps
   its own.
3. **Keep the prereq pattern consistent.** If you're adding a new
   required tool, follow the existing pattern:
   ```bash
   if ! have_cmd <tool>; then
     if have_cmd apt-get; then
       run $SUDO apt-get install -y <deb-pkg> || true
     elif have_cmd dnf; then
       run $SUDO dnf install -y <rpm-pkg> || true
     elif have_cmd yum; then
       run $SUDO yum install -y <rpm-pkg> || true
     fi
     have_cmd <tool> || fail "<tool> is required but could not be installed. See /tmp/carapace-install.log for details."
   fi
   ok "<tool> available"
   ```
   The `|| true` on the install is deliberate — we let the install step
   fail silently and rely on the downstream `have_cmd` check to produce
   a clear error message. Without this, `set -euo pipefail` kills the
   script with no visible message.
4. **Idempotency matters.** The installer is designed to be safe to
   re-run. Don't introduce steps that rotate tokens, overwrite auth
   files, or break existing pairings on re-run. Look at the
   `clean_dirty_install` pattern for reference.
5. **Test on at least one apt-based distro and one dnf-based distro**
   before opening a PR. A fresh Debian 13 cloud image is the easiest
   way — spin one up, `curl | bash`, confirm the whole flow.
6. **Verbose-flag behavior.** The `run` helper hides output by default
   and echoes it in verbose mode. If you add new commands, use `run`
   for anything that could fail — don't call installers directly.

## How to contribute to the website

- Static HTML + Tailwind CDN + vanilla JS. No build step.
- Keep the dark / teal / glass visual language. If you're proposing a
  new section, match the existing `.glass` / `.feature-card` patterns.
- Preview locally by opening `index.html` in a browser, or deploy a
  preview branch via Cloudflare Pages if you have access.
- Be honest in the copy. Don't claim capabilities the software doesn't
  have. If a feature is gated by a paid tier, say so. If a feature is
  pending a third-party SDK (e.g., Meta Ray-Ban beta), say that.

## Commit style

- One logical change per commit.
- First line under 72 characters, imperative mood, with an optional
  scope prefix matching the file it touches, e.g.:
  - `install.sh: add jq as a prereq`
  - `index.html: drop stale '$10/month VPS' framing`
- Body paragraphs wrap at ~72 chars and explain *why*, not *what*.

## Before you submit

- Run `bash -n install.sh` to catch syntax errors.
- `git log` should be legible — no "wip" or "fix2" commits.
- By submitting, you agree your contribution is under the MIT license.

## Reporting security issues

Do **not** use PRs or issues for security problems. See
[SECURITY.md](./SECURITY.md) for the private-disclosure path.
