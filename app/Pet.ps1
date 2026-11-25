param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$true)][hashtable]$Config,
    [ValidateSet('live','demo')][string]$Mode='live',
    [switch]$SmokeTest,
    [int]$SmokeSeconds=2,
    [ValidateRange(0,600)][int]$AutoCloseSeconds=0
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Collector.psm1') -Force
$root=Assert-RebeccaOutputRoot $ProjectRoot
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'The desktop pet requires PowerShell -STA.' }
foreach($directory in @('data','logs','tmp')) { [IO.Directory]::CreateDirectory((Join-Path $root $directory)) | Out-Null }
$env:TEMP=Join-Path $root 'tmp'; $env:TMP=$env:TEMP; $env:PYTHONDONTWRITEBYTECODE='1'
$data=Join-Path $root 'data'
$settingsPath=Join-Path $data 'desktop-settings.json'
$mutex=$null; $ownsMutex=$false; $collector=$null; $timer=$null; $view=$null
try {
    if (-not $SmokeTest) {
        $mutex=New-Object Threading.Mutex($false,'Local\RebeccaT3Pet.Desktop.v1')
        try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
        if (-not $ownsMutex) { Add-Type -AssemblyName PresentationFramework; [Windows.MessageBox]::Show('瑞贝卡已经在运行。请使用她的右键菜单退出。','Rebecca · T3 Pet') | Out-Null; return }
    }
    $view=New-RebeccaView $root $Config $Mode
    Restore-RebeccaViewState $view $settingsPath
    if (-not $SmokeTest) {
        $collector=New-RebeccaCollectorSupervisor $root $Config $Mode
        Update-RebeccaCollectorSupervisor $collector
    }
    $context=$view
    $menu=New-Object Windows.Controls.ContextMenu
    $details=New-Object Windows.Controls.MenuItem; $details.Header='状态详情'
    $details.Add_Click({ $snapshot=$context.Snapshot; $text=('{0}`n来源：{1}  {2}`n模式：{3}' -f $snapshot.message,$snapshot.source.kind,$snapshot.source.version,$snapshot.mode).Replace('`n',[Environment]::NewLine); [Windows.MessageBox]::Show($context.Window,$text,'Rebecca · T3 Pet')|Out-Null }.GetNewClosure())
    $pause=New-Object Windows.Controls.MenuItem; $pause.Header='暂停动作'; $pause.IsCheckable=$true; $pause.IsChecked=$context.Paused
    $pause.Add_Click({$context.Paused=$pause.IsChecked; Set-RebeccaAnimation $context}.GetNewClosure())
    $topmost=New-Object Windows.Controls.MenuItem; $topmost.Header='始终置顶'; $topmost.IsCheckable=$true; $topmost.IsChecked=$context.TopmostRequested
    $topmost.Add_Click({Set-RebeccaTopmost $context ([bool]$topmost.IsChecked)}.GetNewClosure())
    $larger=New-Object Windows.Controls.MenuItem; $larger.Header='放大'; $larger.Add_Click({Set-RebeccaSize $context ($context.Scale+0.1)}.GetNewClosure())
    $smaller=New-Object Windows.Controls.MenuItem; $smaller.Header='缩小'; $smaller.Add_Click({Set-RebeccaSize $context ($context.Scale-0.1)}.GetNewClosure())
    $reset=New-Object Windows.Controls.MenuItem; $reset.Header='回到主屏'; $reset.Add_Click({Reset-RebeccaPosition $context}.GetNewClosure())
    $exit=New-Object Windows.Controls.MenuItem; $exit.Header='退出'; $exit.Add_Click({$context.Window.Close()}.GetNewClosure())
    foreach($item in @($details,$pause,$topmost,$larger,$smaller,$reset,$exit)) { $menu.Items.Add($item)|Out-Null }
    $context.Window.ContextMenu=$menu
    $drag=@{start=$null; moved=$false}
    $context.Window.Add_MouseLeftButtonDown({param($sender,$event) $drag.start=$event.GetPosition($context.Window); $drag.moved=$false}.GetNewClosure())
    $context.Window.Add_MouseMove({param($sender,$event)
        if ($null -eq $drag.start -or $event.LeftButton -ne [Windows.Input.MouseButtonState]::Pressed -or $drag.moved) {return}
        $point=$event.GetPosition($context.Window)
        if ([Math]::Abs($point.X-$drag.start.X) -ge [Windows.SystemParameters]::MinimumHorizontalDragDistance -or [Math]::Abs($point.Y-$drag.start.Y) -ge [Windows.SystemParameters]::MinimumVerticalDragDistance) {
            $drag.moved=$true; $drag.start=$null
            try {$context.Window.DragMove()} catch [InvalidOperationException] {}
        }
    }.GetNewClosure())
    $context.Window.Add_MouseLeftButtonUp({param($sender,$event) if (-not $drag.moved) {$context.Badge.ToolTip=$context.Snapshot.message}; $drag.start=$null}.GetNewClosure())
    $context.Window.Add_KeyDown({param($sender,$event) if($event.Key -eq [Windows.Input.Key]::Escape){$context.Window.Close()}}.GetNewClosure())
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(500)
    $pollSeconds=[double]$Config.poll_seconds
    $started=[DateTime]::UtcNow
    $timer.Add_Tick({
        if($AutoCloseSeconds -gt 0 -and ([DateTime]::UtcNow-$started).TotalSeconds -ge $AutoCloseSeconds){$context.Window.Close();return}
        Restore-RebeccaTopmost $context | Out-Null
        if($SmokeTest){if(([DateTime]::UtcNow-$started).TotalSeconds -ge $SmokeSeconds){$context.Window.Close()};return}
        Update-RebeccaCollectorSupervisor $collector
        if($null -eq $collector.Process){Set-RebeccaVisual $context (New-RebeccaUnavailable $Mode $collector.Message);return}
        $snapshot=Get-RebeccaSnapshot $collector.StatusPath $pollSeconds $Mode
        if(-not $collector.HasFreshSnapshot){
            if(Test-RebeccaCollectorSnapshot $collector $snapshot){$collector.HasFreshSnapshot=$true}
            else{Set-RebeccaVisual $context (New-RebeccaUnavailable $Mode $collector.Message);return}
        }
        Set-RebeccaVisual $context $snapshot
    }.GetNewClosure())
    $timer.Start()
    if($SmokeTest){$context.Paused=$true;Set-RebeccaAnimation $context}
    $context.Window.ShowDialog()|Out-Null
} finally {
    if($null -ne $timer){$timer.Stop()}
    if($null -ne $view -and -not $SmokeTest){try{Save-RebeccaViewState $view $settingsPath}catch{}}
    if($null -ne $collector){try{Stop-RebeccaCollectorSupervisor $collector}catch{}}
    if($ownsMutex){$mutex.ReleaseMutex()}
    if($null -ne $mutex){$mutex.Dispose()}
}
