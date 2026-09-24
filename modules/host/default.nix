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

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.powertop}/bin/powertop --auto-tune";
      RemainAfterExit = true;

      User = "root";
      NoNewPrivileges = true;

      ProtectHome = true;
      ProtectHostname = true;
      ProtectClock = true;
      ProtectKernelLogs = true;
      PrivateTmp = true;

      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";

      UMask = "0077";
    };
  };
}
