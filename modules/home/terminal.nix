{ ... }:

{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        opacity = 0.94;
        padding = { x = 10; y = 8; };
      };

      font = {
        size = 11.5;
        normal = {
          family = "JetBrainsMono Nerd Font";
          style = "Regular";
        };
        bold = {
          family = "JetBrainsMono Nerd Font";
          style = "Bold";
        };
        italic = {
          family = "JetBrainsMono Nerd Font";
          style = "Italic";
        };
      };

      colors = {
        primary = {
          background = "#1E2430";
          foreground = "#D8DEE9";
        };

        cursor = {
          text = "#1E2430";
          cursor = "#EBCB8B";
        };

        selection = {
          text = "#D8DEE9";
          background = "#3B4252";
        };

        normal = {
          black = "#2B303B";
          red = "#FF4FA3";
          green = "#7FDBCA";
          yellow = "#EBCB8B";
          blue = "#5E81AC";
          magenta = "#FF4FA3";
          cyan = "#2DE2E6";
          white = "#D8DEE9";
        };

        bright = {
          black = "#4C566A";
          red = "#FF79C6";
          green = "#8FBCBB";
          yellow = "#FFE08A";
          blue = "#81A1C1";
          magenta = "#FF79C6";
          cyan = "#62F3F5";
          white = "#ECEFF4";
        };
      };
    };
  };
}
