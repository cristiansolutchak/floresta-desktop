#!/usr/bin/env bash
# Builds one standalone florestad release artifact from the PGP-verified
# upstream tag, and checks it before it can be listed in a manifest:
#
#   1. upstream tag signature: VALIDSIG by the pinned primary key;
#   2. tag -> pinned commit;
#   3. build from a `git archive` export (no .git; version from Cargo.toml);
#   4. architecture, minimum OS and dynamic-library allowlist (no /nix,
#      Homebrew or /usr/local paths);
#   5. `--version` prints exactly "florestad v<version>".
#
# Output: $OUT_DIR/florestad-v<version>-<os>-<arch> + build-info.json.
# Nothing is signed or published here.
#
# Usage: tool/release/build_florestad_artifact.sh [rust-target] [out-dir]
#
# Another release: FLORESTA_TAG=v<x.y.z> FLORESTA_COMMIT=<40-hex sha> (both,
# from upstream's release page; the tag must still resolve to that commit
# and be VALIDSIG by the pinned key). .github/workflows/florestad-artifacts.yml
# runs this script that way.
#
# Pinned upstream-master mode (UPS-01): FLORESTA_MASTER_COMMIT=<40-hex sha>
# builds that exact commit instead of the release tag. It must be on
# upstream master and its commit signature must be VALIDSIG by the same
# pinned primary key. master's Cargo.toml (and so `--version`) says 0.9.0,
# so the artifact name and build-info carry the commit.
#   rust-target: aarch64-apple-darwin | x86_64-apple-darwin |
#                x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu
#                (default: the host). Windows is not supported yet.
#
# Verified locally for both macOS targets (2026-10-24) and, through
# build_florestad_linux_in_container.sh, both Linux targets (2026-10-27).
set -euo pipefail

TOOLS_DIR="${FLORESTA_TOOLS_DIR:-$HOME/.cache/floresta-gui-tools}"
FLORESTA_REPO="https://github.com/getfloresta/Floresta.git"
FLORESTA_TAG="${FLORESTA_TAG:-v0.9.1}"
FLORESTA_COMMIT="${FLORESTA_COMMIT:-bc2db8d07e72651f9981ce589c5688f4d575dc7a}"
[[ "$FLORESTA_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  { printf '[artifact] ERROR: FLORESTA_TAG must look like v1.2.3\n' >&2; exit 1; }
[[ "$FLORESTA_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  { printf '[artifact] ERROR: FLORESTA_COMMIT must be a full sha\n' >&2; exit 1; }
FLORESTA_VERSION="${FLORESTA_TAG#v}"
# Davidson Souza; the tag is signed by its subkey ABBB0415…F31869DC3DF97A86.
TAG_SIGNER_PRIMARY="2C8E0F836FD7DBBBB9E9B2EF89964EC3AB22B2E3"
MACOS_MIN="11.0"
MASTER_COMMIT="${FLORESTA_MASTER_COMMIT:-}"
if [[ -n "$MASTER_COMMIT" ]]; then
  [[ "$MASTER_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    { printf '[artifact] ERROR: FLORESTA_MASTER_COMMIT must be a full sha\n' >&2; exit 1; }
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SIGNER_KEY="$HERE/keys/davidson-souza.asc"

log() { printf '\033[1m[artifact]\033[0m %s\n' "$*"; }
die() { printf '[artifact] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

host_target() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo aarch64-apple-darwin ;;
    Darwin-x86_64) echo x86_64-apple-darwin ;;
    Linux-x86_64) echo x86_64-unknown-linux-gnu ;;
    Linux-aarch64) echo aarch64-unknown-linux-gnu ;;
    *) die "unsupported host $(uname -s)-$(uname -m)" ;;
  esac
}

TARGET="${1:-$(host_target)}"
OUT_DIR="${2:-$REPO_ROOT/build/release-artifacts}"
case "$TARGET" in
  aarch64-apple-darwin) os=macos; arch=arm64 ;;
  x86_64-apple-darwin) os=macos; arch=x64 ;;
  x86_64-unknown-linux-gnu) os=linux; arch=x64 ;;
  aarch64-unknown-linux-gnu) os=linux; arch=arm64 ;;
  *) die "unsupported target $TARGET" ;;
