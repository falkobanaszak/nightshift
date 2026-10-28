# Offline test for Collect-NightshiftData.ps1. Fakes the Veeam cmdlets and the REST API with objects
# shaped like the real ones, runs both collection modes and checks the JSON that comes out.
# Run: pwsh ./tests/Test-Collector.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path (Split-Path -Parent $here) 'collector/Collect-NightshiftData.ps1'
$fail = 0
function Check($cond, $msg) { if ($cond) { Write-Host "  ok   $msg" -ForegroundColor Green } else { Write-Host "  FAIL $msg" -ForegroundColor Red; $script:fail++ } }

. $script   # dot-source loads the functions without running a collection

# ---------- fake PowerShell object model ----------
$win = '<scheduler>' + (($Days | ForEach-Object { $h = @(0..23 | ForEach-Object { if ($_ -ge 6 -and $_ -lt 20) { 1 } else { 0 } }); "<$_>$($h -join ',')</$_>" }) -join '') + '</scheduler>'
$hostA = [pscustomobject]@{ Id = [guid]'44444444-0000-0000-0000-000000000001'; Name = 'repo-a.lab'; Type = 'Windows' }
$hostB = [pscustomobject]@{ Id = [guid]'44444444-0000-0000-0000-000000000002'; Name = 'repo-b.lab'; Type = 'Linux' }
$hostVbr = [pscustomobject]@{ Id = [guid]'44444444-0000-0000-0000-000000000003'; Name = 'VBRTEST'; Type = 'Windows' }
$repoA = [pscustomobject]@{ Id = [guid]'11111111-1111-1111-1111-111111111111'; Name = 'Repo-A'; Type = 'WinLocal'; Host = $hostA; MountHost = $hostVbr; Options = [pscustomobject]@{ MaxTaskCount = 4; IsTaskCountUnlim = $false } }
$repoB = [pscustomobject]@{ Id = [guid]'22222222-2222-2222-2222-222222222222'; Name = 'Repo-B'; Type = 'LinuxLocal'; Host = $hostB; Options = [pscustomobject]@{ MaxTaskCount = 8; IsTaskCountUnlim = $false } }
$sobr = [pscustomobject]@{ Id = [guid]'33333333-3333-3333-3333-333333333333'; Name = 'SOBR'; Extent = @([pscustomobject]@{ Repository = $repoA }, [pscustomobject]@{ Repository = $repoB }); CapacityExtent = [pscustomobject]@{ Id = 'cap' }; CapacityTierCopyPolicyEnabled = $true }

