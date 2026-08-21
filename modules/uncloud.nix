# Uncloud machine daemon, pinned to the same release as the management CLI.
#
# The upstream installer targets mutable systemd distributions and writes to
# /usr/local. On NixOS the equivalent is declared here so upgrades, rollback,
# boot ordering and the control-socket group remain reproducible.

{ pkgs, ... }:
let
  version = "0.20.0";
  mkUncloudBinary = { pname, hash }: pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/psviderski/uncloud/releases/download/v${version}/${pname}_linux_amd64.tar.gz";
      inherit hash;
    };

    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      tar -xzf "$src" -C "$out/bin" ${pname}
      chmod 0555 "$out/bin/${pname}"
      runHook postInstall
    '';
  };
  uc = mkUncloudBinary {
    pname = "uc";
    hash = "sha256-zHDdaNPrMyNzbwAmbrXwS5Pub90RlzLxhJLhHvmFMKg=";
  };
  uncloudd = mkUncloudBinary {
    pname = "uncloudd";
    hash = "sha256-L6Ryb5z6r/njXDni0EkT/smwshAMjv5/67a8+vqzqQg=";
  };
in
{
  # uc connects over SSH by executing `uncloudd dial-stdio`, so the daemon
  # must be in the normal system PATH as well as referenced by the unit.
  environment.systemPackages = [ uc uncloudd ];

  # Running uc on the machine should use the local control socket instead of
  # SSHing back into itself. The socket is root:uncloud 0660 and admin is a
  # declared member of that group in users.nix.
  environment.etc."uncloud/config.yaml".text = ''
    current_context: loopdodia
    contexts:
      loopdodia:
        connections:
          - unix: /run/uncloud/uncloud.sock
  '';
  environment.variables.UNCLOUD_CONFIG = "/etc/uncloud/config.yaml";

  systemd.tmpfiles.rules = [
    "d /home/admin/.config/uncloud 0755 admin users -"
    "L+ /home/admin/.config/uncloud/config.yaml - - - - /etc/uncloud/config.yaml"
  ];

  systemd.services.uncloud = {
    description = "Uncloud machine daemon";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    # Most operations use netlink and the Docker API directly. Keep the few
    # administrative tools used for diagnostics/migration available without
    # relying on an interactive shell PATH.
    path = with pkgs; [ docker iproute2 iptables procps systemd wireguard-tools ];

    serviceConfig = {
      Type = "notify";
      ExecStart = "${uncloudd}/bin/uncloudd";
      TimeoutStartSec = 15;
      Restart = "always";
      RestartSec = 2;

      # Matches the hardening shipped by Uncloud's v0.20.0 installer.
      NoNewPrivileges = true;
      ProtectSystem = "full";
      ProtectControlGroups = true;
      ProtectHome = "read-only";
      ProtectKernelTunables = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      RestrictNamespaces = true;
    };
  };
}
