{ ... }:
# Bifrost-only alacritty: colder cyan palette + more transparency so the
# frosted glass / cyan wallpaper shows through. mjolnir keeps its own
# modules/home/terminal.nix.
{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        opacity = 0.85;            # lower = more glass; raise toward 1.0 if text is hard to read
        padding = { x = 12; y = 10; };
      };

      font = {
        size = 11.5;
        normal = { family = "JetBrainsMono Nerd Font"; style = "Regular"; };
        bold   = { family = "JetBrainsMono Nerd Font"; style = "Bold"; };
        italic = { family = "JetBrainsMono Nerd Font"; style = "Italic"; };
      };

      colors = {
        primary   = { background = "#11131a"; foreground = "#c8d3f5"; };
        cursor    = { text = "#11131a"; cursor = "#7df9ff"; };
        selection = { text = "#c8d3f5"; background = "#2a2f44"; };
        normal = {
          black = "#1b1f2a"; red = "#ff5c8a"; green = "#8bffb0"; yellow = "#9ece6a";
          blue = "#7aa2f7"; magenta = "#c099ff"; cyan = "#7df9ff"; white = "#c8d3f5";
        };
        bright = {
          black = "#444b6a"; red = "#ff7aa2"; green = "#a7ffbf"; yellow = "#c3e88d";
          blue = "#9ab8ff"; magenta = "#d2a8ff"; cyan = "#9efcff"; white = "#e6e9ff";
        };
      };
    };
  };
}
