param($Shared, [string]$Root, [hashtable]$Config, [string]$Mode)
$ErrorActionPreference='Stop'
$collector=$null
try {
    Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1')
    Import-Module (Join-Path $PSScriptRoot 'Collector.psm1')
    $collector=New-RebeccaCollectorSupervisor $Root $Config $Mode
    do {
        Update-RebeccaCollectorSupervisor $collector
        $snapshot=$null
        if ($null -ne $collector.Process) {
            $snapshot=Get-RebeccaSnapshot $collector.StatusPath $Config.poll_seconds $Mode
            if (-not $collector.HasFreshSnapshot) {
                $collector.HasFreshSnapshot=Test-RebeccaCollectorSnapshot $collector $snapshot
                if (-not $collector.HasFreshSnapshot) { $snapshot=$null }
            }
        }
        if ($null -eq $snapshot) { $snapshot=New-RebeccaUnavailable $Mode $collector.Message }
        $counts=$snapshot.counts
        $key=@($snapshot.state,$snapshot.message,$snapshot.source.health,$snapshot.source.kind,$snapshot.source.version,$counts.working,$counts.waiting_user,$counts.pending,$counts.failed) -join [char]0
        $Shared.Packet=@{Snapshot=$snapshot;DisplayKey=$key;Expires=[DateTime]::UtcNow.AddSeconds([Math]::Max(10,3*$Config.poll_seconds))}
    } until ($Shared.Stop.WaitOne(500))
} finally {
    $Shared.Ended=$true
    if ($null -ne $collector) {Stop-RebeccaCollectorSupervisor $collector}
}
