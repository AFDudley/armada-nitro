#!/bin/sh
# Populate lib/* submodules at their foundry.lock pins, so `forge build` and
# `forge test` run against the pinned sources with no network at gate time.
# Build-time only (the gate image build has network; the gate run does not).
#
# The judged tree carries gitlinks but no submodule content and no .git, so a
# host `git submodule update` cannot run here. foundry.lock holds each pin
# (either {"rev": ...} or {"tag": {"rev": ...}}) and .gitmodules holds each url.
# After cloning, strip every nested .git so the parent's throwaway git commits
# lib/* as plain files, not embedded repos.
set -e

python3 - <<'PY'
import json
import subprocess

lock = json.load(open("foundry.lock"))

mods = {}
cur = None
for line in open(".gitmodules"):
    s = line.strip()
    if s.startswith("path ="):
        cur = s.split("=", 1)[1].strip()
        mods.setdefault(cur, {})["path"] = cur
    elif s.startswith("url =") and cur:
        mods[cur]["url"] = s.split("=", 1)[1].strip()

for path, info in mods.items():
    entry = lock.get(path, {})
    rev = entry.get("rev") or entry.get("tag", {}).get("rev")
    url = info.get("url")
    if not rev or not url:
        raise SystemExit(f"fetch-submodules: no rev/url for {path}")
    subprocess.run(["rm", "-rf", path], check=True)
    subprocess.run(["git", "clone", "--quiet", url, path], check=True)
    subprocess.run(["git", "-C", path, "checkout", "--quiet", rev], check=True)
    # Nested submodules (e.g. lib/armada-poc's privacy-pool, cctp).
    subprocess.run(
        ["git", "-C", path, "submodule", "update", "--init", "--recursive", "--quiet"],
        check=False,
    )
PY

find lib -name .git -exec rm -rf {} + 2>/dev/null || true
