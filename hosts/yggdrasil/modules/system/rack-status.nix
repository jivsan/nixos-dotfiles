{ config, lib, pkgs, ... }:

# rack-status: pings every box in the rack and the internet every 30 s and tells home assistant over mqtt,
# for the rack leds. one binary_sensor.rack_status_<name> per box, on = it answers ping.
# a box shows down after two rounds without an answer (right after a start: the first), up again at the first answer.
# if this stops, every entity goes unavailable (the leds show "no data").
# mqtt login: "rack-status" in the mosquitto app's own logins, password in /var/lib/secrets/rack-status-mqtt
let
  broker = {
    host = "10.0.50.101";   # home assistant's mosquitto app. an address, not a name: the allow list below needs it
    username = "rack-status";
    # tls: the mosquitto app's certificate (it's public, fine in the repo), e.g. ./rack-status-mqtt.crt.
    # set = it talks tls on 8883 and checks the broker is really 10.0.50.101. null = plain 1883
    tlsCert = null;
  };
  port = if broker.tlsCert == null then 1883 else 8883;
  every = 30;               # seconds between rounds
  downAfter = 2;            # rounds in a row without an answer before a box shows down

  # top of the rack first. name = the end of the entity id: binary_sensor.rack_status_<name>
  hosts = [
    { name = "bifrost";   address = "10.0.20.2"; }    # the switch
    { name = "pfsense";   address = "10.0.20.1"; }
    { name = "mimir";     address = "10.0.20.18"; }
    { name = "garm";      address = "10.0.20.11"; }   # helheim node 1
    # fenrir gets hella's old address once it's built. off till then.
    # that day: take enabled = false off fenrir.
    # never delete or rename a line, set enabled = false: only that removes the old entity in home assistant
    { name = "fenrir";    address = "10.0.20.10"; enabled = false; }
    { name = "odyn";      address = "10.0.20.6"; }
    { name = "yggdrasil"; address = "10.0.20.21"; }   # this box, so always on while it runs
    { name = "hella";     address = "10.0.20.10"; enabled = false; }   # retired 2026-11-04
    { name = "heimdall";  address = "10.0.20.17"; }   # vm on garm
  ];

  # the internet is up when any of these answers
  internet = [ "1.1.1.1" "9.9.9.9" "8.8.8.8" ];

  targets =
    [ { name = "internet"; addresses = internet; enabled = true; } ]
    ++ map (h: { inherit (h) name; addresses = [ h.address ]; enabled = h.enabled or true; }) hosts;

  pinged = lib.unique (lib.concatMap (t: t.addresses) (lib.filter (t: t.enabled) targets));

  configFile = pkgs.writeText "rack-status.json" (builtins.toJSON {
    mqtt = {
      inherit (broker) host username;
      inherit port;
      ca_file = if broker.tlsCert == null then null else "${broker.tlsCert}";
      client_id = "rack-status-${config.networking.hostName}";
    };
    source = config.networking.hostName;
    topic = "rack-status";                 # rack-status/<name>/state, /attributes, rack-status/availability
    discovery_prefix = "homeassistant";    # homeassistant/binary_sensor/rack_status/<name>/config
    inherit every targets;
    down_after = downAfter;
    fping = "${pkgs.fping}/bin/fping";
    retries = 1;                           # fping tries each box twice per round
    timeout_ms = 1000;
    attributes_every = 300;                # round-trip time refresh, not every round (ha keeps every change)
  });

  python = pkgs.python3.withPackages (ps: [ ps.paho-mqtt ]);
in
{
  systemd.services.rack-status = {
    description = "rack-status: ping the rack, tell home assistant over mqtt";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 0;             # keep trying, the broker might be rebooting
    environment.RACK_STATUS_CONFIG = "${configFile}";
    serviceConfig = {
      ExecStart = "${python}/bin/python3 ${./rack-status.py}";
      Restart = "always";
      RestartSec = "10s";
      LoadCredential = "mqtt-password:/var/lib/secrets/rack-status-mqtt";

      DynamicUser = true;
      # fping pings without root through the kernel's ping sockets (net.ipv4.ping_group_range,
      # open to every group on nixos), so it needs no capabilities at all
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateUsers = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];   # unix: paho's wake-up socket pair
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
      SystemCallErrorNumber = "EPERM";
      UMask = "0077";
      # it only ever talks to the broker, the addresses it pings, and itself: the mqtt library
      # opens a small connection to 127.0.0.1 at start to wake its own thread. without localhost
      # here it hangs for good right after the "pinging ..." line and ignores stop (2026-11-05)
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" broker.host ] ++ pinged;
    };
  };
}
