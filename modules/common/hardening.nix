{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Networking (RestrictAddressFamilies / IPAddress*) is left to each service.
  baseline = {
    # privileges
    NoNewPrivileges = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    RemoveIPC = true;
    PrivateUsers = true;
    CapabilityBoundingSet = [ "" ];
    AmbientCapabilities = [ "" ];

    # filesystem / devices
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateMounts = true;
    DevicePolicy = "closed";
    ProtectProc = "invisible";
    ProcSubset = "pid";

    # kernel
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;

    # syscalls / memory
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
      "~@obsolete"
    ];

    LimitCORE = 0;
  };

  # Fails the build if systemd-analyze scores the unit above maxExposure; the report shows what costs points.
  check =
    name: svc:
    pkgs.runCommand "hardening-${name}" { nativeBuildInputs = [ pkgs.util-linux ]; } ''
      # systemd-analyze needs a writable /run/systemd, which the build sandbox lacks
      mkdir -p root/{nix,run,tmp,etc/systemd/system,usr/lib/systemd/system}
      set -o pipefail
      unshare -rm sh -c 'mount --rbind /nix root/nix && exec chroot root \
        ${pkgs.systemd}/bin/systemd-analyze security --offline=yes --no-pager \
        --threshold=${toString (builtins.floor (svc.hardening.maxExposure * 10 + 0.5))} \
        ${config.systemd.units."${name}.service".unit}/${name}.service' | tee $out || {
        echo "${name}.service exceeds hardening.maxExposure = ${toString svc.hardening.maxExposure}" >&2
        exit 1
      }
    '';

  checks = lib.mapAttrs check (
    lib.filterAttrs (_: svc: svc.hardening.enable) config.systemd.services
  );
in
{
  options.systemd.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.hardening = {
            enable = lib.mkEnableOption "the sandboxing baseline (any key can be overridden in serviceConfig)";
            relax = lib.mkOption {
              type = lib.types.listOf (lib.types.enum (builtins.attrNames baseline));
              default = [ ];
              description = "Baseline settings to leave unset.";
            };
            maxExposure = lib.mkOption {
              type = lib.types.numbers.between 0 10;
              default = 2.0;
              description = "Highest allowed `systemd-analyze security` score.";
            };
          };

          config.serviceConfig = lib.mkIf config.hardening.enable (
            lib.mapAttrs (_: lib.mkDefault) (removeAttrs baseline config.hardening.relax)
          );
        }
      )
    );
  };

  config.system = {
    checks = lib.attrValues checks;
    # picked up by `nix flake check`
    build.hardeningChecks = checks;
  };
}
