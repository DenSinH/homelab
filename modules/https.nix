{
  config,
  lib,
  host,
  ...
}:

let
  cfg = config.homelab.https;
  zones = [
    lib.lan.domains.home
  ]
  ++ lib.optional ((host.tailnet_ip or null) != null) lib.lan.domains.vpn
  ++ [ lib.lan.domains.short ];
  domains = lib.concatMap (name: map (zone: "${name}.${zone}") zones) (
    [ host.hostname ] ++ host.aliases or [ ]
  );
  certName = host.hostname;
in
{
  options.homelab.https = {
    enable = lib.mkEnableOption "a Let's Encrypt cert for <hostname> in every lib.lan.domains zone (.vpn only with a tailnet_ip)";
    tunnel = lib.mkEnableOption "plain HTTP on lib.lan.tunnelPort, reachable by cloudflared only";

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = domains;
      description = "Every name in this LXC's cert.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = lib.head domains;
      description = "Primary FQDN; use as the nginx virtualHost name.";
    };
    vhost = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = {
        useACMEHost = certName;
        onlySSL = true;
        serverAliases = lib.tail domains;
      };
      description = "nginx virtualHost settings serving every name in this LXC's cert over HTTPS.";
    };
    tunnelVhost = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = cfg.vhost // {
        listen = [
          {
            addr = "0.0.0.0";
            port = 443;
            ssl = true;
          }
          {
            addr = "[::]";
            port = 443;
            ssl = true;
          }
          {
            addr = "0.0.0.0";
            port = lib.lan.tunnelPort;
          }
        ];
      };
      description = "`vhost`, plus plain HTTP on the tunnel port (needs `tunnel`).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."acme/cloudflare_dns_api_key".sopsFile = ../secrets/acme.yaml;

    security.acme = {
      acceptTerms = true;
      defaults.email = "admin@hlhrst.nl";

      # Token from https://dash.cloudflare.com/profile/api-tokens: 
      #   Zone - Zone - Read
      #   Zone - DNS - Edit 
      # resources 
      #   Include - Specific zone - hlhrst.nl.
      # See https://go-acme.github.io/lego/dns/cloudflare/#api-tokens
      certs.${certName} = {
        domain = cfg.domain;
        extraDomainNames = lib.tail domains;
        group = "nginx";
        dnsProvider = "cloudflare";
        dnsResolver = "1.1.1.1:53";
        credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE =
          config.sops.secrets."acme/cloudflare_dns_api_key".path;
      };
    };

    # :80 only redirects; also the default server, so http://<ip> redirects too.
    services.nginx.virtualHosts.https-redirect = {
      serverName = cfg.domain;
      serverAliases = lib.tail domains;
      default = true;
      locations."/".return = "301 https://$host$request_uri";
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
    networking.firewall.extraInputRules = lib.mkIf cfg.tunnel ''
      ip saddr ${lib.lxcs.cloudflared.ip} tcp dport ${toString lib.lan.tunnelPort} accept comment "cloudflared tunnel"
    '';
  };
}
