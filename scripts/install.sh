#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROJECT_NAME="docker-secrets-1password"
readonly PROJECT_REPOSITORY="https://github.com/alikhil/docker-secrets-1password"
readonly MIN_DOCKER_VERSION="29.2.0"
readonly MIN_SYSTEMD_VERSION="250"
readonly SERVICE_NAME="docker-secrets-1password.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly DEFAULT_CREDENTIAL_FILE="/etc/docker-secrets-1password/op-connect-token.cred"
readonly DEFAULT_CONNECT_HOST="http://127.0.0.1:8080"
readonly CONNECT_SETUP_URL="https://www.1password.dev/connect/get-started#1password-cli"

WORK_DIR=""
INSTALL_USER=""
INSTALL_GROUP=""
INSTALL_HOME=""
INSTALL_UID=""
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
ARCH=""
PLUGIN_VERSION=""
INSTALLED_PLUGIN_VERSION=""
PLUGIN_ACTION="install"
EXISTING_INSTALLATION="false"
CONNECT_HOST=""
CREDENTIAL_FILE="${DEFAULT_CREDENTIAL_FILE}"

info() {
  printf '\n==> %s\n' "$*"
}

success() {
  printf '  [ok] %s\n' "$*"
}

warn() {
  printf '  [warning] %s\n' "$*" >&2
}

die() {
  printf '  [error] %s\n' "$*" >&2
  exit 1
}

run_quiet() {
  local description="$1"
  local log_file="${WORK_DIR}/command-output.log"
  local status=0

  shift
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] || die "Internal error: command log directory is unavailable."

  printf '  [run] %s...\n' "${description}"
  if "$@" >"${log_file}" 2>&1; then
    success "${description}"
    return 0
  else
    status=$?
  fi

  warn "${description} failed. Last 15 lines of command output:"
  if [[ -s "${log_file}" ]]; then
    if [[ -t 2 ]]; then
      printf '\033[2m' >&2
    fi
    tail -n 15 "${log_file}" >&2
    if [[ -t 2 ]]; then
      printf '\033[0m' >&2
    fi
  else
    printf '    (the command produced no output)\n' >&2
  fi
  die "Command exited with status ${status}."
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

usage() {
  cat <<'EOF'
Interactive installer for Docker Secrets Engine and its 1Password Connect provider.

Supported systems: Ubuntu 24.04+ and Debian 12+ with systemd 250 or later.
Ubuntu 22.04 is intentionally unsupported because it ships systemd 249.

Usage:
  ./scripts/install.sh
  ./scripts/install.sh --help

Run this script as the non-root Linux user whose containers will use Docker
Secrets Engine. The installer asks for sudo only when changing system packages,
systemd configuration, or the encrypted Connect credential.
EOF
}

confirm() {
  local prompt="$1"
  local default="${2:-yes}"
  local answer=""
  local suffix="[Y/n]"

  if [[ "${default}" == "no" ]]; then
    suffix="[y/N]"
  fi

  read -r -p "${prompt} ${suffix} " answer
  answer="${answer:-${default}}"
  case "${answer}" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local answer=""

  read -r -p "${prompt} [${default}]: " answer
  printf '%s' "${answer:-${default}}"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

valid_release_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]
}

provider_install_action() {
  local installed="$1"
  local requested="$2"

  if [[ -z "${installed}" ]]; then
    printf 'install'
  elif dpkg --compare-versions "${requested}" gt "${installed}"; then
    printf 'upgrade'
  elif dpkg --compare-versions "${requested}" lt "${installed}"; then
    printf 'downgrade'
  else
    printf 'reconfigure'
  fi
}

