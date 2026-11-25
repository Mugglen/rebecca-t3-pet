param([string]$OutputDirectory='',[switch]$PassThru)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'app\Desktop.psm1') -Force
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('tmp\topmost-smoke-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
$OutputDirectory=Assert-RebeccaOutputRoot $OutputDirectory
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$env:TEMP=$OutputDirectory;$env:TMP=$OutputDirectory
if(-not ('RebeccaPet.TopmostTestNative' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RebeccaPet {
    public static class TopmostTestNative {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
        [DllImport("user32.dll")] private static extern IntPtr GetTopWindow(IntPtr hwnd);
        public static bool IsAbove(IntPtr first, IntPtr second) {
            IntPtr hwnd = GetTopWindow(IntPtr.Zero);
            for (int i = 0; hwnd != IntPtr.Zero && i < 4096; i++) {
                if (hwnd == first) return true;
                if (hwnd == second) return false;
                hwnd = GetWindow(hwnd, 2);
            }
            return false;
        }
    }
}
'@
}
$script:topmostChecks=0
function Assert-Topmost([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:topmostChecks++}
function Pump-TopmostDispatcher([int]$Milliseconds){
    $frame=New-Object Windows.Threading.DispatcherFrame
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $handler=[EventHandler]{param($sender,$eventArgs) $sender.Stop();$frame.Continue=$false}.GetNewClosure()
    $timer.Add_Tick($handler)
    try{$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$timer.Stop();$timer.Remove_Tick($handler)}
}
function Test-NativeTopmost([IntPtr]$Handle){return (([RebeccaPet.WindowLayerNative]::GetWindowLongW($Handle,-20) -band 8) -ne 0)}
function Set-TestNativeLayer([IntPtr]$Handle,[bool]$Enabled){
    $after=[IntPtr](-2);if($Enabled){$after=[IntPtr](-1)}
    if(-not [RebeccaPet.WindowLayerNative]::SetWindowPos($Handle,$after,0,0,0,0,0x213)){throw 'Native layer injection failed.'}
}
function New-TopmostSnapshot([string]$State){
    return [pscustomobject]@{state=$State;message='Topmost fixture';source=[pscustomobject]@{kind='fixture';version='';health='connected'};counts=[pscustomobject]@{working=0;waiting_user=0;pending=0;failed=0}}
}

$view=$null;$other=$null;$restored=$null;$idleTimer=$null
try{
    $view=New-RebeccaView $root @{scale=1.0;topmost=$true;project_ids=@()} 'demo'
    $view.Paused=$true
    $view.Window.Left=-10000;$view.Window.Top=-10000;$view.Window.Show()
    $handle=(New-Object Windows.Interop.WindowInteropHelper($view.Window)).Handle
    Assert-Topmost ($view.TopmostRequested -and (Test-NativeTopmost $handle)) 'Requested topmost was not applied on initial show.'
    Set-RebeccaVisual $view (New-TopmostSnapshot 'idle')
    $other=New-Object Windows.Window
    $other.Title='Rebecca topmost test';$other.ShowInTaskbar=$false;$other.ShowActivated=$false
    $other.Left=-10000;$other.Top=-10000;$other.Width=320;$other.Height=380;$other.Show()
    $otherHandle=(New-Object Windows.Interop.WindowInteropHelper($other)).Handle
    Assert-Topmost ([RebeccaPet.TopmostTestNative]::IsAbove($handle,$otherHandle)) 'An ordinary test window covered a healthy topmost pet.'

    $position=@($view.Window.Left,$view.Window.Top,$view.Window.Width,$view.Window.Height)
    Set-TestNativeLayer $handle $false
    Assert-Topmost (-not (Test-NativeTopmost $handle)) 'Fault injection did not remove native topmost.'
    Assert-Topmost $view.TopmostRequested 'Native drift changed the user preference.'
    $settingsPath=Join-Path $OutputDirectory 'settings.json'
    Save-RebeccaViewState $view $settingsPath
    $settings=[IO.File]::ReadAllText($settingsPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    Assert-Topmost $settings.topmost 'Saving native drift disabled the persisted preference.'
    $foreground=[RebeccaPet.TopmostTestNative]::GetForegroundWindow()
    Assert-Topmost (Restore-RebeccaTopmost $view) 'A missing topmost flag was not repaired.'
    Assert-Topmost ((Test-NativeTopmost $handle) -and $view.Window.Topmost -and $view.TopmostRequested) 'The repaired native and requested states disagree.'
    Assert-Topmost ([RebeccaPet.TopmostTestNative]::GetForegroundWindow() -eq $foreground) 'Repair changed the foreground window.'
    Assert-Topmost ((@($view.Window.Left,$view.Window.Top,$view.Window.Width,$view.Window.Height) -join ',') -eq ($position -join ',')) 'Repair moved or resized the pet.'
    Assert-Topmost (-not (Restore-RebeccaTopmost $view)) 'A healthy window was unnecessarily raised again.'
    Assert-Topmost ([RebeccaPet.TopmostTestNative]::IsAbove($handle,$otherHandle)) 'The repaired pet is below an ordinary window.'

    # The task remains idle and paused; recovery must not depend on a state change.
    $ticks=@{count=0;repairs=0}
    $idleSnapshot=New-TopmostSnapshot 'idle'
    $idleTimer=New-Object Windows.Threading.DispatcherTimer
    $idleTimer.Interval=[TimeSpan]::FromMilliseconds(50)
    $idleTimer.Add_Tick({
        $ticks.count++
        Set-RebeccaVisual $view $idleSnapshot
        if(Restore-RebeccaTopmost $view){$ticks.repairs++}
    }.GetNewClosure())
    Set-TestNativeLayer $handle $false
    $idleTimer.Start();Pump-TopmostDispatcher 260;$idleTimer.Stop()
    Assert-Topmost ($ticks.count -ge 2 -and $ticks.repairs -eq 1 -and (Test-NativeTopmost $handle) -and $view.State -eq 'idle' -and $view.Paused) 'Repeated identical idle snapshots did not repair once and settle.'

    Set-TestNativeLayer $otherHandle $true
    Assert-Topmost ([RebeccaPet.TopmostTestNative]::IsAbove($otherHandle,$handle)) 'The other topmost fixture was not raised for the no-reordering check.'
    Assert-Topmost (-not (Restore-RebeccaTopmost $view)) 'A healthy pet was raised over another topmost window.'
    Assert-Topmost ([RebeccaPet.TopmostTestNative]::IsAbove($otherHandle,$handle)) 'Healthy polling reordered competing topmost windows.'
    Set-TestNativeLayer $otherHandle $false

    Set-RebeccaTopmost $view $false
    Assert-Topmost (-not $view.TopmostRequested -and -not $view.Window.Topmost -and -not (Test-NativeTopmost $handle)) 'The user cannot disable topmost.'
    Assert-Topmost (-not (Restore-RebeccaTopmost $view) -and -not (Test-NativeTopmost $handle)) 'Recovery ignored the user opt-out.'
    Save-RebeccaViewState $view $settingsPath
    $restored=New-RebeccaView $root @{scale=1.0;topmost=$true;project_ids=@()} 'demo'
    Restore-RebeccaViewState $restored $settingsPath
    Assert-Topmost (-not $restored.TopmostRequested -and -not $restored.Window.Topmost) 'User opt-out was lost across settings restore.'
    $restored.Window.Left=-10000;$restored.Window.Top=-10000;$restored.Window.Show()
    $restoredHandle=(New-Object Windows.Interop.WindowInteropHelper($restored.Window)).Handle
    Assert-Topmost (-not (Test-NativeTopmost $restoredHandle)) 'Restored opt-out became topmost on show.'
    $restored.Window.Close()

    $view.Paused=$false;Set-RebeccaVisual $view (New-TopmostSnapshot 'working')
    Set-RebeccaTopmost $view $true
    $clock=$view.WorkingClock
    Assert-Topmost ($null -ne $clock) 'Working GIF did not start in the recovery fixture.'
    Set-TestNativeLayer $handle $false
    Assert-Topmost (Restore-RebeccaTopmost $view) 'Working mode did not recover topmost.'
    Assert-Topmost ([object]::ReferenceEquals($clock,$view.WorkingClock)) 'Layer recovery restarted the GIF clock.'

    $view.Window.Hide();Set-TestNativeLayer $handle $false
    Assert-Topmost (-not (Restore-RebeccaTopmost $view) -and -not $view.Window.IsVisible -and -not (Test-NativeTopmost $handle)) 'Recovery forced a hidden window onto the desktop.'
    $view.Window.Show();$view.Window.WindowState=[Windows.WindowState]::Minimized
    Pump-TopmostDispatcher 20;Set-TestNativeLayer $handle $false
    Assert-Topmost (-not (Restore-RebeccaTopmost $view) -and $view.Window.WindowState -eq [Windows.WindowState]::Minimized -and -not (Test-NativeTopmost $handle)) 'Recovery restored or raised a minimized window.'
    $view.Window.Close()
    Assert-Topmost ($view.IsClosed -and -not (Restore-RebeccaTopmost $view)) 'Recovery touched a closed window.'
    Set-RebeccaTopmost $view $true
    Assert-Topmost (-not [RebeccaPet.WindowLayerNative]::IsWindow($handle)) 'Setting the preference recreated a closed native window.'
}finally{
    if($null -ne $idleTimer){$idleTimer.Stop()}
    if($null -ne $restored -and -not $restored.IsClosed){$restored.Window.Close()}
    if($null -ne $other){$other.Close()}
    if($null -ne $view -and -not $view.IsClosed){$view.Window.Close()}
}
$result=[ordered]@{checks=$script:topmostChecks;result='passed';mode='native-window-fault-injection';original_incident_reproduced=$false;output=$OutputDirectory}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
if($PassThru){[pscustomobject]$result}else{$result|ConvertTo-Json}
