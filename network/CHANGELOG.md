# bifrost (Arista core) — change log

Manual EOS changes to the running config, newest first. `bifrost-arista-core.cfg`
is kept in sync with the switch; this log records **what changed and why**.

---

## 2026-10-18 — yggdrasil on Et12; admin key now mjolnir's; config file synced

**Why:** yggdrasil (Lenovo ThinkCentre M93p) is the new always-on box outside hella that
runs hermes, on `10.0.20.21`. It needs one untagged VLAN 20 port and nothing else.

**Et12** was unused (default VLAN 1, no config). Now access VLAN 20 with portfast, so the
NixOS installer got DHCP at once. Link is 1G (onboard Intel I217-LM).

**Switch login:** Nexterm was removed from the fleet the same day; its key on `admin` was
replaced with mjolnir's (`username admin ssh-key ...`, then `write memory`), so changes
can be made from mjolnir with key login.

**Config file synced** with the running config, which had drifted from this repo:
Port-Channel2 is gone (odyn now uses Et4 alone as a trunk, native 20 + 30 tagged), Et5
(odyn's second port, 1G only) is shut down, and Et10 / Et11 are the hella and odyn
management ports (access VLAN 20). Dates of those older changes are not known.

### Commands applied (EOS)
```
enable
configure
interface Ethernet12
   description yggdrasil
   switchport mode access
   switchport access vlan 20
   spanning-tree portfast
   no shutdown
end
write memory
```

---

## 2026-07-01 — mimir on a single NIC: Et6 access VLAN 20 (unbundle Po3)

**Why:** mimir (the new NixOS AI box) shipped with a single onboard 10GbE NIC —
no dual-port NIC — so the pre-planned `Port-Channel3` LACP bond (Et6+Et7, trunk
20+30) can't form. Switched mimir to a plain **access** port instead, matching its
NixOS config (untagged, static `10.0.20.18`) and the mjolnir/Et8 convention.

**VLAN 30 impact (intentional):** mimir drops off the storage VLAN. Not needed —
TrueNAS (`odyn`) is on VLAN 20 at `10.0.20.6` (the same address heimdall uses for
NFS), so mimir gets full-10G **L2** access to storage on VLAN 20, no pfSense hairpin.

**Ports:** `Et6` = mimir. `Et7` = parked spare (shutdown) for a future 2nd NIC →
rebuild Po3.

### Commands applied (EOS)
```
enable
configure
!
interface Ethernet6
   no channel-group
interface Ethernet7
   no channel-group
!
no interface Port-Channel3
!
interface Ethernet6
   description mimir-nixos
   switchport mode access
   switchport access vlan 20
   spanning-tree portfast
   no shutdown
!
interface Ethernet7
   description spare (was mimir Po3; free for a future 2nd NIC)
   shutdown
!
end
write memory
```

### Before
```
interface Port-Channel3
   description mimir-nixos
   switchport mode trunk
   switchport trunk native vlan 20
   switchport trunk allowed vlan 20,30
   spanning-tree portfast
interface Ethernet6
   description mimir-p1
   channel-group 3 mode active
interface Ethernet7
   description mimir-p2
   channel-group 3 mode active
```

### After
```
interface Ethernet6
   description mimir-nixos
   switchport mode access
   switchport access vlan 20
   spanning-tree portfast
interface Ethernet7
   description spare (was mimir Po3; free for a future 2nd NIC)
   shutdown
!  (Port-Channel3 removed)
```

### Verify
```
show port-channel summary            ! Po3 should be gone
show interfaces Ethernet6 switchport ! Enabled, mode Access, Access VLAN 20
show interfaces status | in Et6|Et7  ! Et6 up when mimir is plugged in; Et7 disabled
```

### Revert (only if a dual-NIC upgrade happens later)
Recreate `Port-Channel3` as a 20+30 trunk, put Et6+Et7 back with
`channel-group 3 mode active`, and bond both NICs on mimir with 802.3ad.
