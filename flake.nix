{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = rec {
          inherit (pkgs) hello;
          default = hello;
        };
        checks = {
          formatting = pkgs.runCommandNoCC "stylua-check" { } ''
            cd ${./.}
            mkdir $out
            ${pkgs.lib.getExe pkgs.stylua} . -c
          '';
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              statix.enable = true;
              nixpkgs-fmt.enable = true;
              stylua.enable = true;
              deadnix.enable = true;
            };
          };
        };
        # nix fmt's docs say this should only be for *.nix files but we're ignoring that as that's inconvenient
        # See https://github.com/NixOS/nix/issues/9132#issuecomment-1754999829
        formatter = pkgs.writeShellApplication {
          name = "run-formatters";
          runtimeInputs = [ pkgs.stylua pkgs.nixpkgs-fmt ];
          text = ''
            set -xeu
            nixpkgs-fmt "$@"
            stylua "$@"
          '';
        };
        devShells = rec {
          lua = pkgs.mkShell {
            buildInputs = [
              pkgs.subversion # for dev-setup script
              pkgs.zip
              pkgs.stylua

              (pkgs.luajit.withPackages
                (ps: with ps; [ luasocket lpeg inspect luaunit tl ]))
            ];
            inherit (self.checks.${system}.pre-commit-check) shellHook;
          };
          default = lua;
        };
      });
}
