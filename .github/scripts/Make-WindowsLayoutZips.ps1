[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $StagingDirectory,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string] $Version
)

$ErrorActionPreference = 'Stop'

# Package only prevalidated staging trees. Never build a DLL or publish a release.
$staging = (Resolve-Path -LiteralPath $StagingDirectory).Path.TrimEnd('\', '/')
$output = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $output -PathType Container)) {
    throw "Output directory does not exist: $output"
}
if ($output.Equals($staging, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($staging + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $staging.StartsWith($output + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output and staging directories must be separate and non-nested.'
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw 'Version must be a valid filename-safe dotted version.'
}

$layouts = @(
    @{ Name = 'legacy'; Dll = 'obs-plugins/64bit/obs-asio.dll'; Data = 'data/obs-plugins/obs-asio' },
    @{ Name = 'modern'; Dll = 'plugins/obs-asio/obs-asio.dll'; Data = 'plugins/obs-asio/data' }
)
$plans = @()
foreach ($layout in $layouts) {
    $root = Join-Path $staging $layout.Name
    if (-not (Test-Path -LiteralPath (Join-Path $root $layout.Dll) -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $root $layout.Data) -PathType Container)) {
        throw "Incomplete $($layout.Name) staging layout: $root"
    }
    if (((Get-Item -LiteralPath $root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Staging root cannot be a reparse point: $root"
    }
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)
    if ($files.Count -eq 0) { throw "Empty staging layout: $root" }
    if (@(Get-ChildItem -LiteralPath $root -Recurse -Force -Attributes ReparsePoint).Count -gt 0) {
        throw "Reparse points are not permitted inside staging: $root"
    }
    $destination = Join-Path $output "obs-asio-$Version-$($layout.Name)-win64.zip"
    if (Test-Path -LiteralPath $destination) { throw "Archive already exists: $destination" }
    $plans += @{ Name = $layout.Name; Root = $root; Files = $files; Destination = $destination }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$created = @()
try {
    foreach ($plan in $plans) {
        $temp = Join-Path $output ('.' + [guid]::NewGuid().ToString('N') + '.zip.tmp')
        try {
            [System.IO.Compression.ZipFile]::CreateFromDirectory(
                $plan.Root, $temp, [System.IO.Compression.CompressionLevel]::Optimal, $false)
            $archive = [System.IO.Compression.ZipFile]::OpenRead($temp)
            try {
                $entries = @($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
                if ($entries.Count -ne $plan.Files.Count) {
                    throw "ZIP file-count mismatch for $($plan.Name)"
                }
                foreach ($file in $plan.Files) {
                    $relative = [System.IO.Path]::GetRelativePath($plan.Root, $file.FullName).Replace('\', '/')
                    $entry = $archive.GetEntry($relative)
                    if ($null -eq $entry) { throw "ZIP entry missing: $relative" }
                    $stream = $entry.Open()
                    try {
                        $zipHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream))
                    } finally { $stream.Dispose() }
                    $fileHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                    if ($zipHash -ne $fileHash) { throw "ZIP content mismatch: $relative" }
                }
            } finally { $archive.Dispose() }
            [System.IO.File]::Move($temp, $plan.Destination, $false)
            $created += $plan.Destination
            Write-Output "$($plan.Name): $($plan.Destination)"
            Write-Output "SHA256: $((Get-FileHash -LiteralPath $plan.Destination -Algorithm SHA256).Hash)"
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
        }
    }
} catch {
    # Remove only the archives created in this invocation, never pre-existing files.
    foreach ($file in $created) { Remove-Item -LiteralPath $file -Force }
    throw
}
