# cacert: CA bundle for the host, from its own nixpkgs pin (see flake.nix).
{ cacert, lib, modulesPath, pkgs, self, tailscalePkgs, ... }:

let
  inherit (import ./keys.nix) roles;
  runner = self.packages.${pkgs.system}.local-db-remote-runner;
in {
  imports = [
    (modulesPath + "/virtualisation/digital-ocean-config.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
  ];

  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  networking.useDHCP = lib.mkForce false;

  services = {
    openssh = {
      enable = true;
      settings = {
        KbdInteractiveAuthentication = false;
        LoginGraceTime = "30s";
        MaxAuthTries = 3;
        MaxStartups = "50:30:100";
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    fail2ban = {
      enable = true;
      bantime = "1h";
      maxretry = 3;
      jails.sshd.settings = {
        enabled = true;
        findtime = "10m";
        mode = "aggressive";
      };
    };

    tailscale = {
      enable = true;
      openFirewall = true;
      package = tailscalePkgs.tailscale;
    };
  };

  users.users.root.openssh.authorizedKeys.keys = roles.ssh;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  # Serve the pinned CA bundle at the paths security.pki would populate from
  # the rainix nixpkgs cacert. Overriding the etc entries avoids an overlay,
  # which would rebuild everything that depends on cacert.
  environment.etc = lib.genAttrs [
    "ssl/certs/ca-certificates.crt"
    "ssl/certs/ca-bundle.crt"
    "pki/tls/certs/ca-bundle.crt"
  ] (_: { source = lib.mkForce "${cacert}/etc/ssl/certs/ca-bundle.crt"; }) // {
    "ssl/trust-source".source =
      lib.mkForce "${cacert.p11kit}/etc/ssl/trust-source";
  };

  assertions = [{
    assertion = lib.versionOlder pkgs.cacert.version cacert.version;
    message =
      "rainix nixpkgs cacert ${pkgs.cacert.version} has caught up with the pinned cacert ${cacert.version}; remove the nixpkgs-cacert input, the /etc CA overrides and the nix-daemon CURL_CA_BUNDLE override.";
  }];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      openssl
      sqlite
      stdenv.cc.cc
      zlib
    ];
  };

  systemd.tmpfiles.rules = [
    "d /etc/local-db-remote 0750 root root -"
    "d /etc/local-db-remote/deployments 0750 root root -"
    "d /var/lib/local-db-remote 0755 root root -"
    "d /var/lib/local-db-remote/bin 0755 root root -"
    "d /var/lib/local-db-remote/deployments 0755 root root -"
    "d /var/lib/local-db-remote/work 0755 root root -"
  ];

  systemd.services.local-db-sync = {
    description = "Local DB remote sync";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    restartIfChanged = false;
    stopIfChanged = true;

    unitConfig = {
      ConditionPathExists = [
        "/etc/local-db-remote/env"
        "/var/lib/local-db-remote/bin/rain-orderbook-cli"
      ];
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = "/var/lib/local-db-remote";
      EnvironmentFile = "/etc/local-db-remote/env";
      ExecStart = "${runner}/bin/local-db-remote-run";
      TimeoutStartSec = "4h";
      KillMode = "control-group";
    };
  };

  systemd.timers.local-db-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "1s";
      Persistent = true;
      Unit = "local-db-sync.service";
    };
  };

  # nix-daemon reads the read-only security.pki.caBundle, which still points at
  # the rainix cacert.
  systemd.services.nix-daemon.environment.CURL_CA_BUNDLE =
    lib.mkForce "/etc/ssl/certs/ca-certificates.crt";

  systemd.services."local-db-sync@" = {
    description = "Local DB remote sync for deployment %i";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    restartIfChanged = false;
    stopIfChanged = true;

    unitConfig = {
      ConditionPathExists = [
        "/etc/local-db-remote/deployments/%i/env"
        "/var/lib/local-db-remote/deployments/%i/bin/rain-orderbook-cli"
      ];
    };

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = "/var/lib/local-db-remote";
      Environment = "LOCAL_DB_DEPLOYMENT_ID=%i";
      EnvironmentFile = "/etc/local-db-remote/deployments/%i/env";
      ExecStart = "${runner}/bin/local-db-remote-run";
      TimeoutStartSec = "4h";
      KillMode = "control-group";
    };
  };

  systemd.timers."local-db-sync@" = {
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "1s";
      Persistent = true;
      Unit = "local-db-sync@%i.service";
    };
  };

  environment.systemPackages = with pkgs; [
    bat
    curl
    git
    htop
    jq
    tailscalePkgs.tailscale
    zellij
  ];

  programs.bash.interactiveShellInit = "set -o vi";
  system.stateVersion = "24.11";
}
