{ pkgs, ... }:
{
  users.users.christina = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    packages = with pkgs; [
      tree
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1csspUrW5PNLgmMxv/eMWVnnBWqmSEDlE4OemZGfDQ jivsan"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPk8y0SG07+N9tZvyCkxNKjpiGDk94u3qKyiJtAG7P+ hermes-agent@vps-jiv-prod"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEA+3wCqGYzfe9u9zkU5beCkzBT9YWNc7M1nz/alhLaa hlidskjalf-dev"
      # tyr, my agent workstation: reaches the whole fleet like mjolnir does
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6bnnGGpBRPpHocQbpv/EfXM550646mUUCLAaoLeuhk tyr"
    ];
  };

  # no sudo password: key-only ssh is the gate
  security.sudo.wheelNeedsPassword = false;
}
