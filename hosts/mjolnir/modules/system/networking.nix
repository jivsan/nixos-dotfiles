{ ... }:

{
  networking.networkmanager.enable = true;
  # octane network rendering: 1047 OctaneServer master port, 48000 daemon port
  networking.firewall.allowedTCPPorts = [ 1047 48000 ];
  networking.firewall.allowedUDPPorts = [ 1047 48000 ];
  # mimir's render node connects back on a port OctaneServer picks itself (1025, 1026, ...),
  # so a fixed list doesn't hold: mimir gets in on any tcp port, or the node never shows up
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -p tcp -s 10.0.20.18 -j nixos-fw-accept
  '';
}
