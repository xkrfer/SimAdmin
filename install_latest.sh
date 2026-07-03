#!/bin/sh

set -eu

REPO="${REPO:-xkrfer/SimAdmin}"
INSTALL_DIR="${INSTALL_DIR:-/opt/simadmin}"
SERVICE_NAME="${SERVICE_NAME:-simadmin}"
VERSION="${VERSION:-latest}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}}"
SERVICE_URL="${SERVICE_URL:-${RAW_BASE}/main/scripts/simadmin.service}"
MODEM_RECOVERY_SCRIPT_URL="${MODEM_RECOVERY_SCRIPT_URL:-${RAW_BASE}/main/scripts/simadmin-modem-recovery.sh}"
MODEM_RECOVERY_SERVICE_URL="${MODEM_RECOVERY_SERVICE_URL:-${RAW_BASE}/main/scripts/simadmin-modem-recovery.service}"
ASSET_URL="${ASSET_URL:-}"
ASSET_NAME="${ASSET_NAME:-}"
SIMADMIN_INSTALL_LPAC="${SIMADMIN_INSTALL_LPAC:-1}"
LPAC_REPO="${LPAC_REPO:-estkme-group/lpac}"
LPAC_RELEASE_BASE_URL="${LPAC_RELEASE_BASE_URL:-https://github.com/${LPAC_REPO}/releases/latest/download}"
LPAC_LATEST_RELEASE_URL="${LPAC_LATEST_RELEASE_URL:-https://github.com/${LPAC_REPO}/releases/latest}"
LPAC_COMPAT_RELEASE_BASE_URL="${LPAC_COMPAT_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download/lpac}"
LPAC_COMPAT_MANIFEST_NAME="${LPAC_COMPAT_MANIFEST_NAME:-lpac.json}"
LPAC_TARGET_ARCH="${LPAC_TARGET_ARCH:-}"
LPAC_TARGET_VERSION="${LPAC_TARGET_VERSION:-}"
LPAC_LATEST_RELEASE_API_URL="${LPAC_LATEST_RELEASE_API_URL:-https://api.github.com/repos/${LPAC_REPO}/releases/latest}"
LPAC_ASSET_FLAVOR="${LPAC_ASSET_FLAVOR:-compat}"
LPAC_ASSET_NAME="${LPAC_ASSET_NAME:-}"
LPAC_ASSET_URL="${LPAC_ASSET_URL:-}"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "error: please run as root" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

download_with_proxies() {
  src_url="$1"
  dst_path="$2"
  echo "    ${src_url}"
  curl -fsSL "$src_url" -o "$dst_path"
}

read_with_proxies() {
  src_url="$1"
  echo "    ${src_url}" >&2
  curl -fsSL "$src_url"
}

version_to_tag() {
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *) printf 'v%s\n' "$1" ;;
  esac
}

asset_url_from_tag() {
  tag="$1"
  asset_name="$(resolve_asset_name)"
  printf 'https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$tag" "$asset_name"
}

resolve_asset_name() {
  if [ -n "$ASSET_NAME" ]; then
    printf '%s\n' "$ASSET_NAME"
    return 0
  fi

  case "$(uname -m)" in
    aarch64|arm64)
      printf '%s\n' "simadmin.tar.gz"
      ;;
    x86_64|amd64)
      printf '%s\n' "simadmin-x86_64.tar.gz"
      ;;
    *)
      printf '%s\n' "simadmin.tar.gz"
      ;;
  esac
}

repo_version() {
  version_text="$(read_with_proxies "${RAW_BASE}/main/VERSION" | tr -d '[:space:]')"
  if [ -z "$version_text" ]; then
    return 1
  fi
  printf '%s\n' "$version_text"
}

resolve_asset_url() {
  if [ -n "$ASSET_URL" ]; then
    printf '%s\n' "$ASSET_URL"
    return 0
  fi

  if [ "$VERSION" = "latest" ]; then
    asset_name="$(resolve_asset_name)"
    printf 'https://github.com/%s/releases/latest/download/%s\n' "$REPO" "$asset_name"
  else
    asset_url_from_tag "$(version_to_tag "$VERSION")"
  fi
}

