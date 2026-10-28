<#
.SYNOPSIS
    Exports job schedules, task limits and run history from Veeam Backup & Replication
    into a JSON file for the Nightshift backup window planner.

.DESCRIPTION
    Read-only. The script never changes anything in VBR. It reads:
      - every job with its schedule, backup window, chaining, full backup and health check settings
      - repositories and scale-out repositories with their concurrent task limits
      - backup proxies with their task limits, and the servers behind proxies, repositories,
        extents, gateways and mount servers
      - system jobs that use the same resources (configuration backup, SOBR offload, SureBackup, tape)
      - job session start and end times for the last -HistoryDays days
      - observed background sessions such as retention, repository maintenance, malware detection,
        restores and rescans (Rest mode, or PowerShell mode with -ActivityFromRest)

    Two ways to collect:
      PowerShell  Runs on the VBR server (or any machine with the Veeam PowerShell module)
                  and uses the Veeam cmdlets. Works with v12 and v13 on Windows.
      Rest        Talks to the VBR REST API on port 9419. Use this for the v13 Linux
                  appliance or when you can't run scripts on the VBR server.

    Open the JSON in nightshift.html. Nothing is uploaded anywhere.

.PARAMETER Mode
    PowerShell (default) or Rest.

.PARAMETER Server
    VBR server name. PowerShell mode: optional, connects with Connect-VBRServer.
    Rest mode: required.

.PARAMETER Credential
    Credential for the VBR server. Rest mode prompts if you leave it out.

.PARAMETER HistoryDays
    How many days of session history to read. Default 30.

.PARAMETER OutFile
    Where to write the JSON. Default .\nightshift-<server>-<date>.json

.PARAMETER Anonymize
    Replaces job, repository, proxy and server names with neutral labels and hashes all ids,
    so you can share the file or a screenshot in a forum post.

.PARAMETER Port
    REST API port. Default 9419.

.PARAMETER ApiVersion
    Value for the x-api-version header in Rest mode. Default 1.1-rev0, which v12 and later accept.

.PARAMETER SkipCertificateCheck
    Rest mode only. Accepts the self-signed certificate VBR ships with. PowerShell 7 only.

.PARAMETER ActivityFromRest
    PowerShell mode only. Also reads background sessions (retention, repository maintenance,
    malware detection, restores, rescans) from the REST API on the same server. The Veeam cmdlets
    don't expose most of these. Rest mode always reads them.

.PARAMETER ReadHardware
    Reads CPU cores and RAM of Windows servers that hold Veeam roles through CIM (read-only).
    Linux servers are left blank and can be filled in in the planner.

.PARAMETER InvertWindow
    Flips how backup window hours are read. Use it if the planner shows your allowed hours
    as blocked. See the README for why this switch exists.

.EXAMPLE
    .\Collect-NightshiftData.ps1
    Runs on the VBR server with the current Windows login.

.EXAMPLE
    .\Collect-NightshiftData.ps1 -Mode Rest -Server vbr01.lab.local -SkipCertificateCheck -Anonymize

.NOTES
    Project  : Nightshift, a community tool. Not made or supported by Veeam Software.
    License  : MIT
    Version  : 0.1.0
#>
[CmdletBinding()]
param(
    [ValidateSet('PowerShell', 'Rest')]
    [string]$Mode = 'PowerShell',
    [string]$Server,
    [pscredential]$Credential,
    [ValidateRange(1, 365)]
    [int]$HistoryDays = 30,
    [string]$OutFile,
    [switch]$Anonymize,
    [int]$Port = 9419,
    [string]$ApiVersion = '1.1-rev0',
    [switch]$SkipCertificateCheck,
    [switch]$InvertWindow,
    [switch]$ActivityFromRest,
    [switch]$ReadHardware
)

$ErrorActionPreference = 'Stop'
$CollectorVersion = '0.1.0'
$Days = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$WeekDays = $Days[0..4]

#region helpers ---------------------------------------------------------------

function Get-Prop {
    # Returns the first non-null value among dotted property paths. Veeam object models move
    # properties between versions, so every read goes through here and never throws.
    param($Object, [string[]]$Path)
    foreach ($p in $Path) {
        $cur = $Object
        foreach ($part in $p.Split('.')) {
            if ($null -eq $cur) { break }
            try { $cur = $cur.$part } catch { $cur = $null }
        }
        if ($null -eq $cur) { continue }
        if ($cur -is [string] -and $cur -eq '') { continue }
        if ($cur -is [System.Collections.ICollection] -and $cur.Count -eq 0) { continue }
        return $cur
    }
    return $null
}

function ConvertTo-DayName {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim()
    foreach ($d in $Days) { if ($d -ieq $s -or $d.Substring(0, 3) -ieq $s) { return $d } }
    return $null
}

function ConvertTo-DayList {
    param($Values)
    $out = @()
    foreach ($v in @($Values)) { $d = ConvertTo-DayName $v; if ($d -and $out -notcontains $d) { $out += $d } }
    # keep Monday-first order
    return @($Days | Where-Object { $out -contains $_ })
}

