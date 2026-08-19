# Shared helpers for the mise tasks in mise-tasks/. Source it, don't run it:
#
#     source "$MISE_PROJECT_ROOT/Tools/dal.sh"
#
# Everything the build/test/publish tasks need to know about "which models does
# this repo have and what does each one ship" is derived here, from the
# filesystem, so adding a model is adding directories - never editing a list.
#
#   Sources/<Product>/Catalog.swift   the model exists
#   packages/<model>-node/            it ships an npm package
#   packages/<model>-kotlin/          it ships a Maven AAR
#
# shellcheck shell=bash

set -euo pipefail

DAL_ROOT="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$DAL_ROOT"

# ---------------------------------------------------------------- models

# Every model in the repo, lowercase, e.g. "clear emo redact".
dal_models() {
    local dir
    for dir in Sources/*/Catalog.swift; do
        [ -f "$dir" ] || continue
        basename "$(dirname "$dir")" | tr '[:upper:]' '[:lower:]'
    done | sort
}

# Models that ship the given platform package: dal_models_with node|kotlin.
dal_models_with() {
    local model
    for model in $(dal_models); do
        [ -d "packages/$model-$1" ] && echo "$model"
    done
    return 0
}

# A pure model ships hand-written ports and no native/wasm cores: its npm
# package declares `"desertant": {"pure": true}` (tongue is the first). Tasks
# that stage or test native artifacts skip these; their suites still run
# (test:node runs the package's own tests, Gradle runs the Kotlin ones).
#
# grep, not node: the release's native-build containers carry no JS toolchain,
# and a guard that quietly returns false there sends a pure model into a native
# build that cannot exist (v1.2.0 learned this the hard way).
dal_node_pure() { # <model>
    grep -q '"pure"[[:space:]]*:[[:space:]]*true' "packages/$1-node/package.json" 2> /dev/null
}

# "emo" -> "Emo". The Swift product/target name, and the native library prefix.
dal_product() { echo "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')${1:1}"; }

# Resolve a task's model argument: a name, or "all" for every model that ships
# the given platform. Fails loudly on a typo rather than silently doing nothing.
#
#     models=$(dal_select "${usage_model:-all}" node)
dal_select() {
    local want="${1:-all}" platform="${2:-}" all
    if [ -n "$platform" ]; then all=$(dal_models_with "$platform"); else all=$(dal_models); fi
    if [ "$want" = all ]; then
        [ -n "$all" ] || { echo "error: no model ships a $platform package" >&2; return 1; }
        echo "$all"
        return 0
    fi
    grep -qx "$want" <<<"$all" || {
        echo "error: unknown model '$want'${platform:+ (models shipping $platform: $(echo $all))}" >&2
        return 1
    }
    echo "$want"
}

# ---------------------------------------------------------------- version

# THE version: every artifact in this repo ships this number. Gradle reads the
# same file (see build.gradle.kts), so it is never duplicated in a build script.
dal_version() {
    local v
    v=$(tr -d '[:space:]' < VERSION)
    [ -n "$v" ] || { echo "error: VERSION is empty" >&2; return 1; }
    echo "$v"
}

# ---------------------------------------------------------------- swift SDKs

# The toolchain's own version, which every cross-compilation SDK must match.
dal_swift_version() {
    local v
    v=$(swift --version 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]/) { print $i; exit }}')
    [ -n "$v" ] || { echo "error: could not determine the Swift version" >&2; return 1; }
    echo "$v"
}

# SwiftPM's SDK directory varies by host: ~/.swiftpm (macOS), ~/.config/swiftpm
# (Linux), plus the sandboxed macOS location.
dal_has_swift_sdk() {
    local dir
    for dir in "$HOME/.swiftpm/swift-sdks" "$HOME/.config/swiftpm/swift-sdks" "$HOME/Library/org.swift.swiftpm/swift-sdks"; do
        [ -d "$dir/$1.artifactbundle" ] && return 0
    done
    return 1
}

# Install the WebAssembly SDK matching the toolchain if it is missing, and echo
# its name. Downloading first and installing from the local file means no
# per-version checksum has to be pinned here.
dal_wasm_sdk() {
    local version sdk tmp
    version=$(dal_swift_version)
    sdk="${WASM_SDK:-swift-$version-RELEASE_wasm}"
    if ! dal_has_swift_sdk "$sdk"; then
        echo "Installing the Swift WebAssembly SDK $version (one-time)..." >&2
        tmp=$(mktemp -d)
        curl -fSL -o "$tmp/sdk.tar.gz" \
            "https://download.swift.org/swift-$version-release/wasm-sdk/swift-$version-RELEASE/$sdk.artifactbundle.tar.gz"
        swift sdk install "$tmp/sdk.tar.gz" >&2
        rm -rf "$tmp"
    fi
    echo "$sdk"
}

# ---------------------------------------------------------------- litert

# Vendor the host's libLiteRt.so into Vendor/litert/lib/<linux-arch>. Apple hosts
# need nothing: the Swift SDK and the Node native both run Core ML there.
dal_vendor_litert() {
    local version="${DAL_LITERT_VERSION:-2.1.6}" arch wheel dest tmp
    [ "$(uname)" = Darwin ] && return 0
    case "$(uname -m)" in
        x86_64 | amd64) arch=linux-x64 wheel=x86_64-manylinux_2_28 ;;
        aarch64 | arm64) arch=linux-arm64 wheel=aarch64-manylinux_2_28 ;;
        *) echo "error: unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
    dest="Vendor/litert/lib/$arch"
    [ -f "$dest/libLiteRt.so" ] && return 0
    mkdir -p "$dest"
    tmp=$(mktemp -d)
    echo "Fetching ai-edge-litert $version ($arch libLiteRt.so, one-time)..." >&2
    # uv resolves the wheel for the target platform without a host Python and
    # unpacks it into a throwaway dir; the runtime ships at ai_edge_litert/.
    uv pip install --python-platform "$wheel" --python-version 3.12 \
        --target "$tmp/site" --only-binary=:all: "ai-edge-litert==$version" >/dev/null
    [ -f "$tmp/site/ai_edge_litert/libLiteRt.so" ] \
        || { echo "error: libLiteRt.so is not in the ai-edge-litert wheel" >&2; return 1; }
    cp "$tmp/site/ai_edge_litert/libLiteRt.so" "$dest/"
    # GPU models also want the WebGPU accelerator sibling, which core's
    # LiteRTSession picks up automatically when it is next to the runtime.
    if [ -n "${DAL_GPU:-}" ] && [ -f "$tmp/site/ai_edge_litert/libLiteRtWebGpuAccelerator.so" ]; then
        cp "$tmp/site/ai_edge_litert/libLiteRtWebGpuAccelerator.so" "$dest/"
    fi
    rm -rf "$tmp"
}

# The vendored LiteRT directory for this host (empty on Apple).
dal_litert_dir() {
    [ "$(uname)" = Darwin ] && return 0
    case "$(uname -m)" in
        x86_64 | amd64) echo "Vendor/litert/lib/linux-x64" ;;
        *) echo "Vendor/litert/lib/linux-arm64" ;;
    esac
}

# ---------------------------------------------------------------- misc

# node/npm-style arch key for the host: x64 or arm64.
dal_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x64 ;;
        arm64 | aarch64) echo arm64 ;;
        *) uname -m ;;
    esac
}

# Build and start Tools/EchoServer.swift for HTTPTests, wait until it accepts,
# and register a trap that stops it however the task exits.
dal_start_echo_server() {
    local port="${1:-8199}" bin
    bin="$(mktemp -d)/echo-server"
    # Host-SDK toolchain: xcrun (Xcode) on macOS, plain swiftc on Linux. A
    # swift.org toolchain pinned for a cross build has no macOS SDK.
    if command -v xcrun > /dev/null 2>&1; then
        xcrun swiftc -O Tools/EchoServer.swift -o "$bin"
    else
        swiftc -O Tools/EchoServer.swift -o "$bin"
    fi
    "$bin" "$port" &
    DAL_ECHO_PID=$!
    # shellcheck disable=SC2064
    trap "kill $DAL_ECHO_PID 2>/dev/null; wait $DAL_ECHO_PID 2>/dev/null || true" EXIT
    local _
    for _ in $(seq 1 50); do
        curl -sf -o /dev/null "http://127.0.0.1:$port/" && break
        sleep 0.2
    done
    kill -0 "$DAL_ECHO_PID" 2> /dev/null \
        || { echo "error: the echo server did not start (is port $port already in use?)" >&2; return 1; }
}
