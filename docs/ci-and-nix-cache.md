# ci and the nix cache

what happens after i push, and how my nix cache on mimir is built. three parts, set up 2026-10-20:

- **ci** (forgejo actions, the runner is on mimir): every push to main and every pull request builds all six hosts,
  so a broken config shows up as a red cross on forgejo before i rebuild anything.
- **the nix cache** (ncps on mimir, pool `brunnr`): every host downloads from mimir first. it keeps what the hosts
  fetch from cache.nixos.org and the other caches, plus everything ci built, so a package gets built or downloaded
  once for all my machines.
- **renovate** (on yggdrasil): opens pull requests on forgejo when a pinned container image or a flake input is behind.

## how i work, with this in place

the same as in the readme: edit and commit on mjolnir, `git push origin main`, the hosts pull by themselves, i
rebuild on the host. what's new:

1. after the push forgejo builds every host: https://git.oryxserver.org/jivsan/nixos-dotfiles/actions. the first
   build of a host takes a while, after that it's minutes.
2. once it's green, a rebuild downloads the finished system from mimir instead of building it. rebuilding before
   it's green works too, the host just builds what isn't in the cache yet.
3. rebuild like before, on the host:

   ```sh
   ssh christina@10.0.20.17
   cd /tmp && sudo nixos-rebuild switch --flake ~/nixos-dotfiles#heimdall
   ```

   or from mjolnir with `deploy`.

### deploy (from mjolnir)

`deploy` does those same steps for me: on each host it starts the host's own pull (`dotfiles-pull.service`), checks
the host now has the commit mjolnir has, and runs `nixos-rebuild` there. the hosts still build or download for
themselves, mjolnir only gives the command. the script is `scripts/deploy`, installed on mjolnir as `deploy` by
`hosts/mjolnir/modules/system/deploy.nix` (before mjolnir has that rebuild: `~/nixos-dotfiles/scripts/deploy`).

```sh
deploy                     # every host except mjolnir, one after the other: mimir heimdall yggdrasil tyr njord
deploy heimdall mimir      # only these
deploy --dry heimdall      # build and list what would restart, change nothing
deploy --boot mimir        # use it from the next boot (a new nvidia driver)
deploy mjolnir             # mjolnir itself (asks for my sudo password)
```

a host that doesn't have mjolnir's commit yet (i forgot to push) is skipped with a message, the others carry on, and
at the end it lists which went fine and which failed.

before a heimdall switch that changes the brain bridge, check it has no running jobs: the switch restarts it.
`deploy --dry heimdall` shows what would restart.

## renovate's pull requests

- runs every 3 hours at :20 on yggdrasil (`renovate.service`). rules: `.forgejo/renovate.json`, service:
  `hosts/yggdrasil/modules/system/renovate.nix`.
- watches the `image:tag@sha256:…` pins in the `.nix` files (new versions and new digests, digests grouped weekly)
  and the flake inputs (`flake.lock`, mondays before 7). major versions of postgres, redis and influx, and the
  python image, are off: those i do by hand.
- it never merges and can't push to main (branch protection: only `jivsan` may). the forgejo user is `renovate`,
  a collaborator with write access on this repo only. it keeps one "dependency dashboard" issue with everything it
  sees.
- ci builds every pull request too, so green means all six hosts still build with it.

merging one:

1. read it on forgejo (the description links the release notes), wait for the green check, merge.
2. on mjolnir: `git pull` (mjolnir pulls from forgejo) and `git push origin main` (so github, and with it the
   hosts, get it).
3. rebuild the hosts it touches.

renovate's commits show up as `renovate` in the history.

## how the cache server is built (mimir)

### disks and pool

two 1.2 tb hgst sas disks (`HUC101212CSS600`, the old thor vm drives) as a zfs stripe called `brunnr`. no
redundancy on purpose: it's only a cache. if a disk dies i lose the cache, not data, and nix downloads from
cache.nixos.org again.

