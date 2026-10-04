# OctaneRender — workstation (mjolnir) + render node (mimir)

Config: `modules/apps/octane.nix` (mjolnir), `modules/apps/octane-node.nix` (mimir),
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

mimir's driver is already the open 595 module (Blackwell needs ≥ R572). Deploy
`#mimir`, then:

```sh
scp ~/octane-src/OctaneRender_Studio+_2026_4_node_linux.zip christina@10.0.20.18:
ssh christina@10.0.20.18
sudo octane-node-install ~/OctaneRender_Studio+_2026_4_node_linux.zip
# optional, the OTOY way to pick port/GPUs (writes run_octane_daemon.sh):
cd /opt/octane/node && octane-node-env ./install-daemon.sh        # port 48000
sudo systemctl start octane-node && journalctl -fu octane-node
```

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
48000 are open on mjolnir (`modules/system/networking.nix`); 48000 is open on mimir.

Stop/update the node: `sudo systemctl stop octane-node` (SIGTERM, waits) —
`octane-node-install` does this itself.

## Unverified (needs the real packages, which need the OTOY login)

- Exact file names inside the Linux node zip. The service runs
  `run_octane_daemon.sh` if `install-daemon.sh` was used, else `octane_daemon
  --daemon-port 48000`. If the daemon binary is named differently, fix
  `daemon-start` in `octane-node.nix`.
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
