{ config, pkgs, ... }:

# the same nvidia driver on mjolnir (rtx 5070 ti) and mimir (rtx 4060 ti): the stable branch on the open module
{
  hardware.nvidia = {
    modesetting.enable = true;
    open = true;   # blackwell only runs on the open module, ada runs on both
    # nixpkgs-unstable patchelf 0.19 leaves nvidia-smi with overlapping load segments, it segfaults
    # in ld.so (mimir 2026-10-20). the stable patchelf (0.15) writes them right
    package = config.boot.kernelPackages.nvidiaPackages.stable.overrideAttrs (old: {
      preInstall = toString (old.preInstall or "") + "\nexport PATH=${pkgs.patchelf}/bin:$PATH\n";
    });
  };
}
