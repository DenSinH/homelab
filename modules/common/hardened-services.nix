{ lib, ... }:
{
  options.homelab.hardenedServices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Unit names (no .service suffix) hardened via lib.hardenedService.
      `nix run .#security-report` reads this to find what to check.
    '';
  };
}
