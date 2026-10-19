# OctaneRender — workstation (mjolnir) + render node (mimir)

Config: `hosts/mjolnir/modules/apps/octane.nix` (mjolnir), `hosts/mimir/modules/system/octane-node.nix` (mimir),
shared libs in `modules/apps/octane-libs.nix`, Blender in `modules/apps/blender.nix`.

## How it fits together (since OctaneBlender 31.x)

| Piece | Where | What |
|---|---|---|
| Blender 5.2.2 (vanilla, blender.org) | mjolnir, `blender` | the editor; the Octane addon lives in its user config |
| OctaneRender Blender addon 31.10 | `/opt/octane/addon/<name>` → symlink in `~/.config/blender/5.2/scripts/addons/` | the plugin; talks to OctaneServer |
| OctaneServer 31.10 (Octane 2026.4, Studio+) | mjolnir, `octane-server` (FHS env over `/opt/octane/server`) | holds the OTOY sign-in, renders, drives network rendering |
| Render node 2026.4 | mimir, `octane-node.service` (FHS env over `/opt/octane/node`) | daemon + `octane_node`; mjolnir's server uses mimir's GPU |

There is no "Blender Octane Edition" binary any more. The installer zips are kept
in `~/octane-src` (backed up to the NAS by `backup-nixos`).

**Versions must match**: node version == OctaneServer version, or the primary
ignores the node. Addon 31.10 ⇒ Octane **2026.4** ⇒ node zip `..._2026_4_node_linux.zip`.
(2026.5 exists for Standalone/Node but there is no 31.x server for it yet.)

