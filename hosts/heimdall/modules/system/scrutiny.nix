# scrutiny hub (web ui + its own influxdb); the collector on odyn pushes smart data to :8080

{ config, pkgs, lib, ... }:

let
  # the collector on odyn (odyn/apps/scrutiny-collector) must run the same version: 0.9 finds
  # drives by a scrutiny uuid and drops reports from older collectors
  scrutinyWeb = "ghcr.io/analogj/scrutiny:v0.9.5-web@sha256:4f2ec0c874aec7fb0da5505b8ee127a8d7ac5b9d2b0622b53cf27fb47693877c";
  # 2.8 as in scrutiny's own compose. not 2.9: it turns on token hashing, which can't be undone
  influxdbImage = "docker.io/library/influxdb:2.8.0@sha256:983c696655e862517f07384ff427291928846174de60615b95027b50804c9592";
  stateDir = "/var/lib/scrutiny";
in
{
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
      image = influxdbImage;
      autoStart = true;
      volumes = [
        "${stateDir}/influxdb2:/var/lib/influxdb2"
      ];
      extraOptions = [
        "--network=scrutiny-net"
      ];
    };

    scrutiny-web = {
      image = scrutinyWeb;
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
        # at info it logs every notify url, token included ("Sending notifications to ntfy://:tk_...")
        SCRUTINY_LOG_LEVEL = "WARN";
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
