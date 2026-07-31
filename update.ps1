#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Repository,
    [switch]$CheckOnly,
    [switch]$Notify,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$NoStartMenuShortcut,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function ConvertTo-SemanticVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = $Value.Trim()
    $pattern = '^v?(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>[0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$'
    if ($trimmed -notmatch $pattern) {
        throw "Invalid semantic version: $Value"
    }

    return [pscustomobject]@{
        Original = $trimmed.TrimStart('v')
        Major = [long]$Matches.major
        Minor = [long]$Matches.minor
        Patch = [long]$Matches.patch
        Prerelease = [string]$Matches['prerelease']
    }
}

function Compare-PrereleaseIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftNumeric = $Left -match '^\d+$'
    $rightNumeric = $Right -match '^\d+$'
    if ($leftNumeric -and $rightNumeric) {
        $leftNumber = [System.Numerics.BigInteger]::Parse($Left)
        $rightNumber = [System.Numerics.BigInteger]::Parse($Right)
        return $leftNumber.CompareTo($rightNumber)
    }
    if ($leftNumeric -and -not $rightNumeric) {
        return -1
    }
    if (-not $leftNumeric -and $rightNumeric) {
        return 1
    }
    return [string]::CompareOrdinal($Left, $Right)
}

function Compare-SemanticVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftVersion = ConvertTo-SemanticVersion -Value $Left
    $rightVersion = ConvertTo-SemanticVersion -Value $Right
    foreach ($part in @('Major', 'Minor', 'Patch')) {
        if ($leftVersion.$part -lt $rightVersion.$part) {
            return -1
        }
        if ($leftVersion.$part -gt $rightVersion.$part) {
            return 1
        }
    }

    $leftPrerelease = [string]$leftVersion.Prerelease
    $rightPrerelease = [string]$rightVersion.Prerelease
    if ([string]::IsNullOrWhiteSpace($leftPrerelease) -and [string]::IsNullOrWhiteSpace($rightPrerelease)) {
        return 0
    }
    if ([string]::IsNullOrWhiteSpace($leftPrerelease)) {
        return 1
    }
    if ([string]::IsNullOrWhiteSpace($rightPrerelease)) {
        return -1
    }

    $leftParts = $leftPrerelease.Split('.')
    $rightParts = $rightPrerelease.Split('.')
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $leftParts.Count) {
            return -1
        }
        if ($index -ge $rightParts.Count) {
            return 1
        }
        $comparison = Compare-PrereleaseIdentifier -Left $leftParts[$index] -Right $rightParts[$index]
        if ($comparison -lt 0) {
            return -1
        }
        if ($comparison -gt 0) {
            return 1
        }
    }
    return 0
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-ExpectedChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$ExpectedFileName
    )

    $escapedName = [regex]::Escape($ExpectedFileName)
    $match = [regex]::Match($Content.Trim(), "(?i)^(?<hash>[a-f0-9]{64})\s+\*?$escapedName$")
    if (-not $match.Success) {
        throw "The release checksum file is invalid or does not name $ExpectedFileName."
    }
    return $match.Groups['hash'].Value.ToLowerInvariant()
}

function Assert-UpdateArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ExtractedDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $versionPath = Join-Path $ExtractedDirectory 'VERSION'
    $manifestPath = Join-Path $ExtractedDirectory 'manifest.json'
    $installerPath = Join-Path $ExtractedDirectory 'install.ps1'
    $licensePath = Join-Path $ExtractedDirectory 'LICENSE'
    foreach ($requiredPath in @($versionPath, $manifestPath, $installerPath, $licensePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "The downloaded update is missing $([System.IO.Path]::GetFileName($requiredPath))."
        }
    }

    $archiveVersion = [System.IO.File]::ReadAllText($versionPath).Trim()
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($archiveVersion -ne $ExpectedVersion -or [string]$manifest.version -ne $ExpectedVersion) {
        throw "Downloaded package version metadata does not match release $ExpectedVersion."
    }
    if ([string]$manifest.license -ne '0BSD') {
        throw 'Downloaded package license metadata is missing or invalid.'
    }
    return $installerPath
}

