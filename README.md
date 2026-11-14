# Floresta Desktop

A desktop app for running and managing a [Floresta](https://github.com/getfloresta/Floresta) Bitcoin node without the terminal. It installs `florestad` from signed builds, guides setup, starts and stops the node, shows sync, peers and logs, and follows watch-only wallets.

> **Status: pre-release (v0.0.1).** No packaged release is published yet; build it from source (below).

## Features

- **Installs florestad** from signed builds of the official source. Before installing, the app checks:
  - the release manifest's Ed25519 signature, expiry and serial;
  - each download's size and SHA-256;
  - the binary's `--version`.

  You can also point the app at a `florestad` you built, or connect it to a node you already run (Docker, a Nix service, a terminal).
- **Setup wizard:** network (mainnet by default; signet, testnet4 and regtest under Advanced), data folder, sync method and services.
- **Sync methods:**
  - **Swift Sync** (default for new mainnet and signet nodes): downloads a hints file, then processes blocks from the first one in parallel, without Utreexo proofs.
  - **Fast Start:** starts from the Utreexo state built into Floresta.
  - **Full validation.**
- **Runs the node as a child process.** JSON-RPC is bound to `127.0.0.1` only, since it has no authentication, and the data folder is private to your user. The app stops the node cleanly and reconnects to one it left running.
- **Dashboard:**
  - Overview and Sync, with progress that keeps blocks the node verified apart from what it accepted;
  - Peers, with Add Peer;
  - RPC and Electrum consoles;
  - Logs, with Export Diagnostics;
  - Settings and Help.
- **Watch-only wallet:** balances, addresses and activity from public descriptors. It never asks for, stores or sends private keys or seed phrases, and it cannot sign or send. For that, connect Sparrow or Electrum to the node's Electrum server (`tcp://127.0.0.1:50001` on mainnet).
- **Updates:** checks for new versions of the app and of `florestad` at start, verifies them against the signed release, and installs them now, later or automatically. Settings, wallets and chain data are kept.

## Supported platforms

| Platform | Status |
|---|---|
| macOS 11+ (Apple Silicon and Intel) | Tested on Apple Silicon; Intel builds tested under Rosetta only. |
| Linux arm64 and x64 (glibc 2.34+) | Tested in Debian 12 containers. Other distributions are untested. |
| Windows 10+ x64 | Builds in CI; not tested on Windows. No in-app updates. |

The `florestad` builds the app installs are from Floresta `master` at commit `3a47993` (it reports `v0.9.0`; it includes Swift Sync, which the `v0.9.1` tag lacks). They are published, with their build records, in [floresta-gui-release](https://github.com/cristiansolutchak/floresta-gui-release).

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) **3.35.5** (Dart 3.9.2), the version CI uses.
- macOS: Xcode and CocoaPods.
- Linux: `clang cmake ninja-build pkg-config libgtk-3-dev`. At runtime, GTK 3 and EGL/GLES (`libegl1`, `libgles2`).
- Windows: Visual Studio 2022 with "Desktop development with C++".

## Build and run

```bash
flutter pub get
flutter run -d macos     # or: -d linux, -d windows
```

Plain `flutter run` has no release source, so it cannot install `florestad` or check for updates: choose an existing `florestad` in Installation. To use the published releases instead:

```bash
flutter run -d macos --dart-define-from-file=config/release/production.json
```

Release builds and packages:

```bash
tool/build_app.sh production
tool/package_macos.sh            # macOS: .dmg and the .zip used by updates
FLORESTA_LINUX_ARCH=arm64 tool/build_linux_in_container.sh production   # Linux (Docker): .deb and .tar.gz; arm64 or x64
```

On Windows: `tool\windows\build_app.ps1 production`, then `tool\windows\package_windows.ps1`.

**Development release server.** `tool/release/dev_release.sh` serves a locally built `florestad`, signed with a development key, on `127.0.0.1:8787`. A build made with `config/release/development.json` installs from it. Create that file from `development.example.json`.

## Installing a packaged build

- **macOS:** open the `.dmg` and drag Floresta to Applications. The app is not yet signed with an Apple Developer ID, so the first launch needs System Settings → Privacy & Security → **Open Anyway**.
- **Linux:** run `sudo apt install ./floresta-desktop_<version>_<arch>.deb`. Alternatively, unpack the `.tar.gz` into a folder you own and run `floresta-desktop/floresta_desktop`; that copy updates itself.

Node data lives in `~/.floresta/` (one folder per network) unless you choose another folder. Removing the app never deletes it.

## Tests

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test test
```

Opt-in suites against real nodes, skipped unless their environment is set:

- `test/integration/`:
  - `tool/regtest/bootstrap.sh` builds the tools (utreexod, florestad) into `~/.cache/floresta-gui-tools`;
  - then `source "$(tool/regtest/bootstrap.sh --print-env)"`;
  - then `flutter test test/integration`.

  Each file's header says what it needs.
- `integration_test/`: full-app runs on a desktop, for example `flutter test integration_test/ux_tour_test.dart -d macos`.
- Linux in a container: `tool/test_linux_in_container.sh arm64|x64`.

## Troubleshooting

- **"Port … is in use":** another Floresta or Bitcoin Core node is running. Stop it, or change the RPC port in Settings.
- **"Waiting for Utreexo peers" or "Stalled":** the node has no peer that serves Utreexo proofs. The app keeps looking and adds the ones it can verify.
- **The node stopped:** Logs shows its last output. With "Write a log file" on, the full log is `debug.log` in the data folder.
- **Reporting a problem:** use Help → Copy Diagnostics. Diagnostics contain no wallet data, and extended public keys are redacted.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option, like Floresta itself.
- The `florestad` binaries the app installs are Floresta's (MIT OR Apache-2.0, `assets/licenses/floresta-LICENSE-MIT`).
- The bundled Space Grotesk font is under the SIL Open Font License 1.1 (`assets/fonts/Space_Grotesk/OFL.txt`).
- Help → Licences lists every licence, including the app's dependencies.
