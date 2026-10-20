# Apps on yggdrasil, data on odyn

Self-hosted apps that I add from now on run on **yggdrasil** (the always-on mini PC outside hella),
and everything worth keeping lives on **odyn** (TrueNAS): the files on an NFS share per app, the
database in **appdb**, one Postgres that runs on odyn itself. yggdrasil only holds things that can
be rebuilt (logs, caches, search indexes) and the secrets.

So if yggdrasil dies, nothing is lost: a new box gets the flake, the secrets and the mounts, and
the apps come back with all their data. odyn snapshots and the nightly dumps cover the data.

Forgejo (`git.oryxserver.org`) is the first app built this way, n8n (`n8n.oryxserver.org`) the second.

## Where everything lives

| What | Where | Notes |
|---|---|---|
| App program | yggdrasil, NixOS module in `hosts/yggdrasil/modules/system/<app>.nix` | Native NixOS service, updated with the flake |
| App files | odyn `vault/appdata/<app>`, mounted at `/mnt/appdata/<app>` on yggdrasil | NFS share for yggdrasil only, written as the odyn user `<app>` |
| Database | odyn, truenas custom app **appdb** (Postgres 18) on `10.0.20.6:5432` | Its files are in `vault/appdata/postgres` on odyn's own disks, never over NFS |
| Database dumps | odyn `vault/appdata/backups/postgres/<date>/` | Nightly from yggdrasil (`appdb-backup.service`), kept 14 days |
| Snapshots | odyn tasks 13/14/15 on `vault/appdata`, recursive | Hourly for 2 days, daily for 30 days, weekly for 12 weeks; one atomic snapshot for the whole tree |
| Secrets | yggdrasil `/var/lib/secrets/` (root, 0600) | Never in git. Listed below |
| Web address | heimdall Traefik, `lan-only` | Pi-hole CNAME `<name>.oryxserver.org` → traefik |
| Dashboard tile | Homarr board `asgard`, APPS | Skill `homarr-add-app` |
| Alerts | heimdall `alerting.nix` → ntfy `alerts` | `AppDbDown`, `SiteDown`, `UnitFailed` (any failed unit on yggdrasil, the backup job too) |

## odyn side

