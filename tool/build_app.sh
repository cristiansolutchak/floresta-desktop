#!/usr/bin/env bash
# Builds the desktop app for one flavour with its release configuration.
#
#   tool/build_app.sh production            # config/release/production.json
#   tool/build_app.sh development [config]  # default config/release/development.json
#
# Production builds refuse any development key or development flavour in
# their configuration (SEC-06), and say plainly when automatic installation
# will be unavailable (no manifest URL or no production key compiled in).
# Builds for the host OS only. Signing and packaging: tool/package_macos.sh.
set -euo pipefail

die() { echo "build_app: $*" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
flavor="${1:-}"
[[ "$flavor" == production || "$flavor" == development ]] ||
  die "usage: $0 production|development [config.json]"
config="${2:-$root/config/release/$flavor.json}"
[[ -f "$config" ]] || die "missing $config (see config/release/*.example.json)"

value() { # value KEY -> string value from the JSON config, or empty
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
    "$config" "$1"
}

[[ "$(value FLORESTA_FLAVOR)" == "$flavor" ]] ||
  die "$config sets FLORESTA_FLAVOR=$(value FLORESTA_FLAVOR), expected $flavor"

if [[ "$flavor" == production ]]; then
  [[ -z "$(value FLORESTA_DEV_RELEASE_KEY)" ]] ||
    die "a production configuration must not carry FLORESTA_DEV_RELEASE_KEY"
  url="$(value FLORESTA_RELEASE_MANIFEST_URL)"
  [[ -z "$url" || "$url" == https://* ]] ||
    die "production manifest URL must be https: $url"
  if [[ -z "$url" ]]; then
    echo "build_app: note: no release manifest URL; this build offers no automatic install" >&2
  fi
  if ! grep -v '^[[:space:]]*//' "$root/lib/features/installation/data/release_keys.dart" |
    grep -q 'TrustedReleaseKey('; then
    echo "build_app: note: no production release key compiled in; automatic install stays off" >&2
  fi
fi

case "$(uname -s)" in
  Darwin) target=macos ;;
  Linux) target=linux ;;
  *) die "unsupported host $(uname -s)" ;;
esac

cd "$root"
flutter build "$target" --release --dart-define-from-file="$config"
echo "build_app: built $flavor for $target"
