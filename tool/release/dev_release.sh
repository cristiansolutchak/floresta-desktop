#!/usr/bin/env bash
# Serves a development release of florestad on http://127.0.0.1:8787 so a
# development build of the app (config/release/development.json) installs
# Floresta automatically, without the terminal. Used by VS Code's
# "Floresta (development)" launch configuration; also runnable by hand:
#
#   tool/release/dev_release.sh            # prepare and serve (Ctrl-C stops)
#   tool/release/dev_release.sh --prepare  # prepare only
#
# One-time steps, then cached:
#   1. a development signing key outside the repository
#      ($FLORESTA_DEV_HOME/dev-release-key.hex, mode 600);
#   2. the florestad artifact for this Mac, built from the PGP-verified
#      upstream tag by build_florestad_artifact.sh (several minutes);
#   3. config/release/development.json (gitignored) with the key's public
#      half.
# Every run signs a fresh manifest with a newer serial, so the app's
# anti-rollback check accepts it. Development key only: a production build
# never trusts it, and it is honoured only for a loopback URL.
set -euo pipefail

log() { printf '\033[1m[dev-release]\033[0m %s\n' "$*"; }
die() { printf '[dev-release] ERROR: %s\n' "$*" >&2; exit 1; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
home="${FLORESTA_DEV_HOME:-$HOME/.config/floresta-gui-dev}"
artifacts="${FLORESTA_ARTIFACT_DIR:-$HOME/.cache/floresta-gui-tools/release-artifacts}"
port="${FLORESTA_DEV_RELEASE_PORT:-8787}"
key="$home/dev-release-key.hex"
release="$home/release"
config="$root/config/release/development.json"
tool=(dart run "$root/tool/release/release_tool.dart")

mkdir -p "$home" "$artifacts"
chmod 700 "$home"
cd "$root"

# 1. Development key (never inside the repository).
if [[ ! -f "$key" ]]; then
  log "creating a development signing key in $key"
  "${tool[@]}" keygen --out "$key" >/dev/null
fi
pub="$("${tool[@]}" pubkey --key "$key")"

# 2. The florestad artifact for this machine.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) target=aarch64-apple-darwin; name=macos-arm64 ;;
  Darwin-x86_64) target=x86_64-apple-darwin; name=macos-x64 ;;
  Linux-x86_64) target=x86_64-unknown-linux-gnu; name=linux-x64 ;;
  Linux-aarch64) target=aarch64-unknown-linux-gnu; name=linux-arm64 ;;
  *) die "unsupported host $(uname -s)-$(uname -m)" ;;
esac
if ! ls "$artifacts"/florestad-v*-"$name".build-info.json >/dev/null 2>&1; then
  log "building the florestad artifact for $name (one time, several minutes)"
  tool/release/build_florestad_artifact.sh "$target" "$artifacts"
fi

# 3. Fresh release directory with a newer serial than any before.
rm -rf "$release"
mkdir -p "$release"
for f in "$artifacts"/florestad-v*-"$name" "$artifacts"/florestad-v*-"$name".build-info.json; do
  cp "$f" "$release/"
done
"${tool[@]}" manifest --artifacts "$release" --serial "$(date +%s)" --valid-days 30 >/dev/null
"${tool[@]}" sign --artifacts "$release" --key "$key" --key-id dev >/dev/null

# 4. App configuration for development builds (gitignored).
cat > "$config" <<JSON
{
  "FLORESTA_FLAVOR": "development",
  "FLORESTA_RELEASE_MANIFEST_URL": "http://127.0.0.1:$port/manifest.json",
  "FLORESTA_RELEASE_REDIRECT_HOSTS": "",
  "FLORESTA_DEV_RELEASE_KEY": "$pub"
}
JSON
log "release ready: $(ls "$release" | grep -v json | tr '\n' ' ')"

[[ "${1:-}" == --prepare ]] && exit 0

if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  # A second launch: the running server serves this same folder, which now
  # holds the fresh manifest. Anything else on the port is an error.
  if curl -fsS "http://127.0.0.1:$port/manifest.json" | grep -q '"payload"'; then
    echo "serving $release on http://127.0.0.1:$port/ (already running)"
    exit 0
  fi
  die "port $port is busy with something else; set FLORESTA_DEV_RELEASE_PORT"
fi
exec "${tool[@]}" serve --artifacts "$release" --port "$port"
