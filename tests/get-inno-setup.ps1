#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Use a fresh directory for the verified portable compiler.' }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$download = Join-Path $Destination 'innosetup-7.1.1-x64.exe'
Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-7_1_1/innosetup-7.1.1-x64.exe' -OutFile $download
$expectedHash = '8a5a6711c3766a6e5fb74f280ba0e3551e719ce94538d901fdbd1f8f9920b3f0'
if ((Get-FileHash -LiteralPath $download).Hash -ine $expectedHash) { throw 'Inno Setup SHA-256 verification failed.' }
$signature = Get-AuthenticodeSignature -FilePath $download
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Pyrsys B\.V\.') {
    throw 'Inno Setup publisher verification failed.'
}
$portable = Join-Path $Destination 'compiler'
$process = Start-Process -FilePath $download -ArgumentList @('/PORTABLE=1', '/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', ('/DIR="' + $portable + '"')) -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $portable 'ISCC.exe'))) {
    throw "Portable compiler extraction failed: $($process.ExitCode)"
}
Write-Host "Verified portable compiler: $portable\ISCC.exe"