valid_connect_host() {
  local value="$1"
  local authority=""
  local port=""

  [[ "${value}" =~ ^https?:// ]] || return 1
  authority="${value#*://}"

  if [[ "${authority}" =~ ^[A-Za-z0-9._-]+(:([0-9]{1,5}))?$ ]]; then
    port="${BASH_REMATCH[2]}"
  elif [[ "${authority}" =~ ^\[[0-9A-Fa-f:.]+\](:([0-9]{1,5}))?$ ]]; then
    port="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  if [[ -n "${port}" ]]; then
    ((10#${port} > 0 && 10#${port} <= 65535)) || return 1
  fi
}

docker_version_is_supported() {
  local version="${1#v}"

  dpkg --compare-versions "${version}" ge "${MIN_DOCKER_VERSION}"
}

systemd_version_is_supported() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= MIN_SYSTEMD_VERSION))
}

require_command() {
  command_exists "$1" || die "Required command not found: $1"
}

load_platform() {
  [[ "$(uname -s)" == "Linux" ]] || die "Only Linux is supported."
  [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution."

  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION="${VERSION_ID:-}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

  case "${OS_ID}" in
    ubuntu)
      [[ -n "${OS_VERSION}" ]] || die "Cannot determine the Ubuntu version."
      dpkg --compare-versions "${OS_VERSION}" ge "24.04" \
        || die "Ubuntu 22.04 is not supported. The installer requires Ubuntu 24.04 or later."
      ;;
    debian)
      [[ -n "${OS_VERSION}" ]] || die "Cannot determine the Debian version."
      dpkg --compare-versions "${OS_VERSION}" ge "12" \
        || die "The installer requires Debian 12 or later."
      ;;
    *) die "Only Debian and Ubuntu are currently supported (detected ${OS_ID:-unknown})." ;;
  esac

  [[ -n "${OS_CODENAME}" ]] || die "The distribution codename is unavailable in /etc/os-release."

  ARCH="$(dpkg --print-architecture)"
  case "${ARCH}" in
    amd64 | arm64) ;;
    *) die "No provider release is published for architecture ${ARCH}." ;;
  esac

  success "Operating system: ${PRETTY_NAME:-${OS_ID}}"
  success "Architecture: ${ARCH}"
}

