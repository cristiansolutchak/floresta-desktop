#!/usr/bin/env bash
# Builds the Linux florestad release artifact inside Debian 12 (bookworm), the
# same base as the app's Linux build, so the binary needs no newer glibc than
# the app does. Runs tool/release/build_florestad_artifact.sh unchanged (PGP-
# verified tag, pinned commit, library and --version checks).
#
#   tool/release/build_florestad_linux_in_container.sh arm64|x64 [out-dir]
#
# x64 runs as linux/amd64 (Rosetta or QEMU on Apple Silicon; slow). Rust is
# pinned to the version the macOS artifacts were built with. Caches live in
# ~/.cache/floresta-gui-tools/linux-<arch>; output defaults to
# ~/.cache/floresta-gui-tools/release-artifacts. FLORESTA_TAG and
# FLORESTA_COMMIT, and FLORESTA_MASTER_COMMIT (a pinned master commit), pass
# through (see build_florestad_artifact.sh). Nothing is
# signed here.
set -euo pipefail
arch="${1:-}"
case "$arch" in
  arm64) platform=linux/arm64; target=aarch64-unknown-linux-gnu ;;
  x64) platform=linux/amd64; target=x86_64-unknown-linux-gnu ;;
  *) echo "usage: $0 arm64|x64 [out-dir]" >&2; exit 1 ;;
esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
tools="$HOME/.cache/floresta-gui-tools"
cache="$tools/linux-$arch"
out="${2:-$tools/release-artifacts}"
rust_version="1.95.0"
mkdir -p "$cache" "$out"

docker run --rm --platform "$platform" \
  -v "$root:/src:ro" -v "$cache:/tools" -v "$out:/out" \
  -e TARGET="$target" -e RUST_VERSION="$rust_version" \
  -e FLORESTA_TAG="${FLORESTA_TAG:-}" -e FLORESTA_COMMIT="${FLORESTA_COMMIT:-}" \
  -e FLORESTA_MASTER_COMMIT="${FLORESTA_MASTER_COMMIT:-}" \
  debian:bookworm bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl git \
      gnupg build-essential cmake pkg-config libboost-dev libclang-dev clang \
      binutils file \
      >/dev/null
    export RUSTUP_HOME=/tools/rustup CARGO_HOME=/tools/cargo
    if [[ ! -x /tools/cargo/bin/cargo ]]; then
      curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
        --default-toolchain "$RUST_VERSION" >/dev/null
    fi
    export PATH=/tools/cargo/bin:$PATH
    rustup default "$RUST_VERSION" >/dev/null
    rustup target add "$TARGET" >/dev/null
    FLORESTA_TOOLS_DIR=/tools /src/tool/release/build_florestad_artifact.sh \
      "$TARGET" /out
  '
