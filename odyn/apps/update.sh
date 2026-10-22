#!/usr/bin/env bash
# update a truenas custom app on odyn from odyn/apps/<app>/compose.yaml. run from mjolnir.
#   ./update.sh scrutiny-collector
#   ./update.sh --create scrutiny     the first install (it stops if the app already exists)
# (appdb has its own apply.sh, because its first install needs the admin password)
set -euo pipefail
create=no
if [ "${1:-}" = "--create" ]; then create=yes; shift; fi
app=${1:?usage: update.sh [--create] <app>}
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/$app/compose.yaml" ] || { echo "no $here/$app/compose.yaml" >&2; exit 1; }
py=$(base64 -w0 <<'PY'
import sys, yaml
from truenas_api_client import Client
app, create = sys.argv[1], sys.argv[2] == "yes"
cfg = yaml.safe_load(sys.stdin.read())
with Client() as c:
    exists = bool(c.call("app.query", [["name", "=", app]]))
    if create:
        if exists:
            sys.exit(f"{app} already exists on odyn: run without --create")
        c.call("app.create", {"app_name": app, "custom_app": True, "custom_compose_config": cfg}, job=True)
        done = "created"
    else:
        if not exists:
            sys.exit(f"{app} does not exist on odyn: the first time, run with --create")
        c.call("app.update", app, {"custom_compose_config": cfg}, job=True)
        done = "updated"
    a = c.call("app.query", [["name", "=", app]])[0]
    imgs = [d.get("image") for d in a.get("active_workloads", {}).get("container_details", [])]
    print(f"{app} {done}, state {a['state']}, images {imgs}")
PY
)
ssh truenas_admin@10.0.20.6 "python3 -c \"\$(echo $py | base64 -d)\" $app $create" < "$here/$app/compose.yaml"