esac
[[ "$os" == macos && "$(uname -s)" != Darwin ]] && die "macOS targets build on macOS"
[[ "$os" == linux && "$(uname -s)" != Linux ]] && die "Linux targets build on Linux"

for tool in git gpg cargo cmake; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
if command -v rustup >/dev/null &&
  ! rustup target list --installed | grep -qx "$TARGET"; then
  die "Rust target missing: rustup target add $TARGET"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- 1-2. source: pinned commit, signed tag ---------------------------------------
src="$TOOLS_DIR/src/floresta"
if [[ ! -d "$src/.git" ]]; then
  log "cloning $FLORESTA_REPO"
  git clone --quiet --no-checkout "$FLORESTA_REPO" "$src"
fi
# Isolated keyring: never touches the user's GnuPG state.
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$SIGNER_KEY" 2>/dev/null

if [[ -n "$MASTER_COMMIT" ]]; then
  git -C "$src" fetch --quiet --force origin \
    "+refs/heads/master:refs/remotes/origin/master"
  git -C "$src" merge-base --is-ancestor "$MASTER_COMMIT" origin/master ||
    die "$MASTER_COMMIT is not on upstream master"
  commit="$MASTER_COMMIT"
  status="$(git -C "$src" verify-commit --raw "$commit" 2>&1 || true)"
  source_ref="$commit"
  FLORESTA_VERSION="$(git -C "$src" show "$commit:bin/florestad/Cargo.toml" |
    awk -F'"' '/^version *=/ { print $2; exit }')"
  FLORESTA_TAG="v$FLORESTA_VERSION"           # what --version prints
  ref_label="master@$commit"
  name_ref="v$FLORESTA_VERSION-master-${commit:0:8}"
else
  git -C "$src" fetch --quiet --force origin "refs/tags/$FLORESTA_TAG:refs/tags/$FLORESTA_TAG"
  commit="$(git -C "$src" rev-parse "$FLORESTA_TAG^{commit}")"
  [[ "$commit" == "$FLORESTA_COMMIT" ]] ||
    die "$FLORESTA_TAG points to $commit, expected $FLORESTA_COMMIT"
  status="$(git -C "$src" verify-tag --raw "$FLORESTA_TAG" 2>&1 || true)"
  source_ref="$FLORESTA_TAG"
  ref_label="$FLORESTA_TAG"
  name_ref="$FLORESTA_TAG"
fi
# VALIDSIG <sig-key-fpr> ... <primary-key-fpr> is the last field.
primary="$(printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $NF }')"
[[ "$primary" == "$TAG_SIGNER_PRIMARY" ]] ||
  die "$ref_label is not validly signed by $TAG_SIGNER_PRIMARY"
log "$ref_label signed by $TAG_SIGNER_PRIMARY, commit $commit"

# --- 3. build from an export without .git --------------------------------------------
git -C "$src" archive --format=tar -o "$work/source.tar" "$source_ref"
source_sha="$(sha256_of "$work/source.tar")"
mkdir "$work/src" && tar -xf "$work/source.tar" -C "$work/src"

