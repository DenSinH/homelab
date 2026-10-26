{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Local Caddy listener. NOT 8080: the CrowdSec LAPI defaults to 127.0.0.1:8080.
  proxyPort = 8081;

  proxies = {
    "status.dennishilhorst.nl" = {
      upstream = "http://${lib.lxcs.gatus.ip}";
    };
    "blog.dennishilhorst.nl" = {
      upstream = "http://${lib.lxcs.blog.ip}";
    };
    "cdn.dennishilhorst.nl" = {
      # Cache control set via
      # https://dash.cloudflare.com/ > Caching > Cache Rules
      # Hostname | equals | cdn.dennishilhorst.nl
      # (http.host eq "cdn.dennishilhorst.nl")
      #
      # Then...
      # Eligible for cache
      # Edge TTL: Ignore cache-control header and use this TTL: 6 Months
      # Browser TTL: Ignore cache-control header and use this TTL: 6 Months
      upstream = "http://${lib.lxcs.garage.ip}";
    };
    "chef.dennishilhorst.nl" = {
      upstream = "http://${lib.lxcs.cookbook.ip}";
    };
  };

  releasePins = {
    caddy-crowdsec-bouncer = {
      repo = "hslatman/caddy-crowdsec-bouncer";
      version = "0.14.1";
    };
  };

  releaseGuard = pkgs.writeShellApplication {
    name = "release-guard";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.gnused
      pkgs.coreutils
    ];
    text = ''
      if [ -e /run/skip-release-guard ]; then
        echo "release-guard: skipped via /run/skip-release-guard"
        exit 0
      fi

      fail=0
      ${lib.concatStrings (
        lib.mapAttrsToList (name: pin: ''
          latest=$(curl -fsS --max-time 15 \
            -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${pin.repo}/releases/latest" \
            | jq -r '.tag_name // empty' | sed 's/^v//') || latest=""

          if [ -z "$latest" ]; then
            echo "release-guard: WARN could not determine latest release of ${name}" >&2
          elif [ "$latest" != "${pin.version}" ] \
            && [ "$(printf '%s\n%s\n' "$latest" "${pin.version}" | sort -V | tail -n1)" = "$latest" ]; then
            echo "release-guard: FAIL ${name} pinned at ${pin.version}, latest is $latest" >&2
            echo "  bump releasePins.${name}.version and its hash, or touch /run/skip-release-guard" >&2
            fail=1
          else
            echo "release-guard: ${name} ${pin.version} is current"
          fi
        '') releasePins
      )}

      exit "$fail"
    '';
  };

  proxyListen = "bind 127.0.0.1";

  go1273 = pkgs.go_1_27.overrideAttrs (old: rec {
    version = "1.27.3";
    src = pkgs.fetchurl {
      url = "https://go.dev/dl/go${version}.src.tar.gz";
      hash = "sha256-bndJA1zzYPBrJXXRYup535/ajvZxiJ5cN1+OUHd/Jrs=";
    };
  });

  cloudflaredPackage = (
    pkgs.cloudflared.overrideAttrs (
      final: prev: {
        version = "2026.10.4";

        src = pkgs.fetchFromGitHub {
          owner = "cloudflare";
          repo = "cloudflared";
          tag = final.version;
          hash = "sha256-HuKjytbGutwjUMepozeUmeeHczm4qI7vMvS+hgLsaZ0=";
        };

        vendorHash = "sha256-WtGk5HE6PxAWqwvj8mAAzobuoSw+y6BqBEEB0hRQafk=";

        doCheck = false;

        nativeBuildInputs = builtins.filter (p: p != pkgs.go) prev.nativeBuildInputs ++ [ go1273 ];
      }
    )
  );
in
{
  imports = [ ./fail2ban.nix ];

  # https://search.nixos.org/options?channel=26.05&query=cloudflared
  # For initialization:
  # https://wiki.nixos.org/wiki/Cloudflared
  # on the LXC, run
  #   nix-shell -p cloudflared
  # and then
  #   cloudflared tunnel login
  #   cloudflared tunnel create <tunnel-name-of-choice>
  # the credits file is created by default in
  #   ~/.cloudflared/<tunnel-id>.json
  #
  # These last 2 steps do NOT need to be done when setting up on a new host
  # though I have not copied over the cert.pem file
  sops.defaultSopsFile = ../../secrets/cloudflared.yaml;
  sops.secrets = {
    "cloudflared/tunnel-creds" = { };
  };

  # ---- deploy guard ----
  system.preSwitchChecks.release-guard = ''
    ${releaseGuard}/bin/release-guard || exit 1
  '';

  # ---- cloudflared: all hosts go through the local Caddy ----
  services.cloudflared = {
    enable = true;

    # Package update required for security
    # (Received email on 26-10-2026 telling me to update to at least 2026.10.2)
    # TODO: remove this with 26.11
    package = cloudflaredPackage;

    tunnels."2520e8d8-cf93-4acf-a433-a3706133195f" = {
      credentialsFile = config.sops.secrets."cloudflared/tunnel-creds".path;
      ingress = lib.mapAttrs (host: _: {
        service = "http://127.0.0.1:${toString proxyPort}";
        originRequest = {
          httpHostHeader = host;
          originServerName = host;
        };
      }) proxies;
      default = "http_status:404";
    };
  };

  # ---- Caddy with the CrowdSec bouncer plugin ----
  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [
        "github.com/${releasePins.caddy-crowdsec-bouncer.repo}@v${releasePins.caddy-crowdsec-bouncer.version}"
      ];
      hash = "sha256-cEx69XLcug8ZCtpfspZJZVPkSysZkJK67xGbvFi1QOo=";
    };

    environmentFile = "/run/crowdsec-caddy-bouncer/env";

    globalConfig = ''
      auto_https off
      order crowdsec first
      crowdsec {
        api_url http://127.0.0.1:8080
        api_key {$CROWDSEC_API_KEY}
      }
      servers {
        # only cloudflared (loopback) may set the client IP header
        trusted_proxies static 127.0.0.1/32
        client_ip_headers CF-Connecting-IP
      }
    '';

    virtualHosts =
      (lib.mapAttrs' (
        host: proxy:
        lib.nameValuePair "http://${host}:${toString proxyPort}" {
          logFormat = "output stderr"; # -> journald, read by CrowdSec and fail2ban
          extraConfig = ''
            ${proxyListen}
            route {
              crowdsec
              reverse_proxy ${proxy.upstream}
            }
          '';
        }
      ) proxies)
      // {
        "http://:${toString proxyPort}".extraConfig = ''
          ${proxyListen}
          respond 404
        '';
      };
  };

  # ---- CrowdSec engine ----
  systemd.services.crowdsec-register-caddy-bouncer = {
    description = "Create and register the Caddy bouncer key for the local CrowdSec API";
    wantedBy = [ "multi-user.target" ];
    after = [ "crowdsec.service" ];
    requires = [ "crowdsec.service" ];
    before = [ "caddy.service" ];
    path = [
      pkgs.openssl
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "crowdsec-caddy-bouncer"; # /var/lib/..., root-only
      RuntimeDirectory = "crowdsec-caddy-bouncer"; # /run/..., holds the env file
      RuntimeDirectoryPreserve = true;
      StateDirectoryMode = "0700";
      RuntimeDirectoryMode = "0700";
    };
    script = builtins.readFile ./register-caddy-bouncer.sh;
  };

  systemd.services.caddy = {
    requires = [ "crowdsec-register-caddy-bouncer.service" ];
    after = [ "crowdsec-register-caddy-bouncer.service" ];
  };

  # verify crowdsec works with your own IP (https://whatsmyip.com/):
  #   sudo cscli decisions add -i <your-ip> -d 5m
  # wait 10 seconds, you should get a 403 when going to the website
  #   sudo cscli decisions delete -i <your-ip>
  services.crowdsec = {
    enable = true;
    name = "cloudflared";

    hub.collections = [
      "crowdsecurity/caddy"
      "crowdsecurity/base-http-scenarios"
      "crowdsecurity/http-cve"
    ];

    localConfig.acquisitions = [
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=caddy.service" ];
        labels.type = "caddy";
      }
    ];

    settings = {
      general.api.server = {
        enable = true;
        listen_uri = "127.0.0.1:8080";
      };
      lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";
      capi.credentialsFile = "/var/lib/crowdsec/state/online_api_credentials.yaml";
    };
  };
  users.users.crowdsec.extraGroups = [ "systemd-journal" ];

  # diagnostic script
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ban-status" ''
      set -e

      jails=$(
        sudo fail2ban-client status |
          sed -n 's/.*Jail list:[[:space:]]*//p' |
          tr ',' ' '
      )

      echo "=== Fail2Ban jails ==="
      for jail in $jails; do
        echo
        echo "[$jail]"
        sudo fail2ban-client status "$jail" |
          grep -E 'Currently failed|Currently banned|Total failed|Total banned|Banned IP list'
      done

      echo
      echo "=== All banned IPs (CrowdSec scenarios + fail2ban) ==="
      # --limit 0 disables the default cap; add -a to also include the community blocklist
      sudo cscli decisions list --limit 0 -o json |
        ${pkgs.jq}/bin/jq -r '
          (. // [])[] | .decisions[]?
          | [.value, .origin, .scenario, .duration] | @tsv
        ' |
        sort -u |
        ${pkgs.util-linux}/bin/column -t -s "$(printf '\t')" \
          -N IP,ORIGIN,REASON,REMAINING
      echo
      echo "Total: $(sudo cscli decisions list --limit 0 -o json | ${pkgs.jq}/bin/jq '[(. // [])[] | .decisions[]?] | length') decisions"

      echo
      echo "=== Bouncers (is Caddy pulling decisions?) ==="
      sudo cscli bouncers list
    '')
  ];

  # cloudflared logs its own level (ERR/WRN/INF); WRN-level lines often still
  # contain the word "error" (e.g. in an `error=` field), which gets
  # mis-detected by Loki as an actual error.
  homelab.alloy.extraLokiProcessConfig = ''
    stage.match {
      selector = "{unit=~\"cloudflared-tunnel-.*\"} |~ \" WRN \""

      stage.template {
        source   = "level"
        template = "warn"
      }

      stage.structured_metadata {
        values = {
          level = "",
        }
      }
    }
  '';
}