function ConvertTo-HHmm {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToString('HH:mm') }
    if ($Value -is [timespan]) { return '{0:00}:{1:00}' -f $Value.Hours, $Value.Minutes }
    $s = "$Value".Trim()
    if ($s -match '^(\d{1,2}):(\d{2})') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
        if ($s -match '(?i)\bPM\b' -and $h -lt 12) { $h += 12 }
        if ($s -match '(?i)\bAM\b' -and $h -eq 12) { $h = 0 }
        return '{0:00}:{1:00}' -f $h, $m
    }
    try { return ([datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm') } catch { return $null }
}

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $idx = [math]::Ceiling($P * $s.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($s[$idx], 1)
}

function ConvertFrom-WindowString {
    # Veeam stores a backup window as 7 x 24 hour flags. The PowerShell object model uses an XML-ish
    # string like <scheduler><Sunday>0,0,1,...</Sunday>...</scheduler>, where 0 means the hour is
    # permitted and 1 means denied. Returns @{ Monday = [bool[24]] ... } with $true = allowed.
    param([string]$Text, [string]$AllowedValue = '0')
    if (-not $Text) { return $null }
    $result = [ordered]@{}
    $found = $false
    foreach ($d in $Days) {
        $m = [regex]::Match($Text, "<$d>\s*([0-9,\s]+)\s*</$d>", 'IgnoreCase')
        if ($m.Success) {
            $vals = $m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($vals.Count -ge 24) {
                $result[$d] = @(0..23 | ForEach-Object { $vals[$_] -eq $AllowedValue })
                $found = $true
                continue
            }
        }
        $result[$d] = @(0..23 | ForEach-Object { $true })
    }
    if (-not $found) { return $null }
    return $result
}

function ConvertFrom-WindowDays {
    # REST API form: { days: [ { day: "monday", hours: "1,1,0,..." } ] }
    param($Days7, [string]$AllowedValue = '1')
    if (-not $Days7) { return $null }
    $result = [ordered]@{}
    foreach ($d in $Days) { $result[$d] = @(0..23 | ForEach-Object { $true }) }
    $found = $false
    foreach ($entry in @($Days7)) {
        $name = ConvertTo-DayName (Get-Prop $entry 'day')
        $hours = "$(Get-Prop $entry 'hours')" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($name -and $hours.Count -ge 24) { $result[$name] = @(0..23 | ForEach-Object { $hours[$_] -eq $AllowedValue }); $found = $true }
    }
    if (-not $found) { return $null }
    return $result
}

function New-MonthlyRule {
    param($DayNumberInMonth, $DayOfWeek, $DayOfMonth, $Months, $Time)
    $rule = [ordered]@{}
    $n = "$DayNumberInMonth"
    if ($n -match '(?i)^(First|Second|Third|Fourth|Last)$') {
        $rule.weekNumber = (Get-Culture).TextInfo.ToTitleCase($n.ToLower())
        $rule.dayOfWeek = ConvertTo-DayName $DayOfWeek
    } else {
        $dom = Get-Prop $DayOfMonth @('Day', 'DayOfMonth')
        if ($null -eq $dom) { $dom = $DayOfMonth }
        if ("$dom" -match '^\d+$') { $rule.dayOfMonth = [int]"$dom" }
        elseif ("$dom" -match '(?i)last') { $rule.dayOfMonth = 'Last' }
    }
    $mon = @(@($Months) | Where-Object { $_ } | ForEach-Object { (Get-Culture).TextInfo.ToTitleCase("$_".ToLower()) })
    if ($mon.Count -gt 0 -and $mon.Count -lt 12) { $rule.months = $mon }
    if ($Time) { $rule.time = ConvertTo-HHmm $Time }
    return $rule
}

function Get-JobKind {
    param([string]$TypeName)
    switch -Regex ($TypeName) {
        'Copy|BackupSync'           { return 'BackupCopy' }
        'Replica'                   { return 'Replica' }
        'Agent|Endpoint|^Ep|Computer|Windows|Linux|Mac' { return 'Agent' }
        'Nas|File|Unstructured'     { return 'FileBackup' }
        'Tape'                      { return 'Tape' }
        'SureBackup'                { return 'SureBackup' }
        'Backup'                    { return 'Backup' }
        default                     { return 'Other' }
    }
}

function Get-Platform {
    param([string]$Text, [string]$Kind)
    if ($Text -match '(?i)hyper|hv') { return 'HyperV' }
    if ($Text -match '(?i)vmware|vsphere|vi|vcd|vcloud') { return 'VMware' }
    if ($Text -match '(?i)nutanix|ahv') { return 'Nutanix' }
    if ($Text -match '(?i)proxmox') { return 'Proxmox' }
    if ($Kind -eq 'Agent') { return 'Agent' }
    return 'Other'
}

function Get-HistoryStats {
    # Sessions: objects with Start, End ([datetime]) and IsFull ([bool] or $null)
    param($Sessions)
    $done = @($Sessions | Where-Object { $_.Start -and $_.End -and $_.End -gt $_.Start })
    $inc = @($done | Where-Object { -not $_.IsFull } | ForEach-Object { ($_.End - $_.Start).TotalMinutes })
    $full = @($done | Where-Object { $_.IsFull } | ForEach-Object { ($_.End - $_.Start).TotalMinutes })
    $last = $done | Sort-Object Start -Descending | Select-Object -First 1
    $stats = [ordered]@{
        runs          = $done.Count
        incMedianMin  = Get-Percentile $inc 0.5
        incP90Min     = Get-Percentile $inc 0.9
        fullMedianMin = Get-Percentile $full 0.5
        fullP90Min    = Get-Percentile $full 0.9
        lastResult    = if ($last) { "$($last.Result)" } else { $null }
    }
    # The REST API doesn't say which sessions were fulls. If one run is far longer than the rest,
    # use it as the full estimate so the planner doesn't fall back to a size-based guess.
    $anyFullFlag = @($done | Where-Object { $null -ne $_.IsFull }).Count -gt 0
    if (-not $anyFullFlag -and $inc.Count -ge 5) {
        $max = ($inc | Measure-Object -Maximum).Maximum
        if ($max -gt 2.5 * $stats.incMedianMin) {
            $typical = @($inc | Where-Object { $_ -le 2.5 * $stats.incMedianMin })
            $stats.fullMedianMin = [math]::Round($max, 1)
            $stats.fullP90Min = [math]::Round($max * 1.1, 1)
            $stats.incMedianMin = Get-Percentile $typical 0.5
            $stats.incP90Min = Get-Percentile $typical 0.9
        }
    }
    return $stats
}

function New-AllowAllWindow { return [ordered]@{ enabled = $false; allowed = $null } }

#endregion

#region infrastructure and activity helpers ----------------------------------------

function Reset-HostRegistry { $script:HostReg = [ordered]@{}; $script:ServerCache = $null }

function Register-Host {
    param([string]$Id, [string]$Name, [string]$Os, [switch]$IsBackupServer)
    if (-not $Id -or $Id -match '^0{8}-0{4}-0{4}-0{4}-0{12}$') { return $null }
    if (-not $script:HostReg.Contains($Id)) {
        $script:HostReg[$Id] = [ordered]@{ id = $Id; name = $(if ($Name) { $Name } else { $Id }); os = $Os; cores = $null; ramGB = $null; isBackupServer = [bool]$IsBackupServer }
    } else {
        $h = $script:HostReg[$Id]
        if ($Name -and $h.name -eq $Id) { $h.name = $Name }
        if ($Os -and -not $h.os) { $h.os = $Os }
        if ($IsBackupServer) { $h.isBackupServer = $true }
    }
    return $Id
}

function Resolve-HostRef {
    # Accepts a host object, an id, or a list of either. Registers each server and returns the ids.
    param($Value)
    $ids = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item -or "$item" -eq '') { continue }
        if ($item -is [string] -or $item -is [guid]) {
            $id = "$item"; $name = $null; $os = $null
            if ($null -eq $script:ServerCache -and (Get-Command Get-VBRServer -ErrorAction SilentlyContinue)) {
                $script:ServerCache = @{}
                try { foreach ($sv in @(Get-VBRServer -WarningAction SilentlyContinue)) { $script:ServerCache["$($sv.Id)"] = $sv } } catch { }
            }
            if ($script:ServerCache -and $script:ServerCache.ContainsKey($id)) { $name = $script:ServerCache[$id].Name; $os = "$($script:ServerCache[$id].Type)" }
            $r = Register-Host -Id $id -Name $name -Os $os
        } else {
            $id = "$(Get-Prop $item @('Id', 'gatewayServerId', 'hostId', 'serverId'))"
            $r = Register-Host -Id $id -Name "$(Get-Prop $item @('Name', 'RealName'))" -Os "$(Get-Prop $item @('Type', 'OSType', 'os'))"
        }
        if ($r) { $ids += $r }
    }
    return $ids
}

function Get-RepoTaskLimit {
    param($Repo)
    $unlimited = (Get-Prop $Repo @('Options.IsTaskCountUnlim', 'Options.IsUnlimitedTaskCount')) -eq $true
    $limited = Get-Prop $Repo @('Options.IsTaskCountLimited', 'Options.LimitConcurrentJobs')
    $max = [int](Get-Prop $Repo @('Options.MaxTaskCount', 'Options.MaxTasksCount', 'MaxTaskCount'))
    if ($unlimited -or $limited -eq $false) { return 0 }
    return $max
}

function Add-RepoServers {
    # Adds hostId, gatewayIds and mountServerId to a repository entry from a PowerShell repository object.
    param($Entry, $Repo)
    $h = Get-Prop $Repo @('Host', 'HostId', 'Info.HostId')
    if (-not $h) { try { $h = $Repo.GetHost() } catch { } }
    $hid = @(Resolve-HostRef $h)
    if ($hid.Count) { $Entry.hostId = $hid[0] }
    $gw = @(Resolve-HostRef (Get-Prop $Repo @('GatewayServer', 'GatewayServers', 'Gateway', 'Info.GatewayHostId', 'GatewayHostId', 'ConnectionOptions.GatewayServer')))
    if ($gw.Count) { $Entry.gatewayIds = $gw }
    $m = @(Resolve-HostRef (Get-Prop $Repo @('MountServer', 'MountHost', 'MountHostId', 'Info.MountHostId', 'MountServerId')))
    if ($m.Count) { $Entry.mountServerId = $m[0] }
}

function Get-HostList {
    $list = @($script:HostReg.Values)
    $ph = $list | Where-Object { $_.id -eq 'backup-server' }
    if ($ph) {
        $short = ($ph.name -split '\.')[0]
        $real = $list | Where-Object { $_.id -ne 'backup-server' -and ((($_.name -split '\.')[0]) -ieq $short -or $_.name -ieq 'localhost' -or $_.name -ieq 'This server') } | Select-Object -First 1
        if ($real) { $real.isBackupServer = $true; if ($real.name -ieq 'localhost' -or $real.name -ieq 'This server') { $real.name = $ph.name }; $list = @($list | Where-Object { $_.id -ne 'backup-server' }) }
    }
    return $list
}

function Read-HostHardware {
    foreach ($h in $script:HostReg.Values) {
        $local = $h.id -eq 'backup-server' -or (($h.name -split '\.')[0]) -ieq $env:COMPUTERNAME
        if (-not $local -and "$($h.os)" -notmatch '(?i)windows') { continue }
        try {
            $p = @{ ErrorAction = 'Stop'; OperationTimeoutSec = 15 }
            if (-not $local) { $p.ComputerName = $h.name }
            $cs = Get-CimInstance Win32_ComputerSystem @p
            $cpu = @(Get-CimInstance Win32_Processor @p)
            $h.cores = [int](($cpu | Measure-Object -Property NumberOfCores -Sum).Sum)
            $h.ramGB = [int][math]::Round($cs.TotalPhysicalMemory / 1GB)
        } catch { Write-Verbose "Hardware for $($h.name) not read: $_" }
    }
}

