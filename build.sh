#!/bin/bash
# Build script for ekctl - macOS EventKit CLI tool
#
# Builds, signs with a stable identity, and installs to ~/.local/bin/ekctl.
#
# The signature is load-bearing: TCC ties ekctl's Calendar/Reminders grant to the bundle ID in the
# embedded Info.plist *plus* a stable signing identity. An ad-hoc signature (what the linker leaves
# behind, and what you get if signing fails) has no stable identity, so TCC keys on the cdhash and
# every rebuild looks like a brand-new program — Calendar access is silently revoked. This script
# therefore refuses to install anything it has not verified as properly signed.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="${HOME}/.local/bin/ekctl"
BINARY_PATH="${PROJECT_DIR}/.build/release/ekctl"
ENTITLEMENTS="${PROJECT_DIR}/ekctl.entitlements"
INFO_PLIST="${PROJECT_DIR}/Info.plist"
# Apple Development: <your signing identity> — stable identity, so TCC survives rebuilds.
SIGNING_IDENTITY="${EKCTL_SIGNING_IDENTITY:-}"
EXPECTED_IDENTIFIER="com.ekctl.cli"

AQUA_SERVICE=""
AQUA_PLIST=""
AQUA_LOG=""

cleanup_aqua_signer() {
    if [ -n "$AQUA_SERVICE" ]; then
        launchctl bootout "$AQUA_SERVICE" >/dev/null 2>&1 || true
    fi
    [ -z "$AQUA_PLIST" ] || rm -f "$AQUA_PLIST"
    [ -z "$AQUA_LOG" ] || rm -f "$AQUA_LOG"
    AQUA_SERVICE=""
    AQUA_PLIST=""
    AQUA_LOG=""
}

trap cleanup_aqua_signer EXIT

# codesign cannot reach the login keychain's private key from an SSH audit session; it fails with
# errSecInternalComponent. Re-run the identical codesign invocation as a one-shot launchd job in the
# logged-in Aqua domain, which can. Same approach as spock's scripts/build.sh.
sign_in_aqua_session() {
    local -a cs_args=("$@")
    local uid domain label state exit_code="" plist_base index

    uid="$(id -u)"
    domain="gui/${uid}"
    label="com.ekctl.codesign-once.$$"
    AQUA_SERVICE="${domain}/${label}"

    if ! launchctl print "$domain" >/dev/null 2>&1; then
        echo "Error: no logged-in Aqua session is available at ${domain}." >&2
        return 1
    fi

    # The Aqua domain cannot reliably read an SSH session's private $TMPDIR; /tmp is shared.
    plist_base="$(mktemp "/tmp/ekctl-codesign.XXXXXX")"
    AQUA_PLIST="${plist_base}.plist"
    mv "$plist_base" "$AQUA_PLIST"
    chmod 644 "$AQUA_PLIST"
    AQUA_LOG="${AQUA_PLIST}.log"

    plutil -create xml1 "$AQUA_PLIST"
    plutil -insert Label -string "$label" "$AQUA_PLIST"
    plutil -insert ProgramArguments -array "$AQUA_PLIST"
    plutil -insert ProgramArguments.0 -string /usr/bin/codesign "$AQUA_PLIST"
    index=1
    for arg in "${cs_args[@]}"; do
        plutil -insert "ProgramArguments.${index}" -string "$arg" "$AQUA_PLIST"
        index=$((index + 1))
    done
    plutil -insert StandardOutPath -string "$AQUA_LOG" "$AQUA_PLIST"
    plutil -insert StandardErrorPath -string "$AQUA_LOG" "$AQUA_PLIST"
    plutil -insert RunAtLoad -bool true "$AQUA_PLIST"

    plutil -lint "$AQUA_PLIST" >/dev/null
    if ! launchctl bootstrap "$domain" "$AQUA_PLIST"; then
        echo "Error: launchd rejected the generated Aqua signer job:" >&2
        plutil -p "$AQUA_PLIST" >&2
        cleanup_aqua_signer
        return 1
    fi

    # launchd reports "(never exited)" before the job runs; only a literal numeric last exit code
    # means it finished. Treating the initial state as success would ship an unsigned binary.
    for ((attempt = 0; attempt < 300; attempt++)); do
        state="$(launchctl print "$AQUA_SERVICE" 2>&1 || true)"
        exit_code="$(printf '%s\n' "$state" | sed -nE 's/^[[:space:]]*last exit code = (-?[0-9]+).*$/\1/p' | tail -1)"
        [ -z "$exit_code" ] || break
        sleep 0.1
    done

    if [ -z "$exit_code" ]; then
        echo "Error: Aqua-session codesign did not report completion within 30 seconds." >&2
        [ ! -f "$AQUA_LOG" ] || tail -50 "$AQUA_LOG" >&2
        cleanup_aqua_signer
        return 1
    fi

    if [ "$exit_code" -ne 0 ]; then
        echo "Error: Aqua-session codesign exited with status ${exit_code}." >&2
        [ ! -f "$AQUA_LOG" ] || tail -50 "$AQUA_LOG" >&2
        cleanup_aqua_signer
        return 1
    fi

    cleanup_aqua_signer
}

echo "Building ekctl..."

# Build in release mode, embedding the Info.plist so macOS TCC can persist permissions.
# -sectcreate __TEXT __info_plist embeds the plist into the binary itself (no app bundle needed).
swift build -c release \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "$INFO_PLIST"

echo "Signing binary with a stable identity + entitlements..."
CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$BINARY_PATH")
if ! codesign "${CODESIGN_ARGS[@]}" 2>/dev/null; then
    echo "Direct signing could not access the private key; retrying in the logged-in Aqua session..."
    sign_in_aqua_session "${CODESIGN_ARGS[@]}"
fi

# Prove the signature is the stable one before installing. An ad-hoc signature here means TCC would
# revoke Calendar access on the next run, so this is a hard gate, not a warning.
SIG_INFO="$(codesign -dvvv "$BINARY_PATH" 2>&1)"
if printf '%s\n' "$SIG_INFO" | grep -q 'Signature=adhoc'; then
    echo "Error: binary is ad-hoc signed — refusing to install (this would revoke Calendar access)." >&2
    exit 1
fi
if ! printf '%s\n' "$SIG_INFO" | grep -q "^Identifier=${EXPECTED_IDENTIFIER}$"; then
    echo "Error: expected Identifier=${EXPECTED_IDENTIFIER}; the embedded Info.plist did not take." >&2
    printf '%s\n' "$SIG_INFO" | grep -E '^(Identifier|Authority|Signature)' >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$BINARY_PATH"

# Install by replacing the file, not writing through it: a running ekctl keeps its open inode, and a
# partial write would leave an unsigned binary on disk.
mkdir -p "$(dirname "$INSTALL_PATH")"
cp "$BINARY_PATH" "${INSTALL_PATH}.new"
mv -f "${INSTALL_PATH}.new" "$INSTALL_PATH"

echo ""
echo "Build complete — installed to ${INSTALL_PATH}"
printf '%s\n' "$SIG_INFO" | grep -E '^(Identifier|Authority|TeamIdentifier)' | head -3
