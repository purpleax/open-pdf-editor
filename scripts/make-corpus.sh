#!/bin/bash
# Builds mutool from the same MuPDF build (if needed) and generates the test
# corpus in build/corpus with Tests/Corpus/make-corpus.js.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$PWD/build/mupdf/arm64
MUTOOL=$OUT/mutool
mkdir -p build
if [ ! -x "$MUTOOL" ] || [ thirdparty/mupdf/.git -nt "$MUTOOL" ]; then
    echo "corpus: building mutool"
    make -C thirdparty/mupdf -j"$(sysctl -n hw.ncpu)" build=release barcode=no tesseract=no \
        HAVE_GLUT=no HAVE_X11=no HAVE_CURL=no OUT="$OUT" \
        XCFLAGS="-arch arm64 -mmacosx-version-min=14.0" XLDFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
        "$MUTOOL" > build/mutool.log 2>&1 || { tail -20 build/mutool.log >&2; exit 1; }
    git -C thirdparty/mupdf checkout -q -- generated
fi
mkdir -p build/corpus
"$MUTOOL" run Tests/Corpus/make-corpus.js build/corpus

# lazy.pdf: damage one xref entry (the last object, on page 3) so MuPDF only
# finds out, and repairs the file, when that page is used.
python3 -I - build/corpus/lazy-source.pdf build/corpus/lazy.pdf <<'PY'
import re, sys
data = bytearray(open(sys.argv[1], "rb").read())
start = data.rindex(b"\nxref")
entries = list(re.finditer(rb"(\d{10}) (\d{5}) n", data[start:]))
last = entries[-1]
offset = start + last.start(1)
data[offset:offset + 10] = b"%010d" % 5   # points into the header
open(sys.argv[2], "wb").write(data)
PY
rm -f build/corpus/lazy-source.pdf
