{ ... }:

{
  services.traefik = {
    enable = true;

    staticConfigOptions = {
      api = {
        dashboard = true;
        insecure = false;
      };

      entryPoints = {
        web = {
          address = ":80";
          http.redirections.entryPoint = {
            to = "websecure";
            scheme = "https";
          };
        };

        websecure = {
          address = ":443";
        };

        metrics = {
          address = "127.0.0.1:8082";
        };

        # forgejo's ssh (git push/pull), passed through to yggdrasil
        gitssh = {
          address = ":2222";
        };
      };

      metrics.prometheus = {
        entryPoint = "metrics";
        addEntryPointsLabels = true;
        addRoutersLabels = true;
        addServicesLabels = true;
      };

      log.level = "INFO";
      accessLog = {};
    };

    dynamicConfigOptions = {
      tls = {
        stores.default.defaultCertificate = {
          certFile = "/var/lib/acme/oryxserver.org/fullchain.pem";
          keyFile = "/var/lib/acme/oryxserver.org/key.pem";
        };

        certificates = [
          {
            certFile = "/var/lib/acme/oryxserver.org/fullchain.pem";
            keyFile = "/var/lib/acme/oryxserver.org/key.pem";
            stores = [ "default" ];
          }
        ];
      };

      http = {
        routers = {
          dashboard = {
            rule = "Host(`traefik.oryxserver.org`)";
            service = "api@internal";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          immich = {
            rule = "Host(`immich.oryxserver.org`)";
            service = "immich";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          truenas = {
            rule = "Host(`truenas.oryxserver.org`)";
            service = "truenas";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          homarr = {
            rule = "Host(`home.oryxserver.org`)";
            service = "homarr";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          paperless = {
            rule = "Host(`paperless.oryxserver.org`)";
            service = "paperless";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          grafana = {
            rule = "Host(`grafana.oryxserver.org`)";
            service = "grafana";
            entryPoints = [ "websecure" ];
            tls = {};
            middlewares = [ "lan-only" ];
          };

          scrutiny = {
            rule = "Host(`scrutiny.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "scrutiny";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          obsidian = {
            rule = "Host(`obsidian.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "obsidian";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          brain = {
            rule = "Host(`brain.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "brain";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          comfyui = {
            rule = "Host(`comfyui.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "comfyui";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          homeassistant = {
            rule = "Host(`homeassistant.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "homeassistant";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          sure = {
            rule = "Host(`sure.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "sure";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          vaultwarden = {
            rule = "Host(`vault.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "vaultwarden";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          ntfy = {
            rule = "Host(`ntfy.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "ntfy";
            tls = {};
            middlewares = [ "ntfy-allow" ];
          };

          pihole = {
            rule = "Host(`pihole.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "pihole";
            tls = {};
            middlewares = [ "lan-only" "pihole-admin" ];
          };

          pfsense = {
            rule = "Host(`pfsense.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "pfsense";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          changedetection = {
            rule = "Host(`changedetection.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "changedetection";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          searxng = {
            rule = "Host(`search.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "searxng";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          forgejo = {
            rule = "Host(`git.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "forgejo";
            tls = {};
            middlewares = [ "lan-only" ];
          };

          n8n = {
            rule = "Host(`n8n.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "n8n";
            tls = {};
            middlewares = [ "lan-only" ];
          };

        };

        services = {
          immich = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:2283"; }
              ];
            };
          };

          truenas = {
            loadBalancer = {
              servers = [
                { url = "https://10.0.20.6"; }
              ];
              serversTransport = "insecure";
            };
          };

          homarr = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:7575"; }
              ];
            };
          };

          paperless = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8010"; }
              ];
            };
          };

          grafana = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:3002"; }
              ];
            };
          };
          scrutiny = {
            loadBalancer = {
              servers = [
                { url = "http://10.0.20.6:30808"; }   # an odyn app since 2026-10-22 (odyn/apps/scrutiny)
              ];
            };
          };
          obsidian = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:3000"; }
              ];
            };
          };
          brain = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8090"; }
              ];
            };
          };

          vaultwarden = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8222"; }
              ];
            };
          };

          ntfy = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:2586"; }
              ];
            };
          };

          # comfyui on mimir
          comfyui = {
            loadBalancer = {
              servers = [
                { url = "http://10.0.20.18:8188"; }
              ];
            };
          };

          # sure (finance) on njord, whose nftables only accept :3000 from heimdall
          sure = {
            loadBalancer = {
              servers = [
                { url = "http://10.0.20.20:3000"; }
              ];
            };
          };

          # home assistant on the iot vlan; needs use_x_forwarded_for + trusted_proxies
          # in its configuration.yaml or it answers 400
          homeassistant = {
            loadBalancer = {
              servers = [
                { url = "http://10.0.50.101:8123"; }
              ];
            };
          };

          # pi-hole v6, LXC 152 on hella
          pihole = {
            loadBalancer = {
              servers = [
                { url = "http://10.0.20.4"; }
              ];
            };
          };

          # pfsense web ui, self-signed cert; its hostname is pfsense.oryxserver.org,
          # so its dns-rebind and referer checks accept this name
          changedetection.loadBalancer.servers = [ { url = "http://127.0.0.1:5000"; } ];
          searxng.loadBalancer.servers = [ { url = "http://127.0.0.1:8888"; } ];
          # forgejo on yggdrasil, whose firewall only lets heimdall reach :3000 and :2222
          forgejo.loadBalancer.servers = [ { url = "http://10.0.20.21:3000"; } ];
          n8n.loadBalancer.servers = [ { url = "http://10.0.20.21:5678"; } ];

          pfsense = {
            loadBalancer = {
              servers = [
                { url = "https://10.0.20.1"; }
              ];
              serversTransport = "insecure";
            };
          };
        };

        serversTransports = {
          insecure = {
            insecureSkipVerify = true;
          };
        };

        middlewares = {
          lan-only = {
            ipAllowList.sourceRange = [
              "10.0.20.0/24"
              "10.0.50.10/32"    # my phone (static lease on the iot vlan), just this one host
              "100.64.0.0/10"
              "127.0.0.1/32"
              "10.88.200.10/32"  # homarr's container (homarr.nix), it checks the sites by their https names
            ];
          };

          # lan-only plus heimdall's own podman networks: apps in containers here send to ntfy by its
          # https name. ntfy still wants a login or a token from every one of them
          ntfy-allow = {
            ipAllowList.sourceRange = [
              "10.0.20.0/24"
              "10.0.50.10/32"    # my phone
              "100.64.0.0/10"
              "127.0.0.1/32"
              "10.88.0.0/16"     # podman's default network
              "10.89.0.0/16"     # the per-app networks (immich, paperless, changedetection)
            ];
          };

          # pi-hole answers 403 on / for any name but pi.hole, so send / to the admin page
          pihole-admin = {
            redirectRegex = {
              regex = "^https://pihole\\.oryxserver\\.org/?$";
              replacement = "https://pihole.oryxserver.org/admin/";
            };
          };

        };
      };

      # ssh://git@git.oryxserver.org:2222 → forgejo's own ssh server on yggdrasil
      tcp = {
        routers.forgejo-ssh = {
          rule = "HostSNI(`*`)";
          entryPoints = [ "gitssh" ];
          service = "forgejo-ssh";
          middlewares = [ "lan-only-tcp" ];
        };
        services.forgejo-ssh.loadBalancer.servers = [ { address = "10.0.20.21:2222"; } ];
        middlewares.lan-only-tcp.ipAllowList.sourceRange = [
          "10.0.20.0/24"
          "10.0.50.10/32"    # my phone
          "100.64.0.0/10"
        ];
      };
    };
  };

  systemd.services.traefik.serviceConfig.SupplementaryGroups = [ "traefik" ];

  networking.firewall.allowedTCPPorts = [ 80 443 2222 ];
}
