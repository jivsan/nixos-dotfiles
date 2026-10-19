{ ... }:
{
  fileSystems."/mnt/data_ssd" = {
    device = "/dev/disk/by-uuid/8ddfb4e3-1a92-43da-8767-45891077866f";
    fsType = "ext4";
    options = [ "defaults" "nofail" "x-gvfs-show" ];
  };

  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-uuid/0af00153-3483-4bd7-a116-ae99e4c03c69";
    fsType = "ext4";
    options = [ "defaults" "nofail" "x-gvfs-show" ];
  };
}
