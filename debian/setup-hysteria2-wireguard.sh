#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Run on the Debian 13 VPS, not on the machine hosting these dotfiles.
# sudo bash setup-hysteria2-wireguard.sh --wg-config /root/vpn.conf
# sudo bash setup-hysteria2-wireguard.sh --status
# sudo bash setup-hysteria2-wireguard.sh --remove
# References:
# https://v2.hysteria.network/docs/advanced/Full-Server-Config/
# https://manpages.debian.org/trixie/wireguard-tools/wg-quick.8.en.html
# https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html

STATE_DIR=/var/lib/hysteria2-wireguard
WG_INTERFACE=hy2wg
WG_TARGET=/etc/wireguard/hy2wg.conf
ROUTE_TABLE=51888
RULE_PRIORITY=100
DNS_PORT=1053
TUNNEL_SERVICE=hysteria2-wireguard.service
DNS_SERVICE=hysteria2-wireguard-dns.service
HELPER=/usr/local/libexec/hysteria2-wireguard-route
SERVICE=hysteria-server.service
CONFIG=/etc/hysteria/config.yaml
WG_CONFIG=
DNS=
ACTION=install
FORCE=0
WORK_DIR=
TRANSACTION=0
DROP_IN=

usage() {
    cat <<'EOF'
Usage (on the Debian 13 VPS):
  sudo bash setup-hysteria2-wireguard.sh --wg-config /root/vpn.conf [options]
  sudo bash setup-hysteria2-wireguard.sh --status
  sudo bash setup-hysteria2-wireguard.sh --remove [--force]

  --wg-config FILE  WireGuard provider's standard wg-quick client configuration.
  --dns IP          DNS server reached through WireGuard. Default: first usable
                    DNS IP in that configuration, otherwise 1.1.1.1.
  --config FILE     Existing Hysteria server YAML (default: /etc/hysteria/config.yaml).
  --service UNIT    Existing systemd service (default: hysteria-server.service).
  --status          Show installed services, tunnel handshake and routing.
  --remove          Restore the original Hysteria configuration and remove this
                    script's services/routing. Keep the original backup.
  --force           With --remove only: restore even if Hysteria YAML was edited.
  -h, --help        Show this help without changing the system.

Requires root, Debian 13, systemd, a RUNNING Hysteria 2 server, Internet access,
and a WireGuard peer that permits Internet access. Installs wireguard-tools,
iproute2, dnsmasq-base and python3-yaml. Existing Hysteria credentials, listener,
certificates and client profiles stay valid; clients reconnect during setup.

Replaces Hysteria's outbounds, ACL and resolver so every forwarded TCP/UDP
connection uses WireGuard. An isolated DNS forwarder listens on 127.0.0.1:1053
and sends upstream queries through WireGuard. The host's DNS/default routes,
SSH, firewall and IP-forwarding settings are not changed. Existing firewall
rules must permit outbound WireGuard UDP and traffic on the tunnel interface.

Supports one peer with Address, PrivateKey, PublicKey, Endpoint and full IPv4
AllowedIPs (0.0.0.0/0). IPv6 forwarding is enabled only when both an IPv6 Address
and ::/0 are present; otherwise IPv6 destinations fail without a direct fallback.
Split tunnels and wg-quick shell hooks are rejected. DNS/Table/SaveConfig/FwMark
are replaced in the managed copy; Address prefixes become /32 or /128 to avoid
installing connected subnet routes in the host's main table. The input is intact.

Services start at boot, with no direct outbound fallback when VPN/DNS is down.
To change the VPN, --remove first, then install again. Backups contain secrets
and are stored under /var/lib/hysteria2-wireguard with root-only directory access.
After setup, verify the exit IP from a CONNECTED Hysteria client. For SOCKS mode:
  curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
Client-side DNS outside Hysteria still depends on the client's VPN/proxy settings.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

restore_original() {
    local failed=0
    # Stop Hysteria before removing its tunnel, including on failed installation.
    systemctl stop "$SERVICE" || failed=1
    systemctl stop "$DNS_SERVICE" "$TUNNEL_SERVICE" || failed=1
    if [[ -x "$HELPER" ]]; then "$HELPER" down || failed=1; fi
    systemctl disable "$TUNNEL_SERVICE" "$DNS_SERVICE" >/dev/null 2>&1 || true
    rm -f -- "$DROP_IN" "/etc/systemd/system/$TUNNEL_SERVICE" \
        "/etc/systemd/system/$DNS_SERVICE" "$HELPER" "$WG_TARGET"
    cp -a -- "$STATE_DIR/original-config" "$CONFIG" || failed=1
    systemctl daemon-reload || failed=1
    systemctl reset-failed "$SERVICE" "$DNS_SERVICE" "$TUNNEL_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$SERVICE" || failed=1
    if (( failed )); then
        printf 'Restore encountered an error; backup remains at %s/original-config.\n' "$STATE_DIR" >&2
        return 1
    fi
    rm -f -- "$STATE_DIR/installed" "$STATE_DIR/installing"
    touch "$STATE_DIR/restored"
}

cleanup() {
    local result=$?
    trap - EXIT
    if (( TRANSACTION )); then
        printf 'Setup did not complete; restoring the original Hysteria setup...\n' >&2
        restore_original || result=1
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
    exit "$result"
}
trap cleanup EXIT
trap 'printf "ERROR: Command failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

while (( $# )); do
    case "$1" in
        --wg-config|--dns|--config|--service)
            (( $# >= 2 )) || die "Missing value for $1."
            case "$1" in
                --wg-config) WG_CONFIG=$2 ;;
                --dns) DNS=$2 ;;
                --config) CONFIG=$2 ;;
                --service) SERVICE=$2 ;;
            esac
            shift 2 ;;
        --status|--remove)
            [[ "$ACTION" == install ]] || die 'Choose just one action.'
            ACTION=${1#--}; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use --help." ;;
    esac
done
(( ! FORCE )) || [[ "$ACTION" == remove ]] || die '--force is only supported with --remove.'
if [[ "$ACTION" == install ]]; then
    [[ -n "$WG_CONFIG" && -f "$WG_CONFIG" ]] || die 'Supply --wg-config with an existing WireGuard configuration.'
fi
[[ "$SERVICE" == *.service ]] || SERVICE+=.service
[[ "$SERVICE" =~ ^[a-zA-Z0-9_@.-]+\.service$ ]] || die 'Invalid systemd service name.'
[[ "$SERVICE" != "$TUNNEL_SERVICE" && "$SERVICE" != "$DNS_SERVICE" ]] || die 'Choose the Hysteria service.'
(( EUID == 0 )) || die 'Run this script on the VPS as root (sudo bash ...).'
# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || die 'This script requires Debian 13.'
[[ -d /run/systemd/system ]] || die 'systemd must be running.'
exec 9>/run/lock/setup-hysteria2-wireguard.lock
flock -n 9 || die 'Another instance of this script is running.'

if [[ "$ACTION" != install ]]; then
    [[ -f "$STATE_DIR/service" && -f "$STATE_DIR/config-path" ]] || die 'No saved installation was found.'
    SERVICE=$(cat "$STATE_DIR/service")
    CONFIG=$(cat "$STATE_DIR/config-path")
    DROP_IN=/etc/systemd/system/$SERVICE.d/90-wireguard-egress.conf
    if [[ "$ACTION" == status ]]; then
        systemctl --no-pager --full status "$SERVICE" "$TUNNEL_SERVICE" "$DNS_SERVICE" || true
        wg show "$WG_INTERFACE" || true
        ip -4 rule show
        ip -4 route show table "$ROUTE_TABLE" || true
        ip -6 rule show
        ip -6 route show table "$ROUTE_TABLE" || true
        exit 0
    fi
    [[ ! -f "$STATE_DIR/restored" ]] || die 'The original configuration has already been restored.'
    if (( ! FORCE )) && [[ -f "$STATE_DIR/managed-config.sha256" ]]; then
        EXPECTED=$(cat "$STATE_DIR/managed-config.sha256")
        CURRENT=$(sha256sum -- "$CONFIG"); CURRENT=${CURRENT%% *}
        [[ "$CURRENT" == "$EXPECTED" ]] || die "Hysteria config has changed. Save your edits, then use --remove --force to restore $STATE_DIR/original-config."
    fi
    restore_original || die 'Restore failed; inspect the services and saved backup.'
    printf 'Original Hysteria configuration restored. Backup retained in %s.\n' "$STATE_DIR"
    exit 0
fi

if [[ -d "$STATE_DIR" && ! -f "$STATE_DIR/restored" ]]; then
    die 'A previous installation or unfinished setup exists. Use --status or --remove before installing again.'
fi
[[ -f "$CONFIG" ]] || die "Hysteria configuration does not exist: $CONFIG"
CONFIG_REQUESTED=$CONFIG
CONFIG=$(realpath -- "$CONFIG")
[[ "$CONFIG" =~ ^/[a-zA-Z0-9_./-]+$ ]] || die 'Use a Hysteria config path without spaces or special characters.'
[[ "$CONFIG" == *.yaml || "$CONFIG" == *.yml ]] || die 'The Hysteria config must be a .yaml or .yml file.'
DROP_IN=/etc/systemd/system/$SERVICE.d/90-wireguard-egress.conf
for TARGET in "$WG_TARGET" "$HELPER" "$DROP_IN" "/etc/systemd/system/$TUNNEL_SERVICE" "/etc/systemd/system/$DNS_SERVICE"; do
    [[ ! -e "$TARGET" && ! -L "$TARGET" ]] || die "Refusing to overwrite existing file: $TARGET"
done
systemctl is-active --quiet "$SERVICE" || die "The Hysteria service $SERVICE must already be running."
EXEC_START=$(systemctl show "$SERVICE" --property=ExecStart --value)
[[ "$EXEC_START" == *"$CONFIG_REQUESTED"* || "$EXEC_START" == *"$CONFIG"* ]] \
    || die 'The selected config path is absent from the service ExecStart. Supply the actual --service and --config.'
[[ "$(systemctl show "$SERVICE" --property=PrivateNetwork --value)" != yes ]] \
    || die 'Hysteria must use the host network namespace (PrivateNetwork=no).'
[[ -z "$(systemctl show "$SERVICE" --property=NetworkNamespacePath --value)" ]] \
    || die 'A Hysteria service in a separate network namespace is not supported.'

printf 'Installing Debian dependencies...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends wireguard-tools iproute2 dnsmasq-base python3-yaml
ip link show dev "$WG_INTERFACE" >/dev/null 2>&1 && die "Interface $WG_INTERFACE already exists."

# Reserve only unused policy-routing resources. The rules must follow the local
# table but precede other policies which could capture device-bound sockets.
python3 - "$ROUTE_TABLE" "$RULE_PRIORITY" "$DNS_PORT" <<'PY'
import json
import socket
import subprocess
import sys
table, priority, port = map(int, sys.argv[1:])
for family in ("-4", "-6"):
    rules = json.loads(subprocess.check_output(["ip", family, "-j", "rule", "show"]))
    for rule in rules:
        pref = rule.get("priority", 32766)
        is_local = pref == 0 and str(rule.get("table")) in ("local", "255")
        if (pref <= priority and not is_local) or str(rule.get("table")) == str(table):
            sys.exit(f"Routing priority <= {priority} or table {table} is in use; refusing to override it.")
    routes = subprocess.run(["ip", family, "-j", "route", "show", "table", str(table)],
                            text=True, capture_output=True)
    if routes.returncode == 0 and json.loads(routes.stdout):
        sys.exit(f"Routing table {table} is already in use.")
    if routes.returncode != 0 and "FIB table does not exist" not in routes.stderr:
        sys.exit(routes.stderr or "Unable to inspect routing tables.")
for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            sys.exit(f"Local DNS port {port} is already in use.")
PY

WORK_DIR=$(mktemp -d /tmp/setup-hysteria2-wireguard.XXXXXXXX)
cp -a -- "$CONFIG" "$WORK_DIR/hysteria.yaml"

# Parse inputs instead of doing text substitutions in YAML or running arbitrary
# provider hooks. This stage does not touch the running service or host routing.
python3 - "$WG_CONFIG" "$WORK_DIR" "$DNS" "$WG_INTERFACE" "$DNS_PORT" <<'PY'
import base64
import ipaddress
from pathlib import Path
import re
import sys
import yaml

source, output, dns_override, interface, dns_port = sys.argv[1:]
output = Path(output)
sections = []
for number, raw in enumerate(Path(source).read_text().splitlines(), 1):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    if line in ("[Interface]", "[Peer]"):
        sections.append((line, {}))
        continue
    if not sections or "=" not in line:
        sys.exit(f"Invalid WireGuard configuration at line {number}.")
    key, value = (part.strip() for part in line.split("=", 1))
    if not value:
        sys.exit(f"Empty WireGuard setting at line {number}.")
    settings = sections[-1][1]
    if key in settings and key not in ("Address", "DNS", "AllowedIPs"):
        sys.exit(f"Duplicate WireGuard setting: {key}.")
    settings[key] = settings.get(key, "") + (", " if key in settings else "") + value

if [name for name, _ in sections] != ["[Interface]", "[Peer]"]:
    sys.exit("Supply a standard WireGuard client configuration with one Interface and one Peer.")
local, peer = (settings for _, settings in sections)
supported_local = {"PrivateKey", "Address", "DNS", "MTU", "ListenPort", "Table", "SaveConfig", "FwMark"}
supported_peer = {"PublicKey", "PresharedKey", "AllowedIPs", "Endpoint", "PersistentKeepalive"}
unknown = (set(local) - supported_local) | (set(peer) - supported_peer)
if unknown:
    sys.exit("Unsupported WireGuard options (shell hooks are not run): " + ", ".join(sorted(unknown)))
for settings, required in ((local, ("PrivateKey", "Address")),
                           (peer, ("PublicKey", "AllowedIPs", "Endpoint"))):
    for key in required:
        if key not in settings:
            sys.exit(f"Missing WireGuard setting: {key}.")
for settings, key in ((local, "PrivateKey"), (peer, "PublicKey"), (peer, "PresharedKey")):
    if key in settings:
        try:
            if len(base64.b64decode(settings[key], validate=True)) != 32:
                raise ValueError()
        except (ValueError, base64.binascii.Error):
            sys.exit(f"Invalid WireGuard {key} (expected a base64-encoded 32-byte key).")
try:
    addresses = [ipaddress.ip_interface(value.strip()) for value in local["Address"].split(",")]
    allowed = {ipaddress.ip_network(value.strip(), strict=False) for value in peer["AllowedIPs"].split(",")}
except ValueError:
    sys.exit("Invalid WireGuard Address or AllowedIPs.")
if not any(addr.version == 4 for addr in addresses) or ipaddress.ip_network("0.0.0.0/0") not in allowed:
    sys.exit("The VPN must have an IPv4 Address and full-tunnel AllowedIPs = 0.0.0.0/0.")
ipv6 = any(addr.version == 6 for addr in addresses) and ipaddress.ip_network("::/0") in allowed
for addr in addresses:
    if addr.ip.is_unspecified or addr.ip.is_multicast or addr.ip.is_loopback or addr.ip.is_link_local or getattr(addr.ip, "scope_id", None):
        sys.exit("WireGuard Address must be an unscoped unicast tunnel address.")
if ipv6 and Path("/proc/sys/net/ipv6/conf/all/disable_ipv6").read_text().strip() == "1":
    sys.exit("The VPN specifies IPv6, but this host has IPv6 disabled.")
for settings, key, low, high in ((local, "MTU", 1280 if ipv6 else 576, 9000),
                                 (local, "ListenPort", 0, 65535),
                                 (peer, "PersistentKeepalive", 0, 65535)):
    if key in settings and (not settings[key].isdigit() or not low <= int(settings[key]) <= high):
        sys.exit(f"Invalid WireGuard {key}.")
endpoint = peer["Endpoint"]
match = re.fullmatch(r"(?:\[([0-9a-fA-F:]+)\]|([a-zA-Z0-9._-]+)):(\d{1,5})", endpoint)
if not match or not 1 <= int(match.group(3)) <= 65535:
    sys.exit("Invalid WireGuard Endpoint; expected hostname:port, IPv4:port or [IPv6]:port.")
if match.group(1):
    try:
        ipaddress.IPv6Address(match.group(1))
    except ValueError:
        sys.exit("Invalid IPv6 WireGuard Endpoint.")

def usable_dns(value):
    try:
        addr = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if (addr.is_unspecified or addr.is_multicast or addr.is_loopback or addr.is_link_local
            or getattr(addr, "scope_id", None) or (addr.version == 6 and not ipv6)
            or any(addr == tunnel.ip for tunnel in addresses)):
        return None
    return str(addr)

if dns_override:
    dns = usable_dns(dns_override)
    if dns is None:
        sys.exit("--dns must be a non-local IP supported by this WireGuard tunnel.")
else:
    dns = next((value for part in local.get("DNS", "").split(",") if (value := usable_dns(part))), "1.1.1.1")

# /32 and /128 prevent a provider's Address prefix from diverting host subnets.
lines = ["[Interface]", "PrivateKey = " + local["PrivateKey"],
         "Address = " + ", ".join(f"{addr.ip}/{32 if addr.version == 4 else 128}" for addr in addresses
                                   if addr.version == 4 or ipv6), "Table = off"]
for key in ("MTU", "ListenPort"):
    if key in local:
        lines.append(f"{key} = {local[key]}")
lines.extend(["", "[Peer]", "PublicKey = " + peer["PublicKey"]])
if "PresharedKey" in peer:
    lines.append("PresharedKey = " + peer["PresharedKey"])
lines.extend(["AllowedIPs = 0.0.0.0/0" + (", ::/0" if ipv6 else ""),
              "Endpoint = " + endpoint,
              "PersistentKeepalive = " + peer.get("PersistentKeepalive", "25")])
(output / "hy2wg.conf").write_text("\n".join(lines) + "\n")
(output / "ipv6").write_text("1\n" if ipv6 else "0\n")
(output / "dns").write_text(dns + "\n")
source4 = next(str(addr.ip) for addr in addresses if addr.version == 4)
source6 = next((str(addr.ip) for addr in addresses if addr.version == 6), "") if ipv6 else ""
(output / "source4").write_text(source4 + "\n")
(output / "source6").write_text(source6 + "\n")
dns_source = source6 if ipaddress.ip_address(dns).version == 6 else source4

# Reject duplicate YAML keys instead of silently losing settings.
class UniqueLoader(yaml.SafeLoader):
    pass
# YAML 1.2 (used by Hysteria) treats on/off/yes/no as strings. PyYAML's default
# YAML 1.1 interpretation would change an unquoted password such as "off".
UniqueLoader.yaml_implicit_resolvers = {
    key: [(tag, pattern) for tag, pattern in resolvers if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
UniqueLoader.add_implicit_resolver("tag:yaml.org,2002:bool",
                                 re.compile(r"^(?:true|false|True|False|TRUE|FALSE)$"), list("tTfF"))
def construct_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    pairs = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in pairs:
            raise ValueError("Duplicate YAML key")
        pairs[key] = loader.construct_object(value_node, deep=deep)
    return pairs
UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)
config_path = output / "hysteria.yaml"
try:
    config = yaml.load(config_path.read_text(), Loader=UniqueLoader)
except (yaml.YAMLError, ValueError, TypeError):
    sys.exit("Hysteria YAML could not be parsed (check syntax and duplicate keys).")
if not isinstance(config, dict) or not (config.get("tls") or config.get("acme")) or not config.get("auth"):
    sys.exit("The selected YAML must contain a Hysteria server's TLS/ACME and auth configuration.")
config.pop("acl", None)
config["outbounds"] = [{"name": "wireguard", "type": "direct", "direct": {
    "mode": "auto" if ipv6 else "4", "bindDevice": interface}}]
config["resolver"] = {"type": "udp", "udp": {"addr": f"127.0.0.1:{dns_port}", "timeout": "5s"}}
config_path.write_text(yaml.safe_dump(config, sort_keys=False, allow_unicode=True))

(output / "dnsmasq.conf").write_text(f"""# Managed by setup-hysteria2-wireguard.sh
port={dns_port}
listen-address=127.0.0.1
bind-interfaces
no-resolv
no-poll
no-hosts
cache-size=1000
server={dns}@{interface}@{dns_source}
user=root
group=root
pid-file=
log-facility=-
""")
print(f"Prepared IPv4{'/IPv6' if ipv6 else '-only'} WireGuard egress; DNS {dns} through {interface}.")
PY
python3 - "$WORK_DIR/hy2wg.conf" <<'PY'
import ipaddress
import json
from pathlib import Path
import subprocess
import sys
existing = json.loads(subprocess.check_output(["ip", "-j", "address", "show"]))
assigned = {ipaddress.ip_address(addr["local"]) for link in existing for addr in link.get("addr_info", [])}
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("Address = "):
        for value in line.split("=", 1)[1].split(","):
            address = ipaddress.ip_interface(value.strip()).ip
            if address in assigned:
                sys.exit(f"WireGuard address {address} is already assigned on this host; refusing to duplicate it.")
PY
dnsmasq --test --conf-file="$WORK_DIR/dnsmasq.conf"

# A dedicated table is consulted only for sockets explicitly bound to hy2wg.
# The unreachable route prevents falling through if a tunnel route is removed.
cat > "$WORK_DIR/route-helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WG_INTERFACE=hy2wg
WG_CONFIG=/etc/wireguard/hy2wg.conf
TABLE=51888
PRIORITY=100
IPV6=$(cat /var/lib/hysteria2-wireguard/ipv6)
SOURCE4=$(cat /var/lib/hysteria2-wireguard/source4)
SOURCE6=$(cat /var/lib/hysteria2-wireguard/source6)

down() {
    for family in -4 -6; do
        ip "$family" rule del priority "$PRIORITY" oif "$WG_INTERFACE" table "$TABLE" 2>/dev/null || true
        ip "$family" route flush table "$TABLE" 2>/dev/null || true
    done
    if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
        wg-quick down "$WG_CONFIG"
    fi
}
case "${1:-}" in
    up)
        # An installation check reserves the name/table; do not borrow another WG.
        if ip link show dev "$WG_INTERFACE" >/dev/null 2>&1; then
            printf 'Interface %s already exists.\n' "$WG_INTERFACE" >&2
            exit 1
        fi
        trap 'down' ERR
        wg-quick up "$WG_CONFIG"
        for family in -4 -6; do
            ip "$family" route add unreachable default table "$TABLE" metric 32767
            if [[ "$family" == -4 || "$IPV6" == 1 ]]; then
                SOURCE=$SOURCE4
                if [[ "$family" == -6 ]]; then SOURCE=$SOURCE6; fi
                ip "$family" route add default dev "$WG_INTERFACE" src "$SOURCE" table "$TABLE" metric 10
            fi
            ip "$family" rule add priority "$PRIORITY" oif "$WG_INTERFACE" table "$TABLE"
        done
        # Strict reverse-path filtering would compare tunnel replies to the
        # physical default route. Limit this adjustment to the new WG interface.
        printf '2\n' > "/proc/sys/net/ipv4/conf/$WG_INTERFACE/rp_filter"
        ;;
    down) down ;;
    *) printf 'Usage: %s up|down\n' "$0" >&2; exit 2 ;;
