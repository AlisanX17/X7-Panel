#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run: curl -fsSLO https://raw.githubusercontent.com/AlisanX17/X7-Panel/main/update.sh && sudo bash update.sh"; exit 1; }
curl -fLsS https://raw.githubusercontent.com/AlisanX17/X7-Panel/main/install.sh -o /tmp/x7-install.sh
exec bash /tmp/x7-install.sh
