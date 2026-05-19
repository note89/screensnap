#!/usr/bin/env bash
# One-time setup: create a self-signed code-signing certificate so every
# rebuild produces a binary with the same cryptographic identity. macOS TCC
# binds permissions (Screen Recording, Accessibility, Microphone, etc.) to
# this identity — so after running this script, you only need to grant
# Screen Recording permission once and it survives every future rebuild.
#
# To remove the cert later:
#   security delete-certificate -c "GifRecorder Dev"
#
# To check it exists:
#   security find-certificate -c "GifRecorder Dev"

set -euo pipefail

CERT_NAME="GifRecorder Dev"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "✓ Certificate '$CERT_NAME' already exists in your login keychain."
    echo "  Nothing to do. Run ./Scripts/build-app.sh to rebuild signed with it."
    exit 0
fi

WORK_DIR="$(mktemp -d -t gifrecorder-signing-XXXX)"
trap "rm -rf '$WORK_DIR'" EXIT
cd "$WORK_DIR"

# Use Apple's bundled LibreSSL — its PKCS#12 output is always accepted by
# macOS's `security` tool. Homebrew's openssl 3 produces files that
# `security` rejects with "MAC verification failed" even with `-legacy`.
OPENSSL=/usr/bin/openssl

echo "→ Generating private key"
"$OPENSSL" genrsa -out key.pem 2048 2>/dev/null

echo "→ Generating self-signed code-signing certificate (valid 10 years)"
"$OPENSSL" req -new -x509 -key key.pem -out cert.pem \
    -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    2>/dev/null

echo "→ Packaging into PKCS#12 bundle"
# macOS's `security` tool refuses empty-password PKCS12 files even when the
# bundle is otherwise valid. We use a throwaway password just for the
# import handshake — the key has no password once it lands in the keychain.
P12_PW="$(/usr/bin/openssl rand -hex 12)"
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem \
    -out bundle.p12 -name "$CERT_NAME" -passout "pass:$P12_PW" 2>/dev/null

echo "→ Importing into login keychain (pre-authorizing /usr/bin/codesign)"
# Import the cert + private key together. `-T` pre-authorizes codesign;
# don't pass `-A` (which means "no ACL") — combining them breaks the
# key→cert pairing so `find-identity` reports zero identities.
security import bundle.p12 \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PW" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -f pkcs12 >/dev/null

# Belt-and-suspenders: explicitly add codesign to the partition list so the
# pre-auth above survives macOS keychain migrations.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

echo
echo "✓ Created '$CERT_NAME' code-signing cert in your login keychain."
echo "  Future rebuilds will sign with it, and macOS will treat them as the"
echo "  same app — so Screen Recording permission persists across builds."
echo
echo "Next: rebuild and re-grant Screen Recording permission ONE more time."
echo "  ./Scripts/build-app.sh"
