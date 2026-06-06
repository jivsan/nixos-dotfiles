# Deploying services on nix-services

How to add a new containerized service to nix-services using NixOS's `virtualisation.oci-containers` (podman). This is the same pattern used for immich, nextcloud, and crafty.

## Mental model

Each service is a `.nix` module under `hosts/nix-services/modules/system/`. The module declares:

1. The container(s) to run
2. Volumes/mounts (NFS or local)
3. Ports to expose
4. Environment vars + secrets
5. Network (if multi-container)
6. Firewall rules

Then you:
- Add the module to `hosts/nix-services/default.nix` imports
- Add a Traefik route in `hosts/nix-services/modules/system/traefik.nix`
- Add a Pi-hole DNS record
- Push to GitHub, pull on nix-services, rebuild

That's it.

## Workflow at a glance

```
┌─ on mjolnir ─────────────────┐    ┌─ on nix-services ────┐
│ 1. Edit hosts/nix-services/  │    │ 5. git pull          │
│    modules/system/myapp.nix  │    │ 6. nixos-rebuild     │
│ 2. Add to default.nix import │ →  │ 7. verify podman ps  │
│ 3. Add Traefik route         │    │ 8. test in browser   │
│ 4. git commit && push        │    │                      │
└──────────────────────────────┘    └──────────────────────┘

In Pi-hole:
  9. Add DNS record: myapp.oryxserver.org → 10.0.0.17
```

## Anatomy of a service module

This is a complete, working pattern — copy and adjust:

```nix
# hosts/nix-services/modules/system/myapp.nix
{ pkgs, ... }:
let
  # Always pin to a SHA, never use :latest or :stable for production services
  myappImage = "docker.io/library/myapp@sha256:abc123...";
in
{
  # Pre-create directories with correct ownership.
  # 999:999 is the typical UID:GID inside official postgres/redis/nextcloud images.
  systemd.tmpfiles.rules = [
    "d /var/lib/myapp 0700 999 999 -"
  ];

  virtualisation.oci-containers.containers.myapp = {
    image = myappImage;
    autoStart = true;

    # Plain key=value env vars (visible in `systemctl show`)
    environment = {
      TZ = "Etc/UTC";
      MYAPP_LOG_LEVEL = "info";
    };

    # Secrets — file format: KEY=VALUE per line
    environmentFiles = [ "/var/lib/secrets/myapp.env" ];

    # Volumes — host:container[:options]
    volumes = [
      "/var/lib/myapp:/var/lib/myapp:rw"
      "/mnt/nas/myapp-data:/data:rw"
      "/etc/localtime:/etc/localtime:ro"
    ];

    # Ports — host:container[/proto]
    ports = [
      "127.0.0.1:8080:80"     # only reachable from this host (good for backends)
      "0.0.0.0:8443:443"      # reachable from LAN (good for Traefik backends or direct access)
    ];

    # Wait for these other containers (in the same compose group) to start first
    dependsOn = [ "myapp-db" ];

    extraOptions = [
      "--network=myapp-net"
    ];
  };

  # Custom network so containers can resolve each other by name
  systemd.services."create-myapp-network" = {
    description = "Create podman network for myapp";
    after = [ "network.target" "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists myapp-net || \
      ${pkgs.podman}/bin/podman network create myapp-net
    '';
  };

  # Open ports on the host firewall
  networking.firewall.allowedTCPPorts = [ 8443 ];
}
```

## Step-by-step: deploy a new service

### 1. Find a good image and pin it

Pull image, get its digest:

```bash
podman pull myorg/myapp:1.5.0
podman inspect myorg/myapp:1.5.0 --format '{{.Digest}}'
# Returns: sha256:abc123...
```

Use the SHA in the nix file, NOT the tag. `:latest` and `:stable` are moving targets and will break reproducibility.

### 2. Identify the data layout

For each path the container expects to persist:

- **Tiny/local-only data** (config, sqlite, runtime state) → `/var/lib/myapp` on the SSD, `tmpfiles.rules` to create with right ownership
- **Big/shareable data** (photos, files, world saves) → NFS mount at `/mnt/nas/myapp-data` (see "Adding NFS mounts" below)
- **System data** (locale, timezone) → bind mount from host: `/etc/localtime:/etc/localtime:ro`

