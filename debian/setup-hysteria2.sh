#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Standalone Debian 13 VPS setup; no domain or other dotfiles are required.
# Install: sudo bash setup-hysteria2.sh
# Override detection: sudo bash setup-hysteria2.sh --server-ip 203.0.113.10
# See --help for options. Run this on the VPS, then copy the exported client
# profiles to your machine. Allow the selected UDP port in the provider firewall.
# Upstream documentation:
# https://v2.hysteria.network/docs/getting-started/Server-Installation-Script/
# https://v2.hysteria.network/docs/advanced/Full-Client-Config/

CONFIG_DIR=/etc/hysteria
STATE_DIR=$CONFIG_DIR/setup-hysteria2
CLIENT_DIR=/root/hysteria2-client
FIREWALL_HELPER=/usr/local/libexec/hysteria2-open-port
DROP_IN=/etc/systemd/system/hysteria-server.service.d/50-setup-hysteria2.conf
MARKER='# Managed by setup-hysteria2.sh'
SERVER_IP=
PORT=
SKIP_FIREWALL=0
FORCE=0
WORK_DIR=

usage() {
    cat <<'EOF'
Usage: sudo bash setup-hysteria2.sh [options]

  --server-ip IP     Public IPv4 or IPv6 address clients will connect to.
                     Default: reuse the saved address, or detect the public IP.
  --port PORT        UDP listening port (default: saved port, or 443).
  --skip-firewall    Manage firewall allowances yourself.
  --force            Back up and replace an existing unmanaged server config.
  -h, --help         Show this help without changing the system.

Requires Debian 13, systemd, root, and Internet access. Installs dependencies and
the latest Hysteria 2 using https://get.hy2.sh/. Uses a self-signed certificate
with SHA-256 pinning; a domain and ACME are unnecessary.

Reruns refresh the generated configuration and client files, preserving the
password, certificate, address, and port. Existing server configs are backed up.
Exports a connection URI, proxy profile, Linux TUN profile, and instructions to
/root/hysteria2-client/ (accessible only to root).

Open the selected UDP port in your VPS provider's firewall/security group too.
For all-machine traffic, enable VPN/TUN mode in your Hysteria 2 client, or use
the generated Linux TUN profile. A proxy profile covers configured apps only.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'printf "ERROR: Setup failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

while (( $# )); do
    case "$1" in
        --server-ip|--port)
            (( $# >= 2 )) || die "Missing value for $1."
            if [[ "$1" == --server-ip ]]; then SERVER_IP=$2; else PORT=$2; fi
            shift 2
            ;;
        --skip-firewall) SKIP_FIREWALL=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use --help." ;;
    esac
done

if [[ -n "$PORT" ]]; then
    [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die 'Port must be an integer from 1 to 65535.'
    PORT=$((10#$PORT))
    (( PORT >= 1 && PORT <= 65535 )) || die 'Port must be from 1 to 65535.'
fi
(( EUID == 0 )) || die 'Run this script on the VPS with sudo bash setup-hysteria2.sh.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || die 'This script requires Debian 13.'
[[ -d /run/systemd/system ]] || die 'systemd must be running (use a VPS, not a container without systemd).'

if [[ -f "$CONFIG_DIR/config.yaml" ]]; then
    if ! head -n 1 "$CONFIG_DIR/config.yaml" | grep -Fxq "$MARKER" && (( ! FORCE )); then
        die "An existing unmanaged $CONFIG_DIR/config.yaml was found. Use --force to back it up and replace it."
    fi
fi

printf 'Installing Debian dependencies...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl python3 iproute2 nftables

if [[ -z "$SERVER_IP" && -f "$STATE_DIR/server-ip" ]]; then
    SERVER_IP=$(cat "$STATE_DIR/server-ip")
fi
if [[ -z "$PORT" && -f "$STATE_DIR/port" ]]; then
    PORT=$(cat "$STATE_DIR/port")
fi
PORT=${PORT:-443}
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || die 'Saved port is invalid; supply --port.'
PORT=$((10#$PORT))
(( PORT >= 1 && PORT <= 65535 )) || die 'Port must be from 1 to 65535.'

curl_https() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --retry 3 "$@"
}

if [[ -z "$SERVER_IP" ]]; then
    printf 'Detecting the VPS public IP...\n'
    SERVER_IP=$(curl_https --ipv4 --max-time 15 https://api.ipify.org) || SERVER_IP=
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl_https --ipv6 --max-time 15 https://api6.ipify.org) || SERVER_IP=
    fi
    [[ -n "$SERVER_IP" ]] || die 'Public IP detection failed. Rerun with --server-ip YOUR_VPS_IP.'
fi
# Normalize IPv6 and reject hostnames, CIDRs, and text that could corrupt configs.
SERVER_IP=$(python3 - "$SERVER_IP" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.ip_address(sys.argv[1].strip())
    if getattr(address, "scope_id", None):
        raise ValueError("scoped addresses are not public endpoints")
    print(address)
except ValueError:
    sys.exit("Invalid --server-ip: supply a public IPv4 or IPv6 address without a port.")
PY
)

# Do not displace another UDP service. A running Hysteria is restarted below.
LISTENERS=$(ss -H -lunp "sport = :$PORT")
if [[ -n "$LISTENERS" ]] && printf '%s\n' "$LISTENERS" | grep -v '"hysteria"' >/dev/null; then
    die "UDP port $PORT is already used by another process. Choose --port PORT."
fi

WORK_DIR=$(mktemp -d /tmp/setup-hysteria2.XXXXXXXX)
if [[ -f "$CONFIG_DIR/config.yaml" ]]; then
    BACKUP="$CONFIG_DIR/config.yaml.bak.$(date -u +%Y%m%dT%H%M%S).$$"
    cp -a -- "$CONFIG_DIR/config.yaml" "$BACKUP"
    chmod 600 "$BACKUP"
    printf 'Saved existing server config: %s\n' "$BACKUP"
fi

printf 'Installing Hysteria 2 using the official installer...\n'
curl_https https://get.hy2.sh/ --output "$WORK_DIR/install-hysteria.sh"
HYSTERIA_USER=hysteria HYSTERIA_HOME_DIR=/var/lib/hysteria bash "$WORK_DIR/install-hysteria.sh"
[[ -x /usr/local/bin/hysteria ]] || die 'The official installer did not install the Hysteria executable.'
getent passwd hysteria >/dev/null || die 'The official installer did not create the hysteria user.'

install -d -m 750 -o root -g hysteria "$CONFIG_DIR" "$CONFIG_DIR/tls"
install -d -m 700 -o root -g root "$STATE_DIR" "$CLIENT_DIR"
if [[ ! -f "$STATE_DIR/password" ]]; then
    openssl rand -hex 32 > "$STATE_DIR/password"
fi
chmod 600 "$STATE_DIR/password"
PASSWORD=$(cat "$STATE_DIR/password")
[[ "$PASSWORD" =~ ^[0-9a-f]{64}$ ]] || die "Invalid saved password in $STATE_DIR/password."

CERT=$CONFIG_DIR/tls/server.crt
KEY=$CONFIG_DIR/tls/server.key
if [[ ! -e "$CERT" && ! -e "$KEY" ]]; then
    printf 'Generating a TLS certificate...\n'
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -nodes \
        -days 3650 -subj '/CN=hysteria' -addext 'subjectAltName=DNS:hysteria' \
        -keyout "$WORK_DIR/server.key" -out "$WORK_DIR/server.crt"
    install -m 640 -o root -g hysteria "$WORK_DIR/server.key" "$KEY"
    install -m 640 -o root -g hysteria "$WORK_DIR/server.crt" "$CERT"
else
    [[ -f "$CERT" && -f "$KEY" ]] || die "Both $CERT and $KEY must exist; restore the missing file before rerunning."
    openssl x509 -checkend 86400 -noout -in "$CERT" || die 'The saved TLS certificate has expired or expires within a day. Replace the certificate/key and update all client pins.'
    CERT_PUBLIC=$(openssl x509 -pubkey -noout -in "$CERT")
    KEY_PUBLIC=$(openssl pkey -pubout -in "$KEY")
    [[ "$CERT_PUBLIC" == "$KEY_PUBLIC" ]] || die 'The saved TLS certificate and private key do not match.'
    chown root:hysteria "$CERT" "$KEY"
    chmod 640 "$CERT" "$KEY"
fi
FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT")
FINGERPRINT=${FINGERPRINT#*=}
FINGERPRINT=${FINGERPRINT//:/}
[[ "$FINGERPRINT" =~ ^[0-9A-Fa-f]{64}$ ]] || die 'Could not calculate the certificate fingerprint.'

cat > "$WORK_DIR/config.yaml" <<EOF
$MARKER
listen: ":$PORT"
tls:
  cert: "$CERT"
  key: "$KEY"
auth:
  type: password
  password: "$PASSWORD"
EOF
install -m 640 -o root -g hysteria "$WORK_DIR/config.yaml" "$CONFIG_DIR/config.yaml"
printf '%s\n' "$SERVER_IP" > "$STATE_DIR/server-ip"
printf '%s\n' "$PORT" > "$STATE_DIR/port"

# Reapply the UDP allowance at service start and boot, after firewall services.
# No ruleset is flushed and no default policy or SSH rule is changed.
install -d -m 755 /usr/local/libexec
cat > "$WORK_DIR/open-port" <<'PY'
#!/usr/bin/python3
import json
import shutil
import subprocess
import sys

port = int(sys.argv[1])
if not 1 <= port <= 65535:
    sys.exit("Invalid Hysteria UDP port")

def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)

if shutil.which("ufw"):
    status = run(["ufw", "status"], capture_output=True).stdout
    if "Status: active" in status:
        run(["ufw", "allow", f"{port}/udp", "comment", "Hysteria 2"])
        sys.exit(0)

if shutil.which("firewall-cmd"):
    status = subprocess.run(["firewall-cmd", "--state"], capture_output=True, text=True)
    if status.returncode == 0:
        # Cover interfaces assigned to a non-default zone as well.
        active = run(["firewall-cmd", "--get-active-zones"], capture_output=True).stdout
        zones = {line for line in active.splitlines() if line and not line[0].isspace()}
        zones.add(run(["firewall-cmd", "--get-default-zone"], capture_output=True).stdout.strip())
        for zone in sorted(zones):
            for persistence in ([], ["--permanent"]):
                run(["firewall-cmd", *persistence, f"--zone={zone}", f"--add-port={port}/udp"])
        sys.exit(0)

# nftables is Debian 13's native firewall. An accept in a separate table cannot
# override a drop in an existing table, so add an allowance in each INPUT chain.
ruleset = json.loads(run(["nft", "--json", "list", "ruleset"], capture_output=True).stdout)
marker = "setup-hysteria2"
commands = []
for item in ruleset["nftables"]:
    rule = item.get("rule", {})
    if rule.get("comment") == marker:
        commands.append("delete rule {} {} {} handle {}".format(
            rule["family"], json.dumps(rule["table"]), json.dumps(rule["chain"]), int(rule["handle"])))
for item in ruleset["nftables"]:
    chain = item.get("chain", {})
    if (chain.get("family") in {"inet", "ip", "ip6"}
            and chain.get("hook") == "input" and chain.get("type") == "filter"):
        commands.append("insert rule {} {} {} udp dport {} counter accept comment {}".format(
            chain["family"], json.dumps(chain["table"]), json.dumps(chain["name"]), port, json.dumps(marker)))
if commands:
    # Submit one atomic transaction, including removal of our previous allowance.
    run(["nft", "-f", "-"], input="\n".join(commands) + "\n")
else:
    print("No nftables INPUT filters found; no local UDP allowance is needed.")
PY
install -m 700 -o root -g root "$WORK_DIR/open-port" "$FIREWALL_HELPER"

install -d -m 755 "${DROP_IN%/*}"
cat > "$WORK_DIR/service.conf" <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target nftables.service ufw.service firewalld.service

[Service]
Restart=on-failure
RestartSec=3
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/hysteria
ExecStartPre=
EOF
if (( ! SKIP_FIREWALL )); then
    # '+' runs just the firewall helper with root privileges. Hysteria itself
    # runs as the hysteria user with only the capability to bind privileged ports.
    printf 'ExecStartPre=+%s %s\n' "$FIREWALL_HELPER" "$PORT" >> "$WORK_DIR/service.conf"
fi
install -m 644 -o root -g root "$WORK_DIR/service.conf" "$DROP_IN"

printf 'Enabling and starting the VPN service...\n'
systemctl daemon-reload
systemctl enable hysteria-server.service
if ! systemctl restart hysteria-server.service; then
    journalctl -u hysteria-server.service -n 40 --no-pager >&2
    die 'Hysteria failed to start; inspect the service logs above.'
fi
# Type=simple may report active before the configuration has been loaded.
READY=0
for (( ATTEMPT=0; ATTEMPT<15; ATTEMPT++ )); do
    sleep 1
    if systemctl is-active --quiet hysteria-server.service \
        && ss -H -lunp "sport = :$PORT" | grep -q '"hysteria"'; then
        READY=1
        break
    fi
done
if (( ! READY )); then
    journalctl -u hysteria-server.service -n 40 --no-pager >&2
    die "Hysteria did not open UDP port $PORT."
fi

ENDPOINT=$SERVER_IP:$PORT
if [[ "$SERVER_IP" == *:* ]]; then ENDPOINT=[$SERVER_IP]:$PORT; fi
URI="hysteria2://$PASSWORD@$ENDPOINT/?sni=hysteria&insecure=1&pinSHA256=$FINGERPRINT#VPS-Hysteria2"
cat > "$WORK_DIR/client-common.yaml" <<EOF
# Self-signed TLS: skip public-CA validation, but REQUIRE this certificate pin.
server: "$ENDPOINT"
auth: "$PASSWORD"
tls:
  sni: hysteria
  insecure: true
  pinSHA256: "$FINGERPRINT"
EOF
cp "$WORK_DIR/client-common.yaml" "$WORK_DIR/client-proxy.yaml"
cat >> "$WORK_DIR/client-proxy.yaml" <<'EOF'
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF
cp "$WORK_DIR/client-common.yaml" "$WORK_DIR/client-tun.yaml"
cat >> "$WORK_DIR/client-tun.yaml" <<'EOF'
tun:
  name: hytun
  mtu: 1400
  address:
    ipv4: 100.100.100.101/30
    ipv6: fd00:100:100::1/126
  route:
    ipv4: ["0.0.0.0/0"]
    ipv6: ["::/0"]
EOF
if [[ "$SERVER_IP" == *:* ]]; then
    printf '    ipv6Exclude: ["%s/128"]\n' "$SERVER_IP" >> "$WORK_DIR/client-tun.yaml"
else
    printf '    ipv4Exclude: ["%s/32"]\n' "$SERVER_IP" >> "$WORK_DIR/client-tun.yaml"
fi
install -m 600 -o root -g root "$WORK_DIR/client-proxy.yaml" "$CLIENT_DIR/client-proxy.yaml"
install -m 600 -o root -g root "$WORK_DIR/client-tun.yaml" "$CLIENT_DIR/client-tun.yaml"
printf '%s\n' "$URI" > "$CLIENT_DIR/connection.txt"

cat > "$CLIENT_DIR/README.txt" <<EOF
Hysteria 2 server: $ENDPOINT (UDP)

1. Allow inbound UDP $PORT in your VPS provider firewall/security group.
   For a VPS behind NAT, forward this UDP port to the VPS as well.
2. Copy these files over SSH to your machine. They contain your VPN password.
   Example from your machine (replace VPS_SSH_HOST with your SSH host):
     scp -r root@VPS_SSH_HOST:/root/hysteria2-client ./
   If root SSH is disabled, use your normal SSH account and sudo to read them:
     ssh -t USER@VPS_SSH_HOST 'sudo cat /root/hysteria2-client/connection.txt'
3. Import connection.txt's URI into a Hysteria 2 client and enable its VPN/TUN
   mode to send your machine's traffic through the VPS. Keep certificate pinning
   enabled: the URI and profiles contain the server's SHA-256 fingerprint.

Official CLI client (install on YOUR machine, not just on the VPS):
  https://v2.hysteria.network/docs/getting-started/Installation/

Proxy mode, without root privileges:
  hysteria client -c client-proxy.yaml
  Configure apps to use SOCKS5 127.0.0.1:1080 or HTTP 127.0.0.1:8080.
  Check the exit IP in another terminal:
    curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org

Linux TUN mode, to route TCP/UDP traffic from the whole machine:
  sudo hysteria client -c client-tun.yaml
  The VPS address is excluded from the tunnel to prevent a routing loop.
  Both IPv4 and IPv6 are routed; IPv6 destinations require IPv6 on the VPS.
  Choose different TUN addresses if these overlap with your existing networks.
  DNS is not changed automatically. Use a public resolver such as 1.1.1.1,
  so a DNS server at your local router does not become unreachable in the tunnel.
  With systemd-resolved, after hytun appears, use another terminal:
    sudo resolvectl dns hytun 1.1.1.1 1.0.0.1
    sudo resolvectl domain hytun '~.'
  If Linux drops TUN traffic due to reverse-path filtering, try:
    sudo sysctl -w net.ipv4.conf.default.rp_filter=2 net.ipv4.conf.all.rp_filter=2
  Check the exit IP with: curl -4 https://api.ipify.org
  Stop the client with Ctrl-C to remove the TUN interface and routes.
  This profile targets Linux; macOS needs a utun interface name. TUN forwards
  TCP/UDP traffic; ICMP is not forwarded. Verify with curl instead of ping.

VPS administration:
  systemctl status hysteria-server.service
  journalctl -u hysteria-server.service -f
  systemctl restart hysteria-server.service
  systemctl disable --now hysteria-server.service
  Server config: $CONFIG_DIR/config.yaml

Local firewall: active UFW/firewalld allowances are saved by those tools.
Otherwise nftables INPUT allowances are reapplied whenever the service starts.
After manually reloading nftables, restart hysteria-server.service as well.
Custom OUTPUT/PREROUTING rules and iptables-legacy firewalls must be managed
separately. Changing --port may leave an old UFW/firewalld allowance to remove.
No automatic killswitch is installed on your machine.

Rerun setup-hysteria2.sh to refresh or upgrade, keeping the same password/cert.
Reruns replace the generated configs; keep any custom changes in your own copy.
Use --server-ip or --port to change the saved endpoint, then copy/import the
updated client files. Replacing the TLS certificate requires updating client
pins too. Existing server configuration backups are in $CONFIG_DIR/config.yaml.bak.*
EOF

printf '\nHysteria 2 is running on %s (UDP).\n' "$ENDPOINT"
printf 'Allow inbound UDP %s in the VPS provider firewall.\n' "$PORT"
printf 'Client files and connection instructions: %s/\n' "$CLIENT_DIR"
printf 'For all-machine traffic, import this URI and enable VPN/TUN mode:\n\n%s\n\n' "$URI"
printf 'Logs: journalctl -u hysteria-server.service -f\n'
