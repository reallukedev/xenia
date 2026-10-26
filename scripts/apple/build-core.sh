#!/bin/zsh
# Builds xenia-core (the shared Rust engine) for the platform Xcode is building, and regenerates
# its Swift bindings when the Rust changed. Runs as the first build phase of the XeniaCore
# framework; also works by hand:
#
#   PLATFORM_NAME=macosx CONFIGURATION=Debug scripts/apple/build-core.sh
#
# The library lands in target/<triple>/<debug|release>/libxenia_core.a, which the apps link.
set -euo pipefail

ROOT="${0:A:h:h:h}"
PLATFORM="${PLATFORM_NAME:-macosx}"
CONFIG="${CONFIGURATION:-Debug}"
GENERATED="$ROOT/apple/XeniaCore/Generated"

# A fixed PATH: Xcode's puts its toolchain's bare clang first, which has no default SDK.
export PATH="$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

case "$PLATFORM" in
  macosx) TARGET=aarch64-apple-darwin ;;
  iphoneos) TARGET=aarch64-apple-ios ;;
  iphonesimulator) TARGET=aarch64-apple-ios-sim ;;
  *) echo "error: xenia-core has no Rust target for platform '$PLATFORM'" >&2; exit 1 ;;
esac

if [[ "$CONFIG" == Release ]]; then
  PROFILE_ARGS=(--release); PROFILE_DIR=release
else
  PROFILE_ARGS=(); PROFILE_DIR=debug
fi

# Cargo runs in a clean environment: Xcode's describes the app's SDK, which build scripts
# compiled for this Mac must not see, and an identical environment every time keeps cargo's
# fingerprints stable between Xcode and command-line builds. Deployment targets are explicit.
clean_cargo() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 \
    IPHONEOS_DEPLOYMENT_TARGET=26.0 IPHONESIMULATOR_DEPLOYMENT_TARGET=26.0 MACOSX_DEPLOYMENT_TARGET=26.0 \
    ${XENIA_LOG:+XENIA_LOG="$XENIA_LOG"} cargo "$@"
}

cd "$ROOT"
clean_cargo build -p xenia-core --lib --target "$TARGET" "${PROFILE_ARGS[@]}"

LIB="$ROOT/target/$TARGET/$PROFILE_DIR/libxenia_core.a"
STAMP="$GENERATED/.source"

# Bindings: regenerated only when the library changed, so Swift doesn't recompile needlessly.
if [[ ! -f "$GENERATED/XeniaCore.swift" || ! -f "$STAMP" || "$LIB" -nt "$STAMP" ]]; then
  clean_cargo build -p uniffi-bindgen --quiet
  OUT="$(mktemp -d)"
  "$ROOT/target/debug/uniffi-bindgen" generate --library "$LIB" --language swift --out-dir "$OUT" >/dev/null
  mkdir -p "$GENERATED/include"
  # Only touch files whose content changed.
  for pair in "XeniaCore.swift:XeniaCore.swift" "XeniaCoreFFI.h:include/XeniaCoreFFI.h" "XeniaCoreFFI.modulemap:include/module.modulemap"; do
    src="$OUT/${pair%%:*}"; dst="$GENERATED/${pair##*:}"
    if ! cmp -s "$src" "$dst" 2>/dev/null; then cp "$src" "$dst"; fi
  done
  rm -rf "$OUT"
  touch "$STAMP"
fi
