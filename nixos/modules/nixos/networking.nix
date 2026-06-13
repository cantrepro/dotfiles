{ ... }:
{
  networking.enableIPv6 = false;
  networking.nameservers = [ "8.8.8.8" ];

  networking.networkmanager.enable = false;
  networking.dhcpcd.enable = true;

  networking.resolvconf.enable = true;
  services.resolved.enable = false;

  networking.wireless.iwd = {
    enable = true;
    settings = {
      General = {
        EnableNetworkConfiguration = true;
      };
      Network = {
        EnableIPv6 = false;
        NameResolvingService = "resolvconf";
      };
    };
  };

  networking.firewall = {
    enable = true;
    allowPing = true;
    logReversePathDrops = true;
  };
}
