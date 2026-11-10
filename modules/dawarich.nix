{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}:

{
  homelab.egress.enable = true;
  homelab.ingress.enable = true;
  homelab.https.enable = true;

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

    localDomain = config.homelab.https.domain;

    environment = {
      APPLICATION_PROTOCOL = "https";
      APPLICATION_HOSTS = lib.concatStringsSep "," (
        [
          "127.0.0.1"
          "::1"
        ]
        ++ config.homelab.https.domains
      );
      RAILS_LOG_LEVEL = "info";

      NOMINATIM_API_HOST = "nominatim.openstreetmap.org";
      NOMINATIM_API_USE_HTTPS = "true";

      # Nominatim sets a rate limit of 1rps, let's just be a
      # little more conservative
      REVERSE_GEOCODING_RPS = "0.5";
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

  services.nginx.virtualHosts.${config.homelab.https.domain} = config.homelab.https.vhost;
}