fallback_asset_url() {
  if [ "$VERSION" = "latest" ] && [ -z "$ASSET_URL" ]; then
    if version_text="$(repo_version)"; then
      asset_url_from_tag "$(version_to_tag "$version_text")"
      return 0
    fi
  fi

  return 1
}

download_release_asset() {
  archive_path="$1"
  primary_url="$2"
  fallback_url=""

  echo "==> downloading release asset"
  if download_with_proxies "$primary_url" "$archive_path"; then
    return 0
  fi

  if fallback_url="$(fallback_asset_url)" && [ "$fallback_url" != "$primary_url" ]; then
    echo "==> latest asset alias download failed, trying versioned asset"
    if download_with_proxies "$fallback_url" "$archive_path"; then
      return 0
    fi
  fi

  echo "error: failed to download OTA asset" >&2
  echo "       tried: $primary_url" >&2
  if [ -n "$fallback_url" ]; then
    echo "       tried: $fallback_url" >&2
  fi
  exit 1
}

install_service_file() {
  service_dst="/etc/systemd/system/${SERVICE_NAME}.service"
  mkdir -p /etc/systemd/system
  download_with_proxies "$SERVICE_URL" "$service_dst"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service" >/dev/null
}

install_modem_recovery_service() {
  script_dst="/usr/local/bin/simadmin-modem-recovery.sh"
  service_dst="/etc/systemd/system/simadmin-modem-recovery.service"

  mkdir -p /usr/local/bin /etc/systemd/system
  download_with_proxies "$MODEM_RECOVERY_SCRIPT_URL" "$script_dst"
  chmod 0755 "$script_dst"
  download_with_proxies "$MODEM_RECOVERY_SERVICE_URL" "$service_dst"
  systemctl daemon-reload
  systemctl enable simadmin-modem-recovery.service >/dev/null
}

configure_networkmanager_modem_unmanaged() {
  if [ ! -d /etc/NetworkManager ]; then
    return 0
  fi

  echo "==> configuring NetworkManager to ignore wwan modem"
  mkdir -p /etc/NetworkManager/conf.d
  nm_conf="/etc/NetworkManager/conf.d/99-simadmin-unmanaged-modem.conf"
  {
    printf '%s\n' '[keyfile]'
    printf '%s\n' 'unmanaged-devices=interface-name:wwan*,interface-name:wws*'
  } > "$nm_conf"

  if systemctl is-active --quiet NetworkManager.service; then
    systemctl restart NetworkManager.service || true
  fi
}

MM_POLICY_CONF="/etc/ModemManager/conf.d/99-simadmin-allow-all.conf"
QUECTEL_UDEV_RULES="/etc/udev/rules.d/99-simadmin-quectel-mm.rules"

udev_device_missing_mm_tags() {
  dev="$1"
  [ -e "$dev" ] || return 1
  udevadm info "$dev" 2>/dev/null | grep -q 'ID_MM_CANDIDATE=1' && return 1
  return 0
}

