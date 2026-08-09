{
  description = "Homelab NixOS configuration (kodo)";

  inputs = {
    # Tracks the release branch so the host receives security updates.
    #
    # This was temporarily pinned to 21ea275a7c46 — the revision the
    # provider image ships — while the deploy pipeline was being proven.
    # The pin made the built kernel byte-identical to the one already known
    # to boot, which removed it as a variable while four separate outages
    # were being diagnosed. It was a debugging aid, not a resting state: a
    # permanent pin freezes security updates.
    #
    # Unpinning changes the kernel. Treat every `nix flake update` as a
    # change that needs the full sequence in README.md: build, diff the
    # closure against /run/current-system, test, verify from a NEW
    # connection, then boot and reboot.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosConfigurations.kodo = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/default.nix
          ./hosts/kodo/default.nix
        ];
      };
    };
}
