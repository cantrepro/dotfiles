#!/bin/sh

set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scripts="${root_dir}/scripts"

if [ "$(uname -s)" != "FreeBSD" ]; then
  echo >&2 "This setup is for FreeBSD."
  exit 1
fi

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

desktop_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

require_user() {
  if [ "$(id -u)" -eq 0 ]; then
    echo >&2 "Run user and desktop setup as the target login user, not root."
    exit 1
  fi
}

setup_user() {
  require_user
  "$scripts/installpackages"
  "$scripts/restow"

  if [ ! -e "$HOME/bin" ]; then
    ln -s "$scripts" "$HOME/bin"
  elif [ -L "$HOME/bin" ] && [ "$(readlink "$HOME/bin")" = "$scripts" ]; then
    :
  else
    echo "INFO: $HOME/bin already exists; scripts were not linked."
  fi
}

setup_desktop() {
  require_user
  user_name=$(desktop_user)
  as_root pw groupmod video -m "$user_name"
  as_root sysrc dbus_enable=YES
  as_root service dbus onestart || as_root service dbus restart
  echo "INFO: install and enable the correct DRM driver for this machine."
}

usage() {
  cat <<'EOF'
Usage: ./setup.sh [user|desktop|system|firewall|disable-ipv6|all]

  user          Install packages, stow configs, and link ~/bin (default).
  desktop       Add the user to video and enable D-Bus.
  system        Configure audit, DNS, lid behavior, and Xorg touchpad.
  firewall      Install the PF workstation ruleset (backs up /etc/pf.conf).
  disable-ipv6  Disable IPv6 configuration and request a reboot.
  all           Run user, desktop, and system; firewall remains explicit.
EOF
}

action=${1:-user}

case "$action" in
  user)
    setup_user
    ;;
  desktop)
    setup_desktop
    ;;
  system)
    as_root "$scripts/enablesec"
    as_root "$scripts/fixdns"
    as_root "$scripts/fixlid"
    as_root "$scripts/fixpad"
    ;;
  firewall)
    as_root "$scripts/setupfw4"
    ;;
  disable-ipv6)
    as_root "$scripts/disableip6"
    ;;
  all)
    setup_user
    setup_desktop
    as_root "$scripts/enablesec"
    as_root "$scripts/fixdns"
    as_root "$scripts/fixlid"
    as_root "$scripts/fixpad"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
