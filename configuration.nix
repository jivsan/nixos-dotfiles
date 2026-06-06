{ ... }:

{
  imports = [
    ./modules/system/boot.nix
    ./modules/system/locale.nix
    ./modules/system/networking.nix
    ./modules/system/desktop.nix
    ./modules/system/remote.nix
    ./modules/system/users.nix
    ./modules/system/packages.nix
    ./modules/system/fonts.nix
    ./modules/system/nix.nix
    ./modules/system/storage.nix
    ./modules/system/nas.nix
    ./modules/system/dconf.nix
    ./modules/system/usb.nix
    ./modules/system/octane-shutdown.nix
    ./modules/system/network-identity.nix
    ./modules/system/uv.nix
  ];
}