```sh
# the disks by id, never sda/sdb (those names change between boots)
A=/dev/disk/by-id/wwn-0x5000cca01dbf841c
B=/dev/disk/by-id/wwn-0x5000cca01d54b810
sudo zpool create -o ashift=12 -O atime=off -O xattr=sa -O compression=lz4 -O mountpoint=none -O canmount=off brunnr $A $B
sudo zfs create -o mountpoint=legacy -o recordsize=1M -o primarycache=metadata -o quota=1800G brunnr/nixcache
sudo zfs create -o mountpoint=legacy -o recordsize=16K brunnr/nixcache-db
sudo zpool export brunnr     # from here on nixos imports and mounts it (fileSystems in nix-cache-server.nix)
```

- `recordsize=1M`: the cache is big compressed files that are read whole.
- `primarycache=metadata`: zfs keeps only the index in ram, not the files.
- `recordsize=16K`: the small pages of ncps's sqlite database.

`hosts/mimir/modules/system/storage.nix` turns zfs on for mimir, pins `networking.hostId` (zfs won't import a pool
on a host with another id) and caps zfs's ram cache (arc) at 1 gib with `zfs_arc_max`, so the rest of the ram stays
free for octane when a scene doesn't fit in vram. scrub monthly.

### signing key

the cache signs what it serves with its own key, and every host trusts that key.

```sh
sudo mkdir -p /var/lib/secrets && sudo chmod 700 /var/lib/secrets
nix key generate-secret --key-name mimir-nixcache-1 | sudo install -m 0600 /dev/stdin /var/lib/secrets/nixcache-signing-key
sudo sh -c 'nix key convert-secret-to-public < /var/lib/secrets/nixcache-signing-key'
```

the public half (`mimir-nixcache-1:7VO4…`) goes into `modules/system/nix-cache.nix`. the secret stays on mimir,
never in git.

### the server

`hosts/mimir/modules/system/nix-cache-server.nix`:

- **ncps** (`services.ncps`) on `127.0.0.1:8501` only. what it doesn't have it asks cache.nixos.org,
  cache.numtide.com and hyprland.cachix.org for, keeps a copy on brunnr and signs it.
- size limit 1600G: at 04:00 it drops the least recently used paths above that. the dataset quota (1.8 T) is the
  hard stop.
- it takes uploads (PUT), but only on localhost: that's how ci fills it.
- **nginx** on `10.0.20.18:5000` in front: only GET and HEAD go through, so nobody on the lan can put anything in it.
- **firewall**: port 5000 only from mjolnir, heimdall, tyr, njord and yggdrasil. nginx listens on the lan address
  alone, so tailscale (which skips nixos-fw) can't reach it.
- what mimir builds itself is signed with the same key (`nix.settings.secret-key-files`).

### the hosts

`modules/system/nix-cache.nix` (imported by `modules/system/nix.nix`, and by mjolnir directly): mimir as the first
substituter (`priority=10`, cache.nixos.org is 40), its public key, `connect-timeout = 5` and `fallback = true`.
if mimir is off a rebuild waits 5 seconds, then goes to cache.nixos.org as before.

## the runner (mimir)

`hosts/mimir/modules/system/forgejo-runner.nix`: `forgejo-runner` as `gitea-runner-mimir.service`, label
`nixos:host`, so jobs run as a plain user straight on mimir (no container) with nix. one job at a time, 6 h limit.
the nix daemon builds at idle cpu and io priority, 4 jobs × 8 cores at most, so comfyui, the llm and octane come first.

the workflow, `.forgejo/workflows/build.yml`: check out the commit, `nix build` the host's system, `nix copy` it to
ncps on localhost.

it is registered for this repo only, so other repos can't run jobs on mimir. to register it again with a new token:

```sh
# on yggdrasil
sudo -u forgejo env FORGEJO_WORK_DIR=/var/lib/forgejo FORGEJO_CUSTOM=/mnt/appdata/forgejo/custom \
  forgejo actions generate-runner-token --scope jivsan/nixos-dotfiles
# on mimir: put TOKEN=<that token> in /var/lib/secrets/forgejo-runner-token (root 0600), then
sudo systemctl restart gitea-runner-mimir     # a changed token makes it register again
```

## checks

