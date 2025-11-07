{
  description = "Flake for development workflows.";

  inputs = {
    rainix.url = "github:rainlanguage/rainix";
    rain.url = "github:rainlanguage/rain.cli";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.follows = "rainix/nixpkgs";
  };

  outputs = { self, flake-utils, rainix, rain, nixpkgs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        baseDevShells = rainix.devShells.${system};
        addAwsCli = shell:
          shell.overrideAttrs (old: {
            buildInputs = (old.buildInputs or []) ++ [ pkgs.awscli2 ];
          });
      in rec {
        packages = rec {
        } // rainix.packages.${system};

        devShells = builtins.mapAttrs (_: addAwsCli) baseDevShells;
      });
}
