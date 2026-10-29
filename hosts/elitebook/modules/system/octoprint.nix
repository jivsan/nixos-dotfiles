{ pkgs-unstable, ... }:

# octoprint: the web page for the ender-3 v3 se, on http://10.0.20.22:5000 from mjolnir.
# orcaslicer on mjolnir can send to it too (printer settings, physical printer, octoprint + the api key)
{
  services.octoprint = {
    enable = true;
    # 1.11.8 fixes CVE-2026-54134 (high) and CVE-2026-35163, nixos-26.05 still has 1.11.7.
    # drop this line once 26.05 has 1.11.8
    package = pkgs-unstable.octoprint;
    port = 5000;
    openFirewall = false;   # would open 5000 to the whole lan, the rule at the bottom lets only mjolnir in
    plugins = ps: with ps; [
      bedlevelvisualizer    # shows the bed mesh from the auto levelling
      simpleemergencystop   # a stop button in the top bar
    ];
    # merged into config.yaml at every start, so these win over the web page.
    # no passwords or api keys here, they would end up world-readable in the nix store
    extraConfig = {
      serial = {
        port = "/dev/ttyUSB_ender3";   # the udev link below. it has to start with ttyUSB to be listed
        baudrate = 115200;
        autoconnect = true;
      };
      # no battery: a power cut while it starts would put the next start in safe mode (plugins off)
      server.ignoreIncompleteStartup = true;
      # nix updates octoprint and its plugins, so no update button that can't work
      plugins._disabled = [ "softwareupdate" ];
    };
  };

  systemd.services.octoprint = {
    restartIfChanged = false;   # a rebuild never restarts octoprint mid-print, i restart it by hand when idle
    serviceConfig = {
      UMask = "0077";           # config.yaml holds the secret key and api key
      Restart = "on-failure";
    };
  };

  # the printer's usb serial chip (ch340 1a86:7523, check with lsusb) gets a fixed name.
  # a ch340 has no serial number, so this would also match an esp32 board on the same chip:
  # once the laptop runs, match the usb port instead (ENV{ID_PATH} from `udevadm info /dev/ttyUSB0`)
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", SYMLINK+="ttyUSB_ender3"
  '';

  # the web page only for mjolnir. extraCommands runs before nixos-fw's final refuse rule
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 10.0.20.100 --dport 5000 -j nixos-fw-accept
  '';
}