function New-FakeJob($id, $name, $type, $sched, $opts, $objects = 3, $repo = $sobr.Id) {
    $j = [pscustomobject]@{
        Id = [guid]$id; Name = $name; JobType = $type; IsScheduleEnabled = $true; ScheduleOptions = $sched; Options = $opts
        Info = [pscustomobject]@{ TargetRepositoryId = $repo; IncludedSize = 500GB; IsDisabled = $false }
        BackupPlatform = [pscustomobject]@{ Platform = 'EVmware' }; PreviousJobIdInScheduleChain = $null
    }
    $objs = @(1..$objects | ForEach-Object { [pscustomobject]@{ Type = 'Include' } })
    $j | Add-Member ScriptMethod GetObjectsInJob ([scriptblock]::Create("return @(1..$objects | ForEach-Object { [pscustomobject]@{ Type = 'Include' } })"))
    $j | Add-Member ScriptMethod GetProxy { return @() }
    return $j
}
function New-Sched([hashtable]$o) {
    $base = @{
        OptionsDaily = [pscustomobject]@{ Enabled = $false }; OptionsMonthly = [pscustomobject]@{ Enabled = $false }
        OptionsPeriodically = [pscustomobject]@{ Enabled = $false }; OptionsContinuous = [pscustomobject]@{ Enabled = $false }
        OptionsScheduleAfterJob = [pscustomobject]@{ IsEnabled = $false }; OptionsBackupWindow = [pscustomobject]@{ IsEnabled = $false }
        RetrySpecified = $true; RetryTimes = 3; RetryTimeout = 10
    }
    foreach ($k in $o.Keys) { $base[$k] = $o[$k] }
    return [pscustomobject]$base
}
function New-Opts($active = $false, $activeDays = @(), $synth = $false, $synthDays = @(), $monthly = $null) {
    [pscustomobject]@{
        BackupStorageOptions = [pscustomobject]@{ EnableFullBackup = $active }
        BackupTargetOptions = [pscustomobject]@{ FullBackupScheduleKind = $(if ($monthly) { 'Monthly' } else { 'Daily' }); FullBackupDays = $activeDays; FullBackupMonthlyScheduleOptions = $monthly; TransformFullToSyntethic = $synth; TransformToSyntethicDays = $synthDays }
        GenerationPolicy = [pscustomobject]@{ EnableRechek = $true; RecheckScheduleKind = 'Monthly'; RecheckBackupMonthlyScheduleOptions = [pscustomobject]@{ DayNumberInMonth = 'Last'; DayOfWeek = 'Saturday'; Months = @() } }
        JobOptions = [pscustomobject]@{ SourceProxyAutoDetect = $true }
    }
}
$j1 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000001' 'SQL' 'Backup' (New-Sched @{ OptionsDaily = [pscustomobject]@{ Enabled = $true; Kind = 'SelectedDays'; DaysSrv = @([DayOfWeek]::Saturday); TimeLocal = [datetime]'2026-01-01 22:00' } }) (New-Opts $true @('Saturday'))
$j2 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000002' 'Files' 'Backup' (New-Sched @{ OptionsDaily = [pscustomobject]@{ Enabled = $true; Kind = 'WeekDays'; TimeLocal = [datetime]'2026-01-01 21:15' }; OptionsBackupWindow = [pscustomobject]@{ IsEnabled = $true; BackupWindow = $win } }) (New-Opts $false @() $true @('Friday')) 10
$j3 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000003' 'App' 'Backup' (New-Sched @{ OptionsScheduleAfterJob = [pscustomobject]@{ IsEnabled = $true } }) (New-Opts $true @() $false @() ([pscustomobject]@{ DayNumberInMonth = 'First'; DayOfWeek = 'Monday'; Months = @() }))
$j3.PreviousJobIdInScheduleChain = $j1.Id
$j4 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000004' 'Dev' 'Backup' (New-Sched @{ OptionsPeriodically = [pscustomobject]@{ Enabled = $true; PeriodicallyKind = 'Hours'; FullPeriod = 240; HourlyOffset = 15; Schedule = $win } }) (New-Opts)
$j5 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000005' 'Copy' 'SimpleBackupCopyPolicy' (New-Sched @{}) (New-Opts) 4 $repoB.Id
$j6 = New-FakeJob 'aaaaaaaa-0000-0000-0000-000000000006' 'Monthly' 'Backup' (New-Sched @{ OptionsMonthly = [pscustomobject]@{ Enabled = $true; DayNumberInMonth = 'Last'; DayOfWeek = 'Sunday'; Months = @('January', 'July'); TimeLocal = [datetime]'2026-01-01 02:30' } }) (New-Opts)

