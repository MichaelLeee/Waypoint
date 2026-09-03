#!/bin/bash
set -e
echo "Download mihomo core"

cd Waypoint/goWaypoint
python3 bundle_mihomo.py
cd ../..

echo "delete old files"
rm -f ./Waypoint/Resources/Country.mmdb
rm -f GeoLite2-Country.*

echo "install mmdb"
curl -L -o Country.mmdb https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb
gzip -f Country.mmdb
mv Country.mmdb.gz ./Waypoint/Resources/Country.mmdb.gz

echo "install dashboard"
rm -rf ./Waypoint/Resources/dashboard
git clone -b gh-pages --depth 1 https://github.com/MetaCubeX/yacd.git ./Waypoint/Resources/dashboard
rm -rf ./Waypoint/Resources/dashboard/.git
