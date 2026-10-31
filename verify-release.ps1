#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$ChecksumPath,
    [switch]$RequireSignature,
    [ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$ExpectedThumbprint,
    [switch]$SignatureOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Path = (Resolve-Path -LiteralPath $Path).Path
if ($SignatureOnly -and -not $RequireSignature) { throw 'SignatureOnly requires RequireSignature.' }
if ($ExpectedThumbprint) { $RequireSignature = $true }
if (-not $SignatureOnly) {
    if (-not $ChecksumPath) { $ChecksumPath = "$Path.sha256.txt" }
    $checksum = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ChecksumPath).Path).Trim()
    $match = [regex]::Match($checksum, '^([a-fA-F0-9]{64})  (.+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne [IO.Path]::GetFileName($Path)) { throw 'Checksum must name exactly this artifact.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $match.Groups[1].Value) { throw 'Release checksum mismatch.' }
}
$signatureStatus = 'NotApplicable'
if ([IO.Path]::GetExtension($Path) -eq '.exe') {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signatureStatus = [string]$signature.Status
    if ($signatureStatus -notin @('Valid', 'NotSigned')) { throw "Invalid installer signature: $signatureStatus" }
    if ($RequireSignature) {
        if ($signatureStatus -ne 'Valid' -or $null -eq $signature.TimeStamperCertificate) { throw 'A trusted, timestamped signature is required.' }
        if ($ExpectedThumbprint -and $signature.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) { throw 'Unexpected signing certificate.' }
    }
} elseif ($RequireSignature) { throw 'Authenticode verification requires a Windows EXE.' }
Write-Host "Verified $([IO.Path]::GetFileName($Path)); Authenticode: $signatureStatus"
