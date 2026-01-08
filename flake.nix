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
          local-db-pipeline = pkgs.writeShellApplication {
            name = "local-db-pipeline";
            runtimeInputs = with pkgs; [
              awscli2
              coreutils
              curl
              findutils
              gnugrep
              gnutar
            ];
            text = ''
              set -euo pipefail

              repo_root="''${LOCAL_DB_REPO_ROOT:-$(pwd -P)}"
              scripts_dir="$repo_root/scripts"

              if [ ! -d "$scripts_dir" ]; then
                echo "❌ scripts directory not found at $scripts_dir"
                exit 1
              fi

              env_file="$repo_root/.env"
              if [ -f "$env_file" ]; then
                echo "📦 Loading environment variables from $env_file"
                set -a
                # shellcheck disable=SC1090
                source "$env_file"
                set +a
              else
                echo "⚠️  No .env file found at $env_file; relying on current environment"
              fi

              steps=(
                "sync.sh"
                "do-spaces-upload.sh"
                "cleanup.sh"
              )

              for script in "''${steps[@]}"; do
                echo
                echo "🚀 Running $script"
                "$scripts_dir/$script"
              done

              echo
              echo "✅ Local DB pipeline complete."
            '';
          };
        } // rainix.packages.${system};

        devShells = builtins.mapAttrs (_: addAwsCli) baseDevShells;
      });
}
