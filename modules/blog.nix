{
  pkgs,
  lib,
  ...
}:

let
  blogSrc = pkgs.fetchFromGitHub {
    owner = "DenSinH";
    repo = "blog";
    rev = "refs/heads/main";
    fetchSubmodules = true; # theme submodule
    hash = "sha256-IaDorbxZr1a+VsYzTBI/vmNw9ZIcf8NkQ2OTW/2Jtno=";
  };

  blog = pkgs.stdenvNoCC.mkDerivation {
    pname = "blog";
    version = "main";

    src = blogSrc;

    nativeBuildInputs = [
      pkgs.hugo
    ];

    buildPhase = ''
      runHook preBuild

      hugo --minify

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r public/* $out/

      runHook postInstall
    '';
  };
in
{
  services.nginx = {
    enable = true;

    virtualHosts.default = {
      default = true;
      root = blog;

      locations."/" = {
        tryFiles = "$uri $uri/ =404";
      };

      locations."~* \\.(js|css|png|jpg|jpeg|gif|svg|ico)$" = {
        extraConfig = ''
          expires 30d;
          add_header Cache-Control "public, immutable";
        '';
      };
    };
  };

  networking.firewall = {
    allowedTCPPorts = [
      80
    ];
  };
}