```sh
curl http://10.0.20.18:5000/nix-cache-info                         # from any of my hosts
curl http://10.0.20.18:5000/pubkey                                  # must be mimir-nixcache-1:7VO4…
nix path-info --store http://10.0.20.18:5000 /run/current-system    # is this host's system in the cache?
systemctl status ncps nginx gitea-runner-mimir                      # on mimir
zpool status brunnr; zfs list -o name,used,avail brunnr/nixcache    # on mimir
journalctl -u renovate -n 50                                        # on yggdrasil; run it now: sudo systemctl start renovate
```

prometheus on heimdall scrapes ncps (job `nixcache`) and probes `/nix-cache-info`, so `SiteDown` reaches my phone
when the cache stops answering.

## when something is wrong

- **mimir is off or the cache is down**: nothing breaks. rebuilds wait 5 s and download from cache.nixos.org, and ci
  waits until mimir is back.
- **ncps won't start after a first deploy or a new pool** ("unable to open database file"): the folders got their
  owner before the datasets were mounted. `sudo systemd-tmpfiles --create && sudo systemctl restart ncps`.
- **a disk in brunnr dies**: the pool is gone, nothing else. `sudo zpool destroy brunnr` if it's still listed, make
  it again as above with the disks left, then `sudo systemctl restart ncps`.
- **a new signing key** (the old one leaked or got lost): make a key with a new name (`mimir-nixcache-2`), add its
  public half to `modules/system/nix-cache.nix` next to the old one and deploy every host. then swap the secret on
  mimir, stop ncps, delete everything under `/srv/nixcache` and `/srv/nixcache-db`, start ncps, remove the old
  public key and deploy again.

## mimir changes that came with this

- zfs back on, pool `brunnr` (above), arc capped at 1 gib.
- mimir and mjolnir share one nvidia module, `modules/system/nvidia-driver.nix`: the 595 driver from the stable
  branch on the open kernel module, built with the 26.05 `patchelf`. the `patchelf` in nixpkgs-unstable (0.19)
  rewrites nvidia's tools so that `nvidia-smi` crashes on start (segfault in `ld-linux`); cuda itself kept working.
- after mimir reboots, the octane render node needs my otoy sign-in once (`docs/misc/octane.md`).

## retiring github

where github is still used for this repo and what replaces it:

| what | today | on forgejo |
|---|---|---|
| mjolnir pushes | `git push origin main` → github + forgejo (two push urls) | drop github's push url (last step) |
| mjolnir pulls | forgejo, since 2026-10-20 | done |
| the hosts pull (`dotfiles-pull`, every 2 min) | https://github.com/jivsan/nixos-dotfiles, public, no login | forgejo wants a login to read anything (`REQUIRE_SIGNIN_VIEW`), so each host gets its own read-only deploy key |
| ci, renovate, `deploy` | forgejo | done |
| flake inputs (nixpkgs, home-manager …) | github, other people's repos | stay |

per host, once:

1. on the host: `ssh-keygen -t ed25519 -N "" -C "dotfiles-pull@$(hostname)" -f ~/.ssh/dotfiles-pull`
2. on forgejo: repo → settings → deploy keys → add `~/.ssh/dotfiles-pull.pub`, read only (leave write unticked).
3. in the repo, `modules/system/dotfiles-pull.nix` gets forgejo's ssh host key (`programs.ssh.knownHosts` for
   `[git.oryxserver.org]:2222`, since the pull can't answer a host key prompt) and a `Host git.oryxserver.org` block
   with `Port 2222`, `User git` and `IdentityFile ~/.ssh/dotfiles-pull`. deploy it.
4. on the host: `git -C ~/nixos-dotfiles remote set-url origin ssh://git@git.oryxserver.org:2222/jivsan/nixos-dotfiles.git`
   and `sudo systemctl start dotfiles-pull`, which must succeed.

when every host pulls from forgejo: on mjolnir
`git remote set-url --delete --push origin git@github.com:jivsan/nixos-dotfiles.git`, then archive the github repo
(settings → archive), like Hlidskjalf.

one thing changes with it: the hosts reach forgejo through traefik on heimdall, so while heimdall is down they can't
pull (github never depended on heimdall). rebuilding from mjolnir's own copy still works then:
`nixos-rebuild switch --flake .#<host> --target-host christina@<ip> --sudo`.
