param([string]$OutputDirectory='', [string]$PythonPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('tmp\collector-lifecycle-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if([IO.Path]::GetPathRoot($OutputDirectory) -ine 'D:\'){throw 'Test output must be on D:.'}
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$env:TEMP=$OutputDirectory; $env:TMP=$OutputDirectory
$env:PSModuleAnalysisCachePath=Join-Path $OutputDirectory 'PowerShellModuleCache'
$env:PYTHONDONTWRITEBYTECODE='1'
Import-Module (Join-Path $root 'app\Desktop.psm1') -Force
Import-Module (Join-Path $root 'app\Collector.psm1') -Force
if(-not $PythonPath){
    $workspacePython=Join-Path (Split-Path -Parent $root) '.venv\Scripts\python.exe'
    if([IO.File]::Exists($workspacePython)){$PythonPath=$workspacePython}
    else {$PythonPath=(Get-Command python.exe -ErrorAction Stop).Source}
}
if(-not [IO.File]::Exists($PythonPath)){throw 'Set -PythonPath to an existing Python 3.12+ executable.'}
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Wait-NewSnapshot($Supervisor){
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        $snapshot=Get-RebeccaSnapshot $Supervisor.StatusPath 0.2 'demo'
        if(Test-RebeccaCollectorSnapshot $Supervisor $snapshot){return $snapshot}
        Start-Sleep -Milliseconds 25
    } while([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'Timed out waiting for a new demo snapshot.'
}
function Get-OwnedChildren($Supervisor){
    if($null -eq $Supervisor.Process){return @()}
    # Query only children of this test's exact owned launcher, never a global name scan.
    return @(Get-CimInstance Win32_Process -Filter ('ParentProcessId = '+$Supervisor.Process.Id) |
        Select-Object ProcessId,ParentProcessId,CreationDate,Name)
}
function Test-RecordedProcessAlive($Record){
    $process=$null
    try {
        $process=[Diagnostics.Process]::GetProcessById([int]$Record.ProcessId)
        $null=$process.Handle
        return -not $process.HasExited -and [Math]::Abs(($process.StartTime.ToUniversalTime()-$Record.CreationDate.ToUniversalTime()).TotalMilliseconds) -lt 1
    } catch {return $false} finally {if($null -ne $process){$process.Dispose()}}
}
function Wait-OwnedChildrenExit($Records){
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(4)
    do {
        $remaining=@($Records|Where-Object {Test-RecordedProcessAlive $_})
        if($remaining.Count -eq 0){return $true}
        Start-Sleep -Milliseconds 50
    } while([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}
function Stop-TestLeftover($Record){
    # Failure cleanup only: preserve the original creation identity before killing.
    $process=$null
    try {
        $recordNow=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$Record.ProcessId)
        if($null -eq $recordNow -or $recordNow.ParentProcessId -ne $Record.ParentProcessId -or $recordNow.CreationDate -ne $Record.CreationDate){return}
        $process=[Diagnostics.Process]::GetProcessById([int]$Record.ProcessId)
        $null=$process.Handle
        if(-not $process.HasExited -and [Math]::Abs(($process.StartTime.ToUniversalTime()-$Record.CreationDate.ToUniversalTime()).TotalMilliseconds) -lt 1){
            $process.Kill();$process.WaitForExit(3000)|Out-Null
        }
    } catch {} finally {if($null -ne $process){$process.Dispose()}}
}

$config=@{python_path=$PythonPath;t3_home=(Join-Path $OutputDirectory 'never-read-T3');poll_seconds=0.2;project_ids=@()}
$supervisor=$null;$other=$null;$bad=$null;$children=@()
try {
    $supervisor=New-RebeccaCollectorSupervisor $root $config 'demo' (Join-Path $OutputDirectory 'restart')
    $old=[pscustomobject]@{schema_version=1;observed_at=[DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o');mode='demo';state='working';message='old demo';source=[pscustomobject]@{kind='demo';version='';health='connected'};counts=[pscustomobject]@{working=2;waiting_user=0;pending=0;failed=0};event=$null}
    [IO.File]::WriteAllText($supervisor.StatusPath,($old|ConvertTo-Json -Depth 8 -Compress),(New-Object Text.UTF8Encoding($false)))
    Update-RebeccaCollectorSupervisor $supervisor
    Assert-Test ($null -ne $supervisor.Process -and -not $supervisor.Process.HasExited) 'Initial owned collector did not start.'
    Assert-Test (-not (Test-RebeccaCollectorSnapshot $supervisor $old)) 'Previous fresh snapshot accepted at startup.'
    $first=Wait-NewSnapshot $supervisor
    Assert-Test ($first.mode -eq 'demo' -and $first.source.kind -eq 'demo') 'Demo collector accessed the wrong source.'
    $firstPid=$supervisor.Process.Id
    $firstChildren=@(Get-OwnedChildren $supervisor);$children+=$firstChildren
    foreach($record in $firstChildren){Assert-Test (Test-RecordedProcessAlive $record) 'Could not verify an owned child identity before exit testing.'}

    $other=New-RebeccaCollectorSupervisor $root $config 'demo' (Join-Path $OutputDirectory 'other-owned')
    Update-RebeccaCollectorSupervisor $other
    $null=Wait-NewSnapshot $other
    $children+=@(Get-OwnedChildren $other)

    $supervisor.Process.Kill();$supervisor.Process.WaitForExit(3000)|Out-Null
    $now=[DateTimeOffset]::UtcNow
    Update-RebeccaCollectorSupervisor $supervisor $now
    Assert-Test ($null -eq $supervisor.Process -and $supervisor.Failures -eq 1) 'Exited collector was not moved into retry.'
    Assert-Test (($supervisor.NextAttemptAt-$now).TotalSeconds -eq 2) 'First retry delay is not two seconds.'
    Assert-Test ($null -ne $supervisor.LastExitCode -and $supervisor.Message.Contains([string]$supervisor.LastExitCode)) 'Exit code missing from retry message.'
    Update-RebeccaCollectorSupervisor $supervisor ($now.AddSeconds(1))
    Assert-Test ($null -eq $supervisor.Process) 'Collector restarted before retry deadline.'
    Assert-Test (Wait-OwnedChildrenExit $firstChildren) 'Actual child of killed venv launcher remained alive.'
    Update-RebeccaCollectorSupervisor $supervisor $supervisor.NextAttemptAt
    Assert-Test ($null -ne $supervisor.Process -and $supervisor.Process.Id -ne $firstPid) 'Retry did not start a new owned PID.'
    Assert-Test (-not (Test-RebeccaCollectorSnapshot $supervisor $first)) 'Previous collector snapshot accepted after restart.'
    $second=Wait-NewSnapshot $supervisor
    Assert-Test ([DateTimeOffset]::Parse($second.observed_at) -gt [DateTimeOffset]::Parse($first.observed_at)) 'Restart did not produce a new snapshot.'
    $secondChildren=@(Get-OwnedChildren $supervisor);$children+=$secondChildren
    $supervisor.Failures=4
    $supervisor.Process.Kill();$supervisor.Process.WaitForExit(3000)|Out-Null
    Update-RebeccaCollectorSupervisor $supervisor ([DateTimeOffset]::UtcNow.AddSeconds(31))
    Assert-Test ($supervisor.Failures -eq 5) 'A delayed UI tick mistook an early exit for stable runtime.'
    Assert-Test (Wait-OwnedChildrenExit $secondChildren) 'Actual child of second killed launcher remained alive.'
    Update-RebeccaCollectorSupervisor $supervisor $supervisor.NextAttemptAt
    $null=Wait-NewSnapshot $supervisor
    $shutdownChildren=@(Get-OwnedChildren $supervisor);$children+=$shutdownChildren
    $supervisor.Failures=4;$supervisor.RetryStartedAt=[DateTimeOffset]::UtcNow.AddSeconds(-31)
    Update-RebeccaCollectorSupervisor $supervisor
    Assert-Test ($supervisor.Failures -eq 0) 'Stable runtime did not reset retry count.'
    Stop-RebeccaCollectorSupervisor $supervisor
    Assert-Test ($supervisor.Stopped -and $null -eq $supervisor.Process) 'Stop did not release the owned process.'
    Assert-Test (Wait-OwnedChildrenExit $shutdownChildren) 'Actual collector child remained after shutdown.'
    Assert-Test (-not $other.Process.HasExited) 'Stopping one supervisor killed a separate collector.'
    Update-RebeccaCollectorSupervisor $supervisor ([DateTimeOffset]::UtcNow.AddMinutes(1))
    Assert-Test ($null -eq $supervisor.Process) 'Stopped supervisor restarted a process.'

    $badConfig=$config.Clone();$badConfig.python_path=Join-Path $OutputDirectory 'SYNTHETIC_SECRET_do_not_log.exe'
    $bad=New-RebeccaCollectorSupervisor $root $badConfig 'demo' (Join-Path $OutputDirectory 'start-failure')
    $attempt=[DateTimeOffset]::UtcNow
    foreach($delay in @(2,4,8,16,30,30)){
        Update-RebeccaCollectorSupervisor $bad $attempt
        Assert-Test ($null -eq $bad.Process -and ($bad.NextAttemptAt-$attempt).TotalSeconds -eq $delay) ('Wrong repeated-start delay: '+$delay)
        $before=[IO.File]::ReadAllText($bad.LogPath)
        Update-RebeccaCollectorSupervisor $bad ($attempt.AddMilliseconds(100))
        Assert-Test ([IO.File]::ReadAllText($bad.LogPath) -eq $before) 'Start failure retried before deadline.'
        $attempt=$bad.NextAttemptAt
    }
    $log=[IO.File]::ReadAllText($bad.LogPath)
    Assert-Test (-not $log.Contains('SYNTHETIC_SECRET') -and -not $log.Contains($OutputDirectory)) 'Lifecycle log disclosed a command or exception path.'
    [IO.File]::WriteAllText($bad.LogPath,('x'*65490),(New-Object Text.UTF8Encoding($false)))
    Update-RebeccaCollectorSupervisor $bad $bad.NextAttemptAt
    Assert-Test ((Get-Item -LiteralPath $bad.LogPath).Length -le 65536) 'Lifecycle log exceeded its byte cap.'
    Stop-RebeccaCollectorSupervisor $bad
    $before=[IO.File]::ReadAllText($bad.LogPath)
    Update-RebeccaCollectorSupervisor $bad $bad.NextAttemptAt
    Assert-Test ([IO.File]::ReadAllText($bad.LogPath) -eq $before) 'Stop during backoff allowed another launch.'
    $rejected=$false;try{New-RebeccaCollectorSupervisor $root $config 'demo' 'C:\temp\rebecca-test'|Out-Null}catch{$rejected=$true}
    Assert-Test $rejected 'Lifecycle accepted a C-drive runtime directory.'
} finally {
    foreach($item in @($supervisor,$other,$bad)){if($null -ne $item){try{Stop-RebeccaCollectorSupervisor $item}catch{}}}
    foreach($record in $children){Stop-TestLeftover $record}
}
$result=[ordered]@{result='passed';checks=$script:checks;mode='synthetic-demo-only';old_pid=$firstPid;new_snapshot=$second.observed_at;venv_children_observed=$firstChildren.Count;output=$OutputDirectory}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json
