#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $LicensePath,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$temporaryPath = $null

try {
    if (-not (Test-Path -LiteralPath $LicensePath -PathType Leaf)) {
        throw "License file not found: $LicensePath"
    }

    if (Test-Path -LiteralPath $OutputPath) {
        throw "Output already exists; refusing overwrite: $OutputPath"
    }

    $outputDirectory = Split-Path -Parent $OutputPath

    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Output directory does not exist: $outputDirectory"
    }

    # Read the authoritative license without modifying it.
    $licenseBytes = [System.IO.File]::ReadAllBytes($LicensePath)

    foreach ($byte in $licenseBytes) {
        if ($byte -gt 127) {
            throw 'Non-ASCII license content detected; encoding review required.'
        }
    }

    $original = [System.Text.Encoding]::ASCII.GetString($licenseBytes)

    # Escape RTF control characters.
    $escaped = $original.Replace('\', '\\')
    $escaped = $escaped.Replace('{', '\{')
    $escaped = $escaped.Replace('}', '\}')

    # Convert source line endings into RTF paragraph commands.
    $escaped = [regex]::Replace(
        $escaped,
        '\r\n|\r|\n',
        "\par`r`n"
    )

    # Add a final paragraph terminator to compensate for
    # RichTextBox omitting the last paragraph break on extraction.
    $rtf = "{\rtf1\ansi\deff0{\fonttbl{\f0 Courier New;}}\f0\fs18`r`n" +
           $escaped +
           "\par`r`n`r`n}"

    # Create a unique staging file in the destination directory.
    $temporaryPath = Join-Path $outputDirectory (
        '.license-' + [guid]::NewGuid().ToString('N') + '.rtf'
    )

    [System.IO.File]::WriteAllText(
        $temporaryPath,
        $rtf,
        [System.Text.Encoding]::ASCII
    )

    # Validate the RTF using the Windows RichTextBox parser.
    Add-Type -AssemblyName System.Windows.Forms

    $reader = [System.Windows.Forms.RichTextBox]::new()

    try {
        $reader.LoadFile(
            $temporaryPath,
            [System.Windows.Forms.RichTextBoxStreamType]::RichText
        )

        $expected = $original.Replace("`r`n", "`n").Replace("`r", "`n")
        $actual = $reader.Text.Replace("`r`n", "`n").Replace("`r", "`n")

        if ($expected -cne $actual) {
            $index = 0
            $limit = [Math]::Min($expected.Length, $actual.Length)

            while (
                $index -lt $limit -and
                $expected[$index] -ceq $actual[$index]
            ) {
                $index++
            }

            throw "RTF validation failed at character index $index."
        }
    }
    finally {
        $reader.Dispose()
    }

    # Publish only the successfully validated resource.
    # Move-Item does not provide overwrite protection by itself.
    if (Test-Path -LiteralPath $OutputPath) {
        throw 'Output appeared during validation; refusing overwrite.'
    }

    [System.IO.File]::Move($temporaryPath, $OutputPath)
    $temporaryPath = $null

    Write-Output 'License RTF generation: PASS'
    Write-Output "Source: $LicensePath"
    Write-Output "Output: $OutputPath"
    Write-Output "Characters: $($expected.Length)"
    Write-Output 'ExactTextMatch: True'
    Write-Output "Bytes: $((Get-Item -LiteralPath $OutputPath).Length)"
    Write-Output "SHA256: $((Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash)"
}
finally {
    if (
        $null -ne $temporaryPath -and
        (Test-Path -LiteralPath $temporaryPath)
    ) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}