load_install_user() {
  [[ "${EUID}" -ne 0 ]] || die "Do not run this installer with sudo. Run it as the intended Docker user."

  INSTALL_USER="$(id -un)"
  INSTALL_GROUP="$(id -gn)"
  INSTALL_UID="$(id -u)"
  INSTALL_HOME="$(getent passwd "${INSTALL_USER}" | cut -d: -f6)"

  [[ "${INSTALL_USER}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "The installation user name cannot be represented safely in a systemd unit."
  [[ "${INSTALL_GROUP}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "The installation group name cannot be represented safely in a systemd unit."
  [[ "${INSTALL_HOME}" == /* && "${INSTALL_HOME}" != *[[:space:]\"\\]* ]] \
    || die "The installation home path cannot be represented safely in a systemd unit."
  [[ -n "${INSTALL_HOME}" && -d "${INSTALL_HOME}" ]] || die "Cannot determine the home directory for ${INSTALL_USER}."
  success "Installation user: ${INSTALL_USER} (${INSTALL_HOME})"
}

check_base_prerequisites() {
  local systemd_version=""

  info "Checking host prerequisites"

  [[ -t 0 && -t 1 ]] || die "This installer is interactive and must run in a terminal."

  require_command apt-get
  require_command apt-cache
  require_command awk
  require_command cat
  require_command cut
  require_command dirname
  require_command dpkg
  require_command dpkg-query
  require_command getent
  require_command grep
  require_command id
  require_command install
  require_command loginctl
  require_command mktemp
  require_command ps
  require_command rm
  require_command sha256sum
  require_command sleep
  require_command sudo
  require_command systemctl
  require_command tail
  require_command tr
  require_command uname

  [[ "$(ps -p 1 -o comm= | tr -d ' ')" == "systemd" ]] || die "systemd must be PID 1."
  systemd_version="$(systemctl --version | awk 'NR == 1 { print $2 }')"
  systemd_version_is_supported "${systemd_version}" \
    || die "systemd ${MIN_SYSTEMD_VERSION} or later is required for encrypted credentials (detected ${systemd_version:-unknown})."
  require_command systemd-ask-password
  require_command systemd-creds

  success "systemd ${systemd_version} supports encrypted credentials"
  success "Required base commands are available"
}

confirm_sudo_access() {
  info "Confirming administrative access"
  sudo -v
  success "sudo access confirmed"
}

package_is_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)" == "ii " ]]
}

install_download_prerequisites() {
  info "Installing download prerequisites"
  if command_exists curl && package_is_installed ca-certificates; then
    success "ca-certificates and curl are already installed"
    return 0
  fi

  run_quiet "Updating APT package lists" sudo apt-get update
  run_quiet "Installing ca-certificates and curl" sudo apt-get install -y ca-certificates curl
  require_command curl
}

confirm_connect_available() {
  info "Checking 1Password Connect availability"
  if confirm "Is a 1Password Connect server already running and reachable from this host?" yes; then
    success "1Password Connect is available for configuration"
    return 0
  fi

  printf '\nInstall and start 1Password Connect before continuing:\n'
  printf '  %s\n' "${CONNECT_SETUP_URL}"
  printf '\nAfter Connect is reachable from this host, rerun this installer.\n'
  die "A running 1Password Connect server is required."
}

docker_repository_has_secrets_engine() {
  apt-cache show docker-secrets-engine >/dev/null 2>&1
}

configure_docker_repository() {
  local key_file="${WORK_DIR}/docker.asc"
  local source_file="${WORK_DIR}/docker.sources"

  info "Configuring Docker's official APT repository"
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    "https://download.docker.com/linux/${OS_ID}/gpg" \
    --output "${key_file}"

  printf '%s\n' \
    'Types: deb' \
    "URIs: https://download.docker.com/linux/${OS_ID}" \
    "Suites: ${OS_CODENAME}" \
    'Components: stable' \
    "Architectures: ${ARCH}" \
    'Signed-By: /etc/apt/keyrings/docker.asc' >"${source_file}"

  sudo install -d -m 0755 /etc/apt/keyrings
  sudo install -m 0644 "${key_file}" /etc/apt/keyrings/docker.asc
  sudo install -m 0644 "${source_file}" /etc/apt/sources.list.d/docker.sources
  run_quiet "Refreshing APT package lists" sudo apt-get update

  docker_repository_has_secrets_engine || die "Docker's repository does not offer docker-secrets-engine for ${OS_ID} ${OS_CODENAME} (${ARCH})."
  success "Docker APT repository configured"
}

ensure_docker_repository() {
  if docker_repository_has_secrets_engine; then
    success "Docker's APT repository provides Docker Secrets Engine"
    return 0
  fi

  warn "Docker Secrets Engine is not available from the configured APT repositories."
  confirm "Configure Docker's official APT repository?" yes || die "Docker's official repository is required."
  configure_docker_repository
}

docker_server_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null
}

install_docker_ce() {
  info "Installing Docker CE"
  run_quiet "Installing Docker CE packages" \
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_quiet "Enabling and starting Docker" sudo systemctl enable --now docker.service
}

ensure_docker_access() {
  local server_version=""

  if ! command_exists docker; then
    warn "Docker is not installed."
    confirm "Install Docker CE from Docker's official repository?" yes || die "Docker Engine ${MIN_DOCKER_VERSION}+ is required."
    install_docker_ce
  fi

  server_version="$(docker_server_version || true)"
  if [[ -z "${server_version}" ]]; then
    if ! sudo docker version >/dev/null 2>&1; then
      warn "The Docker daemon is not reachable."
      confirm "Enable and start docker.service?" yes || die "A running Docker daemon is required."
      run_quiet "Enabling and starting Docker" sudo systemctl enable --now docker.service
    fi

    server_version="$(docker_server_version || true)"
  fi

  if [[ -z "${server_version}" ]]; then
    warn "${INSTALL_USER} cannot access the Docker daemon."
    warn "Membership in the docker group grants root-equivalent access to the host."
    if confirm "Add ${INSTALL_USER} to the docker group?" no; then
      sudo usermod -aG docker "${INSTALL_USER}"
      die "Group membership was updated. Log out and back in, then rerun this installer."
    fi
    die "The installation user must be able to access the Docker daemon."
  fi

  if ! docker_version_is_supported "${server_version}"; then
    warn "Docker Engine ${server_version} is older than the required ${MIN_DOCKER_VERSION}."
    if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'ok installed'; then
      warn "Upgrading Docker may restart the daemon and running containers."
      confirm "Upgrade Docker CE now?" no || die "Upgrade Docker Engine before continuing."
      install_docker_ce
      server_version="$(docker_server_version || true)"
    else
      die "An unsupported non-Docker-CE installation is present. Migrate it using Docker's official Engine instructions, then rerun this installer."
    fi
  fi

  [[ -n "${server_version}" ]] || die "Cannot read the Docker server version after installation."
  docker_version_is_supported "${server_version}" || die "Docker Engine ${server_version} is still older than ${MIN_DOCKER_VERSION}."
  success "Docker Engine ${server_version} is running and accessible"
}

install_secrets_engine() {
  info "Installing Docker Secrets Engine"
  run_quiet "Installing Docker Secrets Engine packages" \
    sudo apt-get install -y docker-secrets-engine docker-secrets-engine-plugins

  docker pass --help >/dev/null 2>&1 || die "The installed Docker CLI does not provide 'docker pass'."
  success "Docker Secrets Engine packages installed"

  if confirm "Install Docker's recommended DBus and Secret Service packages?" yes; then
    run_quiet "Installing DBus and gnome-keyring packages" \
      sudo apt-get install -y dbus-user-session gnome-keyring
  else
    warn "The external 1Password provider works without a keyring, but some docker pass commands may not."
  fi
}

latest_plugin_version() {
  local final_url=""
  local tag=""

  final_url="$(curl --fail --silent --show-error --location \
    --output /dev/null --write-out '%{url_effective}' \
    --proto '=https' --proto-redir '=https' \
    "${PROJECT_REPOSITORY}/releases/latest")"
  tag="${final_url##*/}"
  tag="${tag#v}"
  valid_release_version "${tag}" || return 1
  printf '%s' "${tag}"
}

installed_plugin_version() {
  local version=""

  version="$(dpkg-query -W -f='${Version}' "${PROJECT_NAME}" 2>/dev/null)" || return 1
  [[ -n "${version}" ]] || return 1
  printf '%s' "${version}"
}

detect_existing_installation() {
  detect_existing_installation_from \
    "${SERVICE_FILE}" \
    "$(installed_plugin_version || true)"
}

detect_existing_installation_from() {
  local service_file="$1"
  local detected_version="$2"

  INSTALLED_PLUGIN_VERSION="${detected_version}"
  EXISTING_INSTALLATION="false"
  [[ -n "${INSTALLED_PLUGIN_VERSION}" ]] || return 0

  info "Existing provider installation detected"
  success "Installed provider version: ${INSTALLED_PLUGIN_VERSION}"

  if [[ -r "${service_file}" ]]; then
    EXISTING_INSTALLATION="true"
    success "Existing system service: ${service_file}"
  else
    warn "The provider package is installed, but its system service is not configured."
  fi
}

select_plugin_version() {
  local default_version=""
  local latest=""
  local requested=""

  info "Selecting provider release"
  latest="$(latest_plugin_version)" || die "Cannot determine the latest ${PROJECT_NAME} release."
  default_version="${latest}"

  if [[ -n "${INSTALLED_PLUGIN_VERSION}" ]]; then
    if dpkg --compare-versions "${INSTALLED_PLUGIN_VERSION}" gt "${latest}"; then
      default_version="${INSTALLED_PLUGIN_VERSION}"
      warn "The installed provider is newer than the latest published release (${latest})."
    fi
  fi

  requested="$(prompt_with_default "Provider version" "${default_version}")"
  valid_release_version "${requested}" || die "Invalid release version: ${requested}"
  PLUGIN_VERSION="${requested}"
  PLUGIN_ACTION="$(provider_install_action "${INSTALLED_PLUGIN_VERSION}" "${PLUGIN_VERSION}")"

  if [[ "${PLUGIN_ACTION}" == "reconfigure" && ! -x /usr/bin/docker-secrets-1password ]]; then
    PLUGIN_ACTION="reinstall"
    warn "The provider package is registered as installed, but its binary is missing."
  fi

  case "${PLUGIN_ACTION}" in
    install) success "Provider v${PLUGIN_VERSION} will be installed" ;;
    upgrade) success "Provider will be upgraded from v${INSTALLED_PLUGIN_VERSION} to v${PLUGIN_VERSION}" ;;
    reconfigure) success "Provider v${PLUGIN_VERSION} is already installed; its service will be refreshed" ;;
    reinstall) success "Provider v${PLUGIN_VERSION} will be reinstalled" ;;
    downgrade)
      warn "Requested provider v${PLUGIN_VERSION} is older than installed v${INSTALLED_PLUGIN_VERSION}."
      confirm "Downgrade the provider?" no || die "Provider downgrade cancelled."
      ;;
    *) die "Internal error: unknown provider action ${PLUGIN_ACTION}." ;;
  esac

  success "Provider version: ${PLUGIN_VERSION}"
}

