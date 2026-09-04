#!/bin/sh

require_freebsd() {
  if [ "$(uname -s)" != "FreeBSD" ]; then
    echo >&2 "This script is for FreeBSD."
    exit 1
  fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo >&2 "Run this script as root."
    exit 1
  fi
}

backup_and_install() {
  source_file=$1
  target_file=$2
  file_mode=${3:-0644}

  if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
    return 0
  fi

  if [ -e "$target_file" ]; then
    backup=$(mktemp "${target_file}.dotfiles-backup.$(date +%Y%m%d%H%M%S).XXXXXX")
    cp -p "$target_file" "$backup"
    echo "Backed up $target_file to $backup"
  fi

  install -m "$file_mode" "$source_file" "$target_file"
}

set_sysctl_persistent() {
  key=$1
  value=$2
  config_file=${3:-/etc/sysctl.conf}
  temp_file=$(mktemp /tmp/dotfiles-sysctl.XXXXXX)

  if [ -f "$config_file" ]; then
    awk -F= -v key="$key" '
      {
        lhs = $1
        gsub(/[[:space:]]/, "", lhs)
        if (lhs != key)
          print
      }
    ' "$config_file" > "$temp_file"
  fi

  printf '%s=%s\n' "$key" "$value" >> "$temp_file"

  if [ -f "$config_file" ] && cmp -s "$temp_file" "$config_file"; then
    rm -f "$temp_file"
    sysctl "$key=$value"
    return 0
  fi

  if [ -e "$config_file" ]; then
    backup=$(mktemp "${config_file}.dotfiles-backup.$(date +%Y%m%d%H%M%S).XXXXXX")
    cp -p "$config_file" "$backup"
    echo "Backed up $config_file to $backup"
  fi

  install -m 0644 "$temp_file" "$config_file"
  rm -f "$temp_file"
  sysctl "$key=$value"
}
