# Vendor libLiteRt.dll for Windows x64 into Vendor/litert/lib/windows-x64,
# mirroring dal_vendor_litert in Tools/dal.sh (which handles Linux). The runtime
# ships in the ai-edge-litert PyPI wheel; the win_amd64 wheel carries
# libLiteRt.dll at ai_edge_litert/. Windows additionally needs an import
# library (LiteRt.lib) generated from the DLL's export table, because link.exe
# cannot link against a bare DLL; that step needs dumpbin/lib from an MSVC
# developer environment (CI: ilammy/msvc-dev-cmd).
$ErrorActionPreference = "Stop"

$version = if ($env:DAL_LITERT_VERSION) { $env:DAL_LITERT_VERSION } else { "2.1.6" }
$dest = "Vendor/litert/lib/windows-x64"

if ((Test-Path "$dest/libLiteRt.dll") -and (Test-Path "$dest/LiteRt.lib")) {
    Write-Host "LiteRT $version already vendored at $dest"
    exit 0
}
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host "Fetching ai-edge-litert $version (win_amd64 libLiteRt.dll, one-time)..."
    pip download "ai-edge-litert==$version" --only-binary=:all: --no-deps -d $tmp | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "pip download failed" }

    $whl = Get-ChildItem $tmp -Filter *.whl | Select-Object -First 1
    if (-not $whl) { throw "no wheel downloaded" }
    Expand-Archive $whl.FullName -DestinationPath "$tmp/whl"

    $dll = "$tmp/whl/ai_edge_litert/libLiteRt.dll"
    if (-not (Test-Path $dll)) { throw "libLiteRt.dll is not in the ai-edge-litert wheel" }
    Copy-Item $dll "$dest/libLiteRt.dll"

    # Import library: dump the DLL's exports into a .def, then lib /def. The
    # LIBRARY statement pins the loader to the vendored DLL name.
    $exports = & dumpbin /exports "$dest/libLiteRt.dll"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed (run from an MSVC developer environment)" }
    $names = $exports | ForEach-Object {
        if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { $Matches[1] }
    } | Where-Object { $_ }
    if (-not $names) { throw "no exports found in libLiteRt.dll" }

    @("LIBRARY libLiteRt.dll", "EXPORTS") + $names | Set-Content "$tmp/LiteRt.def"
    & lib "/def:$tmp/LiteRt.def" /machine:x64 "/out:$dest/LiteRt.lib" /nologo
    if ($LASTEXITCODE -ne 0) { throw "lib.exe failed" }

    Write-Host "Vendored LiteRT $version -> $dest ($($names.Count) exports)"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
