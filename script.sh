#!/usr/bin/env bash
# ==============================================================================
#  Cluckers Central — Linux Setup Script
#
#  Installs Wine, all required Windows libraries, the Cluckers Central
#  launcher, and the game itself. Configures Steam integration and a
#  gateway proxy so login works correctly on Linux.
#
#  CREDITS
#    Linux login fix (gateway proxy)  — oldtunasalad (Discord)
#
#  USAGE
#    chmod +x cluckers-setup.sh       # make the script runnable (first time)
#    ./cluckers-setup.sh              # standard interactive install
#    ./cluckers-setup.sh -a           # auto mode  (skips Gamescope question)
#    ./cluckers-setup.sh -v           # verbose    (shows all Wine output)
#    ./cluckers-setup.sh -g           # no Gamescope (mouse won't be grabbed)
#    ./cluckers-setup.sh -u           # uninstall everything
#
#  PINNING A GAME VERSION
#    GAME_VERSION=0.36.9999.0 ./cluckers-setup.sh
#
# ==============================================================================

# Exit immediately if any command fails, if an undefined variable is used, or
# if any command in a pipe fails. This prevents the script from silently
# continuing after an error and leaving things in a broken state.
set -euo pipefail

# ==============================================================================
#  User configuration
#
#  GAME_VERSION controls which build is downloaded from the update server.
#  Set it to a specific version string to pin a release, or "auto" to ask
#  the server for the latest version at install time. You can also override
#  it without editing this file:
#    GAME_VERSION=0.36.9999.0 ./cluckers-setup.sh
# ==============================================================================

GAME_VERSION="${GAME_VERSION:-0.36.2100.0}"

# ==============================================================================
#  Constants
#
#  All paths and fixed values are declared here with `readonly` so they
#  cannot be overwritten by mistake later in the script.
# ==============================================================================

# Wine prefix — an isolated folder that acts as a self-contained fake Windows
# installation just for this game. It lives at ~/.wine-cluckers and is
# completely separate from any other Wine games or applications on your system.
# Uninstalling is as simple as deleting this one folder.
readonly WINEPREFIX="${HOME}/.wine-cluckers"

# URL and local path for the Cluckers Central Windows installer.
readonly INSTALLER_URL="https://updater.realmhub.io/cluckers-central_1.1.68_x64-setup.exe"
readonly INSTALLER_PATH="/tmp/cluckers-central-setup.exe"

# The launcher script this setup creates. It starts the gateway proxy, then
# launches Wine inside Gamescope. You can run it directly or via Steam.
readonly LAUNCHER_SCRIPT="${HOME}/.local/bin/cluckers-central.sh"

# The .desktop file makes the game appear in your application menu and
# allows Steam to show it with proper cover art.
readonly DESKTOP_FILE="${HOME}/.local/share/applications/cluckers-central.desktop"
readonly ICON_DIR="${HOME}/.local/share/icons"
readonly ICON_PATH="${ICON_DIR}/cluckers-central.png"

readonly APP_NAME="Cluckers Central"
readonly REALM_ROYALE_APPID="813820"  # Official Steam AppID for Realm Royale.

# Gateway proxy — a small Python program that runs in the background during
# each play session. It listens on port 18080 and relays the launcher's
# login requests to the game's authentication server. See Step 9 for details.
# Credit: login fix discovered and documented by oldtunasalad (Discord).
readonly PROXY_INSTALL_DIR="${HOME}/.local/share/cluckers-central"
readonly PROXY_SCRIPT="${PROXY_INSTALL_DIR}/gateway_proxy.py"
readonly PROXY_PID_FILE="/tmp/cluckers_proxy.pid"
readonly PROXY_LOG_FILE="/tmp/cluckers_proxy.log"

# ==============================================================================
#  Gamescope default options
#
#  Gamescope is a Valve-made compositor that runs the game in its own isolated
#  window session. On COSMIC and other Wayland desktops it keeps the mouse
#  locked inside the game so it can't escape to your desktop while you play.
#
#  These flags are baked into the launcher script at setup time. Do NOT add
#  "--" at the end — the launcher appends it automatically before "wine".
#
#  Common adjustments:
#    -W 2560 -H 1440  change to your monitor's native resolution
#    -r 144           change to your monitor's refresh rate in Hz
#    remove --adaptive-sync if your monitor doesn't support FreeSync/G-Sync
# ==============================================================================

readonly DEFAULT_GAMESCOPE_OPTS="gamescope -f --force-grab-cursor -W 1920 -H 1080 -r 240 --adaptive-sync --borderless"

# Point Wine at our isolated prefix and run in 64-bit Windows mode.
export WINEPREFIX
export WINEARCH="win64"

# ANSI colour codes used by the output helper functions below.
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'  # Resets the terminal colour back to normal.

# ==============================================================================
#  Output helpers
# ==============================================================================

# Prints a bold step header to mark the start of a major install phase.
#
# Arguments:
#   $1 - Step description to display.
step_msg() {
  printf "\n${BLUE}%s${NC}\n${BLUE}[STEP]${NC} ${GREEN}%s${NC}\n" \
    "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$1"
}

# Prints an informational message.
#
# Arguments:
#   $1 - Message to display.
info_msg() { printf "  ${CYAN}[INFO]${NC}  %s\n" "$1"; }

# Prints a success message.
#
# Arguments:
#   $1 - Message to display.
ok_msg() { printf "  ${GREEN}[ OK ]${NC}  %s\n" "$1"; }

# Prints a non-fatal warning message.
#
# Arguments:
#   $1 - Warning message to display.
warn_msg() { printf "  ${YELLOW}[WARN]${NC}  %s\n" "$1"; }

# Prints an error message to stderr and exits the script immediately.
#
# Arguments:
#   $1 - Error message to display.
error_exit() {
  printf "\n${RED}[ERROR]${NC} %s\n\n" "$1" >&2
  exit 1
}

# Returns 0 if the named command exists in PATH, 1 otherwise.
#
# Arguments:
#   $1 - Command name to test.
command_exists() { command -v "$1" > /dev/null 2>&1; }

# ==============================================================================
#  Dependency helpers
# ==============================================================================

# Installs a Windows library into the Wine prefix using winetricks.
#
# Checks the winetricks log before doing anything — if the package is already
# recorded as installed the function returns immediately. This makes re-running
# setup safe: nothing is reinstalled unnecessarily.
#
# Globals:
#   WINEPREFIX
# Arguments:
#   $1 - winetricks package identifier (e.g. "vcrun2019").
#   $2 - Human-readable description shown in progress output.
install_winetricks_pkg() {
  local -r pkg="$1"
  local -r desc="$2"
  local -r log="${WINEPREFIX}/winetricks.log"

  if [[ -f "${log}" ]] && grep -qw "${pkg}" "${log}" 2>/dev/null; then
    ok_msg "${desc} already installed — skipping."
    return 0
  fi

  info_msg "Installing ${desc}..."
  if winetricks -q "${pkg}"; then
    ok_msg "${desc} installed."
  else
    warn_msg "${pkg} install failed — continuing anyway."
  fi
}

