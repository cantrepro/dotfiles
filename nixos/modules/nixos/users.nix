{ pkgs, hostVars, ... }:
{
  users.users.${hostVars.userName} = {
    isNormalUser = true;
    description = hostVars.fullName;
    shell = pkgs.bashInteractive;
    extraGroups = [
      "wheel"
      "audio"
      "video"
      "input"
      "kvm"
      "libvirtd"
      "docker"
    ];
  };
}
