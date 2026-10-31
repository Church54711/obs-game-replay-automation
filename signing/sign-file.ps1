#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Inno calls this for Setup, temporary loaders, and the embedded uninstaller.
# Secrets never appear in the compiler command line or the source tree.
$thumbprint = $env:REPLAY_SIGNING_THUMBPRINT
if ($thumbprint -notmatch '^[A-Fa-f0-9]{40}$') { throw 'Select an explicit code-signing certificate thumbprint.' }
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint"
$usages = @($certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
    ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or
    $certificate.NotBefore -gt (Get-Date) -or
    '1.3.6.1.5.5.7.3.3' -notin $usages) {
    throw 'The selected certificate must be current and have a code-signing private key.'
}
$timestamp = $env:REPLAY_SIGNING_TIMESTAMP_URL
$uri = $null
if (-not [Uri]::TryCreate($timestamp, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
    throw 'Set an HTTPS RFC 3161 timestamp URL.'
}
$signTool = $env:REPLAY_SIGNTOOL_PATH
if (-not $signTool -or -not (Test-Path -LiteralPath $signTool -PathType Leaf)) { throw 'Windows SDK SignTool was not found.' }
& $signTool sign /sha1 $thumbprint /s My /fd SHA256 /tr $timestamp /td SHA256 $Path
if ($LASTEXITCODE -ne 0) { throw "SignTool signing failed: $LASTEXITCODE" }
& $signTool verify /pa /all /tw $Path
if ($LASTEXITCODE -ne 0) { throw "SignTool verification failed: $LASTEXITCODE" }
& (Join-Path $PSScriptRoot '..\verify-release.ps1') -Path $Path -RequireSignature -ExpectedThumbprint $thumbprint -SignatureOnly
