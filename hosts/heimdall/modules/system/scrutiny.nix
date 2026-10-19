# scrutiny hub (web ui + its own influxdb); the collector on odyn pushes smart data to :8080

{ config, pkgs, lib, ... }:

let
  scrutinyVersion = "v0.8.6";
  influxdbVersion = "2.7";
  stateDir = "/var/lib/scrutiny";
in
{
  # podman settings for the whole host live here, not only scrutiny's
  virtualisation = {
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      dockerCompat = true;   # `docker` alias
    };
    oci-containers.backend = "podman";
  };

  systemd.services.podman-network-scrutiny = {
    description = "Create scrutiny podman network";
    after = [ "podman.service" ];
    requires = [ "podman.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman network exists scrutiny-net || \
        ${pkgs.podman}/bin/podman network create scrutiny-net
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir}             0755 root root -"
    "d ${stateDir}/config      0755 root root -"
    "d ${stateDir}/influxdb2   0755 root root -"
  ];

  virtualisation.oci-containers.containers = {

    # influxdb 2, separate from influxdb.nix; no host port, only scrutiny-web reaches it
    scrutiny-influxdb = {
      image = "influxdb:${influxdbVersion}";
      autoStart = true;
      volumes = [
        "${stateDir}/influxdb2:/var/lib/influxdb2"
      ];
      extraOptions = [
        "--network=scrutiny-net"
      ];
    };

    scrutiny-web = {
      image = "ghcr.io/analogj/scrutiny:${scrutinyVersion}-web";
      autoStart = true;
      ports = [
        "8080:8080"
      ];
      volumes = [
        "${stateDir}/config:/opt/scrutiny/config"
      ];
      environment = {
        SCRUTINY_WEB_INFLUXDB_HOST = "scrutiny-influxdb";
        SCRUTINY_WEB_INFLUXDB_PORT = "8086";
      };
      # SCRUTINY_NOTIFY_URLS=ntfy://:<token>@ntfy.oryxserver.org/alerts?..., a failing drive pushes to my phone.
      # it goes through traefik (ntfy-allow lets this network in); test: curl -X POST 127.0.0.1:8080/api/health/notify
      environmentFiles = [ "/var/lib/secrets/scrutiny-notify.env" ];
      dependsOn = [ "scrutiny-influxdb" ];
      extraOptions = [
        "--network=scrutiny-net"
      ];
    };
  };

  systemd.services.podman-scrutiny-influxdb = {
    after = [ "podman-network-scrutiny.service" ];
    requires = [ "podman-network-scrutiny.service" ];
  };
  systemd.services.podman-scrutiny-web = {
    after = [ "podman-network-scrutiny.service" ];
    requires = [ "podman-network-scrutiny.service" ];
  };

  # odyn's collector pushes here
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