esac
EOF

cat > "$WORK_DIR/tunnel.service" <<EOF
[Unit]
Description=WireGuard egress for Hysteria 2
Wants=network-online.target $SERVICE
After=network-online.target
Before=$DNS_SERVICE $SERVICE

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER up
ExecStop=$HELPER down
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
cat > "$WORK_DIR/dns.service" <<EOF
[Unit]
Description=Hysteria 2 DNS through WireGuard
BindsTo=$TUNNEL_SERVICE
After=$TUNNEL_SERVICE
PartOf=$TUNNEL_SERVICE
Before=$SERVICE

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=$STATE_DIR/dnsmasq.conf
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
cat > "$WORK_DIR/hysteria.conf" <<EOF
[Unit]
BindsTo=$TUNNEL_SERVICE $DNS_SERVICE
After=$TUNNEL_SERVICE $DNS_SERVICE
PartOf=$TUNNEL_SERVICE $DNS_SERVICE

[Service]
# SO_BINDTODEVICE on TCP/UDP sockets requires CAP_NET_RAW. These lines add to
# existing capabilities, including the privileged-port capability.
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
EOF

if [[ -d "$STATE_DIR" ]]; then
    mv -- "$STATE_DIR" "$STATE_DIR.backup.$(date -u +%Y%m%dT%H%M%S).$$"
