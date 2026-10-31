#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\install.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Installer parse errors' }
# Load only pure path helpers; never invoke installer actions or bypass its
# running-OBS protection. All fixtures live under one disposable directory.
foreach ($name in @('ConvertTo-AbsolutePath', 'Get-ScriptsDirFromObsRoot')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('obs-path-test-' + [guid]::NewGuid().ToString('N'))
try {
    $expected = Join-Path $root 'data\scripts\obs-game-replay-automation'
    if ((Get-ScriptsDirFromObsRoot $root) -ne $expected) { throw 'Fresh install depends on native plugin layout' }
    $legacy = Join-Path $root 'data\obs-plugins\frontend-tools\scripts'
    New-Item -ItemType Directory -Force $legacy | Out-Null
    if ((Get-ScriptsDirFromObsRoot $root) -ne $expected) { throw 'Empty legacy directory selected' }
    [IO.File]::WriteAllText((Join-Path $legacy 'game-replay-auto.lua'), '-- fixture')
    if ((Get-ScriptsDirFromObsRoot $root) -ne $legacy) { throw 'Existing script path lost during upgrade' }
    Write-Host '3 installer path compatibility checks passed'
} finally {
    $full = [IO.Path]::GetFullPath($root)
    if ((Split-Path $full -Parent) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and
        (Split-Path $full -Leaf) -like 'obs-path-test-*') { Remove-Item -LiteralPath $full -Recurse -Force }
}
