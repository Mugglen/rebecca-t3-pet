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
$root=Assert-RebeccaOutputRoot $ProjectRoot
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'The desktop pet requires PowerShell -STA.' }
foreach($directory in @('data','logs','tmp')) { [IO.Directory]::CreateDirectory((Join-Path $root $directory)) | Out-Null }
$env:TEMP=Join-Path $root 'tmp'; $env:TMP=$env:TEMP; $env:PYTHONDONTWRITEBYTECODE='1'
$data=Join-Path $root 'data'
$settingsPath=Join-Path $data 'desktop-settings.json'
$mutex=$null; $ownsMutex=$false; $monitor=$null; $run=$null; $timer=$null; $view=$null
$shared=[hashtable]::Synchronized(@{Packet=$null;Pinned=$false;Stale=$false;Ended=$false;Stop=[Threading.ManualResetEvent]::new($false)})
try {
    if (-not $SmokeTest) {
        $mutex=New-Object Threading.Mutex($false,'Local\RebeccaT3Pet.Desktop.v1')
        try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
        if (-not $ownsMutex) { Add-Type -AssemblyName PresentationFramework; [Windows.MessageBox]::Show('瑞贝卡已经在运行。请使用她的右键菜单退出。','Rebecca · T3 Pet') | Out-Null; return }
    }
    $view=New-RebeccaView $root $Config $Mode
    Restore-RebeccaViewState $view $settingsPath
    $shared.Pinned=$view.TopmostRequested
    if (-not ('RebeccaPet.PetDispatcher' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'PetDispatcher.cs') -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Input.Mouse].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location,'System.Xaml')
    }
    if (-not $SmokeTest) {
        $monitor=[PowerShell]::Create()
        [void]$monitor.AddCommand((Join-Path $PSScriptRoot 'Monitor.ps1')).AddArgument($shared).AddArgument($root).AddArgument($Config).AddArgument($Mode)
        $run=$monitor.BeginInvoke()
    }
    $context=$view
    $menu=New-Object Windows.Controls.ContextMenu
    $details=New-Object Windows.Controls.MenuItem; $details.Header='状态详情'
    $details.Add_Click({ $snapshot=$context.Snapshot; $text=('{0}`n来源：{1}  {2}`n模式：{3}' -f $snapshot.message,$snapshot.source.kind,$snapshot.source.version,$snapshot.mode).Replace('`n',[Environment]::NewLine); [Windows.MessageBox]::Show($context.Window,$text,'Rebecca · T3 Pet')|Out-Null }.GetNewClosure())
    $pause=New-Object Windows.Controls.MenuItem; $pause.Header='暂停动作'; $pause.IsCheckable=$true; $pause.IsChecked=$context.Paused
    $pause.Add_Click({$context.Paused=$pause.IsChecked; Set-RebeccaAnimation $context}.GetNewClosure())
    $topmost=New-Object Windows.Controls.MenuItem; $topmost.Header='始终置顶'; $topmost.IsCheckable=$true; $topmost.IsChecked=$context.TopmostRequested
    $topmost.Add_Click({Set-RebeccaTopmost $context ([bool]$topmost.IsChecked);$shared.Pinned=$context.TopmostRequested}.GetNewClosure())
    $larger=New-Object Windows.Controls.MenuItem; $larger.Header='放大'; $larger.Add_Click({Set-RebeccaSize $context ($context.Scale+0.1)}.GetNewClosure())
    $smaller=New-Object Windows.Controls.MenuItem; $smaller.Header='缩小'; $smaller.Add_Click({Set-RebeccaSize $context ($context.Scale-0.1)}.GetNewClosure())
    $reset=New-Object Windows.Controls.MenuItem; $reset.Header='回到主屏'; $reset.Add_Click({Reset-RebeccaPosition $context}.GetNewClosure())
    $exit=New-Object Windows.Controls.MenuItem; $exit.Header='退出'; $exit.Add_Click({$context.Window.Close()}.GetNewClosure())
    foreach($item in @($details,$pause,$topmost,$larger,$smaller,$reset,$exit)) { $menu.Items.Add($item)|Out-Null }
    $context.Window.ContextMenu=$menu
    $context.Window.Add_KeyDown({param($sender,$event) if($event.Key -eq [Windows.Input.Key]::Escape){$context.Window.Close()}}.GetNewClosure())
    $refresh=[EventHandler]{
        $null=Restore-RebeccaTopmost $context
        if ($shared.Ended) {Set-RebeccaVisual $context (New-RebeccaUnavailable $Mode '状态监控已停止，请重新启动桌宠。')}
        elseif ($shared.Stale) {Set-RebeccaVisual $context (New-RebeccaUnavailable $Mode '状态已过期，采集器可能已停止。')}
        elseif ($shared.DisplayPacket) {Set-RebeccaVisual $context $shared.DisplayPacket.Snapshot}
    }.GetNewClosure()
    $timer=[RebeccaPet.PetDispatcher]::Attach($context.Window,$shared,$refresh)
    if($SmokeTest -or $AutoCloseSeconds -gt 0){
        $closeTimer=[Windows.Threading.DispatcherTimer]::new()
        $seconds=if($AutoCloseSeconds -gt 0){$AutoCloseSeconds}else{$SmokeSeconds}
        $closeTimer.Interval=[TimeSpan]::FromSeconds($seconds)
        $closeTimer.Add_Tick({$closeTimer.Stop();$context.Window.Close()}.GetNewClosure())
        $closeTimer.Start()
    }
    if($SmokeTest){$context.Paused=$true;Set-RebeccaAnimation $context}
    $context.Window.ShowDialog()|Out-Null
} finally {
    if($null -ne $timer){$timer.Stop()}
    if($null -ne $view -and -not $SmokeTest){try{Save-RebeccaViewState $view $settingsPath}catch{}}
    [void]$shared.Stop.Set()
    if($null -ne $monitor){
        try {if($null -ne $run){[void]$monitor.EndInvoke($run)}} finally {$monitor.Dispose()}
    }
    $shared.Stop.Dispose()
    if($ownsMutex){$mutex.ReleaseMutex()}
    if($null -ne $mutex){$mutex.Dispose()}
}
