{ ... }:

# claude's memory notes on odyn, one copy for mjolnir and yggdrasil
# in my home, not /mnt, so hermes can't write to it
# soft + short timeout: if odyn is down claude starts without notes instead of hanging
# actimeo=1: both hosts edit MEMORY.md and see each other's changes within a second
{
  fileSystems."/home/christina/.agent-memory" = {
    device = "10.0.20.6:/mnt/vault/agent-memory";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "timeo=50"
      "retrans=2"
      "actimeo=1"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=15"
    ];
  };
}