function New-SystemJob {
    param([string]$Id, [string]$Name, [string]$Type, [string]$Kind, [string]$RepositoryId, [int]$Tasks, $Schedule)
    return [ordered]@{
        id = $Id; name = $Name; type = $Type; systemKind = $Kind; vbrType = $Kind; platform = 'Other'
        enabled = $true; scheduleEnabled = ($Schedule.type -ne 'none'); repositoryId = $RepositoryId
        proxyAuto = $false; proxyIds = @(); objectCount = [math]::Max(1, $Tasks); sourceSizeGB = $null; sourceJobIds = @()
        schedule = $Schedule
        fulls = [ordered]@{ active = [ordered]@{ enabled = $false }; synthetic = [ordered]@{ enabled = $false } }
        healthCheck = [ordered]@{ enabled = $false }
        history = $null
    }
}

function New-OffloadJob {
    # The capacity tier offload session starts every 4 hours by default.
    param($Repo)
    $w = New-AllowAllWindow
    if ($Repo.capacityTier.window) { $w = [ordered]@{ enabled = $true; allowed = $Repo.capacityTier.window } }
    $sched = [ordered]@{ type = 'periodic'; periodic = [ordered]@{ everyMinutes = 240; offsetMinutes = 0 }; window = $w; retry = $null }
    $tasks = if ($Repo.maxTasks -gt 0) { [math]::Min(4, $Repo.maxTasks) } else { 4 }
    return New-SystemJob "offload-$($Repo.id)" "SOBR offload, $($Repo.name)" 'System' 'SobrOffload' $Repo.id $tasks $sched
}

function ConvertFrom-VbrAnySchedule {
    # Handles the older CScheduleOptions shape and the newer VBR*ScheduleOptions shape used by
    # configuration backup, SureBackup, tape and agent jobs.
    param($Owner, $Opt)
    if ($null -eq $Opt) { return [ordered]@{ type = 'none'; window = (New-AllowAllWindow); retry = $null } }
    if (Get-Prop $Opt 'OptionsDaily') { return ConvertFrom-VbrSchedule $Owner $Opt $null }
    $sched = [ordered]@{ type = 'none'; window = (New-AllowAllWindow); retry = $null }
    if ((Get-Prop $Opt @('Enabled', 'EnableSchedule', 'IsEnabled')) -eq $false) { return $sched }
    $type = "$(Get-Prop $Opt @('Type', 'ScheduleType', 'Kind'))"
    $daily = Get-Prop $Opt @('DailyOptions', 'Daily'); $monthly = Get-Prop $Opt @('MonthlyOptions', 'Monthly'); $per = Get-Prop $Opt @('PeriodicallyOptions', 'Periodically')
    if ($type -match '(?i)after') {
        $sched.type = 'after'; $sched.afterJobId = "$(Get-Prop $Opt @('AfterJobId', 'JobAfter.Id', 'AfterJob.Id', 'Job.Id'))"
    } elseif ($type -match '(?i)month' -or (-not $type -and $monthly -and -not $daily)) {
        $sched.type = 'monthly'
        $sched.monthly = New-MonthlyRule (Get-Prop $monthly 'DayNumberInMonth') (Get-Prop $monthly 'DayOfWeek') (Get-Prop $monthly 'DayOfMonth') (Get-Prop $monthly 'Months') (Get-Prop $monthly @('Period', 'Time', 'StartTime', 'TimeLocal'))
    } elseif ($type -match '(?i)period|hour') {
        $sched.type = 'periodic'
        $period = [double](Get-Prop $per @('FullPeriod', 'Period', 'Interval'))
        if ("$(Get-Prop $per @('PeriodicallyKind', 'Type', 'Kind'))" -match '(?i)hour' -and $period -gt 0 -and $period -le 24) { $period *= 60 }
        elseif ($period -gt 2880) { $period /= 60 }
        if ($period -le 0) { $period = 60 }
        $sched.periodic = [ordered]@{ everyMinutes = [int]$period; offsetMinutes = 0 }
    } elseif ($type -match '(?i)contin') {
        $sched.type = 'continuous'
    } elseif ($daily) {
        $sched.type = 'daily'
        $sched.time = ConvertTo-HHmm (Get-Prop $daily @('Period', 'Time', 'StartTime', 'TimeLocal'))
        $dk = "$(Get-Prop $daily @('Type', 'Kind', 'DailyKind'))"
        $sched.days = @(switch -Regex ($dk) { '(?i)every' { $Days } '(?i)weekday' { $WeekDays } default { ConvertTo-DayList (Get-Prop $daily @('DayOfWeek', 'Days', 'DaysSrv')) } })
        if ($sched.days.Count -eq 0) { $sched.days = $Days }
    }
    return $sched
}

function New-ActivityBuckets { return @{} }

function Add-Activity {
    param($Buckets, [string]$Kind, [string]$Label, $Start, $End)
    if (-not $Start -or -not $End -or $End -le $Start) { return }
    $key = "$Kind|$Label"
    if (-not $Buckets.ContainsKey($key)) { $Buckets[$key] = [pscustomobject]@{ Kind = $Kind; Label = $Label; List = (New-Object System.Collections.ArrayList) } }
    [void]$Buckets[$key].List.Add([pscustomobject]@{ Start = [datetime]$Start; End = [datetime]$End })
}

function Get-ActivityProfile {
    # 168 values, Monday 00:00 first. Each value is the average number of sessions running in that hour of the week.
    param($List)
    $prof = New-Object 'double[]' 168
    foreach ($s in $List) {
        $t = $s.Start; $n = 0
        while ($t -lt $s.End -and $n -lt 24 * 21) {
            $next = $t.Date.AddHours($t.Hour + 1)
            $endSeg = if ($next -lt $s.End) { $next } else { $s.End }
            $idx = ((([int]$t.DayOfWeek) + 6) % 7) * 24 + $t.Hour
            $prof[$idx] += ($endSeg - $t).TotalMinutes / 60
            $t = $next; $n++
        }
    }
    $weeks = [math]::Max(1, $HistoryDays / 7)
    return @($prof | ForEach-Object { [math]::Round($_ / $weeks, 2) })
}

function Get-ActivityList {
    param($Buckets)
    $out = @()
    foreach ($b in $Buckets.Values) {
        if ($b.List.Count -lt 2) { continue }
        $d = @($b.List | ForEach-Object { ($_.End - $_.Start).TotalMinutes })
        $prof = Get-ActivityProfile $b.List
        $out += [pscustomobject]@{ load = ($prof | Measure-Object -Sum).Sum; entry = [ordered]@{ kind = $b.Kind; label = $b.Label; sessions = $b.List.Count; medianMin = (Get-Percentile $d 0.5); p90Min = (Get-Percentile $d 0.9); profile = $prof } }
    }
    return @($out | Sort-Object load -Descending | Select-Object -First 12 | ForEach-Object { $_.entry })
}

function Get-ActivityLabel {
    # Maps a REST session type to an activity group. Returns $null for sessions modelled as jobs.
    param([string]$Type, [string]$Name)
    switch -Regex ($Type) {
        '^(BackupJob|ReplicaJob|SureBackup)$' { return $null }
        '^ConfigurationBackup$' { return $null }
        '^RepositoryMaintenance$' { return @('RepositoryMaintenance', 'Repository maintenance') }
        '^MalwareDetection$' { return @('MalwareDetection', 'Malware detection') }
        '^SecurityComplianceAnalyzer$' { return @('SecurityAnalyzer', 'Security & Compliance Analyzer') }
        '^Infrastructure$' { return @('Infrastructure', 'Infrastructure rescans') }
        '^(RestoreVm|InstantRecovery|FirstClassDiskInstantRestore|FileLevelRestore|LinuxFileLevelRestore|NasRestore|QuickMigration|PublishBackupContentViaMount|CloudDirectorVmRestore|CloudDirectorVAppRestore|EntraIdRestore|FirstClassDiskQuickMigration)$' { return @('Restore', 'Restores and instant recovery') }
        '^RepositoryEvacuate$' { return @('RepositoryEvacuate', 'Repository evacuation') }
        '^(DeleteBackup|InfrastructureItemDeletion)$' { return @('Deletion', 'Backup deletion') }
        '^BackgroundOperation$' {
            $n = ($Name -replace '\s*\(.*\)\s*$', '' -replace '\s*\d[\d\.:/\- ]*$', '').Trim()
            if (-not $n) { $n = 'Background operations' }
            return @('BackgroundOperation', $n)
        }
        default { if ($Type) { return @($Type, ($Type -creplace '(?<=[a-z])(?=[A-Z])', ' ')) } else { return $null } }
    }
}

