#!/bin/zsh
set -euo pipefail

CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
signing_options=()
if [[ -n "${MACOS_SIGN_KEYCHAIN:-}" ]]; then signing_options+=(--keychain "$MACOS_SIGN_KEYCHAIN"); fi
for binary in true false; do
  cp "/usr/bin/$binary" "$CHECK_DIR/$binary"
  codesign --force --sign "${MACOS_SIGN_IDENTITY:--}" "${signing_options[@]}" --identifier dev.this-is-fine.this-is-logged "$CHECK_DIR/$binary"
  codesign -d -r- "$CHECK_DIR/$binary" 2>&1 | sed -n 's/^designated => //p' > "$CHECK_DIR/$binary.requirement"
done
test -s "$CHECK_DIR/true.requirement"
diff "$CHECK_DIR/true.requirement" "$CHECK_DIR/false.requirement"
grep -q 'anchor\|certificate' "$CHECK_DIR/true.requirement"
codesign --verify --strict -R "$CHECK_DIR/true.requirement" "$CHECK_DIR/false"
echo 'ok: stable certificate-bound signing identity'
