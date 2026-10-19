{ ... }:
{
  services.picom = {
    enable = true;
    backend = "glx";

    activeOpacity = 1.0;
    inactiveOpacity = 0.9;

    fade = true;
    fadeSteps = [ 0.03 0.03 ];
    fadeDelta = 5;

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

    # fullscreen and these apps stay fully opaque, even when inactive
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
