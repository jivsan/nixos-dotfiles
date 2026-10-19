{ ... }:

let
  # fleet accent colours
  pink = "38;2;255;79;163";   # #ff4fa3
  cyan = "38;2;45;226;230";   # #2de2e6
in
{
  programs.fastfetch = {
    enable = true;

    settings = {
      "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";

      logo = {
        source = "nixos";
        padding = { top = 1; right = 4; };
        # the snowflake's two blues become cyan + pink
        color = { "1" = cyan; "2" = pink; };
      };

      display = {
        separator = "  ";
        color.keys = cyan;
        percent.type = 9;   # percent coloured green to yellow to red by usage
      };

      modules = [
        # identity
        { type = "title"; color = { user = pink; at = cyan; host = cyan; }; }
        { type = "separator"; string = "─"; }
        { type = "os";       key = " os";      keyColor = pink; }
        { type = "kernel";   key = " kernel";  keyColor = cyan; }
        { type = "packages"; key = "󰏖 pkgs";    keyColor = pink; }
        { type = "shell";    key = " shell";   keyColor = cyan; }
        { type = "uptime";   key = "󰔟 uptime";  keyColor = pink; }
        { type = "loadavg";  key = "󰓅 load";    keyColor = cyan; }
        "break"

        # hardware
        { type = "board";  key = "󰇄 board";  keyColor = pink; }
        { type = "cpu";    key = "󰻠 cpu";    keyColor = cyan;  temp = true; }
        { type = "gpu";    key = "󰢮 gpu";    keyColor = pink;  temp = true; driverSpecific = true; }
        { type = "memory"; key = "󰑭 memory"; keyColor = cyan; }
        { type = "swap";   key = "󰓡 swap";   keyColor = pink; }
        "break"

        # storage
        { type = "disk";   key = "󰋊 disk";   keyColor = cyan; }
        { type = "zpool";  key = " zpool";  keyColor = pink; }
        "break"

        # network
        {
          type = "localip";
          key = "󰩟 network";
          keyColor = cyan;
          showPrefixLen = true;   # shows 10.0.20.18/24
          namePrefix = "en";      # en* only, hides lo, tailscale and veths
        }
        "break"

        { type = "colors"; paddingLeft = 2; symbol = "circle"; }
      ];
    };
  };
}
