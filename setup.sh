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

SECURE_PATH_LINE='Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/bin:/home/user/bin"'
SUDOERS_FILE="/etc/sudoers"
TEMP_SUDOERS=$(mktemp)

echo "INFO: Checking and updating sudoers secure_path..."
if sudo grep -q '^Defaults    secure_path=' "$SUDOERS_FILE"; then
    if ! sudo grep 'Defaults    secure_path=.*:/home/user/bin' "$SUDOERS_FILE"; then
        echo "INFO: Adding /home/user/bin to existing secure_path in $SUDOERS_FILE"
        sudo cp "$SUDOERS_FILE" "$TEMP_SUDOERS"
        sudo sed -i 's|^\(Defaults    secure_path=".*\)"|\1:/home/user/bin"|' "$TEMP_SUDOERS"
        if sudo visudo -cf "$TEMP_SUDOERS"; then
            sudo cp "$TEMP_SUDOERS" "$SUDOERS_FILE"
            echo "SUCCESS: Updated secure_path in $SUDOERS_FILE."
        else
            echo "ERROR: Failed to validate temporary sudoers file. No changes made to $SUDOERS_FILE."
            rm -f "$TEMP_SUDOERS"
            exit 1
        fi
        rm -f "$TEMP_SUDOERS"
    else
        echo "INFO: /home/user/bin already in secure_path in $SUDOERS_FILE."
    fi
else
    echo "INFO: Adding new secure_path with /home/user/bin to $SUDOERS_FILE"
    echo "$SECURE_PATH_LINE" | sudo tee -a "$TEMP_SUDOERS" > /dev/null
    if sudo visudo -cf "$TEMP_SUDOERS"; then
        sudo sh -c "cat '$TEMP_SUDOERS' >> '$SUDOERS_FILE'"
        echo "SUCCESS: Added secure_path to $SUDOERS_FILE."
    else
        echo "ERROR: Failed to validate temporary sudoers file. No changes made to $SUDOERS_FILE."
        rm -f "$TEMP_SUDOERS"
        exit 1
    fi
    rm -f "$TEMP_SUDOERS"
fi

run_command "sudo cp ./static/resolvconf.conf /etc/resolvconf.conf" "Copy resolvconf configuration."
run_command "sudo resolvconf -u" "Update resolvconf."
run_command "sudo cp ./static/main.conf /etc/iwd/main.conf" "Copy iwd configuration."
run_command "sudo systemctl restart iwd" "Restart iwd service."

echo "INFO: All setup tasks completed successfully."
exit 0
