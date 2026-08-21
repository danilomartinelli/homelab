# Uncloud machine daemon, pinned to the same release as the management CLI.
#
# The upstream installer targets mutable systemd distributions and writes to
# /usr/local. On NixOS the equivalent is declared here so upgrades, rollback,
# boot ordering and the control-socket group remain reproducible.

{ pkgs, ... }:
let
  version = "0.20.0";
  uncloudd = pkgs.stdenvNoCC.mkDerivation {
    pname = "uncloudd";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/psviderski/uncloud/releases/download/v${version}/uncloudd_linux_amd64.tar.gz";
      hash = "sha256-L6Ryb5z6r/njXDni0EkT/smwshAMjv5/67a8+vqzqQg=";
    };

    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      tar -xzf "$src" -C "$out/bin" uncloudd
      chmod 0555 "$out/bin/uncloudd"
      runHook postInstall
    '';
  };
in
{
  # uc connects over SSH by executing `uncloudd dial-stdio`, so the daemon
  # must be in the normal system PATH as well as referenced by the unit.
  environment.systemPackages = [ uncloudd ];

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
