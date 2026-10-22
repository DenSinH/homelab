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
      services. Add an entry here, then point the consuming nginx vhost's
      sslCertificate/sslCertificateKey at the entry's certFile/keyFile.
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
  };
}
