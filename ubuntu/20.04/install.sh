#!/bin/bash

#
#   This script is a hard fork over the original Microsoft's Linux VM tools repository,
#   which can be found at: https://github.com/microsoft/linux-vm-tools.
#

# Check if we're running as root
if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run with root privileges' >&2
    exit 1
fi

# Update the machine if needed
apt update && apt upgrade -y

if [ -f /var/run/reboot-required ]; then
    echo "A reboot is required in order to proceed with the install." >&2
    echo "Please reboot and re-run this script to finish the install." >&2
    exit 1
fi

# Install additional kernel components
apt install -y linux-tools-generic-hwe-20.04
apt install -y linux-cloud-tools-generic-hwe-20.04

# Install XRDP
apt install -y xrdp

# Stop XRDP services before modifying files
systemctl stop xrdp
systemctl stop xrdp-sesman

# Do not use vsock transport since newer versions of XRDP do not support it
sed -i_orig -e 's/port=3389/port=vsock:\/\/-1:3389/g' /etc/xrdp/xrdp.ini
# Use rdp security
sed -i_orig -e 's/security_layer=negotiate/security_layer=rdp/g' /etc/xrdp/xrdp.ini
# Remove encryption validation
sed -i_orig -e 's/crypt_level=high/crypt_level=none/g' /etc/xrdp/xrdp.ini
# Disable bitmap compression since its local its much faster
sed -i_orig -e 's/bitmap_compression=true/bitmap_compression=false/g' /etc/xrdp/xrdp.ini
# Disable TCP keepalive for XRDP to reduce session dropouts while changing networks
sed -i_orig -e 's/tcp_keepalive=true/tcp_keepalive=false/g' /etc/xrdp/xrdp.ini

# Add script to setup the Ubuntu session properly
if [ ! -e /etc/xrdp/startubuntu.sh ]; then
cat >> /etc/xrdp/startubuntu.sh << EOF
#!/bin/sh
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
exec /etc/xrdp/startwm.sh
EOF
chmod a+x /etc/xrdp/startubuntu.sh
fi

# Use the script to setup the Ubuntu session
sed -i_orig -e 's/startwm/startubuntu/g' /etc/xrdp/sesman.ini

# Rename the redirected drives to 'shared-drives'
sed -i -e 's/FuseMountName=thinclient_drives/FuseMountName=shared-drives/g' /etc/xrdp/sesman.ini

# Change the allowed_users
sed -i_orig -e 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config

# Blacklist the vmw module
if [ ! -e /etc/modprobe.d/blacklist_vmw_vsock_vmci_transport.conf ]; then
cat >> /etc/modprobe.d/blacklist_vmw_vsock_vmci_transport.conf <<EOF
blacklist vmw_vsock_vmci_transport
EOF
fi

# Ensure hv_sock gets loaded
if [ ! -e /etc/modules-load.d/hv_sock.conf ]; then
echo "hv_sock" > /etc/modules-load.d/hv_sock.conf
fi

# Retrieve all available polkit actions and separate them accordingly
pkaction > /tmp/available_actions
actions=$(sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/;/g' /tmp/available_actions)
rm /tmp/available_actions

# Configure the policies for XRDP session
cat > /etc/polkit-1/localauthority/50-local.d/xrdp-allow-all.pkla <<EOF
[Allow all for all sudoers]
Identity=unix-group:sudo
Action=$actions
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

# Configure required PAM additional modules for XRDP
echo "" >> /etc/pam.d/xrdp-sesman
echo "session required pam_env.so readenv=1 envfile=/etc/environment" >> /etc/pam.d/xrdp-sesman
echo "session required pam_env.so readenv=1 envfile=/etc/default/locale" >> /etc/pam.d/xrdp-sesman

# Start up XRDP service again
systemctl daemon-reload
systemctl start xrdp

echo "Install is complete."
echo "Shutdown your machine, then from an elevated PowerShell session type:"
echo "Set-VM -VMName <your_VM_name> -EnhancedSessionTransportType HvSocket"
echo "And boot your machine back to begin using Enhanced Session."