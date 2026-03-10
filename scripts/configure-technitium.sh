#!/usr/bin/env bash
# configure-technitium.sh — Apply standard Technitium DNS configuration.
#
# Run this after first boot on any host running Technitium to apply the
# shared homelab DNS configuration. Idempotent — safe to re-run.
#
# Usage:
#   ./scripts/configure-technitium.sh <host> <admin-password>
#
# Example:
#   ./scripts/configure-technitium.sh mirkwood  'mypassword' primary
#   ./scripts/configure-technitium.sh rivendell 'mypassword' secondary

set -euo pipefail

HOST="${1:?Usage: $0 <host> <admin-password> [primary|secondary]}"
PASS="${2:?Usage: $0 <host> <admin-password> [primary|secondary]}"
ROLE="${3:-primary}"  # 'primary' (mirkwood) or 'secondary' (rivendell)
BASE="http://${HOST}:5380/api"

PRIMARY_HOST="mirkwood"
PRIMARY_IP="10.0.1.8"

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

echo "Logging in to Technitium on ${HOST}..."
TOKEN=$(curl -sf "${BASE}/user/login?user=admin&pass=${PASS}&includeInfo=false" | jq -r '.token')
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Login failed. Check host and password." >&2
  exit 1
fi
echo "Authenticated."

api() {
  local endpoint="$1"; shift
  local result
  result=$(curl -sf "${BASE}/${endpoint}&token=${TOKEN}" "$@")
  local status
  status=$(echo "$result" | jq -r '.status')
  if [[ "$status" != "ok" ]]; then
    echo "ERROR calling ${endpoint}: $(echo "$result" | jq -r '.errorMessage')" >&2
    exit 1
  fi
  echo "$result"
}

# ---------------------------------------------------------------------------
# Global settings
# ---------------------------------------------------------------------------

echo "Applying global settings..."
api "settings/set?dnssecValidation=false&logQueries=true" > /dev/null

# ---------------------------------------------------------------------------
# DNS-over-HTTPS (DoH)
#
# Technitium serves DoH on port 5381 with a self-signed TLS cert.
# NPM proxies doh.theshire.io (and doh2.theshire.io) to this port so
# browsers can use the local DNS resolver with an encrypted connection.
# The cert is generated on the host and lives in the Technitium config dir.
# ---------------------------------------------------------------------------

echo "Configuring DNS-over-HTTPS (DoH)..."

DOH_CERT="/var/lib/technitium/config/doh.pfx"
DOH_CERT_CONTAINER="/etc/dns/doh.pfx"

if ssh "brian@${HOST}" "test -f ${DOH_CERT}" 2>/dev/null; then
  echo "  DoH cert already exists, skipping generation."
else
  echo "  Generating self-signed TLS cert for DoH..."
  ssh "brian@${HOST}" "nix-shell -p openssl --run \"
    openssl req -x509 -newkey rsa:2048 \
      -keyout /tmp/doh.key -out /tmp/doh.crt \
      -days 3650 -nodes -subj '/CN=${HOST}' \
      -addext 'subjectAltName=DNS:${HOST}' 2>/dev/null &&
    openssl pkcs12 -export \
      -out /tmp/doh.pfx \
      -inkey /tmp/doh.key -in /tmp/doh.crt \
      -passout pass:
  \" && sudo cp /tmp/doh.pfx ${DOH_CERT} && sudo chmod 644 ${DOH_CERT}"
  echo "  Cert generated."
fi

api "settings/set?enableDnsOverHttps=true&dnsOverHttpsPort=5381&webServiceEnableTls=true&webServiceUseSelfSignedTlsCertificate=true&webServiceTlsPort=53443&dnsTlsCertificatePath=${DOH_CERT_CONTAINER}&dnsTlsCertificatePassword=" > /dev/null

echo "  Restarting Technitium to activate DoH listener..."
ssh "brian@${HOST}" "sudo podman restart technitium" > /dev/null
sleep 5

if ssh "brian@${HOST}" "ss -tlnp | grep -q ':5381'" 2>/dev/null; then
  echo "  DoH listening on port 5381."
else
  echo "  WARNING: DoH port 5381 not detected after restart. Check Technitium logs." >&2
fi

# ---------------------------------------------------------------------------
# Blocklists
# ---------------------------------------------------------------------------

echo "Configuring blocklists..."
BLOCKLIST_URLS="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
api "settings/set?enableBlocking=true&blockingType=NxDomain&blockListUrls=${BLOCKLIST_URLS}" > /dev/null

# ---------------------------------------------------------------------------
# Query Logs app
# ---------------------------------------------------------------------------

APP_NAME="Query Logs (Sqlite)"
APP_NAME_ENCODED="Query%20Logs%20(Sqlite)"

echo "Checking for Query Logs app..."
INSTALLED_APPS=$(curl -sf "${BASE}/apps/list?token=${TOKEN}" | jq -r '.response.apps[].name')

if echo "$INSTALLED_APPS" | grep -qxF "$APP_NAME"; then
  echo "  Already installed, skipping."
else
  echo "  Fetching app store listing..."
  APP_URL=$(curl -sf "${BASE}/apps/listStoreApps?token=${TOKEN}" | jq -r --arg name "$APP_NAME" '.response.storeApps[] | select(.name == $name) | .url')
  if [[ -z "$APP_URL" || "$APP_URL" == "null" ]]; then
    echo "  WARNING: Could not find '$APP_NAME' in app store. Install it manually via the web UI." >&2
  else
    api "apps/downloadAndInstall?name=${APP_NAME_ENCODED}&url=${APP_URL}" > /dev/null
    echo "  Installed."
  fi
fi

# ---------------------------------------------------------------------------
# Zones
# ---------------------------------------------------------------------------

ZONES=$(curl -sf "${BASE}/zones/list?token=${TOKEN}" | jq -r '.response.zones[].name')

create_forwarder_zone() {
  local zone="$1" forwarder="$2" description="$3"
  echo "Configuring forwarder zone: ${zone} -> ${forwarder} (${description})..."
  if echo "$ZONES" | grep -qx "$zone"; then
    echo "  Already exists, skipping."
  else
    api "zones/create?zone=${zone}&type=Forwarder&forwarder=${forwarder}&dnssecValidation=false" > /dev/null
    echo "  Created."
  fi
}

create_forwarder_zone "local"              "10.0.1.1" "router DHCP hostnames"
create_forwarder_zone "1.0.10.in-addr.arpa" "10.0.1.1" "reverse DNS"

echo "Configuring theshire.io zone (split-horizon for local NPM)..."
if echo "$ZONES" | grep -qx "theshire.io"; then
  echo "  Already exists, skipping."
elif [[ "$ROLE" == "primary" ]]; then
  api "zones/create?zone=theshire.io&type=Primary" > /dev/null
  api "zones/records/add?zone=theshire.io&domain=*.theshire.io&type=A&ipAddress=10.0.1.9&ttl=300" > /dev/null
  api "zones/options/set?zone=theshire.io&zoneTransfer=Allow&notify=AllNameServers&notifyNameServers=10.0.1.9" > /dev/null
  echo "  Created as Primary with wildcard -> 10.0.1.9, zone transfer enabled to rivendell."
else
  api "zones/create?zone=theshire.io&type=Secondary&primaryNameServerAddresses=${PRIMARY_IP}" > /dev/null
  echo "  Created as Secondary, syncing from ${PRIMARY_HOST} (${PRIMARY_IP})."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Technitium configuration complete on ${HOST}."
echo "Verify at http://${HOST}:5380"
