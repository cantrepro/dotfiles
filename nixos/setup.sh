#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_VARS_FILE="${ROOT_DIR}/hosts/default/host-vars.nix"
HARDWARE_FILE="${ROOT_DIR}/hosts/default/hardware-configuration.nix"

if [[ ! -e /etc/NIXOS ]]; then
  echo "ERROR: setup.sh is intended for NixOS hosts only."
  exit 1
fi

if ! command -v nixos-rebuild >/dev/null 2>&1; then
  echo "ERROR: nixos-rebuild is not available."
  exit 1
fi

USERNAME="${DOTNIX_USER:-${SUDO_USER:-$USER}}"
HOSTNAME="${DOTNIX_HOSTNAME:-$(hostname)}"
FULL_NAME="${DOTNIX_FULL_NAME:-$USERNAME}"
GIT_USERNAME="${DOTNIX_GIT_USERNAME:-$USERNAME}"
EMAIL="${DOTNIX_EMAIL:-${USERNAME}@example.org}"
TIMEZONE="${DOTNIX_TIMEZONE:-$(timedatectl show --property=Timezone --value 2>/dev/null || echo UTC)}"
STATE_VERSION="${DOTNIX_STATE_VERSION:-}"

if [[ -z "${STATE_VERSION}" && -r /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  if [[ "${ID:-}" == "nixos" && "${VERSION_ID:-}" =~ ^[0-9]{2}\\.[0-9]{2}$ ]]; then
    STATE_VERSION="${VERSION_ID}"
  fi
fi

if [[ -z "${STATE_VERSION}" ]]; then
  STATE_VERSION="25.05"
fi

case "$(uname -m)" in
  x86_64)
    SYSTEM="x86_64-linux"
    ;;
  aarch64|arm64)
    SYSTEM="aarch64-linux"
    ;;
  *)
    echo "ERROR: Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

cat > "${HOST_VARS_FILE}" <<EOF_HOSTVARS
{
  system = "${SYSTEM}";
  hostName = "${HOSTNAME}";
  userName = "${USERNAME}";
  fullName = "${FULL_NAME}";
  gitUserName = "${GIT_USERNAME}";
  email = "${EMAIL}";
  timeZone = "${TIMEZONE}";
  stateVersion = "${STATE_VERSION}";
}
EOF_HOSTVARS

if [[ -r /etc/nixos/hardware-configuration.nix ]]; then
  cp /etc/nixos/hardware-configuration.nix "${HARDWARE_FILE}"
else
  echo "WARN: /etc/nixos/hardware-configuration.nix not found."
  echo "WARN: Create ${HARDWARE_FILE} manually before rebuilding."
fi

echo "INFO: Applying flake configuration for ${USERNAME}@${HOSTNAME}"
sudo nixos-rebuild switch --flake "${ROOT_DIR}#default"

echo "INFO: Setup complete."
