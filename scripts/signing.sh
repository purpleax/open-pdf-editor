# Signing settings, sourced by the other scripts. They come from
# scripts/signing.env (not in git; copy signing.env.example):
#   SIGN_ID         codesign identity, e.g. "Developer ID Application: Name (TEAMID)";
#                   "-" (the default, for contributors without one) signs ad hoc
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials)
# OPDF_SIGN_ID / OPDF_NOTARY_PROFILE in the environment override them.
SIGN_ID=-
NOTARY_PROFILE=
if [ -f scripts/signing.env ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            SIGN_ID) SIGN_ID=$value ;;
            NOTARY_PROFILE) NOTARY_PROFILE=$value ;;
        esac
    done < <(grep -E '^(SIGN_ID|NOTARY_PROFILE)=' scripts/signing.env)
fi
SIGN_ID=${OPDF_SIGN_ID:-$SIGN_ID}
NOTARY_PROFILE=${OPDF_NOTARY_PROFILE:-$NOTARY_PROFILE}
# Notarize only with a real identity and a notary profile.
NOTARIZE=0
[ "$SIGN_ID" != "-" ] && [ -n "$NOTARY_PROFILE" ] && NOTARIZE=1

# A real identity also gets the hardened runtime and a secure timestamp,
# which notarization requires.
if [ "$SIGN_ID" = "-" ]; then
    SIGN_FLAGS=()
else
    SIGN_FLAGS=(--options runtime --timestamp)
fi

# Fails early when the identity or notary profile isn't usable.
check_signing() {
    [ "$SIGN_ID" = "-" ] && return 0
    security find-identity -v -p codesigning | grep -qF "\"$SIGN_ID\"" \
        || { echo "signing: identity not in the keychain: $SIGN_ID" >&2; return 1; }
    if [ "$NOTARIZE" = 1 ]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
            || { echo "signing: notary profile \"$NOTARY_PROFILE\" doesn't work (xcrun notarytool store-credentials)" >&2; return 1; }
    fi
}

sign() { codesign --force --sign "$SIGN_ID" "${SIGN_FLAGS[@]}" "$@"; }
