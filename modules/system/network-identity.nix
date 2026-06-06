# modules/system/network-identity.nix
{ config, pkgs, ... }:

{
  # Force permanent (real hardware) MAC on all interfaces
  networking.networkmanager.ethernet.macAddress = "permanent";
  networking.networkmanager.wifi.macAddress = "permanent";
  networking.networkmanager.wifi.scanRandMacAddress = false;

  # Pin machine-id so it never changes across rebuilds
  environment.etc."machine-id".text = "8a8808e3d3fd45de9544648fbe275a27\n";
}
