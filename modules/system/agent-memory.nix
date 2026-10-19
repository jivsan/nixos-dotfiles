{ ... }:

# odyn dataset vault/agent-memory (NFS share 16, every client mapped to the NAS user
# christina, uid 3002): Claude Code's memory notes, one copy for mjolnir and yggdrasil,
# snapshotted like the studio (hourly 2 days, daily 30, weekly 12 weeks). Claude reads it
# at ~/.agent-memory/claude: on mjolnir ~/.claude/projects/-home-christina-nixos-dotfiles/memory
# links there, on yggdrasil `autoMemoryDirectory` in ~/.claude/settings.json points there.
#
# Inside her home (mode 700), like ~/muninn: the share maps every client to its owner, so
# file modes protect nothing, and at /mnt any local user could write it. hermes on
# yggdrasil reads outside messages; a line it wrote here would load into every Claude
# session. hermes gets its read-only copy from `claude-to-yggdrasil` instead.
#
# soft with a short timeout, unlike the studio: when odyn is down Claude starts without its
# notes after a few seconds instead of hanging, and can still help fix things. actimeo=1:
# both hosts edit MEMORY.md, so each sees the other's change within a second.
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
