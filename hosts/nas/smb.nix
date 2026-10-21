{
  config,
  lib,
  pkgs,
  ...
}:

{
  sops.defaultSopsFile = ../../secrets/nas.yaml;

  sops.secrets."samba/dennis" = {
    # re-run the password service whenever the secret changes
    restartUnits = [ "samba-set-password.service" ];
  };

  # The Samba user needs a Unix account to map to
  users.users.dennis = {
    isSystemUser = true; # or reuse your existing user instead
    group = "dennis";
  };
  users.groups.dennis = { };

  systemd.services.samba-set-password = {
    description = "Set Samba password for dennis from sops secret";
    wantedBy = [ "multi-user.target" ];
    before = [ "samba-smbd.service" ];
    requiredBy = [ "samba-smbd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      pw="$(cat ${config.sops.secrets."samba/dennis".path})"
      printf '%s\n%s\n' "$pw" "$pw" | ${pkgs.samba}/bin/smbpasswd -a -s dennis
    '';
  };

  services.samba = {
    enable = true;
    openFirewall = false; # open 445 yourself, see below
    settings = {
      global = {
        "server min protocol" = "SMB3";
        "server smb encrypt" = "required";
        "map to guest" = "never";
        "restrict anonymous" = "2";
        "hosts allow" = "192.168.50. 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
        "disable netbios" = "yes";
        "smb ports" = "445";
        "server signing" = "mandatory";
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "log level" = "1";
      };
      drive = {
        path = "/tank/drive";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "dennis";
        "force user" = "dennis";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 445 ];
}
