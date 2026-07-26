{
  description = "Automatically updated x86_64-linux sing-box package and binary cache";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      singBox = pkgs.callPackage ./package.nix { };
      cacheUrl = "https://rannj-nixos.cachix.org";
      cachePublicKey = "rannj-nixos.cachix.org-1:gpiOHG8mVVoIvgYtTf5cGj3pykTxCcGEM9ErtS5xkqI=";
    in
    {
      packages.${system} = {
        sing-box = singBox;
        default = singBox;
      };

      checks.${system} = {
        sing-box = singBox;

        updater = pkgs.runCommand "check-sing-box-updater" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.jq
            pkgs.shellcheck
          ];
        } ''
          shellcheck -x \
            ${self.outPath}/scripts/update-sing-box.sh \
            ${self.outPath}/tests/update-sing-box.sh
          bash ${self.outPath}/tests/update-sing-box.sh
          touch "$out"
        '';

        workflow = pkgs.runCommand "check-github-workflows" {
          nativeBuildInputs = [ pkgs.actionlint ];
        } ''
          actionlint \
            ${self.outPath}/.github/workflows/check.yml \
            ${self.outPath}/.github/workflows/update-cache.yml
          touch "$out"
        '';
      };

      formatter.${system} = pkgs.nixfmt;

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.actionlint
          pkgs.curl
          pkgs.gawk
          pkgs.gh
          pkgs.gnused
          pkgs.jq
          pkgs.nixfmt
          pkgs.shellcheck
        ];
      };

      nixosModules.default =
        {
          lib,
          pkgs,
          ...
        }:
        {
          assertions = [
            {
              assertion = pkgs.stdenv.hostPlatform.system == system;
              message = "This sing-box cache only supports x86_64-linux.";
            }
          ];

          services.sing-box.package = lib.mkDefault self.packages.${system}.sing-box;

          nix.settings = {
            extra-substituters = [ cacheUrl ];
            extra-trusted-public-keys = [ cachePublicKey ];
          };
        };
    };
}