fi
install -d -m 700 -o root -g root "$STATE_DIR"
cp -a -- "$CONFIG" "$STATE_DIR/original-config"
printf '%s\n' "$SERVICE" > "$STATE_DIR/service"
printf '%s\n' "$CONFIG" > "$STATE_DIR/config-path"
touch "$STATE_DIR/installing"
TRANSACTION=1
install -d -m 700 /etc/wireguard
install -d -m 755 /usr/local/libexec "${DROP_IN%/*}"
install -m 600 "$WORK_DIR/hy2wg.conf" "$WG_TARGET"
install -m 600 "$WORK_DIR/ipv6" "$STATE_DIR/ipv6"
install -m 600 "$WORK_DIR/source4" "$STATE_DIR/source4"
install -m 600 "$WORK_DIR/source6" "$STATE_DIR/source6"
install -m 600 "$WORK_DIR/dnsmasq.conf" "$STATE_DIR/dnsmasq.conf"
install -m 600 "$WORK_DIR/dns" "$STATE_DIR/dns"
install -m 700 "$WORK_DIR/route-helper" "$HELPER"
install -m 644 "$WORK_DIR/tunnel.service" "/etc/systemd/system/$TUNNEL_SERVICE"
install -m 644 "$WORK_DIR/dns.service" "/etc/systemd/system/$DNS_SERVICE"
systemctl daemon-reload
systemctl start "$TUNNEL_SERVICE" "$DNS_SERVICE"

