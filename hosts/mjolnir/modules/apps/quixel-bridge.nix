{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    appimage-run
    (writeShellScriptBin "quixel-bridge" ''
      exec appimage-run /home/christina/applications/Bridge.AppImage --no-sandbox --disable-gpu-sandbox
    '')
  ];

  boot.supportedFilesystems = [ "fuse" ];
  programs.fuse.userAllowOther = true;
}
