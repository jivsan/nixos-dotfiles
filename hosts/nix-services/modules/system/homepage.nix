{ pkgs, ... }:

let
  settingsYaml = pkgs.writeText "homepage-settings.yaml" ''
    title: Oryx Command
    description: Homelab control plane
    theme: dark
    color: slate
    headerStyle: boxedWidgets
    statusStyle: dot
    target: _blank
    hideVersion: true
    useEqualHeights: true
    fiveColumns: true

    layout:
      Command:
        style: row
        columns: 4
      Core Services:
        style: row
        columns: 4
      Intelligence:
        style: row
        columns: 4
      Infrastructure:
        style: row
        columns: 4
      Operations:
        style: row
        columns: 4
  '';

  servicesYaml = pkgs.writeText "homepage-services.yaml" ''
    - Command:
        - Oryx Command:
            icon: homepage.png
            href: https://home.oryxserver.org
            description: Homelab launch deck
            ping: https://home.oryxserver.org

        - Grafana:
            icon: grafana.png
            href: https://grafana.oryxserver.org
            description: Metrics, dashboards, observability
            ping: https://grafana.oryxserver.org

        - Traefik:
            icon: traefik.png
            href: https://traefik.oryxserver.org
            description: Edge router and TLS ingress
            ping: https://traefik.oryxserver.org

        - Tailscale:
            icon: tailscale.png
            href: https://login.tailscale.com/admin/machines
            description: Private mesh network

    - Core Services:
        - Immich:
            icon: immich.png
            href: https://immich.oryxserver.org
            description: Photos, faces, memories
            ping: https://immich.oryxserver.org

        - Nextcloud:
            icon: nextcloud.png
            href: https://nextcloud.oryxserver.org
            description: Files and personal cloud
            ping: https://nextcloud.oryxserver.org

        - Paperless:
            icon: paperless-ngx.png
            href: https://paperless.oryxserver.org
            description: Documents, OCR, archive
            ping: https://paperless.oryxserver.org

        - Crafty:
            icon: minecraft.png
            href: https://crafty.oryxserver.org
            description: Minecraft server control
            ping: https://crafty.oryxserver.org

    - Intelligence:
        - Open WebUI:
            icon: open-webui.png
            href: https://openwebui.oryxserver.org
            description: Local AI chat interface
            ping: https://openwebui.oryxserver.org

        - ComfyUI:
            icon: comfyui.png
            href: https://comfyui.oryxserver.org
            description: Image generation workflows
            ping: https://comfyui.oryxserver.org

        - nix-oryx:
            icon: nixos.png
            href: https://openwebui.oryxserver.org
            description: AI workload VM

        - Model Lab:
            icon: ollama.png
            href: https://openwebui.oryxserver.org
            description: LLM experiments

    - Infrastructure:
        - TrueNAS:
            icon: truenas.png
            href: https://truenas.oryxserver.org
            description: Storage, datasets, NFS
            ping: https://truenas.oryxserver.org

        - Proxmox Thor:
            icon: proxmox.png
            href: https://thor.oryxserver.org:8006
            description: Proxmox node thor

        - Proxmox Hella:
            icon: proxmox.png
            href: https://hella.oryxserver.org:8006
            description: Proxmox node hella

        - pfSense:
            icon: pfsense.png
            href: https://10.0.0.1
            description: Firewall and routing

        - Pi-hole:
            icon: pi-hole.png
            href: http://10.0.0.4/admin
            description: DNS and ad blocking

    - Operations:
        - NixOS Options:
            icon: nixos.png
            href: https://search.nixos.org/options
            description: System option search

        - Nix Packages:
            icon: nixos.png
            href: https://search.nixos.org/packages
            description: Package search

        - GitHub:
            icon: github.png
            href: https://github.com
            description: Code, repos, mirrors

        - TrueNAS Dataset:
            icon: truenas.png
            href: https://truenas.oryxserver.org
            description: /mnt/vault/nix-services
  '';

  widgetsYaml = pkgs.writeText "homepage-widgets.yaml" ''
    - datetime:
        text_size: xl
        format:
          dateStyle: full
          timeStyle: short
          hour12: false

    - resources:
        label: nix-services
        cpu: true
        memory: true
        disk: /

    - search:
        provider: duckduckgo
        target: _blank
        focus: false
  '';

  bookmarksYaml = pkgs.writeText "homepage-bookmarks.yaml" ''
    - Quick Ops:
        - nix-services SSH:
            - icon: terminal.png
              href: ssh://christina@10.0.0.17
        - nix-oryx SSH:
            - icon: terminal.png
              href: ssh://christina@10.0.0.15
        - Tailscale Machines:
            - icon: tailscale.png
              href: https://login.tailscale.com/admin/machines
        - NixOS Manual:
            - icon: nixos.png
              href: https://nixos.org/manual/nixos/stable/

    - Storage:
        - TrueNAS:
            - icon: truenas.png
              href: https://truenas.oryxserver.org
        - Nextcloud:
            - icon: nextcloud.png
              href: https://nextcloud.oryxserver.org
        - Paperless:
            - icon: paperless-ngx.png
              href: https://paperless.oryxserver.org
        - Immich:
            - icon: immich.png
              href: https://immich.oryxserver.org

    - Build / Debug:
        - NixOS Options:
            - icon: nixos.png
              href: https://search.nixos.org/options
        - NixOS Packages:
            - icon: nixos.png
              href: https://search.nixos.org/packages
        - MyNixOS:
            - icon: nixos.png
              href: https://mynixos.com
        - GitHub:
            - icon: github.png
              href: https://github.com
  '';

  customCss = pkgs.writeText "homepage-custom.css" ''
    :root {
      --card-blur: 18px;
      --orb-cyan: rgba(34, 211, 238, 0.16);
      --orb-violet: rgba(168, 85, 247, 0.18);
      --orb-blue: rgba(59, 130, 246, 0.14);
    }

    body {
      background:
        radial-gradient(circle at 15% 10%, var(--orb-cyan), transparent 28%),
        radial-gradient(circle at 85% 5%, var(--orb-violet), transparent 30%),
        radial-gradient(circle at 50% 95%, var(--orb-blue), transparent 34%),
        linear-gradient(135deg, #020617 0%, #0f172a 45%, #111827 100%) !important;
      background-attachment: fixed !important;
    }

    #page_container {
      backdrop-filter: saturate(120%);
    }

    .service-card,
    .bookmark-card,
    .resources,
    .datetime,
    .search {
      border: 1px solid rgba(148, 163, 184, 0.18) !important;
      background: rgba(15, 23, 42, 0.58) !important;
      box-shadow:
        0 20px 60px rgba(0, 0, 0, 0.24),
        inset 0 1px 0 rgba(255, 255, 255, 0.04) !important;
      backdrop-filter: blur(var(--card-blur)) !important;
      border-radius: 22px !important;
    }

    .service-card:hover,
    .bookmark-card:hover {
      transform: translateY(-3px) scale(1.01);
      border-color: rgba(34, 211, 238, 0.42) !important;
      box-shadow:
        0 24px 70px rgba(0, 0, 0, 0.32),
        0 0 28px rgba(34, 211, 238, 0.10) !important;
      transition: all 180ms ease;
    }

    .service-title,
    .bookmark-title {
      letter-spacing: 0.01em;
      font-weight: 700 !important;
    }

    .service-description {
      opacity: 0.78;
    }

    .group-title {
      letter-spacing: 0.08em;
      text-transform: uppercase;
      font-size: 0.82rem !important;
      color: rgba(226, 232, 240, 0.86) !important;
    }

    .status-dot {
      box-shadow: 0 0 10px currentColor;
    }

    input {
      border-radius: 999px !important;
      background: rgba(2, 6, 23, 0.56) !important;
      border: 1px solid rgba(148, 163, 184, 0.20) !important;
    }
  '';
in
{
  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    autoStart = true;

    ports = [
      "127.0.0.1:3004:3000"
    ];

    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.oryxserver.org,localhost:3004,127.0.0.1:3004";
    };

    volumes = [
      "${settingsYaml}:/app/config/settings.yaml:ro"
      "${servicesYaml}:/app/config/services.yaml:ro"
      "${widgetsYaml}:/app/config/widgets.yaml:ro"
      "${bookmarksYaml}:/app/config/bookmarks.yaml:ro"
      "${customCss}:/app/config/custom.css:ro"
    ];
  };
}
