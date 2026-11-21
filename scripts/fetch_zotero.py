#!/usr/bin/env python3
"""Fetch stage (planning#5): snapshot of the owner's public Zotero group 6765723.

This and the Ontop/JDBC download (`make fetch`) are the only steps of the converter that use
the network; materialize, enrich, check and package run offline on the snapshot.

Writes, only after a complete and consistent download:
  .cache/zotero/group-6765723.json      the items, sorted by item key (same library version
                                        = same file)
  .cache/zotero/group-6765723.version   the library version (Zotero `Last-Modified-Version`),
                                        recorded in the release manifest
Every page must report the same library version; if the library changes during the download,
the download is repeated (at most 3 times). With an existing snapshot, the API is asked only for
changes since its version (304 = unchanged, nothing is written).

Usage: scripts/fetch_zotero.py [--force]
"""
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUP = 6765723
CACHE = ROOT / ".cache" / "zotero"
ITEMS = CACHE / f"group-{GROUP}.json"
VERSION = CACHE / f"group-{GROUP}.version"
API = f"https://api.zotero.org/groups/{GROUP}/items"
HEADERS = {"Zotero-API-Version": "3", "User-Agent": "LOD-AM-converter/0.2 (https://lod-am.net)"}


def get(url, since=None):
    headers = dict(HEADERS, **({"If-Modified-Since-Version": str(since)} if since is not None else {}))
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
            return int(r.headers["Last-Modified-Version"]), json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return since, None
        raise


def download():
    items, start, version = [], 0, None
    while True:
        v, page = get(f"{API}?format=json&limit=100&start={start}")
        if version is None:
            version = v
        elif v != version:
            return None, None                      # library changed during the download
        items += page
        start += 100
        if len(page) < 100:
            return version, items


def main(force):
    old = int(VERSION.read_text()) if VERSION.exists() and ITEMS.exists() and not force else None
    if old is not None:
        v, _ = get(f"{API}?format=versions&limit=1", since=old)
        if v == old:
            print(f"zotero: group {GROUP} unchanged (library version {old})")
            return
    for _ in range(3):
        version, items = download()
        if version is not None:
            break
    else:
        sys.exit("FAIL: Zotero library changed during every download attempt")
    if not items:
        sys.exit("FAIL: Zotero returned no items; snapshot not replaced")
    items.sort(key=lambda i: i["key"])
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = ITEMS.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False, sort_keys=True, indent=0) + "\n", encoding="utf-8")
    tmp.replace(ITEMS)
    VERSION.write_text(f"{version}\n")
    print(f"zotero: group {GROUP}, library version {version}, {len(items)} items")


if __name__ == "__main__":
    main("--force" in sys.argv[1:])
