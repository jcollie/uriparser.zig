# SPDX-FileCopyrightText: © 2024 Jeffrey C. Ollie
# SPDX-License-Identifier: MIT

{
  inputs = {
    nixpkgs = {
      url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    };
    zig = {
      url = "git+https://git.ocjtech.us/jeff/zig-overlay.git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
      ...
    }:
    let
      packages =
        system:
        import nixpkgs {
          inherit system;
        };
      forAllSystems = (
        function:
        nixpkgs.lib.genAttrs [
          "aarch64-linux"
          "aarch64-darwin"
          "x86_64-linux"
          "x86_64-darwin"
        ] (system: function (packages system))
      );
    in
    {
      devShells = forAllSystems (pkgs: {
        name = "uriparser.zig";
        master = pkgs.mkShell {
          name = "uriparser.zig";
          nativeBuildInputs = [
            zig.packages.${pkgs.stdenv.hostPlatform.system}.master
            pkgs.regctl
            pkgs.reuse
          ];
        };
        default = self.devShells.${pkgs.stdenv.hostPlatform.system}.master;
      });
    };
}
