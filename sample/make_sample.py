"""Generates sample/nightshift-sample.json, a fictional VBR environment with
deliberate scheduling problems so every conflict type shows up in the viewer."""
import json, os

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
WEEKDAYS = DAYS[:5]


def window(allowed_ranges, days=DAYS):
    """allowed_ranges is a list of (startHour, endHour) pairs, end exclusive, may wrap midnight.
    Returns {day: [24 bools]} where True means the job may run in that hour."""
    out = {}
    for d in DAYS:
        hours = [False] * 24
        if d in days:
            for s, e in allowed_ranges:
                h = s
                while h != e:
                    hours[h] = True
                    h = (h + 1) % 24
        out[d] = hours
    return out


def full_window():
    return {"enabled": False, "allowed": None}


def job(id, name, type, repo, objects, sizeGB, schedule, history, fulls=None, health=None,
        platform="VMware", proxyAuto=True, proxyIds=None, enabled=True, sourceJobIds=None):
    return {
        "id": id, "name": name, "type": type, "platform": platform,
        "enabled": enabled, "scheduleEnabled": True,
        "repositoryId": repo, "proxyAuto": proxyAuto, "proxyIds": proxyIds or [],
        "objectCount": objects, "sourceSizeGB": sizeGB,
        "sourceJobIds": sourceJobIds or [],
        "schedule": schedule,
        "fulls": fulls or {"active": {"enabled": False}, "synthetic": {"enabled": False}},
        "healthCheck": health or {"enabled": False},
        "history": history,
    }


def sysjob(id, name, kind, repo, tasks, schedule, history):
    t = kind if kind in ("SureBackup", "Tape") else "System"
    j = job(id, name, t, repo, tasks, None, schedule, history, platform="Other", proxyAuto=False)
    j["systemKind"] = kind
    return j


def profile(slots):
    """slots: list of (dayList, startHour, endHour, avgConcurrent). Returns 168 values, Monday 00:00 first."""
    out = [0.0] * 168
    for days, a, b, v in slots:
        for d in days:
            i = DAYS.index(d) * 24 + a
            n = (b - a) % 24 or 24
            for k in range(n):
                idx = (i + k) % 168
                out[idx] = round(out[idx] + v, 2)
    return out


def hist(runs, inc, incp90, full=None, fullp90=None, last="Success"):
    return {"runs": runs, "incMedianMin": inc, "incP90Min": incp90,
            "fullMedianMin": full, "fullP90Min": fullp90, "lastResult": last}


hosts = [
    {"id": "h-vbr", "name": "vbr-demo", "os": "Windows", "cores": 8, "ramGB": 32, "isBackupServer": True},
    {"id": "h-px1", "name": "vproxy-01", "os": "Linux", "cores": 8, "ramGB": 16},
    {"id": "h-px2", "name": "vproxy-02", "os": "Linux", "cores": 8, "ramGB": 16},
    {"id": "h-ext1", "name": "repo-ext-01", "os": "Linux", "cores": 4, "ramGB": 32},
    {"id": "h-ext2", "name": "repo-hv-01", "os": "Windows", "cores": 4, "ramGB": 24},
    {"id": "h-hard", "name": "hardened-01", "os": "Linux", "cores": 4, "ramGB": 16},
    {"id": "h-branch", "name": "branch-aio", "os": "Windows", "cores": 4, "ramGB": 16},
    {"id": "h-gw", "name": "s3-gateway-01", "os": "Linux", "cores": None, "ramGB": None},
]
repos = [
    {"id": "r-sobr", "name": "SOBR-Primary", "type": "ScaleOut", "maxTasks": 12,
     "extents": [{"name": "Extent-01", "hostId": "h-ext1", "maxTasks": 6},
                 {"name": "Extent-02", "hostId": "h-ext2", "maxTasks": 6}],
     "capacityTier": {"enabled": True, "move": True, "copy": False}, "mountServerId": "h-vbr"},
    {"id": "r-hard", "name": "Hardened-Linux-01", "type": "LinuxHardened", "maxTasks": 6, "hostId": "h-hard", "mountServerId": "h-vbr"},
    {"id": "r-branch", "name": "Branch-Repo", "type": "WinLocal", "maxTasks": 4, "hostId": "h-branch", "mountServerId": "h-branch"},
    {"id": "r-obj", "name": "Object-Offsite", "type": "S3Compatible", "maxTasks": 8, "gatewayIds": ["h-gw"], "mountServerId": "h-vbr"},
]
proxies = [
    {"id": "p-1", "name": "vproxy-01", "type": "VMware", "maxTasks": 8, "hostId": "h-px1"},
    {"id": "p-2", "name": "vproxy-02", "type": "VMware", "maxTasks": 8, "hostId": "h-px2"},
    {"id": "p-3", "name": "repo-hv-01", "type": "HyperV", "maxTasks": 4, "hostId": "h-ext2"},
]

