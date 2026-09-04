# FreeBSD port

This tree ports the parts of the Arch setup that have a useful FreeBSD
equivalent. It targets supported FreeBSD 14.x and 15.x releases and uses base
system conventions where possible: `pkg`, rc.d/`sysrc`, PF, `resolvconf`,
`dhclient`, Xorg under `/usr/local/etc`, and bhyve through `vm-bhyve`.

Nothing under this directory changes the Arch setup in the repository root.

## Setup

Run user setup as the login user:

```sh
cd ~/dotfiles/FreeBSD
./setup.sh user
./setup.sh desktop
```

The setup follows the original repository in assuming `sudo` is already
available. On a fresh install, bootstrap it first as root with
`pkg install sudo` and grant the login user the intended sudo policy.

`user` installs packages, restows all configs, and links `~/bin` to the
FreeBSD scripts. Stow intentionally refuses to overwrite existing files; move
or back up any conflicting dotfiles first. `desktop` adds the current user to
the `video` group and enables D-Bus. Install the DRM kernel module appropriate
for the machine separately (`drm-kmod`, an NVIDIA driver, or another driver).

The package list excludes qutebrowser because its FreeBSD port currently needs
to be built from the Ports Collection rather than installed as a binary
package:

```sh
cd /usr/ports/www/qutebrowser
sudo make install clean
```

Host-wide changes are opt-in:

```sh
./setup.sh system
./setup.sh disable-ipv6
./setup.sh firewall
```

`system` enables FreeBSD BSM auditing, restricts cross-user process visibility
and debugging, prepends Google DNS through resolvconf, ignores ACPI lid-close
events, and installs a libinput touchpad fragment. Each replaced regular file
gets a timestamped `*.dotfiles-backup.*` copy.

`disable-ipv6` requires a reboot to mark interfaces as IPv6-disabled.

## Firewall and routing

The firewall command installs a default-deny inbound PF ruleset. Run it from a
local console or add required inbound rules first if a remote connection must
survive. An existing `/etc/pf.conf` is backed up before replacement.

Dynamic rules are kept in `/etc/pf.anchors/dotfiles.conf`:

```sh
sudo ./scripts/opentcp 22 192.168.1.0/24
sudo ./scripts/openudp 51820 192.168.1.0/24
sudo ./scripts/closetcp 22 192.168.1.0/24
sudo ./scripts/closeudp 51820 192.168.1.0/24
```

Enable source NAT for a private network or bhyve switch:

```sh
sudo ./scripts/patinit enable em0 vm-public 192.168.23.0/24
sudo ./scripts/patinit disable em0 vm-public 192.168.23.0/24
```

Forward a TCP port to a guest, optionally restricting the source network:

```sh
sudo ./scripts/vm-port-forward enable em0 192.168.1.149 8080 192.168.23.2 8080 192.168.1.0/24
sudo ./scripts/vm-port-forward disable em0 192.168.1.149 8080 192.168.23.2 8080 192.168.1.0/24
```

## bhyve

`virtstart` replaces the KVM/libvirt bridge bootstrap with `vm-bhyve`. By
default it initializes `/vm` and a `public` switch at `192.168.23.1/24`:

```sh
sudo ./scripts/virtstart
sudo ./scripts/createbhyve freebsd-test default 50G FreeBSD.iso
```

The defaults can be changed with `VM_DIR`, `VM_SWITCH`, `VM_SWITCH_CIDR`, and
`VM_NETWORK`. `VM_DIR=zfs:zroot/vm` is supported when that dataset already
exists and has a normal mountpoint.

## Wireless examples

FreeBSD uses `wpa_supplicant` rather than iwd. After adapting the example and
the hardware interface name:

```sh
sudo install -m 0600 static/wpa_supplicant.conf.example /etc/wpa_supplicant.conf
sudo sysrc wlans_iwm0=wlan0
sudo sysrc ifconfig_wlan0="WPA SYNCDHCP"
sudo service netif restart
```

`static/hostapd.conf.example` is the FreeBSD hostapd equivalent. Set its
interface and credentials before installing it; then use
`sysrc hostapd_enable=YES` and `service hostapd start`.

## Port map

| Arch item | FreeBSD item |
| --- | --- |
| pacman package installer | `pkg` package installer |
| iptables firewall and open/close scripts | PF ruleset plus managed anchor |
| `net.ipv4.ip_forward` | `gateway_enable=YES` and `net.inet.ip.forwarding` |
| systemd audit service | base BSM `auditd` via rc.d |
| systemd lid policy | `hw.acpi.lid_switch_state=NONE` |
| Synaptics Xorg fragment | libinput fragment in `/usr/local/etc/X11/xorg.conf.d` |
| `lsmod` snapshot | `kldstat` snapshot |
| KVM/libvirt helpers | bhyve/`vm-bhyve` helpers |
| iwd configuration | `wpa_supplicant.conf` example |

The application configs remain separate Stow packages. FreeBSD-specific edits
include `/usr/local` executable paths, BSD `ls`/`sed` syntax, PF and `sockstat`
aliases, the FreeBSD Bash and Neovim paths, D-Bus X startup, and removal of
Linux-only GPU metrics. The i3status battery block uses FreeBSD's aggregate
ACPI battery interface.

## Deliberate omissions

- `dockerstart` and `dockerrun`: Docker is not a native FreeBSD runtime; jails
  and OCI-compatible jail tooling need a workload-specific design.
- `killbt`: Linux `rfkill` has no device-independent FreeBSD equivalent.
- `limitcharge` and the CPU/fan aliases: they write Linux, model-specific
  `/sys` controls.
- `disablelisteners`: it names systemd services. FreeBSD already leaves inetd
  disabled by default; audit listeners with `sockstat -46l` and disable each
  owning rc.d service explicitly.
- `setupfw6`: the PF ruleset handles IPv4 and IPv6 together.
- `vm-wg-pat`: it depends on Linux policy routing, iptables, `/proc`, and Linux
  WireGuard interface lifecycle. A correct FreeBSD design needs the actual
  tunnel addresses and routing policy; the generic PF NAT helper is retained.
- `addbintopath`: no username is hard-coded into sudo's secure path. Invoke
  privileged helpers as `sudo "$HOME/bin/helper"` or from this directory.
- AppArmor and Firejail settings: neither facility exists natively on FreeBSD;
  Capsicum, jails, MAC policies, and application-specific sandboxing are not
  interchangeable drop-in replacements.
