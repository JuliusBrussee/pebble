param(
    [string]$Configuration = "release",
    [switch]$SkipBuild,
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Manifest = Get-Content (Join-Path $Root "packaging/package-manifest.json") -Raw | ConvertFrom-Json
$Version = $Manifest.version
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $Root "dist/windows-x64" }

if (-not $SkipBuild) {
    Push-Location $Root
    try {
        swift build -c $Configuration --product pebble-win
        swift build -c $Configuration --product pebserver
    } finally { Pop-Location }
}

Push-Location $Root
try { $Bin = (swift build -c $Configuration --show-bin-path).Trim() }
finally { Pop-Location }
if (-not $Bin -or -not (Test-Path $Bin)) { throw "SwiftPM binary directory not found: $Bin" }
$ShaderOutput = Join-Path $Bin "vulkan-shaders"
New-Item $ShaderOutput -ItemType Directory -Force | Out-Null
$GlslcCommand = Get-Command glslc -ErrorAction SilentlyContinue
$GlslcPath = if ($GlslcCommand) { $GlslcCommand.Source } else { "" }
if (-not $GlslcPath) {
    $SdkGlslc = if ($env:VULKAN_SDK) { Join-Path $env:VULKAN_SDK "Bin/glslc.exe" } else { "" }
    if ($SdkGlslc -and (Test-Path $SdkGlslc)) { $GlslcPath = $SdkGlslc }
}
if (-not $GlslcPath) { throw "glslc not found; install Vulkan SDK" }
foreach ($Shader in Get-ChildItem (Join-Path $Root "Shaders/Vulkan") -File | Where-Object { $_.Extension -in @(".vert", ".frag") }) {
    & $GlslcPath --target-env=vulkan1.2 -O $Shader.FullName -o (Join-Path $ShaderOutput ($Shader.Name + ".spv"))
    if ($LASTEXITCODE -ne 0) { throw "shader compile failed: $($Shader.Name)" }
}
$Client = Join-Path $Bin "pebble-win.exe"
$Server = Join-Path $Bin "pebserver.exe"
if (-not (Test-Path $Client)) { throw "missing client executable: $Client" }
if (-not (Test-Path $Server)) { throw "missing server executable: $Server" }

Remove-Item $OutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
New-Item (Join-Path $OutputDirectory "assets") -ItemType Directory -Force | Out-Null
New-Item (Join-Path $OutputDirectory "licenses") -ItemType Directory -Force | Out-Null
New-Item (Join-Path $OutputDirectory "shaders") -ItemType Directory -Force | Out-Null
Copy-Item $Client (Join-Path $OutputDirectory "Pebble.exe")
Copy-Item $Server (Join-Path $OutputDirectory "pebserver.exe")

foreach ($Asset in @("logo.png", "title-bg.png", "Faithful 32x - 1.20.1.zip")) {
    $Source = Join-Path $Root "packaging/$Asset"
    if (-not (Test-Path $Source)) { throw "missing package asset: $Asset" }
    Copy-Item $Source (Join-Path $OutputDirectory "assets/$Asset")
}
Copy-Item (Join-Path $Root "LICENSE") (Join-Path $OutputDirectory "licenses/LICENSE")
Copy-Item (Join-Path $Root "packaging/FAITHFUL-LICENSE.txt") (Join-Path $OutputDirectory "licenses/FAITHFUL-LICENSE.txt")
Copy-Item (Join-Path $Root "packaging/THIRD-PARTY-NOTICES.txt") (Join-Path $OutputDirectory "licenses/THIRD-PARTY-NOTICES.txt")
Copy-Item (Join-Path $Root "packaging/README-WINDOWS.txt") $OutputDirectory
Copy-Item (Join-Path $ShaderOutput "*.spv") (Join-Path $OutputDirectory "shaders")

