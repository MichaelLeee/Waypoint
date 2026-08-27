#!/bin/bash
set -e
cd "$(dirname "$0")"
python3 download_mihomo.py "$@"
