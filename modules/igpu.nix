{
  config,
  pkgs,
  lib,
  ...
}:

let
  colorsScript = builtins.readFile ../scripts/colors.sh;
in
{
  # Check existence of
  # - /dev/dri/card*
  # - /dev/dri/renderD128
  # these devices need to be passed through
  system.activationScripts.check-igpu = ''
    ${colorsScript}

    render="/dev/dri/renderD128"
    cards=(/dev/dri/card*)

    has_card=false
    card_name=""

    if [[ -e "''${cards[0]}" ]]; then
      has_card=true
      card_name="$(basename "''${cards[0]}")"
    fi

    missing=false

    if ! $has_card; then
      print_error "No /dev/dri/card* device found."
      missing=true
    else
      print_success "/dev/dri/$card_name exists"
    fi

    if [[ ! -c "$render" ]]; then
      print_error "No /dev/dri/renderD128 device found."
      missing=true
    else
      print_success "/dev/dri/renderD128 exists"
    fi

    if $missing; then
      print_warning ""
      print_warning "GPU passthrough is not configured correctly for this LXC."
      print_warning ""
      print_warning "Add the following to your Proxmox container config:"
      print_warning ""
      if $has_card; then
        print_warning "dev0: /dev/dri/$card_name,gid=44"
      else
        print_warning "dev0: /dev/dri/cardX,gid=44"
        print_warning "(replace X with the correct card ID from your proxmox host)"
      fi
      print_warning "dev1: /dev/dri/renderD128,gid=104"
      print_warning ""
      print_warning "Or run: nix run .#config-dri -- $(hostname)"
    else
      print_success "iGPU passthrough correctly configured"
      print_success "Test by running:"
      print_success ""
      print_success "intel_gpu_top"
      print_success ""
      print_success "On the proxmox host, then:"
      print_success ""
      print_success "nix-shell -p ffmpeg --run \"ffmpeg -vaapi_device /dev/dri/renderD128 -f lavfi -i testsrc=duration=30:size=3840x2160:rate=60 -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null -\""
      print_success ""
      print_success "In the LXC"
    fi
  '';

  # Ensure /dev/dri exists and is populated
  services.udev.extraRules = ''
    KERNEL=="card*", SUBSYSTEM="drm", GROUP="video", MODE="0660"
    KERNEL=="renderD*", SUBSYSTEM="drm", GROUP="render", MODE="0660"
  '';

  systemd.tmpfiles.rules = [
    "d /dev/dri 0755 root root -"
  ];

  # Ensure the users exist
  users.groups.video = { };
  users.groups.render = { };

  hardware.graphics = {
    enable = true;
    extraPackages = [
      # todo: if I ever have a proxmox node with a different GPU,
      #       these need to be updated
      pkgs.intel-media-driver
    ];
  };
}