### 3. Identify ports

- **Backend (will go through Traefik)** → bind to `127.0.0.1` only. Examples: `127.0.0.1:8080:80`. Outside world can't reach them, only Traefik on the same host can.
- **Direct LAN access** (e.g. game servers, anything not HTTP) → bind to `0.0.0.0`. Example: Minecraft `0.0.0.0:25565:25565`.
- **Multi-container apps** (db, redis, server) → only the user-facing one needs an exposed port. Backends communicate over the user-defined network.

### 4. Identify secrets

Anything sensitive (passwords, API tokens) goes to `/var/lib/secrets/` as `chmod 600` files, NEVER into the .nix file.

For a single env var:
```bash
sudo tee /var/lib/secrets/myapp.env > /dev/null <<EOF
MYAPP_API_KEY=somesecretvalue
EOF
sudo chmod 600 /var/lib/secrets/myapp.env
```

Then in the .nix module:
```nix
environmentFiles = [ "/var/lib/secrets/myapp.env" ];
```

### 5. Write the module

Copy the template from "Anatomy" above. Save as:
```
hosts/nix-services/modules/system/myapp.nix
```

### 6. Register it in default.nix

```bash
nano hosts/nix-services/default.nix
```

Add to the imports list:
```nix
imports = [
  # ... existing ...
  ./modules/system/myapp.nix
];
```

### 7. Add Traefik route (if HTTP-based)

```bash
nano hosts/nix-services/modules/system/traefik.nix
```

In `dynamicConfigOptions.http.routers`:
```nix
myapp = {
  rule = "Host(`myapp.oryxserver.org`)";
  service = "myapp";
  entryPoints = [ "websecure" ];
  tls = {};
  middlewares = [ "lan-only" ];
};
```

In `dynamicConfigOptions.http.services`:
```nix
myapp.loadBalancer.servers = [
  { url = "http://127.0.0.1:8080"; }
];
```

If the backend serves HTTPS with a self-signed cert (like odyn):
```nix
myapp.loadBalancer = {
  servers = [
    { url = "https://127.0.0.1:8443"; }
  ];
  serversTransport = "insecure";
};
```

(The `insecure` transport is already defined in `serversTransports.insecure.insecureSkipVerify = true`.)

### 8. Parse-check, commit, push

```bash
cd ~/nixos-dotfiles

nix-instantiate --parse hosts/nix-services/modules/system/myapp.nix > /dev/null && echo OK
nix-instantiate --parse hosts/nix-services/modules/system/traefik.nix > /dev/null && echo OK

git status
git add hosts/nix-services/
git commit -m "nix-services: add myapp"
git push origin main
```

### 9. Deploy on nix-services

```bash
ssh christina@10.0.0.17
cd ~/nixos-dotfiles
git pull origin main
sudo nixos-rebuild switch --flake .#nix-services
```

Watch the output. New units should be listed. If you don't see `podman-myapp.service` in "starting the following units", the container didn't get registered. Run rebuild again — sometimes the second rebuild kicks things in. If still missing, check that the module is actually imported.

### 10. Verify

```bash
sudo podman ps | grep myapp
sudo podman logs myapp 2>&1 | tail -30
sudo systemctl status podman-myapp --no-pager | head -10
```

### 11. Add Pi-hole DNS

In Pi-hole admin → Local DNS → DNS Records:
- `myapp.oryxserver.org` → `10.0.0.17`

### 12. Test

`https://myapp.oryxserver.org` — should show real Let's Encrypt cert + your app.

## Adding NFS mounts

If your service needs data on odyn (10.0.0.6):

Edit `hosts/nix-services/modules/system/nas.nix`:

```nix
fileSystems."/mnt/nas/myapp-data" = {
  device = "10.0.0.6:/mnt/vault/path/to/data";
  fsType = "nfs";
  options = commonOpts;   # or commonOpts ++ [ "ro" ] for read-only
};
```

The `commonOpts` variable in nas.nix already defines: `nfsvers=4.2 soft noatime x-systemd.automount x-systemd.idle-timeout=600 x-systemd.mount-timeout=10`.

