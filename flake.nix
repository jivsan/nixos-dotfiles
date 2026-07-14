{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland.url = "github:hyprwm/Hyprland/v0.55.0";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
    oxwm = {
      url = "github:tonybanters/oxwm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    helium = {
      url = "github:AlvaroParker/helium-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    blender-bin = {
      url = "github:edolstra/nix-warez?dir=blender";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-code = {
      url = "github:sadjow/claude-code-nix";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };
    hlidskjalf = {
      url = "github:jivsan/Hlidskjalf";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager, oxwm, claude-code, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      mkHost = hostPath: homeFile: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs;
          pkgs-unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
        };
        modules = [
          hostPath
          home-manager.nixosModules.home-manager
          {
            nixpkgs.hostPlatform = system;
            nixpkgs.overlays = [ claude-code.overlays.default ];
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              users.christina = import homeFile;
              backupFileExtension = "backup";
              extraSpecialArgs = { inherit inputs; };
            };
          }
        ];
      };
    in
    {
      devShells.${system}.suckless = pkgs.mkShell {
        packages = with pkgs; [
          pkg-config
          libx11
          libxft
          libxinerama
          fontconfig
          freetype
          harfbuzz
          gcc
          gnumake
        ];
      };
      nixosConfigurations = {
        mjolnir  = mkHost ./hosts/mjolnir/default.nix  ./hosts/mjolnir/home.nix;
        heimdall = mkHost ./hosts/heimdall/default.nix ./hosts/heimdall/home.nix;
        mimir    = mkHost ./hosts/mimir/default.nix    ./hosts/mimir/home.nix;
      };
    };
}