function Get-VBRJob { $j1, $j2, $j3, $j4, $j5, $j6 }
function Get-VBRBackupRepository([switch]$ScaleOut) { if ($ScaleOut) { $sobr } else { $repoA, $repoB } }
function Get-VBRObjectStorageRepository { @() }
function Get-VBRViProxy { [pscustomobject]@{ Id = [guid]::NewGuid(); Name = 'px1'; MaxTasksCount = 6; IsDisabled = $false; Host = $hostVbr } }
function Get-VBRConfigurationBackupJob { [pscustomobject]@{ Enabled = $true; Repository = $repoB; ScheduleOptions = [pscustomobject]@{ Type = 'Daily'; DailyOptions = [pscustomobject]@{ Type = 'Everyday'; Period = [timespan]'10:00:00' } } } }
function Get-VBRSureBackupJob { [pscustomobject]@{ Id = [guid]'bbbbbbbb-0000-0000-0000-000000000001'; Name = 'SB-Weekly'; IsEnabled = $true; LinkedJob = @([pscustomobject]@{ Job = $j1; VerificationVMs = @(1, 2) }); ScheduleOptions = [pscustomobject]@{ Type = 'Daily'; DailyOptions = [pscustomobject]@{ Type = 'SelectedDays'; DayOfWeek = @('Sunday'); Period = [timespan]'08:30:00' } } } }
function Get-VBRRestoreSession { $n = Get-Date; foreach ($d in 1..6) { [pscustomobject]@{ CreationTime = $n.Date.AddDays(-$d).AddHours(10); EndTime = $n.Date.AddDays(-$d).AddHours(10).AddMinutes(30) } } }
function Get-VBRHvProxy { @() }
function Get-VBRBackupCopyJob { [pscustomobject]@{ Id = $j5.Id; Mode = 'Immediate'; BackupJob = @($j1, $j2) } }
function Get-VBRBackupServerInfo { [pscustomobject]@{ Build = '13.0.1.1071' } }
function Get-VBRBackupSession {
    $now = Get-Date
    foreach ($d in 1..20) {
        $s = $now.Date.AddDays(-$d).AddHours(22)
        [pscustomobject]@{ JobId = $j1.Id; CreationTime = $s; EndTime = $s.AddMinutes(60 + $d); Result = 'Success'; IsFullMode = ($d % 7 -eq 0); IsRetryMode = $false }
        [pscustomobject]@{ JobId = $j2.Id; CreationTime = $s; EndTime = $s.AddMinutes(30); Result = 'Warning'; IsFullMode = $false; IsRetryMode = ($d -eq 3) }
    }
    [pscustomobject]@{ JobId = $j1.Id; CreationTime = $now.AddDays(-90); EndTime = $now.AddDays(-90).AddMinutes(999); Result = 'Success'; IsFullMode = $false }
}

Write-Host 'PowerShell mode'
$Mode = 'PowerShell'; $HistoryDays = 28; $Server = $null; $env:COMPUTERNAME = 'VBRTEST'
$core = Get-NightshiftDataPowerShell
Check ($core -is [System.Collections.Specialized.OrderedDictionary]) 'collection returns one object and leaks nothing to the pipeline'
$jobs = @{}; foreach ($j in $core.jobs) { $jobs[$j.name] = $j }
Check ($core.repositories.Count -eq 3) 'reads 2 repositories and 1 scale-out repository'
Check (($core.repositories | Where-Object type -eq 'ScaleOut').maxTasks -eq 12) 'scale-out task limit is the sum of its extents'
Check ($jobs.SQL.schedule.type -eq 'daily' -and $jobs.SQL.schedule.time -eq '22:00') 'daily schedule and start time'
Check (@($jobs.SQL.schedule.days).Count -eq 1 -and $jobs.SQL.schedule.days[0] -eq 'Saturday') 'selected days stay an array with one entry'
Check ($jobs.SQL.fulls.active.enabled -and $jobs.SQL.fulls.active.days[0] -eq 'Saturday') 'weekly active full'
Check ($jobs.SQL.healthCheck.kind -eq 'monthly' -and $jobs.SQL.healthCheck.monthly.weekNumber -eq 'Last') 'monthly health check'
Check ($jobs.SQL.history.runs -eq 20) 'history ignores sessions older than the window'
Check ($jobs.SQL.history.fullMedianMin -gt 0 -and $jobs.SQL.history.incMedianMin -gt 60) 'history splits full and incremental runs'
Check ($jobs.Files.history.runs -eq 19) 'retry sessions are left out'
Check (@($jobs.Files.schedule.days).Count -eq 5) 'weekdays expand to five days'
Check ($jobs.Files.schedule.window.enabled -and $jobs.Files.schedule.window.allowed.Monday[2] -eq $true -and $jobs.Files.schedule.window.allowed.Monday[10] -eq $false) 'backup window parsed, 0 means allowed'
Check ($jobs.Files.fulls.synthetic.enabled -and $jobs.Files.fulls.synthetic.days[0] -eq 'Friday') 'synthetic full days'
Check ($jobs.Files.objectCount -eq 10) 'object count'
Check ($jobs.App.schedule.type -eq 'after' -and $jobs.App.schedule.afterJobId -eq "$($j1.Id)") 'chained job points at its predecessor'
Check ($jobs.App.fulls.active.kind -eq 'monthly' -and $jobs.App.fulls.active.monthly.weekNumber -eq 'First') 'monthly active full'
Check ($jobs.Dev.schedule.type -eq 'periodic' -and $jobs.Dev.schedule.periodic.everyMinutes -eq 240 -and $jobs.Dev.schedule.periodic.offsetMinutes -eq 15) 'periodic schedule in minutes'
Check ($jobs.Copy.type -eq 'BackupCopy' -and $jobs.Copy.schedule.type -eq 'immediate' -and @($jobs.Copy.sourceJobIds).Count -eq 2) 'immediate backup copy with sources'
Check ($jobs.Monthly.schedule.monthly.weekNumber -eq 'Last' -and $jobs.Monthly.schedule.monthly.time -eq '02:30' -and @($jobs.Monthly.schedule.monthly.months).Count -eq 2) 'monthly schedule with months'

