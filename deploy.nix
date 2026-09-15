{ deployRsLib, self }:

let
  system = "x86_64-linux";
  inherit (deployRsLib) activate;
in {
  config = {
    nodes.local-db-remote = {
      hostname = builtins.getEnv "DEPLOY_HOST";
      sshUser = "root";
      user = "root";

      profiles.system = {
        path = activate.nixos self.nixosConfigurations.local-db-remote;
      };
    };
  };

  wrappers = { pkgs, infraPkgs, deployRsPackage, localSystem }:
    let
      deployInputs = infraPkgs.buildInputs ++ [ deployRsPackage ];

      deployPreamble = ''
        ${infraPkgs.parseIdentity}
        if [ -n "''${DEPLOY_HOST:-}" ]; then
          host_ip="$DEPLOY_HOST"
        else
          ${infraPkgs.resolveIp}
          export DEPLOY_HOST="$host_ip"
        fi
        export NIX_SSHOPTS="-i $identity"
        ssh_flag="--ssh-opts=-i $identity"
      '';

      deployFlags =
        if localSystem == system then "" else "--skip-checks --remote-build";
    in {
      deployNixos = pkgs.writeShellApplication {
        name = "deploy-nixos";
        runtimeInputs = deployInputs;
        text = ''
          ${deployPreamble}
          deploy ${deployFlags} ''${ssh_flag:+"$ssh_flag"} .#local-db-remote.system \
            -- --impure "$@"
        '';
      };

      deployAll = pkgs.writeShellApplication {
        name = "deploy-all";
        runtimeInputs = deployInputs;
        text = ''
          ${deployPreamble}
          deploy ${deployFlags} ''${ssh_flag:+"$ssh_flag"} .#local-db-remote \
            -- --impure "$@"
        '';
      };
    };
}
