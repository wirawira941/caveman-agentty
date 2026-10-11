#!/usr/bin/env sh
# agentty non-PIE launcher fix for Termux (Android 11, aarch64).
#
# PROBLEM
#   Android 11 refuses to execute non-PIE ELF. agentty 0.9.13-2 as packaged
#   ships a *static* ET_EXEC binary, so launching it dies with:
#
#       error: ".../agentty.bin" has unexpected e_type: 2
#
#   (e_type 2 == ET_EXEC; Android only accepts ET_DYN, i.e. PIE.)
#
# FIX
#   The same .deb also contains a second, correctly-built PIE binary produced
#   under data/... with a different toolchain (NDK r30, dynamic). This script
#   downloads the package, extracts that binary, and installs it over the
#   broken one. It is idempotent and safe to re-run after any package upgrade
#   that reverts the fix.
#
#   The original is backed up to agentty.bin.nonpie-bak, only once.
set -u

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
PKG_DIR="$HOME_DIR/.caveman-agentty/agentty-fix"
TARGET="/data/data/com.termux/files/usr/lib/agentty/agentty.bin"
WRAPPER="/data/data/com.termux/files/usr/bin/agentty"

log()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found: pkg install $1"; }

[ -w "$(dirname "$TARGET")" ] || die "$(dirname "$TARGET") is not writable"

# Nothing to do if the installed binary already launches.
if timeout 10 "$WRAPPER" --version >/dev/null 2>&1; then
  log "agentty already launches; nothing to fix"
  exit 0
fi
log "agentty fails to launch (non-PIE binary); fixing"

# Prefer the previously extracted copy if it is still good, so the fix works
# offline after the first run.
CACHED="$PKG_DIR/agentty.bin"
mkdir -p "$PKG_DIR"

if [ ! -s "$CACHED" ] || ! timeout 10 "$CACHED" --version >/dev/null 2>&1; then
  need ar; need tar; need curl
  cd "$PKG_DIR" || die "cannot cd to $PKG_DIR"

  # Fetch the package. apt-get download honours the configured repos; fall back
  # to the maintainer's own repo if the local apt metadata is unavailable.
  log "downloading agentty package"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get download agentty >/dev/null 2>&1 || true
  fi
  if ! ls *.deb >/dev/null 2>&1; then
    curl -fsSL -o agentty.deb \
      "https://twilight0.github.io/termux-repo/pool/stable/main/a/agentty/agentty_0.9.13-2_aarch64.deb" \
      || die "could not download agentty package"
  fi

  DEB=$(ls -1 *.deb | head -1)
  [ -n "$DEB" ] || die "no .deb found in $PKG_DIR"
  log "extracting from $DEB"

  ar x "$DEB" 2>/dev/null || die "ar x failed"
  tar xf data.tar.* 2>/dev/null || die "tar extraction failed"

  NEW=$(find . -path '*/agentty/agentty.bin' -type f | head -1)
  [ -n "$NEW" ] || die "agentty.bin not found inside the package"

  # Guard: only adopt a PIE (ET_DYN) image. e_type is a 16-bit little-endian
  # value at ELF offset 0x10; 0300 == ET_DYN, 0200 == ET_EXEC.
  ETYPE=$(xxd -s 16 -l 2 "$NEW" 2>/dev/null | awk '{print $2}')
  [ "$ETYPE" = "0300" ] || die "package binary is not PIE (e_type=$ETYPE); aborting"

  cp -p "$NEW" "$CACHED" || die "could not stage $CACHED"
  rm -rf data control.tar.* data.tar.* debian-binary
fi

# Back up the original broken binary exactly once.
if [ ! -f "$TARGET.nonpie-bak" ]; then
  cp -p "$TARGET" "$TARGET.nonpie-bak" 2>/dev/null || true
fi

install -m 755 "$CACHED" "$TARGET" || die "could not install $TARGET"
log "installed PIE binary at $TARGET"

# The wrapper sets LD_LIBRARY_PATH for the dynamic build; keep it correct.
timeout 10 "$WRAPPER" --version >/dev/null 2>&1 \
  && log "agentty now launches: $(timeout 10 "$WRAPPER" --version 2>&1 | head -1)" \
  || die "installed binary still does not launch"