$sobrOut = $core.repositories | Where-Object type -eq 'ScaleOut'
Check (@($sobrOut.extents).Count -eq 2 -and $sobrOut.extents[0].hostId -eq "$($hostA.Id)" -and $sobrOut.extents[0].maxTasks -eq 4) 'extents carry their server and task limit'
Check ((($core.repositories | Where-Object name -eq 'Repo-A').mountServerId) -eq "$($hostVbr.Id)") 'mount server recorded'
$hl = @($core.hosts)
Check ($hl.Count -eq 3 -and @($hl | Where-Object isBackupServer).Count -eq 1 -and ($hl | Where-Object isBackupServer).name -eq 'VBRTEST') 'servers collected and backup server merged with its managed server entry'
Check ($core.proxies[0].hostId -eq "$($hostVbr.Id)") 'proxy points at its server'
$cfg = $core.jobs | Where-Object systemKind -eq 'ConfigurationBackup'
Check ($cfg -and $cfg.schedule.type -eq 'daily' -and $cfg.schedule.time -eq '10:00' -and @($cfg.schedule.days).Count -eq 7 -and $cfg.repositoryId -eq "$($repoB.Id)") 'configuration backup as a system job'
$sb = $core.jobs | Where-Object systemKind -eq 'SureBackup'
Check ($sb -and $sb.schedule.time -eq '08:30' -and $sb.schedule.days[0] -eq 'Sunday' -and $sb.repositoryId -eq "$($sobr.Id)" -and $sb.objectCount -eq 2) 'SureBackup job with schedule, repository and VM count'
$off = $core.jobs | Where-Object systemKind -eq 'SobrOffload'
Check ($off -and $off.schedule.periodic.everyMinutes -eq 240 -and $off.repositoryId -eq "$($sobr.Id)") 'capacity tier adds a 4-hourly offload job'
$rest0 = @($core.activity | Where-Object kind -eq 'Restore')
Check ($rest0.Count -eq 1 -and $rest0[0].sessions -eq 6 -and $rest0[0].profile.Count -eq 168) 'restore sessions become an activity profile'
$tueIdx = ((([int](Get-Date).Date.AddDays(-1).DayOfWeek) + 6) % 7) * 24 + 10
Check ($rest0[0].profile[$tueIdx] -gt 0) 'profile lands on the right hour of the week'

