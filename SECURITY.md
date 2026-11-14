# Security policy

Floresta GUI runs a Bitcoin node and installs and updates programs on your computer, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub: **Security → Report a vulnerability** on this repository. Include what you found, how to reproduce it, and the app version (Help shows it).

You will get an acknowledgement, and a fix or an explanation, as soon as it can be investigated. Please give a reasonable time to ship a fix before you disclose it.

Problems in Floresta itself (`florestad`) belong to [getfloresta/Floresta](https://github.com/getfloresta/Floresta).

## Scope

In scope, for example:
- verification of downloaded `florestad` builds and app updates (signed manifests, checksums, rollback protection);
- how the app starts processes and replaces itself during an update;
- exposure of the node's RPC or Electrum server beyond `127.0.0.1`;
- leaks of descriptors or extended public keys into logs, diagnostics or preferences;
- input paths that could let private keys or seed phrases reach the node or disk.

The app is watch-only by design: it never holds private keys or seed phrases.