retry = {"count": 3, "waitMinutes": 10}

jobs = [
    job("j-dc", "Domain Controllers", "Backup", "r-sobr", 3, 300,
        {"type": "daily", "time": "20:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 12, 18, 45, 60),
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Saturday"]}}),
    job("j-web", "Web Frontends", "Backup", "r-sobr", 10, 1800,
        {"type": "daily", "time": "21:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 35, 55, 160, 190),
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Saturday"]}}),
    job("j-sql", "SQL Production", "Backup", "r-sobr", 8, 6200,
        {"type": "daily", "time": "22:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 75, 110, 330, 380),
        fulls={"active": {"enabled": True, "kind": "weekly", "days": ["Saturday"]},
               "synthetic": {"enabled": False}},
        health={"enabled": True, "kind": "monthly", "monthly": {"weekNumber": "Last", "dayOfWeek": "Saturday"}}),
    job("j-files", "File Servers", "Backup", "r-sobr", 12, 14500,
        {"type": "daily", "time": "22:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 95, 140, 520, 600),
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Saturday"]}}),
    job("j-exch", "Exchange DAG", "Backup", "r-sobr", 4, 5100,
        {"type": "daily", "time": "22:30", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 60, 85, 280, 320),
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Friday"]}}),
    job("j-app", "App Servers", "Backup", "r-sobr", 14, 3900,
        {"type": "after", "afterJobId": "j-sql", "window": full_window(), "retry": retry},
        hist(30, 50, 80, 240, 290),
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Sunday"]}}),
    job("j-vdi", "VDI Gold Images", "Backup", "r-sobr", 40, 9800,
        {"type": "daily", "time": "23:00", "days": WEEKDAYS,
         "window": {"enabled": True, "allowed": window([(20, 6)])}, "retry": retry},
        hist(22, 140, 210, 470, 540),
        fulls={"active": {"enabled": True, "kind": "monthly",
                          "monthly": {"weekNumber": "First", "dayOfWeek": "Monday"}},
               "synthetic": {"enabled": False}}),
    job("j-agents", "Linux Agents", "Agent", "r-sobr", 18, 2600,
        {"type": "daily", "time": "01:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 40, 70, 150, 180), platform="Linux", proxyAuto=False),
    job("j-hv", "Hyper-V Cluster", "Backup", "r-sobr", 9, 4100,
        {"type": "daily", "time": "00:30", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 55, 90, 260, 300), platform="HyperV", proxyAuto=False, proxyIds=["p-3"],
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Saturday"]}}),
    job("j-copy-imm", "Copy to Hardened (Tier 1)", "BackupCopy", "r-hard", 12, 11300,
        {"type": "immediate", "window": full_window(), "retry": retry},
        hist(30, 45, 70, 200, 240), sourceJobIds=["j-sql", "j-exch"], proxyAuto=False),
    job("j-copy-files", "Copy Files to Hardened", "BackupCopy", "r-hard", 12, 14500,
        {"type": "daily", "time": "23:30", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 70, 120, 300, 360), sourceJobIds=["j-files"], proxyAuto=False),
    job("j-branch", "Branch Office", "Backup", "r-branch", 6, 1900,
        {"type": "daily", "time": "19:00", "days": WEEKDAYS,
         "window": {"enabled": True, "allowed": window([(18, 7)])}, "retry": retry},
        hist(20, 150, 260, 420, 500),
        fulls={"active": {"enabled": True, "kind": "weekly", "days": ["Friday"]},
               "synthetic": {"enabled": False}}),
    job("j-dev", "Dev Lab", "Backup", "r-branch", 15, 2200,
        {"type": "periodic", "periodic": {"everyMinutes": 240, "offsetMinutes": 0},
         "window": full_window(), "retry": retry},
        hist(60, 50, 75)),
    job("j-cap", "Offsite Copy (Object)", "BackupCopy", "r-obj", 30, 21000,
        {"type": "daily", "time": "03:00", "days": DAYS, "window": full_window(), "retry": retry},
        hist(30, 110, 170, 600, 720), sourceJobIds=["j-web", "j-dc"], proxyAuto=False),
    job("j-new", "New ERP (no history yet)", "Backup", "r-sobr", 5, 2400,
        {"type": "daily", "time": "22:15", "days": DAYS, "window": full_window(), "retry": retry},
        {"runs": 0, "incMedianMin": None, "incP90Min": None, "fullMedianMin": None,
         "fullP90Min": None, "lastResult": None},
        fulls={"active": {"enabled": False}, "synthetic": {"enabled": True, "days": ["Saturday"]}}),
    sysjob("s-cfg", "Configuration backup", "ConfigurationBackup", "r-hard", 1,
           {"type": "daily", "time": "10:00", "days": DAYS, "window": full_window(), "retry": None}, hist(30, 4, 6)),
    sysjob("s-offload", "SOBR offload, SOBR-Primary", "SobrOffload", "r-sobr", 4,
           {"type": "periodic", "periodic": {"everyMinutes": 240, "offsetMinutes": 0}, "window": full_window(), "retry": None},
           hist(180, 20, 55)),
    sysjob("s-sure", "SureBackup, Tier 1 apps", "SureBackup", "r-sobr", 3,
           {"type": "daily", "time": "08:00", "days": ["Sunday"], "window": full_window(), "retry": None}, hist(4, 95, 120)),
    sysjob("s-tape", "Tape GFS weekly", "Tape", "r-sobr", 2,
           {"type": "daily", "time": "01:00", "days": ["Sunday"], "window": full_window(), "retry": None}, hist(4, 310, 380)),
    job("j-old", "Decommissioned CRM", "Backup", "r-sobr", 2, 400,
        {"type": "daily", "time": "21:30", "days": DAYS, "window": full_window(), "retry": retry},
        hist(5, 10, 14), enabled=False),
]

data = {
    "schema": "nightshift/1",
    "generatedAt": "2026-10-27T09:00:00",
    "collector": {"name": "sample", "version": "0.1.0", "mode": "Sample"},
    "server": {"name": "vbr-demo", "version": "13.0.1", "timezone": "Europe/Lisbon", "utcOffsetMinutes": 0},
    "anonymized": False,
    "historyDays": 30,
    "hosts": hosts,
    "repositories": repos,
    "proxies": proxies,
    "jobs": jobs,
    "activity": [
        {"kind": "BackgroundOperation", "label": "Background retention", "sessions": 30, "medianMin": 35, "p90Min": 70,
         "profile": profile([(DAYS, 0, 1, 1.0)])},
        {"kind": "RepositoryMaintenance", "label": "Repository maintenance (compact, health check)", "sessions": 8, "medianMin": 160, "p90Min": 230,
         "profile": profile([(["Saturday"], 22, 2, 1.6), (["Sunday"], 2, 4, 0.8)])},
        {"kind": "MalwareDetection", "label": "Malware detection scans", "sessions": 120, "medianMin": 25, "p90Min": 50,
         "profile": profile([(DAYS, 1, 3, 0.9), (DAYS, 23, 1, 0.4)])},
        {"kind": "Restore", "label": "Restores and instant recovery", "sessions": 22, "medianMin": 18, "p90Min": 75,
         "profile": profile([(DAYS[:5], 9, 17, 0.25)])},
        {"kind": "Infrastructure", "label": "Infrastructure rescans", "sessions": 180, "medianMin": 6, "p90Min": 12,
         "profile": profile([(DAYS, h, h + 1, 0.15) for h in range(0, 24, 4)])},
    ],
}

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "nightshift-sample.json"), "w") as f:
    json.dump(data, f, indent=2)
print("jobs:", len(jobs))
