# podman for the whole host: the apps here run as containers in it (oci-containers).
# this used to sit in scrutiny.nix
{
  virtualisation = {
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      dockerCompat = true;   # `docker` alias
    };
    oci-containers.backend = "podman";
  };
}