has_cellular_modem_hardware() {
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb 2>/dev/null | grep -qiE 'quectel|modem|2c7c:|1bc7:|1199:|05c6:|1e0e:'; then
      return 0
    fi
  fi

  if [ -e /dev/cdc-wdm0 ]; then
    return 0
  fi

  if ls /dev/ttyUSB* >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

has_quectel_modem() {
  command -v lsusb >/dev/null 2>&1 || return 1
  lsusb 2>/dev/null | grep -q '2c7c:'
}

needs_quectel_udev_fix() {
  has_quectel_modem || return 1

  if [ -e /dev/cdc-wdm0 ] && udev_device_missing_mm_tags /dev/cdc-wdm0; then
    return 0
  fi

  for dev in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
    if [ -e "$dev" ] && udev_device_missing_mm_tags "$dev"; then
      return 0
    fi
  done

  return 1
}

modemmanager_sees_modem() {
  command -v mmcli >/dev/null 2>&1 || return 1
  mmcli -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem/'
}

ensure_modemmanager_ready() {
  if ! command -v mmcli >/dev/null 2>&1; then
    echo "    installing ModemManager packages"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        modemmanager libqmi-utils libmbim-utils usb-modeswitch
    else
      echo "warning: mmcli not found and apt-get unavailable; install modemmanager manually" >&2
      return 0
    fi
  fi

  if systemctl list-unit-files ModemManager.service >/dev/null 2>&1; then
    systemctl enable ModemManager.service >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet ModemManager.service; then
      echo "    starting ModemManager"
      systemctl start ModemManager.service || true
      MODEM_ENV_NEEDS_MM_RESTART=0
      sleep 3
    fi
  fi
}

ensure_modemmanager_filter_policy() {
  mkdir -p /etc/ModemManager/conf.d
  if [ -f "$MM_POLICY_CONF" ] && grep -q 'filter-policy=none' "$MM_POLICY_CONF" 2>/dev/null; then
    return 0
  fi

  echo "    configuring ModemManager filter-policy=none"
  cat > "$MM_POLICY_CONF" <<'EOF'
# SimAdmin: avoid strict filtering blocking USB modems (e.g. Quectel in VMs)
[Policy]
filter-policy=none
EOF
  MODEM_ENV_NEEDS_MM_RESTART=1
}

ensure_quectel_udev_tags() {
  if ! needs_quectel_udev_fix; then
    return 0
  fi

  echo "    applying Quectel ModemManager udev tags (missing ID_MM_* workaround)"
  cat > "$QUECTEL_UDEV_RULES" <<'EOF'
# SimAdmin: Quectel USB modems - force ModemManager port tags when official
# 77-mm-quectel-port-types.rules does not set ENV{.MM_USBIFNUM} (common in VMs)
SUBSYSTEM=="usbmisc", KERNEL=="cdc-wdm*", ATTRS{idVendor}=="2c7c", \
  TAG+="uaccess", ENV{ID_MM_CANDIDATE}="1", ENV{ID_MM_PORT_TYPE}="qmi"

SUBSYSTEM=="tty", KERNEL=="ttyUSB*", ATTRS{idVendor}=="2c7c", \
  ENV{ID_MM_CANDIDATE}="1", ENV{ID_MM_PORT_TYPE}="at"
EOF
  MODEM_ENV_NEEDS_UDEV_RELOAD=1
}

restart_modemmanager_if_needed() {
  if truthy "${MODEM_ENV_NEEDS_UDEV_RELOAD:-0}"; then
    echo "    reloading udev rules"
    udevadm control --reload-rules
    udevadm trigger
    sleep 2
    MODEM_ENV_NEEDS_MM_RESTART=1
  fi

  if ! truthy "${MODEM_ENV_NEEDS_MM_RESTART:-0}"; then
    return 0
  fi

  if ! systemctl list-unit-files ModemManager.service >/dev/null 2>&1; then
    return 0
  fi

  echo "    restarting ModemManager"
  systemctl stop ModemManager.service >/dev/null 2>&1 || true
  rm -rf /var/lib/ModemManager/* 2>/dev/null || true
  systemctl start ModemManager.service >/dev/null 2>&1 || true
  sleep 8
}

verify_modemmanager_modem() {
  if ! command -v mmcli >/dev/null 2>&1; then
    return 0
  fi

  if modemmanager_sees_modem; then
    mmcli -L 2>/dev/null | sed -n '/Modem/s/^[[:space:]]*/    /p' | head -n 1
    return 0
  fi

  echo "warning: modem hardware detected but ModemManager reports no modems (mmcli -L)" >&2
  echo "warning: check: journalctl -u ModemManager -n 50 --no-pager" >&2
}

prepare_modem_environment() {
  if truthy "${SIMADMIN_SKIP_MODEM_ENV:-0}"; then
    echo "==> skipping modem environment setup (SIMADMIN_SKIP_MODEM_ENV=1)"
    return 0
  fi

  echo "==> checking cellular modem environment"
  MODEM_ENV_NEEDS_UDEV_RELOAD=0
  MODEM_ENV_NEEDS_MM_RESTART=0

  if ! has_cellular_modem_hardware; then
    echo "    no cellular modem hardware detected, skipping"
    return 0
  fi

  ensure_modemmanager_ready
  ensure_modemmanager_filter_policy
  ensure_quectel_udev_tags
  restart_modemmanager_if_needed

  if modemmanager_sees_modem; then
    echo "    ModemManager modem ready"
    verify_modemmanager_modem
    return 0
  fi

  verify_modemmanager_modem
}

normalize_lpac_arch() {
  case "$1" in
    aarch64|arm64)
      printf '%s\n' "aarch64"
      ;;
    x86_64|amd64)
      printf '%s\n' "x86_64"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_lpac_arch() {
  if [ -n "$LPAC_TARGET_ARCH" ]; then
    normalize_lpac_arch "$LPAC_TARGET_ARCH"
    return $?
  fi

  normalize_lpac_arch "$(uname -m)"
}

