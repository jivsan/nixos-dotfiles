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
      # tyr — agent workstation; reaches the whole fleet the way mjolnir does
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ6bnnGGpBRPpHocQbpv/EfXM550646mUUCLAaoLeuhk tyr"
      # Nexterm (heimdall) — web SSH console; private half lives in Nexterm's identity store
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICv5EKRDOCy5PIuPwglImox8QAia8PX4+nvtoNLE1Vmr nexterm@heimdall"
    ];
  };

  # Passwordless sudo for wheel members.
  # SSH key authentication acts as the auth gate; password is redundant.
  security.sudo.wheelNeedsPassword = false;
}
