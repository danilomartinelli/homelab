{ ... }:
{
  imports = [
    ./users.nix
    ./networking.nix
    ./docker.nix
    ./tailscale.nix
    ./secrets.nix
    ./backup.nix
  ];
}
