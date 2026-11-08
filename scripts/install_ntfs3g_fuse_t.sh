#!/bin/bash
# Builds ntfs-3g against FUSE-T (kext-less FUSE: no kernel extension, no
# Reduced Security, no System Settings approval) and installs it to
# /usr/local/bin/ntfs-3g. MacReader prefers this build when it exists.
#
# Requires FUSE-T first:
#   brew trust --cask macos-fuse-t/cask/fuse-t
#   brew install --cask macos-fuse-t/cask/fuse-t
# FUSE-T is free for personal / non-commercial use (commercial use needs a
# license from its authors). ntfs-3g is GPL.
set -euo pipefail

SRC="${1:-$HOME/Macreader-deps/ntfs-3g}"

if [ ! -f /usr/local/lib/libfuse-t.dylib ] && [ ! -f /usr/local/lib/libfuse-t.a ]; then
  echo "FUSE-T is not installed (no /usr/local/lib/libfuse-t.*). Install it first." >&2
  exit 1
fi

brew install automake autoconf libtool libgcrypt pkg-config gnutls

if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g "$SRC"
fi
cd "$SRC"

export CPPFLAGS="-I/usr/local/include/fuse"
export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"

./autogen.sh
./configure \
  --prefix=/usr/local \
  --exec-prefix=/usr/local \
  --with-fuse=external \
  --sbindir=/usr/local/bin \
  --bindir=/usr/local/bin
make -j"$(sysctl -n hw.ncpu)"
sudo make install

echo
echo "✅ Installed: $(/usr/local/bin/ntfs-3g --version 2>&1 | head -1)"
otool -L /usr/local/bin/ntfs-3g | grep -i fuse || true
