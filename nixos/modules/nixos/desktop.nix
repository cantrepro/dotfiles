{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    xkb.layout = "us";

    displayManager.startx.enable = true;
    desktopManager.xterm.enable = false;
    windowManager.i3.enable = true;

    libinput = {
      enable = true;
      touchpad = {
        tapping = true;
        scrollMethod = "twofinger";
        disableWhileTyping = false;
      };
    };
  };

  security.polkit.enable = true;
  programs.dconf.enable = true;

  hardware.bluetooth.enable = false;

  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  fonts.packages = with pkgs; [
    dejavu_fonts
    noto-fonts
  ];
}
