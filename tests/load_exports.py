# Loads every export written by Test-Collector.ps1 into the viewer and fails on script errors
# or if the viewer rejects a file. Run Test-Collector.ps1 first.
import glob, os, pathlib, sys, tempfile
from playwright.sync_api import sync_playwright

url = (pathlib.Path(__file__).resolve().parent.parent / "dist" / "nightshift.html").as_uri()
files = sorted(glob.glob(os.path.join(tempfile.gettempdir(), "nightshift-test-*.json")))
if not files:
    sys.exit("No exports found. Run pwsh tests/Test-Collector.ps1 first.")

failed = False
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(url)
    pg.wait_for_timeout(400)
    for f in files:
        pg.set_input_files("#file", f)
        pg.wait_for_timeout(400)
        r = pg.evaluate("""() => ({
            jobs: window.__nightshift.data.jobs.length,
            runs: window.__nightshift.sim.all.length,
            conflicts: window.__nightshift.sim.conflicts.length,
            banner: document.querySelector('#banner').hidden ? '' : document.querySelector('#banner').textContent })""")
        print(os.path.basename(f), r)
        if r["banner"]:
            failed = True
    b.close()

print("errors", errs)
if errs or failed:
    sys.exit(1)
