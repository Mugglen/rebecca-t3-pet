param([ValidateSet('live','demo')][string]$Mode='live',[string]$ConfigPath='', [switch]$SmokeTest, [int]$SmokeSeconds=2, [ValidateRange(0,600)][int]$AutoCloseSeconds=0)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
try {
    if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)) -ine 'D:\') { throw 'Rebecca must run from a D: project directory.' }
    [IO.Directory]::CreateDirectory((Join-Path $root 'tmp'))|Out-Null
    $env:TEMP=Join-Path $root 'tmp';$env:TMP=$env:TEMP
    $env:PSModuleAnalysisCachePath=Join-Path $env:TEMP 'PowerShellModuleCache'
    Import-Module (Join-Path $root 'app\Desktop.psm1') -Force
    $root=Assert-RebeccaOutputRoot $root
    $config=Read-RebeccaConfig $root $ConfigPath
    & (Join-Path $root 'app\Pet.ps1') -ProjectRoot $root -Config $config -Mode $Mode -SmokeTest:$SmokeTest -SmokeSeconds $SmokeSeconds -AutoCloseSeconds $AutoCloseSeconds
} catch {
    $message=$_.Exception.Message
    if($SmokeTest){throw}
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show(('瑞贝卡未能启动。'+[Environment]::NewLine+$message+[Environment]::NewLine+'请检查 config.local.json 与 README。'),'Rebecca · T3 Pet')|Out-Null
    exit 1
}