#endregion

#region PowerShell mode ---------------------------------------------------------

function Connect-NightshiftPowerShell {
    if (-not (Get-Command Get-VBRJob -ErrorAction SilentlyContinue)) {
        try { Import-Module Veeam.Backup.PowerShell -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue }
        catch {
            try { Add-PSSnapin VeeamPSSnapin -ErrorAction Stop }
            catch { throw "The Veeam PowerShell module isn't available here. Run the script on the VBR server or a machine with the Veeam console installed, or use -Mode Rest." }
        }
    }
    if ($Server) {
        $p = @{ Server = $Server }
        if ($Credential) { $p.Credential = $Credential }
        Connect-VBRServer @p | Out-Null
    }
}

function ConvertFrom-VbrSchedule {
    # Turns a CScheduleOptions object (job.ScheduleOptions) into the Nightshift schedule shape.
    param($Job, $Opt, $CopyInfo)
    $allowed = if ($InvertWindow) { '1' } else { '0' }
    $sched = [ordered]@{ type = 'none'; window = (New-AllowAllWindow); retry = $null }

    $daily = Get-Prop $Opt 'OptionsDaily'
    $monthly = Get-Prop $Opt 'OptionsMonthly'
    $periodic = Get-Prop $Opt 'OptionsPeriodically'
    $cont = Get-Prop $Opt 'OptionsContinuous'
    $after = Get-Prop $Opt 'OptionsScheduleAfterJob'

    if ($CopyInfo -and "$($CopyInfo.Mode)" -match '(?i)immediate') {
        $sched.type = 'immediate'
    } elseif ((Get-Prop $after 'IsEnabled') -eq $true) {
        $sched.type = 'after'
        $prev = Get-Prop $Job @('PreviousJobIdInScheduleChain', 'Info.ParentScheduleId')
        $sched.afterJobId = if ($prev) { "$prev" } else { $null }
    } elseif ((Get-Prop $daily 'Enabled') -eq $true) {
        $sched.type = 'daily'
        $sched.time = ConvertTo-HHmm (Get-Prop $daily @('TimeLocal', 'Time'))
        $kind = "$(Get-Prop $daily 'Kind')"
        $sched.days = @(switch -Regex ($kind) {
            '(?i)every' { $Days }
            '(?i)weekday' { $WeekDays }
            default { ConvertTo-DayList (Get-Prop $daily @('DaysSrv', 'Days')) }
        })
    } elseif ((Get-Prop $monthly 'Enabled') -eq $true) {
        $sched.type = 'monthly'
        $sched.monthly = New-MonthlyRule (Get-Prop $monthly 'DayNumberInMonth') (Get-Prop $monthly 'DayOfWeek') (Get-Prop $monthly 'DayOfMonth') (Get-Prop $monthly 'Months') (Get-Prop $monthly @('TimeLocal', 'Time'))
    } elseif ((Get-Prop $periodic 'Enabled') -eq $true) {
        $sched.type = 'periodic'
        $period = [double](Get-Prop $periodic @('FullPeriod', 'Period'))
        $pkind = "$(Get-Prop $periodic @('PeriodicallyKind', 'Kind'))"
        # FullPeriod is stored in minutes on the versions we've seen. Guard against hours or seconds.
        if ($pkind -match '(?i)hour' -and $period -gt 0 -and $period -le 24) { $period = $period * 60 }
        elseif ($period -gt 2880) { $period = $period / 60 }
        if ($period -le 0) { $period = 60 }
        $sched.periodic = [ordered]@{ everyMinutes = [int]$period; offsetMinutes = [int](Get-Prop $periodic @('HourlyOffset', 'StartTimeWithinHour')) }
        $w = ConvertFrom-WindowString "$(Get-Prop $periodic 'Schedule')" $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    } elseif ((Get-Prop $cont 'Enabled') -eq $true) {
        $sched.type = 'continuous'
        $w = ConvertFrom-WindowString "$(Get-Prop $cont 'Schedule')" $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    }

    $bw = Get-Prop $Opt 'OptionsBackupWindow'
    if ((Get-Prop $bw 'IsEnabled') -eq $true) {
        $w = ConvertFrom-WindowString "$(Get-Prop $bw 'BackupWindow')" $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    }
    if ((Get-Prop $Opt 'RetrySpecified') -eq $true) {
        $sched.retry = [ordered]@{ count = [int](Get-Prop $Opt 'RetryTimes'); waitMinutes = [int](Get-Prop $Opt 'RetryTimeout') }
    }
    return $sched
}

function ConvertFrom-VbrFulls {
    param($Options)
    $tgt = Get-Prop $Options 'BackupTargetOptions'
    $stor = Get-Prop $Options 'BackupStorageOptions'
    $gen = Get-Prop $Options 'GenerationPolicy'

    $active = [ordered]@{ enabled = ((Get-Prop $stor 'EnableFullBackup') -eq $true) }
    if ($active.enabled) {
        if ("$(Get-Prop $tgt 'FullBackupScheduleKind')" -match '(?i)month') {
            $mo = Get-Prop $tgt 'FullBackupMonthlyScheduleOptions'
            $active.kind = 'monthly'
            $active.monthly = New-MonthlyRule (Get-Prop $mo 'DayNumberInMonth') (Get-Prop $mo 'DayOfWeek') (Get-Prop $mo 'DayOfMonth') (Get-Prop $mo 'Months') $null
        } else {
            $active.kind = 'weekly'
            $active.days = @(ConvertTo-DayList (Get-Prop $tgt 'FullBackupDays'))
        }
    }
    $synthetic = [ordered]@{ enabled = ((Get-Prop $tgt @('TransformFullToSyntethic', 'TransformFullToSynthetic')) -eq $true) }
    if ($synthetic.enabled) { $synthetic.days = @(ConvertTo-DayList (Get-Prop $tgt @('TransformToSyntethicDays', 'TransformToSyntheticDays'))) }

    $health = [ordered]@{ enabled = ((Get-Prop $gen @('EnableRechek', 'EnableRecheck')) -eq $true) }
    if ($health.enabled) {
        if ("$(Get-Prop $gen 'RecheckScheduleKind')" -match '(?i)month') {
            $mo = Get-Prop $gen 'RecheckBackupMonthlyScheduleOptions'
            $health.kind = 'monthly'
            $health.monthly = New-MonthlyRule (Get-Prop $mo 'DayNumberInMonth') (Get-Prop $mo 'DayOfWeek') (Get-Prop $mo 'DayOfMonth') (Get-Prop $mo 'Months') $null
        } else {
            $health.kind = 'weekly'
            $health.days = @(ConvertTo-DayList (Get-Prop $gen 'RecheckDays'))
        }
    }
    return @{ fulls = [ordered]@{ active = $active; synthetic = $synthetic }; health = $health }
}

