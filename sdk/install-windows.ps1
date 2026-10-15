# Install a Windows SDK directory without requiring symlinks or administrator rights.
# A2SDK_HOME overrides %LOCALAPPDATA%/Programs/a2sdk.
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDir
)

$ErrorActionPreference = 'Stop'
$bundle = [System.IO.Path]::GetFullPath($BundleDir).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath "$bundle/ob.exe" -PathType Leaf) -or
    -not (Test-Path -LiteralPath "$bundle/lib" -PathType Container)) {
    throw "Incomplete Windows SDK in $bundle"
}

$destination = $env:A2SDK_HOME
if (-not $destination) { $destination = Join-Path $env:LOCALAPPDATA 'Programs/a2sdk' }
$destination = [System.IO.Path]::GetFullPath($destination).TrimEnd('\', '/')
if ($destination -eq [System.IO.Path]::GetPathRoot($destination).TrimEnd('\', '/')) {
    throw 'A2SDK_HOME must name an SDK directory, not a drive root.'
}
if ($destination -eq $bundle -or $bundle.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $destination.StartsWith($bundle + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'A2SDK_HOME must be separate from the build bundle directory.'
}

# Stage the complete payload before replacing an existing installation.
$parent = Split-Path -Parent $destination
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$staging = Join-Path $parent ('.a2sdk-' + [guid]::NewGuid().ToString('N'))
$backup = $staging + '.old'
try {
    Copy-Item -LiteralPath $bundle -Destination $staging -Recurse
    if (-not (Test-Path -LiteralPath "$staging/ob.exe" -PathType Leaf) -or
        -not (Test-Path -LiteralPath "$staging/lib" -PathType Container)) {
        throw "Incomplete Windows SDK in $bundle"
    }
    & "$staging/ob.exe" version
    if ($LASTEXITCODE -ne 0) { throw "The new SDK failed 'ob version' (exit $LASTEXITCODE)." }
    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath "$destination/ob.exe" -PathType Leaf)) {
            throw "Refusing to replace $destination because it contains no ob.exe."
        }
        # The language server keeps symbol files open without FILE_SHARE_DELETE.
        # Stop only servers from this installation so Windows can rename the directory.
        $executable = Join-Path $destination 'ob.exe'
        $servers = Get-CimInstance Win32_Process -Filter "Name = 'ob.exe'" | Where-Object {
            $_.ExecutablePath -eq $executable -and $_.CommandLine -match '\bob\.exe"?\s+lsp(?:\s|$)'
        }
        foreach ($server in $servers) {
            $process = Get-Process -Id $server.ProcessId -ErrorAction SilentlyContinue
            if ($process) {
                Write-Output "Stopping SDK language server $($server.ProcessId); restart your editor after updating."
                Stop-Process -Id $server.ProcessId -Force
                if (-not $process.WaitForExit(5000)) { throw 'The SDK language server did not stop.' }
            }
        }
        # Move-Item can fall back to moving individual files when a directory is locked.
        # Directory.Move either renames the whole directory or leaves it in place.
        [System.IO.Directory]::Move($destination, $backup)
    }
    try {
        [System.IO.Directory]::Move($staging, $destination)
    } catch {
        if (Test-Path -LiteralPath $backup) {
            [System.IO.Directory]::Move($backup, $destination)
        }
        throw
    }
} finally {
    # Both paths are generated directly under the verified installation parent.
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
if (Test-Path -LiteralPath $backup) {
    try {
        Remove-Item -LiteralPath $backup -Recurse -Force
    } catch {
        Write-Warning "SDK updated; old files are still in use in $backup. Restart applications using the SDK, then remove that directory."
    }
}

Write-Output "SDK installed in $destination"
if (-not (($env:PATH -split ';').TrimEnd('\', '/') -contains $destination)) {
    Write-Output "Add this directory to your user PATH to run ob: $destination"
}
Write-Output "Next: ob run `"$destination/examples/Hello.Mod`""
