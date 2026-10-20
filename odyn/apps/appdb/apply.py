# runs on odyn (sent by apply.sh). stdin: first line the admin password (empty except on the very
# first install), then compose.yaml. creates or updates the truenas custom app "appdb".
# the password only goes into the app for initdb; apply.sh's second run takes it out again.
import sys

import yaml
from truenas_api_client import Client

password = sys.stdin.readline().rstrip("\n")
cfg = yaml.safe_load(sys.stdin.read())

with Client() as c:
    exists = bool(c.call("app.query", [["name", "=", "appdb"]]))
    if password:
        if exists:
            sys.exit("appdb already exists; the password is only for the first install")
        cfg["services"]["postgres"]["environment"] = {"POSTGRES_PASSWORD": password}
        c.call("app.create", {"app_name": "appdb", "custom_app": True, "custom_compose_config": cfg}, job=True)
        print("appdb created")
    elif exists:
        c.call("app.update", "appdb", {"custom_compose_config": cfg}, job=True)
        print("appdb updated")
    else:
        sys.exit("appdb does not exist yet: run with --init")
    app = c.call("app.query", [["name", "=", "appdb"]])[0]
    env = (c.call("app.config", "appdb")["services"]["postgres"].get("environment") or {})
    print("state:", app["state"], "| password in app config:", "yes" if "POSTGRES_PASSWORD" in env else "no")
