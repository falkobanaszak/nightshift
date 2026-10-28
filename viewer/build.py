"""Builds the viewer. dist/nightshift.html is the standalone file for the repo,
dist/nightshift-demo.fragment.html is the same page without the document skeleton,
docs/index.html is the copy GitHub Pages serves as the live demo."""
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
app = open(os.path.join(here, "src", "app.html"), encoding="utf-8").read()
sample = json.load(open(os.path.join(root, "sample", "nightshift-sample.json"), encoding="utf-8"))
blob = json.dumps(sample, separators=(",", ":")).replace("</", "<\\/")
page = app.replace("/*__SAMPLE__*/", blob)
os.makedirs(os.path.join(root, "dist"), exist_ok=True)
open(os.path.join(root, "dist", "nightshift-demo.fragment.html"), "w", encoding="utf-8").write(page)
cut = page.index("</style>") + len("</style>")
full = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        + page[:cut] + '\n</head>\n<body>\n' + page[cut:] + '\n</body>\n</html>\n')
open(os.path.join(root, "dist", "nightshift.html"), "w", encoding="utf-8").write(full)
# GitHub Pages serves docs/, so the live demo is the same file
open(os.path.join(root, "docs", "index.html"), "w", encoding="utf-8").write(full)
open(os.path.join(root, "docs", ".nojekyll"), "w").close()
print("built", len(full), "bytes")
