#!/bin/bash
# Short-lived debug-only credentials. Never modifies a keychain or trust store.
set -euo pipefail
umask 077
[[ $# == 1 && -d "$1" && ! -e "$1/identity.p12" && ! -e "$1/control.key" ]] || {
    echo 'Usage: create_debug_control_identity.sh EMPTY_PRIVATE_DIRECTORY' >&2; exit 1;
}
DEBUG_IDENTITY_DIR="$1"
chmod 700 "$DEBUG_IDENTITY_DIR"
/usr/bin/openssl rand -out "$DEBUG_IDENTITY_DIR/control.key" 32
/usr/bin/openssl base64 -A -in "$DEBUG_IDENTITY_DIR/control.key" -out "$DEBUG_IDENTITY_DIR/identity.pass"
/usr/bin/openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -nodes \
    -keyout "$DEBUG_IDENTITY_DIR/private.pem" -out "$DEBUG_IDENTITY_DIR/certificate.pem" \
    -subj /CN=GetOverHere-Debug-Control -days 1 > "$DEBUG_IDENTITY_DIR/generation.log" 2>&1
/usr/bin/openssl x509 -in "$DEBUG_IDENTITY_DIR/certificate.pem" -outform DER -out "$DEBUG_IDENTITY_DIR/certificate.der"
/usr/bin/openssl dgst -sha256 -binary "$DEBUG_IDENTITY_DIR/certificate.der" > "$DEBUG_IDENTITY_DIR/certificate.sha256"
/usr/bin/openssl pkcs12 -export -inkey "$DEBUG_IDENTITY_DIR/private.pem" -in "$DEBUG_IDENTITY_DIR/certificate.pem" \
    -out "$DEBUG_IDENTITY_DIR/identity.p12" -passout "file:$DEBUG_IDENTITY_DIR/identity.pass"
(( $(wc -c < "$DEBUG_IDENTITY_DIR/control.key") == 32 && $(wc -c < "$DEBUG_IDENTITY_DIR/certificate.sha256") == 32 )) || exit 1
echo 'Ephemeral debug identity created; no certificate installed or trusted.'
