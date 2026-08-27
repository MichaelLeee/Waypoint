#!/usr/bin/env python3
"""Bundle a prebuilt mihomo binary for the Waypoint app bundle.

The old in-process CGO bridge (compiled from the upstream core source into a
static ``goWaypoint.a``) has been replaced by running mihomo as a subprocess.
Instead of compiling Go we now fetch the official MetaCubeX release binaries
for both macOS architectures, merge them into one universal Mach-O with
``lipo``, and drop the result into ``Waypoint/Resources/mihomo`` where the app
expects to find it via ``Bundle.main.path(forResource:ofType:)``.

Usage:
    python3 download_mihomo.py                 # latest release
    python3 download_mihomo.py --version 1.19  # specific tag (v prefix optional)
"""

import argparse
import gzip
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO_API = "https://api.github.com/repos/MetaCubeX/mihomo"
USER_AGENT = "Waypoint-build"

# Per-architecture asset name, newest-first preference. Intel Macs on macOS
# 10.14 need the ``-compatible`` build (lower deployment target); Apple Silicon
# has no ``-compatible`` variant because all Apple Silicon Macs run macOS 11+.
ARCH_ASSETS = {
    "amd64": [
        "mihomo-darwin-amd64-compatible-v{ver}.gz",
        "mihomo-darwin-amd64-v{ver}.gz",
    ],
    "arm64": [
        "mihomo-darwin-arm64-v{ver}.gz",
    ],
}


def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


def resolve_version(version):
    if version and version != "latest":
        return version.lstrip("v")
    return fetch_json(f"{REPO_API}/releases/latest")["tag_name"].lstrip("v")


def pick_asset(assets, arch, ver):
    wanted = [p.format(ver=ver) for p in ARCH_ASSETS[arch]]
    by_name = {a["name"]: a for a in assets}
    for name in wanted:
        if name in by_name:
            return by_name[name]
    raise SystemExit(
        f"no mihomo darwin-{arch} asset for v{ver}; looked for: {', '.join(wanted)}"
    )


def download(url, dest):
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req) as resp, open(dest, "wb") as out:
        shutil.copyfileobj(resp, out)


def write_core_version(info_plist, ver):
    with open(info_plist, "rb") as f:
        contents = plistlib.load(f)
    contents["coreVersion"] = ver
    with open(info_plist, "wb") as f:
        plistlib.dump(contents, f, sort_keys=False, fmt=plistlib.FMT_XML)
    print(f"  wrote coreVersion={ver} to {info_plist}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version",
        default=os.environ.get("MIHOMO_VERSION", "latest"),
        help="mihomo version tag to bundle (default: latest)",
    )
    args = parser.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    resources_dir = os.path.abspath(os.path.join(here, "..", "Resources"))
    info_plist = os.path.abspath(os.path.join(here, "..", "Info.plist"))
    out_binary = os.path.join(resources_dir, "mihomo")

    ver = resolve_version(args.version)
    print(f"bundling mihomo v{ver}")

    release = fetch_json(f"{REPO_API}/releases/tags/v{ver}")
    assets = release["assets"]

    tmp = tempfile.mkdtemp(prefix="mihomo-")
    try:
        slices = []
        for arch in ("amd64", "arm64"):
            asset = pick_asset(assets, arch, ver)
            gz = os.path.join(tmp, asset["name"])
            raw = gz[:-3] if gz.endswith(".gz") else gz + ".bin"
            download(asset["browser_download_url"], gz)
            with gzip.open(gz, "rb") as fin, open(raw, "wb") as fout:
                shutil.copyfileobj(fin, fout)
            slices.append(raw)

        os.makedirs(resources_dir, exist_ok=True)
        subprocess.check_call(["lipo", "-create", *slices, "-output", out_binary])
        os.chmod(out_binary, 0o755)
        print(f"  wrote {out_binary}")

        write_core_version(info_plist, ver)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("done")


if __name__ == "__main__":
    sys.exit(main())
