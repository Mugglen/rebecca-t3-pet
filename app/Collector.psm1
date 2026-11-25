Set-StrictMode -Version 2.0

function Write-RebeccaCollectorLifecycle {
    param($Supervisor, [ValidateSet('started','exited','start_failed','stopped')][string]$Event, $Code=$null)
    # Deliberately omit exception messages, paths, command lines and T3 data.
    $line=('{0} event={1}' -f [DateTimeOffset]::UtcNow.ToString('o'),$Event)
    if($null -ne $Code){$line+=(' code={0}' -f [long]$Code)}
    $line+=[Environment]::NewLine
    try {
        if([IO.File]::Exists($Supervisor.LogPath) -and (Get-Item -LiteralPath $Supervisor.LogPath).Length+512 -gt 65536){
            [IO.File]::WriteAllText($Supervisor.LogPath,'',(New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($Supervisor.LogPath,$line,(New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function New-RebeccaCollectorSupervisor {
    param([string]$Root, [hashtable]$Config, [ValidateSet('live','demo')][string]$Mode='live', [string]$RuntimeDirectory='')
    $Root=[IO.Path]::GetFullPath($Root)
    if(-not $RuntimeDirectory){$RuntimeDirectory=Join-Path $Root 'data'}
    $RuntimeDirectory=[IO.Path]::GetFullPath($RuntimeDirectory)
    if([IO.Path]::GetPathRoot($Root) -ine 'D:\' -or [IO.Path]::GetPathRoot($RuntimeDirectory) -ine 'D:\'){
        throw 'Rebecca collector runtime must be on D:.'
    }
    [IO.Directory]::CreateDirectory($RuntimeDirectory)|Out-Null
    return [pscustomobject]@{
        Root=$Root; Config=$Config.Clone(); Mode=$Mode; RuntimeDirectory=$RuntimeDirectory
        StatusPath=(Join-Path $RuntimeDirectory ('status-'+$Mode+'.json'))
        LogPath=(Join-Path $RuntimeDirectory ('collector-'+$Mode+'.lifecycle.log'))
        Process=$null; StartedAt=$null; RetryStartedAt=$null
        NextAttemptAt=[DateTimeOffset]::MinValue; Failures=0
        LastExitCode=$null; LastFailure=''; HasFreshSnapshot=$false; Stopped=$false
        Message='正在连接状态采集器…'
    }
}

function Start-RebeccaOwnedCollector {
    param($Supervisor)
    $config=$Supervisor.Config
    $startInfo=New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName=$config.python_path; $startInfo.WorkingDirectory=$Supervisor.Root
    $arguments=@('-B','-m','rebecca_pet.collector','--t3-home',$config.t3_home,'--output',$Supervisor.StatusPath,'--poll',([double]$config.poll_seconds).ToString([Globalization.CultureInfo]::InvariantCulture),'--parent-pid',([string]$PID))
    if($Supervisor.Mode -eq 'demo'){$arguments+='--demo'}
    foreach($id in $config.project_ids){$arguments+=@('--project-id',$id)}
    # Quote Windows argv, including embedded quotes and trailing backslashes.
    $quoted=foreach($argument in $arguments){'"'+[regex]::Replace([regex]::Replace([string]$argument,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
    $startInfo.Arguments=$quoted -join ' '
    $startInfo.UseShellExecute=$false; $startInfo.CreateNoWindow=$true
    $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['PYTHONPATH']=Join-Path $Supervisor.Root 'src'
    $startInfo.EnvironmentVariables['PYTHONDONTWRITEBYTECODE']='1'
    $temp=Join-Path $Supervisor.RuntimeDirectory 'tmp'
    [IO.Directory]::CreateDirectory($temp)|Out-Null
    $startInfo.EnvironmentVariables['TEMP']=$temp; $startInfo.EnvironmentVariables['TMP']=$temp
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$startInfo
    try {
        if(-not $process.Start()){throw 'Collector process did not start.'}
        return $process
    } catch {
        $process.Dispose()
        throw
    }
}

function Set-RebeccaCollectorRetry {
    param($Supervisor, [DateTimeOffset]$Now)
    $Supervisor.Failures=[Math]::Min(5,$Supervisor.Failures+1)
    $delay=[Math]::Min(30,[Math]::Pow(2,$Supervisor.Failures))
    $Supervisor.NextAttemptAt=$Now.AddSeconds($delay)
    $Supervisor.HasFreshSnapshot=$false
}

function Update-RebeccaCollectorSupervisor {
    param($Supervisor, [DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    if($Supervisor.Stopped){return}
    if($null -ne $Supervisor.Process){
        if($Supervisor.Process.HasExited){
            $Supervisor.LastExitCode=$Supervisor.Process.ExitCode
            $Supervisor.LastFailure='exited'
            Write-RebeccaCollectorLifecycle $Supervisor 'exited' $Supervisor.LastExitCode
            # UI sleep must not make an already-exited process appear stable.
            if(($Supervisor.Process.ExitTime.ToUniversalTime()-$Supervisor.StartedAt.UtcDateTime).TotalSeconds -ge 30){$Supervisor.Failures=0}
            $Supervisor.Process.Dispose(); $Supervisor.Process=$null
            Set-RebeccaCollectorRetry $Supervisor $Now
        } elseif(($Now-$Supervisor.RetryStartedAt).TotalSeconds -ge 30){
            $Supervisor.Failures=0
        }
    }
    if($null -eq $Supervisor.Process -and $Now -ge $Supervisor.NextAttemptAt){
        try {
            # An old, still-fresh snapshot must not be accepted after restart.
            $Supervisor.StartedAt=[DateTimeOffset]::UtcNow
            $Supervisor.Process=Start-RebeccaOwnedCollector $Supervisor
            $Supervisor.RetryStartedAt=$Now
            $Supervisor.HasFreshSnapshot=$false
            Write-RebeccaCollectorLifecycle $Supervisor 'started'
        } catch {
            $Supervisor.Process=$null; $Supervisor.LastFailure='start_failed'
            $Supervisor.LastExitCode=$null
            $code=$_.Exception.HResult
            Write-RebeccaCollectorLifecycle $Supervisor 'start_failed' $code
            Set-RebeccaCollectorRetry $Supervisor $Now
        }
    }
    if($null -eq $Supervisor.Process){
        $seconds=[Math]::Max(0,[Math]::Ceiling(($Supervisor.NextAttemptAt-$Now).TotalSeconds))
        if($Supervisor.LastFailure -eq 'exited'){
            $Supervisor.Message=('正在重新连接（退出码 {0}），{1} 秒后重试。' -f $Supervisor.LastExitCode,$seconds)
        } else {
            $Supervisor.Message=('状态采集器启动失败，{0} 秒后重试。' -f $seconds)
        }
    } elseif($null -ne $Supervisor.LastExitCode){
        $Supervisor.Message=('正在重新连接，等待新状态（上次退出码 {0}）…' -f $Supervisor.LastExitCode)
    } else {
        $Supervisor.Message='正在连接，等待状态采集器的新数据…'
    }
}

function Test-RebeccaCollectorSnapshot {
    param($Supervisor, $Snapshot)
    if($Supervisor.Stopped -or $null -eq $Supervisor.Process -or $Supervisor.Process.HasExited -or $null -eq $Supervisor.StartedAt){return $false}
    try {
        if($Snapshot.source.kind -eq 'desktop'){return $false}
        $observed=[DateTimeOffset]::Parse($Snapshot.observed_at,[Globalization.CultureInfo]::InvariantCulture)
        return $observed -ge $Supervisor.StartedAt
    } catch {return $false}
}

function Stop-RebeccaCollectorSupervisor {
    param($Supervisor)
    $Supervisor.Stopped=$true
    if($null -eq $Supervisor.Process){return}
    try {
        if(-not $Supervisor.Process.HasExited){
            $Supervisor.Process.Kill()
            $Supervisor.Process.WaitForExit(3000)|Out-Null
        }
        Write-RebeccaCollectorLifecycle $Supervisor 'stopped'
    } finally {
        $Supervisor.Process.Dispose(); $Supervisor.Process=$null
        $Supervisor.HasFreshSnapshot=$false
    }
}

Export-ModuleMember -Function New-RebeccaCollectorSupervisor,Update-RebeccaCollectorSupervisor,Test-RebeccaCollectorSnapshot,Stop-RebeccaCollectorSupervisor
