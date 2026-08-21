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
    ./uncloud.nix
    ./tailscale.nix
    # Public ingress is provided by the Caddy service managed by Uncloud.
    # This module declares only the host firewall boundary; the Caddy service
    # and its global config live in Uncloud's replicated cluster state.
    ./ingress.nix
    # secrets.nix must come before anything that reads
    # config.sops.secrets.*, and requires secrets/services.yaml to exist and
    # be decryptable by kodo's host key — otherwise activation fails.
    ./secrets.nix
    ./backup.nix
  ];
}
