# Floresta GUI

A desktop app for running and managing a [Floresta](https://github.com/getfloresta/Floresta) Bitcoin node without the terminal. It finds `florestad`, guides setup, starts and stops the node, shows sync and peer status, and manages Floresta's **watch-only** wallet.

> Status: early development. macOS (arm64) builds; Linux and Windows are scaffolded but unverified. The app has not yet been tested against a real `florestad`. See [docs/implementation/current-status.md](docs/implementation/current-status.md).

## How it works

The app supervises `florestad` as a child process and talks to its local JSON-RPC server ([ADR-0001](docs/decisions/0001-process-management-over-ffi.md)). Floresta publishes no prebuilt binaries yet, so you build it from source (the app shows the steps) or point the app at an existing binary.

The wallet is watch-only. Floresta cannot sign or send. Use Sparrow or Electrum connected to the node's Electrum server for that.

## Develop

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```


## License

Not yet chosen. Floresta itself is MIT OR Apache-2.0.