# Trigger traffic through the isolated resolver, then require a real handshake
# and a valid DNS response before switching the existing Hysteria server.
printf 'Checking WireGuard handshake and tunneled DNS (up to 30 seconds)...\n'
python3 - "$WG_INTERFACE" "$DNS_PORT" <<'PY'
import os
import socket
import struct
import subprocess
import sys
import time
interface, port = sys.argv[1], int(sys.argv[2])
deadline = time.monotonic() + 30
labels = b"".join(bytes([len(label)]) + label for label in (b"example", b"com")) + b"\0"
while time.monotonic() < deadline:
    ident = os.urandom(2)
    query = ident + struct.pack("!HHHHH", 0x0100, 1, 0, 0, 0) + labels + struct.pack("!HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.connect(("127.0.0.1", port))
        try:
            sock.send(query)
            reply = sock.recv(4096)
        except OSError:
            reply = b""
    handshakes = subprocess.check_output(["wg", "show", interface, "latest-handshakes"], text=True)
    if (len(reply) >= 12 and reply[:2] == ident and reply[2] & 0x80 and reply[3] & 15 == 0
            and struct.unpack("!H", reply[6:8])[0] > 0
            and any(int(line.split()[1]) > 0 for line in handshakes.splitlines())):
        break
    time.sleep(1)
else:
    sys.exit("VPN handshake/DNS check failed. Check peer credentials, provider routing, firewall and --dns.")
PY

printf 'Switching Hysteria client forwarding to WireGuard...\n'
systemctl stop "$SERVICE"
cp -a -- "$WORK_DIR/hysteria.yaml" "$CONFIG"
install -m 644 "$WORK_DIR/hysteria.conf" "$DROP_IN"
systemctl daemon-reload
systemctl enable "$TUNNEL_SERVICE" "$DNS_SERVICE"
systemctl start "$SERVICE"
sleep 3
for CHECK_SERVICE in "$SERVICE" "$TUNNEL_SERVICE" "$DNS_SERVICE"; do
    systemctl is-active --quiet "$CHECK_SERVICE" \
        || die "Service $CHECK_SERVICE failed to stay active. Check journalctl -u $CHECK_SERVICE."
done
MAIN_PID=$(systemctl show "$SERVICE" --property=MainPID --value)
[[ "$MAIN_PID" =~ ^[1-9][0-9]*$ ]] || die 'Hysteria has no running main process.'
LISTENERS=$(ss -H -lunp)
grep -Fq "pid=$MAIN_PID," <<< "$LISTENERS" || die 'The Hysteria process did not open a UDP listener.'
MANAGED_HASH=$(sha256sum -- "$CONFIG"); MANAGED_HASH=${MANAGED_HASH%% *}
printf '%s\n' "$MANAGED_HASH" > "$STATE_DIR/managed-config.sha256"
mv -- "$STATE_DIR/installing" "$STATE_DIR/installed"
TRANSACTION=0

printf '\nHysteria client TCP/UDP and server-side DNS now use WireGuard (%s).\n' "$WG_INTERFACE"
printf 'Services persist across reboots. IPv6 is %s.\n' "$(if [[ "$(cat "$STATE_DIR/ipv6")" == 1 ]]; then printf enabled; else printf 'blocked for forwarded destinations'; fi)"
printf 'Original Hysteria config: %s/original-config\n' "$STATE_DIR"
printf 'Verify the VPN exit IP from a connected Hysteria client, for example:\n'
printf '  curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org\n'
printf 'Inspect: sudo bash setup-hysteria2-wireguard.sh --status\n'
printf 'Restore: sudo bash setup-hysteria2-wireguard.sh --remove\n'
