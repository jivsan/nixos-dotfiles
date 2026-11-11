{ ... }:

let
  # neon accents, same as heimdall
  pink = "38;2;255;79;163";   # #ff4fa3
  cyan = "38;2;45;226;230";   # #2de2e6
in
{
  # heimdall's look (its logo, colours and icons) with the lines i had on mjolnir before,
  # plus the gpu and the temperatures
  programs.fastfetch = {
    enable = true;

    settings = {
      "$schema" = "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json";

      logo = {
        # pink to cyan gradient baked into the file (figlet -f slant NIXOS, truecolour per column),
        # the same file as heimdall's
        type = "file-raw";
        source = "${./mjolnir-logo.txt}";
        padding = { top = 1; right = 4; };
      };

      display = {
        separator = "  ";
        color.keys = cyan;
        percent.type = 9;   # coloured %, green to red by usage
      };

      modules = [
        { type = "title";    key = " user";    keyColor = pink; format = "{user-name}"; }
        { type = "uptime";   key = "󰔟 uptime";  keyColor = cyan; }
        { type = "os";       key = " distro";  keyColor = pink; }
        { type = "kernel";   key = " kernel";  keyColor = cyan; }
        { type = "terminal"; key = " term";    keyColor = pink; }
        { type = "shell";    key = " shell";   keyColor = cyan; }
        { type = "cpu";      key = "󰻠 cpu";     keyColor = pink; temp = true; }
        # the gpu and its temperature straight from the nvidia driver: fastfetch's own gpu line can't
        # find the driver's library on nixos, and with it it shows more than i want
        {
          type = "command";
          key = "󰢮 gpu";
          keyColor = cyan;
          text = "nvidia-smi --query-gpu=name,temperature.gpu --format=csv,noheader 2>/dev/null | awk -F', ' '{print $1 \" - \" $2 \"°C\"}' | grep . || echo 'no nvidia driver'";
        }
        { type = "disk";     key = "󰋊 disk";    keyColor = pink; }
        { type = "memory";   key = "󰑭 memory";  keyColor = cyan; }
        { type = "localip";  key = "󰩟 network"; keyColor = pink; showIpv4 = true; showIpv6 = false; showMac = false; }
        "break"
        { type = "colors";   key = " colors";  keyColor = cyan; symbol = "circle"; }
      ];
    };
  };
}
