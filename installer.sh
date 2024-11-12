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

# Secure generator comands
GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"

# The Docker compose file.
COMPOSE_URL="https://raw.githubusercontent.com/mrbrandoncharles/pds/main/compose.yaml"

# The pdsadmin script.
PDSADMIN_URL="https://raw.githubusercontent.com/mrbrandoncharles/pds/main/pdsadmin.sh"

# System dependencies.
REQUIRED_SYSTEM_PACKAGES="
  ca-certificates
  curl
  gnupg
  jq
  lsb-release
  openssl
  sqlite3
  xxd
"
# Docker packages.
REQUIRED_DOCKER_PACKAGES="
  containerd.io
  docker-ce
  docker-ce-cli
  docker-compose-plugin
"

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
  if [[ "${DISTRIB_ID}" == "ubuntu" ]]; then
    if [[ "${DISTRIB_CODENAME}" == "focal" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Ubuntu 20.04 LTS"
    elif [[ "${DISTRIB_CODENAME}" == "jammy" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Ubuntu 22.04 LTS"
    elif [[ "${DISTRIB_CODENAME}" == "mantic" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Ubuntu 23.10 LTS"
    fi
  elif [[ "${DISTRIB_ID}" == "debian" ]]; then
    if [[ "${DISTRIB_CODENAME}" == "bullseye" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Debian 11"
    elif [[ "${DISTRIB_CODENAME}" == "bookworm" ]]; then
      SUPPORTED_OS="true"
      echo "* Detected supported distribution Debian 12"
    fi
  fi

  if [[ "${SUPPORTED_OS}" != "true" ]]; then
    echo "Sorry, only Ubuntu 20.04, 22.04, Debian 11 and Debian 12 are supported by this installer. Exiting..."
    exit 1
  fi

  # Enforce that the data directory is /pds since we're assuming it for now.
  if [[ "${PDS_DATADIR}" != "/pds" ]]; then
    usage "The data directory must be /pds. Exiting..."
  fi

  # Install system packages.
  apt-get update
  apt-get install --yes ${REQUIRED_SYSTEM_PACKAGES}

  # Install Docker.
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

  # Download and install pds launcher.
  echo "* Downloading PDS compose file"
  curl --silent --show-error --fail --output "${PDS_DATADIR}/compose.yaml" "${COMPOSE_URL}"

  # Replace /pds paths in the compose file with the PDS_DATADIR path.
  sed --in-place "s|/pds|${PDS_DATADIR}|g" "${PDS_DATADIR}/compose.yaml"

  # Start Docker containers manually (no systemd).
  echo "* Starting PDS service using Docker Compose"
  docker compose --file "${PDS_DATADIR}/compose.yaml" up --detach

  # Enable firewall access if ufw is in use.
  if ufw status >/dev/null 2>&1; then
    if ! ufw status | grep --quiet '^80[/ ]'; then
      echo "* Enabling access on TCP port 80 using ufw"
      ufw allow 80/tcp >/dev/null
    fi
    if ! ufw status | grep --quiet '^443[/ ]'; then
      echo "* Enabling access on TCP port 443 using ufw"
      ufw allow 443/tcp >/dev/null
    fi
  fi

  # Download and install pdadmin.
  echo "* Downloading pdsadmin"
  curl --silent --show-error --fail --output "/usr/local/bin/pdsadmin" "${PDSADMIN_URL}"
  chmod +x /usr/local/bin/pdsadmin

  cat <<INSTALLER_MESSAGE
========================================================================
PDS installation successful!
------------------------------------------------------------------------

To start PDS service manually, run:
  docker compose --file ${PDS_DATADIR}/compose.yaml up --detach

To stop the PDS service, run:
  docker compose --file ${PDS_DATADIR}/compose.yaml down

========================================================================
INSTALLER_MESSAGE

  CREATE_ACCOUNT_PROMPT=""
  read -p "Create a PDS user account? (y/N): " CREATE_ACCOUNT_PROMPT

  if [[ "${CREATE_ACCOUNT_PROMPT}" =~ ^[Yy] ]]; then
    pdsadmin account create
  fi

}

# Run main function.
main
