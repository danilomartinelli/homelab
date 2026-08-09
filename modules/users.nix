# Users and SSH access.
#
# SSH lives here, not in networking.nix, because losing remote access must
# not be a side effect of slicing networking out of a build. An earlier
# attempt commented out networking.nix to isolate a boot problem and took
# `services.openssh` with it — the machine stayed up and pingable, but
# became unreachable.
#
# ANTI-PATTERN — this cost a reinstall:
#     users.mutableUsers = false;   # without declaring hashedPassword
# That rewrites /etc/shadow on activation. /etc/shadow is mutable state on
# disk, NOT part of the generation closure, so rolling back to an earlier
# generation does not restore it. Setting it without a declared password
# hash locks every account permanently — including on the serial console,
# which is the last way in before a reinstall.

{ config, pkgs, lib, ... }:
let
  adminKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPV/mHijDsESTCFDzWYl6dIx+HtICCMllFlfRFSUWxIv danilomartinelli personal"
  ];
in
{
  users.users.root.openssh.authorizedKeys.keys = adminKeys;

  # "docker" is listed only because modules/docker.nix is enabled; the group
  # is created by that module. Adding it here while docker is disabled makes
  # activation fail on a nonexistent group.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = adminKeys;
  };

  # Reachable only by SSH key, so passwordless sudo is an acceptable trade.
  security.sudo.wheelNeedsPassword = false;

  # PermitRootLogin stays key-only rather than "no": root is the documented
  # recovery path on this provider, and locking it before `admin` has been
  # verified from a fresh connection is how you end up needing the console.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      X11Forwarding = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
