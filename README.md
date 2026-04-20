# CARAPACE

The marketing site for [CARAPACE](https://carapace.info/) and the open-source
Linux installer (`install.sh`) that provisions a headless
[OpenClaw](https://openclaw.ai/) gateway on any Ubuntu / Debian / Raspberry Pi
or Rocky / Alma / Fedora host.

> Your AI. Your machine. Your rules.
> We're just helping you feed it the data it's craving.

---

## What's in this repository

| Asset | License | Notes |
|---|---|---|
| `install.sh` | **MIT** — see [LICENSE](./LICENSE) | The one-liner Linux installer. Inspect it, fork it, send PRs. |
| `index.html`, `install/`, `assets/`, other web content | **MIT** | Marketing site deployed to Cloudflare Pages at carapace.info. |
| `Carapace-*.dmg` | **Proprietary** | Signed macOS application binary. Distributed from this repo for convenience; **not** covered by the MIT license. |

**Not in this repository:**
- The macOS app source (closed-source).
- The iOS app source (closed-source; App Store distribution only).

If you're looking to contribute, you're contributing to `install.sh` or the
website. The Mac and iOS apps are closed and PRs against them have nowhere to
land — see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## The Linux installer

```bash
curl -fsSL https://carapace.info/install.sh | bash
```

It walks the user through:

1. Prerequisites — installs `curl`, `python3`, `git`, `build-essential`
   (`gcc`/`g++`/`make`), `jq`, and `cron` on their behalf.
2. Node.js via `nvm`.
3. OpenClaw via `npm install -g openclaw`.
4. Tailscale for secure remote access to the gateway.
5. A confirm-or-re-enter loop on API-key entry so a typo doesn't require
   restarting the whole installer.
6. Provider picker (Gemini / Claude / OpenAI Codex via ChatGPT OAuth /
   OpenAI API / xAI / Skip).
7. QR-code pair with the Carapace iOS app.

The installer is idempotent — safe to re-run without breaking existing
pairings or authentication tokens.

### Tested on

| OS | Status |
|---|---|
| Debian 11 / 12 / 13 (cloud images) | ✅ |
| Ubuntu 20.04 / 22.04 / 24.04 LTS | ✅ (same apt-get path as Debian) |
| Raspberry Pi OS 64-bit (Bookworm+) | ✅ |
| Rocky / Alma / RHEL 9 | ⚠️ dnf branch supported; validation in progress |
| Fedora 40+ | ⚠️ dnf branch supported; not yet exercised in the wild |

Pacman (Arch), apk (Alpine), and NixOS are not supported. PRs welcome.

### Piping `curl` to `bash` is trust

If you'd rather read the script before running it:

```bash
curl -fsSL https://carapace.info/install.sh -o install.sh
less install.sh   # read it
bash install.sh   # run it
```

---

## Security & liability

**This software is provided AS IS, without warranty of any kind, express or
implied.** The MIT [LICENSE](./LICENSE) covers the legal side. In plain
English, what that means for you:

### You are responsible for

- **Your hardware and hosting.** The installer modifies system configuration
  on the box you run it on (writes to `$HOME/.openclaw/`, installs systemd
  units, adds a cron entry, pulls packages from your distro's repos). Review
  the script if that matters to you.
- **Your API keys and your AI bills.** You bring your own keys for Gemini /
  OpenAI / Anthropic / xAI. CARAPACE never sees those keys — they stay on
  your machine. That also means: *if you generate $500 in usage overnight,
  that's between you and the AI provider.* Set quotas if you're worried.
- **Your data.** CARAPACE is designed so conversations, documents, and
  agent outputs stay on hardware you control. That also means **you own
  your backups** — if your VPS disappears, so does your data.
- **Your network and access control.** SSH keys, Tailscale ACLs, firewall
  rules, physical access to the device — all you.
- **Evaluating model output.** LLMs hallucinate, misread documents, and
  produce confidently wrong answers. Don't use CARAPACE (or any LLM) as
  the only source of truth for anything that matters.

### We are not liable for

- Data breaches, credential leaks, or privacy holes in your own setup.
- Runaway bills at your AI provider.
- Data loss on your hardware or cloud provider.
- Outages at third-party services (AI providers, Tailscale, Cloudflare,
  your hosting company, Apple's App Store).
- Anything a model says or does. We ship a runtime; the model output is
  upstream.
- Damages, direct or indirect, arising from use of this software.

If that level of responsibility isn't right for you, don't use CARAPACE.

### Reporting a vulnerability

Please do **not** open a public GitHub issue for security bugs. Follow the
private-disclosure process in [SECURITY.md](./SECURITY.md).

---

## Contributing

Scoped to `install.sh` and the marketing site. See
[CONTRIBUTING.md](./CONTRIBUTING.md).

---

## Deploying the website

The Cloudflare Pages project (`carapace`) is not git-connected — deploys are
manual via [`./deploy.sh`](./deploy.sh):

```bash
./deploy.sh
```

That script pushes any unpushed commits to GitHub, then runs
`wrangler pages deploy . --project-name=carapace --branch=main`.

---

## License

[MIT](./LICENSE) — applies to `install.sh` and the website content in this
repo. The macOS DMG and the iOS app are proprietary.
