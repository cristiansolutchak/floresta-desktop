# Changelog

## Unreleased

### Added

- **Swift Sync**, the default sync method for new mainnet and signet nodes:
  - the app downloads the network's hints file before the first start;
  - the node then processes blocks from the first one in parallel, without Utreexo proofs;
  - progress comes from the node's output;
  - the setup wizard and Settings offer Swift Sync, Fast Start and Full validation.
- **In-app updates** for the app and for `florestad`:
  - a check at start and every 12 hours;
  - Update now or Later, and an optional automatic mode;
  - every package is verified against a signed manifest before it is installed;
  - settings, wallets and chain data are kept;
  - macOS and Linux (`.tar.gz` installs update themselves; `.deb` installs go through the system installer).

### Changed

- The app installs `florestad` from Floresta `master` at `3a47993`, which reports `v0.9.0` and includes Swift Sync. It is shown as "v0.9.0 (master 3a47993)".
- Each installed `florestad` build gets its own folder, so an update never replaces the running binary or the rollback copy.
- A development build whose local release server is not running says so, instead of blaming the internet connection.

### Fixed

- A long `florestad` version label overflowed the sidebar footer, also while the sidebar collapsed or expanded.

## v0.0.1 (first public pre-release)

Floresta GUI installs, configures, runs and monitors a [Floresta](https://github.com/getfloresta/Floresta) Bitcoin node (`florestad` v0.9.1) without the terminal, and follows watch-only wallets.

### What it does

- **Installs florestad** from signed builds of the official v0.9.1 release ([floresta-gui-release](https://github.com/cristiansolutchak/floresta-gui-release)). The app checks:
  - the manifest's Ed25519 signature;
  - the manifest's expiry and serial;
  - each download's SHA-256 and size;
  - the binary's `--version`.

  You can also, from Advanced setup:
  - point it at a `florestad` you built yourself (one in a Nix profile is found automatically);
  - connect it to a node you already run, in Docker, as a Nix service or in a terminal. The app checks that Floresta answers on the expected network first, and warns when a Docker container exposes the RPC beyond this computer.
- **Setup wizard:** network, data folder, Fast Start (assume-utreexo with background backfill) and services. Mainnet by default; test networks under Advanced.
- **Runs the node as a child process:**
  - RPC bound to `127.0.0.1` only;
  - the data folder made private to your user;
  - a clean stop when you quit;
  - reconnects to a node left running by an earlier session.
- **Dashboard:**
  - Overview and Sync with honest progress: blocks verified by this node are kept apart from the Utreexo snapshot;
  - Peers (with Add Peer);
  - RPC and Electrum consoles (read-only templates; state-changing calls ask first; key material is refused);
  - Logs with filters and Export Diagnostics;
  - Help with the licences.
- **Watch-only wallet:** balances, addresses and activity from public descriptors, checked against the node. It never asks for, stores or sends private keys or seed phrases, and it cannot sign or send.
- **Recovers from:**
  - a node that crashes;
  - a node that stalls in header selection;
  - a damaged florestad wallet store, which is moved aside after you confirm, never deleted.

### Platforms

| Platform | Status |
|---|---|
| macOS 11+ (Apple Silicon and Intel, universal app) | Tested on Apple Silicon. Intel builds tested under Rosetta only. |
| Linux arm64 and x64 (Debian 12 or newer, glibc 2.34+) | Tested in clean Debian 12 containers (x64 under emulation). |
| Windows 10+ x64 | Build scripts ready; **not yet tested on Windows**. |

### Known issues

- **Mainnet sync can be slow or stall.** Floresta needs peers that serve Utreexo proofs, and few are online. The app looks for them and adds the ones it can verify, and shows "Stalled" with an explanation when progress stops. Signet currently has none reachable.
- **The macOS app is not signed with an Apple Developer ID.** Gatekeeper blocks the first launch: right-click the app, choose **Open**, then **Open** again.
- **The node's background re-check of the snapshot (backfill)** reports no progress in florestad 0.9.1, so the app describes it in words instead of a percentage.
- **The florestad release manifest expires on 2027-04-25** and must be re-signed before then.
