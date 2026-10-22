# odyn (TrueNAS) config kept in the repo

odyn (`10.0.20.6`, TrueNAS 25.10) isn't NixOS, so this folder holds the parts of it the NixOS hosts
depend on, plus the scripts that apply them over its API. The scripts run from mjolnir as
`truenas_admin` (`midclt`, or `truenas_api_client` in python). That account has no root shell and
no docker access, and doesn't need them.

## apps

| app | what | files |
|---|---|---|
| `appdb` | Postgres 18 for the apps on yggdrasil (forgejo, n8n) and heimdall (moving one at a time since 2026-10), `10.0.20.6:5432`, tls + scram, each role only from its own host | [`apps/appdb/`](apps/appdb/) |
| `scrutiny-collector` | reads the disks' smart data every 10 min for the scrutiny hub (same version as the hub) | [`apps/scrutiny-collector/`](apps/scrutiny-collector/) |
| `scrutiny` | the scrutiny hub (web + its own influxdb), `10.0.20.6:30808`, files in `vault/appdata/scrutiny`; was on heimdall until 2026-10-22, traefik there still serves `scrutiny.oryxserver.org` | [`apps/scrutiny/`](apps/scrutiny/) |

Change an app's `compose.yaml`, then run `apps/update.sh <app>` (a new app: `apps/update.sh --create <app>`). appdb has its own `apps/appdb/apply.sh`
(it also did the first install; no secrets in the repo, the admin password exists only on yggdrasil).
Also on odyn but not kept here: the catalog apps `dockge` (the arr stacks in `/mnt/vault/stacks`) and
`tailscale`.

## vault/appdata (made 2026-10-20)

| dataset | owner | shared | for |
|---|---|---|---|
| `vault/appdata/postgres` | appdb 3010, 700, recordsize 16K | no | appdb's cluster (`18/docker`, server.crt/key) |
| `vault/appdata/forgejo` | forgejo 3011, 750 | NFS share 18, 10.0.20.21 only, mapall forgejo | Forgejo on yggdrasil |
| `vault/appdata/n8n` | n8n 3012, 750 | NFS share 20, 10.0.20.21 only, mapall n8n | n8n on yggdrasil |
| `vault/appdata/backups` | appdb 3010, 700 | NFS share 19, 10.0.20.21 only, mapall appdb | nightly dumps from yggdrasil |
| `vault/appdata/paperless` | paperless 3014, 750 | NFS share 22, 10.0.20.17 only, mapall paperless | Paperless's documents (heimdall) |
| `vault/appdata/changedetection` | changedetection 3015, 700 | NFS share 23, 10.0.20.17 only, mapall changedetection | changedetection's watches (heimdall) |
| `vault/appdata/scrutiny` | scrutiny 3016, 700 | no (share 24 only for the copy from heimdall, then deleted) | the `scrutiny` app here |

Snapshot tasks 13 (hourly, 2 days), 14 (daily, 30 days), 15 (weekly, 12 weeks): recursive on
`vault/appdata`.

`/mnt/vault/apps/` is something else: a plain folder with a `node_exporter` binary from March.
Leave it alone.

## a new app's dataset, user and share

```sh
ssh truenas_admin@10.0.20.6
midclt call group.create '{"name":"<app>","gid":<id>,"smb":false}'
midclt call user.create '{"username":"<app>","full_name":"<app> on yggdrasil","uid":<id>,"group":<group row id>,
  "group_create":false,"password_disabled":true,"home":"/var/empty","shell":"/usr/sbin/nologin","smb":false}'
midclt call pool.dataset.create '{"name":"vault/appdata/<app>","atime":"OFF"}'
midclt call -j filesystem.setperm '{"path":"/mnt/vault/appdata/<app>","uid":<id>,"gid":<id>,"mode":"750","options":{"stripacl":true}}'
midclt call sharing.nfs.create '{"path":"/mnt/vault/appdata/<app>","hosts":["10.0.20.21"],"mapall_user":"<app>","mapall_group":"<app>"}'
```

For an app on heimdall, put `10.0.20.17` in `hosts` instead.

Ids so far: appdb 3010, forgejo 3011, n8n 3012, backups 3013 (owns `vault/backups`, see below),
paperless 3014, changedetection 3015, scrutiny 3016.
Kept for heimdall's apps as they move: immichdb 3017, vaultwarden 3018, crafty 3019 (only if it
moves), homarr 3020 (for kubernetes later).
The next new app gets 3021. Check the id is free first: `midclt call user.query '[["uid","=",<id>]]'`
gives `[]`. The snapshot tasks already cover new datasets under `vault/appdata`. The whole pattern is
in [`docs/apps-on-odyn.md`](../docs/apps-on-odyn.md).

## vault/backups (made 2026-10-21)

Where data backups go from now on (recordsize 1M, owner backups 3013, 700). Snapshot tasks 19/20/21
(hourly 2 days, daily 30 days, weekly 12 weeks), recursive. `vault/backups/heimdall-move` holds the
backups for moving heimdall's data to odyn (NFS share 21, heimdall only, mapall backups), with a
`README.txt` that says what's where. `vault/backups/influxdb-pfsense` (since 2026-10-22, NFS share 25,
heimdall only, mapall backups) gets heimdall's nightly influxdb backup, a folder per night, a week kept
(`hosts/heimdall/modules/system/influxdb.nix`).
