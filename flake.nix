{
  description = "Flake for local DB remote workflows.";

  inputs = {
    rainix.url = "github:rainlanguage/rainix";
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.follows = "rainix/nixpkgs";
    nixpkgs-tailscale.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    ragenix.url = "github:yaxitech/ragenix";
    deploy-rs.url = "github:serokell/deploy-rs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "rainix/nixpkgs";

    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "rainix/nixpkgs";
  };

  outputs = { self, flake-utils, rainix, nixpkgs, nixpkgs-tailscale, ragenix
    , deploy-rs, disko, nixos-anywhere, ... }:
    let deploySystem = "x86_64-linux";
    in {
      nixosConfigurations.local-db-remote =
        let tailscalePkgs = import nixpkgs-tailscale { system = deploySystem; };
        in rainix.inputs.nixpkgs.lib.nixosSystem {
          system = deploySystem;
          specialArgs = { inherit self tailscalePkgs; };
          modules = [ disko.nixosModules.disko ./os.nix ];
        };

      deploy = (import ./deploy.nix { inherit deploy-rs self; }).config;
      checks.${deploySystem} =
        deploy-rs.lib.${deploySystem}.deployChecks self.deploy;
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (pkgs.lib.getName pkg) [ "terraform" ];
        };
        buildPkgs = import nixpkgs-tailscale { inherit system; };

        baseDevShells = rainix.devShells.${system};
        rainixPkgs = rainix.packages.${system};

        addBuildInputs = shell: extraInputs:
          shell.overrideAttrs
          (old: { buildInputs = (old.buildInputs or [ ]) ++ extraInputs; });

        repoRootSetup = ''
          repo_root="''${LOCAL_DB_REPO_ROOT:-$(pwd -P)}"
        '';

        raindexSetup = ''
          ${repoRootSetup}
          raindex_root="$repo_root/lib/raindex"
          raindex_manifest="$raindex_root/Cargo.toml"

          if [ ! -f "$raindex_manifest" ]; then
            echo "❌ Raindex submodule not found at $raindex_manifest"
            echo "   Run: git submodule update --init --recursive"
            exit 1
          fi
        '';

        envSetup = ''
          env_file="$repo_root/.env"

          load_env_file() {
            if [ "''${LOCAL_DB_ENV_LOADED:-0}" = "1" ]; then
              return 0
            fi

            if [ -f "$env_file" ]; then
              echo "📦 Loading environment variables from $env_file"
              set -a
              # shellcheck disable=SC1090
              source "$env_file"
              set +a
            else
              echo "⚠️  No .env file found at $env_file; relying on current environment"
            fi

            export LOCAL_DB_ENV_LOADED=1
          }
        '';

        shellHelpers = ''
          require_var() {
            local name="$1"
            if [ -z "''${!name:-}" ]; then
              echo "❌ Missing required environment variable: $name"
              exit 1
            fi
          }

          resolve_manifest_publish_target() {
            local urls first_url

            urls="$("$cli_bin" local-db manifest-urls --settings-yaml "$settings_yaml")"
            first_url=""

            while IFS= read -r url; do
              if [ -n "$url" ]; then
                first_url="$url"
                break
              fi
            done <<<"$urls"

            if [ -z "$first_url" ]; then
              echo "❌ Expected at least one local-db remote manifest URL"
              exit 1
            fi

            manifest_url="$first_url"
            manifest_dir_url="''${manifest_url%/*}"

            if [ "$manifest_dir_url" = "$manifest_url" ]; then
              echo "❌ Manifest URL does not contain a publish directory: $manifest_url"
              exit 1
            fi
          }

          url_host() {
            local without_scheme="$1"
            without_scheme="''${without_scheme#http://}"
            without_scheme="''${without_scheme#https://}"
            printf '%s\n' "''${without_scheme%%/*}"
          }

          url_path() {
            local without_scheme="$1"
            without_scheme="''${without_scheme#http://}"
            without_scheme="''${without_scheme#https://}"

            case "$without_scheme" in
              */*) printf '/%s\n' "''${without_scheme#*/}" ;;
              *) printf '\n' ;;
            esac
          }

          object_key_from_url() {
            local url="$1"
            local host path endpoint_host

            host="$(url_host "$url")"
            path="$(url_path "$url")"
            endpoint_host="$(url_host "$SPACES_ENDPOINT")"

            case "$host" in
              "$SPACES_BUCKET.$endpoint_host")
                printf '%s\n' "''${path#/}"
                ;;
              "$endpoint_host")
                case "$path" in
                  "/$SPACES_BUCKET/"*)
                    printf '%s\n' "''${path#/"$SPACES_BUCKET"/}"
                    ;;
                  *)
                    echo "Manifest URL path is not inside bucket $SPACES_BUCKET: $url" >&2
                    exit 1
                    ;;
                esac
                ;;
              *)
                echo "Manifest URL host does not match bucket endpoint: $url" >&2
                exit 1
                ;;
            esac
          }

        '';

        buildRaindexCliCommand = pkgs.writeShellApplication {
          name = "build-raindex-cli";
          runtimeInputs = with pkgs; [
            buildPkgs.cargo
            coreutils
            gmp
            gnused
            openssl
            pkg-config
            buildPkgs.rustc
            sqlite
          ];
          text = ''
            set -euo pipefail
            ${raindexSetup}

            export CPATH="${pkgs.gmp.dev}/include''${CPATH:+:$CPATH}"
            export LIBRARY_PATH="${pkgs.gmp}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
            export PKG_CONFIG_PATH="${pkgs.gmp.dev}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export RUSTFLAGS="-L native=${pkgs.gmp}/lib ''${RUSTFLAGS:-}"
            export OPENSSL_DIR="${pkgs.openssl.dev}"
            export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"
            export OPENSSL_INCLUDE_DIR="${pkgs.openssl.dev}/include"
            COMMIT_SHA="$(git -C "$raindex_root" rev-parse HEAD)"
            export COMMIT_SHA

            target_triple="$(rustc -vV | sed -n 's/^host: //p')"

            case "$target_triple" in
              aarch64-apple-darwin|x86_64-apple-darwin|x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu)
                ;;
              *)
                echo "❌ Unsupported host target: $target_triple"
                exit 1
                ;;
            esac

            binary_source="$raindex_root/target/$target_triple/release/raindex_cli"
            binary_output="$repo_root/rain-orderbook-cli"

            echo "Building local raindex CLI artifact..."
            cargo build --release --manifest-path "$raindex_manifest" -p raindex_cli --target "$target_triple"

            cp "$binary_source" "$binary_output"
            chmod 755 "$binary_output"
            strip "$binary_output" || true

            echo "Setup complete!"
          '';
        };

        localDbSyncCommand = pkgs.writeShellApplication {
          name = "local-db-sync";
          runtimeInputs = with pkgs; [ coreutils curl ];
          text = ''
            set -euo pipefail
            ${raindexSetup}
            ${envSetup}
            ${shellHelpers}

            load_env_file

            require_var SETTINGS_YAML_URL
            require_var HYPER_RPC_API_TOKEN

            cli_bin="$repo_root/rain-orderbook-cli"
            if [ ! -x "$cli_bin" ]; then
              echo "❌ Local CLI artifact missing at $cli_bin"
              echo "   Run: nix run .#build-raindex-cli"
              exit 1
            fi

            out_root="$repo_root/local-db"

            echo "🌐 Fetching settings YAML from $SETTINGS_YAML_URL"
            settings_yaml="$(curl -fsSL "$SETTINGS_YAML_URL")"
            resolve_manifest_publish_target

            echo "🚀 Running local-db sync via $cli_bin"
            "$cli_bin" local-db sync \
              --settings-yaml "$settings_yaml" \
              --api-token "$HYPER_RPC_API_TOKEN" \
              --release-base-url "$manifest_dir_url" \
              --out-root "$out_root" \
              --debug-status
          '';
        };

        localDbUploadCommand = pkgs.writeShellApplication {
          name = "local-db-upload";
          runtimeInputs = with pkgs; [ awscli2 coreutils curl findutils ];
          text = ''
            set -euo pipefail
            ${repoRootSetup}
            ${envSetup}
            ${shellHelpers}

            load_env_file

            require_var SETTINGS_YAML_URL
            require_var SPACES_ACCESS_KEY
            require_var SPACES_SECRET_KEY
            require_var SPACES_REGION
            require_var SPACES_BUCKET
            require_var SPACES_ENDPOINT

            export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY"
            export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY"
            export AWS_DEFAULT_REGION="$SPACES_REGION"

            local_dir="$repo_root/local-db"
            cli_bin="$repo_root/rain-orderbook-cli"

            if [ ! -x "$cli_bin" ]; then
              echo "❌ Local CLI artifact missing at $cli_bin"
              echo "   Run: nix run .#build-raindex-cli"
              exit 1
            fi

            if [ ! -d "$local_dir" ]; then
              echo "❌ Local DB directory not found at $local_dir"
              exit 1
            fi

            echo "🌐 Fetching settings YAML from $SETTINGS_YAML_URL"
            settings_yaml="$(curl -fsSL "$SETTINGS_YAML_URL")"
            resolve_manifest_publish_target
            manifest_object_key="$(object_key_from_url "$manifest_url")"
            publish_prefix_key="''${manifest_object_key%/*}"

            if [ "$publish_prefix_key" = "$manifest_object_key" ]; then
              publish_prefix_key=""
            fi

            echo "🚀 Uploading dump files and manifest from $local_dir to Spaces bucket: $SPACES_BUCKET"
            echo "   Manifest URL: $manifest_url"
            echo

            echo "🗂️ Uploading SQL dump files..."
            find "$local_dir" -type f -iname "*-0x*.sql.gz" | while IFS= read -r file; do
              filename="$(basename "$file")"
              if [ -n "$publish_prefix_key" ]; then
                object_key="$publish_prefix_key/$filename"
              else
                object_key="$filename"
              fi
              echo "→ Uploading: $filename"
              aws s3 cp "$file" "s3://$SPACES_BUCKET/$object_key" \
                --endpoint-url "$SPACES_ENDPOINT" \
                --acl public-read \
                --content-type "application/gzip"
            done

            if [ -f "$local_dir/manifest.yaml" ]; then
              echo "📄 Uploading manifest.yaml to $manifest_url..."
              aws s3 cp "$local_dir/manifest.yaml" "s3://$SPACES_BUCKET/$manifest_object_key" \
                --endpoint-url "$SPACES_ENDPOINT" \
                --acl public-read \
                --content-type "text/yaml"
            fi

            echo
            echo "✅ Upload complete!"
          '';
        };

        localDbCreateEmptyManifestCommand = pkgs.writeShellApplication {
          name = "local-db-create-empty-manifest";
          runtimeInputs = with pkgs; [ awscli2 coreutils gnused ];
          text = ''
            set -euo pipefail
            ${raindexSetup}
            ${envSetup}

            load_env_file

            for required_var in \
              SPACES_ACCESS_KEY \
              SPACES_SECRET_KEY \
              SPACES_REGION \
              SPACES_BUCKET \
              SPACES_ENDPOINT; do
              if [ -z "''${!required_var:-}" ]; then
                echo "❌ Missing required environment variable: $required_var"
                exit 1
              fi
            done

            export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY"
            export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY"
            export AWS_DEFAULT_REGION="$SPACES_REGION"

            manifest_schema_file="$raindex_root/crates/settings/src/local_db_manifest.rs"
            if [ ! -f "$manifest_schema_file" ]; then
              echo "❌ Manifest schema file not found at $manifest_schema_file" >&2
              exit 1
            fi

            manifest_version="$(sed -nE 's/^pub const MANIFEST_VERSION: u32 = ([0-9]+);$/\1/p' "$manifest_schema_file")"
            db_schema_version="$(sed -nE 's/^pub const DB_SCHEMA_VERSION: u32 = ([0-9]+);$/\1/p' "$manifest_schema_file")"

            if [ -z "$manifest_version" ] || [ -z "$db_schema_version" ]; then
              echo "❌ Failed to read manifest schema versions from $manifest_schema_file" >&2
              exit 1
            fi

            epoch_ms="$(date +%s%3N)"
            object_key="local-db-manifests/$epoch_ms/manifest.yaml"
            manifest_path="$(mktemp)"
            trap 'rm -f "$manifest_path"' EXIT

            printf 'manifest-version: %s\ndb-schema-version: %s\nnetworks: {}\n' \
              "$manifest_version" \
              "$db_schema_version" >"$manifest_path"

            echo "🚀 Uploading empty local DB manifest to Spaces..." >&2
            echo "   Object key: $object_key" >&2

            aws s3 cp "$manifest_path" "s3://$SPACES_BUCKET/$object_key" \
              --endpoint-url "$SPACES_ENDPOINT" \
              --acl public-read \
              --content-type "text/yaml" >&2

            endpoint_host="$(printf '%s' "$SPACES_ENDPOINT" | sed -E 's#^https?://##; s#/.*$##')"

            if [ -z "$endpoint_host" ]; then
              echo "❌ Failed to derive endpoint host from SPACES_ENDPOINT=$SPACES_ENDPOINT" >&2
              exit 1
            fi

            case "$endpoint_host" in
              "$SPACES_BUCKET".*)
                manifest_url="https://$endpoint_host/$object_key"
                ;;
              *)
                manifest_url="https://$SPACES_BUCKET.$endpoint_host/$object_key"
                ;;
            esac

            echo "✅ Empty manifest uploaded." >&2
            echo "   Manifest URL: $manifest_url" >&2

            printf '%s\n' "$manifest_url"
          '';
        };

        localDbRemoteRunner = pkgs.writeShellApplication {
          name = "local-db-remote-run";
          runtimeInputs = with pkgs; [ awscli2 coreutils curl findutils ];
          text = ''
            ${builtins.readFile ./nixos/local-db-remote-run.sh}
          '';
        };

        infraPkgs = import ./infra { inherit pkgs ragenix rainix system; };

        deployPkgs =
          (import ./deploy.nix { inherit deploy-rs self; }).wrappers {
            inherit pkgs infraPkgs;
            localSystem = system;
          };

        bootstrapNixos = rainix.mkTask.${system} {
          name = "bootstrap-nixos";
          additionalBuildInputs = infraPkgs.buildInputs
            ++ [ nixos-anywhere.packages.${system}.default ];
          body = ''
            ${infraPkgs.resolveIp}
            ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -i $identity"

            nixos-anywhere --flake ".#local-db-remote" \
              --option pure-eval false \
              --ssh-option "IdentityFile=$identity" \
              --target-host "root@$host_ip" "$@"

            echo "Waiting for host to come back up..."
            retries=0
            until ssh $ssh_opts "root@$host_ip" true 2>/dev/null; do
              retries=$((retries + 1))
              if [ "$retries" -ge 60 ]; then
                echo "Host did not come back up after 5 minutes" >&2
                exit 1
              fi
              sleep 5
            done

            echo "Bootstrap complete."
          '';
        };

        tfRekey = rainix.mkTask.${system} {
          name = "tf-rekey";
          additionalBuildInputs = infraPkgs.buildInputs;
          body = infraPkgs.tfRekey;
        };

        resolveIpCommand = pkgs.writeShellApplication {
          name = "resolve-ip";
          runtimeInputs = infraPkgs.buildInputs;
          text = ''
            ${infraPkgs.resolveIp}
            printf '%s\n' "$host_ip"
          '';
        };

        remoteCommand = pkgs.writeShellApplication {
          name = "remote";
          runtimeInputs = infraPkgs.buildInputs ++ [ pkgs.openssh ];
          text = ''
            ${infraPkgs.resolveIp}
            exec ssh -i "$identity" "root@$host_ip" "$@"
          '';
        };
      in {
        packages = rainixPkgs // {
          bootstrap-nixos = bootstrapNixos;
          build-raindex-cli = buildRaindexCliCommand;
          deploy-all = deployPkgs.deployAll;
          deploy-nixos = deployPkgs.deployNixos;
          local-db-create-empty-manifest = localDbCreateEmptyManifestCommand;
          local-db-remote-runner = localDbRemoteRunner;
          local-db-sync = localDbSyncCommand;
          local-db-upload = localDbUploadCommand;
          remote = remoteCommand;
          resolve-ip = resolveIpCommand;
          tf-apply = infraPkgs.tfApply;
          tf-destroy = infraPkgs.tfDestroy;
          tf-edit-vars = infraPkgs.tfEditVars;
          tf-init = infraPkgs.tfInit;
          tf-plan = infraPkgs.tfPlan;
          tf-rekey = tfRekey;
        };

        formatter = pkgs.nixfmt-classic;

        devShells.default = addBuildInputs baseDevShells.default (with pkgs; [
          awscli2
          deploy-rs.packages.${system}.deploy-rs
          jq
          nixos-anywhere.packages.${system}.default
          ragenix.packages.${system}.default
          terraform
          bootstrapNixos
          deployPkgs.deployAll
          deployPkgs.deployNixos
          remoteCommand
          resolveIpCommand
          infraPkgs.tfApply
          infraPkgs.tfDestroy
          infraPkgs.tfEditVars
          infraPkgs.tfInit
          infraPkgs.tfPlan
          tfRekey
        ]);
      });

  nixConfig = {
    extra-substituters = [ "https://nix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
}
