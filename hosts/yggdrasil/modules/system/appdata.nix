{ pkgs, ... }:

# apps on yggdrasil keep their data on odyn: files on an nfs share per app under /mnt/appdata, the
# database in appdb (postgres on odyn, odyn/apps/appdb). yggdrasil itself only holds rebuildable
# things (logs, caches, search indexes) and the secrets in /var/lib/secrets. docs/apps-on-odyn.md
let
  # hard: a write waits for odyn instead of failing half way and breaking a repo.
  # automount: after a power cut this box is up long before odyn; the apps retry until the share answers
  opts = [
    "nfsvers=4.2"
    "hard"
    "noatime"
    "_netdev"
    "nofail"
    "x-systemd.automount"
    "x-systemd.mount-timeout=30"
  ];
  share = name: {
    device = "10.0.20.6:/mnt/vault/appdata/${name}";
    fsType = "nfs";
    options = opts;
  };
in
{
  fileSystems."/mnt/appdata/forgejo" = share "forgejo";   # odyn user forgejo (3011) owns it
  fileSystems."/mnt/appdata/backups" = share "backups";   # odyn user appdb (3010) owns it

  # every night: each appdb database as its own pg_dump file, plus the roles (without passwords),
  # into odyn's backups share, kept 14 days. odyn's snapshots of vault/appdata keep older ones.
  # a failed run shows up as UnitFailed (heimdall alerting.nix) → ntfy "alerts"
  systemd.services.appdb-backup = {
    description = "dump every appdb database to odyn";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [ "/mnt/appdata/backups" ];
    path = [ pkgs.postgresql_18 pkgs.coreutils pkgs.findutils ];
    environment = {
      PGHOST = "10.0.20.6";
      PGUSER = "backup";                              # pg_read_all_data, nothing else
      PGSSLMODE = "require";
      PGPASSFILE = "/var/lib/secrets/appdb-backup.pgpass";
    };
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    script = ''
      set -euo pipefail
      dir=/mnt/appdata/backups/postgres/$(date +%F)
      mkdir -p "$dir"
      pg_dumpall -d postgres --roles-only --no-role-passwords > "$dir/roles.sql"
      for db in $(psql -d postgres -Atc "select datname from pg_database where datallowconn and not datistemplate and datname <> 'postgres'"); do
        pg_dump -d "$db" -Fc -f "$dir/$db.dump.part"
        mv "$dir/$db.dump.part" "$dir/$db.dump"
        echo "$db: $(du -h "$dir/$db.dump" | cut -f1)"
      done
      find /mnt/appdata/backups/postgres -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
    '';
  };
  systemd.timers.appdb-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;                              # catch up after a night the box was off
      RandomizedDelaySec = "10m";
    };
  };
}
