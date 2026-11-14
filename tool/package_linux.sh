#!/usr/bin/env bash
# Packages the Linux release build as a .deb and a .tar.gz.
#
#   tool/build_app.sh production      # on Linux
#   tool/package_linux.sh [--out dist]
#
# The .deb declares the runtime libraries the Flutter GTK runner needs
# (GTK 3 and EGL/GLES; without libEGL the app exits at start, observed in a
# clean Debian container on 2026-10-25). Nothing is signed or published.
set -euo pipefail

die() { echo "package_linux: $*" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist"
[[ "${1:-}" == --out ]] && out="$2"
case "$(uname -m)" in
  aarch64) flutter_arch=arm64; deb_arch=arm64 ;;
  x86_64) flutter_arch=x64; deb_arch=amd64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac
bundle="$root/build/linux/$flutter_arch/release/bundle"
[[ -x "$bundle/floresta_gui" ]] || die "no release build at $bundle"
version="$(awk '/^version:/ { split($2, v, "+"); print v[1] }' "$root/pubspec.yaml")"
name="floresta-gui_${version}_${deb_arch}"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pkg="$work/$name"
mkdir -p "$pkg/DEBIAN" "$pkg/opt/floresta-gui" "$pkg/usr/bin" \
  "$pkg/usr/share/applications" "$pkg/usr/share/icons"
cp -R "$bundle/." "$pkg/opt/floresta-gui/"
# The in-app updater checks this against the signed manifest.
echo "$version" > "$pkg/opt/floresta-gui/VERSION"
ln -s /opt/floresta-gui/floresta_gui "$pkg/usr/bin/floresta-gui"
# Every size from tool/brand/render_app_icon.swift (16-512 px).
cp -R "$root/linux/icons/hicolor" "$pkg/usr/share/icons/"
mkdir -p "$pkg/usr/share/doc/floresta-gui"
cp "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$root/README.md" \
  "$pkg/usr/share/doc/floresta-gui/"
cat > "$pkg/usr/share/applications/floresta-gui.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Floresta
Comment=Run and monitor a Floresta Bitcoin node
Exec=/opt/floresta-gui/floresta_gui
Icon=floresta-gui
StartupWMClass=io.github.cristiansolutchak.floresta_gui
Categories=Network;Finance;
Terminal=false
DESKTOP
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: floresta-gui
Version: $version
Architecture: $deb_arch
Maintainer: Floresta GUI <noreply@localhost>
Depends: libgtk-3-0 | libgtk-3-0t64, libegl1, libgles2
Section: net
Priority: optional
Description: Desktop app to install, configure and run a Floresta node
 Installs florestad from a signed source when configured, runs it as a
 child process and shows its state. Watch-only; never handles keys.
CONTROL
dpkg-deb --root-owner-group --build "$pkg" "$out/$name.deb" >/dev/null
# One top-level folder, unpacked anywhere the user owns (for example
# ~/Applications/floresta-gui); the app then updates itself in place
#, and checks VERSION against the signed manifest.
tarroot="$work/tar/floresta-gui"
mkdir -p "$tarroot"
cp -R "$bundle/." "$tarroot/"
echo "$version" > "$tarroot/VERSION"
cp "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$root/README.md" "$tarroot/"
tar -C "$work/tar" -czf "$out/floresta-gui-$version-linux-$flutter_arch.tar.gz" \
  floresta-gui
(cd "$out" && sha256sum "$name.deb" "floresta-gui-$version-linux-$flutter_arch.tar.gz" | tee SHA256SUMS-linux-$flutter_arch)
echo "package_linux: wrote $out/$name.deb"
