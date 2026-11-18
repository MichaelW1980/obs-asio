# Build and audit the OBS-ASIO 3.2.1 Windows x64 MSI.
# Requires PowerShell 7, WiX 6 with WixToolset.UI.wixext, and Windows Forms.
# This initial wrapper intentionally supports 3.2.1 only. Future releases
# require an explicitly reviewed production-upgrade policy and new ProductCode.
#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InstallerSource,

    [Parameter(Mandatory = $true)]
    [string] $StagingDirectory,

    [Parameter(Mandatory = $true)]
    [string] $SourceRoot,

    [Parameter(Mandatory = $true)]
    [string] $IdentityFile,

    [Parameter(Mandatory = $true)]
    [string] $LicenseConverter,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedInnoId = '{77AFA351-2AD0-4997-BBA8-1B1285074A8A}'
$expectedUpgradeCode = '{E8C3A1F0-0E7C-4D1B-8B63-0E58B7E2A152}'
$expectedProductCode321 = '{C208E056-47B4-4A46-BF75-D2D745A91AAB}'
$expectedIdentityHash = '01FF12172BEB7F066D9DBC553E21EE9697EFE3B5A00D21A1858073436288F272'
$expectedSourceHash = 'C7D7403907224A9622485768DE4D6924321F70E7135E9DFBEDA1D2C0AD355C3E'
$expectedConverterHash = 'F6D0C66F237C802C3F4BF84304C4E900626F63F978A342B2892113FD896427CB'

function Get-FullPath {
    param([string] $Path)
    return [System.IO.Path]::GetFullPath(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    ).TrimEnd('\', '/')
}

function Assert-File {
    param([string] $Path, [string] $Description)
    if (-not [System.IO.File]::Exists($Path)) { throw "Missing $Description`: $Path" }
    if ([System.IO.FileInfo]::new($Path).Length -eq 0) { throw "Empty $Description`: $Path" }
}

function Assert-Hash {
    param([string] $Path, [string] $Expected)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "SHA-256 mismatch: $Path"
    }
}

