{
  config,
  pkgs,
  lib,
  ...
}:

{
  homelab.selfSignedCerts.bentopdf.hostName = "bentopdf.home";

  services.bentopdf = {
    enable = true;
    domain = "bentopdf.home";

    nginx = {
      enable = true;
      virtualHost = {
        forceSSL = true;
        sslCertificate = config.homelab.selfSignedCerts.bentopdf.certFile;
        sslCertificateKey = config.homelab.selfSignedCerts.bentopdf.keyFile;
      };
    };
  };

  # open firewall to nginx
  networking.firewall = {
    allowedTCPPorts = [
      80
      443
    ];
  };
}
