{ ... }:

{
  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 1047 48000 ];
  networking.firewall.allowedUDPPorts = [ 1047 48000 ];
}
