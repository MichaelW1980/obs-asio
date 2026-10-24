[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ReleaseDirectory,

    [Parameter(Mandatory = $true)]
    [string] $StagingDirectory,

    [ValidateSet('x64')]
    [string] $Target = 'x64'
)

$ErrorActionPreference = 'Stop'

# Staging only: no compiler invocation, ZIP creation, installer creation, or publication.
$ReleaseDirectory = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$StagingDirectory = [System.IO.Path]::GetFullPath($StagingDirectory)

$architecture = '64bit'
$dll = Join-Path $ReleaseDirectory "obs-plugins/$architecture/obs-asio.dll"
$data = Join-Path $ReleaseDirectory 'data/obs-plugins/obs-asio'

if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
    throw "Required compiled plugin not found: $dll"
}
if (-not (Test-Path -LiteralPath $data -PathType Container)) {
    throw "Required plugin resources not found: $data"
}
if (Test-Path -LiteralPath $StagingDirectory) {
    throw "Staging destination already exists; refusing to overwrite it: $StagingDirectory"
}

$stageParent = [System.IO.Path]::GetDirectoryName($StagingDirectory)
if (-not (Test-Path -LiteralPath $stageParent -PathType Container)) {
    throw "Staging parent does not exist: $stageParent"
}

# Never allow a staging operation to modify the source installation tree.
$sourcePrefix = $ReleaseDirectory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$stagePrefix = $StagingDirectory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($StagingDirectory.Equals($ReleaseDirectory, [System.StringComparison]::OrdinalIgnoreCase) -or
    $stagePrefix.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    $sourcePrefix.StartsWith($stagePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source release directory and staging destination must be separate, non-nested directories.'
}

$resourceFiles = @(Get-ChildItem -LiteralPath $data -File -Recurse -Force)
if ($resourceFiles.Count -eq 0) {
    throw "No resource files found: $data"
}

$legacy = Join-Path $StagingDirectory 'legacy'
$modern = Join-Path $StagingDirectory 'modern'
$legacyDll = Join-Path $legacy "obs-plugins/$architecture/obs-asio.dll"
$legacyData = Join-Path $legacy 'data/obs-plugins/obs-asio'
$modernDll = Join-Path $modern 'plugins/obs-asio/obs-asio.dll'
$modernData = Join-Path $modern 'plugins/obs-asio/data'

$stageCreated = $false
try {
    New-Item -ItemType Directory -Path $StagingDirectory -ErrorAction Stop | Out-Null
    $stageCreated = $true

    foreach ($file in @($legacyDll, $modernDll)) {
        $directory = [System.IO.Path]::GetDirectoryName($file)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Copy-Item -LiteralPath $dll -Destination $file -ErrorAction Stop
    }

    foreach ($destination in @($legacyData, $modernData)) {
        foreach ($resource in $resourceFiles) {
            $relativePath = [System.IO.Path]::GetRelativePath($data, $resource.FullName)
            $targetFile = Join-Path $destination $relativePath
            New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($targetFile)) -Force | Out-Null
            Copy-Item -LiteralPath $resource.FullName -Destination $targetFile -ErrorAction Stop
        }
    }

    $expected = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    foreach ($file in @($legacyDll, $modernDll)) {
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actual -ne $expected) {
            throw "Staged binary differs from the original: $file"
        }
    }

    foreach ($destination in @($legacyData, $modernData)) {
        $stagedResources = @(Get-ChildItem -LiteralPath $destination -File -Recurse -Force)
        if ($stagedResources.Count -ne $resourceFiles.Count) {
            throw "Resource file count mismatch in: $destination"
        }
        foreach ($resource in $resourceFiles) {
            $relativePath = [System.IO.Path]::GetRelativePath($data, $resource.FullName)
            $targetFile = Join-Path $destination $relativePath
            $originalHash = (Get-FileHash -LiteralPath $resource.FullName -Algorithm SHA256).Hash
            $stagedHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
            if ($originalHash -ne $stagedHash) {
                throw "Resource differs from original: $targetFile"
            }
        }
    }

    Write-Output "Legacy stage: $legacy"
    Write-Output "Modern stage: $modern"
    Write-Output "Binary SHA256 (both layouts): $expected"
    Write-Output "Verified resource files per layout: $($resourceFiles.Count)"
}
catch {
    if ($stageCreated -and (Test-Path -LiteralPath $StagingDirectory)) {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
    }
    throw
}
