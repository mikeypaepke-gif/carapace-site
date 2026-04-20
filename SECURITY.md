# Security policy

> **Legal context.** This document describes how to report security
> issues responsibly. It does not modify or expand the Author's
> liability, warranty disclaimer, or indemnification provisions. Those
> live in [TERMS.md](./TERMS.md) and at
> <https://carapace.info/terms/>, and the Author accepts no liability
> whatsoever for security-related events affecting your systems or
> data. Continue only if you've read and agreed to those Terms.

## Reporting a vulnerability

**Please do not open public GitHub issues for security bugs.**

If you think you've found a security issue in `install.sh` or anything else
in this repository, report it privately using GitHub's security-advisory
flow:

👉 **https://github.com/mikeypaepke-gif/carapace-site/security/advisories/new**

This lets us discuss the issue, fix it, and publish an advisory without
exposing users in the interim.

### What to include

- A short description of the issue and its impact.
- Steps to reproduce (or a proof-of-concept).
- The distro / host environment where you hit it, if relevant (Debian 13
  cloud image, Raspberry Pi OS 64-bit, Rocky 9, etc.).
- Your assessment of severity.

### What to expect

- Acknowledgement within a few days.
- A fix timeline proportional to severity — we prioritize issues that can
  compromise a running gateway, leak API keys, or grant remote code
  execution.
- Credit in the advisory (unless you'd rather stay anonymous).

## Scope

**In scope:**

- `install.sh` — the Linux installer.
- The marketing website (`index.html`, `install/*`, `manage.html`, etc.).
- Build and deploy scripts in this repo.

**Out of scope** (different reporting path):

- The **macOS application** (the `Carapace-*.dmg` binary). Source is closed
  and maintained separately. Report via the app's `Help → Report an Issue`
  menu, or contact the email listed on the App Store page.
- The **iOS application** (Carapace on the App Store). Same — source is
  closed and tracked separately.
- **OpenClaw itself** — that's upstream. Report to the OpenClaw project
  directly at [openclaw.ai](https://openclaw.ai/).
- **Third-party providers** (Tailscale, Cloudflare, AI provider APIs,
  your hosting company) — report to them directly.

## What we consider a vulnerability

Examples of things we *would* fix under this policy:

- The installer fetching a URL that an attacker could control (DNS
  hijacking aside — we can't fix that).
- The installer writing to paths an unprivileged attacker could hijack
  via a race condition.
- Cleartext secrets persisted to unexpected locations.
- Cross-site scripting / injection in the website.
- Any path by which running `curl … | bash` on an unmodified install.sh
  could yield code execution beyond what the user reasonably expects.

Examples of things that are **not** vulnerabilities:

- "Piping curl to bash is dangerous." Yes, and the user is trusting the
  script they chose to run. Mitigation is documented in the README
  (download first, read, then run).
- "The installer needs sudo / modifies system state." That's what
  installers do. It only modifies state the user's account can modify.
- Outputs from the AI model itself. That's an upstream model behavior,
  not a bug in this software.
- Runaway AI-provider bills caused by model use.

## No bug bounty

We can't offer monetary rewards. We can offer public thanks in the
advisory and — depending on severity — a mention on the release notes.
