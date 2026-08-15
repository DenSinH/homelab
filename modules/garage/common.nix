{
  pkgs,
  ...
}:

{
  # Default currently, but to ensure this never accidentally breaks
  # with some nix flake update
  garagePackage = pkgs.garage_2;

  # Internal hostname suffix used by Garage's web gateway.
  #
  # It does NOT need to exist in DNS. nginx connects to Garage on
  # localhost and supplies this Host header.
  garageWebDomain = "web.garage.internal";

  # garage / s3 config
  s3_region = "garage";
  s3_api_bind_port = 3900;
  s3_rpc_bind_port = 3901;
  s3_web_bind_port = 3902;
  s3_admin_bind_port = 3903;
}
