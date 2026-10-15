# Build and install the Windows SDK using Git Bash.
# A2SDK_HOME overrides the destination; no symlink or administrator rights are needed.
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)
$buildForBash = $BuildDir.Replace('\', '/')

# PATH often resolves bash.exe to the WSL launcher. Prefer the bash shipped with Git.
$git = Get-Command git.exe -ErrorAction SilentlyContinue
$candidates = @()
if ($git) {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
    $candidates += Join-Path $gitRoot 'bin/bash.exe'
}
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA/Programs")) {
    if ($base) { $candidates += Join-Path $base 'Git/bin/bash.exe' }
}
$onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($onPath -and $onPath.Source -ne "$env:WINDIR\System32\bash.exe") {
    $candidates += $onPath.Source
}
$bash = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $bash) { throw 'Git Bash not found. Install Git for Windows to build the SDK.' }

if ($env:A64) {
    Write-Output '== the AArch64 objects as well'
    & $bash "$root/tests/a64-stdlib-check.sh" "$buildForBash/Win64" "$buildForBash/A64/bin"
    if ($LASTEXITCODE -ne 0) { throw "Building AArch64 objects failed (exit $LASTEXITCODE)." }
}

$bundle = Join-Path $BuildDir 'bundle-win64'
& $bash "$root/tests/win-bundle.sh" "$buildForBash/Win64" -o "$buildForBash/bundle-win64" --no-tar
if ($LASTEXITCODE -ne 0) { throw "Building the Windows SDK failed (exit $LASTEXITCODE)." }

& "$PSScriptRoot/install-windows.ps1" -BundleDir $bundle
