#!/bin/bash
# Builds mutool from the same MuPDF build (if needed) and generates the test
# corpus in build/corpus with tests/corpus/make-corpus.js.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$PWD/build/mupdf/arm64
MUTOOL=$OUT/mutool
if [ ! -x "$MUTOOL" ] || [ thirdparty/mupdf/.git -nt "$MUTOOL" ]; then
    echo "corpus: building mutool"
    make -C thirdparty/mupdf -j"$(sysctl -n hw.ncpu)" build=release barcode=no tesseract=no \
        HAVE_GLUT=no HAVE_X11=no HAVE_CURL=no OUT="$OUT" \
        XCFLAGS="-arch arm64 -mmacosx-version-min=14.0" XLDFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
        "$MUTOOL" > build/mutool.log 2>&1 || { tail -20 build/mutool.log >&2; exit 1; }
    git -C thirdparty/mupdf checkout -q -- generated
fi
mkdir -p build/corpus
"$MUTOOL" run tests/corpus/make-corpus.js build/corpus