function Get-NightshiftDataPowerShell {
    Connect-NightshiftPowerShell
    $since = (Get-Date).AddDays(-$HistoryDays)
    Reset-HostRegistry
    $bs = if ($Server) { $Server } else { $env:COMPUTERNAME }
    [void](Register-Host -Id 'backup-server' -Name $bs -Os 'Windows' -IsBackupServer)

    # Repositories, with the servers that do their work (host, gateways, mount server)
    Write-Verbose 'Reading repositories'
    $repos = New-Object System.Collections.ArrayList
    $repoTasks = @{}
    foreach ($r in @(Get-VBRBackupRepository -WarningAction SilentlyContinue)) {
        $max = Get-RepoTaskLimit $r
        $repoTasks["$($r.Id)"] = $max
        $entry = [ordered]@{ id = "$($r.Id)"; name = $r.Name; type = "$(Get-Prop $r @('TypeDisplay', 'Type'))"; maxTasks = $max }
        Add-RepoServers $entry $r
        [void]$repos.Add($entry)
    }
    try {
        foreach ($s in @(Get-VBRBackupRepository -ScaleOut -WarningAction SilentlyContinue)) {
            $ext = @(Get-Prop $s @('Extent', 'Extents'))
            $sum = 0; $extents = @(); $anyUnlimited = $false
            foreach ($e in $ext) {
                $er = Get-Prop $e 'Repository'
                $rid = "$(Get-Prop $e @('Repository.Id', 'RepositoryId', 'Id'))"
                $t = if ($repoTasks.ContainsKey($rid)) { $repoTasks[$rid] } elseif ($er) { Get-RepoTaskLimit $er } else { 0 }
                if ($t -eq 0) { $anyUnlimited = $true } else { $sum += $t }
                $x = [ordered]@{ name = "$(Get-Prop $e @('Repository.Name', 'Name'))"; maxTasks = $t }
                if ($er) { Add-RepoServers $x $er }
                $extents += $x
            }
            $entry = [ordered]@{ id = "$($s.Id)"; name = $s.Name; type = 'ScaleOut'; maxTasks = $(if ($anyUnlimited) { 0 } else { $sum }); extents = $extents }
            $cap = Get-Prop $s @('CapacityExtent', 'CapacityTier')
            $capOn = (Get-Prop $s @('EnableCapacityTier', 'CapacityTierEnabled')) -eq $true -or $null -ne $cap
            if ($capOn) {
                $entry.capacityTier = [ordered]@{ enabled = $true
                    move = ((Get-Prop $s @('CapacityTierMovePolicyEnabled', 'EnableCapacityTierMove', 'MovePolicyEnabled')) -ne $false)
                    copy = ((Get-Prop $s @('CapacityTierCopyPolicyEnabled', 'EnableCapacityTierCopy', 'CopyPolicyEnabled')) -eq $true) }
            }
            [void]$repos.Add($entry)
        }
    } catch { Write-Verbose "Scale-out repositories skipped: $_" }
    try {
        foreach ($o in @(Get-VBRObjectStorageRepository -WarningAction SilentlyContinue)) {
            if ($repos | Where-Object { $_.id -eq "$($o.Id)" }) { continue }
            $max = [int](Get-Prop $o @('Options.MaxTaskCount', 'MaxConcurrentTasksCount', 'ConcurrentTasksLimit'))
            $entry = [ordered]@{ id = "$($o.Id)"; name = $o.Name; type = "$(Get-Prop $o @('Type', 'TypeDisplay'))"; maxTasks = $max }
            Add-RepoServers $entry $o
            [void]$repos.Add($entry)
        }
    } catch { Write-Verbose "Object storage repositories skipped: $_" }

    # Proxies and the servers they run on
    Write-Verbose 'Reading proxies'
    $proxies = New-Object System.Collections.ArrayList
    foreach ($pair in @(@('Get-VBRViProxy', 'VMware'), @('Get-VBRHvProxy', 'HyperV'))) {
        if (-not (Get-Command $pair[0] -ErrorAction SilentlyContinue)) { continue }
        try {
            foreach ($p in @(& $pair[0] -WarningAction SilentlyContinue)) {
                if ((Get-Prop $p @('IsDisabled')) -eq $true) { continue }
                $hid = @(Resolve-HostRef (Get-Prop $p @('Host', 'Server', 'HostId', 'Info.HostId')))[0]
                [void]$proxies.Add([ordered]@{ id = "$($p.Id)"; name = $p.Name; type = $pair[1]; maxTasks = [int](Get-Prop $p @('MaxTasksCount', 'Options.MaxTasksCount', 'MaxTaskCount')); hostId = $hid })
            }
        } catch { Write-Verbose "$($pair[0]) skipped: $_" }
    }

    # Backup copy job details (mode and sources) where the newer cmdlet exists
    $copyInfo = @{}
    if (Get-Command Get-VBRBackupCopyJob -ErrorAction SilentlyContinue) {
        try {
            foreach ($c in @(Get-VBRBackupCopyJob -WarningAction SilentlyContinue)) {
                $src = @(@(Get-Prop $c @('BackupJob', 'SourceJob')) | Where-Object { $_ } | ForEach-Object { "$($_.Id)" })
                $copyInfo["$($c.Id)"] = [pscustomobject]@{ Mode = "$(Get-Prop $c 'Mode')"; Sources = $src }
            }
        } catch { Write-Verbose "Get-VBRBackupCopyJob skipped: $_" }
    }

    # Sessions, read once and grouped by job
    Write-Verbose "Reading sessions since $since"
    $sessByJob = @{}
    foreach ($s in @(Get-VBRBackupSession -WarningAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since })) {
        if ((Get-Prop $s @('IsRetryMode', 'Info.IsRetryMode')) -eq $true) { continue }
        $jid = "$($s.JobId)"
        if (-not $sessByJob.ContainsKey($jid)) { $sessByJob[$jid] = New-Object System.Collections.ArrayList }
        $isFull = Get-Prop $s @('IsFullMode', 'Info.IsFullMode')
        [void]$sessByJob[$jid].Add([pscustomobject]@{ Start = $s.CreationTime; End = $s.EndTime; IsFull = $(if ($null -ne $isFull) { [bool]$isFull } else { $false }); Result = "$($s.Result)" })
    }

    # Jobs
    Write-Verbose 'Reading jobs'
    $jobs = New-Object System.Collections.ArrayList
    $repoOfJob = @{}
    foreach ($j in @(Get-VBRJob -WarningAction SilentlyContinue)) {
        $typeName = "$(Get-Prop $j @('JobType', 'TypeToString'))"
        $kind = Get-JobKind $typeName
        $opt = Get-Prop $j 'ScheduleOptions'
        if (-not $opt) { try { $opt = Get-VBRJobScheduleOptions -Job $j } catch { $opt = $null } }
        $options = Get-Prop $j 'Options'
        if (-not $options) { try { $options = $j.GetOptions() } catch { $options = $null } }
        $ci = $copyInfo["$($j.Id)"]

        $objects = 0
        try { $objects = @($j.GetObjectsInJob() | Where-Object { "$($_.Type)" -ne 'Exclude' }).Count } catch { }
        $sizeBytes = [double](Get-Prop $j @('Info.IncludedSize', 'Info.IncludedSizeBytes'))

        $proxyAuto = (Get-Prop $options @('JobOptions.SourceProxyAutoDetect', 'ViSourceOptions.ProxyAutoDetect')) -ne $false
        $proxyIds = @()
        if (-not $proxyAuto) { try { $proxyIds = @($j.GetProxy() | ForEach-Object { "$($_.Id)" }) } catch { } }

        $sources = @()
        if ($ci) { $sources = $ci.Sources }
        elseif ($kind -eq 'BackupCopy') { $sources = @(@(Get-Prop $j @('LinkedJobIds', 'Info.LinkedJobIds')) | Where-Object { $_ } | ForEach-Object { "$_" }) }

        $fh = ConvertFrom-VbrFulls $options
        $repoId = "$(Get-Prop $j @('Info.TargetRepositoryId', 'TargetRepositoryId'))"
        $repoOfJob["$($j.Id)"] = $repoId
        $job = [ordered]@{
            id              = "$($j.Id)"
            name            = $j.Name
            type            = $kind
            vbrType         = $typeName
            platform        = Get-Platform "$(Get-Prop $j @('BackupPlatform.Platform', 'Platform', 'SourceType'))" $kind
            enabled         = -not ((Get-Prop $j @('IsDisabled', 'Info.IsDisabled')) -eq $true)
            scheduleEnabled = ((Get-Prop $j 'IsScheduleEnabled') -ne $false)
            repositoryId    = $repoId
            proxyAuto       = $proxyAuto
            proxyIds        = $proxyIds
            objectCount     = $objects
            sourceSizeGB    = $(if ($sizeBytes -gt 0) { [math]::Round($sizeBytes / 1GB, 1) } else { $null })
            sourceJobIds    = $sources
            schedule        = (ConvertFrom-VbrSchedule $j $opt $ci)
            fulls           = $fh.fulls
            healthCheck     = $fh.health
            history         = (Get-HistoryStats $sessByJob["$($j.Id)"])
        }
        [void]$jobs.Add($job)
    }

    # Internal jobs that use repositories, proxies and mount servers outside the backup jobs
    Write-Verbose 'Reading system jobs'
    try {
        $cb = Get-VBRConfigurationBackupJob -WarningAction SilentlyContinue
        if ($cb -and (Get-Prop $cb 'Enabled') -ne $false) {
            [void]$jobs.Add((New-SystemJob 'config-backup' 'Configuration backup' 'System' 'ConfigurationBackup' "$(Get-Prop $cb @('Repository.Id', 'RepositoryId'))" 1 (ConvertFrom-VbrAnySchedule $cb (Get-Prop $cb 'ScheduleOptions'))))
        }
    } catch { Write-Verbose "Configuration backup job skipped: $_" }
    if (Get-Command Get-VBRSureBackupJob -ErrorAction SilentlyContinue) {
        try {
            foreach ($sb in @(Get-VBRSureBackupJob -WarningAction SilentlyContinue)) {
                $linked = @(@(Get-Prop $sb @('LinkedJob', 'LinkedJobs')) | ForEach-Object { "$(Get-Prop $_ @('Job.Id', 'Id', 'JobId'))" } | Where-Object { $_ })
                $repoId = if ($linked.Count -and $repoOfJob.ContainsKey($linked[0])) { $repoOfJob[$linked[0]] } else { $null }
                $vms = @(@(Get-Prop $sb @('LinkedJob', 'LinkedJobs')) | ForEach-Object { Get-Prop $_ 'VerificationVMs' }).Count
                $sj = New-SystemJob "$($sb.Id)" $sb.Name 'SureBackup' 'SureBackup' $repoId ([math]::Max(1, $vms)) (ConvertFrom-VbrAnySchedule $sb (Get-Prop $sb @('ScheduleOptions', 'Schedule')))
                $sj.enabled = (Get-Prop $sb @('IsEnabled', 'Enabled')) -ne $false
                $sj.history = Get-HistoryStats $sessByJob["$($sb.Id)"]
                [void]$jobs.Add($sj)
            }
        } catch { Write-Verbose "SureBackup jobs skipped: $_" }
    }
    if (Get-Command Get-VBRTapeJob -ErrorAction SilentlyContinue) {
        try {
            foreach ($tj in @(Get-VBRTapeJob -WarningAction SilentlyContinue)) {
                $src = @(@(Get-Prop $tj @('Object', 'Objects', 'SourceJob')) | ForEach-Object { "$(Get-Prop $_ @('Id', 'JobId'))" } | Where-Object { $_ })
                $repoId = if ($src.Count -and $repoOfJob.ContainsKey($src[0])) { $repoOfJob[$src[0]] } else { $null }
                $sj = New-SystemJob "$($tj.Id)" $tj.Name 'Tape' 'Tape' $repoId 1 (ConvertFrom-VbrAnySchedule $tj (Get-Prop $tj @('ScheduleOptions', 'FullBackupPolicy.ScheduleOptions', 'Schedule')))
                $sj.enabled = (Get-Prop $tj @('Enabled', 'IsEnabled')) -ne $false
                $sj.history = Get-HistoryStats $sessByJob["$($tj.Id)"]
                [void]$jobs.Add($sj)
            }
        } catch { Write-Verbose "Tape jobs skipped: $_" }
    }
    foreach ($r in $repos) { if ($r.capacityTier -and $r.capacityTier.enabled) { [void]$jobs.Add((New-OffloadJob $r)) } }

    # Observed activity: restores here, everything else needs the REST API
    $activity = New-ActivityBuckets
    if (Get-Command Get-VBRRestoreSession -ErrorAction SilentlyContinue) {
        try { foreach ($rs in @(Get-VBRRestoreSession -WarningAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since })) { Add-Activity $activity 'Restore' 'Restores and instant recovery' $rs.CreationTime $rs.EndTime } }
        catch { Write-Verbose "Restore sessions skipped: $_" }
    }
    $restActivity = $null
    if ($ActivityFromRest) {
        if (-not $Server) { $script:RestServer = 'localhost' } else { $script:RestServer = $Server }
        try {
            Connect-VbrApi
            $known = @{}; foreach ($j in $jobs) { $known[$j.id] = $j }
            Read-ApiSessions $known $activity
        } catch { Write-Warning "Couldn't read background activity from the REST API: $_" }
    }

    if ($ReadHardware) { Read-HostHardware }

    $ver = $null
    try { $ver = "$((Get-VBRBackupServerInfo).Build)" } catch { }

    return [ordered]@{
        server       = [ordered]@{ name = $bs; version = $ver; timezone = [TimeZoneInfo]::Local.Id; utcOffsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes }
        hosts        = @(Get-HostList)
        repositories = $repos
        proxies      = $proxies
        jobs         = $jobs
        activity     = @(Get-ActivityList $activity)
    }
}

