#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_valid_version() {
  valid_release_version "$1" || fail "expected valid release version: $1"
}

assert_invalid_version() {
  if valid_release_version "$1"; then
    fail "expected invalid release version: $1"
  fi
}

assert_valid_host() {
  valid_connect_host "$1" || fail "expected valid Connect host: $1"
}

assert_invalid_host() {
  if valid_connect_host "$1"; then
    fail "expected invalid Connect host: $1"
  fi
}

assert_valid_version "0.2.0"
assert_valid_version "1.0.0-rc.1"
assert_invalid_version "v0.2.0"
assert_invalid_version "0.2"
assert_invalid_version "0.2.0/../../payload"
assert_invalid_version "0.2.0\$(touch /tmp/pwned)"

if ! command_exists dpkg; then
  dpkg() {
    [[ "$1" == "--compare-versions" ]] || return 2
    case "$2 $3 $4" in
      "0.2.0 gt 0.1.0" | "0.2.0 lt 0.3.0") return 0 ;;
      *) return 1 ;;
    esac
  }
fi

[[ "$(provider_install_action "" "0.2.0")" == "install" ]] \
  || fail "a missing provider should select installation"
[[ "$(provider_install_action "0.1.0" "0.2.0")" == "upgrade" ]] \
  || fail "a newer requested version should select upgrade"
[[ "$(provider_install_action "0.2.0" "0.2.0")" == "reconfigure" ]] \
  || fail "the installed version should select reconfiguration"
[[ "$(provider_install_action "0.3.0" "0.2.0")" == "downgrade" ]] \
  || fail "an older requested version should select downgrade"

existing_install_dir="$(mktemp -d)"
printf '[Service]\n' >"${existing_install_dir}/provider.service"
detect_existing_installation_from "${existing_install_dir}/provider.service" "0.2.0" >/dev/null
[[ "${EXISTING_INSTALLATION}" == "true" ]] \
  || fail "an installed package with a service should be detected as an existing installation"
detect_existing_installation_from "${existing_install_dir}/missing.service" "0.2.0" >/dev/null 2>&1
[[ "${EXISTING_INSTALLATION}" == "false" ]] \
  || fail "an installed package without a service should require fresh configuration"
rm -rf -- "${existing_install_dir}"

systemd_version_is_supported "250" || fail "expected systemd 250 to be supported"
systemd_version_is_supported "255" || fail "expected systemd 255 to be supported"
if systemd_version_is_supported "249"; then
  fail "expected systemd 249 to be unsupported"
fi
if systemd_version_is_supported "invalid"; then
  fail "expected a non-numeric systemd version to be unsupported"
fi

missing_unit_dir="$(mktemp -d)"
use_existing_credential_path "${missing_unit_dir}/missing.service" \
  || fail "a missing existing unit must not terminate a fresh installation"
rm -rf -- "${missing_unit_dir}"

quiet_test_dir="$(mktemp -d)"
# shellcheck disable=SC2034 # Consumed by run_quiet from the sourced installer.
WORK_DIR="${quiet_test_dir}"
quiet_output="$(run_quiet "Testing quiet command" sh -c 'printf "hidden command output\\n"')"
[[ "${quiet_output}" == *"[run] Testing quiet command..."* ]] \
  || fail "quiet command should display a running status"
[[ "${quiet_output}" == *"[ok] Testing quiet command"* ]] \
  || fail "quiet command should display a success status"
[[ "${quiet_output}" != *"hidden command output"* ]] \
  || fail "successful command output should be suppressed"

if quiet_failure_output="$(
  # shellcheck disable=SC2016
  run_quiet "Testing failed command" sh -c \
    'i=1; while [ "$i" -le 20 ]; do printf "command-line-%s\\n" "$i"; i=$((i + 1)); done; exit 7' \
    2>&1
)"; then
  fail "a failed quiet command should terminate with an error"
fi
[[ "${quiet_failure_output}" == *"command-line-6"* ]] \
  || fail "failed command output should include the first of the last 15 lines"
[[ "${quiet_failure_output}" == *"command-line-20"* ]] \
  || fail "failed command output should include the final line"
[[ "${quiet_failure_output}" != *"command-line-5"* ]] \
  || fail "failed command output should not include lines before the last 15"
[[ "${quiet_failure_output}" == *"status 7"* ]] \
  || fail "failed command output should report its exit status"
rm -rf -- "${quiet_test_dir}"

assert_valid_host "http://127.0.0.1:8080"
assert_valid_host "https://connect.example.internal"
assert_valid_host "https://[::1]:8080"
assert_invalid_host "ftp://connect.example.internal"
assert_invalid_host "https://token@connect.example.internal"
assert_invalid_host "https://connect.example.internal/path"
assert_invalid_host "https://connect.example.internal?token=value"
assert_invalid_host "https://connect.example.internal:0"
assert_invalid_host "https://connect.example.internal:65536"
assert_invalid_host 'https://connect.example.internal;touch-pwned'
assert_invalid_host "https://connect.example.internal\`touch-pwned\`"
assert_invalid_host "https://connect.example.internal bad"
assert_invalid_host 'https://connect.example.internal"bad'
assert_invalid_host 'https://connect.example.internal\bad'

bash "${SCRIPT_DIR}/install.sh" --help >/dev/null

printf 'Installer helper tests passed.\n'
