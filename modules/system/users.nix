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
    ];
  };

  # Passwordless sudo for wheel members.
  # SSH key authentication acts as the auth gate; password is redundant.
  security.sudo.wheelNeedsPassword = false;
}
