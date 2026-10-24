{
  config,
  pkgs,
  lib,
  ...
}:

{
  services.dawarich = {
    enable = true;
    localDomain = "dawarich.home";

    # expose over VPN hostname as well
    environment = {
      APPLICATION_HOSTS = "127.0.0.1,::1,dawarich.home,dawarich.vpn";
      RAILS_LOG_LEVEL = "info";
    };
  };

  # Override log level for Sidekiq (really excessive logs...)
  services.dawarich.package = pkgs.dawarich.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace config/initializers/sidekiq.rb \
        --replace-fail \
          'config.logger = Sidekiq::Logger.new($stdout)' \
          'config.logger = Sidekiq::Logger.new($stdout)
      config.logger.level = Logger::WARN'
    '';
  });

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

  # Default 5 threads hit Nominatim's public API concurrently, well above its
  # ~1 req/s policy - the real cause of the Geocoder::NetworkError bursts.
  # Serialize geocoding-related queues onto their own single-threaded process.
  services.dawarich.sidekiqProcesses = {
    default = {
      jobClasses = [
        "app_version_checking"
        "archival"
        "cache"
        "data_migrations"
        "default"
        "digests"
        "exports"
        "families"
        "imports"
        "mailers"
        "points"
        "stats"
        "tracks"
        "trips"
        "visit_suggesting"
      ];
      threads = null; # uses services.dawarich.sidekiqThreads
    };

    geocoding = {
      jobClasses = [
        "places"
        "reverse_geocoding"
      ];
      threads = 1;
    };
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