function Remove-UpdateTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $leaf = [System.IO.Path]::GetFileName($fullPath)
    if (-not $fullPath.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('obs-game-replay-update-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected temporary directory: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Show-UpdateNotification {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentVersion,
        [Parameter(Mandatory = $true)][string]$LatestVersion
    )

    if (-not [Environment]::UserInteractive) {
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $message = "OBS Game Replay Automation $LatestVersion is available (installed: $CurrentVersion)." +
            [Environment]::NewLine + [Environment]::NewLine +
            "Close OBS before installing. Open the updater now?"
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $message,
            'OBS Game Replay Automation update',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $launcher = Join-Path $PSScriptRoot 'Update OBS Game Replay Automation.cmd'
            if (Test-Path -LiteralPath $launcher -PathType Leaf) {
                Start-Process -FilePath $launcher -WorkingDirectory $PSScriptRoot
            }
        }
    } catch {
        Write-Warning "Update $LatestVersion is available, but the desktop notification could not be shown: $($_.Exception.Message)"
    }
}

function Wait-ForObsToClose {
    if ($null -eq (Get-Process -Name 'obs64' -ErrorAction SilentlyContinue)) {
        return $true
    }
    if ($NonInteractive) {
        throw 'OBS Studio is running. Close OBS completely, then run the updater again.'
    }

    while ($null -ne (Get-Process -Name 'obs64' -ErrorAction SilentlyContinue)) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "OBS Studio must be closed before updating.`r`n`r`nClose OBS completely, then choose Retry.",
                'OBS Game Replay Automation update',
                [System.Windows.Forms.MessageBoxButtons]::RetryCancel,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                return $false
            }
        } catch {
            Write-Host 'OBS Studio must be closed before updating.'
            $answer = Read-Host 'Close OBS, then press Enter to retry; type cancel to stop'
            if ($answer -match '^(?i)cancel$') {
                return $false
            }
        }
    }
    return $true
}

function Invoke-UpdaterSelfTest {
    $cases = @(
        @('0.4.0', '0.4.0', 0),
        @('0.3.2', '0.4.0', -1),
        @('1.0.0', '0.9.9', 1),
        @('1.0.0-beta.2', '1.0.0-beta.10', -1),
        @('1.0.0-rc.1', '1.0.0', -1),
        @('v2.0.0', '2.0.0', 0)
    )
    foreach ($case in $cases) {
        $actual = Compare-SemanticVersion -Left $case[0] -Right $case[1]
        $normalized = if ($actual -lt 0) { -1 } elseif ($actual -gt 0) { 1 } else { 0 }
        if ($normalized -ne $case[2]) {
            throw "Semantic-version comparison failed for $($case[0]) and $($case[1])."
        }
    }

    $sampleHash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    $parsedHash = Get-ExpectedChecksum -Content "$sampleHash  package.zip`n" -ExpectedFileName 'package.zip'
    if ($parsedHash -ne $sampleHash) {
        throw 'Checksum parsing self-test failed.'
    }
    Write-Host 'Updater self-tests passed.'
}

if ($SelfTest) {
    Invoke-UpdaterSelfTest
    return
}

$versionPath = Join-Path $PSScriptRoot 'VERSION'
$manifestPath = Join-Path $PSScriptRoot 'manifest.json'
foreach ($requiredPath in @($versionPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Installed update metadata is missing: $requiredPath"
    }
}

