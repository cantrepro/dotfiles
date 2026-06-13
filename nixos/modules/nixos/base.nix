{ pkgs, hostVars, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  nixpkgs.config.allowUnfree = true;

  networking.hostName = hostVars.hostName;

  time.timeZone = hostVars.timeZone;
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  services.cron.enable = false;
  services.openssh.enable = false;

  programs.bash.enableCompletion = true;
  programs.firejail.enable = true;

  environment.systemPackages = with pkgs; [
    bc
    bind
    bridge-utils
    curl
    dhcpcd
    git
    gnupg
    inetutils
    iproute2
    iptables
    lm_sensors
    lsof
    neovim
    openresolv
    tree
    wget
  ];

  system.stateVersion = hostVars.stateVersion;
}
