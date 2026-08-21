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
  recoveryKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPV/mHijDsESTCFDzWYl6dIx+HtICCMllFlfRFSUWxIv danilomartinelli personal"
  ];
  uncloudAccessKeys = [
    # Public half of ~/.ssh/id_ed25519 on the management Mac. The private
    # key never leaves that machine; uc stores only this key's local path in
    # its client context and connects as the unprivileged admin user.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPqYTfOwfG/QbCPYjEXjx7lMmDclx+uyj4x8YLutzpEd homelab-MacBook-Pro-de-Danilo"
  ];
in
{
  # Keep the recovery key set deliberately smaller. Uncloud administration
  # uses admin + passwordless sudo and does not need direct root login.
  users.users.root.openssh.authorizedKeys.keys = recoveryKeys;

  # uncloudd exposes its local control socket as root:uncloud 0660.
  users.groups.uncloud = { };
  users.users.uncloud = {
    isSystemUser = true;
    group = "uncloud";
    home = "/var/lib/uncloud";
  };

  # "docker" is listed only because modules/docker.nix is enabled; the group
  # is created by that module. Adding it here while docker is disabled makes
  # activation fail on a nonexistent group.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" "uncloud" ];
    openssh.authorizedKeys.keys = recoveryKeys ++ uncloudAccessKeys;
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
