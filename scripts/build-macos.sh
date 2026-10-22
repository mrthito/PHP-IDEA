#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="debug"
TRIPLE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        --triple) TRIPLE="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 [--configuration debug|release] [--triple triple]"; exit 2 ;;
    esac
done

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
    print -u2 -- "Unsupported configuration: $CONFIGURATION"
    exit 2
fi

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/verify-macos-app-build-safety.sh"
"$ROOT_DIR/scripts/build-editor.sh"

RUST_TARGET=""
if [[ -n "$TRIPLE" ]]; then
    case "$TRIPLE" in
        arm64-apple-macosx) RUST_TARGET="aarch64-apple-darwin" ;;
        x86_64-apple-macosx) RUST_TARGET="x86_64-apple-darwin" ;;
        *) print -u2 -- "Unsupported macOS Swift triple: $TRIPLE"; exit 2 ;;
    esac
fi

RUST_BUILD_ARGS=()
if [[ "$CONFIGURATION" == "release" ]]; then
    RUST_BUILD_ARGS+=(--release)
    # Swift 6.2 can crash while emitting round-trip debug types for the
    # optimized DiffSplitLayout.plan function on the macOS release runner.
    SWIFT_CONFIGURATION_ARGS=(
        --configuration release
        -Xswiftc -Xfrontend
        -Xswiftc -disable-round-trip-debug-types
    )
else
    RUST_BUILD_ARGS+=(--debug)
    # Swift 6.2 can crash while emitting round-trip debug types for the
    # existing DiffSplitLayout.plan function, even in a debug preview build.
    # Keep preview builds aligned with the release workaround below so the
    # app can be launched locally with ./scripts/preview.sh.
    SWIFT_CONFIGURATION_ARGS=(
        -Xswiftc -Xfrontend
        -Xswiftc -disable-round-trip-debug-types
    )
fi

if ! /usr/bin/xcrun ld -help 2>&1 | /usr/bin/grep -q -- '-no_warn_duplicate_libraries'; then
    SWIFT_CONFIGURATION_ARGS+=(
        -Xswiftc "-ld-path=$ROOT_DIR/scripts/ld-macos13-compat.sh"
    )
fi

if [[ -n "$RUST_TARGET" ]]; then
    RUST_BUILD_ARGS+=(--target "$RUST_TARGET")
fi
RUST_LIBRARY="$(scripts/build-rust-core.sh "${RUST_BUILD_ARGS[@]}")"

