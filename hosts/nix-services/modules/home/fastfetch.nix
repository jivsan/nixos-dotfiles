{ config, pkgs, ... }:

{
  programs.fastfetch = {
    enable = true;

    settings = {
      logo = {
        source = "nixos_small";
        padding = {
          top = 1;
          right = 3;
        };
      };

      display = {
        separator = "  ";
        size.binaryPrefix = "iec";
      };

      modules = [
        { type = "title"; format = "{user-name-colored}@{host-name-colored}"; }
        { type = "custom"; format = "{#90}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

        { type = "custom"; format = "{#blue}── SYSTEM ──"; }
        { type = "os";      key = "  OS";      keyColor = "blue"; }
        { type = "host";    key = "  Host";    keyColor = "blue"; }
        { type = "kernel";  key = "  Kernel";  keyColor = "blue"; }
        { type = "uptime";  key = "  Uptime";  keyColor = "blue"; }
        { type = "loadavg"; key = "  Load";    keyColor = "blue"; }

        "break"

        { type = "custom"; format = "{#magenta}── RESOURCES ──"; }
        {
          type = "cpu";
          key = "  CPU";
          keyColor = "magenta";
          format = "{name} ({cores-physical}c/{cores-logical}t)";
        }
        { type = "memory"; key = "  Memory"; keyColor = "magenta"; }
        {
          type = "command";
          key = "  Pressure";
          keyColor = "magenta";
          text = "cat /proc/pressure/cpu 2>/dev/null | awk '/some/ {print $2, $3, $4}' | sed 's/avg10=/cpu10=/; s/avg60=/cpu60=/; s/avg300=/cpu300=/' || echo unavailable";
        }

        "break"

        { type = "custom"; format = "{#cyan}── STORAGE ──"; }
        { type = "disk"; key = "  Root"; keyColor = "cyan"; folders = "/"; }
        {
          type = "command";
          key = "  NAS mounts";
          keyColor = "cyan";
          text = "findmnt -rn -t nfs,nfs4 | wc -l | awk '{print $1 \" mounted\"}'";
        }
        {
          type = "command";
          key = "  Nextcloud";
          keyColor = "cyan";
          text = "findmnt -rn /mnt/nextcloud 2>/dev/null >/dev/null && echo mounted || echo not mounted";
        }
        {
          type = "command";
          key = "  Immich";
          keyColor = "cyan";
          text = "findmnt -rn /mnt/immich 2>/dev/null >/dev/null && echo mounted || echo not mounted";
        }

        "break"

        { type = "custom"; format = "{#green}── CONTAINER STACK ──"; }
        {
          type = "command";
          key = "  Podman";
          keyColor = "green";
          text = "systemctl is-active podman.socket 2>/dev/null || systemctl is-active podman.service 2>/dev/null || echo available";
        }
        {
          type = "command";
          key = "  Running";
          keyColor = "green";
          text = "podman ps --format '{{.Names}}' 2>/dev/null | wc -l | awk '{print $1 \" containers\"}'";
        }
        {
          type = "command";
          key = "  Images";
          keyColor = "green";
          text = "podman images -q 2>/dev/null | sort -u | wc -l | awk '{print $1 \" images\"}'";
        }
        {
          type = "command";
          key = "  Volumes";
          keyColor = "green";
          text = "podman volume ls -q 2>/dev/null | wc -l | awk '{print $1 \" volumes\"}'";
        }

        "break"

        { type = "custom"; format = "{#green}── SERVICES ──"; }
        {
          type = "command";
          key = "  Traefik";
          keyColor = "green";
          text = "systemctl is-active traefik.service 2>/dev/null || echo not installed";
        }
        {
          type = "command";
          key = "  Immich";
          keyColor = "green";
          text = "systemctl is-active podman-immich-server.service 2>/dev/null || systemctl is-active podman-immich.service 2>/dev/null || echo not installed";
        }
        {
          type = "command";
          key = "  Nextcloud";
          keyColor = "green";
          text = "systemctl is-active podman-nextcloud-server.service 2>/dev/null || systemctl is-active podman-nextcloud.service 2>/dev/null || echo not installed";
        }
        {
          type = "command";
          key = "  Crafty";
          keyColor = "green";
          text = "systemctl is-active podman-crafty.service 2>/dev/null || echo not installed";
        }
        {
          type = "command";
          key = "  PostgreSQL";
          keyColor = "green";
          text = "systemctl list-units 'podman-*postgres*.service' --state=active --no-legend 2>/dev/null | wc -l | awk '{print $1 \" active\"}'";
        }
        {
          type = "command";
          key = "  Redis";
          keyColor = "green";
          text = "systemctl list-units 'podman-*redis*.service' --state=active --no-legend 2>/dev/null | wc -l | awk '{print $1 \" active\"}'";
        }

        "break"

        { type = "custom"; format = "{#yellow}── NETWORK ──"; }
        {
          type = "localip";
          key = "  LAN";
          keyColor = "yellow";
          format = "{ipv4} ({ifname})";
        }
        {
          type = "command";
          key = "  Tailscale";
          keyColor = "yellow";
          text = "tailscale ip -4 2>/dev/null || echo offline";
        }
        {
          type = "command";
          key = "  HTTPS";
          keyColor = "yellow";
          text = "systemctl is-active acme-oryxserver.org.timer 2>/dev/null || systemctl is-active acme-order-renew-oryxserver.org.timer 2>/dev/null || echo check manually";
        }

        "break"

        { type = "custom"; format = "{#red}── EDGE ROUTES ──"; }
        {
          type = "command";
          key = "  Immich";
          keyColor = "red";
          text = "curl -ksS --max-time 2 https://immich.oryxserver.org >/dev/null && echo online || echo unreachable";
        }
        {
          type = "command";
          key = "  Nextcloud";
          keyColor = "red";
          text = "curl -ksS --max-time 2 https://nextcloud.oryxserver.org >/dev/null && echo online || echo unreachable";
        }
        {
          type = "command";
          key = "  Traefik";
          keyColor = "red";
          text = "curl -ksS --max-time 2 https://traefik.oryxserver.org >/dev/null && echo online || echo unreachable";
        }

        "break"

        { type = "custom"; format = "{#90}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }
      ];
    };
  };
}
