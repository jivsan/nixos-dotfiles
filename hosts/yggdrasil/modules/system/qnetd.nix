{ pkgs, ... }:

# the third vote for my helheim cluster (garm + fenrir): corosync-qnetd.
# both nodes run corosync-qdevice and talk to this on tcp 5403. in a split, qnetd gives its
# vote to one side only, so either node can go down and the other one keeps quorum.
#
# certificates live in /etc/corosync/qnetd/nssdb (state, not in git). made once by hand:
#   sudo -u coroqnetd corosync-qnetd-certutil -i
# then the cluster side gets signed with `corosync-qnetd-certutil -s` (steps in my vault,
# hella → helheim stage I). qnetd stays off until that database exists.
#
# rules: never reboot this box while a node is down, and remove the qdevice
# (`pvecm qdevice remove`) before adding or removing a node.
let
  qdevice = pkgs.corosync-qdevice;
in
{
  # corosync-qnetd-certutil calls nss's certutil, so both go on the path
  environment.systemPackages = [ qdevice pkgs.nss.tools ];

  users.users.coroqnetd = {
    isSystemUser = true;
    group = "coroqnetd";
  };
  users.groups.coroqnetd = { };

  # the cert tool copies the owner of this folder onto every file it makes
  systemd.tmpfiles.rules = [
    "d /etc/corosync 0755 root root -"
    "d /etc/corosync/qnetd 0770 coroqnetd coroqnetd -"
  ];

  systemd.packages = [ qdevice ];   # ships corosync-qnetd.service
  systemd.services.corosync-qnetd = {
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/etc/corosync/qnetd/nssdb/cert9.db";
    serviceConfig = {
      User = "coroqnetd";
      Group = "coroqnetd";
    };
  };

  # 5403 only for the two nodes (their own addresses on vlan 20)
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 10.0.20.10 --dport 5403 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp -s 10.0.20.11 --dport 5403 -j nixos-fw-accept
  '';
}
