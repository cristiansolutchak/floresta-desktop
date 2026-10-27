#!/usr/bin/env bash
# Runs the app's tests on Linux inside Debian 12 (bookworm), the oldest
# distribution supported: the unit and widget suite, then the full-app clean
# install (integration_test/clean_install_run_test.dart) under Xvfb against
# the release source compiled into the build.
#
#   tool/test_linux_in_container.sh arm64|x64 [production|development] [config.json]
#   SKIP_UNIT=1 ...   only the full-app clean install
#
# The clean install downloads florestad from the configured source (for
# production: the public release repository) and needs regtest's default
# ports inside the container only. x64 runs as linux/amd64 (Rosetta or QEMU on
# Apple Silicon; slow). Flutter 3.35.5 is cached in
# ~/.cache/floresta-gui-tools/flutter-linux-<arch>; the repository is mounted
# read-only and copied, so nothing in the checkout changes.
set -euo pipefail
arch="${1:-}"
case "$arch" in
  arm64) platform=linux/arm64 ;;
  x64) platform=linux/amd64 ;;
  *) echo "usage: $0 arm64|x64 [production|development] [config.json]" >&2; exit 1 ;;
esac
flavor="${2:-production}"
config="${3:-config/release/$flavor.json}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cache="$HOME/.cache/floresta-gui-tools/flutter-linux-$arch"
mkdir -p "$cache"

docker run --rm --platform "$platform" \
  -v "$root:/src:ro" -v "$cache:/cache" \
  -e CONFIG="$config" -e FLUTTER_TAG=3.35.5 -e SKIP_UNIT="${SKIP_UNIT:-}" \
  debian:bookworm bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates git curl \
      unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev \
      liblzma-dev libstdc++-12-dev python3 file xvfb xauth \
      libgl1-mesa-dri libegl1 libgles2 >/dev/null
    if [[ ! -x /cache/flutter/bin/flutter ]]; then
      git clone -q --depth 1 --branch "$FLUTTER_TAG" \
        https://github.com/flutter/flutter.git /cache/flutter
    fi
    export PATH=/cache/flutter/bin:$PATH
    git config --global --add safe.directory /cache/flutter
    flutter config --no-analytics --enable-linux-desktop >/dev/null
    mkdir /work && cd /src
    tar --exclude=./build --exclude=./.dart_tool --exclude=./dist \
      --exclude=./docs --exclude=./macos/Pods -cf - . |
      tar -xf - -C /work
    cd /work
    flutter pub get >/dev/null
    if [[ -z "$SKIP_UNIT" ]]; then
      echo "== unit and widget tests (Linux) =="
      flutter test test -r expanded > /tmp/unit.log 2>&1 || true
      grep -E "\[E\]$" /tmp/unit.log | sed "s#.*/work/##" || true
      tail -1 /tmp/unit.log
    fi
    echo "== full-app clean install (Linux, Xvfb) =="
    export HOME=/root
    xvfb-run -a -s "-screen 0 1440x900x24" \
      flutter test integration_test/clean_install_run_test.dart -d linux \
        "--dart-define-from-file=$CONFIG" \
        --dart-define=FLORESTA_CLEAN_RUN=true > /tmp/full.log 2>&1 || {
          echo "clean install FAILED; last output:"; tail -60 /tmp/full.log; exit 1; }
    grep -E "\[clean-run|All tests" /tmp/full.log
  '
