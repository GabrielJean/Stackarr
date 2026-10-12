#!/usr/bin/env bash

# Stackarr's first-run setup. It intentionally keeps all generated secrets in
# .env, which is ignored by Git and readable only by the installing user.
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="$PROJECT_DIR/.env"
DOCKER_CMD=()
DRY_RUN=0
DOCKER_READY=0
DRY_ENV_FILE=""
STACK_RUNNING=0

usage() {
  printf 'Usage: %s [--dry-run|-n]\n' "$(basename "$0")"
  printf '  --dry-run, -n  Preview setup without changing the host.\n'
}

for argument in "$@"; do
  case "$argument" in
    --dry-run|-n) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

say() {
  printf '\n\033[1;36m%s\033[0m\n' "$1"
}

note() {
  printf '  %s\n' "$1"
}

die() {
  printf '\n\033[1;31mSetup stopped:\033[0m %s\n' "$1" >&2
  exit 1
}

ask() {
  local prompt=$1 default=$2 answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

ask_yes_no() {
  local prompt=$1 answer
  while true; do
    read -r -p "$prompt [Y/n]: " answer
    case "${answer:-y}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) note "Please enter y or n." ;;
    esac
  done
}

ask_optional_yes_no() {
  local prompt=$1 answer
  while true; do
    read -r -p "$prompt [y/N]: " answer
    case "${answer:-n}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) note "Please enter y or n." ;;
    esac
  done
}

require_absolute_path() {
  [[ $1 = /* ]] || die "Folder paths must start with /."
}

install_curl_if_needed() {
  command -v curl >/dev/null 2>&1 && return
  say "Installing curl"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y curl
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm curl
  else
    die "curl is required to install Docker automatically. Install curl, then run this script again."
  fi
}

configure_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    die "Docker is installed but cannot be used. Ensure Docker is running, then run setup again."
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if ((DRY_RUN)); then
      say "Docker is not installed"
      note "Dry run: Docker would be installed using Docker's official convenience script."
      return
    fi
    say "Docker is not installed"
    note "Stackarr will install Docker using Docker's official convenience script."
    ask_yes_no "Install Docker now?" || die "Docker is required to run Stackarr."
    install_curl_if_needed
    curl -fsSL https://get.docker.com -o /tmp/stackarr-get-docker.sh
    sudo sh /tmp/stackarr-get-docker.sh
    rm -f /tmp/stackarr-get-docker.sh
    sudo systemctl enable --now docker 2>/dev/null || true
  fi

  if ((DRY_RUN)) && ! docker info >/dev/null 2>&1; then
    note "Dry run: Docker is installed but not currently available. Compose validation will be skipped."
    return
  fi

  configure_docker_command
  "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || die "Docker Compose v2 is required but was not found."
  DOCKER_READY=1
}

# When the stack is already running, we avoid port conflict checks and
# generally act in an update-friendly way.
check_if_stack_running() {
  if (( DOCKER_READY )); then
    if "${DOCKER_CMD[@]}" compose -f "$PROJECT_DIR/docker-compose.yml" ps -q | grep -q . 2>/dev/null; then
      STACK_RUNNING=1
    fi
  fi
}

default_network() {
  local route interface cidr ip prefix a b c d mask_a mask_b mask_c mask_d
  route=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
  interface=$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<<"$route")
  cidr=$(ip -o -4 addr show dev "$interface" scope global 2>/dev/null | awk 'NR == 1 {print $4}')
  [[ -n $cidr ]] || {
    printf '192.168.1.0/24'
    return
  }

  IFS='./' read -r a b c d prefix <<<"$cidr"
  mask_a=$(( prefix >= 8 ? 255 : (256 - (1 << (8 - prefix))) ))
  mask_b=$(( prefix <= 8 ? 0 : (prefix >= 16 ? 255 : (256 - (1 << (16 - prefix)))) ))
  mask_c=$(( prefix <= 16 ? 0 : (prefix >= 24 ? 255 : (256 - (1 << (24 - prefix)))) ))
  mask_d=$(( prefix <= 24 ? 0 : (prefix >= 32 ? 255 : (256 - (1 << (32 - prefix)))) ))
  printf '%s.%s.%s.%s/%s' "$((a & mask_a))" "$((b & mask_b))" "$((c & mask_c))" "$((d & mask_d))" "$prefix"
}

default_host_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

env_value() {
  local value=$1
  value=${value//\'/\\\'}
  printf "'%s'" "$value"
}

env_line() {
  printf '%s=%s\n' "$1" "$(env_value "$2")"
}

# Read a previous value from an existing .env (without evaluating arbitrary code).
existing_env_value() {
  local key=$1 val raw
  [[ -f $ENV_FILE ]] || { printf '' ; return; }
  raw=$(grep -m1 "^${key}=" "$ENV_FILE" || true)
  [[ -n $raw ]] || { printf '' ; return; }
  val=${raw#*=}
  # strip surrounding single quotes if present
  val=${val#\'}
  val=${val%\'}
  printf '%s' "$val"
}

write_environment() {
  local destination=$1 temp_file
  temp_file=$(mktemp "${destination}.XXXXXX")
  umask 077
  {
    printf '# Generated by setup.sh. Keep this file private.\n'
    env_line PUID "$PUID"
    env_line PGID "$PGID"
    env_line TZ "$TIMEZONE"
    env_line APPDATA "$APPDATA"
    env_line DOWNLOADS_PATH "$DOWNLOADS_PATH"
    env_line MEDIA_PATH "$MEDIA_PATH"
    env_line LAN_SUBNET "$LAN_SUBNET"
    env_line HOMEPAGE_PORT "3001"
    env_line STACKARR_URL "$STACKARR_URL"
    env_line HOMEPAGE_ALLOWED_HOSTS "$HOMEPAGE_ALLOWED_HOSTS"
    env_line PLEX_GPU_COUNT "$PLEX_GPU_COUNT"
    env_line NVIDIA_VISIBLE_DEVICES all
    env_line DOCKHAND_PORT 3000
    env_line QBITTORRENT_PORT 8080
    env_line TORRENT_PORT 6881
    env_line SONARR_PORT 8989
    env_line RADARR_PORT 7878
    env_line JACKETT_PORT 9117
    env_line SEERR_PORT 5055
  } >"$temp_file"
  mv "$temp_file" "$destination"
  chmod 600 "$destination"
}

create_folders() {
  mkdir -p \
    "$APPDATA"/{plex,gluetun,qbittorrent,sonarr,radarr,jackett,seerr} \
    "$APPDATA/gluetun/wireguard" \
    "$DOWNLOADS_PATH"/{incomplete,complete} \
    "$MEDIA_PATH"/{movies,tv}
}

generate_pia_profile() {
  local arguments=(--output "$APPDATA/gluetun/wireguard/wg0.conf")
  [[ -n $PIA_REGION ]] && arguments+=(--region "$PIA_REGION")
  "$PROJECT_DIR/scripts/generate-pia-wireguard.sh" "${arguments[@]}"
}

check_ports_available() {
  # If the stack is already running we'll skip this check because ports will
  # be held by our own containers and are expected to be in use.
  (( STACK_RUNNING )) && return

  local port used_ports=()
  command -v ss >/dev/null 2>&1 || return

  for port in 3000 3001 32400 8080 6881 8989 7878 9117 5055; do
    if ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
      used_ports+=("$port/tcp")
    fi
  done
  if ss -lunH "sport = :6881" 2>/dev/null | grep -q .; then
    used_ports+=("6881/udp")
  fi

  if ((${#used_ports[@]})); then
    die "These ports are already in use: ${used_ports[*]}. Stop the conflicting application, then run setup again."
  fi
}

say "Stackarr setup 🍿"
note "This guided setup creates your folders, configures every service, and starts the stack."

[[ $(uname -s) == Linux ]] || die "Stackarr currently supports Linux hosts only."
command -v ip >/dev/null 2>&1 || die "The ip command is required to detect your local network."

ensure_docker
check_if_stack_running

if (( STACK_RUNNING )); then
  say "Detected existing Stackarr services running. Setup will act in update mode."
else
  say "No running Stackarr containers detected. Performing initial/setup flow."
fi

say "Choose where Stackarr stores your files"
note "App settings stores service databases and preferences. Keep this folder private and do not delete it."
note "Downloads stores incomplete and completed torrent files until Sonarr or Radarr imports them."
note "Media library stores your permanent Movies and TV folders. Plex streams media from here."

# Defaults may come from an existing .env so users can re-run setup safely.
APPDATA_DEFAULT=$(existing_env_value APPDATA)
APPDATA_DEFAULT=${APPDATA_DEFAULT:-$HOME/.local/share/stackarr}
DOWNLOADS_DEFAULT=$(existing_env_value DOWNLOADS_PATH)
DOWNLOADS_DEFAULT=${DOWNLOADS_DEFAULT:-$HOME/Downloads}
MEDIA_DEFAULT=$(existing_env_value MEDIA_PATH)
MEDIA_DEFAULT=${MEDIA_DEFAULT:-$HOME/Media}

APPDATA=$(ask "App settings folder" "$APPDATA_DEFAULT")
DOWNLOADS_PATH=$(ask "Downloads folder" "$DOWNLOADS_DEFAULT")
MEDIA_PATH=$(ask "Media library folder" "$MEDIA_DEFAULT")
require_absolute_path "$APPDATA"
require_absolute_path "$DOWNLOADS_PATH"
require_absolute_path "$MEDIA_PATH"

say "Private Internet Access VPN"
note "Stackarr supports PIA WireGuard. Your PIA password is sent only to PIA and is never stored."
PIA_REGION=""
if ask_optional_yes_no "Choose a specific PIA region?"; then
  note "Available regions will be displayed next. Pick an ID such as ca_toronto."
  if ((DRY_RUN)); then
    note "Dry run: PIA region lookup is skipped."
  else
    "$PROJECT_DIR/scripts/generate-pia-wireguard.sh" --list-regions
  fi
  PIA_REGION=$(ask "PIA region ID" "")
  [[ -n $PIA_REGION ]] || die "A PIA region ID is required when choosing a specific region."
fi

say "Automatic local-network setup"
# Allow reusing existing values from .env for idempotency
PUID=$(existing_env_value PUID)
PUID=${PUID:-$(id -u)}
PGID=$(existing_env_value PGID)
PGID=${PGID:-$(id -g)}
TIMEZONE=$(existing_env_value TZ)
TIMEZONE=${TIMEZONE:-$(timedatectl show --property=Timezone --value 2>/dev/null || true)}
TIMEZONE=${TIMEZONE:-Etc/UTC}
LAN_SUBNET=$(existing_env_value LAN_SUBNET)
LAN_SUBNET=${LAN_SUBNET:-$(default_network)}
HOST_IP=$(default_host_ip)
HOST_IP=${HOST_IP:-127.0.0.1}
STACKARR_URL=$(existing_env_value STACKARR_URL)
STACKARR_URL=${STACKARR_URL:-"http://$HOST_IP"}
STACKARR_URL=${STACKARR_URL%/}
HOMEPAGE_HOST=${STACKARR_URL#http://}
HOMEPAGE_HOST=${HOMEPAGE_HOST#https://}
HOMEPAGE_ALLOWED_HOSTS="$HOMEPAGE_HOST:3001,localhost:3001,127.0.0.1:3001"
note "Detected local network: $LAN_SUBNET"
note "Homepage: $STACKARR_URL:3001"

say "Plex transcoding"
PLEX_GPU_COUNT=$(existing_env_value PLEX_GPU_COUNT)
PLEX_GPU_COUNT=${PLEX_GPU_COUNT:-0}
if ask_optional_yes_no "Use an NVIDIA GPU for Plex transcoding?"; then
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! command -v nvidia-container-cli >/dev/null 2>&1; then
    if ((DRY_RUN)); then
      note "Dry run: NVIDIA driver and Container Toolkit were not detected. A real setup would stop here."
    else
      die "The NVIDIA driver or NVIDIA Container Toolkit was not detected. Install both, then run setup again."
    fi
  fi
  PLEX_GPU_COUNT=1
fi

if ((DRY_RUN)); then
  say "Dry-run preview"
  note "Would create local folders in:"
  note "  Settings:  $APPDATA"
  note "  Downloads: $DOWNLOADS_PATH"
  note "  Media:     $MEDIA_PATH"
  note "Would create a PIA WireGuard profile, write a private .env file, and start all Stackarr services."
  if ((DOCKER_READY)); then
    DRY_ENV_FILE=$(mktemp /tmp/stackarr.env.XXXXXX)
    trap 'rm -f "$DRY_ENV_FILE"' EXIT
    write_environment "$DRY_ENV_FILE"
    say "Checking the generated configuration"
    "${DOCKER_CMD[@]}" compose --env-file "$DRY_ENV_FILE" -f "$PROJECT_DIR/docker-compose.yml" config --quiet
  fi
  say "Dry run complete ✅"
  note "No folders, configuration files, containers, or Docker packages were changed."
  exit 0
fi

# Create folders idempotently
create_folders
check_ports_available

# Handle existing .env safely so git pulls / repo updates do not clobber user's setup.
if [[ -f $ENV_FILE ]]; then
  say ".env already exists"
  note "Your existing .env will be preserved by default so that `git pull` won't overwrite your configuration."
  note "Options: (K)eep existing, (O)verwrite (backup created), (U)pdate missing values from this setup run."
  local_choice=""
  while [[ -z $local_choice ]]; do
    read -r -p "Choose [K/o/u] (default K): " local_choice
    local_choice=${local_choice:-K}
    case "$local_choice" in
      [Kk])
        note "Keeping existing .env. We'll still create folders and try to start/update the stack."
        ;;
      [Oo])
        BACKUP="$ENV_FILE.$(date +%Y%m%d%H%M%S).bak"
        mv "$ENV_FILE" "$BACKUP"
        note "Backed up existing .env to $BACKUP"
        write_environment "$ENV_FILE"
        ;;
      [Uu])
        # Merge: read the existing values and re-write file with current computed defaults
        note "Updating missing values in .env while preserving existing ones."
        # Load existing values into variables if present
        PUID=$(existing_env_value PUID)
        PUID=${PUID:-$PUID}
        PGID=$(existing_env_value PGID)
        PGID=${PGID:-$PGID}
        TIMEZONE=$(existing_env_value TZ)
        TIMEZONE=${TIMEZONE:-$TIMEZONE}
        APPDATA=$(existing_env_value APPDATA)
        APPDATA=${APPDATA:-$APPDATA}
        DOWNLOADS_PATH=$(existing_env_value DOWNLOADS_PATH)
        DOWNLOADS_PATH=${DOWNLOADS_PATH:-$DOWNLOADS_PATH}
        MEDIA_PATH=$(existing_env_value MEDIA_PATH)
        MEDIA_PATH=${MEDIA_PATH:-$MEDIA_PATH}
        LAN_SUBNET=$(existing_env_value LAN_SUBNET)
        LAN_SUBNET=${LAN_SUBNET:-$LAN_SUBNET}
        STACKARR_URL=$(existing_env_value STACKARR_URL)
        STACKARR_URL=${STACKARR_URL:-$STACKARR_URL}
        PLEX_GPU_COUNT=$(existing_env_value PLEX_GPU_COUNT)
        PLEX_GPU_COUNT=${PLEX_GPU_COUNT:-$PLEX_GPU_COUNT}
        write_environment "$ENV_FILE"
        ;;
      *)
        note "Please choose K, o, or u."
        local_choice=""
        ;;
    esac
  done
else
  write_environment "$ENV_FILE"
fi

say "Checking your configuration"
"${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" -f "$PROJECT_DIR/docker-compose.yml" config --quiet

say "Starting/Updating Stackarr"
# If already running, pull new images and recreate changed containers.
if (( STACK_RUNNING )); then
  note "Updating images and containers for the running Stackarr."
  "${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" -f "$PROJECT_DIR/docker-compose.yml" pull || true
  "${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" -f "$PROJECT_DIR/docker-compose.yml" up -d
else
  "${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" -f "$PROJECT_DIR/docker-compose.yml" up -d
fi

say "Stackarr is running 🎉"
note "Homepage:    $STACKARR_URL:3001"
note "Dockhand:    $STACKARR_URL:3000"
note "Plex:        $STACKARR_URL:32400/web"
note "qBittorrent: $STACKARR_URL:8080"
note "Sonarr:      $STACKARR_URL:8989"
note "Radarr:      $STACKARR_URL:7878"
note "Jackett:     $STACKARR_URL:9117"
note "Seerr:       $STACKARR_URL:5055"
note "Open Homepage first, then connect Seerr to Plex, Sonarr, and Radarr."
