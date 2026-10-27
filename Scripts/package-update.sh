#!/bin/bash
# Release CI (docs/app-auto-update.md U2): publishes V2Mac.app file by file for the in-app updater, in the
# sandbox's manifest format (`BundleManifest`). OUT gets one zip per file, bsdiff patches from the same file
# of each of the last 3 releases (skipped when over 60 % of the zip, or for files under 64 KB) and files.json.
#   Scripts/package-update.sh <V2Mac.app> <out dir> <new tag>     (needs gh and bsdiff for the patches)
# Sign files.json afterwards with Scripts/sign-update.swift. Without gh access no patches are made.
set -euo pipefail
APP="$1"; OUT="$2"; TAG="$3"
# The manifest carries regular files only: an empty folder or a link would be lost on update.
[[ -z "$(find "$APP" ! -type f ! -type d)$(find "$APP" -type d -empty)" ]] || { echo "$APP has links or empty folders"; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"
OLD="$(mktemp -d)"
trap 'for m in "$OLD"/mnt-*; do [[ -d "$m" ]] && hdiutil detach -quiet -force "$m"; done; rm -rf "$OLD"' EXIT
for tag in $(gh release list --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "$TAG" | sort -V | tail -3); do
  v="${tag#v}"
  gh release download "$tag" -p "V2Mac-$v.dmg" -D "$OLD" || continue
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$OLD/mnt-$v" "$OLD/V2Mac-$v.dmg"
done
python3 - "$APP" "$OUT" "$OLD" <<'PY'
import glob, hashlib, json, os, subprocess, sys
app, out, old = sys.argv[1:]
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
source = lambda path, name: {"url": name, "sha256": sha(path), "size": os.path.getsize(path)}
olds = sorted(glob.glob(f"{old}/mnt-*"))
files = []
for d, _, names in sorted(os.walk(app)):
    for n in sorted(names):
        full = os.path.join(d, n)
        rel = os.path.relpath(full, app)
        asset = rel.removeprefix("Contents/").replace("/", "_").replace(" ", "_")
        subprocess.run(["ditto", "-c", "-k", full, f"{out}/{asset}.zip"], check=True)
        entry = {"path": rel, "sha256": sha(full), "size": os.path.getsize(full),
                 "executable": os.access(full, os.X_OK), "zip": source(f"{out}/{asset}.zip", f"{asset}.zip"), "patches": []}
        for mount in olds:
            before = os.path.join(mount, "V2Mac.app", rel)
            if entry["size"] < 65536 or not os.path.isfile(before) or sha(before) in [entry["sha256"]] + [p["from"] for p in entry["patches"]]:
                continue
            name = f"{asset}.from-{mount.rsplit('mnt-', 1)[1]}.bsdiff"
            subprocess.run(["bsdiff", before, full, f"{out}/{name}"], check=True)
            # A patch near the zip's size saves little and costs a bspatch.
            if os.path.getsize(f"{out}/{name}") > 0.6 * entry["zip"]["size"]:
                print("skipped", name)
                os.remove(f"{out}/{name}")
                continue
            entry["patches"].append({"from": sha(before), **source(f"{out}/{name}", name)})
        files.append(entry)
version = subprocess.run(["plutil", "-extract", "CFBundleShortVersionString", "raw", f"{app}/Contents/Info.plist"],
                         capture_output=True, text=True, check=True).stdout.strip()
json.dump({"version": version, "files": files}, open(f"{out}/files.json", "w"), indent=1)
full = sum(f["zip"]["size"] for f in files)
print(f"files.json: {len(files)} files, {full} bytes in zips, patches: {sum(len(f['patches']) for f in files)}")
PY