detect_glibc_version() {
  if command -v getconf >/dev/null 2>&1; then
    version="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  if command -v ldd >/dev/null 2>&1; then
    version="$(ldd --version 2>/dev/null | head -n 1 | sed -E 's/.* ([0-9]+\.[0-9]+).*/\1/' || true)"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  printf '%s\n' ""
}

version_le() {
  [ "$1" = "$2" ] && return 0
  [ -n "$1" ] || return 0
  [ -n "$2" ] || return 1
  first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)"
  [ "$first" = "$1" ]
}

normalize_version_value() {
  value="$1"
  value="${value#refs/tags/}"
  value="${value#tags/}"
  value="${value#v}"
  value="${value#V}"
  printf '%s\n' "$value"
}

version_lt() {
  left="$(normalize_version_value "$1")"
  right="$(normalize_version_value "$2")"
  [ -n "$left" ] || return 0
  [ -n "$right" ] || return 1
  [ "$left" = "$right" ] && return 1
  version_le "$left" "$right"
}

version_token_from_text() {
  printf '%s\n' "$1" \
    | tr '",:{}[]()' '          ' \
    | tr '[:space:]' '\n' \
    | sed -nE '/^[vV]?[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z._-]+)?$/p' \
    | head -n 1
}

json_string_field() {
  field="$1"
  sed -nE 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

resolve_lpac_asset_name() {
  arch="$1"

  if [ -n "$LPAC_ASSET_NAME" ]; then
    printf '%s\n' "$LPAC_ASSET_NAME"
    return 0
  fi

  case "$LPAC_ASSET_FLAVOR" in
    compat)
      glibc_version="$(detect_glibc_version)"
      if [ "$arch" = "aarch64" ] && version_le "2.31" "$glibc_version"; then
        printf 'lpac-linux-aarch64-glibc2.31.zip\n'
      elif [ "$arch" = "x86_64" ] && version_le "2.31" "$glibc_version"; then
        printf 'lpac-linux-x86_64-glibc2.31.zip\n'
      else
        printf 'lpac-linux-%s.zip\n' "$arch"
      fi
      ;;
    ""|default)
      printf 'lpac-linux-%s.zip\n' "$arch"
      ;;
    with-qmi)
      printf 'lpac-linux-%s-with-qmi.zip\n' "$arch"
      ;;
    without-lto)
      printf 'lpac-linux-%s-without-lto.zip\n' "$arch"
      ;;
    *)
      echo "warning: unsupported LPAC_ASSET_FLAVOR=${LPAC_ASSET_FLAVOR}, skipping lpac install" >&2
      return 1
      ;;
  esac
}