The `x-systemd.automount` flag means the mount is lazily activated — it won't fail at boot if NFS is briefly unreachable.

After rebuild, reference in your container:
```nix
volumes = [
  "/mnt/nas/myapp-data:/data:rw"
];
```

## Multi-container app pattern

When you need multiple containers that talk to each other (e.g. app + database + cache):

```nix
{ pkgs, ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/myapp-db 0700 999 999 -"
  ];

  virtualisation.oci-containers.containers = {
    myapp-db = {
      image = "postgres:16-alpine";
      autoStart = true;
      environment = {
        POSTGRES_USER = "myapp";
        POSTGRES_DB = "myapp";
      };
      environmentFiles = [ "/var/lib/secrets/myapp-db.env" ];
      volumes = [ "/var/lib/myapp-db:/var/lib/postgresql/data" ];
      ports = [ "127.0.0.1:5435:5432" ];   # localhost-only, unique port
      extraOptions = [ "--network=myapp-net" ];
    };

    myapp-redis = {
      image = "redis:alpine";
      autoStart = true;
      ports = [ "127.0.0.1:6381:6379" ];
      extraOptions = [ "--network=myapp-net" ];
    };

    myapp-server = {
      image = "myorg/myapp@sha256:...";
      autoStart = true;
      environment = {
        DB_HOSTNAME = "myapp-db";       # resolves via network DNS
        REDIS_HOSTNAME = "myapp-redis";
      };
      environmentFiles = [ "/var/lib/secrets/myapp-db.env" ];
      ports = [ "0.0.0.0:8080:8080" ];   # only this one is exposed to LAN/Traefik
      dependsOn = [ "myapp-db" "myapp-redis" ];
      extraOptions = [ "--network=myapp-net" ];
    };
  };

  systemd.services."create-myapp-network" = {
    description = "Create podman network for myapp";
    after = [ "network.target" "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${pkgs.podman}/bin/podman network exists myapp-net || \
      ${pkgs.podman}/bin/podman network create myapp-net
    '';
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
```

Containers on the same `--network=myapp-net` resolve each other by container name (e.g. `myapp-server` reaches Postgres at `myapp-db:5432`).

Allocate **unique localhost ports** per service so multiple Postgres/Redis containers don't collide:

| Service | Postgres host port | Redis host port |
|---|---|---|
| immich | 5433 | 6379 |
| nextcloud | 5434 | 6380 |
| myapp | 5435 | 6381 |
| (next service) | 5436 | 6382 |

## Operating containers (day-to-day)

```bash
# All containers
sudo podman ps
sudo podman ps -a            # also stopped ones

# Logs
sudo podman logs <name>
sudo podman logs --tail 50 -f <name>
sudo journalctl -u podman-<name> -f

# Restart a container
sudo systemctl restart podman-<name>

# Exec into container
sudo podman exec -it <name> bash
sudo podman exec -it <name> sh         # if no bash
sudo podman exec <name> <command>      # one-shot

# Get container env vars
sudo podman inspect <name> --format '{{json .Config.Env}}' | jq

# Force-pull a new image (after updating SHA in nix)
sudo systemctl restart podman-<name>
# It pulls automatically since the image reference changed
```

## Common patterns

### Pre-create a directory with custom ownership

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/myservice 0755 1000 1000 -"
];
```

Format: `type path mode uid gid age argument`. Most container images run as a specific UID — find it via `podman exec <name> id`.

### Run a one-off command at container start

```nix
virtualisation.oci-containers.containers.myapp = {
  image = "...";
  cmd = [ "myapp" "--config" "/etc/myapp.conf" "--verbose" ];
};
```

### Override entrypoint

```nix
virtualisation.oci-containers.containers.myapp = {
  image = "...";
  entrypoint = "/bin/sh";
  cmd = [ "-c" "echo hello && sleep infinity" ];
};
```

### Container that needs to share host network

```nix
extraOptions = [ "--network=host" ];
```

This bypasses container networking — the container uses the host's network directly. Rare; useful for things like nginx-fronting-the-host or services that bind to many ports.

### Run as a specific user

Some images don't pick up `USER` directives or you want to override:
```nix
extraOptions = [ "--user=1000:1000" ];
```

## Troubleshooting

### Rebuild succeeded but container didn't start

```bash
sudo systemctl status podman-myapp --no-pager
sudo podman logs myapp 2>&1 | tail -50
```

Common causes:
- Image SHA wrong / image not pullable
- Volume host path doesn't exist or wrong perms
- Port collision with another container (`Address already in use`)
- Custom network not created yet (the `create-foo-network` service should run before `podman-foo`)

### Rebuild ignored my changes

NixOS's container management sometimes considers "container already running with this name = no change". Two fixes:

```bash
# Soft: restart the unit
sudo systemctl restart podman-myapp

