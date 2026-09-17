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
# `uname` by hand; anything unrecognized answers linux.
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
# build that cannot exist.
dal_node_pure() { # <model>
    grep -q '"pure"[[:space:]]*:[[:space:]]*true' "packages/$1-node/package.json" 2> /dev/null
}

# A model with no native core: its npm package declares
# `"desertant": {"wasmOnly": true}` (voz is the first). Voz has no `dal_*` C ABI
# to build one from - it drives Core ML directly on Apple and ONNX Runtime Web
# in a browser - so Node runs the same wasm core the browser does, with the
# caller's runtime under it. Native tasks skip these; their suites still run.
#
# grep for the same reason `dal_node_pure` greps: the native-build containers
# carry no JS toolchain.
dal_node_wasm_only() { # <model>
    grep -q '"wasmOnly"[[:space:]]*:[[:space:]]*true' "packages/$1-node/package.json" 2> /dev/null
}

# Models whose Android natives are too heavy for the every-commit CI lane (voz
# is a 1.5 GB model and the largest Swift module in the repo). The "all"
# expansion in the Android tasks skips them unless DAL_LONG_TESTS=1, the same
# opt-in the Swift suites' .longRunning trait reads; the release workflow sets
# it, so a published AAR always carries its natives. Naming the model
# explicitly (mise run build:android-natives voz) always builds it.
dal_android_deferred() { # <model>
    [ "${DAL_LONG_TESTS:-}" = 1 ] && return 1
    [ "$1" = voz ]
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
    local version="${DAL_LITERT_VERSION:-2.2.0}" arch wheel lib gpu dest tmp
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
# ship in the Swift toolchain, which keeps this off an MSVC developer prompt.
# The LIBRARY line
# pins the loader to the vendored DLL's name.
dal_windows_import_lib() { # <dll> <out.lib>
    local dll="$1" out="$2" tmp names
    command -v llvm-readobj > /dev/null 2>&1 && command -v llvm-lib > /dev/null 2>&1 \
        || { echo "error: llvm-readobj and llvm-lib (Swift toolchain) are not on PATH" >&2; return 1; }
    names=$(llvm-readobj --coff-exports "$dll" | sed -n 's/^  Name: //p')
    [ -n "$names" ] || { echo "error: no exports found in $(basename "$dll")" >&2; return 1; }
    tmp=$(mktemp -d)
    local def="$tmp/$(basename "${out%.lib}").def"
    { echo "LIBRARY $(basename "$dll")"; echo EXPORTS; echo "$names"; } > "$def"
    # llvm-lib is a native tool: it cannot read Git Bash's /c/... paths.
    llvm-lib "/def:$(cygpath -w "$def")" /machine:x64 \
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

# ----------------------------------------------------------- onnxruntime

# The ONNX Runtime version vendored below. The headers in the COnnxRuntime
# package (see Package.swift) came out of this same release, so moving one
# without the other is how the shim starts compiling against an API table the
# DLL does not have.
DAL_ORT_VERSION=1.23.0

# Windows only. Linux and Android have LiteRT and need no second runtime; Apple
# has Core ML. This exists because the NPU execution providers are Windows-only.
dal_onnxruntime_dir() {
    [ "$(dal_host_os)" = windows ] || return 0
    echo "Vendor/onnxruntime/lib/windows-x64"
}

# Vendor ONNX Runtime into Vendor/onnxruntime/lib/windows-x64.
#
# The DirectML build, not the stock one, and that is the whole point: the plain
# GitHub release carries no GPU execution provider, and on this hardware the GPU
# is what makes the models fast. Measured on a Radeon 8060S, Voz end to end runs
# at 366x real time on DirectML against 38.7x on the CPU provider, on the same
# float16 weights and with a character-identical transcript.
#
# It comes from the PyPI wheel because that is the only place the DirectML build
# is published; the wheel ships no import library, so one is synthesized from the
# DLL's export table exactly as the LiteRT path does.
dal_vendor_onnxruntime() {
    local dest tmp url
    dest=$(dal_onnxruntime_dir)
    [ -n "$dest" ] || return 0
    [ -f "$dest/onnxruntime.dll" ] && [ -f "$dest/onnxruntime.lib" ] \
        && [ -f "$dest/DirectML.dll" ] && return 0

    mkdir -p "$dest"
    echo "Fetching ONNX Runtime $DAL_ORT_VERSION (DirectML, windows-x64, one-time)..." >&2
    tmp=$(mktemp -d)
    python -m pip download --quiet --no-deps --only-binary=:all: -d "$tmp" \
        "onnxruntime-directml==$DAL_ORT_VERSION" > /dev/null 2>&1 \
        || { echo "error: could not download onnxruntime-directml==$DAL_ORT_VERSION" >&2
             rm -rf "$tmp"; return 1; }
    local whl
    whl=$(find "$tmp" -name '*.whl' | head -1)
    [ -n "$whl" ] || { echo "error: no wheel downloaded" >&2; rm -rf "$tmp"; return 1; }
    # A wheel is a zip; Git Bash's tar is GNU tar and does not read zips, and
    # PowerShell wants the extension to say so.
    cp "$whl" "$tmp/ort.zip"
    powershell -NoProfile -Command \
        "Expand-Archive -Path '$(cygpath -w "$tmp/ort.zip")' -DestinationPath '$(cygpath -w "$tmp/x")' -Force" \
        > /dev/null || { echo "error: could not unpack the wheel" >&2; rm -rf "$tmp"; return 1; }

    local capi="$tmp/x/onnxruntime/capi"
    [ -f "$capi/onnxruntime.dll" ] && [ -f "$capi/DirectML.dll" ] \
        || { echo "error: onnxruntime.dll / DirectML.dll are not in the wheel" >&2
             rm -rf "$tmp"; return 1; }
    cp "$capi/onnxruntime.dll" "$capi/DirectML.dll" "$dest/"
    [ -f "$capi/onnxruntime_providers_shared.dll" ] \
        && cp "$capi/onnxruntime_providers_shared.dll" "$dest/"
    dal_windows_import_lib "$dest/onnxruntime.dll" "$dest/onnxruntime.lib"
    rm -rf "$tmp"
}

# Copy onnxruntime.dll next to the binaries in <products-dir>.
#
# PATH is not enough for this one, unlike libLiteRt.dll. Windows searches the
# application directory and then System32 BEFORE PATH, and Windows ML ships its
# own C:\Windows\System32\onnxruntime.dll - 1.17 on a 26200 host. A PATH entry
# therefore loses to it silently, and the shim fails at
# `OrtGetApiBase()->GetApi(ORT_API_VERSION)` with "The requested API version
# [23] is not available", which reads like a build error and is not one. The
# application directory outranks System32, so staging the DLL there is what
# makes the vendored copy win.
dal_stage_onnxruntime() { # <products-dir>
    local dir src f
    src=$(dal_onnxruntime_dir)
    [ -n "$src" ] || return 0
    dir="$1"
    [ -d "$dir" ] || return 0
    # DirectML.dll travels with it: onnxruntime.dll loads it by name when the
    # GPU provider is asked for, and without it a .gpu session silently becomes
    # a CPU one.
    for f in onnxruntime.dll DirectML.dll onnxruntime_providers_shared.dll; do
        [ -f "$src/$f" ] && cp -f "$src/$f" "$dir/" 2> /dev/null
    done
    return 0
}

# Link flags for the vendored ONNX Runtime, in the same shape as
# dal_litert_link_flags:
#
#     eval "$(dal_onnxruntime_link_flags)"   # sets onnx_flags
dal_onnxruntime_link_flags() {
    local dir
    dir=$(dal_onnxruntime_dir)
    if [ -z "$dir" ]; then
        echo "onnx_flags=()"
    else
        echo "onnx_flags=(-Xlinker \"/LIBPATH:$dir\")"
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
    # Any answer here is another process: the tests would talk to it instead,
    # and fail far from the cause.
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
        echo "error: port $port is already in use; DAL_SWIFT_ECHO_PORT or DAL_WASI_ECHO_PORT moves the task off it" >&2
        return 1
    fi
    "$bin" "$port" &
    DAL_ECHO_PID=$!
    # shellcheck disable=SC2064
    trap "kill $DAL_ECHO_PID 2>/dev/null; wait $DAL_ECHO_PID 2>/dev/null || true" EXIT
    # Ready only when the reply is our own probe echoed back, so a listener
    # that took the port in the meantime is not mistaken for this server.
    local _ probe="dal-echo-$$"
    for _ in $(seq 1 50); do
        [ "$(curl -sf --max-time 2 -X POST --data "$probe" "http://127.0.0.1:$port/echo" 2> /dev/null)" = "$probe" ] \
            && return 0
        kill -0 "$DAL_ECHO_PID" 2> /dev/null || break
        sleep 0.2
    done
    echo "error: the echo server did not start on port $port (is it already in use?)" >&2
    return 1
}
