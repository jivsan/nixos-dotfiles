{ config, ... }:

let
  dotfiles = "${config.home.homeDirectory}/nixos-dotfiles/config";
  createSymlink = path: config.lib.file.mkOutOfStoreSymlink path;
  configs = {
    qtile = "qtile";
    rofi = "rofi";
    nvim = "nvim";
  };
in
{
  xdg.configFile = builtins.mapAttrs
    (_: subpath: {
      source = createSymlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
