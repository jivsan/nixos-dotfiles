{ pkgs, ... }:
let
  grafanaProvisioning = pkgs.runCommand "grafana-provisioning" {} ''
    mkdir -p $out/datasources $out/dashboards $out/dashboards-json $out/alerting

    # every grafana alert goes to the ntfy topic "alerts" (ntfy.nix); $NTFY_TOKEN comes from ntfy-publish.env
    cat > $out/alerting/ntfy.yaml <<'EOF'
    apiVersion: 1
    contactPoints:
      - orgId: 1
        name: ntfy
        receivers:
          - uid: ntfy-alerts
            type: webhook
            settings:
              url: http://host.containers.internal:2586/alerts?template=grafana
              httpMethod: POST
              authorization_scheme: Bearer
              authorization_credentials: $NTFY_TOKEN
    policies:
      - orgId: 1
        receiver: ntfy
        group_by: [grafana_folder, alertname]
    EOF
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
      - name: InfluxDB
        type: influxdb
        access: proxy
        url: http://host.containers.internal:8086
        database: pfsense
        uid: influxdb
        isDefault: false
        jsonData:
          timeInterval: "10s"
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
    cp ${./pfsense-geomap-dashboard.json} $out/dashboards-json/pfsense-geomap.json
    cp ${./ai-gateway-dashboard.json} $out/dashboards-json/ai-gateway.json
    # these two were made in the web page; saved as files 2026-10-22 when grafana moved to appdb
    cp ${./node-exporter-full-dashboard.json} $out/dashboards-json/node-exporter-full.json
    cp ${./pfsense-system-dashboard.json} $out/dashboards-json/pfsense-system.json
  '';
in
{
  # grafana's database is in appdb on odyn since 2026-10-22 (started fresh: every dashboard,
  # datasource and the ntfy contact point come from the files above, the admin from grafana.env).
  # /var/lib/grafana keeps only plugins and caches
  systemd.tmpfiles.rules = [
    "d /var/lib/grafana 0750 472 472 -"
  ];

  virtualisation.oci-containers.containers.grafana = {
    image = "docker.io/grafana/grafana:13.2.4@sha256:dbbc38ea21103cefb50396340cd88afec779c7e070b0a7bf5a75b4ce46651d3f";   # grafana-oss stopped getting updates at 13.0.2
    autoStart = true;
    ports = [ "127.0.0.1:3002:3000" ];
    environmentFiles = [
      "/var/lib/secrets/grafana.env"
      "/var/lib/secrets/ntfy-publish.env"   # NTFY_TOKEN for the ntfy contact point
      "/var/lib/secrets/grafana-db.env"     # GF_DATABASE_PASSWORD (its appdb role) + GF_SECURITY_SECRET_KEY
    ];
    environment = {
      GF_SERVER_ROOT_URL = "https://grafana.oryxserver.org";
      GF_SECURITY_COOKIE_SECURE = "true";
      GF_USERS_ALLOW_SIGN_UP = "false";
      GF_ANALYTICS_REPORTING_ENABLED = "false";
      GF_ANALYTICS_CHECK_FOR_UPDATES = "false";

      # appdb on odyn (odyn/apps/appdb), checked against its certificate
      GF_DATABASE_TYPE = "postgres";
      GF_DATABASE_HOST = "10.0.20.6:5432";
      GF_DATABASE_NAME = "grafana";
      GF_DATABASE_USER = "grafana";
      GF_DATABASE_SSL_MODE = "verify-full";
      GF_DATABASE_CA_CERT_PATH = "/etc/appdb/ca.crt";
      GF_DATABASE_MAX_OPEN_CONN = "10";      # its role allows 15
      GF_DATABASE_MAX_IDLE_CONN = "2";
    };
    volumes = [
      "/var/lib/grafana:/var/lib/grafana"
      "${grafanaProvisioning}:/etc/grafana/provisioning:ro"
      "/etc/appdb/ca.crt:/etc/appdb/ca.crt:ro"
    ];
    extraOptions = [
      "--add-host=host.containers.internal:host-gateway"
    ];
  };

  # no backup job here any more: yggdrasil's appdb-backup dumps the grafana database every night
}
