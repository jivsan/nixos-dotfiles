{ config, pkgs, ... }:

# mjolnir's sshd. Key-only, no root login, no remote desktop: mjolnir is not
# accessed remotely (tyr is the RDP workstation; see hosts/tyr/modules/system/desktop.nix).
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
