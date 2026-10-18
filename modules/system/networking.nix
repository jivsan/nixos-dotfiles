{ ... }:

{
  networking.networkmanager.enable = true;
  # OctaneRender network rendering: 1047 = OctaneServer's master port, 48000 = daemon port.
  networking.firewall.allowedTCPPorts = [ 1047 48000 ];
  networking.firewall.allowedUDPPorts = [ 1047 48000 ];
  # The render node on mimir answers OctaneServer's search by connecting back to a port
  # OctaneServer picks by itself (seen: 1025, and 1026 after a firewall reload), so a fixed
  # port list does not hold. Without this the node runs and answers but never shows up in
  # OctaneServer. Let mimir in on TCP, whatever the port.
  networking.firewall.extraCommands = ''
    iptables -I nixos-fw -p tcp -s 10.0.20.18 -j nixos-fw-accept
  '';
}
