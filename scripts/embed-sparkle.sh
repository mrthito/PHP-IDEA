#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_DIR="${1:?Usage: embed-sparkle.sh app-directory}"

case "$(uname -m)" in
    arm64) host_triple="arm64-apple-macosx" ;;
    x86_64) host_triple="x86_64-apple-macosx" ;;
    *) print -u2 -- "Unsupported host architecture: $(uname -m)"; exit 1 ;;
esac

# Xcode 26.6 keeps binary artifacts under .build/artifacts. Newer SwiftPM
# scratch-path builds (Xcode 27) put the same xcframework under
# .build/<triple>/artifacts. Packaging must accept both; do not create a
# user toolchain or copy artifacts by hand.
candidates=()
candidates+=("$ROOT_DIR"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N))
candidates+=("$ROOT_DIR"/.build/*/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N))

framework=""
if [[ ${#candidates} -eq 1 ]]; then
    framework="${candidates[1]}"
elif [[ ${#candidates} -gt 1 ]]; then
    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == *"/.build/${host_triple}/artifacts/"* ]]; then
            framework="$candidate"
            break
        fi
    done
    if [[ -z "$framework" ]]; then
        framework="${candidates[1]}"
    fi
fi

if [[ -z "$framework" || ! -d "$framework" ]]; then
    print -u2 -- "Resolve the pinned Sparkle Swift package before packaging."
    print -u2 -- "Looked for Sparkle.framework under .build/artifacts and .build/<triple>/artifacts."
    exit 1
fi

mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
