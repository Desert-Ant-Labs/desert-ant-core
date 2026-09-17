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

# ---------------------------------------------------------------- host

# The host OS as these tasks talk about it: darwin, linux, or windows. Git Bash
# and MSYS answer `uname -s` with MINGW64_NT-10.0-26200, so no task matches on
# `uname` by hand; anything unrecognized answers linux, which is what the
# `[ "$(uname)" = Darwin ]` tests this replaced already assumed.
dal_host_os() {
    case "$(uname -s)" in
        Darwin) echo darwin ;;
        MINGW* | MSYS* | CYGWIN*) echo windows ;;
        *) echo linux ;;
    esac
}

# Windows hands out symbolic links only to a process holding
# SeCreateSymbolicLinkPrivilege, which is what Settings > System > For
# developers > Developer Mode grants. SwiftPM needs them in two places - the
# .build/release alias, and checking out a dependency whose tree contains
# symlinks (JavaScriptKit does) - so the tasks that depend on one ask here
# first and say what is missing, rather than failing twenty lines deep in a
# libgit2 error. Always true on Linux and macOS.
dal_can_symlink() {
    local tmp ok=1
    [ "$(dal_host_os)" = windows ] || return 0
    tmp=$(mktemp -d)
    : > "$tmp/target"
    # MSYS silently copies when it cannot link, so the -L test is the real
    # answer, not ln's exit status.
    ln -s "$tmp/target" "$tmp/link" 2> /dev/null && [ -L "$tmp/link" ] && ok=0
    rm -rf "$tmp"
    return $ok
}

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
# (Linux), %LOCALAPPDATA%/org.swift.swiftpm (Windows), plus the sandboxed macOS
# location.
dal_swift_sdk_dirs() {
    printf '%s\n' "$HOME/.swiftpm/swift-sdks" "$HOME/.config/swiftpm/swift-sdks" \
        "$HOME/Library/org.swift.swiftpm/swift-sdks" \
        "${LOCALAPPDATA:-$HOME/AppData/Local}/org.swift.swiftpm/swift-sdks"
}

dal_has_swift_sdk() {
    local dir
    while IFS= read -r dir; do
        [ -d "$dir/$1.artifactbundle" ] && return 0
    done < <(dal_swift_sdk_dirs)
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
        # A 404 here is almost always "this Swift release has no wasm SDK yet",
        # which is a toolchain-selection problem and reads like a network error
        # if curl is left to report it.
        curl -fSL -o "$tmp/sdk.tar.gz" \
            "https://download.swift.org/swift-$version-release/wasm-sdk/swift-$version-RELEASE/$sdk.artifactbundle.tar.gz" \
            || { echo "error: no WebAssembly SDK published for Swift $version; build with a toolchain that has one" >&2; return 1; }
        swift sdk install "$tmp/sdk.tar.gz" >&2
        rm -rf "$tmp"
    fi
    echo "$sdk"
}

# ---------------------------------------------------------------- litert

# Vendor the host's LiteRT runtime into Vendor/litert/lib/<host-arch>. Apple
# hosts need nothing: the Swift SDK and the Node native both run Core ML there.
# Linux and Windows both take it from the ai-edge-litert PyPI wheel, which is
# where Google ships the prebuilt runtime; only the file names differ.
dal_vendor_litert() {
    local version="${DAL_LITERT_VERSION:-2.1.6}" arch wheel lib gpu dest tmp
    case "$(dal_host_os)" in
        darwin) return 0 ;;
        windows)
            arch=windows-x64 wheel=x86_64-pc-windows-msvc
            lib=libLiteRt.dll gpu=libLiteRtWebGpuAccelerator.dll
            ;;
        *)
            case "$(uname -m)" in
                x86_64 | amd64) arch=linux-x64 wheel=x86_64-manylinux_2_28 ;;
                aarch64 | arm64) arch=linux-arm64 wheel=aarch64-manylinux_2_28 ;;
                *) echo "error: unsupported arch $(uname -m)" >&2; return 1 ;;
            esac
            lib=libLiteRt.so gpu=libLiteRtWebGpuAccelerator.so
            ;;
    esac
    dest="Vendor/litert/lib/$arch"
    # Windows is vendored only once both halves are there: a DLL with no import
    # library links nothing.
    if [ -f "$dest/$lib" ]; then
        [ "$arch" != windows-x64 ] && return 0
        [ -f "$dest/LiteRt.lib" ] && return 0
    fi
    mkdir -p "$dest"
    tmp=$(mktemp -d)
    echo "Fetching ai-edge-litert $version ($arch $lib, one-time)..." >&2
    # uv resolves the wheel for the target platform without a host Python and
    # unpacks it into a throwaway dir; the runtime ships at ai_edge_litert/.
    uv pip install --python-platform "$wheel" --python-version 3.12 \
        --target "$tmp/site" --only-binary=:all: "ai-edge-litert==$version" >/dev/null
    [ -f "$tmp/site/ai_edge_litert/$lib" ] \
        || { echo "error: $lib is not in the ai-edge-litert wheel" >&2; return 1; }
    cp "$tmp/site/ai_edge_litert/$lib" "$dest/"
    # GPU models also want the WebGPU accelerator sibling, which core's
    # LiteRTSession picks up automatically when it is next to the runtime.
    if [ -n "${DAL_GPU:-}" ] && [ -f "$tmp/site/ai_edge_litert/$gpu" ]; then
        cp "$tmp/site/ai_edge_litert/$gpu" "$dest/"
    fi
    rm -rf "$tmp"
    [ "$arch" = windows-x64 ] && dal_windows_import_lib "$dest/$lib" "$dest/LiteRt.lib"
    return 0
}

