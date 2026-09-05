#!/bin/bash
# Creates a local self-signed code-signing certificate so League Vault keeps the same
# signature across rebuilds. macOS ties Accessibility permission to that signature, so
# without this you must re-grant it after every build.
#
# The certificate is local, self-signed, and used for nothing but signing this app.
# Remove it any time from Keychain Access, or with:
#   security delete-certificate -c "League Vault Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="League Vault Local Signing"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Certificate already exists: $NAME"
    exit 0
fi

cat > "$DIR/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = League Vault Local Signing
[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

echo "Generating a self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/openssl.cnf" 2>/dev/null

# Apple's `security` cannot verify the SHA-256 MAC that modern OpenSSL writes, so the
# bundle has to use the legacy PKCS#12 algorithms — and a non-empty password.
P12PASS="leaguevault"
openssl pkcs12 -export -out "$DIR/bundle.p12" \
    -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
    -passout "pass:$P12PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "Importing into your login keychain (macOS may ask for your password)…"
security import "$DIR/bundle.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12PASS" -A -T /usr/bin/codesign

echo "Trusting it for code signing…"
security add-trusted-cert -d -r trustAsRoot \
    -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$DIR/cert.pem" 2>/dev/null \
    || echo "(trust step skipped — signing usually works regardless)"

echo "Done. build.sh will now sign with: $NAME"