function Test-Within {
    param([string] $Path, [string] $Directory)
    return $Path.StartsWith($Directory.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-MsiRows {
    param($Database, [string] $Sql, [int] $Columns)
    $view = $null
    try {
        $view = $Database.OpenView($Sql)
        [void] $view.Execute()
        while ($record = $view.Fetch()) {
            $values = @()
            for ($i = 1; $i -le $Columns; $i++) {
                $values += [string] $record.StringData($i)
            }
            [pscustomobject] @{ Fields = $values }
        }
    }
    finally {
        if ($null -ne $view) {
            [void] $view.Close()
            [void] [Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
    }
}

$tempDirectory = $null
$createdOutputDirectory = $false
try {
    $installer = Get-FullPath $InstallerSource
    $stage = Get-FullPath $StagingDirectory
    $source = Get-FullPath $SourceRoot
    $identityPath = Get-FullPath $IdentityFile
    $converter = Get-FullPath $LicenseConverter
    $output = Get-FullPath $OutputDirectory

    foreach ($item in @(
        @($installer, 'WiX installer source'),
        @($identityPath, 'identity JSON'),
        @($converter, 'RTF converter'),
        @((Join-Path $source 'LICENSE'), 'repository LICENSE'),
        @((Join-Path $source 'CMakeLists.txt'), 'CMake project file'),
        @((Join-Path $source 'cmake\bundle\windows\installer-Windows.iss.in'), 'Inno template')
    )) {
        Assert-File $item[0] $item[1]
    }
    if (-not [IO.Directory]::Exists($stage)) { throw "Missing staging directory: $stage" }
    if (-not [IO.Directory]::Exists($source)) { throw "Missing source root: $source" }
    if ($output.Equals($stage, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Within $output $stage) -or (Test-Within $stage $output) -or
        $output.Equals($source, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Within $output $source)) {
        throw 'Output must not overlap the staging directory or be inside the source repository.'
    }
    if (-not $installer.EndsWith('.wxs', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'InstallerSource must be a .wxs file.'
    }

    # Freeze the initial release's verified source and identity until reviewed.
    Assert-Hash $installer $expectedSourceHash
    Assert-Hash $identityPath $expectedIdentityHash
    Assert-Hash $converter $expectedConverterHash

    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $productCode = [string] $identity.msiProductCodes.'3.2.1'
    if ($identity.innoAppId -cne $expectedInnoId -or
        $identity.msiUpgradeCode -cne $expectedUpgradeCode -or
        $productCode -cne $expectedProductCode321 -or
        $identity.firstProductionMsiVersion -cne '3.2.1') {
        throw 'Identity contract mismatch.'
    }

    $cmake = [IO.File]::ReadAllText((Join-Path $source 'CMakeLists.txt'))
    $projectMatch = [regex]::Match($cmake, '(?m)^\s*project\s*\(\s*([\w-]+)\s+VERSION\s+(\d+\.\d+\.\d+)\s*\)')
    $authorMatch = [regex]::Match($cmake, '(?m)^\s*set\s*\(\s*PLUGIN_AUTHOR\s+"([^"]+)"\s*\)')
    if (-not $projectMatch.Success -or -not $authorMatch.Success) {
        throw 'Cannot extract authoritative CMake project metadata.'
    }
    $projectName = $projectMatch.Groups[1].Value
    $version = $projectMatch.Groups[2].Value
    $author = $authorMatch.Groups[1].Value
    if ($projectName -cne 'obs-asio' -or $version -cne '3.2.1' -or $author -cne 'Andersama & pkv') {
        throw "Unsupported or unexpected project metadata: $projectName / $version / $author"
    }

    $inno = [IO.File]::ReadAllText((Join-Path $source 'cmake\bundle\windows\installer-Windows.iss.in'))
    if (-not $inno.Contains('AppId={{77AFA351-2AD0-4997-BBA8-1B1285074A8A') -or
        -not $inno.Contains("EnumRelatedMsiProducts('{E8C3A1F0-0E7C-4D1B-8B63-0E58B7E2A152}'")) {
        throw 'Inno AppId or MSI-family detection no longer matches the identity contract.'
    }

    $wxs = [IO.File]::ReadAllText($installer)
    [xml] $xml = $wxs
    $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('w', 'http://wixtoolset.org/schemas/v4/wxs')
    $package = $xml.SelectSingleNode('/w:Wix/w:Package', $ns)
    if ($null -eq $package -or $package.GetAttribute('Name') -cne $projectName -or
        $package.GetAttribute('Manufacturer') -cne $author -or
        $package.GetAttribute('Version') -cne $version -or
        $package.GetAttribute('ProductCode') -cne $productCode -or
        $package.GetAttribute('UpgradeCode') -cne $expectedUpgradeCode -or
        $package.GetAttribute('UpgradeStrategy') -cne 'none') {
        throw 'WiX production metadata or upgrade policy differs from the identity contract.'
    }

    $payloadPaths = @(
        'legacy\obs-plugins\64bit\obs-asio.dll',
        'legacy\data\obs-plugins\obs-asio\data\locale\en-US.ini',
        'modern\plugins\obs-asio\obs-asio.dll',
        'modern\plugins\obs-asio\data\locale\en-US.ini'
    )
    foreach ($relative in $payloadPaths) {
        Assert-File (Join-Path $stage $relative) "staged payload $relative"
    }
    foreach ($pair in @(
        @($payloadPaths[0], $payloadPaths[2]),
        @($payloadPaths[1], $payloadPaths[3])
    )) {
        $left = (Get-FileHash -LiteralPath (Join-Path $stage $pair[0]) -Algorithm SHA256).Hash
        $right = (Get-FileHash -LiteralPath (Join-Path $stage $pair[1]) -Algorithm SHA256).Hash
        if ($left -ne $right) { throw "Staged layouts disagree: $($pair -join ' / ')" }
    }

    $wix = (Get-Command 'wix.exe' -CommandType Application -ErrorAction Stop).Source
    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('obs-asio-msi-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($tempDirectory)
    $tempWxs = Join-Path $tempDirectory 'installer-Windows.wxs'
    $tempRtf = Join-Path $tempDirectory 'GPL-v3-automated.rtf'
    $tempMsi = Join-Path $tempDirectory "obs-asio-$version-Windows-x64.msi"
    [IO.File]::Copy($installer, $tempWxs, $false)

    & $converter -LicensePath (Join-Path $source 'LICENSE') -OutputPath $tempRtf
    Assert-File $tempRtf 'generated GPL RTF'
    & $wix build $tempWxs -arch x64 -ext WixToolset.UI.wixext -d "StageRoot=$stage" -b $tempDirectory -out $tempMsi
    if ($LASTEXITCODE -ne 0) { throw "WiX build failed with exit code $LASTEXITCODE" }
    Assert-File $tempMsi 'compiled MSI'

    # Read-only inspection of the actual MSI database, not the authored XML alone.
    $installerCom = $null
    $database = $null
    try {
        $installerCom = New-Object -ComObject WindowsInstaller.Installer
        $database = $installerCom.OpenDatabase($tempMsi, 0)
        $properties = @{}
        foreach ($row in (Get-MsiRows $database 'SELECT `Property`,`Value` FROM `Property`' 2)) {
            $properties[$row.Fields[0]] = $row.Fields[1]
        }
        $expectedProperties = @{
            ProductName = $projectName
            ProductVersion = $version
            Manufacturer = $author
            ProductCode = $productCode
            UpgradeCode = $expectedUpgradeCode
        }
        foreach ($check in $expectedProperties.GetEnumerator()) {
            if ($properties[$check.Key] -cne $check.Value) {
                throw "Compiled MSI property mismatch: $($check.Key)"
            }
        }
        $upgradeRows = @(Get-MsiRows $database 'SELECT `UpgradeCode`,`VersionMin`,`VersionMax`,`Attributes`,`ActionProperty` FROM `Upgrade`' 5)
        if ($upgradeRows.Count -ne 2) { throw "Expected two Upgrade rows; found $($upgradeRows.Count)." }
        $upgradeProperties = @($upgradeRows | ForEach-Object { $_.Fields[4] } | Sort-Object)
        if (($upgradeProperties -join ',') -cne 'OBSASIONEWER,OBSASIOPROTOTYPE') {
            throw "Unexpected Upgrade action properties: $($upgradeProperties -join ',')"
        }
        foreach ($row in $upgradeRows) {
            if ($row.Fields[0] -cne $expectedUpgradeCode -or $row.Fields[3] -cne '258') {
                throw 'Compiled UpgradeCode or detection-only attributes mismatch.'
            }
            if ($row.Fields[4] -ceq 'OBSASIOPROTOTYPE' -and
                ($row.Fields[1] -cne '0.0.0' -or $row.Fields[2] -cne '3.2.1')) {
                throw 'Historical prototype detection boundary changed.'
            }
            if ($row.Fields[4] -ceq 'OBSASIONEWER' -and
                ($row.Fields[1] -cne '3.2.1' -or $row.Fields[2] -cne '')) {
                throw 'Same/newer version detection boundary changed.'
            }
        }
        $rtfRows = @(Get-MsiRows $database "SELECT ``Text`` FROM ``Control`` WHERE ``Dialog_``='ObsAsioLicenseInfoDlg' AND ``Control``='LicenseText'" 1)
        if ($rtfRows.Count -ne 1 -or $rtfRows[0].Fields[0] -cne [IO.File]::ReadAllText($tempRtf)) {
            throw 'Compiled license RTF differs from the generated RTF.'
        }
        $sequenceRows = @(Get-MsiRows $database "SELECT ``Action``,``Condition`` FROM ``InstallExecuteSequence`` WHERE ``Action``='RemoveExistingProducts'" 2)
        if ($sequenceRows.Count -ne 1 -or $sequenceRows[0].Fields[1] -cne 'OBSPORTABLE <> "1"') {
            throw 'Managed-only RemoveExistingProducts condition changed.'
        }
    }
    finally {
        if ($null -ne $database) { [void] [Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
        if ($null -ne $installerCom) { [void] [Runtime.InteropServices.Marshal]::ReleaseComObject($installerCom) }
    }

    if (-not [IO.Directory]::Exists($output)) {
        [void] [IO.Directory]::CreateDirectory($output)
        $createdOutputDirectory = $true
    }
    $destination = Join-Path $output ([IO.Path]::GetFileName($tempMsi))
    if ([IO.File]::Exists($destination)) { throw "Refusing to overwrite existing MSI: $destination" }
    [IO.File]::Move($tempMsi, $destination, $false)
    [pscustomobject] @{
        Path = $destination
        Bytes = ([IO.FileInfo]::new($destination)).Length
        SHA256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        ProductVersion = $version
        ProductCode = $productCode
        UpgradeCode = $expectedUpgradeCode
        UpgradeRows = 2
        LicenseTextMatch = $true
    }
}
finally {
    if ($null -ne $tempDirectory -and [IO.Directory]::Exists($tempDirectory)) {
        [IO.Directory]::Delete($tempDirectory, $true)
    }
    if ($createdOutputDirectory -and [IO.Directory]::Exists($output) -and
        @([IO.Directory]::EnumerateFileSystemEntries($output)).Count -eq 0) {
        [IO.Directory]::Delete($output)
    }
}