# Windows only: link.exe cannot link against a bare DLL, so synthesize the
# import library from the DLL's own export table. llvm-readobj and llvm-lib both
# ship in the Swift toolchain, which is what keeps this off an MSVC developer
# prompt - the one thing that used to make the step CI-only. The LIBRARY line
# pins the loader to the vendored DLL's name.
dal_windows_import_lib() { # <dll> <out.lib>
    local dll="$1" out="$2" tmp names
    command -v llvm-readobj > /dev/null 2>&1 && command -v llvm-lib > /dev/null 2>&1 \
        || { echo "error: llvm-readobj and llvm-lib (Swift toolchain) are not on PATH" >&2; return 1; }
    names=$(llvm-readobj --coff-exports "$dll" | sed -n 's/^  Name: //p')
    [ -n "$names" ] || { echo "error: no exports found in $(basename "$dll")" >&2; return 1; }
    tmp=$(mktemp -d)
    { echo "LIBRARY $(basename "$dll")"; echo EXPORTS; echo "$names"; } > "$tmp/LiteRt.def"
    # llvm-lib is a native tool: it cannot read Git Bash's /c/... paths.
    llvm-lib "/def:$(cygpath -w "$tmp/LiteRt.def")" /machine:x64 \
        "/out:$(cygpath -w "$out")" /nologo > /dev/null
    rm -rf "$tmp"
    echo "Generated $(basename "$out") ($(echo "$names" | wc -l | tr -d ' ') exports)" >&2
}

# The vendored LiteRT directory for this host (empty on Apple).
dal_litert_dir() {
    case "$(dal_host_os)" in
        darwin) return 0 ;;
        windows) echo "Vendor/litert/lib/windows-x64" ;;
        *)
            case "$(uname -m)" in
                x86_64 | amd64) echo "Vendor/litert/lib/linux-x64" ;;
                *) echo "Vendor/litert/lib/linux-arm64" ;;
            esac
            ;;
    esac
}

# The flags that put the vendored LiteRT on the link line, as a bash array:
#
#     eval "$(dal_litert_link_flags)"   # sets litert_flags
#
# The search-path spelling is the one thing every host disagrees on: -L for ld,
# /LIBPATH: for link.exe, and nothing at all on Apple.
dal_litert_link_flags() {
    local dir
    dir=$(dal_litert_dir)
    if [ -z "$dir" ]; then
        echo "litert_flags=()"
    elif [ "$(dal_host_os)" = windows ]; then
        echo "litert_flags=(-Xlinker \"/LIBPATH:$dir\")"
    else
        echo "litert_flags=(-Xlinker \"-L$dir\")"
    fi
}

# ---------------------------------------------------------------- bundles

# SwiftPM on Windows stages every resource bundle twice: correctly into
# <scratch>/out/Products/<config>/<Name>.bundle, and again as loose members in
# the working directory, which for these tasks is the repo root. One
# `swift build` leaves fifteen files there (Info.plist, golden.json,
# tongue_int8.bin ...), so sweep the second copy away.
#
# Deliberately narrow: a file goes only if git does not track it AND it is
# byte-identical to a member of a bundle this build produced. That makes the
# sweep idempotent (it also clears what an earlier run left) and keeps it from
# ever touching a real source file that happens to share a name.
dal_sweep_bundle_leaks() { # <scratch-path>
    local member name swept=0
    [ "$(dal_host_os)" = windows ] || return 0
    [ -d "$1" ] || return 0
    while IFS= read -r member; do
        name=$(basename "$member")
        [ -f "$name" ] || continue
        git ls-files --error-unmatch "$name" > /dev/null 2>&1 && continue
        cmp -s "$member" "$name" || continue
        rm -f "$name"
        swept=$((swept + 1))
    done < <(find "$1" -type d -name '*.bundle' -exec find {} -maxdepth 1 -type f ';' 2> /dev/null)
    [ "$swept" -gt 0 ] && echo "swept $swept stray resource-bundle file(s) from the repo root" >&2
    return 0
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
    # Windows will not execute a PE without the extension, and swiftc writes
    # exactly the name it is given.
    [ "$(dal_host_os)" = windows ] && bin="$bin.exe"
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
