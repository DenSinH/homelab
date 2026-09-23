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
    domain = "paperless.home"; # canonical; paperless.vpn is added as an alias below

    settings = {
      # PAPERLESS_URL is set automatically to https://${domain} by configureNginx;
      # override it back to plain http since we're not using TLS
      PAPERLESS_URL = lib.mkForce "http://paperless.vpn";
      PAPERLESS_ALLOWED_HOSTS = "paperless.home,paperless.vpn,paperless";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "http://paperless.home,http://paperless.vpn";
      PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ title }}";
      PAPERLESS_CONSUMER_RECURSIVE = true;
      PAPERLESS_OCR_LANGUAGE = "eng+nld";
    };
  };

  services.nginx.virtualHosts."paperless.home" = {
    forceSSL = lib.mkForce false;
    serverAliases = [ "paperless.vpn" ];
    extraConfig = "client_max_body_size 50M;";
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
