{
  description = "FlClashX binary package and NixOS integration without source patches";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      package = pkgs.callPackage ./package.nix { };
      testSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          { programs.flclashx.enable = true; }
        ];
      };
    in
    {
      packages.${system} = {
        default = package;
        flclashx = package;
      };
      nixosModules.default = import ./module.nix;
      checks.${system} = {
        package = package;
        installer = testSystem.config.system.build.flclashxInstaller;
      };
      formatter.${system} = pkgs.nixfmt-tree;
    };
}
