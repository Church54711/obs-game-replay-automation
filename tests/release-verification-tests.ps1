#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$SetupPath)
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot '..\verify-release.ps1'
& $verify -Path $SetupPath
if ((Get-AuthenticodeSignature -LiteralPath $SetupPath).Status -eq 'NotSigned') {
    $rejected = $false
    try { & $verify -Path $SetupPath -RequireSignature } catch { $rejected = $_.Exception.Message -match 'trusted, timestamped signature' }
    if (-not $rejected) { throw 'Unsigned installer was accepted when a signature was required.' }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('replay-checksum-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($temp, ('0' * 64) + '  ' + [IO.Path]::GetFileName($SetupPath))
    $rejected = $false
    try { & $verify -Path $SetupPath -ChecksumPath $temp } catch { $rejected = $_.Exception.Message -match 'checksum mismatch' }
    if (-not $rejected) { throw 'Incorrect release digest was accepted.' }
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS release checksum and signature policy'
