<p align="center">
  <img src="assets/carapace-logo.png" alt="CARAPACE" width="200">
</p>

<h1 align="center">CARAPACE</h1>

<p align="center">
  <strong>Your OpenClaw. Your machine. Your rules.</strong><br>
  <sub>Get your mom on OpenClaw in ten minutes.</sub>
</p>

<p align="center">
  <a href="https://github.com/mikeypaepke-gif/carapace-site/releases/latest"><img src="https://img.shields.io/badge/release-v2.0.6-00DCC8?style=flat-square" alt="v2.0.6"></a>
  <a href="https://carapace.info"><img src="https://img.shields.io/badge/website-carapace.info-00DCC8?style=flat-square" alt="Website"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-00C4B4?style=flat-square" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platforms-macOS%20%E2%80%A2%20iOS%20%E2%80%A2%20Linux%20%E2%80%A2%20Raspberry%20Pi-888?style=flat-square" alt="Platforms">
  <a href="https://apps.apple.com/us/app/carapace/id6760282881"><img src="https://img.shields.io/badge/App%20Store-iOS-ffffff?style=flat-square" alt="App Store"></a>
</p>

<p align="center">
  <img src="assets/mac-chat.png" alt="CARAPACE on macOS" width="820">
</p>

---

This repository hosts the marketing site for [CARAPACE](https://carapace.info/)
and the open-source Linux installer (`install.sh`) that **layers Carapace on
top of an existing [OpenClaw](https://openclaw.ai/) gateway** on any Ubuntu /
Debian / Raspberry Pi or Rocky / Alma / Fedora host.

Carapace is a **shell on top of OpenClaw** — OpenClaw owns the AI runtime,
your provider, your API key, and the gateway service. Carapace adds
Tailscale serve, the iOS pairing layer, sentinel-bounded workspace prompts,
a status server, and helper commands. The carapace install is **non-
destructive on existing OpenClaw setups** — your chats, keys, and identity
files are preserved by design.

---

## What's in this repository

| Asset | License | Notes |
|---|---|---|
| `install.sh` | **MIT** — see [LICENSE](./LICENSE) | The Linux installer that layers Carapace onto an existing OpenClaw. Inspect it, fork it, send PRs. |
| `index.html`, `install/`, `assets/`, other web content | **MIT** | Marketing site deployed to Cloudflare Pages at carapace.info. |
| `status-server.js`, `cognitive/` | **MIT** | The status server + cognitive memory modules dropped at `~/.carapace/` during install. |
| `Carapace-*.dmg` | **Proprietary** | Signed macOS application binary. Distributed from this repo for convenience; **not** covered by the MIT license. |

**Not in this repository:**
- The macOS app source (closed-source).
- The iOS app source (closed-source; App Store distribution only).
- OpenClaw itself (separate project, [openclaw.ai](https://openclaw.ai)).

If you're looking to contribute, you're contributing to `install.sh`,
`status-server.js`, or the website. The Mac and iOS apps are closed and PRs
against them have nowhere to land — see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## The Linux installer (two commands)

Carapace is a **shell** on top of OpenClaw. Install OpenClaw first
(handles Node, npm, and the interactive provider/key/model wizard),
then layer Carapace on top:

```bash
# 1. Install OpenClaw (one-time, handles node + provider/key/model)
curl -fsSL https://openclaw.ai/install.sh | bash
# When asked "Hatch in Terminal? [y/N]" → say NO. The terminal hatch
# fires a chat turn that races Carapace's setup. Skip it.

# 2. Layer Carapace on top
curl -fsSL https://carapace.info/install.sh | bash
```

The Carapace installer (this repo's `install.sh`) walks through:

1. **Pre-flight** — verifies OpenClaw is installed and has at least one
   AI provider configured. Bails clean with actionable instructions if
   either is missing.
2. **Tailscale** — installs + interactive auth (one click in your browser).
3. **HTTPS verification** — confirms Tailscale serve will work over HTTPS.
4. **Gateway service** — installs/restarts the openclaw-gateway systemd
   unit with a dynamic openclaw path resolver (handles per-user nvm,
   sudo-npm system, and `~/.npm-global` install layouts).
5. **Status server** — drops `status-server.js` + cognitive memory modules
   at `~/.carapace/`, registers as systemd service, exposes `/agents`,
   `/cron`, `/sessions`, `/projects`, `/history`, `/chat`, etc.
6. **Helper commands** — installs `carapace-qr`, `carapace-onboard`,
   `carapace-prune` to `/usr/local/bin/`.
7. **Health check** — port-bind probe (NOT `/health` curl, which is
   unreliable during the openclaw acpx runtime cold-start window).
8. **Carapace shell setup** — bumps `agents.defaults.timeoutSeconds`
   (180s, only if your value is lower), `bootstrapMaxChars` (50K),
   `gateway.trustedProxies` (Tailscale CGNAT range). Sentinel-bounded
   inserts into `AGENTS.md` + `MEMORY.md`. Preserves any non-default
   `IDENTITY.md`. Writes `PROJECTS.md` only if missing. Removes
   `BOOTSTRAP.md` only if it carries our sentinel or known openclaw-stock
   headers.
9. **Connect** — verifies gateway responsive, Tailscale serve active,
   workspace files present, gateway token present. Runs a single warmup
   chat completion against the configured provider so the user's first
   iOS message after pairing isn't stuck in cold-start. Then prints the
   QR + pair URL.
10. **Cron jobs** — installs nightly gateway restart (3am UTC) + daily
    trajectory prune (3:30am UTC) so the TUI/iOS history tabs stay
    snappy without the user ever managing trajectory bloat manually.

The installer is **idempotent** — safe to re-run any time you want to
refresh the workspace prompts, pull updated helper commands, or pick up
a newer Carapace release. Re-runs respect every safeguard above.

### What Carapace never touches

| File / state | Behavior |
|---|---|
| `~/.openclaw/agents/main/sessions/*.jsonl` (your chat history) | **Never touched** |
| `~/.openclaw/agents/main/agent/auth-profiles.json` (your API keys) | **Never touched** |
| Custom workspace files (`SOUL.md`, `USER.md`, `OPS.md`, `TASKS.md`, etc.) | **Never touched** |
| `IDENTITY.md` with a non-default Name field | **Never touched** (only seeds if openclaw's unfilled template) |
| `openclaw.json` config values larger than ours | **Never reduced** (caps only bump if your value is lower) |
| Existing Tailscale serve routes | **Never reset** (only adds) |

Want a snapshot before running? `tar czf ~/openclaw-backup.tar.gz -C ~ .openclaw`

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

**The Software is provided AS IS, WITH ALL FAULTS, AND WITHOUT WARRANTY OF
ANY KIND.** You are solely responsible for the security of any system on
which you install or run the Software, for the management of your API
keys and AI-provider bills, for the configuration of Tailscale (or any
other remote-access tool you choose) and your network, and for any data
you process. The Author accepts **no liability** for data breaches,
privacy incidents, credential compromise, data loss, runaway bills,
third-party service outages, AI model output, or any other damages
arising from use of the Software.

Full terms, including warranty disclaimer, limitation of liability,
indemnification, and governing law, are in **[TERMS.md](./TERMS.md)**
(also published at <https://carapace.info/terms/>). By using the
Software, you agree to those Terms.

**Reporting a vulnerability:** please do *not* open a public GitHub
issue for security bugs. Follow the private-disclosure process in
[SECURITY.md](./SECURITY.md).

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
