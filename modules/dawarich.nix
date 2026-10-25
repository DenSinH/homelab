{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}:

{
  services.dawarich = {
    enable = true;

    # Use unstable because fixes are available in newer versions (past 26.05)
    # Override log level for Sidekiq (really excessive logs...)
    package = pkgs-unstable.dawarich.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace config/initializers/sidekiq.rb \
          --replace-fail \
            'config.logger = Sidekiq::Logger.new($stdout)' \
            'config.logger = Sidekiq::Logger.new($stdout)
        config.logger.level = Logger::WARN'
      '';
    });

    localDomain = "dawarich.home";

    # expose over VPN hostname as well
    environment = {
      APPLICATION_HOSTS = "127.0.0.1,::1,dawarich.home,dawarich.vpn";
      RAILS_LOG_LEVEL = "info";

      PHOTON_API_HOST = "photon.komoot.io";
      PHOTON_API_USE_HTTPS = "true";
    };
  };

  services.redis.servers.dawarich = {
    logLevel = "warning";

    # Reduce disk writes
    # Redis only holds the job queue/cache here, so snapshots
    # are mostly wasted disk writes. Removing this also stops the BGSAVE churn itself.
    save = [
      [
        3600
        1
      ]
      [
        300
        100
      ]
    ];
  };

  # expose on vpn as well
  services.nginx.virtualHosts."dawarich.home" = {
    serverAliases = [
      "dawarich.vpn"
    ];
  };

  # open firewall to nginx
  networking.firewall = {
    allowedTCPPorts = [ 80 ];
  };
}
