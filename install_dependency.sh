#!/bin/bash
# Fetch the assets the app bundle needs that are not built from source: the
# mihomo core, the GeoIP database, and the web dashboard. Every download is
# verified against a pin — mihomo in Waypoint/goWaypoint/mihomo.sha256 (tag,
# commit and per-asset hashes), the rest in assets.sha256 — so an upstream
# release moving underneath us fails the bootstrap instead of silently changing
# what gets shipped.
#
#     ./install_dependency.sh            verify the pins, then install
#     ./install_dependency.sh --update   re-pin the assets in assets.sha256
#
# --update trusts whatever upstream is serving at that moment; review the new
# bytes before committing the refreshed pins.
set -euo pipefail

cd "$(dirname "$0")"

update=0
[ "${1:-}" = "--update" ] && update=1

# shellcheck source=assets.sha256
. ./assets.sha256

echo "==> mihomo core"
(cd Waypoint/goWaypoint && python3 bundle_mihomo.py)

echo "==> GeoIP database"
country_mmdb="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb"
curl -fsSL -o Country.mmdb "$country_mmdb"
mmdb_actual=$(shasum -a 256 Country.mmdb | cut -d' ' -f1)
if [ "$mmdb_actual" != "$mmdb_sha256" ]; then
    if [ "$update" != 1 ]; then
        echo "error: Country.mmdb does not match the pinned hash" >&2
        echo "  pinned: $mmdb_sha256" >&2
        echo "  actual: $mmdb_actual" >&2
        echo "" >&2
        echo "Upstream republished the rolling 'latest' release. Audit the new" >&2
        echo "database, then re-pin it with: ./install_dependency.sh --update" >&2
        exit 1
    fi
    mmdb_sha256=$mmdb_actual
    echo "note: re-pinned Country.mmdb to $mmdb_sha256"
fi

echo "==> dashboard"
dashboard=Waypoint/Resources/dashboard
if [ "$update" = 1 ]; then
    tip=$(git ls-remote https://github.com/MetaCubeX/yacd.git refs/heads/gh-pages | cut -f1)
    if [ -z "$tip" ]; then
        echo "error: could not read the yacd gh-pages tip" >&2
        exit 1
    fi
    yacd_commit=$tip
    echo "note: re-pinned dashboard to $yacd_commit"
fi

rm -rf "$dashboard"
git init -q "$dashboard"
git -C "$dashboard" remote add origin https://github.com/MetaCubeX/yacd.git
if ! git -C "$dashboard" fetch -q --depth 1 origin "$yacd_commit" 2>/dev/null; then
    echo "error: could not fetch yacd commit $yacd_commit" >&2
    echo "The commit may have been garbage-collected upstream. Re-pin it with:" >&2
    echo "  ./install_dependency.sh --update" >&2
    exit 1
fi
git -C "$dashboard" checkout -q FETCH_HEAD
git -C "$dashboard" rev-parse HEAD | grep -qx "$yacd_commit"
rm -rf "$dashboard/.git"

if [ "$update" = 1 ]; then
    python3 - "$mmdb_sha256" "$yacd_commit" <<'PY'
import pathlib, re, sys

mmdb_sha256, yacd_commit = sys.argv[1], sys.argv[2]
pin = pathlib.Path("assets.sha256")
text = pin.read_text()
text = re.sub(r"^mmdb_sha256=.*$", f"mmdb_sha256={mmdb_sha256}", text, flags=re.M)
text = re.sub(r"^yacd_commit=.*$", f"yacd_commit={yacd_commit}", text, flags=re.M)
pin.write_text(text)
PY
fi

echo "==> install GeoIP database"
rm -f ./Waypoint/Resources/Country.mmdb
gzip -f Country.mmdb
mv Country.mmdb.gz ./Waypoint/Resources/Country.mmdb.gz

echo "done"
