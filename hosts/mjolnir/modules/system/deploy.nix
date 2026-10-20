{ pkgs, ... }:
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "deploy";
      runtimeInputs = with pkgs; [ git openssh ];
      text = builtins.readFile ../../../../scripts/deploy;
    })
  ];
}
