{ config, pkgs, hostVars, ... }:
let
  pkgOr = name:
    if builtins.hasAttr name pkgs
    then [ builtins.getAttr name pkgs ]
    else [ ];
in
{
  home.username = hostVars.userName;
  home.homeDirectory = "/home/${hostVars.userName}";
  home.stateVersion = hostVars.stateVersion;

  programs.home-manager.enable = true;

  xdg.enable = true;

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.sessionVariables = {
    TERMINAL = "alacritty";
    LC_ALL = "en_US.UTF-8";
    LANG = "en_US.UTF-8";
    LANGUAGE = "en_US.UTF-8";
    PAGER = "less";
    VISUAL = "nvim";
    EDITOR = "nvim";
    BROWSER = "firefox";
    NO_AT_BRIDGE = "1";
  };

  programs.bash = {
    enable = true;
    enableCompletion = true;
    initExtra = builtins.readFile ../../configs/bash/.bashrc;
    profileExtra = builtins.readFile ../../configs/bash/.bash_profile;
  };

  programs.git = {
    enable = true;
    userName = hostVars.fullName;
    userEmail = hostVars.email;
    extraConfig = {
      user.username = hostVars.gitUserName;
      core.editor = "nvim";
    };
    aliases = {
      lg1 = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(bold yellow)%d%C(reset)' --all";
      lg2 = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(bold yellow)%d%C(reset)%n''          %C(white)%s%C(reset) %C(dim white)- %an%C(reset)' --all";
      lg = "!git lg1";
    };
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraConfig = builtins.readFile ../../configs/nvim/.config/nvim/init.vim;
  };

  home.packages = with pkgs; [
    alacritty
    aria2
    bash-completion
    bc
    bind
    btop
    bridge-utils
    clipmenu
    curl
    dialog
    dmenu
    dunst
    firefox
    git
    gnupg
    highlight
    httpie
    inetutils
    i3status
    less
    lm_sensors
    lsof
    lynx
    man-pages
    nmap
    obs-studio
    openresolv
    openssh
    picom
    wiremix
    qemu
    qutebrowser
    ranger
    ripgrep
    scrot
    slock
    tesseract
    tree
    unzip
    virt-manager
    virt-viewer
    wget
    xcalib
    xclip
    xdotool
    xorg.xinit
    xorg.xmodmap
    zip
    cronie
    netcat
    dhcpcd
    spice-gtk
    zathura
  ];

  home.file = {
    ".alacritty.toml".source = ../../configs/alacritty/.alacritty.toml;
    ".inputrc".source = ../../configs/readline/.inputrc;
    ".Xdefaults".source = ../../configs/xorg/.Xdefaults;
    ".xinitrc".source = ../../configs/xorg/.xinitrc;

    ".urxvt/ext/resize-font".source = ../../configs/urxvt/.urxvt/ext/resize-font;

    ".local/bin" = {
      source = ../../scripts;
      recursive = true;
    };

    ".local/share/dotnix/one-black-pixel.png".source = ../../static/one-black-pixel.png;
    ".local/share/dotnix/legacy/arch_packages".source = ../../static/arch_packages;
    ".local/share/dotnix/legacy/archinstall/user_configuration.json".source = ../../static/archinstall/user_configuration.json;
    ".local/share/dotnix/legacy/archinstall/user_credentials.json".source = ../../static/archinstall/user_credentials.json;

    ".local/state/dotnix/.gitignore".source = ../../state/.gitignore;

    "kvm".source = config.lib.file.mkOutOfStoreSymlink "/var/lib/libvirt/images";
  };

  xdg.configFile."btop/btop.conf".source = ../../configs/btop/.config/btop/btop.conf;
  xdg.configFile."dunst/dunstrc".source = ../../configs/dunst/.config/dunst/dunstrc;
  xdg.configFile."i3/config".source = ../../configs/i3/.config/i3/config;
  xdg.configFile."i3status/config".source = ../../configs/i3status/.config/i3status/config;
  xdg.configFile."parcellite/parcelliterc".source = ../../configs/parcellite/.config/parcellite/parcelliterc;
  xdg.configFile."picom/picom.conf".source = ../../configs/picom/.config/picom/picom.conf;
  xdg.configFile."qutebrowser/config.py".source = ../../configs/qutebrowser/.config/qutebrowser/config.py;
  xdg.configFile."spicy/settings".source = ../../configs/spicy/.config/spicy/settings;
  xdg.configFile."zathura/zathurarc".source = ../../configs/zathura/.config/zathura/zathurarc;
}
