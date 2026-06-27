# pfSense configuration — homelab VLAN router-on-a-stick

pfSense routes between your VLANs over a single trunk link to the Arista (`Et1`).
VLAN 20 is the untagged / native **trusted LAN**; VLAN 50 (IoT/Wi-Fi) is a **tagged**
subinterface. VLAN 30 (storage) is deliberately **not** here — it stays pure L2 on
the Arista with no gateway anywhere.

---

## Interfaces / NICs

Two physical ports, which you almost certainly already have:

- **WAN** — to your modem / ISP.
- **LAN** — to Arista `Et1` (carries trusted VLAN 20 untagged + VLAN 50 tagged).

You do **not** need a NIC per VLAN — that is the point of router-on-a-stick.

Speed note: only internet (WAN↔LAN) and inter-VLAN routing (20↔50, light IoT
traffic) cross pfSense. Your 10G host-to-host traffic is intra-VLAN-20 and stays on
the Arista, so a 1G pfSense LAN port is not a bottleneck for it. Use a 10G port if
you have one, but it is not required.

---

## Suggested IP plan

| Host | VLAN | IP |
|---|---|---|
| pfSense (gateway) | 20 | 10.0.20.1 |
| bifrost (Arista mgmt) | 20 | 10.0.20.2 |
| hella (Proxmox host) | 20 | 10.0.20.10 |
| odyn (TrueNAS) | 20 | 10.0.20.11 |
| mimir | 20 | 10.0.20.12 |
| nix-services VM | 20 | 10.0.20.17 |
| mjolnir | 20 | 10.0.20.20 |
| Home Assistant VM | 50 | 10.0.50.10 |
| DHCP pool (trusted) | 20 | 10.0.20.100–199 |
| DHCP pool (IoT/Wi-Fi) | 50 | 10.0.50.100–199 |

Tip: keep the last octet from your old `10.0.0.x` addresses to cut down on
remapping (e.g. nix-services `.17` → `.17`).

---

## Step 1 — Assign interfaces
**Interfaces → Assignments**
- **WAN** = the NIC on your modem.
- **LAN** = the NIC on Arista `Et1`. Leave it as the plain (untagged) interface — this
  *is* VLAN 20. Do **not** create a VLAN 20 subinterface; untagged = VLAN 20 by the
  native-VLAN setting on the switch port.

## Step 2 — Create the IoT VLAN
**Interfaces → Assignments → VLANs → Add**
- Parent interface = the LAN NIC
- VLAN tag = `50`
- Description = `IOT`

Then **Interfaces → Assignments**, add the new VLAN 50 (appears as OPT1) → rename to
**IOT** and Enable.

## Step 3 — Interface addresses
- **LAN**: IPv4 static, `10.0.20.1/24`
- **IOT**: IPv4 static, `10.0.50.1/24`
- **WAN**: DHCP (or per your ISP)

## Step 4 — DHCP
**Services → DHCP Server**
- **LAN**: enable, range `10.0.20.100–10.0.20.199`, DNS `10.0.20.1`
- **IOT**: enable, range `10.0.50.100–10.0.50.199`, DNS `10.0.50.1`

Give your servers static IPs on the host side (or DHCP reservations here). For ESP
nodes a DHCP reservation each keeps them at stable addresses, though Home Assistant's
ESPHome discovery finds them either way.

---

## Step 5 — Firewall rules (the important part)

### Alias
**Firewall → Aliases → Add** a network alias named `RFC1918` containing:
`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.

### IOT interface — **Firewall → Rules → IOT** (top to bottom, first match wins)
1. **Pass** — Source `IOT net`, Dest `IOT address`, Port `53` (TCP/UDP) — DNS to pfSense.
   - *(optional)* Pass ICMP `IOT net` → `IOT address` so devices can ping the gateway.
2. **Block** — Source `IOT net`, Dest `RFC1918` — stops IoT reaching trusted, storage,
   or any other private network.
3. **Pass** — Source `IOT net`, Dest `any` — internet only (private is already blocked above).

Order matters. Same-subnet IoT↔IoT traffic (Home Assistant talking to your ESP/Shelly
devices) is switched on VLAN 50 and never reaches pfSense, so the `RFC1918` block does
not affect it — the firewall only sees traffic that is *leaving* the subnet.

### LAN interface — **Firewall → Rules → LAN**
- Keep the default **Pass `LAN net` → any**. Trusted reaches the internet and VLAN 50,
  so opening Home Assistant at `10.0.50.10:8123` just works.
- Leave the automatic anti-lockout rule in place.

*Optional tighter posture:* if you'd rather trusted reach **only** Home Assistant on
IoT and nothing else there, replace the allow-any with:
1. Pass `LAN net` → `10.0.50.10` port `8123`
2. Block `LAN net` → `RFC1918`
3. Pass `LAN net` → `any`

Most homelabs don't bother — you usually want to manage IoT from trusted.

---

## Step 6 — DNS
- **Services → DNS Resolver**: enabled (default). It listens on LAN and IOT.
- If you want Pi-hole filtering everywhere, point the Resolver's upstream (or
  **System → General → DNS Servers** in forwarding mode) at your Pi-hole, and hand out
  only pfSense as the DNS address to clients. That keeps IoT devices from talking
  directly to Pi-hole on VLAN 20.

---

## How trusted reaches HA while IoT stays sealed

pfSense is **stateful**. When mjolnir opens `10.0.50.10:8123`, the outbound packet
matches `LAN → any` and creates a state entry; Home Assistant's replies come back on
that existing state automatically, *without ever being evaluated by the IOT rules*.
The IOT block only filters **new** connections that IoT devices try to start — so a
compromised smart plug can't reach odyn, but your browser still reaches HA. One-way
isolation, for free.

(If a Home Assistant integration ever needs to *initiate* a connection back to a
trusted host, that specific flow would be blocked — add a narrow Pass rule on the IOT
interface for just that destination/port when the need comes up.)

---

## Not here on purpose
- **VLAN 30 (storage)** has no pfSense interface and no gateway — odyn↔mimir talk
  directly at L2 on the Arista. Nothing to configure here.
- The Arista `Et1` trunk doesn't even allow VLAN 30 toward pfSense, so it can't leak.

## Test
- From **mjolnir** (VLAN 20): ping `10.0.20.1`, browse to HA at `10.0.50.10:8123`,
  reach the internet.
- From an **IoT device** (VLAN 50): reach the internet + DNS, but fail to reach
  `10.0.20.x` — that failure is the isolation working.