$out = Join-Path ([IO.Path]::GetTempPath()) 'nightshift-test-ps.json'
$data = [ordered]@{ schema = 'nightshift/1'; generatedAt = (Get-Date).ToString('s'); collector = @{ mode = 'PowerShell' }; server = $core.server; anonymized = $false; historyDays = 28; hosts = @($core.hosts); repositories = @($core.repositories); proxies = @($core.proxies); jobs = @($core.jobs); activity = @($core.activity) }
$json = $data | ConvertTo-Json -Depth 12
$back = $json | ConvertFrom-Json
Check (($back.jobs | Where-Object name -eq 'SQL').schedule.days -is [array]) 'single day survives as a JSON array'
[IO.File]::WriteAllText($out, $json)

$anon = Protect-NightshiftData ($json | ConvertFrom-Json -AsHashtable)
Check ((($anon.jobs | ForEach-Object name) -join ',') -notmatch 'SQL|Files') 'anonymize hides job names'
$appA = $anon.jobs | Where-Object { $_.schedule.type -eq 'after' }
Check (@($anon.jobs | Where-Object { $_.id -eq $appA.schedule.afterJobId }).Count -eq 1) 'anonymize keeps chain references intact'
$aSobr = $anon.repositories | Where-Object type -eq 'ScaleOut'
Check (@($anon.hosts | Where-Object { $_.id -eq $aSobr.extents[0].hostId }).Count -eq 1 -and ($anon.hosts.name -join ',') -notmatch 'repo-a|VBRTEST') 'anonymize hashes server ids consistently and hides server names'
[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) 'nightshift-test-anon.json'), ($anon | ConvertTo-Json -Depth 12))

