{ config, pkgs, ... }:

{
  # always the real hardware mac, never a random one
  networking.networkmanager.ethernet.macAddress = "permanent";
  networking.networkmanager.wifi.macAddress = "permanent";
  networking.networkmanager.wifi.scanRandMacAddress = false;

  # pinned, so the machine-id never changes across rebuilds
  environment.etc."machine-id".text = "8a8808e3d3fd45de9544648fbe275a27\n";
}
