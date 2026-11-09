{
  config,
  lib,
  host,
  ...
}:

let
  https = host.https or null;
  domains = lib.concatMap (d: [ d.fqdn ] ++ lib.optional d.wildcard "*.${d.fqdn}") (
    lib.httpsDomains host
  );
  certName = host.hostname;
in
{
  options.homelab.https = {
    domain = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default =
        if domains == [ ] then
          throw "${certName}: homelab.https used, but its homelab.nix entry has no `https = { ... }`"
        else
          lib.head domains;
      description = "Primary FQDN; use as the nginx virtualHost name.";
    };
    vhost = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      # addSSL, not forceSSL: old plain-HTTP .home/.vpn aliases must keep working for now.
      default = {
        useACMEHost = certName;
        addSSL = true;
        serverAliases = lib.tail domains;
      };
      description = "nginx virtualHost settings serving every name in this LXC's cert.";
    };
  };

  config = lib.mkIf (https != null) {
    sops.secrets."acme/cloudflare_dns_api_key".sopsFile = ../secrets/acme.yaml;

    security.acme = {
      acceptTerms = true;
      defaults.email = "admin@hlhrst.nl";
      defaults.server = lib.mkIf (https.staging or false
      ) "https://acme-staging-v02.api.letsencrypt.org/directory";

      # Token from https://dash.cloudflare.com/profile/api-tokens: Zone - Zone - Read and
      # Zone - DNS - Edit, resources Include - Specific zone - hlhrst.nl.
      # See https://go-acme.github.io/lego/dns/cloudflare/#api-tokens
      certs.${certName} = {
        domain = config.homelab.https.domain;
        extraDomainNames = lib.tail domains;
        group = "nginx";
        dnsProvider = "cloudflare";
        dnsResolver = "1.1.1.1:53";
        credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE =
          config.sops.secrets."acme/cloudflare_dns_api_key".path;
      };
    };

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