# ---------- fake REST API ----------
Write-Host 'Rest mode'
$hrs = (@(0..23 | ForEach-Object { if ($_ -ge 6 -and $_ -lt 20) { 0 } else { 1 } }) -join ',')
$api = @{
    '/api/v1/serverInfo' = [pscustomobject]@{ buildVersion = '13.0.1.1071' }
    '/api/v1/backupInfrastructure/managedServers' = @([pscustomobject]@{ id = 'm1'; name = 'hard01'; type = 'LinuxHost' }, [pscustomobject]@{ id = 'm2'; name = 'px01'; type = 'LinuxHost' })
    '/api/v1/backupInfrastructure/repositories' = @([pscustomobject]@{ id = 'r1'; name = 'Hardened'; type = 'LinuxHardened'; hostId = 'm1'; mountServer = [pscustomobject]@{ mountServerId = 'm2' }; repository = [pscustomobject]@{ maxTaskCount = 6; taskLimitEnabled = $true } })
    '/api/v1/backupInfrastructure/scaleOutRepositories' = @([pscustomobject]@{ id = 's1'; name = 'SOBR'; performanceTier = [pscustomobject]@{ performanceExtents = @([pscustomobject]@{ id = 'r1'; name = 'Hardened' }) }; capacityTier = [pscustomobject]@{ isEnabled = $true; movePolicyEnabled = $true; copyPolicyEnabled = $false } })
    '/api/v1/backupInfrastructure/proxies' = @([pscustomobject]@{ id = 'p1'; name = 'px'; type = 'ViProxy'; server = [pscustomobject]@{ maxTaskCount = 4; hostId = 'm2' } })
    '/api/v1/configBackup' = [pscustomobject]@{ isEnabled = $true; backupRepositoryId = 'r1'; schedule = [pscustomobject]@{ isEnabled = $true; daily = [pscustomobject]@{ isEnabled = $true; dailyKind = 'Everyday'; localTime = '10:00' } } }
    '/api/v1/jobs' = @(
        [pscustomobject]@{ id = 'j1'; name = 'Web'; type = 'VSphereBackup'; isDisabled = $false; virtualMachines = [pscustomobject]@{ includes = @(1, 2, 3) }
            storage = [pscustomobject]@{ backupRepositoryId = 'r1'; advancedSettings = [pscustomobject]@{ synthenticFulls = [pscustomobject]@{ isEnabled = $true; weekly = [pscustomobject]@{ days = @('saturday') } }; activeFulls = [pscustomobject]@{ isEnabled = $false }; backupHealth = [pscustomobject]@{ isEnabled = $false } } }
            schedule = [pscustomobject]@{ runAutomatically = $true; daily = [pscustomobject]@{ isEnabled = $true; dailyKind = 'Everyday'; localTime = '10:30 PM' }; backupWindow = [pscustomobject]@{ isEnabled = $true; backupWindow = [pscustomobject]@{ days = @($Days | ForEach-Object { [pscustomobject]@{ day = $_.ToLower(); hours = $hrs } }) } }; retry = [pscustomobject]@{ isEnabled = $true; retryCount = 2; awaitMinutes = 5 } } }
        [pscustomobject]@{ id = 'j2'; name = 'Chain'; type = 'VSphereBackup'; isDisabled = $true; virtualMachines = [pscustomobject]@{ includes = @(1) }
            storage = [pscustomobject]@{ backupRepositoryId = 'r1' }; schedule = [pscustomobject]@{ runAutomatically = $true; afterThisJob = [pscustomobject]@{ isEnabled = $true; jobName = 'Web' } } }
    )
    '/api/v1/sessions' = @(
        @(1..12 | ForEach-Object { $s = (Get-Date).Date.AddDays(-$_).AddHours(22); [pscustomobject]@{ jobId = 'j1'; sessionType = 'BackupJob'; name = 'Web'; creationTime = $s.ToString('o'); endTime = $s.AddMinutes($(if ($_ -eq 6) { 300 } else { 40 })).ToString('o'); result = [pscustomobject]@{ result = 'Success' } } })
        @(1..10 | ForEach-Object { $s = (Get-Date).Date.AddDays(-$_); [pscustomobject]@{ jobId = $null; sessionType = 'BackgroundOperation'; name = "Backup retention ($_)"; creationTime = $s.ToString('o'); endTime = $s.AddMinutes(40).ToString('o') } })
        @(1..4 | ForEach-Object { $s = (Get-Date).Date.AddDays(-7 * $_).AddHours(2); [pscustomobject]@{ jobId = $null; sessionType = 'RepositoryMaintenance'; name = 'Compact'; creationTime = $s.ToString('o'); endTime = $s.AddMinutes(150).ToString('o') } })
        @(1..5 | ForEach-Object { $s = (Get-Date).Date.AddDays(-$_).AddHours(10); [pscustomobject]@{ jobId = $null; sessionType = 'ConfigurationBackup'; name = 'Backup Configuration Job'; creationTime = $s.ToString('o'); endTime = $s.AddMinutes(5).ToString('o') } })
        @(1..6 | ForEach-Object { $s = (Get-Date).Date.AddDays(-$_).AddHours(4 * ($_ % 6)); [pscustomobject]@{ jobId = $null; sessionType = 'BackgroundOperation'; name = 'SOBR Offload'; creationTime = $s.ToString('o'); endTime = $s.AddMinutes(25).ToString('o') } })
    )
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $ContentType, [switch]$SkipCertificateCheck)
    if ($Uri -like '*oauth2/token') { return [pscustomobject]@{ access_token = 'tkn' } }
    $path = ([uri]$Uri).AbsolutePath
    $skip = if ($Uri -match 'skip=(\d+)') { [int]$Matches[1] } else { 0 }
    $v = $api[$path]
    if ($path -in @('/api/v1/serverInfo', '/api/v1/configBackup')) { return $v }
    return [pscustomobject]@{ data = $(if ($skip -gt 0) { @() } else { @($v) }) }
}
$Server = 'vbr-linux'; $Credential = New-Object pscredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force)); $SkipCertificateCheck = $true
$rest = Get-NightshiftDataRest
Check ($rest -is [System.Collections.Specialized.OrderedDictionary]) 'REST collection returns one object'
$web = $rest.jobs | Where-Object name -eq 'Web'
$chain = $rest.jobs | Where-Object name -eq 'Chain'
Check ($rest.server.version -eq '13.0.1.1071') 'server version'
Check ($web.schedule.time -eq '22:30' -and @($web.schedule.days).Count -eq 7) '12-hour clock and everyday kind'
Check ($web.schedule.window.allowed.Monday[2] -eq $true -and $web.schedule.window.allowed.Monday[10] -eq $false) 'REST window parsed, 1 means allowed'
Check ($web.fulls.synthetic.enabled -and $web.fulls.synthetic.days[0] -eq 'Saturday') 'REST synthetic full'
Check ($web.objectCount -eq 3 -and $web.repositoryId -eq 'r1') 'REST objects and repository'
Check ($web.history.runs -eq 12 -and $web.history.fullMedianMin -eq 300 -and $web.history.incMedianMin -eq 40) 'outlier session treated as a full'
Check ($chain.schedule.afterJobId -eq 'j1' -and $chain.enabled -eq $false) 'REST chained job resolved by name'
Check ($rest.proxies[0].maxTasks -eq 4 -and $rest.proxies[0].hostId -eq 'm2') 'REST proxy task limit and server'
Check ((($rest.repositories | Where-Object id -eq 'r1').hostId) -eq 'm1' -and (($rest.repositories | Where-Object id -eq 'r1').mountServerId) -eq 'm2') 'REST repository host and mount server'
Check ((@($rest.hosts) | Where-Object id -eq 'm1').name -eq 'hard01') 'REST managed servers named'
$rs = $rest.repositories | Where-Object id -eq 's1'
Check ($rs.extents[0].hostId -eq 'm1' -and $rs.maxTasks -eq 6 -and $rs.capacityTier.move) 'REST SOBR extents and capacity tier'
$rc = $rest.jobs | Where-Object systemKind -eq 'ConfigurationBackup'
Check ($rc.schedule.time -eq '10:00' -and $rc.history.runs -eq 5) 'REST configuration backup with history from its sessions'
$ro = $rest.jobs | Where-Object systemKind -eq 'SobrOffload'
Check ($ro.history.runs -eq 6) 'offload sessions become the offload job history'
$ra = @($rest.activity)
Check (@($ra | Where-Object label -eq 'Backup retention').Count -eq 1 -and @($ra | Where-Object kind -eq 'RepositoryMaintenance').Count -eq 1) 'background sessions grouped into activities'
Check (@($ra | Where-Object { $_.label -match 'Web|Configuration' }).Count -eq 0) 'job sessions are not counted as background activity'
$restData = [ordered]@{ schema = 'nightshift/1'; generatedAt = (Get-Date).ToString('s'); collector = @{ mode = 'Rest' }; server = $rest.server; anonymized = $false; historyDays = 30; hosts = @($rest.hosts); repositories = @($rest.repositories); proxies = @($rest.proxies); jobs = @($rest.jobs); activity = @($rest.activity) }
[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) 'nightshift-test-rest.json'), ($restData | ConvertTo-Json -Depth 12))

Write-Host 'Full script run'
$full = Join-Path ([IO.Path]::GetTempPath()) 'nightshift-test-full.json'
$Server = $null
& $script -OutFile $full -Anonymize | Out-Null
$f = Get-Content $full -Raw | ConvertFrom-Json
Check ($f.schema -eq 'nightshift/1' -and $f.anonymized -eq $true -and $f.jobs.Count -eq 9 -and $f.hosts.Count -eq 3) 'end-to-end run writes an anonymized export with system jobs and servers'

Write-Host ''
if ($fail) { Write-Host "$fail checks failed" -ForegroundColor Red; exit 1 } else { Write-Host 'All checks passed' -ForegroundColor Green }