#endregion

#region REST mode -----------------------------------------------------------------

function Invoke-VbrApi {
    param([string]$Path, [hashtable]$Query = @{})
    $base = "https://$($script:RestServer):$Port"
    $qs = ($Query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString("$($_.Value)"))" }) -join '&'
    $uri = "$base$Path" + $(if ($qs) { "?$qs" } else { '' })
    $p = @{ Uri = $uri; Headers = @{ 'x-api-version' = $ApiVersion; Authorization = "Bearer $script:Token" }; Method = 'Get' }
    if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
    return Invoke-RestMethod @p
}

function Get-VbrApiAll {
    param([string]$Path, [hashtable]$Query = @{})
    $all = New-Object System.Collections.ArrayList
    $skip = 0; $limit = 500
    do {
        $q = $Query.Clone(); $q.skip = $skip; $q.limit = $limit
        $resp = Invoke-VbrApi $Path $q
        $page = @($resp.data)
        foreach ($x in $page) { [void]$all.Add($x) }
        $skip += $limit
    } while ($page.Count -eq $limit -and $skip -lt 100000)
    return $all
}

function Connect-VbrApi {
    if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -lt 6) { throw '-SkipCertificateCheck needs PowerShell 7. Install PowerShell 7 or trust the VBR certificate on this machine.' }
    $cred = $Credential
    if (-not $cred) { $cred = Get-Credential -Message "VBR REST API login for $($script:RestServer)" }
    $body = @{ grant_type = 'password'; username = $cred.UserName; password = $cred.GetNetworkCredential().Password }
    $p = @{ Uri = "https://$($script:RestServer):$Port/api/oauth2/token"; Method = 'Post'; Body = $body; ContentType = 'application/x-www-form-urlencoded'; Headers = @{ 'x-api-version' = $ApiVersion } }
    if ($SkipCertificateCheck) { $p.SkipCertificateCheck = $true }
    $script:Token = (Invoke-RestMethod @p).access_token
}

