#!/usr/bin/env sh
# xcross installer — downloads the latest prebuilt binary from GitHub Releases
# and installs it system-wide. No local Dart toolchain required.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
#   # or, pin a version / change install dir:
#   XCROSS_VERSION=v1.2.3 INSTALL_DIR=/usr/local/bin sh install.sh
set -eu

REPO="arxdeus/xcross"
BINARY="xcross"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${XCROSS_VERSION:-latest}"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1"; }

# --- detect OS (releases are Linux-only) -----------------------------------
os="$(uname -s)"
[ "$os" = "Linux" ] || err "xcross prebuilt releases are Linux-only (got: $os). Build from source instead."

# --- detect architecture ---------------------------------------------------
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64)          asset="xcross-linux-x64" ;;
  aarch64 | arm64)         asset="xcross-linux-arm64" ;;
  *) err "unsupported architecture: $arch (supported: x86_64, aarch64)" ;;
esac
info "Detected: $os/$arch -> $asset"

# --- resolve download URL ---------------------------------------------------
if [ "$VERSION" = "latest" ]; then
  url="https://github.com/$REPO/releases/latest/download/$asset"
else
  url="https://github.com/$REPO/releases/download/$VERSION/$asset"
fi

# --- pick a downloader ------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  download() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  download() { wget -qO "$2" "$1"; }
else
  err "need curl or wget to download"
fi

# --- download to a temp file ------------------------------------------------
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
info "Downloading $VERSION binary..."
download "$url" "$tmp" || err "download failed: $url"
[ -s "$tmp" ] || err "downloaded file is empty: $url"
chmod +x "$tmp"

# --- install (use sudo if the target dir is not writable) -------------------
target="$INSTALL_DIR/$BINARY"
if [ -w "$INSTALL_DIR" ] || { [ ! -e "$INSTALL_DIR" ] && mkdir -p "$INSTALL_DIR" 2>/dev/null; }; then
  mv "$tmp" "$target"
elif command -v sudo >/dev/null 2>&1; then
  info "Elevating with sudo to write $target"
  sudo mkdir -p "$INSTALL_DIR"
  sudo mv "$tmp" "$target"
  sudo chmod +x "$target"
else
  err "cannot write to $INSTALL_DIR and sudo is unavailable. Set INSTALL_DIR to a writable path."
fi
trap - EXIT INT TERM

info "Installed: $target"

# --- verify + PATH hint -----------------------------------------------------
if command -v "$BINARY" >/dev/null 2>&1; then
  info "$("$BINARY" --version 2>/dev/null || echo "$BINARY ready")"
else
  info "Installed, but $INSTALL_DIR is not on your PATH. Add it:"
  printf '    export PATH="%s:$PATH"\n' "$INSTALL_DIR"
fi
