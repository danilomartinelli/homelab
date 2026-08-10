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
    # Caddy is what opens 80/443 to the internet. It exists solely to
    # terminate TLS for the WhatsApp Cloud API webhook, which Meta POSTs to
    # from its own infrastructure and therefore cannot reach over Tailscale.
    ./caddy.nix
    # secrets.nix must come before anything that reads
    # config.sops.secrets.*, and requires secrets/services.yaml to exist and
    # be decryptable by kodo's host key — otherwise activation fails.
    ./secrets.nix
    ./backup.nix
  ];
}