Defined in `odyn/` in this repo (odyn isn't NixOS, so these are applied with scripts over its API).

- **Users** (no login, no password): `appdb` 3010:3010 runs Postgres and owns the dumps,
  `forgejo` 3011:3011 owns Forgejo's share, `n8n` 3012:3012 owns n8n's. Each app gets its own user with a pinned id, and the
  same id on yggdrasil.
- **Datasets** under `vault/appdata` (atime off):
  - `postgres`: recordsize 16K for Postgres pages, owner appdb, mode 700, not shared
  - `forgejo`: owner forgejo, mode 750, NFS share 18
  - `n8n`: owner n8n, mode 750, NFS share 20
  - `backups`: owner appdb, mode 700, NFS share 19
- **NFS shares** answer only `10.0.20.21` (yggdrasil) and map every client user to the dataset's owner
  (`mapall`), like the other shares on odyn.
- **appdb** (`odyn/apps/appdb/compose.yaml`) is a TrueNAS custom app: `postgres:18.6-trixie` pinned
  by digest, running as uid 3010, listening on `10.0.20.6:5432`, 4 GB memory limit. Apply changes from
  mjolnir with `odyn/apps/appdb/apply.sh` (it recreates the container, a few seconds of downtime).
- **pg_hba** (in the same compose file) refuses everything that isn't listed. Every LAN line is
  `hostssl` + `scram-sha-256` from `10.0.20.21/32` only: admin `postgres`, read-only `backup`, and one
  line per app for its own database. Unencrypted connections and every other host are turned away
  before a password is asked.
- **TLS**: a self-signed certificate for `10.0.20.6` (EC P-256, valid until 2036) in the data dir as
  `server.crt`/`server.key`, `ssl = on` in `postgresql.auto.conf`. It was written by the server itself
  over an admin connection (`COPY ... TO '/var/lib/postgresql/18/docker/server.key'`). COPY creates
  files 0644 and Postgres refuses a readable key, so it then needed
  `COPY (SELECT 1) TO PROGRAM 'chmod 600 .../server.key'` and `SELECT pg_reload_conf()`. Clients use
  `sslmode=require`: encrypted, but they don't check the certificate.
- **First install** (done 2026-10-20): `apply.sh --init` passed the admin password from yggdrasil to
  initdb over ssh stdin, and the second step took it out of the app config again. The password now
  exists only on yggdrasil.

## yggdrasil side

- `hosts/yggdrasil/modules/system/appdata.nix`: the `/mnt/appdata/<app>` mounts, plus the nightly
  `appdb-backup` job.
  - The mounts are `hard`: a write waits for odyn instead of failing half way and breaking a repo.
  - They're automounts. After a power cut yggdrasil is up long before odyn, so the apps keep
    retrying (`RestartSec`, no start limit) until the share answers.
  - `appdb-backup` runs at 03:30 (`Persistent`, so a missed night catches up). It writes one
    `pg_dump -Fc` file per database plus `roles.sql` (roles without passwords).
- `hosts/yggdrasil/modules/system/<app>.nix`: the app.
  - It pins the app user's uid/gid to match odyn.
  - Its unit has `RequiresMountsFor` its share and `ReadWritePaths` for it.
  - It connects to appdb with `sslmode=require`.
  - The firewall lets only heimdall (`10.0.20.17`) reach its ports.
- Secrets in `/var/lib/secrets/` (root 0600, generated on the box, never printed):

  | File | What |
  |---|---|
  | `appdb-admin.password`, `appdb-admin.pgpass` | Postgres superuser (admin from yggdrasil only) |
  | `appdb-backup.password`, `appdb-backup.pgpass` | The read-only `backup` role for the dumps |
  | `forgejo-db-password` | Forgejo's database role |
  | `n8n-db-password` | n8n's database role |

  Forgejo's own secret keys (`SECRET_KEY`, `INTERNAL_TOKEN`, JWT secrets) are on odyn in
  `/mnt/appdata/forgejo/custom/conf/`. They encrypt the 2FA secrets in the database, so they're
  backed up with the data.

## heimdall side

- `traefik.nix`: an HTTPS router per app (`lan-only`). Forgejo also gets a TCP entrypoint `:2222`
  that passes git-over-ssh through to yggdrasil (`lan-only-tcp`).
- `prometheus.nix`: the app's URL in the blackbox `SiteDown` list.
- `alerting.nix`: the `appdb` TCP probe and the `AppDbDown` alert.

## Forgejo

- Web: <https://git.oryxserver.org>. Clone over ssh: `ssh://git@git.oryxserver.org:2222/<user>/<repo>.git`
  (the built-in ssh server only accepts the user `git`, `BUILTIN_SSH_SERVER_USER`).
- Package `forgejo-lts` (the long-term-support line) from nixpkgs.
- Registration is off. Accounts are made by the admin, and nothing is visible without logging in.
  New repos are private.
- On odyn (`/mnt/appdata/forgejo`): `repositories/`, `lfs/`, `data/` (attachments, avatars, packages,
  ssh host keys), `custom/conf/` (app.ini, written by NixOS on every start, and the secret keys).
- On yggdrasil (`/var/lib/forgejo`): logs, queues, the issue search index, git's home. All rebuildable.
- Admin commands (on yggdrasil):

  ```sh
  sudo -u forgejo env FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/mnt/appdata/forgejo/custom \
    forgejo admin user list
  ```

## n8n

- Web: <https://n8n.oryxserver.org>, LAN only like everything behind Traefik. Webhooks are under
  the same name, so they only answer the LAN too.
- Package: `pkgs.n8n` with the version and hashes set in `n8n.nix`, because nixpkgs lags behind
  n8n's security releases. To update: new `version`, then build once with each hash emptied to get
  the new `src` and `pnpmDeps` hashes. Drop the override when nixpkgs catches up.
- The NixOS module runs n8n as a random user; `n8n.nix` turns that off and uses `n8n` 3012, so the
  files on the share match odyn.
- In appdb (database `n8n`): workflows, credentials (encrypted), run history, users.
- On odyn (`/mnt/appdata/n8n`): `encryption-key` (0400) and `storage/` (files that runs keep).
  Without the key the credentials in a restored database can't be read, so it lives next to the data.
- On yggdrasil (`/var/lib/n8n`): `.n8n/config` (a copy of the key), logs. Rebuildable.
- The first visitor to the web page makes the owner account. Make it right after a fresh install.
- Morning report (workflow "Morning report", 07:30) posts to ntfy `reports` as the ntfy user `n8n`
  (write `reports`, read `alerts`, `backups`, `updates`, `changes`). It reads Prometheus (heimdall
  opens 9090 to yggdrasil only), Scrutiny, Proxmox through the read-only token `n8n-report@pve!morning`
  (PVEAuditor on `/nodes/hella`, `/vms`, `/storage/pbs`) and the vault's `journal/` and `MOCs/`
  (`N8N_RESTRICT_FILE_ACCESS_TO`). The tokens live only in n8n's encrypted credentials.
- Health: `/healthz/readiness` answers 200 only when the database is connected and migrated
  (Prometheus `SiteDown` and the Homarr tile use it).

## Adding the next app

1. **odyn**: a user with a fixed id, dataset `vault/appdata/<app>` owned by it, and an NFS share for
   `10.0.20.21` with mapall to it. See `odyn/README.md` for the midclt calls.
2. **appdb** (if it needs a database), on yggdrasil as root with
   `PGPASSFILE=/var/lib/secrets/appdb-admin.pgpass`:
   - Generate the password into `/var/lib/secrets/<app>-db-password`.
   - Turn it into a SCRAM verifier locally, so only the hash crosses the wire (python `hashlib.pbkdf2_hmac`, 4096 rounds).
   - Run:

     ```sql
     CREATE ROLE <app> LOGIN PASSWORD 'SCRAM-SHA-256$4096:...';
     CREATE DATABASE <app> OWNER <app> TEMPLATE template0 ENCODING 'UTF8';
     REVOKE CONNECT ON DATABASE <app> FROM PUBLIC;
     GRANT CONNECT ON DATABASE <app> TO <app>, backup;
     ```

   - Add `hostssl <app> <app> 10.0.20.21/32 scram-sha-256` to the pg_hba in
     `odyn/apps/appdb/compose.yaml` and run `odyn/apps/appdb/apply.sh`.
   - The nightly dump picks the new database up by itself.
3. **yggdrasil**: add the mount to `appdata.nix` and write `<app>.nix` like `forgejo.nix`: pinned
   uid, `RequiresMountsFor`, `ReadWritePaths`, firewall only for heimdall.
4. **heimdall**: Traefik router + service, blackbox target.
5. **Pi-hole**: CNAME `<name>.oryxserver.org` → traefik.
6. **Homarr**: tile in APPS (skill `homarr-add-app`).
7. Write it down here and in the vault.

## Restore

- **A file or a repo**: odyn snapshots, `/mnt/vault/appdata/<app>/.zfs/snapshot/<name>/` on odyn,
  or roll the dataset back in the TrueNAS UI.
- **A database** (on yggdrasil, as root):

  ```sh
  export PGPASSFILE=/var/lib/secrets/appdb-admin.pgpass PGHOST=10.0.20.6 PGSSLMODE=require PGUSER=postgres
  pg_restore --clean --if-exists -d <db> /mnt/appdata/backups/postgres/<date>/<db>.dump
  ```

  Stop the app first (`systemctl stop forgejo` / `n8n`). For a fresh appdb, recreate the roles first
  (`roles.sql` has them without passwords; set the passwords again from `/var/lib/secrets`).
- **The whole of appdb**: roll back `vault/appdata/postgres` to a snapshot with the app stopped. The
  snapshot is crash-consistent, and Postgres replays its WAL on start.
- **yggdrasil itself**: install from the flake, put the secrets back in `/var/lib/secrets/`, rebuild.
  The mounts and apps come back with their data. If the secrets are gone too, make new ones:
  - In the TrueNAS web shell (root), run `docker exec -it appdb psql -U postgres`. Socket logins
    inside the container need no password.
  - `ALTER ROLE <role> PASSWORD '...'` for each role.
  - Forgejo's own keys are on odyn, so they survive.

## Not covered yet

- Nothing leaves the house. odyn has no off-site copy (Backrest is first on the self-hosting roadmap
  in the vault).
- appdb's certificate isn't checked by clients (`require`, not `verify-full`).
