{ config, lib, pkgs, ... }:

# pearl (prl) mining on the 4060 ti for my kryptex account (pool.kryptex.com, paid out as btc/usdt).
# krig is kryptex's own miner (0% fee, closed source), so it runs as a throwaway user in a tight sandbox.
# the card is shared: krig-yield stops the miner as soon as anything else computes on the card or holds
# more than 1 gb (comfyui, octane, embeddings, whisper, blender tests) and starts it again after 5 idle minutes.
# stop mining: sudo systemctl stop krig-yield (takes the miner with it), start: sudo systemctl start krig-yield
# my kryptex username (krx…) is in /var/lib/secrets/krig-user on this box (root 0600), never in git
let
  userFile = "/var/lib/secrets/krig-user";
  pool = "stratum+ssl://prl.kryptex.network:8048";
  worker = "mimir";
  idleMinutes = 5;

  # new release: bump the version, set hash = lib.fakeHash, the first build prints the right one
  krig = pkgs.stdenv.mkDerivation rec {
    pname = "krig-miner";
    version = "1.6.0";
    src = pkgs.fetchurl {
      url = "https://github.com/kryptex/krig-miner/releases/download/v${version}/krig-miner-${version}-linux-x64.tar.gz";
      hash = "sha256-kTc4jVxL+4Q73ou5bjdpVEaSTfwATrPedqcf0ZVuSgQ=";
    };
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    # it loads openssl (for the ssl pool) and the driver's libcuda itself, so both go on its library path
    runtimeDependencies = [ (lib.getLib pkgs.openssl) ];
    appendRunpaths = [ "${pkgs.addDriverRunpath.driverLink}/lib" ];
    # only the miner: the other file in the tarball is for intel arc cards
    installPhase = "install -Dm755 krig-miner $out/bin/krig-miner";
    meta.license = lib.licenses.unfree;
  };

  start = pkgs.writeShellScript "krig-miner-start" ''
    user=$(${pkgs.coreutils}/bin/tr -d ' \n' < "$CREDENTIALS_DIRECTORY/user")
    exec ${krig}/bin/krig-miner --url ${pool} --user "$user/${worker}" \
      --no-rocm --no-intel --no-tui --api-port 12000 --api-host 127.0.0.1
  '';

  smi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  yield = pkgs.writeShellScript "krig-yield" ''
    last=$(date +%s)   # after a boot or restart the card has to be free for the idle time first
    warned=""
    while true; do
      now=$(date +%s)
      # the miner's own processes don't count
      cg=$(systemctl show -p ControlGroup --value krig-miner.service)
      mine=" "
      [ -n "$cg" ] && mine=" $(tr '\n' ' ' < "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null) "
      busy=""
      # anything else computing on the card right now
      while read -r _ pid _ sm _; do
        case "$mine" in *" $pid "*) continue ;; esac
        if [[ $sm =~ ^[0-9]+$ ]] && (( sm > 0 )); then busy="$(ps -o comm= -p "$pid") computes ($sm%)"; fi
      done < <(${smi} pmon -c 1 -s u | grep -v '^#')
      # or holding a loaded model or scene
      while IFS=', ' read -r pid mem; do
        case "$mine" in *" $pid "*) continue ;; esac
        if [[ $mem =~ ^[0-9]+$ ]] && (( mem > 1024 )); then busy="$(ps -o comm= -p "$pid") holds $mem MiB"; fi
      done < <(${smi} --query-compute-apps=pid,used_memory --format=csv,noheader,nounits)

      if [ -n "$busy" ]; then
        last=$now
        if systemctl is-active -q krig-miner; then
          echo "card busy: $busy, pausing the miner"
          systemctl stop krig-miner
        fi
      elif (( now - last >= ${toString (idleMinutes * 60)} )) && ! systemctl is-active -q krig-miner; then
        if systemctl is-failed -q krig-miner; then
          # a broken miner (wrong username, pool down) isn't started again every 10 s
          [ -z "$warned" ] && echo "krig-miner has failed, not starting it: journalctl -u krig-miner, then restart krig-yield"
          warned=1
        else
          echo "card free for ${toString idleMinutes} min, mining"
          systemctl start krig-miner
        fi
      fi
      sleep 10
    done
  '';
in
{
  systemd.services.krig-miner = {
    description = "krig: pearl miner on the 4060 ti for pool.kryptex.com";
    # no wantedBy: krig-yield starts it when the card is free, and stopping krig-yield stops it
    partOf = [ "krig-yield.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = start;
      DynamicUser = true;
      LoadCredential = "user:${userFile}";
      StateDirectory = "krig-miner";
      WorkingDirectory = "/var/lib/krig-miner";
      Environment = [ "HOME=/var/lib/krig-miner" ];   # the driver keeps its compiled kernels in ~/.nv
      Restart = "on-failure";
      RestartSec = 30;
      Nice = 10;
      # it only needs the card and the pool (tested with --list-devices in this sandbox)
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
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
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      UMask = "0077";
    };
  };

  systemd.services.krig-yield = {
    description = "mine pearl only while nothing else uses mimir's card";
    wantedBy = [ "multi-user.target" ];
    after = [ "nvidia-persistenced.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    # no kryptex username yet: nothing to mine for
    unitConfig.ConditionPathExists = userFile;
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.procps config.systemd.package ];
    serviceConfig = {
      ExecStartPre = "-${config.systemd.package}/bin/systemctl reset-failed krig-miner.service";
      ExecStart = yield;
      Restart = "always";
      RestartSec = 30;
    };
  };
}
