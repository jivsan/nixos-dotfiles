# odyn — Single 10G Link Runbook (drop the bad-port bond)

**Situation (diagnosed live):** odyn's dual-port 10G NIC has **one bad port**.
- `ens4f0` → **10G** (good) — currently in switch **Et4**
- `ens4f1` → **1G only** (defective; won't negotiate above 1000 Mb/s in any switch port —
  proven by swapping cables NIC-side and watching the 1G follow the NIC, not the switch port)

A 10G+1G LACP bond is worse than useless here: with LAYER2+3 hashing, each connection rides
**one** member, so flows randomly land on the 1G link and bottleneck. **A single guaranteed-10G
link beats a mixed-speed bond** — you lose only redundancy, not speed (a single stream caps at
10G regardless of bonding). So we tear down the bond and run `ens4f0` alone at 10G.

> **Warranty:** flag the NIC — `ens4f1` being stuck at 1G is a hardware defect. RMA if in window.

Management lifeline stays untouched throughout: onboard **`enp9s0` = `10.0.20.102`** (DHCP) on a
separate switch port. You will not lose the TrueNAS UI during any of this.

---

## Part A — Switch (bifrost), tear down Po2, make Et4 a standalone trunk

`ens4f0` (good 10G) is in **Et4**; `ens4f1` (bad) is in **Et5**. Keep Et4, shut Et5, delete Po2.

Console/SSH to bifrost (`ssh admin@10.0.20.2`), then:

```
enable
configure

! --- remove Et4 from the port-channel and make it a clean standalone trunk ---
interface Ethernet4
   no channel-group 2 mode active
   description odyn
   switchport
   switchport mode trunk
   switchport trunk native vlan 20
   switchport trunk allowed vlan 20,30
   spanning-tree portfast
   no shutdown

! --- remove Et5 from the port-channel and disable the bad-port link ---
interface Ethernet5
   no channel-group 2 mode active
   description odyn-ens4f1-BAD-1G-ONLY-DO-NOT-USE
   shutdown

! --- delete the now-empty port-channel ---
no interface Port-Channel2

end
copy running-config startup-config
```

**Verify on the switch:**
```
show interfaces status | include Et4|Et5
```
Expected:
- `Et4   odyn   connected   trunk ...   a-full a-10G   10GBASE-T`  (standalone, **not** "in Po2")
- `Et5   odyn-ens4f1-BAD...   disabled` (shut)

```
show port-channel dense
```
Po2 should be **gone**. (If EOS rejects `no channel-group 2 mode active`, just use
`no channel-group 2` inside each interface, then re-add the trunk lines.)

---

## Part B — TrueNAS (odyn), delete the LAGG, put the IPs on `ens4f0`

You're in the UI via `enp9s0` (`10.0.20.102`). **Network → Interfaces.**