download_and_verify_plugin() {
  local -a apt_install_args=(-y)
  local asset="${PROJECT_NAME}_${PLUGIN_VERSION}_${ARCH}.deb"
  local release_url="${PROJECT_REPOSITORY}/releases/download/v${PLUGIN_VERSION}"
  local package_file="${WORK_DIR}/${asset}"
  local checksums_file="${WORK_DIR}/checksums.txt"
  local expected=""
  local actual=""

  info "Downloading provider v${PLUGIN_VERSION}"
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --proto-redir '=https' \
    "${release_url}/${asset}" --output "${package_file}"
  curl --fail --silent --show-error --location --retry 3 \
    --proto '=https' --proto-redir '=https' \
    "${release_url}/checksums.txt" --output "${checksums_file}"

  expected="$(awk -v asset="${asset}" '$2 == asset { print $1 }' "${checksums_file}")"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "The release checksum file has no valid entry for ${asset}."
  actual="$(sha256sum "${package_file}" | awk '{ print $1 }')"
  [[ "${actual}" == "${expected}" ]] || die "Checksum verification failed for ${asset}."
  success "SHA-256 checksum verified"

  if [[ "${PLUGIN_ACTION}" == "downgrade" ]]; then
    apt_install_args+=(--allow-downgrades)
  elif [[ "${PLUGIN_ACTION}" == "reinstall" ]]; then
    apt_install_args+=(--reinstall)
  fi

  run_quiet "Installing provider package" \
    sudo apt-get install "${apt_install_args[@]}" "${package_file}"
  [[ -x /usr/bin/docker-secrets-1password ]] || die "The provider binary was not installed in /usr/bin."
  success "Provider v${PLUGIN_VERSION} installed"
}