$SDLSearch = @(@(
    (Join-Path $Bin "SDL3.dll"),
    $(if ($env:SDL3_DIR) { Join-Path $env:SDL3_DIR "bin/SDL3.dll" } else { "" }),
    $(if ($env:VCPKG_ROOT) { Join-Path $env:VCPKG_ROOT "installed/x64-windows/bin/SDL3.dll" } else { "" })
) | Where-Object { $_ -and (Test-Path $_) })
if ($SDLSearch.Count -eq 0) { throw "SDL3.dll not found; set SDL3_DIR or install x64-windows SDL3 through vcpkg" }
Copy-Item $SDLSearch[0] (Join-Path $OutputDirectory "SDL3.dll")

$TargetInfo = swiftc -print-target-info | ConvertFrom-Json
$RuntimePaths = @($TargetInfo.paths.runtimeLibraryPaths)
$RuntimeDLLs = @()
foreach ($RuntimePath in $RuntimePaths) {
    if (-not (Test-Path $RuntimePath)) { continue }
    $RuntimeDLLs += Get-ChildItem $RuntimePath -Filter "swift*.dll" -File
    $RuntimeDLLs += Get-ChildItem $RuntimePath -Filter "icu*.dll" -File
}
$RuntimeDLLs = $RuntimeDLLs | Sort-Object FullName -Unique
if ($RuntimeDLLs.Count -eq 0) { throw "Swift runtime DLL closure is empty" }
foreach ($DLL in $RuntimeDLLs) { Copy-Item $DLL.FullName (Join-Path $OutputDirectory $DLL.Name) }

$MSVCRuntimeNames = @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")
foreach ($Name in $MSVCRuntimeNames) {
    $Candidates = @(@(
        (Join-Path $Bin $Name),
        (Join-Path $env:SystemRoot "System32/$Name"),
        $(if ($env:VCToolsRedistDir) { Join-Path $env:VCToolsRedistDir "x64/Microsoft.VC143.CRT/$Name" } else { "" })
    ) | Where-Object { $_ -and (Test-Path $_) })
    if ($Candidates.Count -eq 0) { throw "MSVC runtime dependency missing: $Name" }
    Copy-Item $Candidates[0] (Join-Path $OutputDirectory $Name)
}

$Required = @(
    "Pebble.exe", "pebserver.exe", "SDL3.dll", "README-WINDOWS.txt",
    "assets/logo.png", "assets/title-bg.png", "assets/Faithful 32x - 1.20.1.zip",
    "licenses/LICENSE", "licenses/FAITHFUL-LICENSE.txt", "licenses/THIRD-PARTY-NOTICES.txt"
)
foreach ($Relative in $Required) {
    if (-not (Test-Path (Join-Path $OutputDirectory $Relative))) { throw "package verification missing: $Relative" }
}
$RequiredShaders = @(
    "chunk.vert.spv", "chunk.frag.spv", "shadow.vert.spv", "entity.vert.spv", "entity.frag.spv",
    "entity_shadow.vert.spv",
    "particle.vert.spv", "particle.frag.spv", "sky.vert.spv", "sky.frag.spv", "ui.vert.spv",
    "ui.frag.spv", "fullscreen.vert.spv", "composite.frag.spv"
)
foreach ($Shader in $RequiredShaders) {
    if (-not (Test-Path (Join-Path $OutputDirectory "shaders/$Shader"))) { throw "package verification missing shader: $Shader" }
}
foreach ($Name in $MSVCRuntimeNames) {
    if (-not (Test-Path (Join-Path $OutputDirectory $Name))) { throw "package verification missing runtime: $Name" }
}

$Archive = Join-Path (Split-Path -Parent $OutputDirectory) "Pebble-windows-x64-$Version.zip"
Remove-Item $Archive -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $OutputDirectory "*") -DestinationPath $Archive -CompressionLevel Optimal
$Hash = (Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$Archive.sha256" -Value "$Hash  $(Split-Path -Leaf $Archive)`n" -NoNewline
Write-Output $Archive
