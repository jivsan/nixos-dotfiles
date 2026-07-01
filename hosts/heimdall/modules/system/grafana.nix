{ pkgs, ... }:
let
  grafanaBackupDir = "/mnt/nas/nix-services/grafana-backups";

  grafanaProvisioning = pkgs.runCommand "grafana-provisioning" {} ''
    mkdir -p $out/datasources $out/dashboards $out/dashboards-json
    cat > $out/datasources/datasources.yaml <<'EOF'
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://host.containers.internal:9090
        isDefault: true
        uid: prometheus
        editable: false
      - name: Loki
        type: loki
        access: proxy
        url: http://host.containers.internal:3100
        uid: loki
        editable: false
    EOF
    cat > $out/dashboards/dashboards.yaml <<'EOF'
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /etc/grafana/provisioning/dashboards-json
    EOF
    cp ${./switch-dashboard.json} $out/dashboards-json/switch.json
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana 0750 472 472 -"
    "d ${grafanaBackupDir} 0775 christina users -"
  ];

  virtualisation.oci-containers.containers.grafana = {
    image = "docker.io/grafana/grafana-oss:latest";
    autoStart = true;
    ports = [ "127.0.0.1:3002:3000" ];
    environmentFiles = [ "/var/lib/secrets/grafana.env" ];
    environment = {
      GF_SERVER_ROOT_URL = "https://grafana.oryxserver.org";
      GF_SECURITY_COOKIE_SECURE = "true";
      GF_USERS_ALLOW_SIGN_UP = "false";
      GF_ANALYTICS_REPORTING_ENABLED = "false";
      GF_ANALYTICS_CHECK_FOR_UPDATES = "false";
    };
    volumes = [
      "/var/lib/grafana:/var/lib/grafana"
      "${grafanaProvisioning}:/etc/grafana/provisioning:ro"
    ];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
  };

  systemd.services.grafana-db-backup = {
    description = "Back up Grafana database to TrueNAS";
    path = [ pkgs.sqlite pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    unitConfig.RequiresMountsFor = [ grafanaBackupDir ];
    script = ''
      mkdir -p ${grafanaBackupDir}
      if [ -f /var/lib/grafana/grafana.db ]; then
        sqlite3 /var/lib/grafana/grafana.db ".backup '${grafanaBackupDir}/grafana-$(date +%F-%H%M%S).db'"
        find ${grafanaBackupDir} -type f -name 'grafana-*.db' -mtime +30 -delete
      fi
    '';
  };

  systemd.timers.grafana-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