### B.1 Delete the bond
1. Find **`bond1`** (the LAGG) → ⋮ → **Delete**.
2. Confirm. This frees `ens4f0` and `ens4f1` and removes the `10.0.20.6` that was on the bond.
   (Don't "Test"/commit yet — do all edits, then one commit.)

### B.2 Give `ens4f0` the data IP (VLAN 20, native/untagged on the trunk)
1. **Network → Interfaces → Add** (or edit `ens4f0` if it appears).
   - **Type:** Network Interface (physical) — i.e. configure `ens4f0` directly.
   - **Interface:** `ens4f0`
   - **DHCP:** off → **Define Static IP Addresses**
   - **Add** → `10.0.20.6/24`
   - Leave gateway blank here (the global default gateway handles it — see B.4).
   - MTU: 1500 (leave default).

### B.3 Add the VLAN 30 storage interface on top of `ens4f0`
1. **Network → Interfaces → Add**
   - **Type:** **VLAN**
   - **Parent Interface:** `ens4f0`
   - **VLAN Tag:** **30**
   - **Name:** `vlan30` (or accept default)
   - **DHCP:** off → **Define Static IP Addresses** → `10.0.30.6/24`
   - **No gateway** (VLAN 30 is L2-only, never routed).

### B.4 Confirm global network settings (Network → Global Configuration / Settings)
- **IPv4 Default Gateway:** `10.0.20.1`
- **Nameserver 1:** `10.0.20.4` (Pi-hole) — so odyn resolves internal names.
- Hostname: `truenas`/`odyn` (cosmetic — fine as-is).

### B.5 Commit
Click **Test Changes** → **Apply**. TrueNAS starts a ~60s connectivity test with auto-revert.
Because your management is on `enp9s0` (separate from `ens4f0`), you stay connected → when it
asks, **Keep / Save** the changes.

**Verify on odyn (Shell or SSH):**
```
ip -br addr show ens4f0          # 10.0.20.6/24, link UP
ip -br addr show ens4f0.30       # (or vlan30) 10.0.30.6/24
ethtool ens4f0 | grep -i speed   # Speed: 10000Mb/s   (run with sudo if "Operation not permitted")
ip route                         # default via 10.0.20.1
```

---

## Part C — Verify end-to-end 10G

From **mjolnir** (which is on Et8 at 10G):
```bash
# server on odyn (TrueNAS Shell):
iperf3 -s
# client on mjolnir:
nix-shell -p iperf3 --run "iperf3 -c 10.0.20.6"
nix-shell -p iperf3 --run "iperf3 -c 10.0.20.6 -R"   # reverse direction too
```
Expect **~9.4 Gbit/s** single-stream. (No bond now → no hash roulette → every flow gets 10G.)

- If you see ~7–8 Gbit, it's usually a single-core CPU limit on one end — confirm with
  `iperf3 -c 10.0.20.6 -P 4` (parallel); it should climb toward line rate.
- If `iperf3` isn't installed on TrueNAS, flip it: run `iperf3 -s` on **mjolnir** and
  `iperf3 -c 10.0.20.100` from odyn's shell — or just validate with a large NFS read once
  exports are fixed (Part D). iperf3 isolates the **link**; real file speed also depends on the
  ZFS pool feeding the wire.

If a single-stream test shows ~940 Mbit, the 10G port isn't actually up — re-check
`show interfaces status` (Et4 must read `a-10G`) and `ethtool ens4f0`.

---

## Part D — Fix the NFS exports (REQUIRED for mjolnir + heimdall to mount)

The exports were scoped to the **old** `10.0.0.0/24` and have stale old hosts, so new-subnet
clients get `mount.nfs: access denied by server`. **Shares → Unix (NFS) Shares**, edit each:

| Path | Change |
|---|---|
| `/mnt/vault/backups-workstation` | Networks `10.0.0.0/24` → **`10.0.20.0/24`** |
| `/mnt/vault/media` | Networks → **`10.0.20.0/24`**; Host `10.0.0.17` → `10.0.20.17` or clear |
| `/mnt/vault/nextcloud` | Networks → **`10.0.20.0/24`** |
| `/mnt/vault/nix-services` | Networks → **`10.0.20.0/24`** (this is heimdall's data share) |
| `/mnt/vault/proxmox-backup-server` | Host `10.0.0.5` → PBS's new IP, or clear |
| `/mnt/vault/nfs-pvc-kubernetes` | leftover (Talos, decommissioned) — fix or delete later |
| `/mnt/vault/nix-oryx` | leftover (nix-oryx VM gone) — fix or delete later |

**Simplest reliable approach:** set **Networks = `10.0.20.0/24`** on the shares you actually use
(`media`, `backups-workstation`, `nextcloud`, `nix-services`) and **clear** the specific stale
`10.0.0.x` Host entries. VLAN 20 is your trusted subnet, so allowing the whole `/24` is fine.
Optionally also add `10.0.30.0/24` to Networks if you ever mount over the storage VLAN.

NFS re-reads exports immediately (no reboot). Re-test from mjolnir:
```bash
ls /mnt/nas-media
ls /mnt/nas-backups-workstation
# or just re-run: sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mjolnir
```
Mounts should succeed once the export allows `10.0.20.x`.

---

## Done when…
- [ ] Switch: Et4 standalone trunk at **a-10G**, Et5 shut, Po2 deleted, config saved.
- [ ] odyn: `ens4f0` = `10.0.20.6/24` @ 10000 Mb/s, `ens4f0.30` = `10.0.30.6/24`.
- [ ] iperf3 mjolnir↔odyn ≈ **9.4 Gbit/s**.
- [ ] NFS exports allow `10.0.20.0/24`; mjolnir mounts succeed.
- [ ] Card flagged for warranty (`ens4f1` defective).

Once this is green, odyn is finished and heimdall's NFS path is clear — proceed to
`HEIMDALL-BUILD.md`.
