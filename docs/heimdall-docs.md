# heimdall

Homelab services VM — the home for stateful self-hosted services, replacing the old Talos
k8s cluster. Runs on Proxmox host `hella` (the remaining Proxmox node since `thor` was
decommissioned). Storage lives on `odyn`, the TrueNAS box.

> Renamed from `nix-services` during a clean rebuild — the old VM's network stack was
> corrupted by a VLAN re-IP and was unrecoverable. Same role, same static IP, same NFS
> data (the data lives on odyn, so nothing was lost). See
> [`build-notes/HEIMDALL-BUILD.md`](build-notes/HEIMDALL-BUILD.md) for the build/handoff brief.

## Specs

- **Hostname:** `heimdall`
- **Host:** Proxmox node `hella`
- **IP:** `10.0.20.17` (static, baked into the NixOS config; outside the VLAN 20 DHCP pool)
- **Resources:** 6 vCPU / 16 GB RAM (likely over-provisioned for current load — could trim)
- **OS:** NixOS 26.05 (flake-managed; `stateVersion = "25.11"`)
- **Workloads:** mix of native NixOS services (Traefik, Grafana, Prometheus, Loki) and
  Podman containers (Immich, Nextcloud, Crafty, Paperless, Homepage)

## Storage — odyn (TrueNAS)

All persistent data is on `odyn` at `10.0.20.6`, ZFS pool `vault`, mounted over NFS. See
`hosts/heimdall/modules/system/nas.nix`. Key mounts:

```
10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/immich/upload   → Immich photos
10.0.20.6:/mnt/vault/nextcloud                          → Nextcloud files
10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/*        → Crafty config/backups/servers/…
10.0.20.6:/mnt/vault/nix-services                       → service data (dataset kept its old name)
```

> The `/mnt/vault/nix-services` dataset on odyn keeps its original name even though the host
> is now `heimdall` — renaming the host doesn't rename the NFS export. Local mount stays
> `/mnt/nas/nix-services` (grafana backups + paperless base live under it).

## Services running

Routes are defined in `traefik.nix`; all are `*.oryxserver.org` behind the wildcard cert.
Exact subdomains live in that file — the pattern is `<service>.oryxserver.org`.

| Service | Type | Notes |
|---|---|---|
| Traefik | native | reverse proxy + dashboard (`api@internal`), wildcard TLS |
| Immich | podman | photos; data on odyn NFS |
| Nextcloud | podman | files; data on odyn NFS |
| Crafty | podman | Minecraft server controller |
| Paperless | podman | document management |
| Homepage | podman | dashboard / landing page |
| Grafana | native | monitoring dashboards |
| Prometheus | native | metrics scraping |
| Loki | native | log aggregation (promtail currently commented out) |
| postgres-exporter | native | Postgres metrics |
| blackbox-exporter | native | HTTPS probes |
| Nexterm | podman | SSH/remote-access manager |
| Scrutiny | native | drive health (collector runs on odyn, pushes here) |
| Odyn UI proxy | route | `https://truenas.oryxserver.org` → `https://10.0.20.6` (insecure transport) |

## Architecture

```
             ┌─────────────────────────────────┐
             │ Pi-hole DNS                     │
             │ *.oryxserver.org → 10.0.20.17   │
             └───────────────┬─────────────────┘
                             │
             ┌───────────────▼─────────────────┐
             │ heimdall (10.0.20.17, on hella) │
             │ ┌─────────────────────────────┐ │
             │ │ Traefik :80 → :443 redirect │ │
             │ │   wildcard *.oryxserver.org │ │
             │ │   real LE cert via DNS-01   │ │
             │ └────────────┬────────────────┘ │
             │   ┌──────────┼──────────┐       │
             │   ▼          ▼          ▼       │
             │ immich   nextcloud   monitoring │
             │ +crafty  +paperless  (graf/prom/loki)
             └───────────────┬─────────────────┘
                             │ NFS (RO/RW)
             ┌───────────────▼─────────────────┐
             │ odyn — TrueNAS (10.0.20.6)      │
             │ pool "vault"                    │
             │ /mnt/vault/nextcloud            │
             │ /mnt/vault/nfs-pvc-kubernetes/  │
             └─────────────────────────────────┘
```

## Module layout

```
hosts/heimdall/
├── default.nix                     # cherry-picks shared modules + the service modules
├── hardware-configuration.nix
├── home.nix                        # minimal
└── modules/
    ├── home/fastfetch.nix
    └── system/
        ├── acme.nix                # Cloudflare DNS-01 wildcard cert
        ├── traefik.nix             # reverse proxy + all routes
        ├── nas.nix                 # NFS mounts from odyn
        ├── immich.nix              # immich-server + postgres + redis
        ├── nextcloud.nix           # nextcloud + postgres + redis
        ├── crafty.nix              # Minecraft controller
        ├── paperless.nix
        ├── homepage.nix            # dashboard
        ├── nexterm.nix
        ├── grafana.nix
        ├── prometheus.nix          # scrape targets + alerting
        ├── loki.nix
        ├── promtail.nix            # (currently disabled in default.nix)
        ├── postgres-exporter.nix
        ├── blackbox-exporter.nix
        └── scrutiny.nix            # drive health (collector on odyn)
```

