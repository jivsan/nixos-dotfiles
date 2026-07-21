{ config, lib, pkgs, ... }:

# AmneziaWG tunnel for remote access from behind Russia's TSPU DPI.
#
# Plain WireGuard works here but gets fingerprinted and dropped ~60s into every
# session, on any port. AmneziaWG is WireGuard with the handshake obfuscated
# (randomised H1-H4 magic headers + Jc junk packets), so there is nothing stable
# for the DPI to match on. Same keys, same crypto, same kernel datapath.
#
# nixpkgs carries this natively: networking.wireguard with type = "amneziawg"
# pulls in kernelPackages.amneziawg + amneziawg-tools and drives `awg` instead
# of `wg`. No external flake input is needed.

let
  # Mishka's PUBLIC key. She generates the keypair inside the AmneziaWG Windows
  # client and sends the public half over. Public keys are not secrets, so this
  # belongs in the repo.
  #
  # Kept as an uncommitted local edit on mjolnir and heimdall only: this repo is
  # public, and committing the key would be a durable public link between her and
  # this infra. The committed value stays the placeholder below, so a clean clone
  # fails the assertion loudly rather than deploying a broken peer.
  mishkaPublicKey = "REPLACE_WITH_MISHKA_PUBLIC_KEY";

  # Her laptop. A second device needs its own keypair AND its own address on the
  # tunnel: WireGuard routes by allowedIPs, so two peers sharing 10.9.0.2 would
  # make return traffic ambiguous and break both devices intermittently.
  mishkaLaptopPublicKey = "REPLACE_WITH_MISHKA_LAPTOP_PUBLIC_KEY";

  # This repo has no sops-nix or agenix, so the private key and the PSK live in
  # a root-only directory outside git and are referenced by path. See the
  # "Key generation" note at the bottom of this file.
  secretsDir = "/var/lib/amneziawg";

  # Obfuscation parameters. The client MUST match on S1/S2 and H1-H4 or the
  # handshake is unreadable to the other side. Jc/Jmin/Jmax describe the junk
  # each end emits and may legitimately differ per peer.
  obfuscation = {
    Jc = 8;
    Jmin = 8;
    Jmax = 80;
    S1 = 0;
    S2 = 0;
    H1 = 1148573989;
    H2 = 1637771080;
    H3 = 957228754;
    H4 = 1401450629;
  };
in
{
  assertions = [
    {
      assertion = mishkaPublicKey != "REPLACE_WITH_MISHKA_PUBLIC_KEY";
      message = ''
        amneziawg: mishkaPublicKey is still the placeholder.
        Paste her real public key into hosts/heimdall/modules/system/amneziawg.nix.
      '';
    }
    {
      assertion = mishkaLaptopPublicKey != "REPLACE_WITH_MISHKA_LAPTOP_PUBLIC_KEY";
      message = ''
        amneziawg: mishkaLaptopPublicKey is still the placeholder.
        Paste her laptop's real public key into hosts/heimdall/modules/system/amneziawg.nix.
      '';
    }
  ];

  networking.firewall.allowedUDPPorts = [ 51820 ];

  networking.wireguard.interfaces.awg0 = {
    type = "amneziawg";
    ips = [ "10.9.0.1/24" ];
    listenPort = 51820;

    # Matches the client. The junk packets eat into the usable payload on top of
    # WireGuard's own 80 bytes, and the path out of Russia is not friendly to
    # fragmentation, so stay well under the 1420 default.
    mtu = 1280;

    privateKeyFile = "${secretsDir}/heimdall.key";
    extraOptions = obfuscation;

    peers = [
      {
        name = "mishka";
        publicKey = mishkaPublicKey;
        presharedKeyFile = "${secretsDir}/mishka.psk";
        allowedIPs = [ "10.9.0.2/32" ];
        persistentKeepalive = 25;
      }
      {
        name = "mishka-laptop";
        publicKey = mishkaLaptopPublicKey;
        presharedKeyFile = "${secretsDir}/mishka-laptop.psk";
        allowedIPs = [ "10.9.0.3/32" ];
        persistentKeepalive = 25;
      }
    ];
  };

  # Full tunnel: her traffic arrives on awg0 and has to reach both the LAN
  # (odyn/SMB at 10.0.20.6) and the internet. Masquerading behind ens18 means
  # odyn sees plain 10.0.20.17 and needs no route back into 10.9.0.0/24.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.nat = {
    enable = true;
    externalInterface = "ens18"; # heimdall's LAN NIC, verified via `ip -brief addr`
    internalInterfaces = [ "awg0" ];
  };

  # Deliberately NOT setting networking.firewall.trustedInterfaces = [ "awg0" ]:
  # routing to odyn goes through the FORWARD path and does not need it, and
  # trusting the interface would expose every port heimdall itself listens on.

  # Key generation — run once on heimdall, as root:
  #
  #   mkdir -p /var/lib/amneziawg && chmod 700 /var/lib/amneziawg
  #   cd /var/lib/amneziawg
  #   awg genkey | tee heimdall.key | awg pubkey > heimdall.pub
  #   awg genpsk > mishka.psk
  #   chmod 600 heimdall.key mishka.psk
  #
  # heimdall.pub and mishka.psk both go into Mishka's client config.
}
