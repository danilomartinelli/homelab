{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  composeStack = types.submodule {
    options = {
      file = mkOption {
        type = types.path;
        description = "Compose file to start for this stack.";
      };

      projectName = mkOption {
        type = types.strMatching "[a-z0-9][a-z0-9_-]*";
        description = "Explicit Docker Compose project name for this stack.";
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional systemd units this stack is ordered after.";
      };

      requires = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional systemd units this stack requires.";
      };

      preStart = mkOption {
        type = types.lines;
        default = "";
        description = "Commands to run before starting this stack.";
      };

      conditionPathExists = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Paths that must exist before systemd starts this stack.";
      };
    };
  };

  mkComposeService = name: stack: {
    description = "homelab ${name}";
    after = [ "docker.service" "network-online.target" ] ++ stack.after;
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ] ++ stack.requires;
    wantedBy = [ "multi-user.target" ];
    inherit (stack) preStart;

    unitConfig = lib.optionalAttrs (stack.conditionPathExists != [ ]) {
      ConditionPathExists = stack.conditionPathExists;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker}/bin/docker compose -p ${stack.projectName} -f ${stack.file} up -d --remove-orphans";
      ExecStop = "${pkgs.docker}/bin/docker compose -p ${stack.projectName} -f ${stack.file} down";
      TimeoutStartSec = "10min";
      TimeoutStopSec = "2min";
    };
  };
in
{
  options.homelab.compose.stacks = mkOption {
    type = types.attrsOf composeStack;
    default = { };
    description = "Docker Compose stacks managed as host-local systemd units.";
  };

  config.systemd.services = lib.mapAttrs mkComposeService config.homelab.compose.stacks;
}
