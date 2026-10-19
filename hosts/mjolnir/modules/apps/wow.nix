{ pkgs, ... }:
let
  protonGE = "/home/christina/.local/share/Steam/compatibilitytools.d/GE-Proton10-34";
  prefixPath = "/home/christina/Games/battlenet";
  wowPath = "/mnt/data_ssd/DF BETA/World of Warcraft/_retail_/Wow.exe";
  bnetPath = "/home/christina/Games/battlenet/drive_c/Program Files (x86)/Battle.net/Battle.net.exe";
in
{
  environment.systemPackages = with pkgs; [
    wowup-cf

    (writeShellScriptBin "wow-launch" ''
      export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
      export STEAM_COMPAT_DATA_PATH="${prefixPath}"
      export WINEPREFIX="${prefixPath}/pfx"
      export DXVK_LOG_LEVEL="none"
      export PATH="${python3}/bin:$PATH"

      echo "Launching World of Warcraft (Retail)..."
      ${steam-run}/bin/steam-run "${protonGE}/proton" run "${wowPath}"
    '')

    (writeShellScriptBin "bnet-launch" ''
      export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
      export STEAM_COMPAT_DATA_PATH="${prefixPath}"
      export WINEPREFIX="${prefixPath}/pfx"
      export DXVK_LOG_LEVEL="none"
      export PATH="${python3}/bin:$PATH"

      echo "Launching Battle.net..."
      ${steam-run}/bin/steam-run "${protonGE}/proton" run "${bnetPath}"
    '')
  ];
}
