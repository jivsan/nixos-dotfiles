# bifrost (Arista core) — change log

Manual EOS changes to the running config, newest first. `bifrost-arista-core.cfg`
is kept in sync with the switch; this log records **what changed and why**.

---

## 2026-11-04 — Et13 for garm (access VLAN 20)

**Why:** garm, the first helheim Proxmox node, gets its first 10G port (LAN3) on Et13, so the
Proxmox installer can reach the network at 10.0.20.11. Et13 becomes a trunk (VLANs 20 and 50
tagged, native off 20) once garm's `vmbr1` is set up.

**Changed:** Et13 description `garm`, access VLAN 20, portfast, the same as Et12 (yggdrasil).
Applied in session `garm-et13` with a 5-minute commit timer. A second login showed the new Et13
config with the session pending; then confirmed and `write memory`. Et13 was `notconnect` at
the time (garm not cabled yet).

## 2026-11-02 — VLAN 10 (mgmt) for the BMCs on Et30-32

**Why:** the Supermicro X10 boards (garm, fenrir and the X10SDV router) get their BMCs (IPMI)
on their own VLAN with no internet. Only the firewall routes VLAN 10, and it lets only mjolnir
reach a BMC, on 443 and 5900. 623 (IPMI) is blocked for everyone: the X10 BMC firmware 4.07
has 623 flaws that won't be fixed.

**Changed:** `vlan 10` named `mgmt`. Et30 `garm-ipmi`, Et31 `fenrir-ipmi`, Et32 `router-ipmi`
= access VLAN 10 + portfast. Et1 (the pfSense trunk) now also allows VLAN 10. Applied in a
config session with a 5-minute commit timer. Checked before the commit: from a second login
Et1 showed `Trunking VLANs Enabled: 10,20,40,50` and Et30-32 `static access, VLAN 10 (mgmt)`;
from mjolnir 1.1.1.1, Home Assistant (10.0.50.101), odyn (10.0.20.6) and pfSense (10.0.20.1)
still answered. Then confirmed and `write memory`. A Supermicro BMC (MAC `0c:c4:7a:c8:72:9b`,
garm's) showed up on Et32 right after, so garm's BMC is on Et32 for now (the labels may get
swapped later).

**Never:** an `interface Vlan10` on bifrost. `ip routing` is on, so it would route around the
firewall.

**Config file synced:** `bifrost-arista-core.cfg` now also has `vlan 40` (dmz) and the real
allowed lists on Et1 (10,20,40,50) and Port-Channel1 (20,40,50), which it was missing. The date
of the VLAN 40 change is not known.

### Commands applied (EOS)
```
enable
configure session mgmt-vlan10
vlan 10
   name mgmt
interface Ethernet1
   switchport trunk allowed vlan add 10
interface Ethernet30
   description garm-ipmi
   switchport mode access
   switchport access vlan 10
   spanning-tree portfast
interface Ethernet31
   description fenrir-ipmi
   switchport mode access
   switchport access vlan 10
   spanning-tree portfast
interface Ethernet32
   description router-ipmi
   switchport mode access
   switchport access vlan 10
   spanning-tree portfast
commit timer 00:05:00
configure session mgmt-vlan10 commit
write memory
```

---

## 2026-10-29 — Et19 for the elitebook (OctoPrint)

**Why:** the old HP EliteBook 8540p now runs OctoPrint next to the Ender-3 V3 SE, by the rack.
Et13 and up were unconfigured (default VLAN 1, no DHCP there).

**Changed:** Et19 = access VLAN 20 + portfast, description `elitebook-octoprint`. Applied in a
config session with a 5-minute commit timer, checked (link up at 1G, the laptop's MAC learned
on VLAN 20, admin login still fine), then confirmed and `write memory`.

### Commands applied (EOS)
```
enable
configure session elitebook-et19
interface Ethernet19
   description elitebook-octoprint
   switchport mode access
   switchport access vlan 20
   spanning-tree portfast
commit timer 00:05:00
configure session elitebook-et19 commit
write memory
```

---

## 2026-10-19 — SSH locked down: key-only, from mjolnir + yggdrasil only

**Why:** the fleet security audit (2026-10-19) flagged bifrost's OpenSSH 7.8 banner as
"known CVEs". Checked: the serious server-side OpenSSH flaws don't apply to 7.8
(CVE-2018-15473 was fixed in 7.8; regreSSHion CVE-2024-6387 affects 8.5–9.7 only; Terrapin
CVE-2023-48795 needs ChaCha20-Poly1305 or CBC, which the switch doesn't offer). The real
issues: the switch is end of life (EOS 4.28 is the last train for the 7050X series, bug
fixes ended 2025-03-20), so nothing new will be patched; and SSH accepted the admin
password (keyboard-interactive) from any address. So the management side is narrowed.

**Changed:** SSH only from mjolnir (10.0.20.100) and yggdrasil (10.0.20.21), via a standard
ACL on the SSH service; public-key login only (the password still works on the serial
console); `diffie-hellman-group14-sha1` and `hmac-sha1` removed. Applied in a config
session with a 5-minute commit timer, tested (mjolnir key login works, yggdrasil is offered
`publickey` only, mimir times out), then confirmed and `write memory`.

**Unchanged:** SNMP stays v2c read-only, limited to heimdall by `SNMP-RO` (now listed in
`bifrost-arista-core.cfg`, community left out).

**Recovery:** if mjolnir's key is lost or both hosts are down, use the serial console
(admin password), then add a host to `SSH-MGMT`.

### Commands applied (EOS)
```
enable
configure session harden-ssh
ip access-list standard SSH-MGMT
   10 permit host 10.0.20.100
   20 permit host 10.0.20.21
management ssh
   ip access-group SSH-MGMT in
   authentication protocol public-key
   key-exchange curve25519-sha256@libssh.org ecdh-sha2-nistp521 ecdh-sha2-nistp384 ecdh-sha2-nistp256
   mac hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com hmac-sha2-512 hmac-sha2-256
   exit
commit timer 00:05:00
! tested from a new session, then:
configure session harden-ssh commit
write memory
```

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
