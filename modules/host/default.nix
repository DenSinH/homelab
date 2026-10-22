{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../common/default.nix
  ];

  homelab.hardenedServices = [ "powertop" ];

  environment.systemPackages = with pkgs; [
    # powertop on boot
    powertop

    # useful device utilities
    pciutils
    usbutils
  ];

  # run powertop on boot
  boot.kernelModules = [
    "msr"
    "cpufreq_stats" # might fail to load
  ];

  systemd.services.powertop = {
    description = "PowerTOP auto-tune";

    wantedBy = [ "multi-user.target" ];
    wants = [ "systemd-modules-load.service" ];
    after = [
      "local-fs.target"
      "systemd-modules-load.service"
    ];

    path = [
      pkgs.kmod
    ];

    serviceConfig =
      # powertop --auto-tune writes directly to sysfs/sysctl knobs across the
      # whole system and needs full root to do it.
      removeAttrs lib.hardenedService [
        "ProtectSystem"
        "ProtectKernelTunables"
        "ProtectKernelModules"
        "ProtectControlGroups"
        "ProtectProc"
        "ProcSubset"
        "MemoryDenyWriteExecute"
        "SystemCallFilter"
        "CapabilityBoundingSet"
        "AmbientCapabilities"
        "DevicePolicy"
        "PrivateMounts"
        "RemoveIPC"
        "PrivateUsers"
      ]
      // {
        Type = "oneshot";
        ExecStart = "${pkgs.powertop}/bin/powertop --auto-tune";
        RemainAfterExit = true;

        User = "root";
        UMask = "0077";
      };
  };
}
