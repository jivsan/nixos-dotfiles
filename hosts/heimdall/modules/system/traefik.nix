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

          crafty = {
            rule = "Host(`crafty.oryxserver.org`)";
            service = "crafty";
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
          
          hlidskjalf = {
            rule = "Host(`hlidskjalf.oryxserver.org`)";
            entryPoints = [ "websecure" ];
            service = "hlidskjalf";
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

          crafty = {
            loadBalancer = {
              servers = [
                { url = "https://127.0.0.1:8443"; }
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
                { url = "http://127.0.0.1:8080"; }
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

          hlidskjalf = {
            loadBalancer = {
              servers = [
                { url = "http://127.0.0.1:8787"; }
              ];
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
              "10.88.0.0/16"     # podman's network here: homarr checks the sites by their https names
            ];
          };

        };
      };
    };
  };

  systemd.services.traefik.serviceConfig.SupplementaryGroups = [ "traefik" ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
