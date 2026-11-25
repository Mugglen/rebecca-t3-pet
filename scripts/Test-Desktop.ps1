param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'app\Desktop.psm1') -Force
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('tmp\desktop-smoke-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
$OutputDirectory=Assert-RebeccaOutputRoot $OutputDirectory
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$env:TEMP=$OutputDirectory;$env:TMP=$OutputDirectory
$path=Join-Path $OutputDirectory 'snapshot.json'
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Write-Snapshot($Value){[IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 8 -Compress),(New-Object Text.UTF8Encoding($false)))}
function New-TestSnapshot {
    return [pscustomobject]@{schema_version=1;observed_at=[DateTimeOffset]::UtcNow.ToString('o');mode='live';state='working';message='正在处理 2 个任务';source=[pscustomobject]@{kind='fixture';version='0.1.11';health='connected'};counts=[pscustomobject]@{working=2;waiting_user=0;pending=1;failed=0};event=$null}
}
$snapshot=New-TestSnapshot;Write-Snapshot $snapshot
$read=Get-RebeccaSnapshot $path 2 'live';Assert-Test ($read.state -eq 'working' -and $read.counts.pending -eq 1) 'Valid live snapshot rejected.'
$snapshot.observed_at=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'offline') 'Stale status was not marked offline.'
$snapshot=New-TestSnapshot;$snapshot.schema_version=2;Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Unknown schema accepted.'
$snapshot=New-TestSnapshot;$snapshot.counts.working='2';Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'String count accepted.'
$snapshot=New-TestSnapshot;$snapshot.state='made-up';Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Unknown state accepted.'
$snapshot=New-TestSnapshot;$snapshot.source.health='disconnected';Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Disconnected working snapshot accepted.'
$snapshot=New-TestSnapshot;$snapshot.observed_at=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o');Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Future timestamp accepted.'
$snapshot=New-TestSnapshot;Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'demo').state -eq 'incompatible') 'Live snapshot passed as demo.'
$snapshot.mode='demo';Write-Snapshot $snapshot
Assert-Test ((Get-RebeccaSnapshot $path 2 'demo').mode -eq 'demo') 'Demo snapshot rejected.'
[IO.File]::WriteAllText($path,'{broken')
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Malformed JSON accepted.'
[IO.File]::WriteAllText($path,('x'*65537))
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Oversized JSON accepted.'
[IO.File]::WriteAllText($path,((New-TestSnapshot)|ConvertTo-Json -Depth 8),[Text.Encoding]::Unicode)
Assert-Test ((Get-RebeccaSnapshot $path 2 'live').state -eq 'incompatible') 'Non-UTF8 JSON accepted.'
Assert-Test ((Get-RebeccaSnapshot (Join-Path $OutputDirectory 'missing.json') 2 'live').state -eq 'offline') 'Missing file accepted.'
$rejected=$false;try{Assert-RebeccaOutputRoot 'C:\temp\rebecca'|Out-Null}catch{$rejected=$true};Assert-Test $rejected 'C drive output was accepted.'

$config=@{scale=1.0;topmost=$true;project_ids=@()}
$view=New-RebeccaView $root $config 'live'
$view.Paused=$true
try{
    Assert-Test ($view.Frames.Count -eq 6) 'Atlas did not load six frames.'
    Assert-Test ([Windows.Media.RenderOptions]::GetBitmapScalingMode($view.Character) -eq 'HighQuality') 'High quality bitmap scaling was not enabled.'
    Assert-Test ($view.Window.AllowsTransparency -and $view.Window.WindowStyle -eq 'None' -and -not $view.Window.ShowActivated) 'Window properties do not match desktop requirements.'
    $view.Window.Left=-10000;$view.Window.Top=-10000;$view.Window.Show()
    foreach($state in @('idle','working','attention','success','error','stopped','offline','incompatible')){
        $snapshot=New-TestSnapshot;$snapshot.state=$state
        Set-RebeccaVisual $view $snapshot
        Assert-Test ($null -ne $view.Character.Source -and $view.State -eq $state) ('Missing visual for '+$state)
    }
    $snapshot=New-TestSnapshot;Set-RebeccaVisual $view $snapshot
    $view.Window.UpdateLayout()
    $render=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$view.Window.Width,[int]$view.Window.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($view.Window)
    $png=New-Object Windows.Media.Imaging.PngBitmapEncoder;$png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $stream=[IO.File]::Create((Join-Path $OutputDirectory 'desktop-working.png'));try{$png.Save($stream)}finally{$stream.Dispose()}
    Set-RebeccaSize $view 2;Assert-Test ($view.Scale -eq 1.6) 'Maximum scale not clamped.'
    Set-RebeccaSize $view 0.1;Assert-Test ($view.Scale -eq 0.6) 'Minimum scale not clamped.'
    Reset-RebeccaPosition $view
    $settingsPath=Join-Path $OutputDirectory 'settings.json';Save-RebeccaViewState $view $settingsPath
    Restore-RebeccaViewState $view $settingsPath
    Assert-Test ([IO.File]::Exists($settingsPath)) 'View preferences not saved.'
}finally{$view.Window.Close()}
$animationResult=& (Join-Path $PSScriptRoot 'Test-Animation.ps1') -OutputDirectory (Join-Path $OutputDirectory 'animation') -PassThru
$result=[ordered]@{checks=$script:checks;animation_checks=$animationResult.checks;result='passed';mode='synthetic';render=(Join-Path $OutputDirectory 'desktop-working.png');manual_validation='Multi-monitor DPI, pointer hit testing, drag and visual polish remain manual.'}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($result|ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json