`default.nix` does NOT import `configuration.nix` (that would pull in the desktop). It
cherry-picks the shared modules it needs (`boot`, `locale`, `nix`, `users`, `tailscale`)
and adds the service modules above.

## Wildcard cert (Let's Encrypt + Cloudflare DNS-01)

Cert at `/var/lib/acme/oryxserver.org/`. Auto-renews via systemd timer.

- **Domains:** `oryxserver.org`, `*.oryxserver.org`
- **DNS-01 token:** `/var/lib/secrets/cloudflare-dns-token` (`CLOUDFLARE_DNS_API_TOKEN=...`)
- **No port forwarding** — DNS-01 doesn't need port 80
- The wildcard covers any new subdomain automatically (e.g. you could move the odyn proxy to
  `odyn.oryxserver.org` with just a Pi-hole record — no new cert needed)

## Adding a new service

1. Write a Nix module if it's a container.
2. Add a Traefik router + service in `traefik.nix`.
3. Add a Pi-hole DNS entry: `<service>.oryxserver.org` → `10.0.20.17`.
4. Push, pull on the host, rebuild.

See [`deploying-services.md`](deploying-services.md) for the full walkthrough.

## Migration history

### Immich (from k8s, 2026-04-29)
- pgvecto-rs Postgres + Redis + immich-server; 7,337 assets restored from `pg_dump`.
- Photos on odyn NFS at `/mnt/vault/nfs-pvc-kubernetes/immich/upload`.
- ⚠️ **ML backend was on `nix-oryx` (`10.0.0.15`) — now decommissioned.** The
  `IMMICH_MACHINE_LEARNING_URL` is commented out in `immich.nix`, so smart search / face
  detection are off until ML is re-hosted on the new NixOS AI box (to be configured from
  mjolnir, like heimdall) and re-pointed.

### Nextcloud (from k8s, 2026-04-29)
- postgres:16-alpine + redis:alpine + nextcloud:stable; 137 tables restored from `pg_dump`.
- Files on odyn NFS at `/mnt/vault/nextcloud`; app dir at `/mnt/vault/nfs-pvc-kubernetes/nextcloud/app`.
- DB user `oc_admin` recreated post-restore (dump used `--no-owner --no-acl`).

## Common operations

```bash
# pull + apply
ssh christina@10.0.20.17
cd ~/nixos-dotfiles && git pull origin main
sudo nixos-rebuild switch --flake .#heimdall

# restart one container
sudo systemctl restart podman-<container-name>

# logs
sudo podman logs <container>
sudo journalctl -u podman-<container> -f

# occ inside Nextcloud
sudo podman exec nextcloud-server su -s /bin/bash www-data -c "php /var/www/html/occ <command>"

# manual cert renew (rarely needed)
sudo systemctl start acme-order-renew-oryxserver.org.service
```

## Known gotchas

- **`oc_admin` not in pg_dump:** `--no-owner --no-acl` strips roles. Recreate with
  `CREATE USER oc_admin WITH PASSWORD '...'` (password is `dbpassword` in `config.php`),
  then `GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO oc_admin;`.
- **Traefik dynamic config:** routers/services/middlewares go in `dynamicConfigOptions`,
  not `staticConfigOptions` (that's entryPoints only).
- **ACME `environmentFile`:** must be on the cert itself, not in `defaults` (the `defaults`
  block doesn't propagate to `acme-order-renew-*.service`).
- **Odyn backend has a self-signed cert:** Traefik needs
  `serversTransports.insecure.insecureSkipVerify = true` to accept it.
- **Nextcloud `trusted_domains`:** reachable via `https://nextcloud.oryxserver.org` only;
  `http://10.0.20.17:8081` is rejected.

## Decommissioned dependencies (cleaned up in the heimdall rebuild)

`thor` (Proxmox node) and `nix-oryx` (its AI VM, `10.0.0.15`) are gone. Their references were
removed during the rename:

- `prometheus.nix` — dropped the `thor` (`10.0.0.2`) and `nix-oryx` (`10.0.0.15`) node
  targets and the GPU-metrics job.
- `homepage.nix` — removed the `Intelligence` section (Open WebUI / ComfyUI / nix-oryx /
  Model Lab tiles) and the `Proxmox Thor` tile.
- `traefik.nix` — removed the `openwebui` and `comfyui` routers + services.
- `immich.nix` — ML URL commented out (see Migration history above).

These AI workloads are slated to return on a new NixOS **AI box**, configured from mjolnir
the same way heimdall is.