function Read-ApiSessions {
    # Reads every session type. Sessions of known jobs become their history (where the job has none yet),
    # everything else becomes observed background activity.
    param($KnownJobs, $Activity)
    $since = (Get-Date).AddDays(-$HistoryDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $byJob = @{}
    foreach ($s in (Get-VbrApiAll '/api/v1/sessions' @{ createdAfterFilter = $since })) {
        $st = $null; $en = $null
        try { $st = ([datetimeoffset]::Parse("$($s.creationTime)")).LocalDateTime } catch { }
        try { if ($s.endTime) { $en = ([datetimeoffset]::Parse("$($s.endTime)")).LocalDateTime } } catch { }
        $type = "$($s.sessionType)"; $jid = "$($s.jobId)"
        if ($type -eq 'ConfigurationBackup' -and $KnownJobs.ContainsKey('config-backup')) { $jid = 'config-backup' }
        if ($jid -and $KnownJobs.ContainsKey($jid)) {
            if (-not $byJob.ContainsKey($jid)) { $byJob[$jid] = New-Object System.Collections.ArrayList }
            [void]$byJob[$jid].Add([pscustomobject]@{ Start = $st; End = $en; IsFull = $null; Result = "$(Get-Prop $s 'result.result')" })
            continue
        }
        if ("$($s.name)" -match '(?i)offload') {
            $off = @($KnownJobs.Values | Where-Object { $_.systemKind -eq 'SobrOffload' })
            if ($off.Count -eq 1) { $k = $off[0].id; if (-not $byJob.ContainsKey($k)) { $byJob[$k] = New-Object System.Collections.ArrayList }; [void]$byJob[$k].Add([pscustomobject]@{ Start = $st; End = $en; IsFull = $null; Result = '' }); continue }
        }
        $lab = Get-ActivityLabel $type "$($s.name)"
        if ($lab) { Add-Activity $Activity $lab[0] $lab[1] $st $en }
    }
    foreach ($jid in $byJob.Keys) {
        $j = $KnownJobs[$jid]
        if (-not $j.history -or -not $j.history.runs) { $j.history = Get-HistoryStats $byJob[$jid] }
    }
}

function ConvertFrom-ApiRule {
    # REST full/health rules: { isEnabled, weekly: { isEnabled, days }, monthly: { isEnabled, dayOfWeek, dayNumberInMonth, dayOfMonths, months } }
    param($Rule)
    $out = [ordered]@{ enabled = ((Get-Prop $Rule 'isEnabled') -eq $true) }
    if (-not $out.enabled) { return $out }
    $mo = Get-Prop $Rule 'monthly'
    if ((Get-Prop $mo 'isEnabled') -eq $true) {
        $out.kind = 'monthly'
        $n = "$(Get-Prop $mo 'dayNumberInMonth')"
        $out.monthly = New-MonthlyRule $n (Get-Prop $mo 'dayOfWeek') (Get-Prop $mo @('dayOfMonths', 'dayOfMonth')) (Get-Prop $mo 'months') $null
    } else {
        $out.kind = 'weekly'
        $out.days = @(ConvertTo-DayList (Get-Prop $Rule @('weekly.days', 'days')))
    }
    return $out
}

function ConvertFrom-ApiSchedule {
    param($Sc, $NameToId, [string]$Mode)
    $allowed = if ($InvertWindow) { '0' } else { '1' }
    $sched = [ordered]@{ type = 'none'; window = (New-AllowAllWindow); retry = $null }
    $daily = Get-Prop $Sc 'daily'; $monthly = Get-Prop $Sc 'monthly'; $per = Get-Prop $Sc 'periodically'
    $cont = Get-Prop $Sc 'continuously'; $after = Get-Prop $Sc 'afterThisJob'
    if ($Mode -match '(?i)immediate') { $sched.type = 'immediate' }
    elseif ((Get-Prop $after 'isEnabled') -eq $true) {
        $sched.type = 'after'
        $an = "$(Get-Prop $after 'jobName')"
        $sched.afterJobId = if ($NameToId -and $NameToId.ContainsKey($an)) { $NameToId[$an] } else { $null }
    } elseif ((Get-Prop $daily 'isEnabled') -eq $true) {
        $sched.type = 'daily'; $sched.time = ConvertTo-HHmm (Get-Prop $daily 'localTime')
        $dk = "$(Get-Prop $daily 'dailyKind')"
        $sched.days = @(switch -Regex ($dk) { '(?i)every' { $Days } '(?i)weekday' { $WeekDays } default { ConvertTo-DayList (Get-Prop $daily 'days') } })
    } elseif ((Get-Prop $monthly 'isEnabled') -eq $true) {
        $sched.type = 'monthly'
        $sched.monthly = New-MonthlyRule (Get-Prop $monthly 'dayNumberInMonth') (Get-Prop $monthly 'dayOfWeek') (Get-Prop $monthly @('dayOfMonths', 'dayOfMonth')) (Get-Prop $monthly 'months') (Get-Prop $monthly 'localTime')
    } elseif ((Get-Prop $per 'isEnabled') -eq $true) {
        $sched.type = 'periodic'
        $f = [double](Get-Prop $per 'frequency'); if ($f -le 0) { $f = 1 }
        $mins = if ("$(Get-Prop $per 'periodicallyKind')" -match '(?i)hour') { $f * 60 } else { $f }
        $sched.periodic = [ordered]@{ everyMinutes = [int]$mins; offsetMinutes = [int](Get-Prop $per 'startTimeWithinAnHour') }
        $w = ConvertFrom-WindowDays (Get-Prop $per 'backupWindow.days') $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    } elseif ((Get-Prop $cont 'isEnabled') -eq $true) {
        $sched.type = 'continuous'
        $w = ConvertFrom-WindowDays (Get-Prop $cont 'backupWindow.days') $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    }
    $bw = Get-Prop $Sc 'backupWindow'
    if ((Get-Prop $bw 'isEnabled') -eq $true) {
        $w = ConvertFrom-WindowDays (Get-Prop $bw @('backupWindow.days', 'days')) $allowed
        if ($w) { $sched.window = [ordered]@{ enabled = $true; allowed = $w } }
    }
    $retry = Get-Prop $Sc 'retry'
    if ((Get-Prop $retry 'isEnabled') -eq $true) { $sched.retry = [ordered]@{ count = [int](Get-Prop $retry 'retryCount'); waitMinutes = [int](Get-Prop $retry 'awaitMinutes') } }
    return $sched
}

function ConvertFrom-ApiJob {
    param($J, $NameToId)
    $kind = Get-JobKind "$($J.type)"
    $sc = Get-Prop $J 'schedule'
    $runAuto = (Get-Prop $sc 'runAutomatically') -ne $false
    $sched = ConvertFrom-ApiSchedule $sc $NameToId "$(Get-Prop $J @('mode', 'copyMode'))"
    $adv = Get-Prop $J 'storage.advancedSettings'
    $sources = @(@(Get-Prop $J @('backupJobs', 'sourceJobs', 'objects')) | Where-Object { $_ } | ForEach-Object { "$(Get-Prop $_ @('jobId', 'id'))" } | Where-Object { $_ })
    $includes = @(Get-Prop $J @('virtualMachines.includes', 'computers', 'includes'))
    $proxyAuto = (Get-Prop $J 'storage.proxies.autoSelection') -ne $false
    $proxyIds = @()
    if (-not $proxyAuto) { $proxyIds = @(@(Get-Prop $J 'storage.proxies.proxyIds') | Where-Object { $_ } | ForEach-Object { "$_" }) }
    return [ordered]@{
        id              = "$($J.id)"
        name            = $J.name
        type            = $kind
        vbrType         = "$($J.type)"
        platform        = Get-Platform "$($J.type)" $kind
        enabled         = -not ((Get-Prop $J 'isDisabled') -eq $true)
        scheduleEnabled = $runAuto
        repositoryId    = "$(Get-Prop $J @('storage.backupRepositoryId', 'repositoryId', 'target.backupRepositoryId'))"
        proxyAuto       = $proxyAuto
        proxyIds        = $proxyIds
        objectCount     = [math]::Max(1, $includes.Count)
        sourceSizeGB    = $null
        sourceJobIds    = $sources
        schedule        = $sched
        fulls           = [ordered]@{ active = (ConvertFrom-ApiRule (Get-Prop $adv 'activeFulls')); synthetic = (ConvertFrom-ApiRule (Get-Prop $adv @('synthenticFulls', 'syntheticFulls'))) }
        healthCheck     = (ConvertFrom-ApiRule (Get-Prop $adv 'backupHealth'))
        history         = $null
    }
}

function Get-NightshiftDataRest {
    if (-not $Server) { throw 'Rest mode needs -Server.' }
    $script:RestServer = $Server
    Connect-VbrApi
    Reset-HostRegistry
    [void](Register-Host -Id 'backup-server' -Name $Server -IsBackupServer)

    $ver = $null
    try { $info = Invoke-VbrApi '/api/v1/serverInfo'; $ver = "$($info.buildVersion)" } catch { }

    Write-Verbose 'Reading managed servers'
    try { foreach ($ms in (Get-VbrApiAll '/api/v1/backupInfrastructure/managedServers')) { [void](Register-Host -Id "$($ms.id)" -Name "$($ms.name)" -Os "$($ms.type)") } }
    catch { Write-Verbose "Managed servers skipped: $_" }

    Write-Verbose 'Reading repositories'
    $repos = New-Object System.Collections.ArrayList
    $repoById = @{}
    foreach ($r in (Get-VbrApiAll '/api/v1/backupInfrastructure/repositories')) {
        $lim = (Get-Prop $r @('repository.taskLimitEnabled', 'repository.enableTaskLimit')) -ne $false
        $max = if ($lim) { [int](Get-Prop $r @('repository.maxTaskCount', 'maxTaskCount')) } else { 0 }
        $entry = [ordered]@{ id = "$($r.id)"; name = $r.name; type = "$($r.type)"; maxTasks = $max }
        $h = @(Resolve-HostRef (Get-Prop $r @('hostId', 'repository.hostId'))); if ($h.Count) { $entry.hostId = $h[0] }
        $gw = @(Resolve-HostRef (Get-Prop $r @('gatewayServer.gatewayServerIds', 'gatewayServers', 'share.gatewayServer.gatewayServerIds', 'connectionSettings.gatewayServers', 'proxyAppliance.gatewayServerIds')))
        if ($gw.Count) { $entry.gatewayIds = $gw }
        $m = @(Resolve-HostRef (Get-Prop $r @('mountServer.mountServerId', 'mountServerId'))); if ($m.Count) { $entry.mountServerId = $m[0] }
        $repoById[$entry.id] = $entry
        [void]$repos.Add($entry)
    }
    try {
        foreach ($s in (Get-VbrApiAll '/api/v1/backupInfrastructure/scaleOutRepositories')) {
            $ext = @(Get-Prop $s @('performanceTier.performanceExtents', 'performanceExtents'))
            $sum = 0; $extents = @(); $unl = $false
            foreach ($e in $ext) {
                $base = $repoById["$($e.id)"]
                $t = if ($base) { $base.maxTasks } else { 0 }
                if ($t -eq 0) { $unl = $true } else { $sum += $t }
                $x = [ordered]@{ name = "$(if ($e.name) { $e.name } elseif ($base) { $base.name })"; maxTasks = $t }
                if ($base -and $base.hostId) { $x.hostId = $base.hostId }
                if ($base -and $base.gatewayIds) { $x.gatewayIds = $base.gatewayIds }
                $extents += $x
            }
            $entry = [ordered]@{ id = "$($s.id)"; name = $s.name; type = 'ScaleOut'; maxTasks = $(if ($unl) { 0 } else { $sum }); extents = $extents }
            $cap = Get-Prop $s 'capacityTier'
            if ($cap -and ((Get-Prop $cap @('isEnabled', 'enabled')) -eq $true -or (Get-Prop $cap 'movePolicyEnabled') -eq $true -or (Get-Prop $cap 'copyPolicyEnabled') -eq $true)) {
                $entry.capacityTier = [ordered]@{ enabled = $true; move = ((Get-Prop $cap 'movePolicyEnabled') -eq $true); copy = ((Get-Prop $cap 'copyPolicyEnabled') -eq $true) }
                $w = ConvertFrom-WindowDays (Get-Prop $cap 'offloadWindow.days') $(if ($InvertWindow) { '0' } else { '1' })
                if ($w) { $entry.capacityTier.window = $w }
            }
            [void]$repos.Add($entry)
        }
    } catch { Write-Verbose "Scale-out repositories skipped: $_" }

    Write-Verbose 'Reading proxies'
    $proxies = New-Object System.Collections.ArrayList
    try {
        foreach ($x in (Get-VbrApiAll '/api/v1/backupInfrastructure/proxies')) {
            $t = if ("$($x.type)" -match '(?i)hv|hyper') { 'HyperV' } else { 'VMware' }
            $h = @(Resolve-HostRef (Get-Prop $x @('server.hostId', 'hostId')))
            [void]$proxies.Add([ordered]@{ id = "$($x.id)"; name = $x.name; type = $t; maxTasks = [int](Get-Prop $x @('server.maxTaskCount', 'maxTaskCount')); hostId = $(if ($h.Count) { $h[0] } else { $null }) })
        }
    } catch { Write-Verbose "Proxies skipped: $_" }

    Write-Verbose 'Reading jobs'
    $raw = Get-VbrApiAll '/api/v1/jobs'
    $nameToId = @{}; foreach ($j in $raw) { $nameToId["$($j.name)"] = "$($j.id)" }
    $jobs = New-Object System.Collections.ArrayList
    foreach ($j in $raw) {
        $cj = ConvertFrom-ApiJob $j $nameToId
        if ($cj.type -in @('SureBackup', 'Tape')) { $cj.systemKind = $cj.type }
        [void]$jobs.Add($cj)
    }
    try {
        $cb = Invoke-VbrApi '/api/v1/configBackup'
        if ((Get-Prop $cb 'isEnabled') -ne $false) {
            $sc = ConvertFrom-ApiSchedule (Get-Prop $cb 'schedule') $null ''
            [void]$jobs.Add((New-SystemJob 'config-backup' 'Configuration backup' 'System' 'ConfigurationBackup' "$(Get-Prop $cb 'backupRepositoryId')" 1 $sc))
        }
    } catch { Write-Verbose "Configuration backup skipped: $_" }
    foreach ($r in $repos) { if ($r.capacityTier -and $r.capacityTier.enabled) { [void]$jobs.Add((New-OffloadJob $r)) } }

    Write-Verbose 'Reading sessions'
    $known = @{}; foreach ($j in $jobs) { $known[$j.id] = $j }
    $activity = New-ActivityBuckets
    Read-ApiSessions $known $activity

    return [ordered]@{
        server       = [ordered]@{ name = $Server; version = $ver; timezone = [TimeZoneInfo]::Local.Id; utcOffsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes }
        hosts        = @(Get-HostList)
        repositories = $repos
        proxies      = $proxies
        jobs         = $jobs
        activity     = @(Get-ActivityList $activity)
    }
}

#endregion

#region anonymize and output --------------------------------------------------------

function Protect-NightshiftData {
    param($Data)
    $sha = [Security.Cryptography.SHA256]::Create()
    $salt = [guid]::NewGuid().ToString()
    $h = { param($v) if (-not $v) { return $v }; $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$salt|$v")); return -join ($b[0..5] | ForEach-Object { $_.ToString('x2') }) }
    $i = 0; foreach ($x in $Data.hosts) { $i++; $x.id = & $h $x.id; $x.name = 'Server {0:00}' -f $i }
    $i = 0
    foreach ($r in $Data.repositories) {
        $i++; $r.id = & $h $r.id; $r.name = "Repository $i"
        if ($r.hostId) { $r.hostId = & $h $r.hostId }
        if ($r.mountServerId) { $r.mountServerId = & $h $r.mountServerId }
        if ($r.gatewayIds) { $r.gatewayIds = @($r.gatewayIds | ForEach-Object { & $h $_ }) }
        if ($r.extents) {
            $e = 0
            $r.extents = @($r.extents | ForEach-Object {
                $e++
                if ($_ -is [string]) { "Extent $e" } else {
                    $_.name = "Extent $e"
                    if ($_.hostId) { $_.hostId = & $h $_.hostId }
                    if ($_.gatewayIds) { $_.gatewayIds = @($_.gatewayIds | ForEach-Object { & $h $_ }) }
                    $_
                }
            })
        }
    }
    $i = 0; foreach ($p in $Data.proxies) { $i++; $p.id = & $h $p.id; $p.name = "Proxy $i"; if ($p.hostId) { $p.hostId = & $h $p.hostId } }
    $i = 0
    foreach ($j in $Data.jobs) {
        $i++
        $j.id = & $h $j.id
        $j.name = if ($j.systemKind) { '{0} {1:00}' -f $j.systemKind, $i } else { 'Job {0:00}' -f $i }
        $j.repositoryId = & $h $j.repositoryId
        $j.proxyIds = @($j.proxyIds | ForEach-Object { & $h $_ })
        $j.sourceJobIds = @($j.sourceJobIds | ForEach-Object { & $h $_ })
        if ($j.schedule.afterJobId) { $j.schedule.afterJobId = & $h $j.schedule.afterJobId }
    }
    foreach ($a in $Data.activity) { if ($a.kind -eq 'BackgroundOperation') { $a.label = 'Background operation' } }
    $Data.server.name = 'vbr-server'
    return $Data
}

# Allow the functions to be dot-sourced for tests without running a collection
if ($MyInvocation.InvocationName -eq '.') { return }

$started = Get-Date
$core = if ($Mode -eq 'Rest') { Get-NightshiftDataRest } else { Get-NightshiftDataPowerShell }

$data = [ordered]@{
    schema       = 'nightshift/1'
    generatedAt  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    collector    = [ordered]@{ name = 'Collect-NightshiftData.ps1'; version = $CollectorVersion; mode = $Mode; psVersion = "$($PSVersionTable.PSVersion)" }
    server       = $core.server
    anonymized   = [bool]$Anonymize
    historyDays  = $HistoryDays
    hosts        = @($core.hosts)
    repositories = @($core.repositories)
    proxies      = @($core.proxies)
    jobs         = @($core.jobs)
    activity     = @($core.activity)
}
if ($Anonymize) { $data = Protect-NightshiftData $data }

if (-not $OutFile) {
    $n = if ($Anonymize) { 'anonymized' } else { ($data.server.name -replace '[^\w\-\.]', '_') }
    $OutFile = Join-Path (Get-Location) ("nightshift-{0}-{1}.json" -f $n, (Get-Date -Format 'yyyyMMdd-HHmm'))
}
$json = $data | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))

$noHistory = @($data.jobs | Where-Object { -not $_.history -or $_.history.runs -eq 0 }).Count
Write-Host ''
Write-Host "Nightshift export written to $OutFile" -ForegroundColor Green
Write-Host ("  {0} jobs, {1} repositories, {2} proxies, {3} days of history, {4:n1}s" -f $data.jobs.Count, $data.repositories.Count, $data.proxies.Count, $HistoryDays, ((Get-Date) - $started).TotalSeconds)
if ($noHistory) { Write-Host "  $noHistory jobs have no sessions in that period. The planner estimates their durations." -ForegroundColor Yellow }
Write-Host '  Open nightshift.html in a browser and load this file. Nothing leaves your machine.'

#endregion
