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
api "settings/set?dnssecValidation=false&logQueries=false" > /dev/null

# ---------------------------------------------------------------------------
# Blocklists
# ---------------------------------------------------------------------------

echo "Configuring blocklists..."
BLOCKLIST_URLS="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts,https://big.oisd.nl/domainswild2,https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro-onlydomains.txt"
api "settings/set?enableBlocking=true&blockingType=NxDomain&blockListUrls=${BLOCKLIST_URLS}" > /dev/null

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
