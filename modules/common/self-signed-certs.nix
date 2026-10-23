{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homelab.selfSignedCerts;
  certDir = name: "/var/lib/self-signed-certs/${name}";
in
{
  options.homelab.selfSignedCerts = lib.mkOption {
    default = { };
    description = ''
      Self-signed TLS certs generated once at activation, for internal-only
      services. Add an entry here; if `vhosts` is non-empty, the listed
      services.nginx.virtualHosts entries get forceSSL/sslCertificate/
      sslCertificateKey wired automatically. For anything the automation
      doesn't cover (a non-nginx consumer, a vhost needing a custom
      redirect, a module needing its own cert passthrough option), use
      certFile/keyFile directly instead of `vhosts`.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            hostName = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "CN / primary SAN DNS name for the generated cert.";
            };
            extraSANs = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [
                "DNS:foo.vpn"
                "IP:192.168.50.50"
              ];
              description = "Extra SAN entries beyond DNS:<hostName>.";
            };
            vhosts = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                services.nginx.virtualHosts names to auto-wire this cert onto
                (sslCertificate/sslCertificateKey, plus forceSSL unless
                disabled below). Leave empty to wire things up yourself.
              '';
            };
            forceSSL = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether to also set forceSSL=true on each of `vhosts`.
                Disable if a vhost needs a custom (e.g. non-standard-port)
                redirect instead of nginx's default one.
              '';
            };
            certFile = lib.mkOption {
              type = lib.types.path;
              readOnly = true;
              default = "${certDir name}/cert.pem";
            };
            keyFile = lib.mkOption {
              type = lib.types.path;
              readOnly = true;
              default = "${certDir name}/key.pem";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services = lib.mapAttrs' (
      name: c:
      lib.nameValuePair "self-signed-cert-${name}" {
        description = "Generate self-signed TLS cert for ${c.hostName}";
        before = [ "nginx.service" ];
        wantedBy = [ "nginx.service" ];
        unitConfig.ConditionPathExists = "!${c.certFile}";
        path = [ pkgs.openssl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = ''
          mkdir -p ${certDir name}
          openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 \
            -keyout ${c.keyFile} -out ${c.certFile} \
            -subj "/CN=${c.hostName}" \
            -addext "subjectAltName=DNS:${c.hostName}${lib.concatMapStrings (s: ",${s}") c.extraSANs}"
          chown root:nginx ${c.keyFile}
          chmod 0640 ${c.keyFile}
        '';
      }
    ) cfg;

    services.nginx.virtualHosts = lib.mkMerge (
      lib.flatten (
        lib.mapAttrsToList (
          _: c:
          map (vhostName: {
            ${vhostName} = {
              sslCertificate = c.certFile;
              sslCertificateKey = c.keyFile;
            }
            // lib.optionalAttrs c.forceSSL { forceSSL = true; };
          }) c.vhosts
        ) cfg
      )
    );
  };
}