# Hard: stop, remove, let nixos restart
sudo systemctl stop podman-myapp
sudo podman rm myapp
sudo nixos-rebuild switch --flake .#nix-services
```

### Container can't reach another container by name

Verify both are on the same network:
```bash
sudo podman inspect myapp --format '{{json .NetworkSettings.Networks}}' | jq
sudo podman inspect myapp-db --format '{{json .NetworkSettings.Networks}}' | jq
```

Both should list the same network (e.g. `myapp-net`). If not, the `extraOptions = [ "--network=myapp-net" ]` is missing.

### Permissions errors writing to a volume

Check ownership of the host directory matches what the container expects:
```bash
ls -la /var/lib/myapp
sudo podman exec myapp id
```

If container is uid 999 but `/var/lib/myapp` is owned by root, fix with `tmpfiles.rules`:
```nix
systemd.tmpfiles.rules = [
  "d /var/lib/myapp 0700 999 999 -"
];
```

NOTE: `tmpfiles.rules` only chowns directories it CREATES. If the dir already existed before you added the rule, run `sudo chown -R 999:999 /var/lib/myapp` once manually.

### NFS mount didn't activate

```bash
systemctl status mnt-nas-myapp-data.mount
ls /mnt/nas/myapp-data
```

`x-systemd.automount` makes the mount lazy — it triggers when something accesses the path. If `ls` fails, check the export is allowed for `10.0.0.0/24` in odyn.

## Storing secrets

Currently using plain files at `/var/lib/secrets/<name>.env`, mode 600, root-owned. Format is shell env file:

```
KEY=value
ANOTHER_KEY=another_value
```

These files:
- Are NOT in the flake (would expose secrets in git)
- Persist across rebuilds (in /var/lib, outside /nix/store)
- Should be backed up separately

For a more sophisticated setup later, consider:
- **sops-nix** — encrypted secrets in the flake, decrypted at runtime via age/PGP
- **agenix** — similar, simpler API

Either is a future improvement. Plain files work fine for a homelab.

## Checklist for adding a new service

- [ ] Image pinned with SHA digest
- [ ] Storage decision: local SSD or NFS?
- [ ] Secrets in `/var/lib/secrets/`
- [ ] Module in `hosts/nix-services/modules/system/<name>.nix`
- [ ] Module imported in `default.nix`
- [ ] Traefik route added (if HTTP)
- [ ] Pi-hole DNS record added
- [ ] Firewall ports opened in module
- [ ] Parse-check passes
- [ ] Committed and pushed to GitHub
- [ ] Pulled and rebuilt on nix-services
- [ ] `podman ps` shows container running
- [ ] Logs look clean
- [ ] Browser test passes

## Reference: existing modules to copy from

| Service | Module | Pattern |
|---|---|---|
| immich | `hosts/nix-services/modules/system/immich.nix` | Multi-container (server + db + redis) on shared network, NFS data, Traefik HTTP |
| nextcloud | `hosts/nix-services/modules/system/nextcloud.nix` | Multi-container, NFS for app + data, Traefik HTTP with custom middleware |
| crafty | `hosts/nix-services/modules/system/crafty.nix` | Single container, NFS data, mixed Traefik HTTPS + raw TCP/UDP ports |
| odyn proxy | `hosts/nix-services/modules/system/traefik.nix` | No container — just a Traefik route to an external HTTPS backend |

When adding something new, find the closest match and copy from there.
