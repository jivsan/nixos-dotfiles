# mjolnir's desktop base, imported as its own file so module order stays the same
{ ... }:

{
  imports = [
    ../../../../modules/system/boot.nix
    ../../../../modules/system/locale.nix
    ./networking.nix
    ./desktop.nix
    ./remote.nix
    ../../../../modules/system/users.nix
    ./packages.nix
    ../../../../modules/system/fonts.nix
    ../../../../modules/system/nix.nix
    ./storage.nix
    ./nas.nix
    ./dconf.nix
    ./usb.nix
    ./octane-shutdown.nix
    ./network-identity.nix
    ./uv.nix
  ];
}
