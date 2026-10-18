#!/bin/bash
# Writes the licences of Open PDF Editor and everything it includes, for the
# app's Resources (Acknowledgements.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
M=thirdparty/mupdf
section() {
    printf '\n\n==============================================================================\n%s\n==============================================================================\n\n' "$1"
    cat "$2"
}
echo "Open PDF Editor is free software: you can redistribute it and/or modify it"
echo "under the terms of the GNU Affero General Public License, version 3."
echo "Source code: https://github.com/purpleax/open-pdf-editor"
echo
echo "It includes MuPDF (Artifex Software, AGPL-3.0) and the libraries below."
section "Open PDF Editor and MuPDF: GNU Affero General Public License 3.0" LICENSE
section "Brotli" $M/thirdparty/brotli/LICENSE
section "cmark-gfm" $M/thirdparty/cmark-gfm/COPYING
section "extract" $M/thirdparty/extract/COPYING
section "FreeType" $M/thirdparty/freetype/LICENSE.TXT
section "Gumbo" $M/thirdparty/gumbo-parser/COPYING
section "HarfBuzz" $M/thirdparty/harfbuzz/COPYING
section "jbig2dec" $M/thirdparty/jbig2dec/COPYING
section "Little CMS" $M/thirdparty/lcms2/LICENSE
section "libjpeg (Independent JPEG Group)" $M/thirdparty/libjpeg/README
section "MuJS" $M/thirdparty/mujs/COPYING
section "OpenJPEG" $M/thirdparty/openjpeg/LICENSE
section "zlib" $M/thirdparty/zlib/LICENSE
section "Fonts: URW base 14 (SIL Open Font License)" $M/resources/fonts/urw/OFL.txt
section "Fonts: Noto" $M/resources/fonts/noto/COPYING
section "Fonts: Source Han" $M/resources/fonts/han/LICENSE.txt
section "Fonts: Droid Sans Fallback (Apache 2.0)" $M/resources/fonts/droid/NOTICE
section "Fonts: SIL" $M/resources/fonts/sil/OFL.txt
section "Sparkle" .build/checkouts/Sparkle/LICENSE
