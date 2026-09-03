#!/usr/bin/env python3
"""Bundle the mihomo core for the Waypoint app bundle.

Default mode builds mihomo from the source tag pinned in ``mihomo.sha256``
(pinned tag AND commit hash) with the local Go toolchain, for darwin arm64 +
amd64, merged into one universal Mach-O with ``lipo``. Trust chain: the pinned
source + your Go toolchain — no MetaCubeX release binary is executed or
shipped. Requires Go: ``brew install go`` (or https://go.dev/dl/).

``--official`` instead downloads the official release binaries and verifies
every asset against the SHA256 hashes pinned in ``mihomo.sha256``. Note
MetaCubeX publishes no checksums or signatures, so those pins were computed
from the official GitHub release at pin time; they detect mirror tampering and
download drift, not upstream malice. The official binary can never be proven
to be the pinned source (upstream embeds a wall-clock build timestamp), which
is why from-source is the default.

Built slices are cached under ``.mihomo-build/`` keyed by version; delete it
(or pass --force) to rebuild.

Usage:
    python3 bundle_mihomo.py                  # build pinned version from source
    python3 bundle_mihomo.py --official       # download + verify official binaries
    python3 bundle_mihomo.py --version 1.19   # override version (v prefix optional)
"""

import argparse
import gzip
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = "https://github.com/MetaCubeX/mihomo"
REPO_API = "https://api.github.com/repos/MetaCubeX/mihomo"
USER_AGENT = "Waypoint-build"
HERE = os.path.dirname(os.path.abspath(__file__))
PIN_FILE = os.path.join(HERE, "mihomo.sha256")
CACHE_ROOT = os.path.join(HERE, ".mihomo-build")

# Build flags mirror upstream's Makefile (CGO_ENABLED=0, with_gvisor, trimpath,
# stripped) with a fixed version string so our build is a faithful source build.
GOLDFLAGS = "-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=v{ver}"

# Per-architecture asset name, newest-first preference (official mode only).
# Intel Macs on macOS 10.14 need the ``-compatible`` build (lower deployment
# target); Waypoint itself requires macOS 26+, so from-source builds have no
# deployment-target concern.
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


