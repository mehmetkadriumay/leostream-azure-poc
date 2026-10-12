#!/bin/bash
# Leostream Broker preparation, run as root through Azure Run Command.
#
# install.tf prepends a prelude defining INSTALLER_URI, VM_NAME, LICENSE_KEY and
# OS_UPDATE_MODE. This file is deliberately plain bash rather than a Terraform
# template so that ${...} parameter expansion needs no escaping and the script
# can be checked with "bash -n".

set -euo pipefail

echo '=== Leostream Broker preparation ==='

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
    echo '--- If this is a repository timeout, the Broker has no outbound internet.'
    echo '--- It has no public IP, and Azure retired default outbound access in'
    echo '--- September 2025, so the subnet needs a NAT gateway. Check with:'
    echo '---   curl -s -o /dev/null -w "%{http_code}" --max-time 20 https://www.microsoft.com/'
    echo '--- A result of 000 means no outbound path. Confirm nat_gateway_enabled'
    echo '--- is true and that the subnet association exists.'
    return 1
}

if [ "$OS_UPDATE_MODE" = "skip" ]; then
    echo 'skipping OS update'
else
    dnf_retry update
fi

dnf_retry install firewalld chrony policycoreutils-python-utils tar curl ca-certificates

systemctl enable --now chronyd
systemctl enable --now firewalld

echo '--- configuring firewall ---'
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

echo '--- setting hostname ---'
hostnamectl set-hostname "$VM_NAME"

echo '--- enabling EPEL ---'
# The Leostream packages depend on software that is not in the Azure RHUI
# repositories. CodeReady Builder is already enabled on the Azure RHEL image.
if ! dnf -y install epel-release 2>/dev/null; then
    dnf_retry install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Keep the upstream file name. dnf only treats a local path as a package when
# it ends in .rpm - otherwise it reads it as a package name and fails with
# "No match for argument". Drop the query string of a pre-signed URL, then the
# scheme and host, and fall back if what is left has no file component.
INSTALLER_PATH="${INSTALLER_URI%%\?*}"
INSTALLER_PATH="${INSTALLER_PATH#*://}"
INSTALLER_FILE=''
case "$INSTALLER_PATH" in
    */)  : ;;
    */*) INSTALLER_FILE="${INSTALLER_PATH##*/}" ;;
esac
[ -n "$INSTALLER_FILE" ] || INSTALLER_FILE='leostream-installer'

echo "--- downloading Leostream Platform 26 installer ($INSTALLER_FILE) ---"
curl -fsSL -o "$INSTALLER_FILE" "$INSTALLER_URI"

echo '--- running installer ---'
if head -c 2 "$INSTALLER_FILE" | grep -q '#!' ; then
    chmod +x "$INSTALLER_FILE"
    "./$INSTALLER_FILE"
else
    dnf_retry install "./$INSTALLER_FILE"
fi

echo '--- enabling Leostream services ---'
# The Platform 26 unit is 'leostream-broker', not 'leostream', and it pulls in
# postgresql. Match on the exact unit name: a prefix match finds
# leostream-broker.service but then tries to enable a 'leostream' unit that
# does not exist, which fails silently and leaves the Broker stopped.
for svc in postgresql leostream-broker; do
    if systemctl list-unit-files --no-legend "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    else
        echo "unit ${svc}.service not present - skipping"
    fi
done

echo '--- waiting for the Broker web interface ---'
# control.pl returns as soon as it has forked its workers, so the listener is
# not up yet when systemd reports the unit active. Poll rather than guess.
for attempt in $(seq 1 30); do
    if curl -k -s -o /dev/null --max-time 10 https://localhost/ ; then
        echo "Broker web interface responding after ${attempt} attempt(s)."
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        echo 'WARNING: the Broker web interface did not respond within 5 minutes.'
        echo 'Check "systemctl status leostream-broker" and /opt/leostream/logs/.'
    fi
    sleep 10
done

if [ -n "$LICENSE_KEY" ] && command -v leostream-license >/dev/null 2>&1 ; then
    echo '--- applying licence ---'
    leostream-license "$LICENSE_KEY" || echo 'licence activation failed - complete it in the web interface'
fi

cd /
rm -rf "$WORKDIR"
echo '=== Broker preparation complete ==='