build_env=(MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN")
build_path="$PATH"
if [[ "$os" == macos ]]; then
  # Boost >= 1.90 breaks libbitcoinkernel-sys 0.2.0 (see tool/regtest/bootstrap.sh).
  boost185="$(brew --prefix boost@1.85 2>/dev/null || true)"
  [[ -d "$boost185/include/boost" ]] || die "Homebrew boost@1.85 is required"
  shim="$work/brew-shim"; mkdir -p "$shim"
  real_brew="$(command -v brew)"
  cat > "$shim/brew" <<EOF
#!/bin/sh
if [ "\$1" = "--prefix" ] && [ "\$2" = "boost" ]; then echo "$boost185"; exit 0; fi
exec "$real_brew" "\$@"
EOF
  chmod +x "$shim/brew"
  build_path="$shim:$PATH"
  # libbitcoinkernel-sys runs cmake without the Rust target; without this the
  # kernel is built for the host architecture and linking fails.
  [[ "$arch" == x64 ]] && build_env+=(CMAKE_OSX_ARCHITECTURES=x86_64)
  [[ "$arch" == arm64 ]] && build_env+=(CMAKE_OSX_ARCHITECTURES=arm64)
fi

target_dir="$TOOLS_DIR/release-target/${name_ref}/$TARGET"
log "building florestad $ref_label for $TARGET"
(
  cd "$work/src"
  env PATH="$build_path" CARGO_TARGET_DIR="$target_dir" "${build_env[@]}" \
    cargo build --release --locked -p florestad --target "$TARGET"
)
bin="$target_dir/$TARGET/release/florestad"
[[ -x "$bin" ]] || die "build produced no binary"

# --- 4. architecture, minimum OS, dynamic libraries -------------------------------------
if [[ "$os" == macos ]]; then
  want_arch="$([[ "$arch" == x64 ]] && echo x86_64 || echo arm64)"
  [[ "$(lipo -archs "$bin")" == "$want_arch" ]] || die "wrong architecture"
  minos="$(vtool -show-build "$bin" | awk '$1 == "minos" { print $2 }')"
  [[ "$minos" == "$MACOS_MIN" ]] || die "minos is $minos, expected $MACOS_MIN"
  libs="$(otool -L "$bin" | tail -n +2 | awk '{ print $1 }')"
  while read -r lib; do
    case "$lib" in
      /usr/lib/*|/System/Library/*) ;;
      *) die "non-system library: $lib" ;;
    esac
  done <<< "$libs"
  min_os="$minos"
else
  libs="$(ldd "$bin" | awk '{ print ($3 ~ /^\//) ? $3 : $1 }')"
  while read -r lib; do
    case "$lib" in
      /nix/*|/usr/local/*|/home/*|/opt/*) die "non-system library: $lib" ;;
    esac
  done <<< "$libs"
  min_os="glibc $(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
fi

# --- 5. version probe ---------------------------------------------------------------
runner=()
if [[ "$os" == macos && "$arch" == x64 && "$(uname -m)" == arm64 ]]; then
  runner=(arch -x86_64)   # Rosetta 2; not proof for real Intel hardware
fi
reported="$(${runner[@]+"${runner[@]}"} "$bin" --version)"  # bash 3.2-safe
[[ "$reported" == "florestad $FLORESTA_TAG" ]] ||
  die "--version printed '$reported', expected 'florestad $FLORESTA_TAG'"

# --- output -----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
name="florestad-$name_ref-$os-$arch"
cp "$bin" "$OUT_DIR/$name"
chmod 755 "$OUT_DIR/$name"
cat > "$OUT_DIR/$name.build-info.json" <<EOF
{
  "artifact": "$name",
  "os": "$os",
  "arch": "$arch",
  "rustTarget": "$TARGET",
  "version": "$FLORESTA_VERSION",
  "upstreamTag": "$FLORESTA_TAG",
  "upstreamRef": "$ref_label",
  "upstreamCommit": "$commit",
  "tagSigner": "$TAG_SIGNER_PRIMARY",
  "sourceTarSha256": "$source_sha",
  "rustc": "$(rustc --version)",
  "minOs": "$min_os",
  "sha256": "$(sha256_of "$OUT_DIR/$name")",
  "size": $(wc -c < "$OUT_DIR/$name" | tr -d ' '),
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log "OK $OUT_DIR/$name ($reported, min $min_os)"