resolve_lpac_asset_url() {
  if [ -n "$LPAC_ASSET_URL" ]; then
    printf '%s\n' "$LPAC_ASSET_URL"
    return 0
  fi

  arch="$(detect_lpac_arch)" || return 1
  asset_name="$(resolve_lpac_asset_name "$arch")" || return 1
  if [ "$LPAC_ASSET_FLAVOR" = "compat" ] && {
    [ "$asset_name" = "lpac-linux-aarch64-glibc2.31.zip" ] ||
    [ "$asset_name" = "lpac-linux-x86_64-glibc2.31.zip" ]
  }; then
    printf '%s/%s\n' "$LPAC_COMPAT_RELEASE_BASE_URL" "$asset_name"
    return 0
  fi
  printf '%s/%s\n' "$LPAC_RELEASE_BASE_URL" "$asset_name"
}

extract_lpac_archive() {
  archive="$1"
  target="$2"

  mkdir -p "$target"
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$archive" -d "$target"
    return $?
  fi

  if command -v busybox >/dev/null 2>&1; then
    busybox unzip -oq "$archive" -d "$target"
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$target" <<'PY'
import sys
from zipfile import ZipFile

archive, target = sys.argv[1], sys.argv[2]
ZipFile(archive).extractall(target)
PY
    return $?
  fi

  # Use simadmin's built-in zip extractor if external tools are unavailable.
  if [ -x "${INSTALL_DIR}/simadmin" ]; then
    echo "    using simadmin extract-zip (built-in)"
    "${INSTALL_DIR}/simadmin" extract-zip "$archive" "$target"
    return $?
  fi

  echo "warning: no zip extractor available, skipping lpac install" >&2
  return 1
}

copy_lpac_tree() {
  extract_dir="$1"
  lpac_dst="$2"
  asset_url="$3"

  if [ -f "${extract_dir}/lpac" ]; then
    bundle_root="${extract_dir}"
  elif [ -f "${extract_dir}/executables/lpac" ]; then
    bundle_root="${extract_dir}/executables"
  else
    bundle_root="$(find "$extract_dir" -type f -name lpac -exec dirname {} \; | head -n 1 || true)"
  fi

  if [ -z "$bundle_root" ] || [ ! -f "${bundle_root}/lpac" ]; then
    echo "warning: downloaded lpac asset does not contain lpac executable" >&2
    return 1
  fi

  rm -rf "${lpac_dst}"
  mkdir -p "${lpac_dst}"
  cp -R "${bundle_root}/." "${lpac_dst}/"

  if [ -d "${extract_dir}/lib" ] && [ ! -d "${lpac_dst}/lib" ]; then
    mkdir -p "${lpac_dst}/lib"
    cp -R "${extract_dir}/lib/." "${lpac_dst}/lib/"
  fi

  if [ -d "${extract_dir}/libraries" ] && [ ! -d "${lpac_dst}/lib" ]; then
    mkdir -p "${lpac_dst}/lib"
    cp -R "${extract_dir}/libraries/." "${lpac_dst}/lib/"
  fi

  chmod -R a+rX "${lpac_dst}"
  chmod 0755 "${lpac_dst}/lpac"

  cat > "${lpac_dst}/SOURCE.txt" <<EOF
lpac is installed from:
${asset_url}

Project:
https://github.com/estkme-group/lpac
EOF
}

lpac_env_prefix() {
  lpac_path="$1"
  lpac_home="$(dirname "$lpac_path")"
  printf '%s\n' "${lpac_home}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}

lpac_binary_path_usable() {
  lpac_path="$1"
  if [ ! -x "$lpac_path" ]; then
    return 1
  fi

  output=$(LD_LIBRARY_PATH="$(lpac_env_prefix "$lpac_path")" "$lpac_path" 2>&1 || true)
  case "$output" in
    *GLIBC_*|*No\ such\ file\ or\ directory*)
      return 1
      ;;
  esac

  return 0
}

lpac_binary_usable() {
  lpac_home="$1"
  lpac_binary_path_usable "${lpac_home}/lpac"
}

