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
    ./tailscale.nix
    # secrets.nix must come before anything that reads
    # config.sops.secrets.*, and requires secrets/services.yaml to exist and
    # be decryptable by kodo's host key — otherwise activation fails.
    ./secrets.nix
    ./backup.nix
  ];
}