Downloads (OTOY login): addon + server from the
[31.10 release thread](https://render.otoy.com/forum/viewtopic.php?t=85781),
node + standalone from the
[2026.4 thread](https://render.otoy.com/forum/viewtopic.php?t=85726).
Blender 5.2.2 is fetched by Nix.

## License rules (why the helpers exist)

- Octane binds the license to the machine at sign-in and **only releases it on
  sign-out or a clean exit**. `SIGTERM` triggers "Caught signal, please wait for
  license logout"; `SIGKILL` / power-off does not, and then OTOY support has to
  free it (or the limited web "Unlock" counter is spent).
- So: `octane-stop` (SIGTERM + wait), never `pkill -9`. The shutdown unit
  `octane-license-release` does the same at reboot. mimir's `octane-node.service`
  stops with SIGTERM and a 40 s timeout.
- **Before upgrading** OctaneServer: start the *old* one, Account ▸ Sign Out
  (releases every license on the machine), then `octane-stop`, then install.
- One Studio+ workstation sign-in at a time. The render node takes one of the
  10 render-node licenses included in Studio+, not the workstation one.

## Upgrade procedure on mjolnir

```sh
# 0. deploy (brings Blender 5.2.2 + the helpers)
sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mjolnir

# 1. release the current license cleanly
octane-server        # old server: Account > Sign Out, close it
octane-stop

# 2. bring the old Blender Octane Edition config (addons, startup scene, layout) to 5.2
blender-migrate-config              # copies ~/.config/blender/4.5 -> 5.2 (25 GB)
#   --from 5.1 instead if the vanilla-Blender config is the one you want

# 3. install server + addon
sudo octane-install ~/octane-src/OctaneStudio_for_BlenderOctaneAddon_Linux_31.10-stable.zip \
                    ~/octane-src/octane_blender_addon-31.10-stable.zip

# 4. first run
octane-server &      # sign in with the OTOY account
blender              # dismiss "load 5.1 settings" (config is already migrated);
                     # Preferences > Add-ons: enable OctaneRender if not already on
```

Blender 4.5 shipped Python 3.11, 5.2 ships 3.13: pure-Python addons carry over,
addons with compiled modules (e.g. the AI ones) need a fresh download for 5.2.

## Render node on mimir (after the RTX 5070 Ti is in)

Driver: the RTX 5070 Ti needs the open 595 module (Blackwell needs ≥ R572). Since
2026-10-13 mimir runs the 580 legacy driver for the GTX 1070 that is still in it
(see below). Deploy `#mimir`, then:

```sh
scp ~/octane-src/OctaneRender_Studio+_2026_4_node_linux.zip christina@10.0.20.18:
ssh christina@10.0.20.18
sudo octane-node-install ~/OctaneRender_Studio+_2026_4_node_linux.zip
# optional, the OTOY way to pick port/GPUs (writes run_octane_daemon.sh):
cd /opt/octane/node && octane-node-env ./install-daemon.sh        # port 48000
octane-node-start          # or ~/start-render-node
```

The node does not start at boot. `octane-node-start` checks the card, starts the
service and shows the node's first log lines; `octane-node-stop` (or
`~/stop-render-node`) stops it and waits for the license logout.

Without `install-daemon.sh` the service starts the daemon itself, the way that
script would: `octane_node_daemon --port 48000 --slave /opt/octane/node/octane_node
--alias mimir --out-of-core 16g`. The out-of-core amount (`outOfCoreGb` in
`octane-node.nix`) matters: a node has to hold the whole scene on its own card,
and OTOY's default for a node is out-of-core off.

The GPU in the node needs a driver that knows it. The repo has the open 595
module for the RTX 5070 Ti; a GTX 1070 (Pascal) has no driver under it and needs
`open = false` + `nvidiaPackages.legacy_580` in `hosts/mimir/modules/system/nvidia.nix`.

The service runs as `christina` so the node finds the OTOY sign-in in
`~/.OctaneRender`. If the node asks for a sign-in and the journal shows no way
to do it headless, sign in once with the Standalone over X forwarding:

```sh
# on mjolnir
ssh -X christina@10.0.20.18
sudo octane-node-install ~/OctaneRender_Studio+_2026_4_linux.zip   # -> /opt/octane/standalone
octane-standalone --no-opengl         # sign in, File > Quit (clean exit keeps the session)
```

Then on mjolnir, OctaneServer ▸ Network preferences: enable network rendering,
daemon port 48000, add `10.0.20.18` to the daemon list. The master port 1047 and
48000 are open on mjolnir (`hosts/mjolnir/modules/system/networking.nix`); 48000 is open on mimir.

How the two find each other (measured 2026-10-13 with tcpdump on mimir):
OctaneServer sends a UDP broadcast to `10.0.20.255:48000` every 5 s. The daemon
answers by opening a TCP connection back to mjolnir on a port OctaneServer picks
by itself (seen: 1025, 1026, 1027, a new one after each firewall reload). Then
the daemon starts `octane_node`, which connects to mjolnir on 1047 **and** 1048.
A fixed port list on mjolnir therefore does not hold: `networking.nix` lets
mimir (`10.0.20.18`) in on TCP whatever the port. Symptom without it: the node
runs, is signed in and answers, but "Active network daemons" stays empty.

First sign-in on the node: the daemon's first call of `octane_node` asks for the
OTOY username and password on its terminal. As a service it has none ("Could not
activate"), so run the daemon once in a terminal, inside the FHS env:
`octane-node-env -c 'cd /opt/octane/node && LD_LIBRARY_PATH=/opt/octane/node:/opt/octane/node/lib ./run_octane_daemon.sh'`
(`run_octane_daemon.sh` comes from `install-daemon.sh`; OTOY's programs never
run bare on NixOS). `octane_node --info gpus` does not ask for a sign-in.

Stop/update the node: `octane-node-stop` — `octane-node-install` does this
itself. Stopping sends SIGTERM to `octane_node` first and waits for its license
logout, then to the daemon. A plain signal to the service's main process would
only hit the FHS wrapper, which dies and takes Octane with it by SIGKILL.

## Unverified (needs the real packages, which need the OTOY login)

- (Checked 2026-10-13 against the 2026.4 node zip: it holds `install-daemon.sh`,
  `octane_node_daemon`, `octane_node`, `octane.dat`, `libsenseEIV.so`; the service
  uses those names. Whether the daemon then starts and is seen by mjolnir is
  still untested.)
- Whether the 31.10 addon zip is a legacy addon or an extension; `octane-install`
  handles both and links it into the right Blender directory.
- How a headless node signs in. The Standalone-over-`ssh -X` path above is the
  documented fallback ("a render node requires an activated Standalone license").

## Seen 2026-10-04: "no available licenses on your account"

Caused by launching `octane-server` again (dmenu, after a rebuild) while the
previous instance was still signed in: two sessions, one workstation seat. Not a
machine-identity change (machine-id, hostname and MACs are stable inside the
sandbox). The wrapper now refuses a second instance; stop with `octane-stop`,
then launch. If it ever happens with a single instance: "Sign out and start
again" in the dialog releases every license bound to this machine; the web
"Unlock" on the OTOY account page is the last resort and has a limited counter.
