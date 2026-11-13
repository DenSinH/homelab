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

    # not sandboxed: --auto-tune writes sysfs/sysctl knobs system-wide as root
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.powertop}/bin/powertop --auto-tune";
      RemainAfterExit = true;

      User = "root";
      UMask = "0077";
    };
  };
}
