{ pkgs, inputs, ... }:
let
  blender_5_1 = inputs.blender-bin.lib.mkBlender {
    pname = "blender-bin";
    version = "5.1.1";
    src = pkgs.fetchurl {
      url = "https://download.blender.org/release/Blender5.1/blender-5.1.1-linux-x64.tar.xz";
      hash = "sha256-b5//if7xVO95dNGhxLkWq0vB9WGLy0jVvv7hvQp8fyo=";
    };
  };
in
{
  environment.systemPackages = [
    blender_5_1
  ];
}
