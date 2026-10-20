#!/usr/bin/env bash
# apply compose.yaml to the truenas custom app "appdb" on odyn. run from mjolnir.
#   ./apply.sh           update the running app (after editing compose.yaml, e.g. a new pg_hba line)
#   ./apply.sh --init    first install only: initdb takes the admin password from yggdrasil
#                        (/var/lib/secrets/appdb-admin.password), then it's taken out of the app again
# the password goes ssh to ssh over stdin, never on a command line or into a file on mjolnir
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
py=$(base64 -w0 "$here/apply.py")
run() { ssh truenas_admin@10.0.20.6 "python3 -c \"\$(echo $py | base64 -d)\""; }

if [ "${1:-}" = "--init" ]; then
  { ssh christina@10.0.20.21 'sudo cat /var/lib/secrets/appdb-admin.password'; echo; cat "$here/compose.yaml"; } | run
  echo "waiting for initdb..."
  sleep 20
fi
{ echo; cat "$here/compose.yaml"; } | run
