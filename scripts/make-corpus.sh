#!/bin/bash
# Generates the test corpus in build/corpus with Tests/Corpus/make-corpus.js
# (building mutool first if needed).
set -euo pipefail
cd "$(dirname "$0")/.."
MUTOOL=$(scripts/build-mutool.sh)
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

# contentzip.pdf: a page whose content is a small deflated stream that
# inflates to 80 MB (over the 64 MB the editor reads).
python3 -I - build/corpus/contentzip.pdf <<'PY'
import sys, zlib
data = zlib.compress(b" " * (80 << 20), 9)
objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
        b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(data) + data + b"\nendstream"]
out = bytearray(b"%PDF-1.7\n")
offsets = []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for o in offsets:
    out += b"%010d 00000 n \n" % o
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1], "wb").write(out)
PY

# signer.p12: a self-signed signing identity (password "test") for the
# signature tests, made once with the system's LibreSSL (whose PKCS#12 the
# Keychain reads).
if [ ! -f build/corpus/signer.p12 ]; then
    tmp=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=Open PDF Editor Test/emailAddress=test@example.com" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -passout pass:test -out build/corpus/signer.p12
    rm -rf "$tmp"
fi

# website.p12: a certificate for a website (serverAuth), not for signing.
if [ ! -f build/corpus/website.p12 ]; then
    tmp=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=bank-secure-docs.example" -addext "extendedKeyUsage=serverAuth" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -passout pass:test -out build/corpus/website.p12
    rm -rf "$tmp"
fi

# email.p12: a certificate for email protection, which may sign documents.
if [ ! -f build/corpus/email.p12 ]; then
    tmp=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=Ada Lovelace/emailAddress=ada@example.com" -addext "extendedKeyUsage=emailProtection" \
        -addext "keyUsage=digitalSignature,nonRepudiation" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -passout pass:test -out build/corpus/email.p12
    rm -rf "$tmp"
fi
