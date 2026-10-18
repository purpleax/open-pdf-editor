#!/bin/bash
# Checks out the MuPDF submodules the build uses. Tesseract, Leptonica,
# zxing-cpp, zint, curl and freeglut are left out (see build-mupdf.sh).
set -euo pipefail
cd "$(dirname "$0")/../thirdparty/mupdf"
git submodule update --init --depth 1 \
    thirdparty/brotli thirdparty/cmark-gfm thirdparty/extract thirdparty/freetype \
    thirdparty/gumbo-parser thirdparty/harfbuzz thirdparty/jbig2dec thirdparty/lcms2 \
    thirdparty/libjpeg thirdparty/mujs thirdparty/openjpeg thirdparty/zlib
