#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable prompts for apt-get.
export DEBIAN_FRONTEND="noninteractive"

# System info.
PLATFORM="$(uname --hardware-platform || true)"
DISTRIB_CODENAME="$(lsb_release --codename --short || true)"
DISTRIB_ID="$(lsb_release --id --short | tr '[:upper:]' '[:lower:]' || true)"

# Secure generator commands
GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"

# The Docker compose file.
COMPOSE_URL="https://raw.githubusercontent.com/bluesky-social/pds/main/compose.yaml"

# The pdsadmin script.
PDSADMIN_URL="https://raw.githubusercontent.com/bluesky-social/pds/main/pdsadmin.sh"

# System dependencies.
REQUIRED_SYSTEM_PACKAGES="ca-certificates curl gnupg jq lsb-release openssl sqlite3 xxd"

# Docker packages.
REQUIRED_DOCKER_PACKAGES="containerd.io docker-ce docker-ce-cli docker-compose-plugin"

PUBLIC_IP=""
METADATA_URLS=()
METADATA_URLS+=("http://169.254.169.254/v1/interfaces/0/ipv4/address") # Vultr
METADATA_URLS+=("http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address") # DigitalOcean
METADATA_URLS+=("http://169.254.169.254/2021-03-23/meta-data/public-ipv4") # AWS
METADATA_URLS+=("http://169.254.169.254/hetzner/v1/metadata/public-ipv4") # Hetzner

PDS_DATADIR="${1:-/pds}"
PDS_HOSTNAME="${2:-}"
PDS_ADMIN_EMAIL="${3:-}"
PDS_DID_PLC_URL="https://plc.directory"
PDS_BSKY_APP_VIEW_URL="https://api.bsky.app"
PDS_BSKY_APP_VIEW_DID="did:web:api.bsky.app"
PDS_REPORT_SERVICE_URL="https://mod.bsky.app"
PDS_REPORT_SERVICE_DID="did:plc:ar7c4by46qjdydhdevvrndac"
PDS_CRAWLERS="https://bsky.network"

function usage {
  local error="${1}"
  cat <<USAGE >&2
ERROR: ${error}
Usage:
sudo bash $0

Please try again.
USAGE
  exit 1
}

