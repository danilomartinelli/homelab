{ ... }:
{
  imports = [
    ./users.nix
    # cloud-init runs the provider's boot integration: network file, host
    # keys, filesystem growth. Dropping it deletes that setup rather than
    # leaving it untouched.
    ./cloud-init.nix
    ./networking.nix
    ./docker.nix
    # Added one at a time, each verified by an actual reboot:
    # ./tailscale.nix
    # ./secrets.nix
    # ./backup.nix
  ];
}
