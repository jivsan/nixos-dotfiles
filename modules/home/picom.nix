{ ... }:
{
  services.picom = {
    enable = true;
    backend = "glx";

    # Transparency
    activeOpacity = 1.0;
    inactiveOpacity = 0.9;

    # Fade animations
    fade = true;
    fadeSteps = [ 0.03 0.03 ];
    fadeDelta = 5;

    # Blur behind transparent windows
    settings = {
      blur = {
        method = "dual_kawase";
        strength = 5;
      };
      blur-background-exclude = [
        "window_type = 'dock'"
        "window_type = 'desktop'"
        "class_g = 'slop'"
        "class_g = 'maim'"
      ];
    };

    # Don't dim or change opacity for fullscreen windows
  opacityRules = [
    "100:fullscreen"
    "100:class_g = 'dmenu'"
    "100:class_g = 'slop'"
    "100:class_g = 'firefox'"
    "100:class_g = 'Brave-browser'"
    "100:class_g = 'discord'"
    "100:class_g = 'vesktop'"
    "100:class_g = 'Helium'"
   ];
  };
}