# Installs any system tools that are missing using the distro's package manager.
#
# Checks for wine, winetricks, curl, wget, python3, and unzip. Installs only
# what is absent. Supports apt (Debian/Ubuntu), pacman (Arch), dnf (Fedora),
# and zypper (openSUSE).
#
# Arguments:
#   $1 - Package manager name: "apt", "pacman", "dnf", or "zypper".
install_sys_deps() {
  local -r pkg_mgr="$1"
  local to_install=()

  for tool in wine winetricks curl wget python3 unzip; do
    command_exists "${tool}" || to_install+=("${tool}")
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    ok_msg "All required system tools are already installed."
    return 0
  fi

  info_msg "Missing tools: ${to_install[*]}. Installing..."
  case "${pkg_mgr}" in
    apt)
      # i386 (32-bit) architecture is required by the 32-bit Wine components.
      sudo dpkg --add-architecture i386
      sudo apt-get update -qq
      sudo apt-get install -y \
        "${to_install[@]}" python3-pip wine32 wine64 libwine fonts-wine
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        "${to_install[@]}" python-pip wine-mono wine-gecko
      ;;
    dnf)    sudo dnf install -y "${to_install[@]}" python3-pip ;;
    zypper) sudo zypper install -y "${to_install[@]}" python3-pip ;;
  esac
}

