# Nightshift

**A backup window planner for Veeam Backup & Replication.** Nightshift lays out every job's schedule on one timeline, together with the system jobs and background work that compete for the same proxies, repositories and gateways. It predicts how long each run takes from your real session history, works out how hard each server is loaded, and flags the nights where things collide. You can drag a job to a new start time and see the conflicts update right away, before you touch anything in VBR.

![Nightshift timeline](docs/screenshot.png)

> Community project. Not made, endorsed or supported by Veeam Software.

**[Try the live demo](https://YOUR-GITHUB-USER.github.io/nightshift/)** with sample data, nothing to install.

## Why

The VBR console shows each job's schedule only inside that job's settings, so nobody sees the whole night at once. Jobs pile up at 22:00, fulls land on the same Saturday, backup copies start before their source has finished, and the first sign of trouble is a job still running at 08:30. The VeeamHub Health Check shows concurrency from past sessions, and Veeam ONE has a schedule report. Nightshift is for the step before that, when you're planning a change.

## Quick start

1. **Export** your configuration on the VBR server (read-only, takes seconds to a few minutes).

   ```powershell
   .\Collect-NightshiftData.ps1
   ```

   For the v13 Linux appliance, or when you can't run scripts on the VBR server, use the REST API from any machine with PowerShell 7.

   ```powershell
   .\Collect-NightshiftData.ps1 -Mode Rest -Server vbr01.lab.local -SkipCertificateCheck
   ```

2. **Open** `nightshift.html` in any browser. No install, no server, and it works offline.
3. **Load** the JSON with *Open export* or drag the file onto the page.

The page opens with a sample environment so you can try it before you export anything.

## What it flags

| Conflict | Severity | What it means |
|---|---|---|
| Repository or proxy pool oversubscribed | Critical at 1.5x the limit, warning below | Jobs running at the same time want more task slots than the repository or proxies have, so some of them queue |
| Runs past its backup window | Critical | The job is predicted to still be running when its window closes, and VBR can stop it there |
| Backup copy starts before its source finishes | Critical | A periodic copy starts while the source job is still writing, so it picks up yesterday's restore point |
| Still running when the next run is due | Critical | A periodic or long job overlaps itself |
| Scheduled outside its own window | Warning | The start time falls in hours the window blocks |
| Runs into production hours | Warning (info for periodic jobs) | The job is still busy during the hours you set as business hours |
| Several fulls on one repository the same night | Warning at 3 or more, info at 2 | Active and synthetic fulls pile onto one night |
| Server short on CPU or RAM | Critical at 1.5x, warning below | The roles on one server (proxy, repository, extent, gateway) need more cores or RAM than it has |
| Busy hours overlap with background activity | Warning or info | Retention, repository maintenance, malware scans or restores usually run while a repository or server is near its limit |
| Server hardware unknown | Info | Nightshift shows the peak need, enter the server's cores and RAM to check it |
| No run history | Info | Durations are estimated from source size and throughput |

Every conflict links to the night it happens. Click it and the timeline jumps there.

## Infrastructure and background work

Backup jobs aren't the only thing using your infrastructure at night. Nightshift adds three more layers.

**Servers.** Every server behind a proxy, repository, SOBR extent, gateway or mount server gets its own row. Its load is the sum of what its roles are doing at that moment. A server that is both a Hyper-V proxy and a SOBR extent shows both. CPU and RAM need come from the Veeam best practice guide rules, 1 core and 2 GB per proxy task, and 1 repository core per 3 tasks with 4 GB per repository core. Gateways count as repository tasks. All four numbers are adjustable under Assumptions. Tasks that are queued because a repository is full don't load the server, so the server view shows what can actually run.

**System jobs.** The configuration backup, SOBR offload to the capacity tier (every 4 hours by default), SureBackup and tape jobs are planned like any other job and use slots on their repository. They're drawn in teal.

**Observed background activity.** VBR starts some work on its own, so it can't be predicted from a schedule. Background retention, repository maintenance, malware detection, Security & Compliance Analyzer runs, restores and infrastructure rescans are read from the session history instead and shown as an hour-of-week profile, so you can see that maintenance usually lands on Saturday night before you put six fulls there too. This needs the REST API, so use `-Mode Rest`, or `-ActivityFromRest` with the default PowerShell mode.

## Trying changes

- **Drag a bar** sideways to move that job's start time. It snaps to 15 minutes and every run of the job moves with it.
- **Click a job name** to edit start time, run days, active and synthetic full days, the target repository, or the planning assumptions for parallel tasks and duration.
- **Click a repository header** to try a different concurrent task limit.
- **Click a server** to enter or change its cores and RAM.
- **Switch to Slow night (p90)** to test the plan against the slowest 10% of runs instead of a typical night.
- **The Changes tab** lists everything you changed as a checklist you can copy into a ticket. Nightshift never writes to VBR.

## How the prediction works

- **Durations** come from the session history in the export. Typical uses the median, slow night uses the 90th percentile. Fulls and incrementals are measured separately where VBR records which was which.
- **Synthetic fulls** add a transform step sized as a share of a full (35% by default). Health checks do the same (25% by default). Both are adjustable under Assumptions, because fast-clone repositories on XFS or ReFS need far less.
- **Chained jobs** start when the job before them is predicted to end. Immediate backup copies start when each source run ends.
- **Task slots** assume a job uses one slot per machine, capped at the repository limit. You can override that per job.
- **Without history**, a full is estimated from source size at 250 MB/s and an incremental as 15% of that. Those runs are drawn with a dashed outline.

Nightshift doesn't model storage latency control, network throttling, retries or SOBR offload. A clean plan is likely to work, but it isn't a guarantee.

## Collector reference

| Parameter | Default | Notes |
|---|---|---|
| `-Mode` | `PowerShell` | `PowerShell` uses the Veeam cmdlets, `Rest` uses the REST API on port 9419 |
| `-Server` | local | Required for `Rest` |
| `-Credential` | current user | `Rest` prompts if you leave it out |
| `-HistoryDays` | `30` | How much session history to read |
| `-OutFile` | `.\nightshift-<server>-<date>.json` | |
| `-Anonymize` | off | Replaces names with labels and hashes ids, safe for forum posts |
| `-ApiVersion` | `1.1-rev0` | REST header, raise it if your server rejects the default |
| `-SkipCertificateCheck` | off | REST only, needs PowerShell 7 |
| `-InvertWindow` | off | Flips how backup window hours are read, see below |
| `-ActivityFromRest` | off | PowerShell mode only, also reads background sessions from the REST API |
| `-ReadHardware` | off | Reads cores and RAM of Windows servers through CIM, read-only |

The collector only reads. Run it with an account that can open the VBR console. On large servers, reading sessions takes the longest, so lower `-HistoryDays` if it runs slowly.

## Privacy

The export holds job, repository, proxy and server names, schedules, run times and, with `-ReadHardware`, core and RAM counts. It holds no credentials, VM names or IP addresses. The viewer is one HTML file that reads the export in your browser and sends nothing anywhere. With `-Anonymize`, or *Hide names* in the viewer, you can share a timeline without exposing your naming scheme.

## Status and known gaps

This is version 0.1. The collector has been tested against fake Veeam objects and a mocked REST API (see `tests/`), not yet against a broad set of live servers. Reports from real environments are the most useful contribution right now. These are the places most likely to need a fix.

- **Backup window flags.** The PowerShell object model and the REST API encode allowed hours differently. If the hatched "outside backup window" areas show up exactly where your jobs are allowed to run, collect again with `-InvertWindow` and open an issue.
- **Periodic schedules.** The collector reads the interval in minutes and guards against hours and seconds. Check that a job set to every 4 hours shows up as 240 minutes.
- **Agent policies, file share jobs and tape** come through as far as the cmdlets expose their schedules. Agent jobs managed by policy may show as not scheduled.
- **REST history** can't tell fulls from incrementals, so the collector treats unusually long runs as fulls.
- **Gateway servers.** Where VBR picks gateways automatically, the export may not name them. Repository load then goes to the repository's own server. Linux server hardware isn't read, enter it in the planner.
- **Background activity** is grouped by session type. Names of background operations vary between versions, so some may show up under a generic label.

## Roadmap

- A *suggest a start time* button that finds the least busy slot for a job
- Extra checks in the collector, such as the VBR server acting as a proxy
- A per-night report you can attach to a change request

## Repository layout

```
collector/Collect-NightshiftData.ps1   the export script
dist/nightshift.html                   the viewer, ready to open
docs/index.html                        the same viewer, served by GitHub Pages as the live demo
viewer/src/app.html                    viewer source
viewer/build.py                        builds dist/ and embeds the sample
sample/                                sample export and its generator
docs/schema.md                         export format
tests/                                 collector tests (pwsh) and viewer tests (Playwright)
```

## Contributing

Issues and pull requests are welcome. If a schedule shows up wrong, the most helpful thing you can attach is an anonymized export (`-Anonymize`) and a note on what VBR shows for that job. Run `pwsh tests/Test-Collector.ps1` before you open a pull request that touches the collector. The viewer is edited in `viewer/src/app.html`, then `python3 viewer/build.py` writes `dist/nightshift.html` and the live demo copy in `docs/index.html`. Commit all three, the tests check that they match.

## License

MIT. See [LICENSE](LICENSE). Veeam and Veeam Backup & Replication are trademarks of Veeam Software. This project uses the names only to describe what it works with.