function main {
  # Check that user is root.
  if [[ "${EUID}" -ne 0 ]]; then
    usage "This script must be run as root. (e.g. sudo $0)"
  fi

  # Check for a supported architecture.
  if [[ "${PLATFORM}" == "unknown" ]]; then
    PLATFORM="x86_64"
  fi
  if [[ "${PLATFORM}" != "x86_64" ]] && [[ "${PLATFORM}" != "aarch64" ]] && [[ "${PLATFORM}" != "arm64" ]]; then
    usage "Sorry, only x86_64 and aarch64/arm64 are supported. Exiting..."
  fi

  # Check for a supported distribution.
  SUPPORTED_OS="false"
  if [[ "${DISTRIB_ID}" == "ubuntu" ]] && [[ "${DISTRIB_CODENAME}" =~ ^(focal|jammy|mantic)$ ]]; then
    SUPPORTED_OS="true"
    echo "* Detected supported Ubuntu distribution"
  elif [[ "${DISTRIB_ID}" == "debian" ]] && [[ "${DISTRIB_CODENAME}" =~ ^(bullseye|bookworm)$ ]]; then
    SUPPORTED_OS="true"
    echo "* Detected supported Debian distribution"
  fi

  if [[ "${SUPPORTED_OS}" != "true" ]]; then
    usage "Sorry, only supported Ubuntu or Debian distributions are supported by this installer."
  fi

  # Enforce that the data directory is /pds.
  if [[ "${PDS_DATADIR}" != "/pds" ]]; then
    usage "The data directory must be /pds. Exiting..."
  fi

  # Check if PDS is already installed.
  if [[ -e "${PDS_DATADIR}/pds.sqlite" ]]; then
    echo "ERROR: PDS is already configured in ${PDS_DATADIR}. Please follow the clean-up instructions."
    exit 1
  fi

  # Attempt to determine server's public IP.
  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP=$(hostname --all-ip-addresses | awk '{ print $1 }')
  fi

  if [[ "${PUBLIC_IP}" =~ ^(127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.) ]]; then
    PUBLIC_IP=""
  fi

  if [[ -z "${PUBLIC_IP}" ]]; then
    for METADATA_URL in "${METADATA_URLS[@]}"; do
      METADATA_IP="$(timeout 2 curl --silent --show-error "${METADATA_URL}" | head --lines=1 || true)"
      if [[ "${METADATA_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        PUBLIC_IP="${METADATA_IP}"
        break
      fi
    done
  fi

  if [[ -z "${PUBLIC_IP}" ]]; then
    PUBLIC_IP="Server's IP"
  fi

  # Prompt user for required variables.
  if [[ -z "${PDS_HOSTNAME}" ]]; then
    read -p "Enter your public DNS address (e.g., example.com): " PDS_HOSTNAME
  fi

  if [[ -z "${PDS_HOSTNAME}" ]]; then
    usage "No public DNS address specified."
  fi

  if [[ "${PDS_HOSTNAME}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    usage "Invalid public DNS address (must not be an IP address)."
  fi

  # Admin email
  if [[ -z "${PDS_ADMIN_EMAIL}" ]]; then
    read -p "Enter an admin email address (e.g., you@example.com): " PDS_ADMIN_EMAIL
  fi

  if [[ -z "${PDS_ADMIN_EMAIL}" ]]; then
    usage "No admin email specified."
  fi

  # Install system packages.
  apt-get update
  apt-get install --yes ${REQUIRED_SYSTEM_PACKAGES}

  # Install Docker
  if ! docker version >/dev/null 2>&1; then
    echo "* Installing Docker"
    mkdir --parents /etc/apt/keyrings
    rm --force /etc/apt/keyrings/docker.gpg
    curl --fail --silent --show-error --location "https://download.docker.com/linux/${DISTRIB_ID}/gpg" | \
      gpg --dearmor --output /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRIB_ID} ${DISTRIB_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install --yes ${REQUIRED_DOCKER_PACKAGES}
  fi

  # Create data directory.
  if ! [[ -d "${PDS_DATADIR}" ]]; then
    echo "* Creating data directory ${PDS_DATADIR}"
    mkdir --parents "${PDS_DATADIR}"
  fi
  chmod 700 "${PDS_DATADIR}"

  # Create the PDS env config
  PDS_ADMIN_PASSWORD=$(eval "${GENERATE_SECURE_SECRET_CMD}")
  cat <<PDS_CONFIG >"${PDS_DATADIR}/pds.env"
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_JWT_SECRET=$(eval "${GENERATE_SECURE_SECRET_CMD}")
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(eval "${GENERATE_K256_PRIVATE_KEY_CMD}")
PDS_DATA_DIRECTORY=${PDS_DATADIR}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_BLOB_UPLOAD_LIMIT=52428800
PDS_DID_PLC_URL=${PDS_DID_PLC_URL}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_BSKY_APP_VIEW_DID=${PDS_BSKY_APP_VIEW_DID}
PDS_REPORT_SERVICE_URL=${PDS_REPORT_SERVICE_URL}
PDS_REPORT_SERVICE_DID=${PDS_REPORT_SERVICE_DID}
PDS_CRAWLERS=${PDS_CRAWLERS}
PDS_ADMIN_EMAIL=${PDS_ADMIN_EMAIL}
PDS_DATADIR=${PDS_DATADIR}
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_PUBLIC_IP=${PUBLIC_IP}
PDS_CONFIG_ENABLED=true
PDS_DEBUG=true
PDS_DATA_DIRECTORY=${PDS_DATADIR}
PDS_DATABASE_URL=sqlite:///${PDS_DATADIR}/pds.sqlite
PDS_ADMIN_EMAIL=${PDS_ADMIN_EMAIL}
PDS_CONFIG_ENABLED=true
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(eval "${GENERATE_K256_PRIVATE_KEY_CMD}")
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_DATADIR=${PDS_DATADIR}
PDS_JWT_SECRET=$(eval "${GENERATE_SECURE_SECRET_CMD}")
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_ADMIN_EMAIL=${PDS_ADMIN_EMAIL}
PDS_PUBLIC_IP=${PUBLIC_IP}
PDS_CONFIG_ENABLED=true
PDS_DEBUG=true
PDS_DATABASE_URL=sqlite:///${PDS_DATADIR}/pds.sqlite
PDS_ADMIN_EMAIL=${PDS_ADMIN_EMAIL}
PDS_CONFIG_ENABLED=true
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_CRAWLERS=${PDS_CRAWLERS}
PDS_REPORT_SERVICE_URL=${PDS_REPORT_SERVICE_URL}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_REPORT_SERVICE_DID=${PDS_REPORT_SERVICE_DID}
PDS_CRAWLERS=${PDS_CRAWLERS}
PDS_DATADIR=${PDS_DATADIR}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_CONFIG_ENABLED=true
PDS_DATADIR=${PDS_DATADIR}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATADIR}/blocks
PDS_REPORT_SERVICE_URL=${PDS_REPORT_SERVICE_URL}
PDS_CRAWLERS=${PDS_CRAWLERS}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_BSKY_APP_VIEW_DID=${PDS_BSKY_APP_VIEW_DID}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_BSKY_APP_VIEW_URL_PDS_ROLE_ADMIN```
