# Export format (nightshift/1)

The collector writes one JSON document. The viewer accepts any file with `schema` starting with `nightshift/`, so other tools (a Python collector, a Veeam ONE export, a hand-written plan) can feed it too.

All times are the VBR server's local time. Day names are English, Monday first.

```jsonc
{
  "schema": "nightshift/1",
  "generatedAt": "2026-10-27T09:00:00",
  "collector": { "name": "Collect-NightshiftData.ps1", "version": "0.1.0", "mode": "PowerShell" },
  "server": { "name": "vbr01", "version": "13.0.1.1071", "timezone": "GMT Standard Time", "utcOffsetMinutes": 0 },
  "anonymized": false,
  "historyDays": 30,
  "hosts": [
    { "id": "guid", "name": "repo-01", "os": "Linux", "cores": 8, "ramGB": 32, "isBackupServer": false }
  ],
  "repositories": [
    { "id": "guid", "name": "SOBR-Primary", "type": "ScaleOut", "maxTasks": 12,
      "extents": [ { "name": "Extent-01", "hostId": "guid", "maxTasks": 6 } ],
      "capacityTier": { "enabled": true, "move": true, "copy": false } },
    { "id": "guid", "name": "Object-Offsite", "type": "S3Compatible", "maxTasks": 8, "gatewayIds": ["guid"], "mountServerId": "guid" },
    { "id": "guid", "name": "Hardened-01", "type": "LinuxHardened", "maxTasks": 6, "hostId": "guid" }
  ],
  "proxies": [
    { "id": "guid", "name": "vproxy-01", "type": "VMware", "maxTasks": 8, "hostId": "guid" }
  ],
  "jobs": [ { /* see below */ } ],
  "activity": [
    { "kind": "RepositoryMaintenance", "label": "Repository maintenance", "sessions": 8, "medianMin": 160, "p90Min": 230, "profile": [ /* 168 numbers */ ] }
  ]
}
```

`maxTasks` of `0` means no limit. `cores` and `ramGB` may be null. Extents may also be plain strings (older exports).

## Activity

Observed background work that VBR starts on its own. `profile` has 168 values, Monday 00:00 first, and each is the average number of sessions of that kind running in that hour of the week over the history period. The viewer repeats the profile across the planning horizon.

## Job

| Field | Type | Notes |
|---|---|---|
| `id`, `name` | string | |
| `type` | string | `Backup`, `BackupCopy`, `Agent`, `Replica`, `FileBackup`, `Tape`, `SureBackup`, `System`, `Other` |
| `systemKind` | string | For system jobs, `ConfigurationBackup`, `SobrOffload`, `SureBackup` or `Tape` |
| `vbrType` | string | The raw type VBR reported, kept for debugging |
| `platform` | string | `VMware`, `HyperV`, `Nutanix`, `Proxmox`, `Agent`, `Other` |
| `enabled`, `scheduleEnabled` | bool | Jobs with either set to false are left out of the plan |
| `repositoryId` | string | Matches a repository `id` |
| `proxyAuto` | bool | True when VBR picks proxies automatically |
| `proxyIds` | string[] | Used when `proxyAuto` is false |
| `objectCount` | int | Machines in the job |
| `sourceSizeGB` | number or null | Used only when there is no history |
| `sourceJobIds` | string[] | Backup copy sources |
| `schedule` | object | See below |
| `fulls.active` | rule | `{ enabled, kind: "weekly", days }` or `{ enabled, kind: "monthly", monthly }` |
| `fulls.synthetic` | object | `{ enabled, days }` |
| `healthCheck` | rule | Same shape as `fulls.active` |
| `history` | object | `{ runs, incMedianMin, incP90Min, fullMedianMin, fullP90Min, lastResult }`, any value may be null |

## Schedule

| `type` | Extra fields |
|---|---|
| `daily` | `time` ("22:00"), `days` |
| `monthly` | `monthly` rule with `time` |
| `periodic` | `periodic: { everyMinutes, offsetMinutes }` |
| `continuous` | none |
| `after` | `afterJobId` |
| `immediate` | none, uses `sourceJobIds` |
| `none` | none |

Every schedule can carry `window: { enabled, allowed }` where `allowed` maps each day to 24 booleans, `true` meaning the hour is allowed. `retry: { count, waitMinutes }` is informational.

## Monthly rule

Either `{ dayOfMonth: 1..31 | "Last" }` or `{ weekNumber: "First" | "Second" | "Third" | "Fourth" | "Last", dayOfWeek: "Monday" }`, plus optional `months: ["January", ...]` and `time`.
