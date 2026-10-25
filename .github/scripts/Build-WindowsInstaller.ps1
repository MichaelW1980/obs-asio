# Build the standalone, OBS-version-aware Inno Setup installer.
# Requires PowerShell 7 and a configured .iss script (not an .iss.in template).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerScript,

    [Parameter(Mandatory = $true)]
    [string]$StagingDirectory,

    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-WithinDirectory {
    param([string]$Path, [string]$Directory)
    $prefix = $Directory.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-File {
    param([string]$Path, [string]$Description)
    if (-not [System.IO.File]::Exists($Path)) {
        throw "Missing $Description`: $Path"
    }
    if (([System.IO.FileInfo]::new($Path)).Length -eq 0) {
        throw "Empty $Description`: $Path"
    }
}

$tempDirectory = $null
$createdOutputDirectory = $false
try {
    $installer = Get-FullPath $InstallerScript
    $stage = Get-FullPath $StagingDirectory
    $source = Get-FullPath $SourceRoot
    $output = Get-FullPath $OutputDirectory

    Assert-File $installer 'configured Inno Setup script'
    if ($installer.EndsWith('.iss.in', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $installer.EndsWith('.iss', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallerScript must name a configured .iss file, not a .iss.in template.'
    }
    if (-not [System.IO.Directory]::Exists($stage)) { throw "StagingDirectory does not exist: $stage" }
    if (-not [System.IO.Directory]::Exists($source)) { throw "SourceRoot does not exist: $source" }

    if ($output.Equals($stage, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Test-WithinDirectory $output $stage) -or
        (Test-WithinDirectory $stage $output)) {
        throw 'OutputDirectory and StagingDirectory must not be the same or nested within one another.'
    }

    $payloads = @(
        'legacy\obs-plugins\64bit\obs-asio.dll',
        'legacy\data\obs-plugins\obs-asio\data\locale\en-US.ini',
        'modern\plugins\obs-asio\obs-asio.dll',
        'modern\plugins\obs-asio\data\locale\en-US.ini'
    )
    foreach ($relativePath in $payloads) {
        Assert-File (Join-Path $stage $relativePath) "staged payload '$relativePath'"
    }
    Assert-File (Join-Path $source 'LICENSE') 'source LICENSE'

    $compiler = Get-Command 'ISCC.exe' -CommandType Application -ErrorAction Stop
    $compilerPath = $compiler.Source
    Assert-File $compilerPath 'Inno Setup compiler'

    # A unique, isolated compiler destination keeps incomplete builds out of OutputDirectory.
    $tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('obs-asio-inno-' + [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

    & $compilerPath "/DStageRoot=$stage" "/DSourceRoot=$source" "/O$tempDirectory" $installer
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed with exit code $LASTEXITCODE." }

    $results = @(Get-ChildItem -LiteralPath $tempDirectory -Filter '*.exe' -File)
    if ($results.Count -ne 1) {
        throw "Expected exactly one generated EXE; found $($results.Count)."
    }
    $exe = $results[0]
    Assert-File $exe.FullName 'compiled installer EXE'

    if (-not [System.IO.Directory]::Exists($output)) {
        [System.IO.Directory]::CreateDirectory($output) | Out-Null
        $createdOutputDirectory = $true
    }
    $destination = Join-Path $output $exe.Name
    if ([System.IO.File]::Exists($destination)) {
        throw "Refusing to overwrite existing EXE: $destination"
    }

    # overwrite=false also guards against races after the explicit destination check.
    [System.IO.File]::Move($exe.FullName, $destination, $false)
    $final = Get-Item -LiteralPath $destination
    [pscustomobject]@{
        Path   = $final.FullName
        Bytes  = $final.Length
        SHA256 = (Get-FileHash -LiteralPath $final.FullName -Algorithm SHA256).Hash
    }
}
finally {
    if ($null -ne $tempDirectory -and [System.IO.Directory]::Exists($tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
    if ($createdOutputDirectory -and [System.IO.Directory]::Exists($output) -and
        @([System.IO.Directory]::EnumerateFileSystemEntries($output)).Count -eq 0) {
        [System.IO.Directory]::Delete($output)
    }
}
