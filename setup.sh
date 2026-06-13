#!/usr/bin/env bash

set -e

run_command() {
    echo "INFO: Running: $1"
    if eval "$1"; then
        echo "SUCCESS: Completed: $1"
    else
        echo "ERROR: Failed: $1"
        echo "Description: $2"
        exit 1
    fi
}

run_command "sudo ./scripts/disablelisteners" "Disable unnecessary network listeners."
run_command "sudo ./scripts/killbt" "Kill Bluetooth services."
run_command "sudo ./scripts/disableip6" "Disable IPv6."
run_command "sudo ./scripts/setupfw4" "Set up IPv4 firewall."
run_command "sudo ./scripts/enablefwd4" "Enable IPv4 forwarding."
run_command "sudo ./scripts/fixdns" "Fix DNS settings."
run_command "sudo ./scripts/fixlid" "Fix lid close action."
run_command "sudo ./scripts/fixpad" "Fix touchpad settings."
run_command "sudo dhcpcd wlan0" "Re-running DHCP."
run_command "sudo pkill dhcpcd" "Killing dhcpcd process."
run_command "./scripts/installpackages" "Install base packages."
run_command "rm -f ~/.bashrc" "Remove existing .bashrc."
run_command "rm -f ~/.bash_profile" "Remove existing .bash_profile."
run_command "./scripts/restow" "Restow dotfiles."
run_command "sudo ./scripts/enablesec" "Enable security features."

run_command "ln -sf \`pwd\`/scripts ~/bin" "Create symlink for scripts directory to ~/bin."
run_command "ln -sf /var/lib/libvirt/images ~/kvm" "Create symlink for KVM images."
run_command "sudo chown -R root:root scripts" "Set ownership of scripts directory to root."
run_command "sudo chown -R root:root ~/bin" "Set ownership of ~/bin directory to root."

run_command "sudo cp ./static/resolvconf.conf /etc/resolvconf.conf" "Copy resolvconf configuration."
run_command "sudo resolvconf -u" "Update resolvconf."
run_command "sudo cp ./static/main.conf /etc/iwd/main.conf" "Copy iwd configuration."
run_command "sudo systemctl restart iwd" "Restart iwd service."

run_command "sudo ./scripts/addbintopath" "Adding bin directory to secure path."

echo "INFO: All setup tasks completed successfully."
exit 0
