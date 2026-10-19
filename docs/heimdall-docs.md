# heimdall

my services vm. everything stateful and self hosted lives here, behind traefik at `*.oryxserver.org`.
it runs on `hella` (proxmox) and keeps its bulk data on `odyn` (truenas).

## specs

- **ip:** `10.0.20.17`, static in the config, outside the vlan 20 dhcp pool
- **host:** proxmox node `hella`, 6 vcpu / 16 GB ram
- **os:** nixos 26.05 from this flake, `stateVersion = "25.11"`
- **dns:** pihole (`10.0.20.4`), so the `*.oryxserver.org` records resolve locally
- **backups:** the whole vm disk goes to proxmox backup every night (stored on odyn)

## storage on odyn

bulk files go to odyn over nfs, databases stay on heimdall's own disk (nfs locking can corrupt
sqlite and postgres). mounts are in `hosts/heimdall/modules/system/nas.nix`:

```
10.0.20.6:/mnt/vault/immich                       → immich photos (own dataset, export only for heimdall)
10.0.20.6:/mnt/vault/nfs-pvc-kubernetes/crafty/*  → crafty config, backups, servers …
10.0.20.6:/mnt/vault/nix-services                 → service data (paperless, grafana and vaultwarden backups)
10.0.20.6:/mnt/vault/obsidian                     → the muninn vault
```

the nfs mounts are `soft`, so a slow odyn gives write errors instead of hanging. another reason to keep
databases local.

## services

routes are in `traefik.nix`, all behind the wildcard cert and the `lan-only` middleware (vlan 20, my
phone, tailscale).

| service              | runs as | notes                                                       |
|----------------------|---------|-------------------------------------------------------------|
| traefik              | native  | reverse proxy + dashboard at `traefik.oryxserver.org`       |
| immich               | podman  | photos at `immich.oryxserver.org`, machine learning on mimir (`10.0.20.18:3003`) |
| paperless            | podman  | documents, with its own postgres + redis                    |
| vaultwarden          | podman  | passwords at `vault.oryxserver.org`, sqlite on local disk, daily backup to odyn |
| homarr               | podman  | dashboard at `home.oryxserver.org`, sqlite in `/var/lib/homarr` |
| crafty               | podman  | minecraft server control                                     |
| obsidian             | podman  | the muninn vault in the browser at `obsidian.oryxserver.org` |
| grafana              | podman  | dashboards at `grafana.oryxserver.org`                      |
| influxdb             | podman  | pfsense metrics from telegraf, 90 days                      |
| scrutiny             | podman  | drive health, the collector runs on odyn and pushes here    |
| prometheus + loki    | native  | metrics and logs (no log shipper yet, promtail is off)       |
| blackbox-exporter    | native  | https probes of the main sites                               |
| postgres-exporter    | native  | immich db metrics                                            |
| switch-snmp          | native  | telegraf polls bifrost over snmp for prometheus             |
| pfsense-geoip        | native  | geolocates blocked sources from pfsense syslog into influxdb |
| huginn               | native  | my vault agents (systemd timers on minimax via openrouter)   |
| brain                | native  | the muninn brain page + bridge at `brain.oryxserver.org`     |
| ai-gateway           | native  | one openai-style endpoint on `:4000` for mimir's models and openrouter |
| amneziawg            | native  | obfuscated wireguard for remote access                       |

traefik also proxies to other hosts: `truenas` → odyn, `comfyui` → mimir, `sure` → njord,
`homeassistant` → `10.0.50.101`.

## wildcard cert

let's encrypt through cloudflare dns-01, so no port forwarding. the cert is in `/var/lib/acme/oryxserver.org/`
and renews on a systemd timer.

- **domains:** `oryxserver.org`, `*.oryxserver.org`
- **token:** `/var/lib/secrets/cloudflare-dns-token` (`CLOUDFLARE_DNS_API_TOKEN=...`)
- a new subdomain only needs a pihole record, no new cert

## adding a service

1. write a module in `hosts/heimdall/modules/system/` and import it in `default.nix`
2. add a router + service in `traefik.nix`
3. add the pihole record `<service>.oryxserver.org` → `10.0.20.17`
4. commit and push on mjolnir, pull on heimdall, rebuild

the full walkthrough is in [`deploying-services.md`](deploying-services.md).

## common commands

```bash
# pull + apply
ssh christina@10.0.20.17
git -C ~/nixos-dotfiles pull --ff-only
sudo nixos-rebuild switch --flake ~/nixos-dotfiles#heimdall

# restart one container
sudo systemctl restart podman-<container>

# logs
sudo podman logs <container>
sudo journalctl -u podman-<container> -f

# renew the cert by hand (rarely needed)
sudo systemctl start acme-order-renew-oryxserver.org.service
```

## gotchas

- **traefik dynamic config:** routers, services and middlewares go in `dynamicConfigOptions`, not
  `staticConfigOptions` (that's only for entrypoints)
- **acme `environmentFile`:** has to be on the cert itself, `defaults` doesn't reach
  `acme-order-renew-*.service`
- **odyn's web ui has a self-signed cert:** traefik needs the `insecure` servers transport for it
- **podman ports skip the firewall:** a published container port is forwarded, so `allowedTCPPorts`
  doesn't gate it. limit it with the bind address (`127.0.0.1:`) or a raw-table rule like `influxdb.nix`
- **before a switch:** check the brain bridge for running agent jobs (`curl -s 127.0.0.1:8093/bridge/jobs`)
  when the change touches `brain.nix`, a restart ends them

the history (the k8s move, nextcloud's removal, hlidskjalf, the old `thor` and `nix-oryx` hosts) is in my vault.
