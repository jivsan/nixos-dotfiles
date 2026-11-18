{ lib, pkgs, ... }:

# the engine for my wowsims forever page, https://sims.oryxserver.org. the page runs in my cluster
# (talos-helheim, kubernetes/apps/wowsims), and its route sends the page's sims here, so they run on
# mimir's cpu instead of on a 2 core worker. the same image as the page, built by ci in
# jivsan/wowsims-image from wowsims' source. it keeps nothing on disk: a running sim lives in its
# memory, so a restart loses it and i start it again on the page.
# when mimir is away the cluster's pod can be the engine too: one line in its httproute.yaml
let
  # the same tag and digest as kubernetes/apps/wowsims/deployment.yaml in talos-helheim: page and
  # engine talk in wowsims' own messages, and those change between builds. for each new build
  # renovate opens a pull request here and one there, i merge both the same day, this one first
  # and `deploy mimir` (.forgejo/renovate.json, the wowsims rule).
  # FILL-IN before the first deploy: the step "pushed" of the ci run in wowsims-image prints the
  # whole git.oryxserver.org/jivsan/wowsims-image:<tag>@sha256:<digest>. until then the check at
  # the bottom stops every build of mimir, ci's too
  image = "git.oryxserver.org/jivsan/wowsims-image:2026.11.18-173108-3633162@sha256:2c5595b9c8cb6018e26d9cdaa9409254cc325d492a1a2f3845298f4f1d53dc9a";

  # wowsims' own docker-compose.yml uses it too, and nothing else on mimir does
  port = 18790;

  # the engine's own podman network. nothing else is on it, and every connection that starts in it
  # is dropped (the mangle rule below): the engine only answers
  subnet = "10.89.77.0/24";
