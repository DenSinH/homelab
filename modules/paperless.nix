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
      # PAPERLESS_URL defaults to https://${domain} via configureNginx, which
      # is correct now that paperless.home is TLS-terminated below.
      PAPERLESS_ALLOWED_HOSTS = "paperless.home,paperless.vpn,paperless";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.home,https://paperless.vpn";
      PAPERLESS_FILENAME_FORMAT = "{{ created_year }}/{{ correspondent }}/{{ title }}";
      PAPERLESS_CONSUMER_RECURSIVE = true;
      PAPERLESS_OCR_LANGUAGE = "eng+nld";
    };
  };

  homelab.selfSignedCerts.paperless = {
    hostName = "paperless.home";
    extraSANs = [ "DNS:paperless.vpn" ];
  };

  services.nginx.virtualHosts."paperless.home" = {
    sslCertificate = config.homelab.selfSignedCerts.paperless.certFile;
    sslCertificateKey = config.homelab.selfSignedCerts.paperless.keyFile;
    serverAliases = [ "paperless.vpn" ];
    extraConfig = "client_max_body_size 50M;";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
