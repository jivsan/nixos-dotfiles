{ config, lib, pkgs, ... }:

# amneziawg vpn for mishka, from behind russia's dpi
# plain wireguard gets fingerprinted and dropped about 60s in, awg hides the handshake

let
  # mishka's public key, made in the amneziawg windows client
  mishkaPublicKey = "JJUSr+F2Yft1x52PlqTI4iGhIi5PpPvd1kxUjtYDnxs=";

  # mishka's laptop: each device needs its own keypair and its own tunnel ip,
  # two peers on one allowedIPs address break each other
  mishkaLaptopPublicKey = "uv9X8wXoIwWmsqn3KFNN+jODxIt8fKF8qNUSzdYnanw=";

  # root-only, outside git: heimdall.key (awg genkey) and one <peer>.psk per peer (awg genpsk);
  # heimdall.pub and the peer's psk go into that peer's client config
  secretsDir = "/var/lib/amneziawg";

  # the clients must use the same S1/S2 and H1-H4 or the handshake fails;
  # Jc/Jmin/Jmax only shape each side's junk packets and may differ
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

    # same as the clients: junk packets eat payload and the path out of russia fragments badly
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

  # full tunnel to the lan (odyn smb) and the internet, masqueraded behind ens18
  # so odyn sees 10.0.20.17 and needs no route back to 10.9.0.0/24
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.nat = {
    enable = true;
    externalInterface = "ens18";
    internalInterfaces = [ "awg0" ];
  };

  # awg0 is not a trusted interface on purpose: forwarding doesn't need it,
  # and it would open every port heimdall listens on to the peers

  # mishka only gets odyn's smb share, pihole dns and the internet. without this the
  # masquerade makes her look like heimdall to the whole lan (nfs exports, ssh, web uis,
  # ipmi) and heimdall's own open ports. raw table like influxdb.nix, so it also covers
  # podman's forwarded ports. only traffic inside the tunnel: the awg handshake on ens18 is untouched
  networking.firewall.extraCommands = ''
    iptables -t raw -N awg-mishka 2>/dev/null || iptables -t raw -F awg-mishka
    iptables -t raw -A awg-mishka -d 10.0.20.6 -p tcp --dport 445 -j RETURN
    iptables -t raw -A awg-mishka -d 10.0.20.4 -p udp --dport 53 -j RETURN
    iptables -t raw -A awg-mishka -d 10.0.20.4 -p tcp --dport 53 -j RETURN
    iptables -t raw -A awg-mishka -d 10.0.0.0/8 -j DROP
    iptables -t raw -A awg-mishka -d 172.16.0.0/12 -j DROP
    iptables -t raw -A awg-mishka -d 192.168.0.0/16 -j DROP
    iptables -t raw -A awg-mishka -d 100.64.0.0/10 -j DROP
    iptables -t raw -C PREROUTING -i awg0 -j awg-mishka 2>/dev/null \
      || iptables -t raw -A PREROUTING -i awg0 -j awg-mishka
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t raw -D PREROUTING -i awg0 -j awg-mishka 2>/dev/null || true
    iptables -t raw -F awg-mishka 2>/dev/null || true
    iptables -t raw -X awg-mishka 2>/dev/null || true
  '';
}