install_or_upgrade_plugin() {
  if [[ "${PLUGIN_ACTION}" == "reconfigure" ]]; then
    success "Provider package v${PLUGIN_VERSION} is already current"
    return 0
  fi

  download_and_verify_plugin
}

existing_connect_host() {
  local line=""

  [[ -r "${SERVICE_FILE}" ]] || return 1
  line="$(grep -m1 '^Environment=.*OP_CONNECT_HOST=' "${SERVICE_FILE}" || true)"
  [[ -n "${line}" ]] || return 1
  line="${line#Environment=}"
  line="${line#\"}"
  line="${line%\"}"
  line="${line#OP_CONNECT_HOST=}"
  valid_connect_host "${line}" || return 1
  printf '%s' "${line}"
}

use_existing_credential_path() {
  local service_file="${1:-${SERVICE_FILE}}"
  local line=""
  local path=""

  [[ -r "${service_file}" ]] || return 0
  line="$(grep -m1 '^LoadCredentialEncrypted=op-connect-token:' "${service_file}" || true)"
  [[ -n "${line}" ]] || return 0
  path="${line#LoadCredentialEncrypted=op-connect-token:}"
  if [[ "${path}" != "${DEFAULT_CREDENTIAL_FILE}" \
    && "${path}" != "${INSTALL_HOME}/.config/docker-secrets-1password/op-connect-token.cred" ]]; then
    warn "Ignoring unsupported credential path in the existing unit: ${path}"
    return 0
  fi
  CREDENTIAL_FILE="${path}"
}

select_connect_host() {
  local default_host="${DEFAULT_CONNECT_HOST}"
  local requested=""

  default_host="$(existing_connect_host || printf '%s' "${default_host}")"
  requested="$(prompt_with_default "1Password Connect URL" "${default_host}")"
  requested="${requested%/}"
  valid_connect_host "${requested}" || die "Connect URL must contain only an HTTP(S) hostname or IP address and an optional valid port."
  CONNECT_HOST="${requested}"

  if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    --output /dev/null "${CONNECT_HOST}/health"; then
    success "1Password Connect health check passed"
  else
    warn "Cannot reach ${CONNECT_HOST}/health."
    confirm "Continue and let systemd retry the provider later?" no || die "1Password Connect must be reachable before verification can succeed."
  fi
}

create_encrypted_credential() {
  local credential_tmp="${WORK_DIR}/op-connect-token.cred"

  info "Creating encrypted systemd credential"
  printf 'Create a token with the 1Password CLI if you do not have one yet:\n'
  printf '  op connect token create <tokenName> --server <serverName|serverID> --vault <vaultName|vaultID>\n'
  printf 'Then enter the returned token at the secure prompt below.\n\n'
  printf 'The token will not be stored in an environment variable or shell argument.\n'
  sudo -v
  systemd-ask-password "1Password Connect API token" \
    | sudo systemd-creds encrypt --name=op-connect-token - "${credential_tmp}"

  sudo install -d -m 0700 "$(dirname "${CREDENTIAL_FILE}")"
  sudo install -m 0600 -o root -g root "${credential_tmp}" "${CREDENTIAL_FILE}"
  success "Encrypted credential installed at ${CREDENTIAL_FILE}"
}

