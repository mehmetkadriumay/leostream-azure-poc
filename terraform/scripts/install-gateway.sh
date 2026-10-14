#!/bin/bash
# Leostream Gateway preparation, run as root through Azure Run Command.
#
# install.tf prepends a prelude defining INSTALLER_URI, VM_NAME, BROKER_ADDRESS
# and OS_UPDATE_MODE. This file is deliberately plain bash rather than a
# Terraform template so that ${...} parameter expansion needs no escaping and
# the script can be checked with "bash -n".

set -euo pipefail

echo '=== Leostream Gateway preparation ==='

# Azure's RHUI mirrors intermittently time out fetching repository metadata,
# which aborts the whole install under 'set -e'. Be patient and retry.
cat >> /etc/dnf/dnf.conf <<'DNFCONF'
timeout=60
retries=5
minrate=0
DNFCONF

dnf_retry() {
    attempt=1
    while [ "$attempt" -le 3 ]; do
        if dnf -y "$@"; then
            return 0
        fi
        echo "--- dnf $1 failed (attempt $attempt of 3), retrying in 15s ---"
        sleep 15
        attempt=$((attempt + 1))
    done
    echo "--- dnf $1 failed after 3 attempts ---"
    return 1
}

if [ "$OS_UPDATE_MODE" = "skip" ]; then
    echo 'skipping OS update'
else
    dnf_retry update
fi

dnf_retry install firewalld chrony curl tar ca-certificates policycoreutils-python-utils

systemctl enable --now chronyd
systemctl enable --now firewalld

echo '--- setting hostname ---'
hostnamectl set-hostname "$VM_NAME"

echo '--- kernel settings for the gateway ---'
cat >/etc/sysctl.d/99-leostream-gateway.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10000 65000
SYSCTL
sysctl --system >/dev/null

echo '--- configuring firewall ---'
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=443/tcp
# SSH stays open here on purpose. This is the only administrative way into the
# deployment, and the network security group already restricts the source to
# allowed_client_cidrs. Narrowing it again here would only risk locking you out.
firewall-cmd --permanent --add-service=ssh

# Publish the Broker's administrator interface on this VM's public IP, so it can
# be reached in a browser without an SSH tunnel. This is a plain TCP forward, so
# TLS terminates on the Broker and the certificate you see is the Broker's.
#
# An HTTP reverse proxy would be the obvious alternative, but the Leostream
# Gateway's /etc/httpd/conf.d/leo.conf declares its <Location> blocks outside
# any <VirtualHost>, which makes them global. A new vhost would inherit the
# /app/... handlers that the Broker's own UI also uses, and those requests would
# be answered by the Gateway's mod_perl instead of the Broker.
if [ -n "$ADMIN_PORT" ]; then
    echo "--- forwarding ${ADMIN_PORT}/tcp to the Broker on 443 ---"
    # Masquerade is required: without it the Broker would reply straight to the
    # client through the NAT gateway and the client would drop the packet as
    # asymmetric. It must be permanent, because a firewall-cmd --reload resets
    # the runtime configuration to whatever is on disk.
    firewall-cmd --permanent --add-masquerade
    firewall-cmd --permanent --add-port="${ADMIN_PORT}/tcp"
    firewall-cmd --permanent --add-forward-port=port="${ADMIN_PORT}":proto=tcp:toaddr="${BROKER_ADDRESS}":toport=443
fi

firewall-cmd --reload

echo '--- enabling EPEL ---'
# The Gateway package needs libguac, openvpn, certbot, mod_perl and others that
# are not in the Azure RHUI repositories. CodeReady Builder is already enabled
# on the Azure RHEL image.
if ! dnf -y install epel-release 2>/dev/null; then
    dnf_retry install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Keep the upstream file name. dnf only treats a local path as a package when
# it ends in .rpm - otherwise it reads it as a package name and fails with
# "No match for argument".
INSTALLER_PATH="${INSTALLER_URI%%\?*}"
INSTALLER_PATH="${INSTALLER_PATH#*://}"
INSTALLER_FILE=''
case "$INSTALLER_PATH" in
    */)  : ;;
    */*) INSTALLER_FILE="${INSTALLER_PATH##*/}" ;;
esac
[ -n "$INSTALLER_FILE" ] || INSTALLER_FILE='leostream-gateway-installer'

echo "--- downloading Leostream Gateway installer ($INSTALLER_FILE) ---"
curl -fsSL -o "$INSTALLER_FILE" "$INSTALLER_URI"

echo '--- running installer ---'
if head -c 2 "$INSTALLER_FILE" | grep -q '#!' ; then
    chmod +x "$INSTALLER_FILE"
    "./$INSTALLER_FILE"
else
    dnf_retry install "./$INSTALLER_FILE"
fi

echo '--- recording broker address ---'
mkdir -p /etc/leostream
echo "broker_address=$BROKER_ADDRESS" > /etc/leostream/gateway.conf
chmod 0640 /etc/leostream/gateway.conf

echo '--- enabling Gateway services ---'
# The Gateway ships no 'leostream-gateway' unit. It serves 443 through the
# distribution httpd (with a drop-in at /etc/systemd/system/httpd.service.d/),
# proxies to tomcat, and runs guacd plus its own wsping unit. The RPM enables
# these itself; re-asserting them is harmless and makes the dependency explicit.
for svc in httpd tomcat guacd wsping; do
    if systemctl list-unit-files --no-legend "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    else
        echo "unit ${svc}.service not present - skipping"
    fi
done

echo '--- waiting for the Gateway web interface ---'
for attempt in $(seq 1 30); do
    if curl -k -s -o /dev/null --max-time 10 https://localhost/ ; then
        echo "Gateway web interface responding after ${attempt} attempt(s)."
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        echo 'WARNING: the Gateway web interface did not respond within 5 minutes.'
        echo 'Check "systemctl status httpd tomcat guacd wsping".'
    fi
    sleep 10
done

cd /
rm -rf "$WORKDIR"
echo '=== Gateway preparation complete ==='
