#!/usr/bin/env bash
# Builds the TEST-ONLY tools used by the opt-in regtest integration tests:
#   - Go 1.25.14 (official archive, SHA-256 pinned below)
#   - utreexod v0.6.0 (pinned commit, built without the optional BDK wallet)
#   - florestad v0.9.1 (pinned commit; Boost 1.85 workaround on macOS)
#
# Everything is installed under $FLORESTA_TOOLS_DIR (default:
# ~/.cache/floresta-gui-tools). Nothing is installed system-wide, no PATH or
# shell profile is changed, and sudo is never used. Delete the directory to
# remove everything.
#
# Prerequisites that are NOT installed by this script (install them yourself):
#   - git, curl, shasum (or sha256sum), a C/C++ toolchain
#   - Rust >= 1.85 (cargo) for florestad
#   - macOS: Homebrew boost@1.85, cmake, pkgconf  (brew install boost@1.85 cmake pkgconf)
#   - Linux: cmake, pkg-config, libboost-dev (Boost <= 1.85 known to work)
#   - Bitcoin Core (bitcoind) >= 26 for the multi-node tests (used as miner and
#     signer of TEST transactions only)
#
# Usage: tool/regtest/bootstrap.sh            # build what is missing
#        tool/regtest/bootstrap.sh --print-env # print the env file path
set -euo pipefail

TOOLS_DIR="${FLORESTA_TOOLS_DIR:-$HOME/.cache/floresta-gui-tools}"
ENV_FILE="$TOOLS_DIR/env.sh"

GO_VERSION="1.25.14"
UTREEXOD_REPO="https://github.com/utreexo/utreexod.git"
UTREEXOD_TAG="v0.6.0"
UTREEXOD_COMMIT="fe71f3d9282ef0812f7f6087f0c0df9ce0fda508"
FLORESTA_REPO="https://github.com/getfloresta/Floresta.git"
FLORESTA_TAG="v0.9.1"
FLORESTA_COMMIT="bc2db8d07e72651f9981ce589c5688f4d575dc7a"

if [[ "${1:-}" == "--print-env" ]]; then echo "$ENV_FILE"; exit 0; fi

log() { printf '\033[1m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac

go_sha256() {
  case "$1-$2" in
    darwin-arm64) echo 5b26c0b6f308240fca2614fb02f622cfcc8c0cc3b69c78bba4845489a4590259 ;;
    darwin-amd64) echo b09087a67d5792a8b0fcbf74212d62560c94ac8a8fd750ff920d8cb5f1e20118 ;;
    linux-amd64)  echo a21ae5633a269bcd7e90cf767e48225633795e99d831742cbf3397064fee7712 ;;
    linux-arm64)  echo 9bf234ea70ffec9347fdf6b22ce4add51717d3386a38a441e8c8743fceb5eaee ;;
    *) return 1 ;;
  esac
}

# Clone `repo` at `tag` into `dir` and refuse to continue unless HEAD is the
# pinned commit (protects against a moved or replaced tag).
checkout_pinned() {
  local repo="$1" tag="$2" commit="$3" dir="$4"
  if [[ ! -d "$dir/.git" ]]; then
    git clone --quiet --depth 1 --branch "$tag" "$repo" "$dir"
  fi
  local head; head="$(git -C "$dir" rev-parse HEAD)"
  [[ "$head" == "$commit" ]] || die "$dir is at $head, expected pinned $commit ($tag)"
  [[ -z "$(git -C "$dir" status --porcelain)" ]] || die "$dir has local modifications"
}

mkdir -p "$TOOLS_DIR/src" "$TOOLS_DIR/bin"

# --- Go -----------------------------------------------------------------------
GOROOT_DIR="$TOOLS_DIR/go$GO_VERSION"
if [[ ! -x "$GOROOT_DIR/bin/go" ]]; then
  expected="$(go_sha256 "$os" "$arch")" || die "no pinned Go checksum for $os-$arch"
  archive="$TOOLS_DIR/go$GO_VERSION.$os-$arch.tar.gz"
  log "downloading Go $GO_VERSION ($os-$arch)"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$archive" "https://go.dev/dl/go$GO_VERSION.$os-$arch.tar.gz"
  actual="$(sha256_of "$archive")"
  [[ "$actual" == "$expected" ]] || { rm -f "$archive"; die "Go checksum mismatch: $actual"; }
  tmp="$(mktemp -d "$TOOLS_DIR/go-extract.XXXXXX")"
  tar -xzf "$archive" -C "$tmp"
  mv "$tmp/go" "$GOROOT_DIR" && rmdir "$tmp" && rm -f "$archive"
