# Changelog

## v0.0.1 (first public pre-release)

Floresta GUI installs, configures, runs and monitors a [Floresta](https://github.com/getfloresta/Floresta) Bitcoin node (`florestad` v0.9.1) without the terminal, and follows watch-only wallets.

### What it does

- **Installs florestad** from signed builds of the official v0.9.1 release ([floresta-gui-release](https://github.com/cristiansolutchak/floresta-gui-release)). The app checks:
  - the manifest's Ed25519 signature;
  - the manifest's expiry and serial;
  - each download's SHA-256 and size;
  - the binary's `--version`.

  You can also point it at a `florestad` you built yourself.
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
