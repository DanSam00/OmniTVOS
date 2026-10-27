#!/usr/bin/env python3
"""Removes torrent / debrid / cloud-locker strings from the app's language
catalog in the built Omni (public) bundle. Run by the "Strip Public Catalog"
build phase on the copy inside the .app; the source file is left alone, so
Omni X keeps every string.

usage: strip_public_catalog.py <path to AppLanguageCatalog.json>
"""
import json, re, sys

KEEP = {"debrid_connected", "debrid_disconnect", "debrid_not_set"}
KEY = re.compile(r"torbox|premiumize|real_?debrid|torrent|usenet|magnet|stremio|cloud_library|debrid", re.I)
VALUE = re.compile(r"torrent|magnet|usenet|torbox|premiumize|real.?debrid|debrid|offcloud", re.I)

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    catalog = json.load(f)
removed = 0
for language, strings in catalog.items():
    if not isinstance(strings, dict):
        continue
    for key in [k for k, v in strings.items()
                if k not in KEEP and (KEY.search(k) or (isinstance(v, str) and VALUE.search(v)))]:
        del strings[key]
        removed += 1
with open(path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, separators=(",", ":"))
print(f"strip_public_catalog: removed {removed} strings")
