# Shared systemd sandboxing baseline for our self-defined services (lifted
# from modules/reporting/report.nix's old commonHardening). Merge with `//`
# and override/removeAttrs whatever a specific service needs.
#
# Networking (RestrictAddressFamilies / IPAddressAllow/Deny) is deliberately
# not included - set it explicitly per service.
{
  # --- Privilege restrictions ------------------------------------------
  NoNewPrivileges = true; # cannot gain privileges via setuid/setgid
  RestrictSUIDSGID = true; # cannot create setuid/setgid files
  LockPersonality = true; # cannot change execution domain
  RestrictRealtime = true; # cannot use realtime scheduling
  RestrictNamespaces = true; # cannot unshare namespaces
  RemoveIPC = true; # no shared IPC objects after exit
  PrivateUsers = true; # own user namespace

  # --- Filesystem restrictions -----------------------------------------
  ProtectSystem = "strict"; # / is read-only except ReadWritePaths
  ProtectHome = true; # /home, /root, /run/user are invisible
  PrivateTmp = true; # own /tmp and /var/tmp
  PrivateDevices = true; # no access to physical devices
  ProtectProc = "invisible"; # /proc hides other users' processes
  ProcSubset = "pid"; # only own PIDs visible under /proc

  # --- Kernel / hardware restrictions ----------------------------------
  ProtectClock = true; # cannot set the system clock
  ProtectHostname = true; # cannot change hostname
  ProtectKernelLogs = true; # cannot read the kernel log
  ProtectKernelModules = true; # cannot load/unload modules
  ProtectKernelTunables = true; # cannot write sysctl/kernel tunables
  ProtectControlGroups = true; # cgroup hierarchy is read-only

  # --- Memory / syscall restrictions -----------------------------------
  MemoryDenyWriteExecute = true; # no W+X mappings (blocks many exploits)
  SystemCallArchitectures = "native";
  SystemCallFilter = [
    "@system-service" # a reasonable base for services
    "~@privileged" # deny privileged syscalls
    "~@resources" # deny resource-setting syscalls
    "~@obsolete" # deny obsolete syscalls
  ];
  CapabilityBoundingSet = [ "" ]; # drop all capabilities
  AmbientCapabilities = [ "" ];

  # --- Device / mount restrictions -------------------------------------
  DevicePolicy = "closed"; # no device access except /dev/null etc.
  PrivateMounts = true; # own mount namespace

  # --- Misc --------------------------------------------------------------
  LimitCORE = 0; # no core dumps
}
