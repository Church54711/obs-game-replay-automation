#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$headers = @{ 'User-Agent' = 'obs-game-replay-compatibility' }
if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
if ($Version -ne 'latest' -and $Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected stable version or latest' }
$endpoint = if ($Version -eq 'latest') { 'latest' } else { "tags/$Version" }
$release = Invoke-RestMethod "https://api.github.com/repos/obsproject/obs-studio/releases/$endpoint" -Headers $headers
$assets = @($release.assets | Where-Object { $_.name -eq "OBS-Studio-$($release.tag_name)-Windows-x64.zip" })
if ($assets.Count -ne 1) { throw 'Expected exactly one official Windows x64 ZIP' }
$asset = $assets[0]
if ($asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Official asset lacks a SHA-256 digest' }
$full = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $full) { throw "Use a fresh download destination: $full" }
New-Item -ItemType Directory -Force $full | Out-Null
$zip = Join-Path $full 'obs.zip'
Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
if ('sha256:' + (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant() -ne $asset.digest) { throw 'OBS ZIP digest mismatch' }
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $full 'runtime')
Write-Host "Verified OBS $($release.tag_name): $(Join-Path $full 'runtime')"
