{ ... }:

# odyn dataset vault/agent-memory (NFS share 16, every client mapped to the NAS user
# christina, uid 3002): Claude Code's memory notes, one copy for mjolnir and yggdrasil,
# snapshotted like the studio (hourly 2 days, daily 30, weekly 12 weeks). Claude reads it
# at /mnt/agent-memory/claude: on mjolnir ~/.claude/projects/-home-christina-nixos-dotfiles/memory
# links there, on yggdrasil `autoMemoryDirectory` in ~/.claude/settings.json points there.
# soft with a short timeout, unlike the studio: when odyn is down Claude starts without its
# notes after a few seconds instead of hanging, and can still help fix things.
{
  fileSystems."/mnt/agent-memory" = {
    device = "10.0.20.6:/mnt/vault/agent-memory";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "timeo=50"
      "retrans=2"
      "noatime"
      "_netdev"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
      "x-systemd.mount-timeout=15"
    ];
  };
}