# Queries the update server for the latest game version string.
#
# Tries several plausible API endpoints in sequence. Prints the version string
# (e.g. "0.36.2100.0") to stdout if found, or an empty string if none of the
# endpoints return a recognisable response.
#
# Outputs:
#   Writes the version string (or empty string) to stdout.
detect_latest_game_version() {
  local detected=""
  info_msg "Querying update server for the latest game version..."

  local endpoint
  for endpoint in \
    "https://updater.realmhub.io/version.json" \
    "https://updater.realmhub.io/api/latest" \
    "https://updater.realmhub.io/api/game/version" \
    "https://gateway-dev.project-crown.com/api/v1/game/version"; do

    detected=$(
      curl -sf --max-time 5 "${endpoint}" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for key in ('version', 'gameVersion', 'game_version', 'latestVersion'):
        if key in data and data[key]:
            print(data[key])
            break
except Exception:
    pass
" 2>/dev/null || true
    )

    if [[ "${detected}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "${detected}"
      return 0
    fi
  done

  printf ''
}

# ==============================================================================
#  Uninstall
# ==============================================================================

# Removes every file and configuration entry created by this script.
#
# Stops the proxy if running, deletes the Wine prefix, launcher script, desktop
# shortcut, icon, and proxy program, then cleans up Steam configuration.
#
# Globals:
#   WINEPREFIX, PROXY_PID_FILE, LAUNCHER_SCRIPT, DESKTOP_FILE,
#   ICON_PATH, PROXY_SCRIPT, REALM_ROYALE_APPID, APP_NAME
run_uninstall() {
  step_msg "Uninstalling Cluckers Central..."

  # Stop the proxy if it is currently running.
  local old_pid=""
  old_pid=$(cat "${PROXY_PID_FILE}" 2>/dev/null || true)
  [[ -n "${old_pid}" ]] && kill "${old_pid}" 2>/dev/null || true
  rm -f "${PROXY_PID_FILE}"

  # Delete the Wine prefix — this removes the game, launcher, and all Windows
  # libraries in one go since they all live inside this single folder.
  if [[ -d "${WINEPREFIX}" && -n "${WINEPREFIX}" ]]; then
    info_msg "Removing Wine prefix at ${WINEPREFIX}..."
    rm -rf "${WINEPREFIX}"
    ok_msg "Wine prefix removed."
  fi

  [[ -f "${LAUNCHER_SCRIPT}" ]] \
    && rm -f "${LAUNCHER_SCRIPT}" && ok_msg "Launcher script removed."
  [[ -f "${DESKTOP_FILE}" ]] \
    && rm -f "${DESKTOP_FILE}" && ok_msg "Desktop shortcut removed."
  [[ -f "${ICON_PATH}" ]] \
    && rm -f "${ICON_PATH}" && ok_msg "Icon removed."
  [[ -f "${PROXY_SCRIPT}" ]] \
    && rm -f "${PROXY_SCRIPT}" && ok_msg "Gateway proxy removed."

  # Locate the Steam installation so we can clean up our config entries.
  info_msg "Looking for Steam to clean up shortcuts..."
  local steam_root=""
  local candidate
  for candidate in \
    "${HOME}/.steam/steam" \
    "${HOME}/.local/share/Steam" \
    "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -d "${candidate}" ]]; then
      steam_root="${candidate}"
      break
    fi
  done

  if [[ -z "${steam_root}" ]] || ! command_exists python3; then
    warn_msg "Steam not found or Python unavailable — skipping Steam cleanup."
    printf "\n${GREEN}Uninstall complete.${NC}\n\n"
    return 0
  fi

  local userdata_dir="${steam_root}/userdata"
  local steam_user=""
  local ts name
  if [[ -d "${userdata_dir}" ]]; then
    # Find the most recently active account by sorting on directory mtime.
    while IFS=' ' read -r ts name; do
      steam_user="${name}"
      break
    done < <(
      find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d \
        -printf '%T@ %f\n' 2>/dev/null | sort -rn
    )
  fi

  if [[ -z "${steam_user}" ]]; then
    warn_msg "No Steam user account found — skipping Steam cleanup."
    printf "\n${GREEN}Uninstall complete.${NC}\n\n"
    return 0
  fi

  info_msg "Cleaning Steam config for user ${steam_user}..."
  local -r user_config_dir="${userdata_dir}/${steam_user}/config"

  STEAM_ROOT="${steam_root}" \
  USER_CONFIG_DIR="${user_config_dir}" \
  LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
  REALM_APPID="${REALM_ROYALE_APPID}" \
  APP_NAME_ENV="${APP_NAME}" \
  python3 - << 'PYEOF'
"""Removes Cluckers Central entries from Steam's configuration files."""

import binascii
import os
import shutil

import vdf

USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER = os.environ["LAUNCHER_ENV"]
REALM_APPID = os.environ["REALM_APPID"]
STEAM_ROOT = os.environ["STEAM_ROOT"]
APP_NAME = os.environ["APP_NAME_ENV"]

_OK = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam shortcut ID for a non-Steam game.

    Steam identifies non-Steam shortcuts by a CRC32 hash of the executable
    path and app name combined. We reproduce this calculation so we can find
    and remove exactly the right entry.

    Args:
        exe: Absolute path to the executable.
        name: Display name of the shortcut.

    Returns:
        Unsigned 32-bit integer shortcut ID.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
grid_appid = str(unsigned_id)
# shortcuts.vdf stores a signed 32-bit int; values above 2^31 wrap negative.
shortcut_appid = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)

# -- shortcuts.vdf: remove the non-Steam game entry -------------------------
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
        sc = shortcuts.get("shortcuts", {})
        keys_to_delete = [
            k for k, v in sc.items()
            if isinstance(v, dict)
            and LAUNCHER in v.get("Exe", v.get("exe", ""))
        ]
        for k in keys_to_delete:
            del sc[k]
        with open(shortcuts_path, "wb") as fh:
            vdf.binary_dump(shortcuts, fh)
        print(f"{_OK} Removed shortcut from Steam.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean shortcuts.vdf: {exc}")

# -- localconfig.vdf: remove Gamescope launch options ----------------------
localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(localconfig_path, "r", encoding="utf-8",
                  errors="replace") as fh:
            lc = vdf.load(fh)
        apps = (
            lc.get("UserLocalConfigStore", {})
            .get("Software", {})
            .get("Valve", {})
            .get("Steam", {})
            .get("apps", {})
        )
        if REALM_APPID in apps and "LaunchOptions" in apps[REALM_APPID]:
            del apps[REALM_APPID]["LaunchOptions"]
            with open(localconfig_path, "w", encoding="utf-8") as fh:
                vdf.dump(lc, fh, pretty=True)
            print(f"{_OK} Removed Realm Royale launch options.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean localconfig.vdf: {exc}")

# -- config.vdf: remove Proton compatibility assignments --------------------
config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8", errors="replace") as fh:
            cfg = vdf.load(fh)
        mapping = (
            cfg.get("InstallConfigStore", {})
            .get("Software", {})
            .get("Valve", {})
            .get("Steam", {})
            .get("CompatToolMapping", {})
        )
        if str(shortcut_appid) in mapping:
            del mapping[str(shortcut_appid)]
        if REALM_APPID in mapping:
            del mapping[REALM_APPID]
        with open(config_path, "w", encoding="utf-8") as fh:
            vdf.dump(cfg, fh, pretty=True)
        print(f"{_OK} Removed Proton compatibility settings.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean config.vdf: {exc}")

# -- grid/: remove custom library artwork -----------------------------------
grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
for suffix in [
    "p.jpg", "p.png", ".jpg", ".png",
    "_hero.jpg", "_hero.png", "_logo.png",
]:
    artwork = os.path.join(grid_dir, f"{grid_appid}{suffix}")
    if os.path.exists(artwork):
        os.remove(artwork)
print(f"{_OK} Removed custom Steam artwork.")
PYEOF

  printf "\n${GREEN}Uninstall complete.${NC}\n\n"
}

# ==============================================================================
#  Main install
# ==============================================================================

# Entry point. Parses flags, then runs all install steps in sequence.
#
# Arguments:
#   "$@" - Command-line flags passed to the script.
main() {
  local verbose="false"
  local auto_mode="false"
  local no_gamescope="false"
  local final_gamescope_opts="${DEFAULT_GAMESCOPE_OPTS}"
  local resolved_version="${GAME_VERSION}"

  local arg
  for arg in "$@"; do
    case "${arg}" in
      --uninstall|-u)    run_uninstall; exit 0 ;;
      --verbose|-v)      verbose="true" ;;
      --auto|-a)         auto_mode="true" ;;
      --no-gamescope|-g) no_gamescope="true" ;;
    esac
  done

  # -v shows full Wine debug output; the default suppresses it to keep the
  # terminal readable during install.
  if [[ "${verbose}" == "true" ]]; then
    export WINEDEBUG=""
  else
    export WINEDEBUG="-all"
  fi

  printf "\n"
  printf "${GREEN}╔══════════════════════════════════════════════════════╗${NC}\n"
  printf "${GREEN}║        Cluckers Central — Linux Setup Script         ║${NC}\n"
  printf "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n\n"

  # ----------------------------------------------------------------------------
  # Step 1 — System dependencies
  #
  # Checks for and installs: wine, winetricks, curl, wget, python3, unzip.
  # Also installs two Python libraries used by this script:
  #   vdf      — reads and writes Valve's binary config file format; Steam uses
  #              it for shortcuts.vdf, localconfig.vdf, and config.vdf.
  #   requests — lets the gateway proxy make outbound HTTP requests.
  # ----------------------------------------------------------------------------
  step_msg "Checking system tools..."

  local pkg_mgr=""
  if   command_exists apt;    then pkg_mgr="apt"
  elif command_exists pacman; then pkg_mgr="pacman"
  elif command_exists dnf;    then pkg_mgr="dnf"
  elif command_exists zypper; then pkg_mgr="zypper"
  else
    error_exit "No supported package manager found (apt/pacman/dnf/zypper)."
  fi

  install_sys_deps "${pkg_mgr}"

  if ! python3 -c "import vdf" > /dev/null 2>&1; then
    info_msg "Installing Python 'vdf' library (reads/writes Steam config files)..."
    python3 -m pip install --quiet --break-system-packages vdf 2>/dev/null \
      || python3 -m pip install --quiet --user vdf \
      || error_exit "Could not install the Python 'vdf' library."
  fi

  if ! python3 -c "import requests" > /dev/null 2>&1; then
    info_msg "Installing Python 'requests' (used by the gateway proxy)..."
    python3 -m pip install --quiet --break-system-packages requests 2>/dev/null \
      || python3 -m pip install --quiet --user requests \
      || warn_msg "Could not install 'requests'. The gateway proxy may fail."
  fi

  # ----------------------------------------------------------------------------
  # Step 2 — Resolve game version
  # ----------------------------------------------------------------------------
  step_msg "Resolving game version..."

  if [[ "${resolved_version}" == "auto" ]]; then
    local auto_ver
    auto_ver=$(detect_latest_game_version)
    if [[ -n "${auto_ver}" ]]; then
      resolved_version="${auto_ver}"
      ok_msg "Server reports latest version: ${resolved_version}"
    else
      warn_msg "Version auto-detection failed. Falling back to: 0.36.2100.0"
      resolved_version="0.36.2100.0"
    fi
  else
    ok_msg "Using configured game version: ${resolved_version}"
  fi

  # ----------------------------------------------------------------------------
  # Step 3 — Gamescope configuration
  #
  # Lets the user customise the Gamescope flags before they are baked into the
  # launcher script. Skipped in auto mode (-a).
  #
  # Gamescope is a Valve tool that runs the game in its own window session. On
  # COSMIC and Wayland desktops it locks the mouse inside the game so it can't
  # escape to your desktop while you're playing.
  # ----------------------------------------------------------------------------
  if [[ "${auto_mode}" == "false" ]]; then
    step_msg "Configure Gamescope options"
    printf "  Gamescope keeps your mouse locked inside the game window.\n"
    printf "  This is required on COSMIC and other Wayland desktops.\n\n"
    printf "  ${YELLOW}Flag reference:${NC}\n"
    printf "    ${CYAN}-f${NC}                  Fullscreen.\n"
    printf "    ${CYAN}--force-grab-cursor${NC} Lock the mouse inside the window"
    printf " (essential on COSMIC).\n"
    printf "    ${CYAN}-W 1920 -H 1080${NC}     Output resolution — match your"
    printf " monitor.\n"
    printf "    ${CYAN}-r 240${NC}              Frame rate cap — match your"
    printf " monitor's Hz.\n"
    printf "    ${CYAN}--adaptive-sync${NC}     FreeSync / G-Sync support.\n"
    printf "    ${CYAN}--borderless${NC}        Borderless window.\n\n"
    printf "  ${YELLOW}Note:${NC} Do not add '--' at the end;"
    printf " the launcher appends it automatically.\n\n"
    printf "  ${GREEN}Current default:${NC}\n  %s\n\n" "${final_gamescope_opts}"

    local user_opts=""
    read -rp "  Press Enter to keep default, or type replacement flags: " \
      user_opts
    if [[ -n "${user_opts}" ]]; then
      # Strip any trailing " --" the user may have included by habit.
      user_opts="${user_opts%% --*}"
      final_gamescope_opts="${user_opts}"
      ok_msg "Custom Gamescope options saved."
    else
      ok_msg "Keeping default Gamescope options."
    fi
  fi

  # ----------------------------------------------------------------------------
  # Step 4 — Create the Wine prefix
  #
  # A Wine prefix is an isolated folder that acts as a complete fake Windows
  # installation. Every Windows program we install goes inside it. It lives at
  # ~/.wine-cluckers and has no effect on any other Wine installation or prefix
  # on your system.
  # ----------------------------------------------------------------------------
  step_msg "Creating the Wine environment..."

  if [[ -f "${WINEPREFIX}/system.reg" ]]; then
    ok_msg "Wine environment already exists — skipping."
  else
    info_msg "Setting up a fresh Wine environment (~30 seconds)..."
    wineboot --init || true
    ok_msg "Wine environment ready."
  fi

  # ----------------------------------------------------------------------------
  # Step 5 — Install WebView2
  #
  # WebView2 is Microsoft's embedded browser engine. Cluckers Central uses it
  # to draw its entire user interface — without it, the launcher opens but the
  # window is completely blank.
  #
  # The WebView2 installer requires Windows 8.1 compatibility mode inside Wine.
  # We switch to 8.1, install, then switch back to Windows 10 for everything
  # else.
  # ----------------------------------------------------------------------------
  step_msg "Installing WebView2 (the launcher's UI engine)..."

  local webview_exe=""
  local f
  while IFS= read -r -d '' f; do
    webview_exe="${f}"
    break
  done < <(
    find "${WINEPREFIX}/drive_c" -name "msedgewebview2.exe" -print0 2>/dev/null
  )

  if [[ -n "${webview_exe}" ]]; then
    ok_msg "WebView2 is already installed."
  else
    local -r wv2_installer="/tmp/MicrosoftEdgeWebview2Setup.exe"
    if [[ ! -f "${wv2_installer}" ]]; then
      info_msg "Downloading WebView2 installer from Microsoft..."
      curl -fLS --progress-bar \
        -o "${wv2_installer}" \
        "https://go.microsoft.com/fwlink/p/?LinkId=2124703" \
        || warn_msg "WebView2 download failed. The launcher UI may be blank."
    fi

    if [[ -f "${wv2_installer}" ]]; then
      info_msg "Switching Wine to Windows 8.1 mode for the WebView2 installer..."
      winetricks -q win81

      info_msg "Installing WebView2..."
      if [[ "${verbose}" == "true" ]]; then
        wine "${wv2_installer}" /silent /install \
          2>&1 | tee "${WINEPREFIX}/webview2_install.log" \
          || warn_msg "WebView2 installer reported an error — may still work."
      else
        wine "${wv2_installer}" /silent /install > /dev/null 2>&1 \
          || warn_msg "WebView2 installer reported an error — may still work."
      fi

      info_msg "Restoring Wine to Windows 10 mode..."
      winetricks -q win10
      # Wait for any background Wine processes the installer spawned to exit.
      wineserver -w || true
    fi
  fi

  # ----------------------------------------------------------------------------
  # Step 6 — Windows runtime libraries
  #
  # The game needs several Windows DLLs that Wine does not ship by default.
  # Winetricks downloads and installs them into the Wine prefix:
  #
  #   Visual C++ runtimes  — required by nearly all modern Windows games.
  #   DirectX 9            — the graphics API the game uses.
  #   DXVK                 — translates DirectX 9/10/11 calls to Vulkan.
  #                          This gives much better performance than Wine's
  #                          built-in software renderer.
  # ----------------------------------------------------------------------------
  step_msg "Installing required Windows runtime libraries..."

  install_winetricks_pkg "vcrun2010" "Visual C++ 2010 runtime"
  install_winetricks_pkg "vcrun2012" "Visual C++ 2012 runtime"
  install_winetricks_pkg "vcrun2019" "Visual C++ 2019 runtime"
  install_winetricks_pkg "d3dx9"     "DirectX 9"

  local -r dxvk_dll="${WINEPREFIX}/drive_c/windows/system32/dxgi.dll"
  if [[ -f "${dxvk_dll}" ]]; then
    ok_msg "DXVK already installed."
  else
    info_msg "Installing DXVK (DirectX-to-Vulkan translation layer)..."
    winetricks -q dxvk \
      || warn_msg "DXVK install failed. Game will still run, but may be slower."
  fi

  # ----------------------------------------------------------------------------
  # Step 7 — Install Cluckers Central launcher
  #
  # Downloads and silently runs the official Windows installer inside Wine.
  # Afterwards we query the Wine registry to find exactly where
  # cluckers-central.exe landed, then use `wine winepath` to convert that
  # Windows path (e.g. C:\Program Files\...) to a real Linux filesystem path.
  # If the registry lookup fails we fall back to a disk search.
  # ----------------------------------------------------------------------------
  step_msg "Installing Cluckers Central launcher..."

  if [[ ! -f "${INSTALLER_PATH}" ]]; then
    info_msg "Downloading launcher installer..."
    curl -fLS --progress-bar -o "${INSTALLER_PATH}" "${INSTALLER_URL}" \
      || error_exit "Launcher download failed. Check your internet connection."
  fi

  info_msg "Running installer silently (may take a minute or two)..."
  if [[ "${verbose}" == "true" ]]; then
    wine "${INSTALLER_PATH}" /S \
      2>&1 | tee "${WINEPREFIX}/cluckers_install.log" || true
  else
    wine "${INSTALLER_PATH}" /S > /dev/null 2>&1 || true
  fi

  info_msg "Waiting for installer background processes to finish..."
  wineserver -w || true
  sleep 3

  info_msg "Looking up installation path in the Wine registry..."
  local app_exe_linux=""
  local app_exe_wine=""

  # The installer may write its uninstall entry to any of these keys depending
  # on whether it installs machine-wide (HKLM) or per-user (HKCU).
  local -r keys_to_check=(
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
    "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
  )

  local key
  for key in "${keys_to_check[@]}"; do
    local reg_out=""
    reg_out=$(
      wine reg query "${key}" /v DisplayIcon 2>/dev/null \
        | grep -i 'REG_SZ' || true
    )
    if [[ -n "${reg_out}" ]]; then
      app_exe_wine=$(
        printf '%s' "${reg_out}" \
          | sed -E 's/.*REG_SZ[[:space:]]+//' | tr -d '\r'
      )
      app_exe_wine="${app_exe_wine%%,*}"   # strip icon index suffix (e.g. ,0)
      app_exe_wine="${app_exe_wine%\"*}"   # strip trailing quote
      app_exe_wine="${app_exe_wine#*\"}"   # strip leading quote
      if [[ -n "${app_exe_wine}" ]]; then
        info_msg "Found in registry: ${app_exe_wine}"
        break
      fi
    fi
  done

  if [[ -n "${app_exe_wine}" ]]; then
    # winepath -u converts a Windows-style path to a Linux filesystem path.
    app_exe_linux=$(
      wine winepath -u "${app_exe_wine}" 2>/dev/null | tr -d '\r' || true
    )
  fi

  if [[ -z "${app_exe_linux}" || ! -f "${app_exe_linux}" ]]; then
    warn_msg "Registry lookup failed. Searching disk for cluckers-central.exe..."
    local match
    while IFS= read -r -d '' match; do
      if [[ ! "${match}" =~ [Uu]ninstall ]]; then
        app_exe_linux="${match}"
        break
      fi
    done < <(
      find "${WINEPREFIX}/drive_c" -type f -iname "*cluckers*.exe" \
        -print0 2>/dev/null
    )
  fi

  [[ -n "${app_exe_linux}" && -f "${app_exe_linux}" ]] \
    || error_exit "Cannot find cluckers-central.exe. Check ${WINEPREFIX}."
  ok_msg "Launcher found: ${app_exe_linux}"

  local app_exe_dir
  app_exe_dir="$(dirname "${app_exe_linux}")"

  # ----------------------------------------------------------------------------
  # Step 8 — Download and install game files
  #
  # Downloads the game zip from the update server and extracts it to the path
  # the Cluckers Central launcher expects:
  #
  #   ~/.wine-cluckers/drive_c/users/<you>/Games/Cluckers/<version>/Realm-Royale/
  #
  # The extracted folder structure must be:
  #   Binaries/   — game executables
  #   Engine/     — Unreal Engine shared files
  #   RealmGame/  — game-specific assets and content
  #
  # `wget -c` resumes an interrupted download automatically, so you don't have
  # to start over if your connection drops on a large file.
  # ----------------------------------------------------------------------------
  step_msg "Downloading game files (v${resolved_version})..."

  local -r game_dir="${WINEPREFIX}/drive_c/users/${USER}/Games/Cluckers/${resolved_version}/Realm-Royale"
  local -r game_zip="/tmp/cluckers-game-${resolved_version}.zip"
  local -r game_extract_tmp="/tmp/cluckers-game-extract-${resolved_version}"
  local -r game_dl_url="https://updater.realmhub.io/builds/game-${resolved_version}.zip"

  if [[ -d "${game_dir}/Binaries" || -d "${game_dir}/RealmGame" ]]; then
    ok_msg "Game v${resolved_version} already installed at: ${game_dir}"
  else
    info_msg "Downloading: ${game_dl_url}"
    info_msg "(wget resumes automatically if the download is interrupted)"
    mkdir -p "${game_dir}"
    wget -c --show-progress -O "${game_zip}" "${game_dl_url}" \
      || error_exit "Game download failed. Check your connection and GAME_VERSION."

    info_msg "Extracting game files..."
    rm -rf "${game_extract_tmp}"
    mkdir -p "${game_extract_tmp}"
    unzip -q -o "${game_zip}" -d "${game_extract_tmp}"

    # Some archives wrap all content in a single top-level folder
    # (e.g. game-0.36.2100.0/Binaries/...). Descend into it if present.
    local extract_root="${game_extract_tmp}"
    local top_entries=()
    local entry
    while IFS= read -r -d '' entry; do
      top_entries+=("${entry}")
    done < <(
      find "${game_extract_tmp}" -maxdepth 1 -mindepth 1 -print0 2>/dev/null
    )

    if [[ ${#top_entries[@]} -eq 1 && -d "${top_entries[0]}" ]]; then
      local -r inner="${top_entries[0]}"
      if [[ -d "${inner}/Binaries" \
            || -d "${inner}/RealmGame" \
            || -d "${inner}/Engine" ]]; then
        extract_root="${inner}"
        info_msg "Zip has wrapper folder — descending into: $(basename "${inner}")"
      fi
    fi

    info_msg "Moving files into place..."
    cp -r "${extract_root}/." "${game_dir}/"
    rm -rf "${game_extract_tmp}"
    ok_msg "Game installed at: ${game_dir}"

    # Verify the expected top-level directories are present.
    local missing_dirs=()
    local dir
    for dir in Binaries Engine RealmGame; do
      [[ -d "${game_dir}/${dir}" ]] || missing_dirs+=("${dir}")
    done
    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
      warn_msg "Missing expected directories: ${missing_dirs[*]}"
      warn_msg "The zip layout may have changed. Check: ${game_dir}"
    fi
  fi

  # ----------------------------------------------------------------------------
  # Step 9 — Install gateway proxy
  #
  # Credit: login fix discovered and documented by oldtunasalad (Discord).
  #
  # WHY LOGIN FAILS ON LINUX WITHOUT THIS
  # When you click Play, Cluckers Central contacts gateway-dev.project-crown.com
  # to verify your account and receive a login token. On Linux this request
  # fails silently — the response never arrives and nothing happens when you
  # click Play. This is unrelated to Gamescope or graphics settings.
  #
  # THE FIX
  # A small Python proxy runs on your own machine at 127.0.0.1:18080. The
  # launcher sends its auth request there, the proxy forwards it to the real
  # server over a connection that works correctly on Linux, and returns the
  # response. The launcher never knows the difference.
  #
  # The proxy is told about by a .env file placed next to cluckers-central.exe:
  #   API_BASE_URL=http://127.0.0.1:18080
  #
  # The launcher script (Step 11) starts the proxy automatically before each
  # session and stops it when the game exits. To debug login issues check:
  #   ${PROXY_LOG_FILE}
  #
  # The proxy source is embedded directly in this script — it is never fetched
  # from the internet, so there is no risk of a third-party source being
  # modified or unavailable.
  # ----------------------------------------------------------------------------
  step_msg "Installing gateway proxy (required for login on Linux)..."
  mkdir -p "${PROXY_INSTALL_DIR}"

  cat > "${PROXY_SCRIPT}" << 'PROXYEOF'
#!/usr/bin/env python3
"""Cluckers Central gateway proxy.

Fixes login on Linux by relaying the Cluckers Central launcher's
authentication requests to the game's auth server.

The launcher is configured to talk to http://127.0.0.1:18080 via the .env
file placed next to cluckers-central.exe. This proxy receives those requests
and forwards them to https://gateway-dev.project-crown.com using a standard
HTTP connection that works correctly on Linux.

Credit: login fix discovered and documented by oldtunasalad (Discord).

This program is started and stopped automatically by the launcher script.
You do not normally need to run it yourself.

Manual use (for debugging):
    python3 gateway_proxy.py
    # Then launch the game normally in a separate terminal.
"""

import http.server
import json
import sys
from typing import Optional

try:
    import requests
    from requests import Session
except ImportError:
    print("ERROR: The 'requests' library is not installed.", file=sys.stderr)
    print("Fix:   pip install requests", file=sys.stderr)
    sys.exit(1)

# The real authentication server all requests are forwarded to.
_TARGET: str = "https://gateway-dev.project-crown.com"

# Port this proxy listens on. Must match API_BASE_URL in the .env file.
_PORT: int = 18080

# A persistent session reuses the underlying TCP connection across requests,
# which reduces latency for repeated auth calls during a session.
_SESSION: Session = requests.Session()

# Headers that are connection-specific and must not be forwarded to the
# upstream server. Defined by RFC 7230 §6.1.
_HOP_BY_HOP_REQUEST: frozenset = frozenset(
    {"host", "transfer-encoding", "connection"}
)
_HOP_BY_HOP_RESPONSE: frozenset = frozenset(
    {"transfer-encoding", "connection", "content-encoding", "content-length"}
)


class _GatewayProxyHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler that forwards requests to the game auth server."""

    def do_GET(self) -> None:  # noqa: N802 — name required by BaseHTTPRequestHandler
        """Forward an incoming GET request."""
        self._forward("GET")

    def do_POST(self) -> None:  # noqa: N802
        """Forward an incoming POST request."""
        self._forward("POST")

    def do_PUT(self) -> None:  # noqa: N802
        """Forward an incoming PUT request."""
        self._forward("PUT")

    def _forward(self, method: str) -> None:
        """Forward a request to _TARGET and relay the response.

        Strips hop-by-hop headers in both directions so the forwarded request
        is a clean, self-contained HTTP message.

        Args:
            method: HTTP method string, e.g. "GET" or "POST".
        """
        url: str = _TARGET + self.path
        content_length: int = int(self.headers.get("Content-Length", 0))
        body: Optional[bytes] = (
            self.rfile.read(content_length) if content_length > 0 else None
        )

        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in _HOP_BY_HOP_REQUEST
        }
        headers["Host"] = "gateway-dev.project-crown.com"

        try:
            resp = _SESSION.request(
                method, url, headers=headers, data=body, timeout=30
            )
            self.send_response(resp.status_code)
            for key, value in resp.headers.items():
                if key.lower() not in _HOP_BY_HOP_RESPONSE:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(resp.content)))
            self.end_headers()
            self.wfile.write(resp.content)

        except Exception as exc:  # pylint: disable=broad-except
            # Return a JSON-encoded error so the launcher receives a
            # well-formed response even when the upstream is unreachable.
            error_body: bytes = json.dumps({"error": str(exc)}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            self.wfile.write(error_body)

    def log_message(self, fmt: str, *args: object) -> None:
        """Suppress per-request log lines.

        The launcher script redirects this process's stdout to PROXY_LOG_FILE,
        so silencing the default access log keeps that file readable.

        Args:
            fmt: Unused format string.
            *args: Unused format arguments.
        """


if __name__ == "__main__":
    print(f"[proxy] Listening on  http://127.0.0.1:{_PORT}")
    print(f"[proxy] Forwarding to {_TARGET}")
    http.server.HTTPServer(
        ("127.0.0.1", _PORT), _GatewayProxyHandler
    ).serve_forever()
PROXYEOF

  chmod +x "${PROXY_SCRIPT}"
  ok_msg "Gateway proxy installed at: ${PROXY_SCRIPT}"

  # ----------------------------------------------------------------------------
  # Step 10 — Extract desktop icon
  #
  # Pulls the icon embedded inside cluckers-central.exe so it appears correctly
  # in Steam and the application menu. Requires icoutils (wrestool + icotool).
  # If not installed, setup continues and Wine's generic icon is used instead.
  # ----------------------------------------------------------------------------
  step_msg "Extracting desktop icon..."
  mkdir -p "${ICON_DIR}"
  local final_icon_path="wine"  # Fallback: use the generic Wine icon.

  if command_exists wrestool && command_exists icotool; then
    if wrestool -x --type=14 "${app_exe_linux}" \
        -o /tmp/cluckers.ico 2>/dev/null; then
      icotool -x -o "${ICON_DIR}" /tmp/cluckers.ico 2>/dev/null || true

      # Pick the largest extracted PNG — that is the highest-resolution variant.
      local best_icon=""
      local best_size=0
      local fsize file_iter
      while IFS= read -r -d '' file_iter; do
        fsize=$(stat -c '%s' "${file_iter}" 2>/dev/null || printf '0')
        if (( fsize > best_size )); then
          best_size="${fsize}"
          best_icon="${file_iter}"
        fi
      done < <(
        find "${ICON_DIR}" -maxdepth 1 -name 'cluckers*.png' -print0 2>/dev/null
      )

      if [[ -n "${best_icon}" ]]; then
        cp "${best_icon}" "${ICON_PATH}"
        final_icon_path="${ICON_PATH}"
        ok_msg "Icon extracted."
      fi
    fi
  else
    warn_msg "icoutils not installed — using the default Wine icon."
    warn_msg "To get a proper icon:  sudo apt install icoutils"
  fi

  # ----------------------------------------------------------------------------
  # Step 11 — Create the launcher script
  #
  # This is the script that actually runs every time you click Play. It:
  #
  #   1. Writes a .env file next to cluckers-central.exe telling the launcher
  #      to send its auth requests to the local proxy at 127.0.0.1:18080.
  #
  #   2. Starts the gateway proxy in the background and registers a bash EXIT
  #      trap so the proxy is stopped automatically when the game exits.
  #
  #   3. Launches Wine inside Gamescope:
  #        gamescope [flags] -- wine cluckers-central.exe
  #      Wine runs with no special hooks or interception. Gamescope provides
  #      the mouse grab at the compositor level, covering both the launcher
  #      window and the game window when it opens.
  #
  # The script is split into two heredoc sections:
  #   Part 1 (double-quoted) — paths decided at setup time are expanded now
  #           and written as plain strings into the generated file.
  #   Part 2 (single-quoted) — the launch logic is written literally; variable
  #           expansion happens at launch time when the script runs.
  # ----------------------------------------------------------------------------
  step_msg "Creating launcher script..."

  local real_wine_path=""
  real_wine_path=$(command -v wine) \
    || error_exit "Cannot find the wine binary. Is Wine installed?"
  ok_msg "Wine binary: ${real_wine_path}"

  mkdir -p "$(dirname "${LAUNCHER_SCRIPT}")"

  # Part 1 — setup-time values baked in as plain strings.
  cat > "${LAUNCHER_SCRIPT}" << EOF
#!/usr/bin/env bash
# Cluckers Central launcher — generated by cluckers-setup.sh
#
# To adjust Gamescope settings without re-running setup, edit GS_ARGS below.
# To see Wine debug output, remove the WINEDEBUG export line.

export WINEPREFIX="${WINEPREFIX}"
export WINEDEBUG="-all"  # Remove or empty this to show Wine debug output.

APP_EXE="${app_exe_linux}"         # Full Linux path to cluckers-central.exe.
APP_EXE_DIR="${app_exe_dir}"       # Folder containing cluckers-central.exe.
NO_GAMESCOPE="${no_gamescope}"     # "true" skips Gamescope (set via -g).
GS_ARGS="${final_gamescope_opts}"  # Gamescope flags — edit to change settings.
PROXY_SCRIPT="${PROXY_SCRIPT}"     # Path to gateway_proxy.py.
PROXY_PID="${PROXY_PID_FILE}"      # Stores the proxy's process ID between runs.
PROXY_LOG="${PROXY_LOG_FILE}"      # Proxy output — check here if login fails.
EOF

  # Part 2 — launch-time logic written as literal text.
  cat >> "${LAUNCHER_SCRIPT}" << 'LAUNCHEREOF'

# start_proxy — starts the gateway proxy in the background.
#
# The proxy must be running before Wine starts. It listens on 127.0.0.1:18080
# and relays the launcher's login requests to gateway-dev.project-crown.com.
# Without it the authentication request never completes and clicking Play does
# nothing. Credit: fix by oldtunasalad (Discord).
#
# Globals:
#   PROXY_PID, PROXY_SCRIPT, PROXY_LOG
start_proxy() {
  # Kill any leftover proxy from a previous session before starting a new one.
  local old_pid
  old_pid=$(cat "${PROXY_PID}" 2>/dev/null || true)
  [[ -n "${old_pid}" ]] && kill "${old_pid}" 2>/dev/null || true

  # Start the proxy as a background process; redirect its output to the log.
  python3 "${PROXY_SCRIPT}" > "${PROXY_LOG}" 2>&1 &
  printf '%s' "$!" > "${PROXY_PID}"

  # Give the proxy one second to bind to port 18080 before Wine starts.
  sleep 1
  printf '[launcher] Proxy running   127.0.0.1:18080 → gateway-dev.project-crown.com\n'
  printf '[launcher] Proxy log:      %s\n' "${PROXY_LOG}"
}

# stop_proxy — stops the gateway proxy cleanly.
#
# Called automatically by the EXIT trap when this script exits for any reason.
#
# Globals:
#   PROXY_PID
stop_proxy() {
  local pid
  pid=$(cat "${PROXY_PID}" 2>/dev/null || true)
  [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  rm -f "${PROXY_PID}"
}

# Write the .env file that tells the launcher to use our local proxy.
# Recreated on every launch so it can never accidentally go missing.
printf 'API_BASE_URL=http://127.0.0.1:18080\n' > "${APP_EXE_DIR}/.env"

# Ensure stop_proxy runs when this script exits for any reason (normal exit,
# Ctrl-C, error, etc.) so the proxy is never left running as a stale process.
trap stop_proxy EXIT

start_proxy

# Launch — Wine runs inside Gamescope so the mouse is grabbed immediately.
# `read -ra` splits GS_ARGS into an array so flags are handled correctly.
if [[ "${NO_GAMESCOPE}" != "true" ]]; then
  read -ra gs_cmd <<< "${GS_ARGS}"
  exec "${gs_cmd[@]}" -- wine "${APP_EXE}" "$@"
else
  # -g mode: Wine runs without Gamescope. Login still works because the proxy
  # is running above. The mouse will not be grabbed on COSMIC / Wayland.
  exec wine "${APP_EXE}" "$@"
fi
LAUNCHEREOF

  chmod +x "${LAUNCHER_SCRIPT}"

  # Register the game in the application menu via a .desktop file.
  mkdir -p "$(dirname "${DESKTOP_FILE}")"
  cat > "${DESKTOP_FILE}" << EOF
[Desktop Entry]
Name=Cluckers Central
Comment=Realm Royale launcher
Exec=${LAUNCHER_SCRIPT}
Icon=${final_icon_path}
Type=Application
Categories=Game;
EOF
  chmod +x "${DESKTOP_FILE}"
  command_exists update-desktop-database \
    && update-desktop-database \
        "${HOME}/.local/share/applications" 2>/dev/null || true
  ok_msg "Launcher script created: ${LAUNCHER_SCRIPT}"

  # ----------------------------------------------------------------------------
  # Step 12 — Download Steam library artwork
  #
  # Fetches the official Realm Royale cover art, hero banner, and logo from
  # Steam's CDN. Applied to the Steam shortcut in the next step so the game
  # looks like a first-class entry in your Steam library.
  # ----------------------------------------------------------------------------
  step_msg "Downloading Steam library artwork..."
  mkdir -p "/tmp/cluckers_assets"

  curl -sS -L \
    -o "/tmp/cluckers_assets/grid.jpg" \
    "https://steamcdn-a.akamaihd.net/steam/apps/813820/library_600x900_2x.jpg" \
    || true
  curl -sS -L \
    -o "/tmp/cluckers_assets/hero.jpg" \
    "https://steamcdn-a.akamaihd.net/steam/apps/813820/library_hero.jpg" \
    || true
  curl -sS -L \
    -o "/tmp/cluckers_assets/logo.png" \
    "https://steamcdn-a.akamaihd.net/steam/apps/813820/logo.png" \
    || true
  ok_msg "Artwork downloaded."

  # ----------------------------------------------------------------------------
  # Step 13 — Configure Steam
  #
  # Writes entries to three Steam configuration files:
  #
  #   shortcuts.vdf    — adds the launcher script as a non-Steam game entry.
  #   localconfig.vdf  — sets Gamescope as the launch command for the official
  #                      Realm Royale AppID (covers the Steam release too).
  #   config.vdf       — assigns a Proton version to both the shortcut and the
  #                      official game AppID.
  #
  # IMPORTANT: Steam must be closed before we write these files. If Steam is
  # open it will overwrite our changes the moment it closes.
  #
  # All values are passed to the Python script via environment variables to
  # avoid quoting issues with paths that contain spaces.
  # ----------------------------------------------------------------------------
  step_msg "Configuring Steam..."

  local skip_steam="false"
  local steam_root=""
  local candidate
  for candidate in \
    "${HOME}/.steam/steam" \
    "${HOME}/.local/share/Steam" \
    "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -d "${candidate}" ]]; then
      steam_root="${candidate}"
      break
    fi
  done

  if [[ -z "${steam_root}" ]]; then
    warn_msg "Steam not found — skipping Steam integration."
    skip_steam="true"
  else
    if pgrep -x "steam" > /dev/null 2>&1; then
      printf "\n  ${RED}⚠  STEAM IS OPEN${NC}\n"
      printf "  Steam overwrites its config files when it closes, undoing our\n"
      printf "  changes. Please close Steam before continuing.\n"
      read -rp "  Press Enter once Steam is closed... "
      sleep 2
    fi

    local userdata_dir="${steam_root}/userdata"
    local steam_user=""
    local ts2 name2
    if [[ -d "${userdata_dir}" ]]; then
      while IFS=' ' read -r ts2 name2; do
        steam_user="${name2}"
        break
      done < <(
        find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d \
          -printf '%T@ %f\n' 2>/dev/null | sort -rn
      )
    fi

    if [[ -z "${steam_user}" ]]; then
      warn_msg "No Steam user account found — skipping Steam integration."
      skip_steam="true"
    else
      local -r user_config_dir="${userdata_dir}/${steam_user}/config"

      STEAM_ROOT="${steam_root}" \
      USER_CONFIG_DIR="${user_config_dir}" \
      LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
      ICON_PATH_ENV="${final_icon_path}" \
      REALM_APPID="${REALM_ROYALE_APPID}" \
      APP_NAME_ENV="${APP_NAME}" \
      GAMESCOPE_OPTS_ENV="${final_gamescope_opts}" \
      VERBOSE_ENV="${verbose}" \
      python3 - << 'PYEOF'
"""Writes Cluckers Central into Steam's configuration files."""

import binascii
import os
import shutil

import vdf

STEAM_ROOT = os.environ["STEAM_ROOT"]
USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER = os.environ["LAUNCHER_ENV"]
ICON_PATH_PY = os.environ["ICON_PATH_ENV"]
REALM_APPID = os.environ["REALM_APPID"]
APP_NAME = os.environ["APP_NAME_ENV"]
GAMESCOPE_OPTS = os.environ["GAMESCOPE_OPTS_ENV"]
VERBOSE: bool = os.environ.get("VERBOSE_ENV", "false") == "true"

_OK = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"
_INFO = "  [\033[0;36mINFO\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam shortcut ID for a non-Steam game.

    Steam identifies non-Steam shortcuts by a CRC32 hash of the executable
    path and app name combined. Reproducing this calculation lets us find
    and update exactly the right entry.

    Args:
        exe: Absolute path to the launcher executable.
        name: Display name of the shortcut.

    Returns:
        Unsigned 32-bit integer shortcut ID.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
# shortcuts.vdf stores a signed 32-bit int; values above 2^31 wrap negative.
shortcut_appid: int = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)
# Steam uses the raw unsigned value as the filename prefix in the grid/ folder.
grid_appid: str = str(unsigned_id)


# -- shortcuts.vdf: register the launcher as a non-Steam game ---------------
# Steam's shortcuts.vdf file is a binary VDF file that lists all non-Steam
# games added to your library. We add or update an entry pointing at our
# launcher script so the game appears in Steam with proper artwork.
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
shortcuts = vdf.VDFDict({"shortcuts": vdf.VDFDict()})
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
    except Exception:  # pylint: disable=broad-except
        print(f"{_WARN} Could not read shortcuts.vdf — creating a new one.")

sc = shortcuts.get("shortcuts", vdf.VDFDict())
entry_exists = False
for k, v in sc.items():
    if isinstance(v, dict) and LAUNCHER in v.get("Exe", v.get("exe", "")):
        # Entry already exists — refresh the icon path in case it moved.
        v["icon"] = ICON_PATH_PY if os.path.exists(ICON_PATH_PY) else ""
        # Launch options are handled inside the launcher script, not here.
        v["LaunchOptions"] = ""
        entry_exists = True
        break

if not entry_exists:
    next_idx = str(
        max((int(k) for k in sc if k.isdigit()), default=-1) + 1
    )
    sc[next_idx] = vdf.VDFDict({
        "AppName": APP_NAME,
        "Exe": f'"{LAUNCHER}"',
        "StartDir": f'"{os.path.dirname(LAUNCHER)}"',
        "icon": ICON_PATH_PY if os.path.exists(ICON_PATH_PY) else "",
        "LaunchOptions": "",
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "tags": vdf.VDFDict({"0": "Cluckers"}),
        "appid": shortcut_appid,
    })

shortcuts["shortcuts"] = sc
with open(shortcuts_path, "wb") as fh:
    vdf.binary_dump(shortcuts, fh)
print(f"{_OK} Added shortcut to Steam.")


# -- localconfig.vdf: set Gamescope launch options for Realm Royale ---------
# localconfig.vdf stores per-user settings for each game, including custom
# launch options. Setting the Gamescope command here means it applies whenever
# Realm Royale is launched through Steam — including the official release if
# you also own it.
localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(
            localconfig_path, "r", encoding="utf-8", errors="replace"
        ) as fh:
            lc = vdf.load(fh)
        apps = (
            lc.setdefault("UserLocalConfigStore", {})
            .setdefault("Software", {})
            .setdefault("Valve", {})
            .setdefault("Steam", {})
            .setdefault("apps", {})
        )
        apps.setdefault(REALM_APPID, {})["LaunchOptions"] = GAMESCOPE_OPTS
        with open(localconfig_path, "w", encoding="utf-8") as fh:
            vdf.dump(lc, fh, pretty=True)
        print(f"{_OK} Set Gamescope launch options for Realm Royale.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not update localconfig.vdf: {exc}")


# -- config.vdf: assign a Proton version ------------------------------------
# Proton is Valve's compatibility layer for running Windows games on Linux.
# config.vdf maps each game AppID to the Proton version it should use.
# We scan your existing mappings to find the version you use most — that is
# likely the one that works best on your hardware — and apply it to both the
# non-Steam shortcut and the official Realm Royale AppID.
config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(
            config_path, "r", encoding="utf-8", errors="replace"
        ) as fh:
            cfg = vdf.load(fh)
        mapping = (
            cfg.setdefault("InstallConfigStore", {})
            .setdefault("Software", {})
            .setdefault("Valve", {})
            .setdefault("Steam", {})
            .setdefault("CompatToolMapping", {})
        )

        proton_counts: dict = {}
        for _app, data in mapping.items():
            if isinstance(data, dict):
                tool_name = data.get("name", "")
                if "proton" in tool_name.lower():
                    proton_counts[tool_name] = (
                        proton_counts.get(tool_name, 0) + 1
                    )

        best_proton = "proton_experimental"
        if proton_counts:
            best_proton = max(proton_counts, key=proton_counts.get)
            if VERBOSE:
                print(f"{_INFO} Most-used Proton version: {best_proton}")

        mapping[str(shortcut_appid)] = {
            "name": best_proton, "config": "", "Priority": "250"
        }
        mapping[REALM_APPID] = {
            "name": best_proton, "config": "", "Priority": "250"
        }

        with open(config_path, "w", encoding="utf-8") as fh:
            vdf.dump(cfg, fh, pretty=True)
        print(f"{_OK} Assigned '{best_proton}' to launcher and Realm Royale.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not update config.vdf: {exc}")


# -- grid/: copy library artwork --------------------------------------------
# Steam loads library images from userdata/<id>/config/grid/ using the
# shortcut's app ID as a filename prefix:
#   <id>p.jpg       portrait cover shown in the library list
#   <id>_hero.jpg   wide banner shown when the game is selected
#   <id>_logo.png   logo overlaid on the hero image
grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
os.makedirs(grid_dir, exist_ok=True)
artwork_map = {
    "grid.jpg": f"{grid_appid}p.jpg",
    "hero.jpg": f"{grid_appid}_hero.jpg",
    "logo.png": f"{grid_appid}_logo.png",
}
for src_name, dest_name in artwork_map.items():
    src = os.path.join("/tmp/cluckers_assets", src_name)
    if os.path.exists(src) and os.path.getsize(src) > 0:
        shutil.copy2(src, os.path.join(grid_dir, dest_name))
print(f"{_OK} Applied Steam library artwork.")
PYEOF
    fi
  fi

  # ============================================================================
  # Done
  # ============================================================================
  printf "\n${GREEN}╔══════════════════════════════════════════════════════╗${NC}\n"
  printf "${GREEN}║                ✓  Setup complete!                    ║${NC}\n"
  printf "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n\n"

  printf "  ${YELLOW}Game version:${NC}  %s\n" "${resolved_version}"
  printf "  ${YELLOW}Game path:${NC}     %s\n\n" "${game_dir}"

  printf "  ${YELLOW}What happens each time you launch:${NC}\n"
  printf "  1. A gateway proxy starts on 127.0.0.1:18080 and relays the\n"
  printf "     launcher's login requests to the auth server.\n"
  printf "     This is what makes login work on Linux — without it, clicking\n"
  printf "     Play does nothing regardless of any other setting.\n"
  printf "     Credit: fix by oldtunasalad (Discord).\n\n"
  printf "  2. Wine launches inside Gamescope:\n"
  printf "       gamescope [flags] -- wine cluckers-central.exe\n"
  printf "     Gamescope locks the mouse inside the window on COSMIC / Wayland.\n\n"
  printf "  3. When you exit the game, the proxy stops automatically.\n\n"

  if [[ "${no_gamescope}" == "true" ]]; then
    printf "  ${YELLOW}Note:${NC} Gamescope is disabled (-g). Login still works.\n"
    printf "  Your mouse will not be grabbed on COSMIC / Wayland.\n"
    printf "  Re-run setup without -g to enable Gamescope.\n\n"
  fi

  printf "  ${CYAN}Change resolution or Hz:${NC}  edit GS_ARGS in %s\n" \
    "${LAUNCHER_SCRIPT}"
  printf "  ${CYAN}Disable Gamescope:${NC}         ./cluckers-setup.sh -g\n"
  printf "  ${CYAN}Uninstall:${NC}                 ./cluckers-setup.sh --uninstall\n\n"

  if [[ "${skip_steam}" == "false" ]]; then
    printf "  ${GREEN}▶  Open Steam and launch Cluckers Central from your library.${NC}\n"
  else
    printf "  ${GREEN}▶  Launch the game by running:${NC}\n"
    printf "     %s\n" "${LAUNCHER_SCRIPT}"
  fi
  printf "\n"
}

main "$@"
