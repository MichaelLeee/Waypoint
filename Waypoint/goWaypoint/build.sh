#!/bin/bash
set -e
cd "$(dirname "$0")"
python3 bundle_mihomo.py "$@"