def read_pin():
    """Returns (version, commit, {asset_name: sha256}) from mihomo.sha256."""
    version, commit, hashes = None, None, {}
    with open(PIN_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("version="):
                version = line.split("=", 1)[1]
            elif line.startswith("commit="):
                commit = line.split("=", 1)[1]
            elif "=" in line:
                name, digest = line.split("=", 1)
                hashes[name.strip()] = digest.strip().lower()
    if not version:
        raise SystemExit(f"malformed pin file {PIN_FILE}: missing version=")
    return version, commit, hashes


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve_version(version):
    if version and version != "latest":
        return version.lstrip("v")
    pinned, _, _ = read_pin()
    return pinned


def check_go():
    try:
        out = subprocess.check_output(["go", "version"], text=True).strip()
        print(f"  {out}")
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(
            "Go is required to build mihomo from source.\n"
            "  install it with: brew install go\n"
            "  or fall back to the checksum-verified official binaries with: --official"
        )


def ls_remote_tag_commit(ver, attempts=3):
    """Resolve the commit a tag points to, retrying against GitHub's
    transient rate limits on unauthenticated git access (CI runners share
    IP pools, so this fails over to the GitHub API before giving up)."""
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            out = subprocess.check_output(
                ["git", "ls-remote", REPO, f"refs/tags/v{ver}"], text=True
            ).strip()
            if not out:
                raise SystemExit(f"tag v{ver} does not exist on {REPO}")
            return out.split()[0]
        except subprocess.CalledProcessError as exc:
            last_error = exc
            print(f"  git ls-remote failed (attempt {attempt}/{attempts}), retrying")
            time.sleep(5 * attempt)
    try:
        ref = fetch_json(f"{REPO_API}/git/ref/tags/v{ver}")
        sha = ref.get("object", {}).get("sha")
        if sha:
            print("  git ls-remote unavailable; resolved the tag via the GitHub API")
            return sha
    except Exception:
        pass
    raise SystemExit(f"cannot resolve tag v{ver} on {REPO}: {last_error}")


def clone_pinned(ver, commit):
    src = tempfile.mkdtemp(prefix="mihomo-src-")
    subprocess.check_call(
        ["git", "clone", "--depth", "1", "--branch", f"v{ver}", REPO, src]
    )
    head = subprocess.check_output(
        ["git", "-C", src, "rev-parse", "HEAD"], text=True
    ).strip()
    if commit and head != commit:
        shutil.rmtree(src, ignore_errors=True)
        raise SystemExit(
            f"COMMIT MISMATCH: tag v{ver} resolved to {head}, pin file says {commit}. "
            "Do not proceed — the clone differs from the pinned commit."
        )
    return src


def build_from_source(ver, commit, force):
    check_go()
    print(f"  verifying tag v{ver} against the pin")
    remote_commit = ls_remote_tag_commit(ver)
    if commit and remote_commit != commit:
        raise SystemExit(
            f"COMMIT MISMATCH: tag v{ver} on GitHub points to {remote_commit}, "
            f"pin file says {commit}. Do not proceed — investigate before building."
        )
    if not commit:
        print(f"  WARNING: no commit= pinned for v{ver}; skipping commit verification")

    print(f"  cloning v{ver}")
    src = clone_pinned(ver, commit)
    try:
        slices = []
        for arch in ("arm64", "amd64"):
            cached = os.path.join(CACHE_ROOT, f"v{ver}", f"darwin-{arch}")
            if force or not os.path.exists(cached):
                print(f"  building darwin/{arch}")
                subprocess.check_call(
                    ["go", "build", "-tags", "with_gvisor", "-trimpath",
                     "-ldflags", GOLDFLAGS.format(ver=ver),
                     "-o", cached + ".tmp", "."],
                    cwd=src,
                    env={**os.environ, "CGO_ENABLED": "0", "GOOS": "darwin",
                         "GOARCH": arch},
                )
                os.makedirs(os.path.dirname(cached), exist_ok=True)
                os.replace(cached + ".tmp", cached)
            else:
                print(f"  reusing cached build {cached} (--force to rebuild)")
            slices.append(cached)
        return slices
    finally:
        shutil.rmtree(src, ignore_errors=True)


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


def official_download(ver, pinned_version, pinned_hashes):
    pinned = ver == pinned_version
    release = fetch_json(f"{REPO_API}/releases/tags/v{ver}")
    tmp = tempfile.mkdtemp(prefix="mihomo-official-")
    try:
        slices = []
        for arch in ("amd64", "arm64"):
            asset = pick_asset(release["assets"], arch, ver)
            gz = os.path.join(tmp, asset["name"])
            raw = gz[:-3] if gz.endswith(".gz") else gz + ".bin"
            download(asset["browser_download_url"], gz)
            digest = sha256_of(gz)
            if pinned:
                expected = pinned_hashes.get(asset["name"])
                if not expected:
                    raise SystemExit(
                        f"{asset['name']} has no pinned hash in {PIN_FILE}; "
                        "add it or fix the pin before building"
                    )
                if digest != expected:
                    raise SystemExit(
                        f"CHECKSUM MISMATCH for {asset['name']}: got {digest}, "
                        f"expected {expected}. Do not proceed — the download "
                        "differs from the pinned release asset."
                    )
                print(f"  {asset['name']}: sha256 OK")
            else:
                print(f"  WARNING: unpinned version v{ver}, no checksum "
                      f"verification. {asset['name']} sha256={digest}")
            with gzip.open(gz, "rb") as fin, open(raw, "wb") as fout:
                shutil.copyfileobj(fin, fout)
            slices.append(raw)
        return slices
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
        "--official", action="store_true",
        help="download the official release binaries (checksum-verified) "
             "instead of building from source",
    )
    parser.add_argument(
        "--force", action="store_true",
        help="rebuild even if cached source-build slices exist",
    )
    parser.add_argument(
        "--version",
        default=os.environ.get("MIHOMO_VERSION"),
        help="mihomo version tag to bundle (default: the version pinned in mihomo.sha256)",
    )
    args = parser.parse_args()

    resources_dir = os.path.abspath(os.path.join(HERE, "..", "Resources"))
    info_plist = os.path.abspath(os.path.join(HERE, "..", "Info.plist"))
    out_binary = os.path.join(resources_dir, "mihomo")

    pinned_version, pinned_commit, pinned_hashes = read_pin()
    ver = resolve_version(args.version)
    print(f"bundling mihomo v{ver}")

    if args.official:
        slices = official_download(ver, pinned_version, pinned_hashes)
    else:
        commit = pinned_commit if ver == pinned_version else None
        slices = build_from_source(ver, commit, args.force)

    os.makedirs(resources_dir, exist_ok=True)
    subprocess.check_call(["lipo", "-create", *slices, "-output", out_binary])
    os.chmod(out_binary, 0o755)
    print(f"  wrote {out_binary}")

    write_core_version(info_plist, ver)
    print("done")


if __name__ == "__main__":
    sys.exit(main())