lpac_command_version() {
  lpac_path="$1"
  [ -x "$lpac_path" ] || return 1

  for arg in version --version -v; do
    output="$(LD_LIBRARY_PATH="$(lpac_env_prefix "$lpac_path")" "$lpac_path" "$arg" 2>&1 || true)"
    version="$(version_token_from_text "$output")"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  done

  return 1
}

lpac_installed_version() {
  lpac_path="$1"
  lpac_home="$(dirname "$lpac_path")"

  if [ -f "${lpac_home}/VERSION.txt" ]; then
    version="$(version_token_from_text "$(cat "${lpac_home}/VERSION.txt")")"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  if version="$(lpac_command_version "$lpac_path")"; then
    printf '%s\n' "$version"
    return 0
  fi

  if [ -f "${lpac_home}/SOURCE.txt" ]; then
    version="$(version_token_from_text "$(cat "${lpac_home}/SOURCE.txt")")"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  return 1
}

lpac_release_version_from_url() {
  url="$1"
  tag="$(printf '%s\n' "$url" | sed -nE 's#^.*/releases/download/([^/]+)/.*#\1#p' | head -n 1)"
  case "$tag" in
    ""|latest)
      return 1
      ;;
  esac

  version="$(version_token_from_text "$tag")"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

lpac_asset_name_from_url() {
  url="$1"
  asset_name="${url%%\?*}"
  asset_name="${asset_name##*/}"
  printf '%s\n' "$asset_name"
}

