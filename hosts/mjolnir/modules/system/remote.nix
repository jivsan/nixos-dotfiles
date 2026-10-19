{ config, pkgs, ... }:

# key-only sshd, no remote desktop here (tyr is my rdp box)
{
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