fi
GO="$GOROOT_DIR/bin/go"
log "go: $("$GO" version)"

# --- utreexod -------------------------------------------------------------------
if [[ ! -x "$TOOLS_DIR/bin/utreexod" ]]; then
  checkout_pinned "$UTREEXOD_REPO" "$UTREEXOD_TAG" "$UTREEXOD_COMMIT" "$TOOLS_DIR/src/utreexod"
  log "building utreexod $UTREEXOD_TAG (without BDK wallet)"
  (
    cd "$TOOLS_DIR/src/utreexod"
    # Module cache and build cache stay inside the tools dir.
    GOROOT="$GOROOT_DIR" GOPATH="$TOOLS_DIR/gopath" GOCACHE="$TOOLS_DIR/gocache" \
      GOTOOLCHAIN=local GOFLAGS=-mod=readonly \
      "$GO" build -trimpath -o "$TOOLS_DIR/bin/utreexod" .
  )
fi
log "utreexod: $("$TOOLS_DIR/bin/utreexod" --version 2>&1 | head -1)"  # exits before creating its app-data dir

# --- florestad ------------------------------------------------------------------
if [[ ! -x "$TOOLS_DIR/bin/florestad" ]]; then
  command -v cargo >/dev/null || die "cargo not found (install Rust >= 1.85)"
  checkout_pinned "$FLORESTA_REPO" "$FLORESTA_TAG" "$FLORESTA_COMMIT" "$TOOLS_DIR/src/floresta"
  build_path="$PATH"
  if [[ "$os" == "darwin" ]]; then
    boost185="$(brew --prefix boost@1.85 2>/dev/null || true)"
    [[ -d "$boost185/include/boost" ]] || die "Homebrew boost@1.85 is required (brew install boost@1.85)"
    # Bitcoin Core's AddBoostIfNeeded.cmake runs `brew --prefix boost`, and
    # Boost >= 1.90 breaks libbitcoinkernel-sys 0.2.0. Answer it with 1.85.
    shim="$TOOLS_DIR/brew-shim"; mkdir -p "$shim"
    real_brew="$(command -v brew)"
    cat > "$shim/brew" <<EOF
#!/bin/sh
if [ "\$1" = "--prefix" ] && [ "\$2" = "boost" ]; then echo "$boost185"; exit 0; fi
exec "$real_brew" "\$@"
EOF
    chmod +x "$shim/brew"
    build_path="$shim:$PATH"
  fi
  log "building florestad $FLORESTA_TAG"
  (
    cd "$TOOLS_DIR/src/floresta"
    PATH="$build_path" CARGO_TARGET_DIR="$TOOLS_DIR/cargo-target" \
      cargo build --release --locked -p florestad
  )
  cp "$TOOLS_DIR/cargo-target/release/florestad" "$TOOLS_DIR/bin/florestad"
  rm -rf "$TOOLS_DIR/cargo-target"   # ~600 MB of intermediates
fi
log "florestad: $("$TOOLS_DIR/bin/florestad" --version)"

# --- Bitcoin Core (detected, never installed) -------------------------------------
BITCOIND="${BITCOIND_PATH:-$(command -v bitcoind || true)}"
if [[ -n "$BITCOIND" ]]; then
  log "bitcoind: $("$BITCOIND" --version | head -1)"
else
  log "bitcoind not found: wallet-sync tests will be skipped"
fi

cat > "$ENV_FILE" <<EOF
# Generated by tool/regtest/bootstrap.sh — source it before the opt-in tests.
export FLORESTAD_PATH="$TOOLS_DIR/bin/florestad"
export UTREEXOD_PATH="$TOOLS_DIR/bin/utreexod"
${BITCOIND:+export BITCOIND_PATH="$BITCOIND"}
EOF
log "wrote $ENV_FILE"
log "binary hashes:"
for b in "$TOOLS_DIR/bin/florestad" "$TOOLS_DIR/bin/utreexod"; do
  printf '  %s  %s\n' "$(sha256_of "$b")" "$b"
done
