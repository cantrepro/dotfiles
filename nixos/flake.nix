{
  description = "Modern Flakes-based NixOS + Home Manager dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      hostVarsPath =
        if builtins.pathExists ./hosts/default/host-vars.nix
        then ./hosts/default/host-vars.nix
        else ./hosts/default/host-vars.template.nix;
      hostVars = import hostVarsPath;

      hardwareModule =
        if builtins.pathExists ./hosts/default/hardware-configuration.nix
        then ./hosts/default/hardware-configuration.nix
        else ({ ... }: { });

      system = hostVars.system;
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      formatter.${system} = pkgs.nixfmt-rfc-style;

      nixosConfigurations.default = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit self hostVars;
        };
        modules = [
          hardwareModule
          ./hosts/default/configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = {
              inherit self hostVars;
            };
            home-manager.users.${hostVars.userName} = import ./modules/home/default.nix;
          }
        ];
      };

      homeConfigurations."${hostVars.userName}@${hostVars.hostName}" =
        home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            inherit self hostVars;
          };
          modules = [
            ./modules/home/default.nix
          ];
        };
    };
}
