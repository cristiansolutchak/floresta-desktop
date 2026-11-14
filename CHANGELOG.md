# Changelog

## v0.0.1-beta (2026-11-13), first public pre-release

Floresta Desktop installs, configures, runs and monitors a [Floresta](https://github.com/getfloresta/Floresta) Bitcoin node (`florestad`) without the terminal, and follows watch-only wallets.

### What it does

- **Installs florestad** from signed builds published in [floresta-gui-release](https://github.com/cristiansolutchak/floresta-gui-release).
  - The build is Floresta `master` at `3a47993`. It reports `v0.9.0` but is newer than the `v0.9.1` tag and includes Swift Sync; the app shows it as "v0.9.0 (master 3a47993)".
  - Before installing, the app checks:
    - the manifest's Ed25519 signature, expiry and serial;
    - each download's size and SHA-256;
    - the binary's `--version`.
  - From Advanced setup you can instead:
    - point the app at a `florestad` you built (one in a Nix profile is found automatically);
    - connect it to a node you already run (Docker, a Nix service, a terminal). The app first checks that Floresta answers on the expected network, and warns when a Docker container exposes the RPC beyond this computer.
- **Setup wizard:** network (mainnet by default; test networks under Advanced), data folder, sync method and services.
- **Sync methods:**
  - **Swift Sync** (default for new mainnet and signet nodes): the app downloads the network's hints file, then the node processes blocks from the first one in parallel, without Utreexo proofs. Progress is read from the node's output.
  - **Fast Start** (assume-utreexo, with background backfill).
  - **Full validation.**
- **Runs the node as a child process:**
  - RPC bound to `127.0.0.1` only, and the data folder private to your user;
  - a clean stop when you quit;
  - it reconnects to a node left running by an earlier session.
- **Dashboard:**
  - Overview and Sync, where blocks this node verified are kept apart from what it accepted;
  - Peers, with Add Peer;
  - RPC and Electrum consoles: read-only templates, state-changing calls ask first, and key material is refused;
  - Logs, with filters and Export Diagnostics;
  - Settings, and Help with the licences.
- **Watch-only wallet:** balances, addresses and activity from public descriptors, checked against the node. It never asks for, stores or sends private keys or seed phrases, and it cannot sign or send.
- **Updates** for the app and for `florestad`:
  - a check at start and every 12 hours, with Update now or Later;
  - an optional automatic mode;
  - each package is verified against a signed manifest before it is installed;
  - settings, wallets and chain data are kept.

  The macOS app and the Linux `.tar.gz` update themselves; the `.deb` goes through the system installer.
- **Recovers from:**
  - a node that crashes;
  - a node that stalls in header selection;
  - a damaged florestad wallet store, which is moved aside after you confirm, never deleted.

### Downloads

| File | For |
|---|---|
| `Floresta-0.0.1-beta-macos-universal-unsigned.dmg` | macOS 11+, Apple Silicon and Intel |
| `Floresta-0.0.1-beta-macos-universal-unsigned.zip` | The same app, as used by in-app updates |
| `floresta-desktop_0.0.1-beta_arm64.deb`, `floresta-desktop_0.0.1-beta_amd64.deb` | Debian, Ubuntu and derivatives |
| `floresta-desktop-0.0.1-beta-linux-arm64.tar.gz`, `floresta-desktop-0.0.1-beta-linux-x64.tar.gz` | Other Linux; unpack into a folder you own (it then updates itself) |
| `SHA256SUMS` | Checksums of every file above |

### Platforms

| Platform | Status |
|---|---|
| macOS 11+ (universal app) | Tested on Apple Silicon. Intel builds tested under Rosetta only. |
| Linux arm64 and x64 (Debian 12 or newer) | Built and packaged in clean Debian 12 containers. |
| Windows 10+ x64 | Builds in CI; **not tested on Windows and not packaged in this release**. |

### Known issues

- **The macOS app is not signed with an Apple Developer ID.** Gatekeeper blocks the first launch: open System Settings → Privacy & Security and choose **Open Anyway**.
- **Mainnet sync can still slow down at the end.** After Swift Sync, the most recent blocks need peers that serve Utreexo proofs, and few are online. The app looks for them, adds the ones it can verify, and shows "Stalled" with an explanation when progress stops.
- **Swift Sync progress is only known for a node this app started**, because no RPC reports it. With "Write a log file" on, Swift Sync writes one line per block to `debug.log`.
- **The node's background re-check of the snapshot (backfill)** reports no progress, so the app describes it in words instead of a percentage.
- **The florestad release manifest expires on 2027-05-12** and must be re-signed before then.