configure_credential() {
  if sudo test -f "${CREDENTIAL_FILE}"; then
    success "Existing encrypted credential found at ${CREDENTIAL_FILE}"
    if confirm "Replace the existing encrypted Connect credential?" no; then
      create_encrypted_credential
    else
      success "Existing encrypted credential preserved"
    fi
  else
    create_encrypted_credential
  fi
}

write_service_unit() {
  local unit_tmp="${WORK_DIR}/${SERVICE_NAME}"

  info "Configuring the provider system service"
  cat >"${unit_tmp}" <<EOF
[Unit]
Description=1Password Connect provider for Docker Secrets Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${INSTALL_USER}
Group=${INSTALL_GROUP}
Environment="HOME=${INSTALL_HOME}"
Environment="XDG_RUNTIME_DIR=/run/user/${INSTALL_UID}"
Environment="OP_CONNECT_HOST=${CONNECT_HOST}"
LoadCredentialEncrypted=op-connect-token:${CREDENTIAL_FILE}
ExecStart=/usr/bin/docker-secrets-1password
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  sudo install -m 0644 -o root -g root "${unit_tmp}" "${SERVICE_FILE}"
  sudo systemctl daemon-reload
  success "System service installed at ${SERVICE_FILE}"
}

start_services() {
  info "Starting Docker Secrets Engine and the provider"
  sudo loginctl enable-linger "${INSTALL_USER}"
  systemctl --user daemon-reload
  systemctl --user enable --now docker-secrets-engine.service
  sudo systemctl enable "${SERVICE_NAME}"
  sudo systemctl restart "${SERVICE_NAME}"
}

verify_installation() {
  local registered="false"

  info "Verifying installation"
  systemctl --user is-active --quiet docker-secrets-engine.service \
    || die "Docker Secrets Engine user service is not active."
  sudo systemctl is-active --quiet "${SERVICE_NAME}" \
    || die "The 1Password provider service is not active. Check: sudo journalctl -u ${SERVICE_NAME}"

  for _ in {1..15}; do
    if docker pass plugins ls 2>/dev/null \
      | grep -F "${PROJECT_NAME}" \
      | grep -F "v${PLUGIN_VERSION}" \
      | grep -Fq 'running'; then
      success "Provider is registered and running"
      registered="true"
      break
    fi
    sleep 1
  done

  [[ "${registered}" == "true" ]] || die "The provider did not register. Check: sudo journalctl -u ${SERVICE_NAME}"

  if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    --output /dev/null "${CONNECT_HOST}/health"; then
    success "1Password Connect is healthy"
  else
    warn "The services are running, but the Connect health check still fails."
  fi

  printf '\nInstallation complete.\n'
  printf 'Use references such as: se://op/<vault>/<item>/<field>\n'
  printf 'Inspect providers with: docker pass plugins ls\n'
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return 0
  fi
  [[ "$#" -eq 0 ]] || die "Unknown argument: $1"

  check_base_prerequisites
  load_platform
  load_install_user

  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT

  detect_existing_installation
  if [[ "${EXISTING_INSTALLATION}" == "true" ]]; then
    success "Existing Connect configuration will be reused and verified"
  else
    confirm_connect_available
  fi
  confirm_sudo_access
  install_download_prerequisites
  ensure_docker_repository
  ensure_docker_access
  select_plugin_version
  use_existing_credential_path
  select_connect_host

  warn "Docker Secrets Engine support on Docker CE is experimental and may change between releases."
  printf '\nInstallation summary:\n'
  printf '  User:               %s\n' "${INSTALL_USER}"
  printf '  Docker requirement: %s or later\n' "${MIN_DOCKER_VERSION}"
  printf '  Provider version:   %s\n' "${PLUGIN_VERSION}"
  printf '  Provider action:    %s\n' "${PLUGIN_ACTION}"
  printf '  Connect URL:        %s\n' "${CONNECT_HOST}"
  printf '  Credential file:    %s\n' "${CREDENTIAL_FILE}"
  confirm "Continue with package and service installation?" yes || die "Installation cancelled."

  install_secrets_engine
  install_or_upgrade_plugin
  configure_credential
  write_service_unit
  start_services
  verify_installation
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
