#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Clip,
    [Parameter(Mandatory = $true)][string]$EvidenceDir
)
$ErrorActionPreference = 'Stop'
$video = Join-Path $EvidenceDir 'capture-frames.rgb'
$audio = Join-Path $EvidenceDir 'capture-tone.pcm'
# Decode the saved replay, not a preview or an OBS source-settings snapshot.
& ffmpeg -nostdin -v error -y -i $Clip -map 0:v:0 -vf 'scale=1:1' -pix_fmt rgb24 -f rawvideo $video
if ($LASTEXITCODE -ne 0) { throw 'Replay video decode failed.' }
& ffmpeg -nostdin -v error -y -i $Clip -map 0:a:0 -ac 1 -ar 48000 -f s16le $audio
if ($LASTEXITCODE -ne 0) { throw 'Replay audio decode failed.' }
$frames = [IO.File]::ReadAllBytes($video)
if ($frames.Length -lt 30) { throw 'Replay has fewer than ten decoded frames.' }
$red = for ($i=0; $i -lt $frames.Length; $i+=3) { [int]$frames[$i] }
$range = ($red | Measure-Object -Maximum -Minimum)
if ($range.Maximum - $range.Minimum -lt 50) { throw 'Captured video is blank or does not contain the animated fixture.' }
$pcm = [IO.File]::ReadAllBytes($audio)
$samples = [int]($pcm.Length / 2)
if ($samples -lt 48000) { throw 'Replay has less than one second of decoded audio.' }
$rms = 0.0; $frequency = 0
# Startup audio can be silent while the process loopback activates. Require a
# full decoded second of the expected tone, rather than dividing crossings by
# those silent startup samples and reporting an artificially low frequency.
for ($start=0; $start + 48000 -le $samples; $start+=48000) {
    $sum = 0.0; $crossings = 0; $previous = 0
    for ($i=$start; $i -lt $start+48000; $i++) {
        $sample = [BitConverter]::ToInt16($pcm, $i*2)
        $sum += [double]$sample * $sample
        if ($previous -lt 0 -and $sample -ge 0) { $crossings++ }
        $previous = $sample
    }
    $windowRms = [Math]::Sqrt($sum / 48000)
    if ($windowRms -gt $rms) { $rms = $windowRms; $frequency = $crossings }
}
if ($rms -lt 2 -or $frequency -lt 430 -or $frequency -gt 450) { throw "Application audio lacks the expected 440 Hz tone: RMS=$rms, Hz=$frequency" }
@{ decodedFrames=[int]($frames.Length/3); redRange=($range.Maximum-$range.Minimum); audioSamples=$samples; audioRms=$rms; toneHz=$frequency } |
    ConvertTo-Json | Set-Content (Join-Path $EvidenceDir 'capture-media.json')
Write-Host "PASS decoded motion and application audio ($([Math]::Round($frequency,1)) Hz)"
