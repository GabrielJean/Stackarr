#!/usr/bin/env bash

# Generates a PIA WireGuard profile for Gluetun without retaining PIA account
# credentials, authentication tokens, certificates, or server-list data.
set -Eeuo pipefail

readonly SERVER_LIST_URL="https://serverlist.piaservers.net/vpninfo/servers/v6"
readonly PIA_CERT_URL="https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt"
REGION_ID="."
OUTPUT_FILE="$(pwd -P)/wg0.conf"
LIST_REGIONS=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--list-regions] [--region REGION_ID] [--output FILE]

Generates a PIA WireGuard profile for Gluetun.

Options:
  -l, --list-regions       List available PIA WireGuard regions and exit.
  -r, --region REGION_ID   Generate a profile for this PIA region.
  -o, --output FILE        Write the profile to this file.
  -h, --help               Show this help text.
EOF
}

install_dependencies() {
  local command packages=() installer=()
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 && continue
    case "$command" in
      curl|jq) packages+=("$command") ;;
      wg) packages+=("wireguard-tools") ;;
    esac
  done
  ((${#packages[@]})) || return

  printf 'Installing required packages: %s\n' "${packages[*]}"
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || { printf 'Administrator access is required to install packages.\n' >&2; exit 1; }
    installer=(sudo)
  fi
  if command -v apt-get >/dev/null 2>&1; then
    "${installer[@]}" apt-get update && "${installer[@]}" apt-get install --yes "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    "${installer[@]}" dnf install --assumeyes "${packages[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    "${installer[@]}" pacman -Sy --noconfirm "${packages[@]}"
  else
    printf 'Install these required packages, then try again: %s\n' "${packages[*]}" >&2
    exit 1
  fi
}

while (($#)); do
  case "$1" in
    -l|--list-regions) LIST_REGIONS=1; shift ;;
    -r|--region) REGION_ID=${2:?The --region option requires a region ID}; shift 2 ;;
    -o|--output) OUTPUT_FILE=${2:?The --output option requires a file path}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unrecognized option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

install_dependencies curl jq
SERVER_LIST=$(curl --fail --silent --show-error --max-time 15 "$SERVER_LIST_URL") || {
  printf 'Unable to retrieve the PIA server list.\n' >&2
  exit 1
}
SERVER_DATA=$(head -n1 <<<"$SERVER_LIST")
jq -e '.regions | type == "array"' >/dev/null <<<"$SERVER_DATA" || {
  printf 'PIA returned an invalid server list.\n' >&2
  exit 1
}

if ((LIST_REGIONS)); then
  printf 'Region ID\tRegion\tPort forwarding\tGeolocated\n'
  jq -r '.regions[] | select((.servers.wg | length) > 0) | [.id, .name, (if .port_forward then "yes" else "no" end), (if .geo then "yes" else "no" end)] | @tsv' <<<"$SERVER_DATA"
  exit 0
fi

install_dependencies wg
command -v shuf >/dev/null 2>&1 || { printf 'Required command not found: shuf\n' >&2; exit 1; }
if [[ $REGION_ID == . ]]; then
  REGION=$(jq -c '.regions[] | select((.servers.wg | length) > 0)' <<<"$SERVER_DATA" | shuf -n1)
else
  REGION=$(jq -c --arg region "$REGION_ID" '.regions[] | select(.id == $region and (.servers.wg | length) > 0)' <<<"$SERVER_DATA")
fi
[[ -n $REGION ]] || { printf "PIA region '%s' was not found.\n" "$REGION_ID" >&2; exit 1; }

REGION_NAME=$(jq -r '.name' <<<"$REGION")
WG_DNS=$(jq -r '.dns' <<<"$REGION")
SELECTED_SERVER=$(jq -c '.servers.wg[]' <<<"$REGION" | shuf -n1)
WG_HOST=$(jq -r '.ip' <<<"$SELECTED_SERVER")
WG_CN=$(jq -r '.cn' <<<"$SELECTED_SERVER")
WG_PORT=$(jq -r '.groups.wg[0].ports[]' <<<"$SERVER_DATA" | shuf -n1)
[[ -n $WG_HOST && -n $WG_CN && -n $WG_PORT ]] || { printf 'The selected PIA region has incomplete WireGuard data.\n' >&2; exit 1; }

umask 077
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/pia-wg.XXXXXX")
trap 'rm -rf -- "$WORKDIR"' EXIT
curl --fail --silent --show-error --max-time 15 "$PIA_CERT_URL" -o "$WORKDIR/pia-rsa.crt"

read -r -p "PIA username: " PIA_USERNAME
read -r -s -p "PIA password: " PIA_PASSWORD
printf '\n'
[[ -n $PIA_USERNAME && -n $PIA_PASSWORD ]] || { printf 'A PIA username and password are required.\n' >&2; exit 1; }
AUTH_BODY=$(jq -nc --arg username "$PIA_USERNAME" --arg password "$PIA_PASSWORD" '{username: $username, password: $password}')
TOKEN=$(curl --silent --show-error --max-time 15 --request POST --header 'Content-Type: application/json' --data "$AUTH_BODY" 'https://www.privateinternetaccess.com/api/client/v2/token' | jq -r '.token // empty')
unset PIA_PASSWORD AUTH_BODY
[[ -n $TOKEN ]] || { printf 'PIA authentication failed.\n' >&2; exit 1; }

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(wg pubkey <<<"$CLIENT_PRIVATE_KEY")
register_key() {
  curl --silent --show-error --max-time 10 --get --data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" --data-urlencode "pt=$TOKEN" --cacert "$WORKDIR/pia-rsa.crt" --resolve "$1:$WG_PORT:$WG_HOST" "https://$1:$WG_PORT/addKey"
}
printf 'Registering WireGuard profile with PIA %s.\n' "$REGION_NAME"
REMOTE_INFO=$(register_key "$WG_CN") || REMOTE_INFO=$(register_key "$WG_DNS")
unset TOKEN
[[ $(jq -r '.status // empty' <<<"$REMOTE_INFO") == OK ]] || { printf 'PIA rejected the WireGuard key registration.\n' >&2; exit 1; }

PEER_IP=$(jq -r '.peer_ip // empty' <<<"$REMOTE_INFO")
SERVER_PUBLIC_KEY=$(jq -r '.server_key // empty' <<<"$REMOTE_INFO")
SERVER_IP=$(jq -r '.server_ip // empty' <<<"$REMOTE_INFO")
SERVER_PORT=$(jq -r '.server_port // empty' <<<"$REMOTE_INFO")
DNS_SERVERS=$(jq -r '[.dns_servers[0:2][]] | join(",")' <<<"$REMOTE_INFO")
[[ -n $PEER_IP && -n $SERVER_PUBLIC_KEY && -n $SERVER_IP && -n $SERVER_PORT && -n $DNS_SERVERS ]] || { printf 'PIA returned incomplete WireGuard data.\n' >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT_FILE")"
cat >"$OUTPUT_FILE" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $PEER_IP
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_IP:$SERVER_PORT
EOF
chmod 600 "$OUTPUT_FILE"
printf 'Generated PIA WireGuard profile for %s.\n' "$REGION_NAME"
