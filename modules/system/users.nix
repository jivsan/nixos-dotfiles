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
    ];
  };

  # Passwordless sudo for wheel members.
  # SSH key authentication acts as the auth gate; password is redundant.
  security.sudo.wheelNeedsPassword = false;
}
