# Contributing

Thanks for helping. Issues and pull requests are welcome. For a large change, open an issue first so the approach can be agreed before you write it.

## Setup

Follow [Prerequisites](README.md#prerequisites) and [Build and run](README.md#build-and-run) in the README. Before you open a pull request, run:

```bash
dart format lib test integration_test tool
flutter analyze            # must be clean
flutter test test          # must pass
```

CI runs the same checks, builds the app on macOS, Linux and Windows, and scans `pubspec.lock` for known vulnerabilities.

## How the code is organised

```
lib/
  app/        shell, router, theme
  core/       cross-cutting: errors, networking, processes, JSON-RPC, Electrum, platform paths, security
  features/<feature>/
    domain/        pure Dart: models and decision logic (no Flutter, no dart:io)
    data/          implementations: processes, files, HTTP, RPC
    presentation/  Riverpod providers, controllers, widgets
  shared/     widgets and formatting used by several features
tool/         build, packaging, release and test-environment scripts
```

Rules the code follows:

- **The node is a separate process.** The app supervises `florestad` and talks to it over JSON-RPC and Electrum. It does not link Floresta in-process.
- **Errors are values.** The data layer catches exceptions and returns `Either<Failure, T>` (fpdart). Every `Failure` carries a title, a message and a recovery hint the UI can show as they are.
- **Dependencies point inwards:**
  - `domain` imports no Flutter, `dart:io` or data code;
  - `core` imports no feature;
  - a feature uses another feature's domain or providers, never its data classes.
- **Pure logic goes in `domain`** as plain functions, with unit tests. There are no pass-through use-case classes.

## Things that need extra care

- **Upstream behaviour.** Every CLI flag, RPC method, response field or log line the app relies on must exist in Floresta's source at the pinned commit. Cite the file and symbol in a comment. Log text is not an API: when the pinned commit changes, re-check the strings in `node/domain/swift_sync.dart`, `node/domain/utreexo_peer.dart` and `installation/data/capability_scan.dart`.
- **Security:**
  - RPC stays bound to `127.0.0.1`;
  - processes start with explicit argument lists and absolute paths, never through a shell;
  - downloads are verified against the signed manifest before use;
  - the app never asks for elevated privileges.
- **Wallet:**
  - The app is watch-only. Do not add send, sign or key-handling features.
  - Input that looks like a private key or seed is refused before it reaches the node (`SensitiveData`).
  - Descriptors and xpubs are kept out of logs, diagnostics and preferences.
- **User data.** Nothing may delete or overwrite the node's data folder, chain state or wallet files without an explicit confirmation that names what will be lost.
- **Honest UI:**
  - Show only what the node reported.
  - Label estimates as estimates.
  - Say plainly when something is unavailable.
  - Never show a success that did not happen.

## Tests

- New domain and data code gets unit tests; new screens and flows get widget tests (`test/app_test.dart` or next to the feature).
- A bug fix comes with a regression test.
- Use the fakes in `test/helpers/` (`FakeProcess`, `fakes.dart`, `LocalArtifactServer`) and `package:http/testing.dart`. Unit and widget tests must not need the network, a real `florestad` or a particular machine.
- Tests never use real private keys, seed phrases, mainnet funds or real wallet data.
- Tests against real nodes are opt-in, use regtest or signet and temporary folders, and are skipped unless their environment variable is set (see each file's header).

## Pull requests

- Keep each pull request to one change, and describe what it does and how you checked it.
- Note anything you could not verify, such as an untested platform or a step not run against a real node.
- Update `README.md` or `CHANGELOG.md` when user-visible behaviour changes.

By contributing, you agree that your contributions are licensed under the project's terms: MIT OR Apache-2.0, at the user's option.
