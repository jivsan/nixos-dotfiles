{ ... }:

# heimdall's apps keep their data on odyn too: the database in appdb (postgres on odyn,
# odyn/apps/appdb), the files on an nfs share per app under /mnt/appdata. the apps themselves stay
# here for now, so moving them to kubernetes later is only a config change. moved one app at a time
# from 2026-10; docs/apps-on-odyn.md
let
  # same as yggdrasil's appdata.nix. hard: a write waits for odyn instead of failing half way.
  # automount: after a power cut heimdall is up before odyn; the apps wait until the share answers
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
  # appdb's public certificate (self-signed, for 10.0.20.6). the apps connect with
  # sslmode=verify-full against it, so they know they really talk to appdb
  environment.etc."appdb/ca.crt" = {
    source = ../../../../odyn/apps/appdb/server.crt;
    mode = "0444";
  };

  # one share per app, added in the commit that moves it. each is written as its own odyn user (mapall)
  fileSystems = { };
}