in
{
  # its own network, not podman's default one that comfyui, immich-ml and speaches share, so it
  # can't reach them either. no dns server in it: the engine looks up no names
  systemd.services.create-wowsims-network = {
    description = "Create the wowsims engine's podman network";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      podman network exists wowsims \
        || podman network create --interface-name wowsims0 --subnet ${subnet} --disable-dns wowsims
    '';
  };

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers.wowsims-engine = {
    inherit image;
    autoStart = true;

    # forgejo shows nothing without a login (REQUIRE_SIGNIN_VIEW), its registry neither. a token of
    # mine for mimir alone that can only read packages (forgejo, settings, applications: name
    # mimir-wowsims-pull, package: read, nothing else), root 0600 and never in git. on mimir:
    #   read -rsp 'token: ' t; echo; printf '%s' "$t" | sudo install -m 0600 /dev/stdin /var/lib/secrets/wowsims-pull-token; unset t
    # only a new tag needs it: a restart uses the image mimir already has
    login = {
      registry = "git.oryxserver.org";
      username = "jivsan";
      passwordFile = "/var/lib/secrets/wowsims-pull-token";
    };

    # on the lan address only, so tailscale's 100.x address has nothing on it. who gets in is the raw
    # rule below: traefik in the cluster, from the nodes
    ports = [ "10.0.20.18:${toString port}:8080" ];

    # the image's own command, written out so i see it here. --nvc: no version check on github,
    # it needs nothing outside, and gets nothing (the mangle rule below)
    cmd = [ "--usefs=false" "--launch=false" "--nvc" "--host=:8080" ];
    user = "10001:10001";
    capabilities.ALL = false;   # --cap-drop=ALL, it listens on 8080 inside and needs none

    # go cleans up harder before it gets near the memory cap below, instead of being killed mid sim
    environment.GOMEMLIMIT = "3GiB";

    extraOptions = [
      "--network=wowsims"
      # it writes nothing, like wowsims' docker-compose.yml runs it
      "--read-only"
      "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=64m"
      "--security-opt=no-new-privileges"
      # SIGINT is the only signal it stops cleanly on (it's in the image too, here so i see it)
      "--stop-signal=SIGINT"
      "--stop-timeout=10"
      # cpu: a sim is split into as many parts as go sees cpus (runtime.NumCPU, all 32 threads here),
      # and go runs as many at once as the cpu limit allows (GOMAXPROCS follows --cpus since go 1.25,
      # the image has 1.27; with the image on yggdrasil --cpus=2 gave 2, --cpus=3 gave 3). so all
      # sims together use at most 24 threads, and 8 always stay free for everything else: ssh,
      # deploys, the brain's embeddings and voice.
      # under that a low weight: when immich-ml, comfyui or speaches want cpu at the same time, they
      # get five times the engine's share. ci is in system.slice, the containers in machine.slice,
      # and those two split the box evenly when both want all of it, so ci keeps its half.
      # a Nice= or CPUWeight= on the systemd unit wouldn't reach the sim: podman puts the container in
      # its own cgroup under machine.slice, so it goes on podman's command line
      "--cpus=24"
      "--cgroup-conf=cpu.weight=20"
      # memory: 70-120 MB idle and 450 MB in a small batch on 4 cpus. a batch runs two candidates
      # per cpu at once, so 32 threads need more: a guess, checked after the first big batch
      # (podman stats). 4 GB, and the rest of mimir's 31 stays for comfyui, octane and the blender checks
      "--memory=4g"
      "--pids-limit=256"
    ];
  };

  systemd.services.podman-wowsims-engine = {
    after = [ "create-wowsims-network.service" ];
    requires = [ "create-wowsims-network.service" ];
    # a clean stop ends with 255 (or 0: two goroutines in sim/web/main.go race to exit): its stdin is
    # closed under podman -d, and on SIGINT it then exits with -1. without this every deploy that
    # restarts it leaves the unit failed (tried on yggdrasil with the same podman flags in a notify
    # unit, 2026-11-13)
    serviceConfig.SuccessExitStatus = "255";
  };

  # who gets in: only traefik in my cluster (and mimir itself, lo). a pod leaves with the address of the
  # node it runs on (cilium masquerades). traefik runs on the workers, talos-w1..w6 = 10.0.20.34-39, and
  # the range takes the control planes (.31-.33) too, in case it ever runs there, like forgejo.nix on
  # yggdrasil (nodes.yaml in talos-helheim; if the nodes change there, this range changes with them).
  # a published podman port is forwarded, so nixos-fw and allowedTCPPorts never see it, and tailscale's
  # ts-input accepts tailnet traffic before nixos-fw anyway: this sits in the raw table, before podman's
  # nat, like influxdb.nix on heimdall. only packets for 10.0.20.18 itself, so my containers can still
  # reach some other :18790 out there. no ip6tables line: the port is only on the ipv4 lan address.
  #
  # what the engine reaches: nothing. the same image in the cluster gets no egress either. a sim
  # request (or a bad wowsims commit) that does something it shouldn't can't open a connection to the
  # internet, my lan or the other containers. the mangle table sees a packet before podman's nat and
  # filter rules: every new connection from the engine's network is dropped there. its answers to
  # traefik belong to traefik's connection (conntrack: established), so they go out as before
  networking.firewall.extraCommands = ''
    iptables -t raw -N wowsims-only 2>/dev/null || iptables -t raw -F wowsims-only
    iptables -t raw -A wowsims-only -i lo -j RETURN
    iptables -t raw -A wowsims-only -i enp5s0 -m iprange --src-range 10.0.20.31-10.0.20.39 -j RETURN
    iptables -t raw -A wowsims-only -j DROP
    iptables -t raw -C PREROUTING -p tcp -d 10.0.20.18 --dport ${toString port} -j wowsims-only 2>/dev/null \
      || iptables -t raw -A PREROUTING -p tcp -d 10.0.20.18 --dport ${toString port} -j wowsims-only
    iptables -t mangle -C PREROUTING -s ${subnet} -m conntrack --ctstate NEW -j DROP 2>/dev/null \
      || iptables -t mangle -I PREROUTING -s ${subnet} -m conntrack --ctstate NEW -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -t raw -D PREROUTING -p tcp -d 10.0.20.18 --dport ${toString port} -j wowsims-only 2>/dev/null || true
    iptables -t raw -F wowsims-only 2>/dev/null || true
    iptables -t raw -X wowsims-only 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s ${subnet} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
  '';

  # the image line above, filled in. a FILL-IN would evaluate and build fine and only fail at the
  # deploy, when podman can't pull it
  assertions = [{
    assertion = !(lib.hasInfix "FILL-IN" image);
    message = "hosts/mimir/modules/system/wowsims.nix: fill in the image line from the ci run in wowsims-image (its step \"pushed\")";
  }];
}
