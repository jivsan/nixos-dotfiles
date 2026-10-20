#!/usr/bin/env bash
# update an existing truenas custom app on odyn from odyn/apps/<app>/compose.yaml. run from mjolnir.
#   ./update.sh scrutiny-collector
# (appdb has its own apply.sh, which can also do the first install)
set -euo pipefail
app=${1:?usage: update.sh <app>}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/$app/compose.yaml" ] || { echo "no $here/$app/compose.yaml" >&2; exit 1; }
py=$(base64 -w0 <<'PY'
import sys, yaml
from truenas_api_client import Client
app = sys.argv[1]
cfg = yaml.safe_load(sys.stdin.read())
with Client() as c:
    if not c.call("app.query", [["name", "=", app]]):
        sys.exit(f"{app} does not exist on odyn")
    c.call("app.update", app, {"custom_compose_config": cfg}, job=True)
    a = c.call("app.query", [["name", "=", app]])[0]
    imgs = [d.get("image") for d in a.get("active_workloads", {}).get("container_details", [])]
    print(f"{app} updated, state {a['state']}, images {imgs}")
PY
)
ssh truenas_admin@10.0.20.6 "python3 -c \"\$(echo $py | base64 -d)\" $app" < "$here/$app/compose.yaml"
