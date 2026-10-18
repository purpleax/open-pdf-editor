#!/bin/bash
# Prints the path of Sparkle's command-line tools (generate_keys,
# sign_update, ...), downloading the official release archive once into
# ~/Library/Caches/open-pdf-editor and checking its SHA-256.
# Keep SPARKLE_VERSION in step with Package.swift.
set -euo pipefail
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DIR=$HOME/Library/Caches/open-pdf-editor/Sparkle-$SPARKLE_VERSION
if [ ! -x "$DIR/bin/sign_update" ]; then
    mkdir -p "$DIR"
    ARCHIVE=$DIR.tar.xz
    curl -fsSL -o "$ARCHIVE" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null \
        || { rm -f "$ARCHIVE"; echo "sparkle-tools: checksum mismatch for Sparkle $SPARKLE_VERSION" >&2; exit 1; }
    tar -xJf "$ARCHIVE" -C "$DIR"
    rm -f "$ARCHIVE"
fi
echo "$DIR/bin"
