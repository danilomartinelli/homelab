# Public ingress for services managed by Uncloud.
#
# Uncloud's global Caddy container publishes 80/TCP, 443/TCP and 443/UDP in
# host mode. TCP 80 handles ACME HTTP-01 and redirects; TCP/UDP 443 serve
# HTTPS and HTTP/3. The Caddy service itself is deployed with `uc caddy
# deploy`, because its desired state belongs to the Uncloud cluster.

{ ... }:
{
  networking.firewall.allowedTCPPorts = [
    80
    443

    # Hermes binds this port only to the Uncloud bridge gateway
    # (10.210.0.1), never to the public or Tailscale addresses. Allowing the
    # port through the host firewall lets the Caddy container reach it while
    # the address-specific bind keeps it unavailable on external interfaces.
    8090
  ];
}
