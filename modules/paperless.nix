{
  config,
  pkgs,
  lib,
  ...
}:
let
  port = 28981;
in
{
  homelab.egress.enable = true;
  homelab.ingress.enable = true;
  homelab.https.enable = true;

  sops.secrets."paperless/admin-password" = {
    sopsFile = ../secrets/paperless.yaml;
    owner = config.services.paperless.user;
    mode = "0440";
  };

  services.paperless = {
    enable = true;
    dataDir = "/var/lib/paperless";
    port = port;
    address = "127.0.0.1";

    passwordFile = config.sops.secrets."paperless/admin-password".path;
    configureNginx = true;
    domain = config.homelab.https.domain;

    settings = {
      PAPERLESS_URL = lib.mkForce "https://paperless.${lib.lan.domains.vpn}";
      # "paperless": nginx proxies to the upstream of that name without rewriting Host
      PAPERLESS_ALLOWED_HOSTS = lib.concatStringsSep "," (
        config.homelab.https.domains ++ [ "paperless" ]
      );
      PAPERLESS_CSRF_TRUSTED_ORIGINS = lib.concatMapStringsSep "," (
        h: "https://${h}"
      ) config.homelab.https.domains;
      PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ title }}";
      PAPERLESS_CONSUMER_RECURSIVE = true;
      PAPERLESS_OCR_LANGUAGE = "eng+nld";
    };
  };

  # No excessive disk save logging
  services.redis.servers.paperless = {
    logLevel = "warning";
  };

  services.nginx.virtualHosts.${config.homelab.https.domain} = config.homelab.https.vhost // {
    forceSSL = lib.mkForce false;
    extraConfig = "client_max_body_size 50M;";
  };
}
