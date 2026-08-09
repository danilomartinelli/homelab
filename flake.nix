{
  description = "Homelab NixOS configuration (kodo)";

  inputs = {
    # Pinned to the exact nixpkgs revision the Hostinger image ships
    # (nixos-version reports 26.05.6503.21ea275a7c46). Pinning removes the
    # kernel from the set of variables while the deploy pipeline is being
    # proven: the stock system boots on 6.18.40, and tracking the branch
    # instead produced 6.18.43. After a reboot has been verified end to end,
    # move this back to `github:NixOS/nixpkgs/nixos-26.05` so the host gets
    # security updates — a permanent pin is a liability, not a safety net.
    nixpkgs.url = "github:NixOS/nixpkgs/21ea275a7c46";

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
