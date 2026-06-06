# modules/scrutiny.nix
#
# Scrutiny hub deployment (web UI + InfluxDB) on NixOS via podman.
# The collector runs separately on TrueNAS (10.0.0.6) and pushes
# SMART data to this host on port 8080.
#
# Web UI:  http://10.0.0.17:8080

{ config, pkgs, lib, ... }:

let
  scrutinyVersion = "v0.8.6";
  influxdbVersion = "2.7";
  stateDir = "/var/lib/scrutiny";
in
{
  ############################################################
  # Podman / OCI backend
  ############################################################
  virtualisation = {
    podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers.backend = "podman";
  };

  ############################################################
  # Dedicated podman network so web ↔ influxdb resolve by name
  ############################################################
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

  ############################################################
  # Persistent state directories
  ############################################################
  systemd.tmpfiles.rules = [
    "d ${stateDir}             0755 root root -"
    "d ${stateDir}/config      0755 root root -"
    "d ${stateDir}/influxdb2   0755 root root -"
  ];

  ############################################################
  # Containers
  ############################################################
  virtualisation.oci-containers.containers = {

    # InfluxDB 2.x — backing store for SMART metrics.
    # Not exposed on the host; only scrutiny-web talks to it
    # over the internal scrutiny-net bridge.
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

    # Scrutiny web UI + API — receives pushes from remote collectors.
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
      dependsOn = [ "scrutiny-influxdb" ];
      extraOptions = [
        "--network=scrutiny-net"
      ];
    };
  };

  ############################################################
  # Make scrutiny-web wait for the network unit
  ############################################################
  systemd.services.podman-scrutiny-influxdb = {
    after = [ "podman-network-scrutiny.service" ];
    requires = [ "podman-network-scrutiny.service" ];
  };
  systemd.services.podman-scrutiny-web = {
    after = [ "podman-network-scrutiny.service" ];
    requires = [ "podman-network-scrutiny.service" ];
  };

  ############################################################
  # Firewall — allow the TrueNAS collector at 10.0.0.6
  ############################################################
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