lpac_url_source() {
  url="$1"
  case "$url" in
    "$LPAC_COMPAT_RELEASE_BASE_URL"/*|https://github.com/"$REPO"/releases/download/lpac/*)
      printf '%s\n' "compat"
      ;;
    "$LPAC_RELEASE_BASE_URL"/*|https://github.com/"$LPAC_REPO"/releases/latest/download/*|https://github.com/"$LPAC_REPO"/releases/download/*)
      printf '%s\n' "official"
      ;;
    *)
      printf '%s\n' "custom"
      ;;
  esac
}

compat_lpac_release_version() {
  lpac_url="$1"
  manifest_url="${LPAC_COMPAT_RELEASE_BASE_URL}/${LPAC_COMPAT_MANIFEST_NAME}"
  manifest="$(read_with_proxies "$manifest_url" 2>/dev/null || true)"
  [ -n "$manifest" ] || return 1

  asset_name="$(lpac_asset_name_from_url "$lpac_url")"
  if [ -n "$asset_name" ]; then
    asset_record="$(printf '%s\n' "$manifest" \
      | tr '\n' ' ' \
      | sed 's/}[[:space:]]*,[[:space:]]*{/}\
{/g' \
      | grep "\"name\"[[:space:]]*:[[:space:]]*\"${asset_name}\"" \
      | head -n 1 || true)"
    version="$(printf '%s\n' "$asset_record" | json_string_field version)"
    version="$(version_token_from_text "$version")"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  version="$(printf '%s\n' "$manifest" | json_string_field version)"
  version="$(version_token_from_text "$version")"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

official_lpac_release_version() {
  lpac_url="$1"

  version="$(lpac_release_version_from_url "$lpac_url" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  json="$(read_with_proxies "$LPAC_LATEST_RELEASE_API_URL" 2>/dev/null || true)"
  tag="$(printf '%s\n' "$json" | json_string_field tag_name)"
  version="$(version_token_from_text "$tag")"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  html="$(read_with_proxies "$LPAC_LATEST_RELEASE_URL" 2>/dev/null || true)"
  tag="$(printf '%s\n' "$html" \
    | sed -nE 's#.*releases/(tag|expanded_assets)/([vV]?[0-9]+(\.[0-9]+)+[^"<>/?[:space:]]*).*#\2#p' \
    | head -n 1)"
  version="$(version_token_from_text "$tag")"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
    return 0
  fi

  return 1
}

resolve_lpac_target_version() {
  lpac_url="$1"

  if [ -n "$LPAC_TARGET_VERSION" ]; then
    version="$(version_token_from_text "$LPAC_TARGET_VERSION")"
    [ -n "$version" ] || return 1
    LPAC_TARGET_RELEASE_SOURCE="override"
    printf '%s\n' "$version"
    return 0
  fi

  LPAC_TARGET_RELEASE_SOURCE="$(lpac_url_source "$lpac_url")"
  case "$LPAC_TARGET_RELEASE_SOURCE" in
    compat)
      compat_lpac_release_version "$lpac_url"
      ;;
    official)
      official_lpac_release_version "$lpac_url"
      ;;
    *)
      for candidate in "$lpac_url" "$LPAC_ASSET_URL" "$LPAC_RELEASE_BASE_URL"; do
        version="$(lpac_release_version_from_url "$candidate" || true)"
        if [ -n "$version" ]; then
          printf '%s\n' "$version"
          return 0
        fi
      done

      LPAC_TARGET_RELEASE_SOURCE="official"
      official_lpac_release_version "$LPAC_RELEASE_BASE_URL"
      ;;
  esac
}

find_current_lpac_path() {
  private_path="${INSTALL_DIR}/lpac/lpac"
  if [ -e "$private_path" ] || [ -d "${INSTALL_DIR}/lpac" ]; then
    printf '%s\n' "$private_path"
    return 0
  fi

  if command_path="$(command -v lpac 2>/dev/null)"; then
    printf '%s\n' "$command_path"
    return 0
  fi

  return 1
}

write_lpac_version_file() {
  lpac_home="$1"
  version="$2"
  [ -n "$version" ] || return 0
  printf '%s\n' "$version" > "${lpac_home}/VERSION.txt"
  chmod 0644 "${lpac_home}/VERSION.txt" || true
}

lpac_install_needed() {
  lpac_path="$1"
  lpac_url="$2"
  LPAC_INSTALL_REASON=""
  LPAC_TARGET_RELEASE_VERSION=""
  LPAC_TARGET_RELEASE_SOURCE=""

  if [ -z "$lpac_path" ] || [ ! -x "$lpac_path" ]; then
    LPAC_INSTALL_REASON="not installed"
    return 0
  fi

  if ! lpac_binary_path_usable "$lpac_path"; then
    LPAC_INSTALL_REASON="installed lpac is not usable"
    return 0
  fi

  current_version="$(lpac_installed_version "$lpac_path" || true)"
  if [ -z "$current_version" ]; then
    LPAC_INSTALL_REASON="installed version is unknown"
    return 0
  fi

  LPAC_TARGET_RELEASE_VERSION="$(resolve_lpac_target_version "$lpac_url" || true)"
  if [ -z "$LPAC_TARGET_RELEASE_VERSION" ]; then
    LPAC_INSTALL_REASON="latest version could not be verified"
    return 0
  fi

  if version_lt "$current_version" "$LPAC_TARGET_RELEASE_VERSION"; then
    LPAC_INSTALL_REASON="installed ${current_version}, ${LPAC_TARGET_RELEASE_SOURCE:-target} ${LPAC_TARGET_RELEASE_VERSION}"
    return 0
  fi

  echo "==> skipping lpac install (installed ${current_version}, ${LPAC_TARGET_RELEASE_SOURCE:-target} ${LPAC_TARGET_RELEASE_VERSION})"
  return 1
}

install_lpac() {
  lpac_dst="${INSTALL_DIR}/lpac"
  lpac_archive="${tmp_dir}/lpac.zip"
  lpac_extract="${tmp_dir}/lpac-extract"

  if ! truthy "$SIMADMIN_INSTALL_LPAC"; then
    echo "==> skipping lpac install (SIMADMIN_INSTALL_LPAC=${SIMADMIN_INSTALL_LPAC})"
    return 0
  fi

  lpac_arch="$(detect_lpac_arch || true)"
  if [ -z "$lpac_arch" ]; then
    echo "warning: unsupported device arch for lpac: $(uname -m), skipping lpac install" >&2
    return 0
  fi

  lpac_url="$(resolve_lpac_asset_url || true)"
  if [ -z "$lpac_url" ]; then
    echo "warning: failed to resolve lpac asset, skipping lpac install" >&2
    return 0
  fi

  current_lpac_path="$(find_current_lpac_path || true)"
  if ! lpac_install_needed "$current_lpac_path" "$lpac_url"; then
    return 0
  fi

  if [ -z "$LPAC_TARGET_RELEASE_VERSION" ]; then
    LPAC_TARGET_RELEASE_VERSION="$(resolve_lpac_target_version "$lpac_url" || true)"
  fi

  echo "==> installing lpac for ${lpac_arch} (${LPAC_INSTALL_REASON})"
  if ! download_with_proxies "$lpac_url" "$lpac_archive"; then
    echo "warning: failed to download lpac, keeping existing lpac if present" >&2
    return 0
  fi

  if ! extract_lpac_archive "$lpac_archive" "$lpac_extract"; then
    echo "warning: failed to extract lpac, keeping existing lpac if present" >&2
    return 0
  fi

  if copy_lpac_tree "$lpac_extract" "$lpac_dst" "$lpac_url"; then
    detected_version="$(lpac_command_version "${lpac_dst}/lpac" || true)"
    if [ -z "$detected_version" ]; then
      detected_version="$LPAC_TARGET_RELEASE_VERSION"
    fi
    write_lpac_version_file "$lpac_dst" "$detected_version"
    if lpac_binary_usable "$lpac_dst"; then
      if [ -n "$detected_version" ]; then
        echo "==> lpac ${detected_version} installed to ${lpac_dst}"
      else
        echo "==> lpac installed to ${lpac_dst}"
      fi
    else
      echo "warning: lpac was installed but may not be executable on this device; check glibc/architecture compatibility" >&2
    fi
  else
    echo "warning: failed to install lpac, keeping existing lpac if present" >&2
  fi
}



main() {
  require_root
  require_cmd curl
  require_cmd systemctl
  require_cmd mktemp

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT INT TERM

  asset_url="$(resolve_asset_url)"

  case "$asset_url" in
    *.tar.gz)
      require_cmd tar
      archive_path="${tmp_dir}/simadmin.tar.gz"
      ;;
    *)
      echo "error: unsupported OTA asset format, expected .tar.gz: $asset_url" >&2
      exit 1
      ;;
  esac

  download_release_asset "$archive_path" "$asset_url"

  echo "==> extracting package"
  mkdir -p "${tmp_dir}/pkg"
  tar -xzf "$archive_path" -C "${tmp_dir}/pkg"

  if [ ! -f "${tmp_dir}/pkg/simadmin" ]; then
    echo "error: invalid package, missing simadmin binary" >&2
    exit 1
  fi

  if [ ! -d "${tmp_dir}/pkg/www" ]; then
    echo "error: invalid package, missing frontend www directory" >&2
    exit 1
  fi

  echo "==> stopping existing service"
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

  echo "==> installing files to ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  install -m 0755 "${tmp_dir}/pkg/simadmin" "${INSTALL_DIR}/simadmin"
  rm -rf "${INSTALL_DIR}/www"
  cp -R "${tmp_dir}/pkg/www" "${INSTALL_DIR}/www"
  chmod -R a+rX "${INSTALL_DIR}/www"

  if [ -f "${tmp_dir}/pkg/meta.json" ]; then
    install -m 0644 "${tmp_dir}/pkg/meta.json" "${INSTALL_DIR}/meta.json"
  fi

  install_lpac

  echo "==> installing systemd unit"
  install_service_file
  echo "==> installing modem recovery service"
  install_modem_recovery_service

  configure_networkmanager_modem_unmanaged
  prepare_modem_environment

  echo "==> starting service"
  systemctl restart "${SERVICE_NAME}.service"

  echo "==> done"
  echo "    service: ${SERVICE_NAME}.service"
  echo "    modem recovery: simadmin-modem-recovery.service"
  echo "    install dir: ${INSTALL_DIR}"
  systemctl status "${SERVICE_NAME}.service" --no-pager
}

main "$@"
