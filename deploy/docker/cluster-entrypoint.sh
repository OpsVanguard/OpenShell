#!/bin/sh
# Entrypoint script for navigator-cluster image
#
# This script configures DNS resolution for k3s when running in Docker.
# 
# Problem: On Docker custom networks, /etc/resolv.conf contains 127.0.0.11
# (Docker's internal DNS). k3s detects this loopback address and automatically
# falls back to 8.8.8.8 - but on Docker Desktop (Mac/Windows), external UDP
# traffic to 8.8.8.8:53 doesn't work due to network limitations.
#
# Solution: Use the Docker host gateway (host.docker.internal) for DNS, which
# correctly forwards queries to the host's DNS resolver. We use k3s's
# --resolv-conf flag to provide this alternative resolver configuration.
# Per k3s docs: "Manually specified resolver configuration files are not
# subject to viability checks."

set -e

RESOLV_CONF="/etc/rancher/k3s/resolv.conf"

# Get the host gateway IP from /etc/hosts
# This requires the container to be started with --add-host=host.docker.internal:host-gateway
HOST_GATEWAY_IP=$(grep host.docker.internal /etc/hosts 2>/dev/null | head -1 | awk '{print $1}')

if [ -n "$HOST_GATEWAY_IP" ]; then
    echo "Configuring DNS to use host gateway: $HOST_GATEWAY_IP"
    echo "nameserver $HOST_GATEWAY_IP" > "$RESOLV_CONF"
else
    echo "Warning: host.docker.internal not found in /etc/hosts"
    echo "Falling back to public DNS servers (may not work on Docker Desktop)"
    echo "To fix: start container with --add-host=host.docker.internal:host-gateway"
    cat > "$RESOLV_CONF" <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
fi

# Copy bundled manifests to k3s manifests directory.
# These are stored in /opt/navigator/manifests/ because the volume mount
# on /var/lib/rancher/k3s overwrites any files baked into that path.
if [ -d "/opt/navigator/manifests" ]; then
    echo "Copying bundled manifests to k3s..."
    cp /opt/navigator/manifests/*.yaml /var/lib/rancher/k3s/server/manifests/ 2>/dev/null || true
fi

# Execute k3s with the custom resolv-conf
# The --resolv-conf flag tells k3s to use our DNS configuration instead of /etc/resolv.conf
# Per k3s docs: "Manually specified resolver configuration files are not subject to viability checks"
exec /bin/k3s "$@" --resolv-conf="$RESOLV_CONF"
