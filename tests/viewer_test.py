import sys, json
from playwright.sync_api import sync_playwright
import pathlib
url = (pathlib.Path(__file__).resolve().parent.parent / "dist" / "nightshift.html").as_uri()
out = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1500, "height": 950})
    errs = []
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(url); pg.wait_for_timeout(800)
    conf = pg.evaluate("() => window.__nightshift.sim.conflicts.map(c => [c.sev, c.type, c.title])")
    for c in conf: print(c)
    print("runs", pg.evaluate("() => window.__nightshift.sim.all.length"))
    pg.screenshot(path=f"{out}/s1.png")
    # click a conflict
    pg.click(".cf >> nth=0"); pg.wait_for_timeout(600)
    pg.screenshot(path=f"{out}/s2.png")
    # select job and edit time
    pg.click('[data-jobrow="j-files"] .lab'); pg.wait_for_timeout(300)
    pg.fill("#fTime", "20:30"); pg.dispatch_event("#fTime", "change"); pg.wait_for_timeout(300)
    pg.screenshot(path=f"{out}/s3.png")
    # drag a bar of SQL
    bar = pg.locator('.bar[data-job="j-exch"]').nth(1)
    bb = bar.bounding_box()
    pg.mouse.move(bb["x"]+5, bb["y"]+10); pg.mouse.down(); pg.mouse.move(bb["x"]-60, bb["y"]+10, steps=8); pg.mouse.up()
    pg.wait_for_timeout(400)
    print("exch time", pg.evaluate("() => window.__nightshift.data.jobs.find(j=>j.id==='j-exch').schedule.time"))
    pg.click("#tabChg"); pg.wait_for_timeout(300)
    print(pg.evaluate("() => document.querySelector('#cOut').value"))
    pg.screenshot(path=f"{out}/s4.png")
    pg.click("#tabSet"); pg.wait_for_timeout(200)
    pg.click('[data-est="p90"]'); pg.wait_for_timeout(300)
    pg.click('[data-grp="type"]'); pg.wait_for_timeout(300)
    pg.check("#anon"); pg.wait_for_timeout(300)
    pg.screenshot(path=f"{out}/s5.png")
    # mobile
    m = b.new_page(viewport={"width": 400, "height": 860})
    m.goto(url); m.wait_for_timeout(600)
    print("mobile overflow", m.evaluate("() => document.documentElement.scrollWidth"))
    m.screenshot(path=f"{out}/m1.png", full_page=True)
    d = b.new_page(viewport={"width": 1500, "height": 950}, color_scheme="dark")
    d.goto(url); d.wait_for_timeout(600)
    d.screenshot(path=f"{out}/d1.png")
    real = [e for e in errs if "net::" not in e]  # font downloads fail offline, that is fine
    print("errors", real)
    b.close()
    if real: sys.exit(1)