$currentVersion = [System.IO.File]::ReadAllText($versionPath).Trim()
$null = ConvertTo-SemanticVersion -Value $currentVersion
$installedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$installedManifest.version -ne $currentVersion) {
    throw "Installed VERSION and manifest.json do not agree. Reinstall the current release before updating."
}
if ([string]::IsNullOrWhiteSpace($Repository)) {
    $updates = Get-OptionalPropertyValue -InputObject $installedManifest -Name 'updates'
    if ($null -ne $updates) {
        $Repository = [string](Get-OptionalPropertyValue -InputObject $updates -Name 'repository')
    }
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "The GitHub update repository is missing or invalid: $Repository"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$apiUrl = "https://api.github.com/repos/$Repository/releases/latest"
$headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = "obs-game-replay-automation-updater/$currentVersion"
    'X-GitHub-Api-Version' = '2022-11-28'
}

Write-Host "Checking GitHub for OBS Game Replay Automation updates..."
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
if ([bool]$release.draft -or [bool]$release.prerelease) {
    throw 'GitHub returned a draft or prerelease from the stable update endpoint.'
}
$latestVersion = ([string]$release.tag_name).TrimStart('v')
$null = ConvertTo-SemanticVersion -Value $latestVersion
$comparison = Compare-SemanticVersion -Left $currentVersion -Right $latestVersion
if ($comparison -gt 0) {
    Write-Host "Installed version $currentVersion is newer than published version $latestVersion."
    return
}
if ($comparison -eq 0 -and -not $Force) {
    Write-Host "OBS Game Replay Automation $currentVersion is up to date."
    return
}

Write-Host "Update available: $currentVersion -> $latestVersion"
if ($CheckOnly) {
    if ($Notify) {
        Show-UpdateNotification -CurrentVersion $currentVersion -LatestVersion $latestVersion
    }
    return
}
if (-not (Wait-ForObsToClose)) {
    Write-Host 'Update cancelled.'
    return
}

$zipName = "obs-game-replay-automation-$latestVersion.zip"
$checksumName = "$zipName.sha256.txt"
$zipAsset = @($release.assets | Where-Object { [string]$_.name -eq $zipName })
$checksumAsset = @($release.assets | Where-Object { [string]$_.name -eq $checksumName })
if ($zipAsset.Count -ne 1 -or $checksumAsset.Count -ne 1) {
    throw "Release $latestVersion does not contain the expected package and checksum assets."
}

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("obs-game-replay-update-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDirectory | Out-Null
try {
    $zipPath = Join-Path $tempDirectory $zipName
    $checksumPath = Join-Path $tempDirectory $checksumName
    Invoke-WebRequest -Uri $zipAsset[0].browser_download_url -Headers $headers -OutFile $zipPath -UseBasicParsing
    Invoke-WebRequest -Uri $checksumAsset[0].browser_download_url -Headers $headers -OutFile $checksumPath -UseBasicParsing

    $expectedHash = Get-ExpectedChecksum `
        -Content ([System.IO.File]::ReadAllText($checksumPath)) `
        -ExpectedFileName $zipName
    $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Downloaded package checksum mismatch. Expected $expectedHash but received $actualHash."
    }
    $assetDigest = [string](Get-OptionalPropertyValue -InputObject $zipAsset[0] -Name 'digest')
    if (-not [string]::IsNullOrWhiteSpace($assetDigest) -and
        $assetDigest -notmatch "^(?i)sha256:$actualHash$") {
        throw "GitHub's release-asset digest does not match the downloaded package."
    }

    $extractDirectory = Join-Path $tempDirectory 'package'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDirectory
    $installerPath = Assert-UpdateArchive -ExtractedDirectory $extractDirectory -ExpectedVersion $latestVersion

    $escapedInstaller = $installerPath.Replace("'", "''")
    $escapedScriptsDirectory = $PSScriptRoot.Replace("'", "''")
    $command = "& '$escapedInstaller' -ScriptsDir '$escapedScriptsDirectory' -NonInteractive"
    if ($NoStartMenuShortcut) {
        $command += ' -NoStartMenuShortcut'
    }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The installer exited with code $($process.ExitCode)."
    }
    Write-Host "Updated OBS Game Replay Automation to $latestVersion."
    Write-Host 'Existing settings and replay output folder were preserved.'
} finally {
    Remove-UpdateTempDirectory -Path $tempDirectory
}
