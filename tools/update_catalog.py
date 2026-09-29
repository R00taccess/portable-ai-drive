#!/usr/bin/env python3
"""
Refresh file sizes and SHA-256 checksums in installer/catalog.json from Hugging Face.

    python3 tools/update_catalog.py            # check + update in place
    python3 tools/update_catalog.py --check    # only report problems

For every model / component variant it reads the repo's file list
(https://huggingface.co/api/models/<repo>/tree/main?recursive=true) and copies
the LFS size and sha256 into the catalog. Missing files are reported.
"""
import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CAT = os.path.join(HERE, "..", "installer", "catalog.json")
UA = {"User-Agent": "portable-ai-drive-catalog"}
cache = {}

def tree(repo):
    if repo not in cache:
        url = "https://huggingface.co/api/models/%s/tree/main?recursive=true" % repo
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
            cache[repo] = {f["path"]: f for f in json.loads(r.read()) if f.get("type") == "file"}
    return cache[repo]

def main():
    check_only = "--check" in sys.argv
    cat = json.load(open(CAT, encoding="utf-8"))
    items = [(m["id"], v) for m in cat["models"] for v in m["variants"]]
    items += [(k, v) for k, c in cat["components"].items() for v in c["variants"]]
    bad = 0
    for mid, v in items:
        try:
            f = tree(v["repo"]).get(v["file"])
        except Exception as e:
            print("  [?] %-30s %s: %s" % (mid, v["repo"], e)); bad += 1; continue
        if not f or "lfs" not in f:
            print("  [x] %-30s missing: %s/%s" % (mid, v["repo"], v["file"])); bad += 1; continue
        size, sha = f["lfs"]["size"], f["lfs"]["oid"]
        if size != v.get("size") or sha != v.get("sha256"):
            print("  [~] %-30s %s updated" % (mid, v["file"]))
            v["size"], v["sha256"] = size, sha
        else:
            print("  [ok] %-29s %s" % (mid, v["file"]))
    if not check_only:
        json.dump(cat, open(CAT, "w", encoding="utf-8"), indent=1)
        print("catalog written")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
