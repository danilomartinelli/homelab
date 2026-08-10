# Caddy — TLS termination for the single public endpoint on this host.
#
# Deployed as the NixOS module rather than a container: Caddy needs to bind
# 80 and 443 and to persist ACME account/certificate state. The module
# already handles the CAP_NET_BIND_SERVICE grant, a dedicated `caddy` user,
# and StateDirectory for /var/lib/caddy — all of which would have to be
# rebuilt by hand around a container.
#
# This module is what opens the machine to the internet. Until now the only
# inbound rule was SSH on 22 and everything else arrived over Tailscale.
# Meta's WhatsApp Cloud API cannot use Tailscale: it POSTs inbound messages
# from its own infrastructure to a public HTTPS endpoint, so 80 and 443 have
# to be reachable.
#
# What limits the exposure:
#
#   * The Caddyfile proxies exactly one path (/whatsapp/webhook) and returns
#     a bare 404 for everything else.
#   * The Hermes gateway binds 127.0.0.1:8090 (WHATSAPP_CLOUD_WEBHOOK_HOST
#     pinned in the compose) so it is not directly reachable even with host
#     networking.
#   * Meta signs every request; WHATSAPP_CLOUD_APP_SECRET verifies the HMAC
#     and WHATSAPP_CLOUD_VERIFY_TOKEN gates the subscription handshake.
#   * WHATSAPP_CLOUD_ALLOWED_USERS restricts which senders the agent obeys.
#
# Port 80 is open because the ACME HTTP-01 challenge needs it. It could be
# avoided with DNS-01 (Cloudflare token), which would keep 80 closed — worth
# doing if the public surface ever needs to shrink further.

{ config, pkgs, lib, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ../services/caddy/Caddyfile;
  };

  # ACME HTTP-01 challenge (80) and the webhook itself (443).
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # The Caddyfile writes here; the module's StateDirectory does not cover
  # /var/log.
  systemd.tmpfiles.rules = [
    "d /var/log/caddy 0750 caddy caddy -"
  ];
}
