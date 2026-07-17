{ ... }:

let
  # Fleet neon accents (same family as mimir/tyr)
  pink = "38;2;255;79;163";   # #ff4fa3
  cyan = "38;2;45;226;230";   # #2de2e6
  dim  = "38;2;99;99;125";    # muted steel
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";

      logo = {
        # "NIXOS" slant lettering, pink → cyan gradient baked into the file
        # (regenerate: figlet -f slant NIXOS + per-column truecolor interpolation)
        type = "file-raw";
        source = "${./heimdall-logo.txt}";
        padding = { top = 1; right = 4; };
      };

      display = {
        separator = "  ";
        color.keys = cyan;
        percent.type = 9;   # colored % — green → yellow → red by usage
      };

      modules = [
        # ── identity ──────────────────────────────────────────────
        { type = "title"; color = { user = pink; at = dim; host = cyan; }; }
        { type = "custom"; format = "{#${dim}}⟨ {#${pink}}heimdall{#${dim}} :: watcher of the bifrǫst — services node ⟩"; }
        { type = "separator"; string = "─"; }
        { type = "os";       key = " os";      keyColor = pink; }
        { type = "kernel";   key = " kernel";  keyColor = cyan; }
        { type = "packages"; key = "󰏖 pkgs";    keyColor = pink; }
        { type = "shell";    key = " shell";   keyColor = cyan; }
        { type = "uptime";   key = "󰔟 uptime";  keyColor = pink; }
        { type = "loadavg";  key = "󰓅 load";    keyColor = cyan; }
        "break"

        # ── lab — what a services box cares about ─────────────────
        {
          type = "command";
          key = "󰜉 gen";
          keyColor = pink;
          text = "readlink /nix/var/nix/profiles/system | grep -o '[0-9]\\+' | head -1 | xargs -I{} echo 'generation {}'";
        }
        {
          type = "command";
          key = "󰚰 drift";
          keyColor = cyan;
          text = "timeout 2 git -C ~/nixos-dotfiles fetch -q origin main 2>/dev/null; b=$(git -C ~/nixos-dotfiles rev-list --count HEAD..origin/main 2>/dev/null); [ \"$b\" = 0 ] && echo 'in sync with main' || echo \"$b commit(s) behind main\"";
        }
        {
          type = "command";
          key = "󰒋 units";
          keyColor = pink;
          text = "f=$(systemctl --failed --no-legend | wc -l); [ \"$f\" = 0 ] && echo 'all green' || echo \"$f FAILED\"";
        }
        {
          type = "command";
          key = "󰡨 podman";
          keyColor = cyan;
          text = "sudo -n podman ps -q 2>/dev/null | wc -l | awk '{print $1 \" containers up\"}'";
        }
        {
          type = "command";
          key = "󰑪 traefik";
          keyColor = pink;
          text = "systemctl is-active traefik.service 2>/dev/null; curl -ksS --max-time 2 https://immich.oryxserver.org >/dev/null 2>&1 && echo '  immich edge online' || echo '  immich edge UNREACHABLE'";
        }
        "break"

        # ── hardware ──────────────────────────────────────────────
        { type = "cpu";    key = "󰻠 cpu";    keyColor = pink;  format = "{name} ({cores-logical}t)"; }
        { type = "memory"; key = "󰑭 memory"; keyColor = cyan; }
        { type = "swap";   key = "󰓡 swap";   keyColor = pink; }
        { type = "disk";   key = "󰋊 disk";   keyColor = cyan;  folders = "/"; }
        {
          type = "command";
          key = "󰉓 nas";
          keyColor = pink;
          text = "findmnt -rn -t nfs,nfs4 | wc -l | awk '{print $1 \" odyn mounts\"}'";
        }
        "break"

        # ── network ───────────────────────────────────────────────
        {
          type = "localip";
          key = "󰩟 network";
          keyColor = cyan;
          showPrefixLen = true;
          namePrefix = "en";     # ens*/eno* only — hides lo, tailscale, podman veths
        }
        {
          type = "command";
          key = "󰖂 tailnet";
          keyColor = pink;
          text = "tailscale ip -4 2>/dev/null || echo offline";
        }
        "break"

        { type = "colors"; paddingLeft = 2; symbol = "circle"; }
      ];
    };
  };
}
