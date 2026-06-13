{ ... }:
{
  virtualisation.libvirtd.enable = false;
  virtualisation.spiceUSBRedirection.enable = true;
  programs.virt-manager.enable = false;

  virtualisation.docker = {
    enable = false;
    daemon.settings = {
      iptables = false;
    };
  };
}
