#!/usr/bin/env bash
# Builds and packages the Linux app inside Debian 12 (bookworm), the oldest
# distribution supported, so the binaries do not need a newer glibc/GLib
# than it has. A build made on Ubuntu 24.04 failed on Debian 12 with
# "undefined symbol: g_once_init_enter_pointer" (2026-10-25).
#
#   tool/build_linux_in_container.sh [production|development] [config.json]
#
# Needs Docker. Uses Flutter 3.35.5 from its git tag, the repository mounted
# read-only, and writes dist/ (deb + tar.gz for the host architecture).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
flavor="${1:-production}"
config="${2:-config/release/$flavor.json}"
flutter_tag="3.35.5"
mkdir -p "$root/dist"

docker run --rm \
  -v "$root:/src:ro" -v "$root/dist:/out" \
  -e FLAVOR="$flavor" -e CONFIG="$config" -e FLUTTER_TAG="$flutter_tag" \
  debian:bookworm bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates git curl \
      unzip xz-utils zip clang cmake ninja-build pkg-config libgtk-3-dev \
      liblzma-dev libstdc++-12-dev python3 file >/dev/null
    git clone -q --depth 1 --branch "$FLUTTER_TAG" \
      https://github.com/flutter/flutter.git /opt/flutter
    export PATH=/opt/flutter/bin:$PATH
    git config --global --add safe.directory /opt/flutter
    flutter config --no-analytics --enable-linux-desktop >/dev/null
    mkdir /work && cd /src
    tar --exclude=./build --exclude=./.dart_tool --exclude=./dist \
      --exclude=./docs --exclude=./macos/Pods -cf - . |
      tar -xf - -C /work
    cd /work
    flutter pub get >/dev/null
    bash tool/build_app.sh "$FLAVOR" "$CONFIG"
    bash tool/package_linux.sh --out /out
  '
