#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ $# != 1 ]]; then
  echo "Usage: $0 SNAPSHOT (restores only the dedicated .runtime/ lab disk)" >&2
  exit 2
fi
python3 lab.py stop
python3 lab.py restore "$1"
python3 lab.py start