SWIFT_ARGS=(build --disable-sandbox)
if [[ -n "$TRIPLE" ]]; then
    # Newer SwiftPM layouts put all --triple products below .build/out. Use a
    # per-architecture scratch path only for that layout; SwiftPM versions
    # used by the repository baseline already isolate the triple themselves.
    SWIFT_LAYOUT_ARGS=(--configuration "$CONFIGURATION" --triple "$TRIPLE")
    SWIFT_BIN_PATH="$(swift build --show-bin-path "${SWIFT_LAYOUT_ARGS[@]}")"
    if [[ "$SWIFT_BIN_PATH" == */out/Products/* ]]; then
        SWIFT_ARGS+=(--scratch-path "$ROOT_DIR/.build/$TRIPLE")
    fi
fi
SWIFT_ARGS+=("${SWIFT_CONFIGURATION_ARGS[@]}")
SWIFT_ARGS+=(
    -Xcc -include
    -Xcc "$ROOT_DIR/scripts/MacOS13SDKCompatibility.h"
)
if [[ -n "$TRIPLE" ]]; then
    SWIFT_ARGS+=(--triple "$TRIPLE")
fi
SWIFT_ARGS+=(-Xlinker -force_load -Xlinker "$RUST_LIBRARY")

# Xcode 26+ ships `metal` as a stub. SwiftTerm compiles Shaders.metal during
# the product build, so a missing Metal toolchain becomes an opaque
# CompileMetalFile failure minutes later. Fail here with the install command.
metal_probe_status=0
metal_probe_output="$(/usr/bin/xcrun metal --help 2>&1)" || metal_probe_status=$?
if [[ "$metal_probe_status" -ne 0 ]] && print -r -- "$metal_probe_output" | /usr/bin/grep -Fq -- 'missing Metal Toolchain'; then
    print -u2 -- "Xcode's Metal toolchain is not installed. SwiftTerm compiles Shaders.metal during the macOS build."
    print -u2 -- "Install it once with: xcodebuild -downloadComponent MetalToolchain"
    print -u2 -- "Then rerun the macOS build."
    exit 1
fi

user_metal_toolchain="$HOME/Library/Developer/Toolchains/Metal.xctoolchain"
user_metal_compiler="$user_metal_toolchain/usr/bin/metal"
if [[ -x "$user_metal_compiler" ]]; then
    USER_METAL_TOOLCHAIN_STATE="present"
elif [[ -e "$user_metal_toolchain" || -L "$user_metal_toolchain" ]]; then
    USER_METAL_TOOLCHAIN_STATE="broken"
else
    USER_METAL_TOOLCHAIN_STATE="absent"
fi
METAL_COMPONENT_IDENTITY="$(
    /usr/bin/xcodebuild -showComponent metalToolchain 2>/dev/null \
        | /usr/bin/grep -E '^(Build Version|Status|Toolchain Identifier):' \
        || true
)"

# SwiftPM can reuse binary modules produced by an incompatible compiler after
# an Xcode/toolchain upgrade. Keep the full compiler identity, including its
# build number, and let SwiftPM clean build products while retaining checkouts.
# Also stamp the Metal component and any user Metal.xctoolchain: XCBuild caches
# that absolute metal path, and a removed or remounted toolchain then fails
# with "unable to spawn process .../metal (No such file or directory)".
SWIFT_TOOLCHAIN_VERSION="$(swift --version)"
if [[ -n "${SWIFT_EXEC:-}" ]]; then
    SWIFT_TOOLCHAIN_VERSION+=$'\n'"$("$SWIFT_EXEC" --version)"
fi
SWIFT_TOOLCHAIN_VERSION+=$'\n'"Metal component:"$'\n'"$METAL_COMPONENT_IDENTITY"
SWIFT_TOOLCHAIN_VERSION+=$'\n'"User Metal toolchain: $USER_METAL_TOOLCHAIN_STATE"
SWIFT_TOOLCHAIN_STAMP="$ROOT_DIR/.build/.lithe-swift-toolchain"
PREVIOUS_SWIFT_TOOLCHAIN_VERSION=""
if [[ -f "$SWIFT_TOOLCHAIN_STAMP" ]]; then
    PREVIOUS_SWIFT_TOOLCHAIN_VERSION="$(<"$SWIFT_TOOLCHAIN_STAMP")"
fi
needs_swift_clean=false
if [[ -d "$ROOT_DIR/.build" && "$PREVIOUS_SWIFT_TOOLCHAIN_VERSION" != "$SWIFT_TOOLCHAIN_VERSION" ]]; then
    needs_swift_clean=true
    if [[ -n "$PREVIOUS_SWIFT_TOOLCHAIN_VERSION" ]]; then
        print -- "Swift or Metal toolchain changed; cleaning incompatible SwiftPM build products."
    else
        # Existing caches predate this stamp, so their compiler is unknown.
        print -- "Swift compiler cache version is unknown; cleaning SwiftPM build products once."
    fi
elif [[ "$USER_METAL_TOOLCHAIN_STATE" != "present" ]] \
    && /usr/bin/grep -Rql -- 'Library/Developer/Toolchains/Metal.xctoolchain' "$ROOT_DIR/.build" 2>/dev/null; then
    needs_swift_clean=true
    print -- "Stale Metal user-toolchain path in SwiftPM build cache; cleaning."
fi
if [[ "$needs_swift_clean" == true ]]; then
    SWIFT_CLEAN_ARGS=()
    if (( idx = ${SWIFT_ARGS[(I)--scratch-path]} )); then
        SWIFT_CLEAN_ARGS+=(--scratch-path "${SWIFT_ARGS[idx+1]}")
    fi
    swift package clean "${SWIFT_CLEAN_ARGS[@]}"
fi
mkdir -p "$ROOT_DIR/.build"
# Record only after cleaning succeeds; failed builds can safely resume with
# this compiler without discarding their newly compiled modules.
print -r -- "$SWIFT_TOOLCHAIN_VERSION" > "$SWIFT_TOOLCHAIN_STAMP"
swift "${SWIFT_ARGS[@]}"
