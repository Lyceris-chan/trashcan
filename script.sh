#!/usr/bin/env bash
# ==============================================================================
#  Cluckers Central — Linux Setup Script
#
#  Installs Wine, Windows libraries, and the game. Handles authentication
#  directly via the Project Crown gateway API (the server that manages your
#  account and game content — no Windows launcher needed).
#  Optionally configures Steam integration and Gamescope.
#
#  USAGE
#    chmod +x cluckers-setup.sh          # make executable (first time only)
#    ./cluckers-setup.sh                 # interactive install (keyboard/mouse)
#    ./cluckers-setup.sh --auto          # skip all prompts, use defaults
#    ./cluckers-setup.sh --verbose       # show full Wine debug output
#    ./cluckers-setup.sh --gamescope              # opt-in: enable Gamescope compositor (-g)
#                                                 # Gamescope is a specialized window manager
#                                                 # that provides better performance and
#                                                 # features like upscaling and HDR.
#    ./cluckers-setup.sh --gamescope-with-controller  # opt-in: Gamescope + controller support (-gc)
#                                                 # Combines --gamescope and --controller in one
#                                                 # flag. Ideal for couch/TV setups where you
#                                                 # want the Gamescope compositor AND a gamepad.
#                                                 # Also triggered when both -g and -c are passed.
#    ./cluckers-setup.sh --steam-deck             # opt-in: apply game patches (Deck)    (-d)
#    ./cluckers-setup.sh --controller             # opt-in: enable controller support   (-c)
#    ./cluckers-setup.sh --update                 # check for game update       (-u)
#    ./cluckers-setup.sh --uninstall              # remove everything
#    ./cluckers-setup.sh --help                   # show this help message      (-h)
#
#  SHORT FLAGS
#    -a  auto    -v  verbose    -g  gamescope    -gc  gamescope-with-controller
#    -d  steam-deck    -c  controller    -u  update    -h  help
#    Passing both -g and -c together is the same as -gc (auto-detected).
#    --uninstall  (full word only, no short alias — removes everything)
#
#  UPDATE  (--update / -u)
#    Checks the update server for a newer game version. Update detection
#    compares the local GameVersion.dat BLAKE3 hash (a unique file identifier)
#    against the server's value. If they differ, the new game zip is downloaded
#    with resume support, verified, and extracted in place. All setup steps
#    (Wine compatibility layer, launcher, etc.) are skipped.
#
#    Combine with -d to also re-apply Deck patches afterward:
#      ./cluckers-setup.sh --update --steam-deck
#
#  VERSION PINNING  (--update only)
#    Pass GAME_VERSION=x.x.x.x to target a specific build instead of latest:
#      GAME_VERSION=0.36.2100.0 ./cluckers-setup.sh --update
#
#    Version pinning allows users to lock the game to a specific version for
#    stability and reproducibility (useful when a newer version breaks mods or
#    known functionality).
#
#    The chosen version is written to ~/.cluckers/game/.pinned_version so
#    subsequent plain `./cluckers-setup.sh --update` runs use the same version
#    automatically — no need to set GAME_VERSION each time.
#
#    To return to auto-update (always latest), delete the pin file:
#      rm ~/.cluckers/game/.pinned_version
#
#  STEAM DECK & CONTROLLER USERS
#    Pass --steam-deck / -d or --controller / -c to apply game patches after
#    the game is downloaded. These flags ensure controllers work reliably:
#      • DefaultInput.ini / RealmInput.ini — removes phantom mouse-axis
#        counters to prevent the gamepad switching to keyboard/mouse mode
#        under Wine.
#
#    The --steam-deck / -d flag additionally applies Deck-specific tweaks:
#      • RealmSystemSettings.ini — forced fullscreen at 1280×800
#      • controller_neptune_config.vdf — deploys the custom Steam Deck button
#        layout to your Steam controller config directory (preserves any
#        existing one). VDF is Valve's text-based configuration format.
#      • Gamescope is not used (SteamOS manages its own compositor)
#
#    The --gamescope-with-controller / -gc flag is for desktop Linux users who
#    want BOTH the Gamescope compositor AND controller input support. It is
#    equivalent to passing --gamescope --controller (or -g -c) together and
#    bakes both modes into the generated launcher script. Ideal for couch/TV
#    setups on desktop Linux. Steam Deck users should use --steam-deck instead.
#
#  PIN A SPECIFIC GAME VERSION
#    GAME_VERSION=0.36.9999.0 ./cluckers-setup.sh
#
#  REPRODUCIBLE BINARIES
#    Two small Windows helper binaries are embedded in this script as base64:
#
#    shm_launcher.exe  — creates a named Windows shared memory region
#                        containing the content bootstrap blob that the game
#                        reads on startup.
#                        Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/shm.go
#
#    xinput1_3.dll     — remaps controller input so all buttons work correctly
#                        under Wine/Proton.
#                        Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/deckconfig.go
#
#    To verify you get the same bytes and review the exact source code used
#    to build them (without needing to decode the base64), please see the
#    "REPRODUCIBLE BUILDS" and "SOURCE CODE" sections inside Step 6 of the
#    main() function (search this file for "REPRODUCIBLE BUILDS").
#    The source code is embedded directly in this script as comments, along
#    with full step-by-step build and verification instructions, and links to
#    the official source at https://github.com/0xc0re/cluckers
#
# ==============================================================================

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  printf "\n\033[0;31m[ERROR]\033[0m Please do not run this script as root or with sudo.\n" >&2
  printf "        System dependencies will automatically request sudo if needed.\n\n" >&2
  exit 1
fi

# ==============================================================================
#  User-configurable variables
#  Edit this section to customise the install without touching anything else.
# ==============================================================================

# Game version to install. Leave as "auto" to always get the latest release.
# To pin a specific version, set it here or override on the command line:
#   GAME_VERSION=0.36.2100.0 ./cluckers-setup.sh
GAME_VERSION="${GAME_VERSION:-auto}"

# Gamescope compositor arguments baked into the launcher at setup time.
#
# Gamescope is a Valve compositor that keeps the mouse cursor locked inside the
# game window natively on Wayland (GNOME, KDE, COSMIC). If
# you want to use it, pass --gamescope / -g when running this script.
#
# Common tweaks:
#   -W <width> -H <height>   — output resolution (default: 1920×1080)
#   -r <hz>                  — output refresh rate cap (default: 240)
#   --adaptive-sync          — enable FreeSync/G-Sync (remove if unsupported)
#   --fullscreen             — true fullscreen (borderless is broken — does not
#                              fill the screen even with a correct resolution set)
#   --hdr-enabled            — enable HDR passthrough (requires HDR display)
#
# Steam Deck users: these args are NOT used when --steam-deck / -d is passed
# because SteamOS manages its own Gamescope session automatically.
# --force-grab-cursor is included because it fixes the mouse bugging out
# (stuck in a corner or invisible) on many Desktop Environments and Distros.
# These args are also used when --gamescope-with-controller / -G is passed,
# which enables Gamescope plus full controller support in a single flag.
GAMESCOPE_ARGS="gamescope --force-grab-cursor -W 1920 -H 1080 -r 240 --adaptive-sync --fullscreen"

# ==============================================================================
#  Constants  (readonly — cannot be changed at runtime)
# ==============================================================================

# Root directory for all Cluckers-related data.
readonly CLUCKERS_ROOT="${HOME}/.cluckers"

# Wine prefix: a self-contained fake Windows environment created just for this
# game. Think of it as a tiny, isolated Windows installation that lives inside
# your home folder. It does not affect the rest of your Linux system at all.
# To uninstall the game completely, delete this directory (the --uninstall flag
# does this for you).
# We use the 'pfx' name to match Proton's internal directory structure, which
# improves compatibility with some Proton tools.
readonly WINEPREFIX="${CLUCKERS_ROOT}/pfx"

# Directory where extra Python packages used by this script are installed.
# Packages go here instead of system-wide to avoid needing sudo or affecting
# other Python programs on your system.
readonly CLUCKERS_PYLIBS="${CLUCKERS_ROOT}/pylibs"
export PYTHONPATH="${CLUCKERS_PYLIBS}:${PYTHONPATH:-}"

# XDG Base Directory Specification fallbacks.
# Source: https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
_BIN_HOME="${HOME}/.local/bin"

# The launcher script written to ~/.local/bin/ during setup. This is the small
# shell script that sets up Wine and starts the game. You can run it directly
# from a terminal or via the .desktop shortcut in your application menu.
readonly LAUNCHER_SCRIPT="${_BIN_HOME}/cluckers-central.sh"

# The .desktop file makes the game appear as an icon in your application menu
# (GNOME, KDE, etc.) so you can launch it just like a native Linux app.
readonly DESKTOP_FILE="${_DATA_HOME}/applications/cluckers-central.desktop"
readonly ICON_DIR="${_DATA_HOME}/icons"
# Desktop icon: PNG converted from the ICO embedded in the game EXE.
# The ICO is extracted via unzip and its largest frame converted to PNG
# using Pillow. PNG is used because most Linux DEs do not render ICO
# files reliably via absolute path in Icon=. The Steam shortcuts.vdf
# "icon" field uses STEAM_ICO_PATH (the CDN ICO) instead.
readonly ICON_PATH="${ICON_DIR}/cluckers-central.png"  # game icon (PNG for .desktop Icon= field)
readonly ICON_POSTER_PATH="${ICON_DIR}/cluckers-central.jpg"  # portrait poster (600×900), Steam grid only

readonly APP_NAME="Cluckers Central"

# Update-server endpoint that returns version.json with the latest build info.
# The JSON schema is defined in the companion Go server source:
# https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
readonly UPDATER_URL="https://updater.realmhub.io/builds/version.json"

# Directory where game files are downloaded and extracted.
GAME_DIR="${CLUCKERS_ROOT}/game"

# Path to the game executable, relative to GAME_DIR.
# "ShippingPC-RealmGameNoEditor.exe" is the standard name for a shipped (retail)
# Unreal Engine 3 game binary. "NoEditor" simply means the UE3 level-editor
# tools are stripped out — this is normal for all shipped UE3 titles.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/deckconfig.go
GAME_EXE_REL="Realm-Royale/Binaries/Win64/ShippingPC-RealmGameNoEditor.exe"

# Official Steam store AppID for Realm Royale Reforged. Used when creating and
# removing Steam non-Steam-game shortcuts so the correct shortcut is found.
# Verify: https://store.steampowered.com/app/813820/Realm_Royale_Reforged/
readonly REALM_ROYALE_APPID="813820"
readonly STEAM_ASSET_BASE="https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/${REALM_ROYALE_APPID}"

# High-quality art assets fetched from the Steam CDN.
# All URLs and sizes verified directly from the community assets source.
#
# community assets label  → filename                    Steam grid/ slot / use
# ───────────────────────────────────────────────────────────────────────────
# library_capsule      2x → library_600x900_2x.jpg      portrait poster  (suffix: p)
#                                                         600×900; also used as desktop icon
# library_hero         2x → library_hero_2x.jpg          hero background  (suffix: _hero)
#                                                         3840×1240 (2x HiDPI)
# logo                 2x → logo_2x.png                  logo banner      (suffix: _logo)
#                                                         1280×720 with background; NOT transparent
# main_capsule            → capsule_616x353.jpg           wide cover       (suffix: empty)
#                                                         616×353
# header                  → header.jpg                    store header     (suffix: _header)
#                                                         460×215
# community_icon (ico)    → c59e5de...ico                Steam shortcut icon (32×32 ICO)
#                                                         Used as shortcuts.vdf "icon" field —
#                                                         ICO format is natively read by Steam
#                                                         and Linux desktop environments.
# community_icon (jpg)    → 068664cf...jpg               32×32 JPG — too small, not used
#
# logo_position from community assets (written verbatim to localconfig.vdf):
#   pinned_position: BottomLeft
#   width_pct:  36.44186046511628
#   height_pct: 100
readonly STEAM_LOGO_URL="${STEAM_ASSET_BASE}/logo_2x.png?t=1739811771"
readonly STEAM_GRID_URL="${STEAM_ASSET_BASE}/library_600x900_2x.jpg?t=1739811771"
readonly STEAM_HERO_URL="${STEAM_ASSET_BASE}/library_hero_2x.jpg?t=1739811771"
readonly STEAM_WIDE_URL="${STEAM_ASSET_BASE}/capsule_616x353.jpg?t=1739811771"
readonly STEAM_HEADER_URL="${STEAM_ASSET_BASE}/header.jpg?t=1739811771"
# Game icon: the 32×32 ICO from Steam's community assets — the authoritative
# icon Steam itself uses for this game. ICO is natively handled by Steam and
# Linux desktops (XDG icon theme). Used as the shortcuts.vdf "icon" field.
# Hash from community assets: c59e5deabf96d228085fe122772251dfa526b9e2.ico
readonly STEAM_ICO_URL="https://shared.fastly.steamstatic.com/community_assets/images/apps/813820/c59e5deabf96d228085fe122772251dfa526b9e2.ico"
# community_icon jpg: 32×32 thumbnail — too small to use, not downloaded.

readonly STEAM_ASSETS_DIR="${CLUCKERS_ROOT}/assets"
# Asset paths — filenames match their purpose for clarity.
# Sizes verified against community assets source:
#   library_capsule  → library_600x900_2x.jpg  (portrait poster, 600×900; desktop icon)
#   library_hero     → library_hero_2x.jpg      (hero background, 3840×1240)
#   logo             → logo_2x.png              (logo banner 1280×720 with background; grid _logo slot)
#   main_capsule     → capsule_616x353.jpg       (wide cover, 616×353)
#   community_icon   → c59e5de...ico            (32×32 ICO; Steam shortcut icon field)
readonly STEAM_LOGO_PATH="${STEAM_ASSETS_DIR}/logo.png"
readonly STEAM_GRID_PATH="${STEAM_ASSETS_DIR}/grid.jpg"
readonly STEAM_HERO_PATH="${STEAM_ASSETS_DIR}/hero.jpg"
readonly STEAM_WIDE_PATH="${STEAM_ASSETS_DIR}/wide.jpg"
readonly STEAM_HEADER_PATH="${STEAM_ASSETS_DIR}/header.jpg"
readonly STEAM_ICO_PATH="${STEAM_ASSETS_DIR}/icon.ico"

# Directory where the two helper .exe / .dll binaries are stored after setup.
readonly TOOLS_DIR="${HOME}/.local/share/cluckers-central/tools"

# SHA-256 checksums for the two Windows helper binaries embedded in this script.
# SHA-256 is a fingerprint algorithm: if even one byte of a file changes, the
# fingerprint changes completely. We compare the fingerprint after decoding the
# embedded binary to guarantee you are running exactly the code we compiled —
# not a modified or corrupted version. See the REPRODUCIBLE BUILDS section
# inside Step 6 for full instructions on compiling and verifying yourself.
readonly SHM_LAUNCHER_SHA256="f7dfcbcd2f70089696267ad7c725adeddf4b677c79bfd4e0c3435f800ee40f41"
readonly XINPUT_DLL_SHA256="30c2cf5d35fb7489779ac6fa714c6f874868d58ec2e5f6623d9dd5a24ae503a9"

# SHA-256 fingerprint of the embedded Steam Deck controller layout template.
# Verified after extraction to confirm the embedded data was not corrupted.
readonly CONTROLLER_LAYOUT_SHA256="779194a12bf6a353e8931b17298d930f60e83126aa1a357dc6597d81dfd61709"

export WINEPREFIX

# WINEARCH tells Wine what type of fake Windows environment to create.
# "win64" means a 64-bit Windows prefix. This is required because Realm Royale
# only ships a 64-bit game executable — there is no 32-bit version of the game.
# A "win32" prefix would be unable to run it at all.
# A win64 prefix also keeps 32-bit helper DLLs in a separate folder (syswow64)
# alongside the 64-bit ones in system32, which is needed by the Visual C++
# runtime packages that ship DLLs for both architectures.
# Source: https://wiki.winehq.org/Wine_User%27s_Guide#WINEARCH
export WINEARCH="win64"

# ANSI colour codes.
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ==============================================================================
#  Output helpers
# ==============================================================================

# Prints a bold section-header banner to stdout.
#
# Arguments:
#   $1 - Step description string to display.
#
# Returns:
#   Always 0.
step_msg() {
  printf "\n%b\n%b[STEP]%b %b%b%s%b\n" \
    "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" \
    "${BLUE}" "${NC}" "${BOLD}" "${GREEN}" "$1" "${NC}"
}

# Prints an informational message to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
info_msg() { printf "  %b[INFO]%b  %s\n" "${CYAN}" "${NC}" "$1"; }

# Prints a success message to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
ok_msg() { printf "  %b[ OK ]%b  %s\n" "${GREEN}" "${NC}" "$1"; }

# Prints a non-fatal warning to stdout.
#
# Arguments:
#   $1 - Message string.
#
# Returns:
#   Always 0.
warn_msg() { printf "  %b[WARN]%b  %s\n" "${YELLOW}" "${NC}" "$1"; }

# Prints an error message to stderr and exits with status 1.
#
# Arguments:
#   $1 - Error message string.
#
# Returns:
#   Does not return; exits the process.
error_exit() {
  printf "\n%b[ERROR]%b %s\n\n" "${RED}" "${NC}" "$1" >&2
  exit 1
}

# Prints the script usage documentation extracted from the header comment block.
#
# The header comment spans lines 2-100 of this file. Leading "# " prefixes are
# stripped so the output is plain text, suitable for display in a terminal.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
print_help() {
  sed -n '2,104p' "$0" | sed 's/^# \?//'
}

# Returns 0 if the named command exists on PATH, 1 otherwise.
#
# Arguments:
#   $1 - Command name to look up.
#
# Returns:
#   0 if found, 1 if not found.
command_exists() { command -v "$1" > /dev/null 2>&1; }

# Returns 0 if the named package is installed according to the package manager.
#
# Arguments:
#   $1 - Package manager name.
#   $2 - Package name.
#
# Returns:
#   0 if installed, 1 if not.
is_pkg_installed() {
  local mgr="$1"
  local pkg="$2"
  case "${mgr}" in
    apt)    dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed" ;;
    pacman) pacman -Qq "${pkg}" >/dev/null 2>&1 ;;
    dnf)    rpm -q "${pkg}" >/dev/null 2>&1 ;;
    zypper) zypper se --installed-only "${pkg}" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# ==============================================================================
#  System dependency helpers
# ==============================================================================

# Returns the PATH, LD_LIBRARY_PATH, and WINELOADER required for a Wine binary.
#
# Arguments:
#   $1 - wine_path: Absolute path to the wine or wine64 binary.
#
# Returns:
#   Prints "BIN_DIR|LD_LIB_ADD|LOADER_PATH" to stdout.
get_wine_env_additions() {
  local wine_path="$1"
  [[ -z "${wine_path}" ]] && return 1
  
  if [[ "${wine_path}" != /* ]]; then
    wine_path=$(command -v "${wine_path}" 2>/dev/null || echo "${wine_path}")
  fi
  
  local bin_dir root_dir
  bin_dir=$(readlink -f "$(dirname "${wine_path}")" 2>/dev/null || dirname "${wine_path}")
  root_dir=$(readlink -f "$(dirname "${bin_dir}")" 2>/dev/null || dirname "${bin_dir}")
  
  # If it doesn't look like a standard /bin layout, we can't reliably guess libs.
  if [[ "$(basename "${bin_dir}")" != "bin" ]]; then
    printf '%s||%s' "${bin_dir}" "${wine_path}"
    return 0
  fi
  
  local libs=""
  local ld

  # Search for standard and architecture-specific lib folders.
  local lib_dirs=(
    "lib64" "lib" 
    "lib64/wine" "lib/wine"
    "lib64/wine/x86_64-unix" "lib/wine/i386-unix"
    "lib64/wine/x86_64-windows" "lib/wine/i386-windows"
    "lib/x86_64-linux-gnu" "lib/i386-linux-gnu"
    "lib/x86_64-linux-gnu/wine" "lib/i386-linux-gnu/wine"
  )
  for ld in "${lib_dirs[@]}"; do
    if [[ -d "${root_dir}/${ld}" ]]; then
      libs="${libs}${libs:+:}${root_dir}/${ld}"
    fi
  done
  
  # Proton 'files' layout check
  local is_proton_layout="false"
  if [[ "${bin_dir}" == */files/bin ]]; then
     is_proton_layout="true"
     local parent_root
     parent_root=$(readlink -f "$(dirname "${root_dir}")" 2>/dev/null || dirname "${root_dir}")
     for ld in "${lib_dirs[@]}"; do
       if [[ -d "${parent_root}/${ld}" ]]; then
         libs="${libs}${libs:+:}${parent_root}/${ld}"
       fi
     done
  fi
  
  # Standard system fallbacks — only add if not in a Proton layout to avoid
  # mixing system libs with Proton's bundled runtime.
  if [[ "${is_proton_layout}" == "false" ]]; then
    libs="${libs}${libs:+:}/usr/lib64:/usr/lib:/lib64:/lib:/usr/lib/x86_64-linux-gnu"
  fi
  
  printf "%s|%s|%s" "${bin_dir}" "${libs}" "${wine_path}"
}

# Returns 0 if the local game matches the version info on the server.
# Replicates the version check in:
# https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
#
# BLAKE3 is a cryptographic hash function (a unique file fingerprint).
#
# Arguments:
#   $1 - dat_path_rel: Relative path to GameVersion.dat.
#   $2 - dat_blake3: Expected BLAKE3 hash from the server.
#
# Returns:
#   0 if up to date, 1 otherwise.
is_game_up_to_date() {
  local dat_path_rel="$1"
  local dat_blake3="$2"

  local local_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
  if [[ ! -f "${local_game_exe}" ]]; then
    return 1
  fi

  if [[ -z "${dat_path_rel}" || -z "${dat_blake3}" ]]; then
    ok_msg "Game files found (version info missing; deep integrity check skipped)."
    return 0
  fi

  local local_dat="${GAME_DIR}/${dat_path_rel}"
  if [[ ! -f "${local_dat}" ]]; then
    ok_msg "Game files found but version data is missing — assuming update needed."
    return 1
  fi

  info_msg "Checking local GameVersion.dat (${local_dat})..."
  local local_dat_hash
  local_dat_hash=$(python3 - "${local_dat}" << 'DATBLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    h = b3()
    with open(sys.argv[1], "rb") as f:
        h.update(f.read())
    print(h.hexdigest())
except ImportError:
    print("skip")
DATBLAKE3EOF
  ) || local_dat_hash="skip"

  if [[ "${local_dat_hash}" == "skip" ]]; then
    ok_msg "Game files found, but deep integrity verification was skipped (blake3 missing)."
    return 0
  fi

  if [[ "${local_dat_hash}" == "${dat_blake3}" ]]; then
    ok_msg "Game version verified successfully (BLAKE3 match)."
    return 0
  fi

  warn_msg "Game version mismatch or update available."
  info_msg "Run the script with --update to get the latest version."
  return 1
}

# Installs missing system packages using the distro's package manager.
#
# Checks for the tools this script depends on and installs only those that are
# absent. Supported package managers: apt, pacman, dnf, zypper.
# On apt systems, also ensures wine32:i386, wine64, libwine:i386, and
# fonts-wine are installed, since Wine's 64-bit prefix still needs the 32-bit
# runtime libraries for syswow64 (mixed 32/64-bit DLL support).
#
# Arguments:
#   $1  Package manager name: "apt" | "pacman" | "dnf" | "zypper".
#   $@  Additional package names to check/install beyond the default set.
#
# Returns:
#   0 on success; non-zero if the package manager command fails.
install_sys_deps() {
  local -r pkg_mgr="$1"
  shift
  local to_install=()
  local tool

  local -a tools=(wine winetricks curl wget python3 unzip sha256sum cabextract)

  info_msg "Checking for: ${tools[*]}..."
  for tool in "${tools[@]}" "$@"; do
    if ! command_exists "${tool}"; then
      # If binary doesn't exist, check if the package is missing.
      # Some distros name packages differently than binaries.
      local pkg_name="${tool}"
      [[ "${pkg_mgr}" == "apt" && "${tool}" == "wine" ]] && pkg_name="wine64"
      
      if ! is_pkg_installed "${pkg_mgr}" "${pkg_name}"; then
        to_install+=("${pkg_name}")
      fi
    fi
  done

  # Explicitly check for pip / pip3.
  if ! command_exists pip && ! command_exists pip3; then
    local pip_pkg="python3-pip"
    [[ "${pkg_mgr}" == "pacman" ]] && pip_pkg="python-pip"
    [[ "${pkg_mgr}" == "dnf" ]] && pip_pkg="python3-pip"
    [[ "${pkg_mgr}" == "zypper" ]] && pip_pkg="python3-pip"
    if ! is_pkg_installed "${pkg_mgr}" "${pip_pkg}"; then
      to_install+=("${pip_pkg}")
    fi
  fi

  # Some distros provide wine/winetricks commands via package names that differ
  # from binary names. Ensure apt users still receive the full runtime stack.
  if [[ "${pkg_mgr}" == "apt" ]]; then
    local apt_deps=(wine32:i386 wine64 libwine:i386 fonts-wine)
    for ad in "${apt_deps[@]}"; do
      if ! is_pkg_installed "apt" "${ad}"; then
        # Avoid duplicates
        [[ " ${to_install[*]} " == *" ${ad} "* ]] || to_install+=("${ad}")
      fi
    done
  fi

  # Check for wine-mono/gecko on Arch-based systems.
  if [[ "${pkg_mgr}" == "pacman" ]]; then
    for ap in wine-mono wine-gecko; do
      if ! is_pkg_installed "pacman" "${ap}"; then
        to_install+=("${ap}")
      fi
    done
  fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    # Even if system packages are present, we should still ensure pip modules.
    # We call ensure_python_deps below to handle this.
    ok_msg "All required system tools are already installed."
  else
    info_msg "Missing tools: ${to_install[*]}. Installing..."
    
    # Simple progress bar for the installation process.
    local i
    local total=${#to_install[@]}
    printf "  %b[PROG]%b  Installing system dependencies: [" "${BLUE}" "${NC}"
    for ((i=0; i<40; i++)); do printf "-"; done
    printf "] 0%%\r"

    case "${pkg_mgr}" in
      apt)
        sudo dpkg --add-architecture i386
        # Only update if the cache is older than 1 hour (3600 seconds) to save time.
        local last_update
        last_update=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
        local now
        now=$(date +%s)
        if (( now - last_update > 3600 )); then
          sudo apt-get update -qq
        fi
        # Use fancy progress bar if supported.
        sudo apt-get install -y -qq -o Dpkg::Progress-Fancy="1" "${to_install[@]}" >/dev/null 2>&1
        ;;
      pacman)
        sudo pacman -Sy --noconfirm -q "${to_install[@]}" >/dev/null 2>&1
        ;;
      dnf)
        sudo dnf install -y -q "${to_install[@]}" >/dev/null 2>&1
        ;;
      zypper)
        sudo zypper install -y "${to_install[@]}" >/dev/null 2>&1
        ;;
    esac

    # Complete the progress bar.
    printf "  %b[ OK ]%b  Installing system dependencies: [" "${GREEN}" "${NC}"
    for ((i=0; i<40; i++)); do printf "#"; done
    printf "] 100%%\n"
    ok_msg "All system tools installed."
  fi

  # Step 1c — Ensure Python modules (Pillow, blake3, vdf).
  ensure_python_deps "${pkg_mgr}"
}

# Ensures essential Python modules are installed via pip.
# Pillow is required for icon extraction, blake3 for update verification,
# and vdf for Steam integration. We use 'python3 -m pip install --target'
# to keep these isolated in our local pylibs directory.
#
# Arguments:
#   $1  Package manager name (optional, for install instructions).
ensure_python_deps() {
  local -r pkg_mgr="${1:-}"
  step_msg "Step 1c — Verifying Python dependencies (Pillow, blake3, vdf)..."
  
  if ! command_exists python3; then
    warn_msg "python3 not found — skipping Python dependency check."
    return 0
  fi

  # Prefer 'python3 -m pip' as it is the most reliable way to invoke pip.
  local pip_cmd="python3 -m pip"
  
  # Check if the pip module is actually available to python3.
  if ! python3 -m pip --version >/dev/null 2>&1; then
    info_msg "pip module not found. Attempting to bootstrap via ensurepip..."
    python3 -m ensurepip --user >/dev/null 2>&1 || true
    
    # If ensurepip failed, check for 'pip3' or 'pip' binaries.
    if ! python3 -m pip --version >/dev/null 2>&1; then
      if command_exists pip3; then
        pip_cmd="pip3"
      elif command_exists pip; then
        pip_cmd="pip"
      else
        warn_msg "pip not found. Python modules might be missing."
        case "${pkg_mgr}" in
          apt)    info_msg "To install: sudo apt update && sudo apt install python3-pip" ;;
          pacman) info_msg "To install: sudo pacman -S python-pip" ;;
          dnf)    info_msg "To install: sudo dnf install python3-pip" ;;
          zypper) info_msg "To install: sudo zypper install python3-pip" ;;
          *)      info_msg "Please install the 'pip' package for your Python 3 distribution." ;;
        esac
        return 0
      fi
    fi
  fi

  local -a py_deps=(Pillow blake3 vdf)
  local missing_deps=()

  mkdir -p "${CLUCKERS_PYLIBS}"

  # Add our private pylibs to PYTHONPATH for the check.
  export PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}"

  for dep in "${py_deps[@]}"; do
    if ! python3 -c "import ${dep}" >/dev/null 2>&1; then
      missing_deps+=("${dep}")
    fi
  done

  if [[ ${#missing_deps[@]} -eq 0 ]]; then
    ok_msg "All required Python modules are already present."
    return 0
  fi

  info_msg "Installing missing Python modules: ${missing_deps[*]}..."
  # Use --target to install into our private pylibs directory.
  # This avoids PEP 668 issues and doesn't require sudo.
  if ! ${pip_cmd} install --upgrade --target "${CLUCKERS_PYLIBS}" "${missing_deps[@]}" >/dev/null 2>&1; then
    warn_msg "Failed to install Python modules via pip. Icon extraction or update verification may fail."
    return 1
  fi

  ok_msg "Python modules installed successfully."
}


# Ensures winetricks is recent enough to install the packages the game needs.
#
# winetricks is a helper script that installs Windows libraries (DLLs) into a
# Wine prefix. Like any software, it can become outdated. An old copy may try
# to download a library from a URL that no longer exists, or install a version
# too old to work. This function checks the installed version and updates it
# from the official GitHub source if it is below the minimum required version.
#
# If the update download fails (no internet, GitHub unreachable), the existing
# copy is kept and a warning is printed. The script continues — it never stops
# just because it could not update winetricks.
#
# Official winetricks source:
#   https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks
#
# Arguments:
#   None.
#
# Returns:
#   Always 0 (degrades gracefully on failure).
ensure_winetricks_fresh() {
  local wt_path
  wt_path=$(command -v winetricks 2>/dev/null || true)
  if [[ -z "${wt_path}" ]]; then
    warn_msg "winetricks not found on PATH — skipping freshness check."
    return 0
  fi

  # winetricks --version prints a date string like "20230212" or "20240101".
  local wt_ver
  wt_ver=$(winetricks --version 2>/dev/null | head -n1 | grep -oE '[0-9]{8}' | head -n1 || echo "0")

  # Minimum required version: 20240105 (first release with vcrun2019 + dxvk 2.3).
  local min_ver="20240105"

  if [[ "${wt_ver}" -ge "${min_ver}" ]] 2>/dev/null; then
    ok_msg "winetricks ${wt_ver} is up-to-date (≥ ${min_ver})."
    WINETRICKS_BIN="${wt_path}"
    return 0
  fi

  warn_msg "winetricks version '${wt_ver}' is older than ${min_ver} — fetching latest from GitHub."
  warn_msg "(An old winetricks can install wrong/broken DLL versions.)"

  local wt_url="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
  local wt_tmp
  wt_tmp=$(mktemp /tmp/winetricks.XXXXXX)

  if curl ${CURL_SILENT}fSL --max-time 30 "${wt_url}" -o "${wt_tmp}" 2>/dev/null; then
    # Sanity-check: the downloaded file must look like a shell script.
    local first_line
    first_line=$(head -c 64 "${wt_tmp}" 2>/dev/null || true)
    if [[ "${first_line}" != "#!"* ]]; then
      rm -f "${wt_tmp}"
      warn_msg "Downloaded winetricks is not a valid shell script — keeping installed copy."
      WINETRICKS_BIN="${wt_path}"
      return 0
    fi

    chmod +x "${wt_tmp}"
    local new_ver
    new_ver=$(bash "${wt_tmp}" --version 2>/dev/null \
      | head -n1 | grep -oE '[0-9]{8}' | head -n1 || echo "0")
    if [[ "${new_ver}" -ge "${wt_ver}" ]] 2>/dev/null; then
      local install_dir
      if [[ -w "${wt_path}" ]]; then
        install_dir="$(dirname "${wt_path}")"
      else
        install_dir="${HOME}/.local/bin"
        mkdir -p "${install_dir}"
      fi
      if cp "${wt_tmp}" "${install_dir}/winetricks"; then
        rm -f "${wt_tmp}"
        ok_msg "winetricks updated to ${new_ver} at ${install_dir}/winetricks."
        WINETRICKS_BIN="${install_dir}/winetricks"
      else
        rm -f "${wt_tmp}"
        warn_msg "Could not write updated winetricks to ${install_dir} — keeping installed copy."
        WINETRICKS_BIN="${wt_path}"
      fi
    else
      rm -f "${wt_tmp}"
      warn_msg "Downloaded winetricks version (${new_ver}) is not newer — keeping installed copy."
      WINETRICKS_BIN="${wt_path}"
    fi
  else
    rm -f "${wt_tmp}"
    warn_msg "Could not download latest winetricks (no internet or GitHub unreachable)."
    WINETRICKS_BIN="${wt_path}"
  fi
}

# Installs one or more winetricks packages, skipping any already present.
#
# winetricks "verbs" are short package names (like "vcrun2019" or "dxvk") that
# winetricks translates into real Windows library installers. This function
# checks whether each verb is already installed before running winetricks, so
# re-running the setup script does not waste time re-downloading packages that
# are already present in your Wine prefix.
#
# Two checks are used before deciding to install a package:
#
#   1. winetricks.log — winetricks records every successfully installed verb in
#      "${WINEPREFIX}/winetricks.log", one name per line. We search this file
#      with "grep -w" (whole-word match) using the same logic that winetricks
#      itself uses in its winetricks_is_installed() function.
#      Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
#              winetricks_is_installed() ~line 4277
#              winetricks_stats_log_command() ~line 19630
#
#   2. DLL file presence — each package installs a specific Windows DLL file
#      into the Wine prefix. If that DLL already exists, the package is already
#      installed — even if winetricks did not install it (Proton, for example,
#      pre-installs many of these). The DLL names come from each verb's
#      "installed_file1" entry in the winetricks source code.
#      Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
#              w_metadata blocks for vcrun2010, vcrun2012, vcrun2019, dxvk,
#              d3dx11_43; W_SYSTEM64_DLLS assignment ~line 4673
#
# Arguments:
#   $1  Human-readable label shown in progress messages (e.g. "C++ runtimes").
#   $2  Path to the Wine binary to use for this operation.
#   $3  Path to the wineserver binary paired with $2.
#   $4  "true" if running in non-interactive (auto) mode, "false" otherwise.
#   $@  winetricks verb names to install (e.g. "vcrun2010" "vcrun2019").
#
# Returns:
#   0 on success; continues with a warning if individual verbs fail.
install_winetricks_multi() {
  local -r desc="$1"; shift
  local -r maint_wine="$1"; shift
  local -r maint_server="$1"; shift
  local -r is_auto="$1"; shift
  local -a to_install=()
  local pkg

  # Inside your Wine prefix, Windows DLL files are stored in two folders that
  # mirror the layout of a real 64-bit Windows installation:
  #
  #   drive_c/windows/system32   — 64-bit DLLs (called W_SYSTEM64_DLLS in winetricks)
  #   drive_c/windows/syswow64   — 32-bit DLLs (called W_SYSTEM32_DLLS in winetricks)
  #
  # Even though "system32" sounds like it should hold 32-bit files, on 64-bit
  # Windows (and Wine win64 prefixes) it actually holds the 64-bit libraries.
  # This is a historical naming quirk that Microsoft kept for compatibility.
  # The Visual C++ runtime packages install DLLs into both folders, while DXVK
  # only installs 64-bit DLLs into system32.

  # Checks whether the key DLL for a given winetricks verb already exists in
  # the Wine prefix. Returns 0 (success/true) if found, 1 (failure/false) if
  # not found or if the verb is not recognised.
  #
  # This is used as a fast pre-check so we skip re-installing packages that
  # Proton already put into the prefix before winetricks was ever run (Proton
  # bundles many of the same DLLs that winetricks would install separately).
  #
  # DLL names are taken from the installed_file1 field in each verb's w_metadata
  # block in the winetricks source:
  # https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #
  # Arguments:
  #   $1  winetricks verb name (e.g. "vcrun2010", "dxvk").
  #
  # Returns:
  #   0 if the package's key DLL is present; 1 if absent or verb is unknown.
  _verb_dll_present() {
    local v="$1"
    local search_path="${WINEPREFIX}/drive_c/windows"
    case "${v}" in
      vcrun2010)
        find "${search_path}" -maxdepth 2 -iname "msvcr100.dll" 2>/dev/null | grep -q .
        ;;
      vcrun2012)
        find "${search_path}" -maxdepth 2 -iname "msvcr110.dll" 2>/dev/null | grep -q .
        ;;
      vcrun2019)
        # vcruntime140.dll is the canonical installed_file1 for vcrun2019.
        find "${search_path}" -maxdepth 2 -iname "vcruntime140.dll" 2>/dev/null | grep -q .
        ;;
      dxvk)
        # Both d3d11.dll and dxgi.dll must be present.
        find "${search_path}/system32" -maxdepth 1 -iname "d3d11.dll" 2>/dev/null | grep -q . && \
        find "${search_path}/system32" -maxdepth 1 -iname "dxgi.dll" 2>/dev/null | grep -q .
        ;;
      d3dx11_43)
        find "${search_path}" -maxdepth 2 -iname "d3dx11_43.dll" 2>/dev/null | grep -q .
        ;;
      *)
        return 1
        ;;
    esac
  }

  # winetricks writes one successfully installed verb per line to this log file.
  # It is the most reliable source of truth for what winetricks has installed.
  local wt_log="${WINEPREFIX}/winetricks.log"
  for pkg in "$@"; do
    # First, check the winetricks log (most reliable, same logic winetricks uses).
    # We check case-insensitively and match the whole line to be sure.
    # Winetricks typically logs as "load_verb", so we check for both.
    if grep -iqE "^(load_)?${pkg}$" "${wt_log}" 2>/dev/null; then
      ok_msg "${pkg} already installed (winetricks.log) — skipping."
    elif _verb_dll_present "${pkg}"; then
      ok_msg "${pkg} already installed (DLL present in prefix) — skipping."
    else
      to_install+=("${pkg}")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    ok_msg "All ${desc} are already installed."
    return 0
  fi

  info_msg "Installing ${desc}: ${to_install[*]}..."
  info_msg "(This may take several minutes. Please wait...)"

  # Ensure no orphaned wineservers are running before winetricks.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true

  local wt_flags=""
  if [[ "${is_auto}" == "true" && "${VERBOSE_MODE:-false}" != "true" ]]; then
    wt_flags="-q"
  fi

  # Run all missing packages in a single winetricks call for speed. Multiple
  # packages in one call avoids repeatedly starting and stopping Wine.
  #
  # The environment variables below are critical for a fast, clean install:
  #
  # WINEPREFIX=  — tells winetricks to install into our game's Wine prefix
  #   (~/.cluckers/pfx) instead of the default ~/.wine. Without this,
  #   winetricks would install packages into the wrong place entirely.
  #
  # DISPLAY=""   — prevents Wine from opening graphical installer windows.
  #   The Visual C++ installers normally show a progress dialog that causes
  #   Wine to spawn a full display server process inside a background thread.
  #   That process grows by ~7 MB/s with no visible activity in the terminal,
  #   making the install appear to hang. Setting DISPLAY="" prevents this.
  #
  # WINEDLLOVERRIDES="mscoree,mshtml=" — stops Wine from auto-installing Mono
  #   (.NET runtime) and Gecko (Internet Explorer engine) when the prefix is
  #   first touched. Wine tries to download these automatically, but we don't
  #   need them for this game and they add several minutes of download time.
  # Use env to pass variables to winetricks without re-assigning them in the
  # current shell. Inline VAR=value syntax (VAR=x cmd) is rejected by bash
  # when VAR is declared readonly, even though it would only be a temporary
  # assignment for the child process. env sidesteps this restriction entirely.
  #
  # LD_LIBRARY_PATH and PATH are set using get_wine_env_additions() so
  # winetricks can find Wine's internal DLLs (like kernel32.dll) and binaries.
  # These are skipped if using the Proton wrapper (is_proton_maint), as Proton
  # handles its own environment variables.
  #
  # shellcheck disable=SC2086
  local env_adds bin_add lib_add loader_add temp
  if [[ "${is_proton_maint:-false}" == "false" ]]; then
    env_adds=$(get_wine_env_additions "${maint_wine}")
    bin_add="${env_adds%%|*}"; temp="${env_adds#*|}"; 
    lib_add="${temp%%|*}"; loader_add="${env_adds##*|}"
  else
    # In Proton maintenance mode, maint_wine/maint_server are wrappers.
    # bin_add is the wrapper directory. we leave lib_add empty as Proton
    # handles its own libs, and we set loader_add to the ACTUAL wine binary
    # so winetricks doesn't try to use a script as WINELOADER.
    bin_add=$(dirname "${maint_wine}"); 
    lib_add=""; 
    loader_add="${real_wine_path}"
  fi

  # Start winetricks in the background so we can show a progress indicator.
  local wt_out
  wt_out=$(mktemp /tmp/wt_out.XXXXXX)
  
  # Snapshot the current log so we can count NEW installations.
  local log_before
  log_before=$(mktemp /tmp/wt_log_before.XXXXXX)
  mkdir -p "${WINEPREFIX}"
  touch "${WINEPREFIX}/winetricks.log"
  cp "${WINEPREFIX}/winetricks.log" "${log_before}"
  local lines_before
  lines_before=$(wc -l < "${log_before}" 2>/dev/null || echo 0)

  (
    env WINEPREFIX="${WINEPREFIX}" WINE="${maint_wine}" WINESERVER="${maint_server}" \
       PATH="${bin_add}:${PATH}" \
       ${lib_add:+LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"} \
       WINELOADER="${loader_add}" \
       DISPLAY="" WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG="-all" \
       "${WINETRICKS_BIN:-winetricks}" ${wt_flags} "${to_install[@]}" > "${wt_out}" 2>&1
  ) &
  local wt_pid=$!
  
  local i=0
  local chars="/-\|"
  local current_verb=""
  local completed=0
  local total=${#to_install[@]}

  while kill -0 "${wt_pid}" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    
    # Calculate progress based on how many new verbs appeared in the log.
    local current_lines
    current_lines=$(wc -l < "${WINEPREFIX}/winetricks.log" 2>/dev/null || echo 0)
    completed=$(( current_lines - lines_before ))
    # Clamp completed to total.
    if (( completed > total )); then completed=${total}; fi
    if (( completed < 0 )); then completed=0; fi
    
    # Guard against division by zero if total is somehow 0.
    local percent=0
    local filled=0
    local empty=30
    if [[ ${total} -gt 0 ]]; then
      percent=$(( completed * 100 / total ))
      filled=$(( completed * 30 / total ))
      empty=$(( 30 - filled ))
    fi

    local bar_str empty_str
    bar_str=$(printf "%${filled}s" "" | tr ' ' '#')
    empty_str=$(printf "%${empty}s" "" | tr ' ' '-')
    
    # Try to find what's currently executing from the output.
    # We use || true to prevent the script from exiting when grep finds no matches
    # (which returns exit code 1), as set -e and pipefail are active.
    current_verb=$(grep "Executing" "${wt_out}" 2>/dev/null | tail -n1 | sed 's/.*load_//; s/ .*//' | cut -c1-15 || true)
    [[ -z "${current_verb}" ]] && current_verb="initialising"

    printf "\r  %b[PROG]%b  [%s%s] %d%% (%d/%d) %-15s [%c]" \
      "${BLUE}" "${NC}" "${bar_str}" "${empty_str}" "${percent}" \
      "${completed}" "${total}" "${current_verb}" "${chars:$i:1}"
    
    sleep 0.5
  done
  set +e
  wait "${wt_pid}"
  local wt_status=$?
  set -e
  printf "\r"
  # Clear the progress line.
  printf "                                                                                \r"

  rm -f "${log_before}"

  if [[ "${wt_status}" -eq 0 ]]; then
    ok_msg "${desc} installed successfully."
  else
    warn_msg "Some components in '${desc}' failed to install — continuing anyway."
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
      cat "${wt_out}"
    fi
  fi
  rm -f "${wt_out}"

  # Wait for wineserver to finish all pending work, then stop it.
  #
  # wineserver is a background process Wine uses to manage its internal state
  # (similar to a Windows kernel process). After winetricks finishes, wineserver
  # keeps running until told to stop. Without "-w" (wait), wineserver lingers in
  # the background consuming ~7 MB/s of memory (visible in htop/btop as a Wine
  # process with high priority). "-w" waits for it to finish gracefully; "-k"
  # then sends a kill signal to any that did not exit on their own.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -w 2>/dev/null || true
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true
}

# ==============================================================================
#  Version resolution
# ==============================================================================

# Fetches game version metadata from the update server.
#
# Sends a request to UPDATER_URL and stores the JSON response in the global
# variable VERSION_INFO_JSON. Other functions call parse_version_field() to
# read specific fields (download URL, checksum, version string, etc.) from it.
#
# Arguments:
#   None.
#
# Returns:
#   0 on success; 1 if the server is unreachable or the response is malformed.
fetch_version_info() {
  info_msg "Querying update server for the latest game version..."

  VERSION_INFO_JSON=$(curl ${CURL_SILENT}f --max-time 15 "${UPDATER_URL}" 2>/dev/null || true)

  if [[ -z "${VERSION_INFO_JSON}" ]]; then
    return 1
  fi

  local check
  if ! check=$(python3 - "${VERSION_INFO_JSON}" << 'EOF'
import json, sys
try:
    d = json.loads(sys.argv[1])
    v = d.get("latest_version", "")
    if v:
        print(v)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
EOF
  ); then
    return 1
  fi

  if [[ ! "${check}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
}

# Extracts a single string field from VERSION_INFO_JSON.
#
# Arguments:
#   $1 - JSON key name (e.g. "zip_url").
#
# Returns:
#   Prints the field value to stdout. Prints an empty string if not found.
parse_version_field() {
  local -r field="$1"
  python3 - "${VERSION_INFO_JSON}" << EOF
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("${field}", ""))
except Exception:
    print("")
EOF
}

# ==============================================================================
#  Checksum verification
# ==============================================================================

# Verifies a file's SHA-256 checksum and exits the script on mismatch.
#
# A mismatch means the file is corrupt or has been tampered with. The script
# exits rather than continuing with a bad binary to prevent subtle breakage.
# Skips silently when the expected value is the all-zeros placeholder, which
# signals "checksum not yet known" during development.
#
# Arguments:
#   $1  Path to the file to verify.
#   $2  Expected SHA-256 hex string (64 lowercase hex characters).
#
# Returns:
#   0 if the checksum matches or is the all-zeros placeholder.
#   Does not return on mismatch; exits the process.
verify_sha256() {
  local -r file_path="$1"
  local -r expected="$2"

  if [[ "${expected}" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    # All-zeros is the placeholder — skip rather than fail so the script
    # remains usable when the installer URL changes and the SHA is not yet known.
    warn_msg "Checksum placeholder — skipping SHA-256 verification."
    return 0
  fi

  info_msg "Verifying SHA-256..."
  local actual
  actual=$(sha256sum "${file_path}" | awk '{print $1}')
  if [[ "${actual}" != "${expected}" ]]; then
    error_exit "SHA-256 mismatch for ${file_path}.
  Expected: ${expected}
  Got:      ${actual}
  The file may be corrupt or tampered. Delete it and re-run."
  fi
  ok_msg "Checksum verified."
}

# ==============================================================================
#  Uninstall
# ==============================================================================

# Removes everything this script created and cleans up Steam configuration.
#
# Deletes the Wine prefix, game files, launcher script, .desktop shortcut,
# icon, tools, and the Steam non-Steam-game shortcut entry. The Steam shortcut
# ID computation mirrors the Go implementation so the correct entry is removed.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
#
# Source (shortcut ID algorithm):
#   https://github.com/0xc0re/cluckers/blob/master/internal/cli/steam_linux.go
run_uninstall() {
  step_msg "Uninstalling Cluckers Central..."

  local cluckers_home="${HOME}/.cluckers"

  if [[ -d "${cluckers_home}" ]]; then
    info_msg "Removing Cluckers profile at ${cluckers_home}..."
    rm -rf "${cluckers_home}"
    ok_msg "Cluckers profile removed."
  fi

  local -a to_remove=(
    "${LAUNCHER_SCRIPT}"
    "${DESKTOP_FILE}"
    "${ICON_PATH}"
    "${ICON_DIR}/cluckers-central.ico"
    "${ICON_POSTER_PATH}"
    "${TOOLS_DIR}/shm_launcher.exe"
    "${TOOLS_DIR}/xinput1_3.dll"
    "${ICON_DIR}/hicolor/32x32/apps/cluckers-central.png"
    "${ICON_DIR}/hicolor/256x256/apps/cluckers-central.png"
  )
  local -a labels=(
    "Launcher script"
    "Desktop shortcut"
    "Icon (PNG)"
    "Icon (ICO)"
    "Icon (portrait poster)"
    "shm_launcher.exe"
    "xinput1_3.dll"
    "Hicolor theme icon (32x32)"
    "Hicolor theme icon (256x256)"
  )

  local i
  for i in "${!to_remove[@]}"; do
    if [[ -f "${to_remove[i]}" ]]; then
      rm -f "${to_remove[i]}"
      ok_msg "${labels[i]} removed."
    fi
  done

  # Step 1b — Uninstall Python modules (Pillow, blake3, vdf) via pip.
  if command_exists python3 && python3 -m pip --version >/dev/null 2>&1; then
    info_msg "Uninstalling Python dependencies via pip..."
    # --break-system-packages is needed on some modern distros (PEP 668) 
    # to allow pip to uninstall packages it installed in ~/.local.
    python3 -m pip uninstall -y Pillow blake3 vdf >/dev/null 2>&1 || \
    python3 -m pip uninstall -y --break-system-packages Pillow blake3 vdf >/dev/null 2>&1 || \
      warn_msg "Could not uninstall Python modules via pip (already removed?)."
    ok_msg "Python dependencies removed."
  fi

  info_msg "Looking for Steam installation to clean up shortcuts..."
  local steam_root=""
  local candidate

  # Validate a Steam directory by checking for canonical Steam marker files.
  # This matches the isSteamDir() logic in cluckers/internal/wine/steamdir.go.
  # Checking only for a userdata/ subdirectory is insufficient because some
  # Steam layouts (Flatpak) have userdata elsewhere relative to the root.
  _is_steam_dir() {
    [[ -f "${1}/steam.sh" ]] \
      || [[ -f "${1}/ubuntu12_32/steamclient.so" ]]
  }

  for candidate in \
    "${HOME}/.local/share/Steam" \
    "${HOME}/.steam/steam" \
    "${HOME}/.steam/root" \
    "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
    "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "${HOME}/snap/steam/common/.local/share/Steam"; do
    # Resolve symlinks so we don't visit the same directory twice.
    local _resolved
    _resolved=$(readlink -f "${candidate}" 2>/dev/null) || continue
    if _is_steam_dir "${_resolved}"; then
      steam_root="${_resolved}"
      break
    fi
  done

  if [[ -z "${steam_root}" ]] || ! command_exists python3; then
    warn_msg "Steam not found or Python unavailable — skipping Steam cleanup."
    printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
    return 0
  fi

  local steam_user=""
  local userdata_dir="${steam_root}/userdata"
  if [[ -d "${userdata_dir}" ]]; then
    # Pick the most-recently-modified userdata subdirectory as the active
    # Steam account. stat -c %Y is more portable than find -printf '%T@'
    # (which is a GNU-only extension unavailable on some systems).
    steam_user=$(
      find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | while IFS= read -r _d; do
            printf '%s %s\n' "$(stat -c '%Y' "${_d}" 2>/dev/null || echo 0)" \
                             "$(basename "${_d}")"
          done \
        | sort -rn \
        | awk 'NR==1 {print $2}'
    )
  fi

  if [[ -z "${steam_user}" ]]; then
    warn_msg "No Steam user found — skipping Steam cleanup."
    printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
    return 0
  fi

  info_msg "Cleaning Steam config for user ${steam_user}..."

  STEAM_ROOT="${steam_root}" \
  USER_CONFIG_DIR="${steam_root}/userdata/${steam_user}/config" \
  LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
  REALM_APPID="${REALM_ROYALE_APPID}" \
  APP_NAME_ENV="${APP_NAME}" \
  python3 - << 'PYEOF'
"""Removes Cluckers Central entries from Steam configuration files."""

import binascii
import os

import vdf  # pip install vdf

STEAM_ROOT      = os.environ["STEAM_ROOT"]
USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER        = os.environ["LAUNCHER_ENV"]
REALM_APPID     = os.environ["REALM_APPID"]
APP_NAME        = os.environ["APP_NAME_ENV"]

_OK   = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam non-Steam shortcut ID for the given exe + name pair.

    Steam computes the shortcut ID from the raw (unquoted) exe path concatenated
    with the app name. The Exe field in shortcuts.vdf is stored quoted, but the
    ID itself is derived from the unquoted path.

    Args:
        exe:  Absolute path to the launcher script or executable (unquoted).
        name: Display name used when the shortcut was added.

    Returns:
        Unsigned 32-bit shortcut ID.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id    = compute_shortcut_id(LAUNCHER, APP_NAME)
shortcut_appid = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)
# Both ID formats written by the installer need to be cleaned up.
long_id    = (unsigned_id << 32) | 0x02000000
grid_appids = [str(unsigned_id), str(long_id)]

# -- shortcuts.vdf ----------------------------------------------------------
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
        sc = shortcuts.get("shortcuts", {})
        keys_to_delete = [
            k for k, v in sc.items()
            if isinstance(v, dict)
            and int(v.get("appid", v.get("AppId", 0))) == shortcut_appid
        ]
        for k in keys_to_delete:
            del sc[k]
        with open(shortcuts_path, "wb") as fh:
            vdf.binary_dump(shortcuts, fh)
        print(f"{_OK} Removed shortcut from Steam.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean shortcuts.vdf: {exc}")

# -- localconfig.vdf --------------------------------------------------------
localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(localconfig_path, encoding="utf-8", errors="replace") as fh:
            lc = vdf.load(fh)
        apps = (
            lc.get("UserLocalConfigStore", {})
              .get("Software", {})
              .get("Valve", {})
              .get("Steam", {})
              .get("apps", {})
        )
        changed = False
        if REALM_APPID in apps and "LaunchOptions" in apps[REALM_APPID]:
            del apps[REALM_APPID]["LaunchOptions"]
            print(f"{_OK} Removed Realm Royale launch options.")
            changed = True
        
        if str(shortcut_appid) in apps:
            del apps[str(shortcut_appid)]
            print(f"{_OK} Removed Cluckers Central localconfig settings (signed).")
            changed = True
        
        unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
        if str(unsigned_id) in apps:
            del apps[str(unsigned_id)]
            print(f"{_OK} Removed Cluckers Central localconfig settings (unsigned).")
            changed = True

        if changed:
            with open(localconfig_path, "w", encoding="utf-8") as fh:
                vdf.dump(lc, fh, pretty=True)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean localconfig.vdf: {exc}")

# -- config.vdf -------------------------------------------------------------
config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(config_path, encoding="utf-8", errors="replace") as fh:
            cfg = vdf.load(fh)
        mapping = (
            cfg.get("InstallConfigStore", {})
               .get("Software", {})
               .get("Valve", {})
               .get("Steam", {})
               .get("CompatToolMapping", {})
        )
        for key in (str(shortcut_appid), REALM_APPID):
            mapping.pop(key, None)
        with open(config_path, "w", encoding="utf-8") as fh:
            vdf.dump(cfg, fh, pretty=True)
        print(f"{_OK} Removed Proton compatibility settings.")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"{_WARN} Could not clean config.vdf: {exc}")

# -- grid/ artwork ----------------------------------------------------------
# Remove all artwork files written by the installer.
# Steam uses two ID formats: modern (long_id) and legacy (unsigned_id).
# We clean both to ensure no orphaned files remain after uninstall.
grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
removed = 0
# All suffix+extension combinations written by the installer.
art_names = [
    "p.jpg", "p.png",          # Vertical poster
    ".jpg",  ".png",            # Horizontal grid / wide cover
    "_hero.jpg", "_hero.png",   # Hero background
    "_logo.png", "_logo.jpg",   # Logo banner
    "_header.jpg", "_header.png",  # Small header
]
for grid_id in grid_appids:
    for name in art_names:
        art = os.path.join(grid_dir, f"{grid_id}{name}")
        if os.path.exists(art):
            os.remove(art)
            removed += 1
if removed:
    print(f"{_OK} Removed custom Steam artwork ({removed} file(s)).")
PYEOF

  printf "\n%bUninstall complete.%b\n\n" "${GREEN}" "${NC}"
}


# ==============================================================================
#  Main install
# ==============================================================================

# Downloads a file using parallel HTTP range requests for maximum speed.
#
# Splits the file into N chunks (one per CPU thread, capped at 8) and downloads
# each chunk concurrently with curl using HTTP Range headers. Recombines the
# chunks into the final file with cat. Falls back to a single-threaded curl
# download with resume support (-C -) if the server does not advertise
# "Accept-Ranges: bytes", which is required for range requests to work.
#
# Arguments:
#   $1  Direct HTTP/HTTPS download URL.
#   $2  Destination file path to write the completed download.
#
# Returns:
#   0 on success; 1 on download failure.
#
# Source (parallel download logic):
#   https://github.com/0xc0re/cluckers/blob/master/internal/game/download.go
parallel_download() {
  local url="$1"
  local dest="$2"
  # Detect available CPU threads dynamically. Cap at 8 to avoid hammering the
  # server; floor at 1 for single-core machines or containers without nproc.
  local threads
  threads=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  # Clamp: minimum 1, maximum 8
  [[ "${threads}" -lt 1 ]] && threads=1
  [[ "${threads}" -gt 8 ]] && threads=8

  # Helper: clean up all chunk and temp files for this download.
  # Called on failure so stale chunks don't corrupt a future resume.
  _cleanup_parts() {
    local i
    for ((i=0; i<threads; i++)); do
      rm -f "${dest}.part${i}" "${dest}.part${i}.tmp"
    done
  }

  # Probe the server: get Content-Length and confirm range-request support.
  # We need both to do a correct parallel split.
  local headers
  headers=$(curl ${CURL_SILENT}IL "$url" 2>/dev/null)
  local size
  size=$(printf '%s' "$headers" \
    | grep -i '^content-length:' | tail -n1 | awk '{print $2}' | tr -d '\r' || true)
  local accept_ranges
  accept_ranges=$(printf '%s' "$headers" \
    | grep -i '^accept-ranges:' | tail -n1 | tr -d '\r' | awk '{print $2}' || true)

  # If the server doesn't support range requests, or we couldn't get the file
  # size, fall back to a single-threaded download with resume support.
  # (-C - tells curl to resume from where a previous partial download stopped.)
  if [[ -z "$size" || ! "$size" =~ ^[0-9]+$ || "${accept_ranges,,}" != "bytes" ]]; then
    info_msg "Server does not support parallel downloads — using single-threaded download."
    local resume_flag=""
    if [[ -f "${dest}.partial" ]]; then
      local partial_size
      partial_size=$(stat -c%s "${dest}.partial" 2>/dev/null || echo 0)
      info_msg "Resuming partial download from ${partial_size} bytes..."
      resume_flag="-C -"
    fi
    # resume_flag is intentionally unquoted: when empty it must not expand
    # to an empty-string argument that would confuse curl's option parser.
    # shellcheck disable=SC2086
    curl ${CURL_FLAGS} --progress-bar ${resume_flag} -o "${dest}.partial" "$url" || return 1
    mv "${dest}.partial" "$dest"
    return 0
  fi

  info_msg "Downloading with ${threads} parallel threads (${size} bytes total)..."

  local chunk_size=$(( size / threads ))
  local pids=()
  local i

  for ((i=0; i<threads; i++)); do
    local start=$(( i * chunk_size ))
    local end=$(( (i == threads - 1) ? size - 1 : (i + 1) * chunk_size - 1 ))
    local part_file="${dest}.part${i}"
    local part_size=0

    if [[ -f "$part_file" ]]; then
      part_size=$(stat -c%s "$part_file" 2>/dev/null || echo 0)
    fi

    local expected_size=$(( end - start + 1 ))

    if [[ $part_size -ge $expected_size ]]; then
      # Chunk already complete — nothing to do.
      if [[ $part_size -gt $expected_size ]]; then
        # Chunk is corrupted (too large) — reset it.
        warn_msg "Chunk ${i} is oversized — resetting."
        rm -f "$part_file"
        part_size=0
      else
        continue
      fi
    fi

    # Remove any stale .tmp file left by a previously interrupted run before
    # starting the curl subprocess, so we don't append to garbage data.
    rm -f "${part_file}.tmp"

    local new_start=$(( start + part_size ))
    # Download the remaining bytes for this chunk into a .tmp file, then
    # append to the .part file. This two-step write ensures the .part file
    # only grows with fully received data, making resume safe.
    (
      curl ${CURL_FLAGS}f -r "${new_start}-${end}" -o "${part_file}.tmp" "$url" && \
      cat "${part_file}.tmp" >> "$part_file" && \
      rm -f "${part_file}.tmp"
    ) &
    pids+=($!)
  done

  if [[ ${#pids[@]} -gt 0 ]]; then
    # Show a live progress bar while chunks download in the background.
    while true; do
      local current_size=0
      for ((i=0; i<threads; i++)); do
        local ps=0 tmps=0
        [[ -f "${dest}.part${i}" ]] \
          && ps=$(stat -c%s "${dest}.part${i}" 2>/dev/null || echo 0)
        [[ -f "${dest}.part${i}.tmp" ]] \
          && tmps=$(stat -c%s "${dest}.part${i}.tmp" 2>/dev/null || echo 0)
        current_size=$(( current_size + ps + tmps ))
      done

      local percent=0
      [[ "${size}" -gt 0 ]] && percent=$(( current_size * 100 / size ))
      local bar_length=40
      local filled=$(( percent * bar_length / 100 ))
      local empty=$(( bar_length - filled ))
      local bar_str empty_str
      bar_str=$(printf "%${filled}s"  | tr ' ' '#')
      empty_str=$(printf "%${empty}s" | tr ' ' '-')
      printf "\r  [INFO]  [%s%s] %d%% (%d / %d MB)   " \
        "${bar_str}" "${empty_str}" "${percent}" \
        "$((current_size / 1048576))" "$((size / 1048576))"

      local all_done=true
      local pid
      for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null && { all_done=false; break; }
      done
      $all_done && break
      sleep 1
    done

    # Collect exit codes only after the progress loop exits, so we get the
    # true final status of every subprocess before reporting success or failure.
    local failed=false
    local pid_w
    for pid_w in "${pids[@]}"; do
      wait "$pid_w" || failed=true
    done
    printf "\n"

    if $failed; then
      warn_msg "One or more download chunks failed — cleaning up partial files."
      _cleanup_parts
      return 1
    fi
  fi

  # All chunks complete — concatenate in order into the final destination file.
  rm -f "$dest"
  for ((i=0; i<threads; i++)); do
    cat "${dest}.part${i}" >> "$dest"
    rm -f "${dest}.part${i}"
  done

  return 0
}

# Checks for a newer game version and downloads it if available.
# Skips all setup steps — only updates the game files in GAME_DIR.
# Optionally applies game patches (Steam Deck or Controller) afterward.
# Uses global variables: GAME_DIR, UPDATER_URL, GAME_VERSION.
#
# Update detection: fetches version.json from the update server, reads the
# local GameVersion.dat, computes its BLAKE3 hash, and compares it against
# the server's value. A mismatch means an update is needed.
# BLAKE3 is a cryptographic fingerprinting algorithm (a fast hash function that
# produces a unique file identifier). If even one byte changes, the entire hash
# changes. We use it to verify the downloaded file wasn't corrupted or tampered with.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/game/version.go
#
# Version pinning:
#   Set GAME_VERSION=x.x.x.x before calling to target a specific build.
#   The pin is written to ${GAME_DIR}/.pinned_version so subsequent plain
#   `./cluckers-setup.sh --update` runs remember the chosen version without
#   needing GAME_VERSION set again. Clear the file to return to auto-update.
#   Version pinning allows users to lock the game to a specific version for
#   stability and reproducibility (useful when a newer version breaks mods or
#   known functionality).
#
# Arguments:
#   $1 - steam_deck_flag: "true" | "false"
#   $2 - controller_flag: "true" | "false"
#
# Returns:
#   0 on success; exits with error via error_exit() on failure.
run_update() {
  local -r steam_deck_flag="$1"
  local -r controller_flag="$2"

  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║          Cluckers Central — Game Update              ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n\n" "${GREEN}" "${NC}"

  step_msg "Checking for game update..."

  # Fetch version metadata from the update server.
  # VERSION_INFO_JSON is a local to avoid polluting the caller's scope.
  local VERSION_INFO_JSON=""
  if ! fetch_version_info; then
    error_exit "Could not reach update server. Check your internet connection."
  fi

  local server_version
  local zip_url
  local zip_blake3
  local dat_path_rel
  local dat_blake3
  server_version=$(parse_version_field "latest_version")
  zip_url=$(parse_version_field "zip_url")
  zip_blake3=$(parse_version_field "zip_blake3")
  # gameversion_dat_path is relative to GAME_DIR — e.g.
  # "Realm-Royale/Binaries/GameVersion.dat" (no Win64/ component).
  dat_path_rel=$(parse_version_field "gameversion_dat_path")
  dat_blake3=$(parse_version_field "gameversion_dat_blake3")

  info_msg "Latest version on server: ${server_version}"

  # ---- Version pinning -------------------------------------------------------
  # Version pinning allows users to lock the game to a specific version for
  # stability and reproducibility (useful when a newer version breaks mods or
  # known functionality). Priority order (highest first):
  #   1. GAME_VERSION env var set by the user for this run.
  #   2. .pinned_version file written by a previous pinned --update run.
  #   3. "auto" — use latest from server.
  local pin_file="${GAME_DIR}/.pinned_version"
  local target_version="${GAME_VERSION}"

  if [[ "${target_version}" == "auto" ]] && [[ -f "${pin_file}" ]]; then
    target_version=$(tr -d '[:space:]' < "${pin_file}" 2>/dev/null || echo "auto")
    # Validate the pin file value is a safe dotted-numeric version string.
    # This prevents a tampered/corrupted pin file from injecting arbitrary
    # characters into the download URL constructed below.
    if [[ "${target_version}" != "auto" ]]; then
      if [[ "${target_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        info_msg "Using pinned version from ${pin_file}: ${target_version}"
      else
        warn_msg "Pin file contains invalid version '${target_version}' — ignoring, using latest."
        target_version="auto"
      fi
    fi
  fi

  if [[ "${target_version}" == "auto" ]]; then
    target_version="${server_version}"
    info_msg "Targeting latest version: ${target_version}"
  else
    info_msg "Targeting pinned version: ${target_version}"
    # Build the zip URL for the pinned version (BLAKE3 not available for old
    # builds, so we skip hash verification and rely on SHA-256 of the zip).
    # target_version is already validated as ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$
    # so it is safe to interpolate directly into the URL.
    zip_url="https://updater.realmhub.io/builds/game-${target_version}.zip"
    zip_blake3=""
    dat_blake3=""
    # Write pin file so future plain --update runs use the same version.
    mkdir -p "${GAME_DIR}"
    printf '%s\n' "${target_version}" > "${pin_file}"
    ok_msg "Version pinned to ${target_version} (saved to ${pin_file})."
    info_msg "To return to auto-update, delete ${pin_file} or run:"
    info_msg "  rm ${pin_file}"
  fi

  # ---- Update detection ------------------------------------------------------
  # Read the local GameVersion.dat, compute its BLAKE3 hash, and compare to
  # the server's value. Falls back to "needs update" if absent or unreadable.
  if is_game_up_to_date "${dat_path_rel}" "${dat_blake3}"; then
    ok_msg "Game is already up to date (${target_version})."
    ok_msg "Game version verified successfully."
    return 0
  fi

  # Validate the zip URL before use — reject anything that isn't a plain
  # https:// URL pointing to the expected update host. This prevents a
  # compromised version.json from redirecting downloads to an attacker's server.
  if [[ ! "${zip_url}" =~ ^https://updater\.realmhub\.io/ ]]; then
    error_exit "Update server returned an unexpected download URL: '${zip_url}'
  Only https://updater.realmhub.io/ URLs are accepted. Aborting for safety."
  fi

  info_msg "Update required. Downloading ${target_version}..."
  info_msg "URL: ${zip_url}"

  # ---- Download with resume --------------------------------------------------
  local zip_path="${GAME_DIR}/game.zip"
  mkdir -p "${GAME_DIR}"

  info_msg "Downloading (~5.3 GB — this may take a while)..."
  info_msg "If interrupted, re-run with --update / -u to resume."

  parallel_download "${zip_url}" "${zip_path}" \
    || error_exit "Download failed. Check your internet connection."

  ok_msg "Download complete."

  # ---- BLAKE3 hash verification (file integrity check) ----------------------
  if [[ -n "${zip_blake3}" ]]; then
    info_msg "Verifying BLAKE3 integrity of game zip..."
    # Verify downloaded zip integrity using BLAKE3 hash comparison against server's value.
    local actual_blake3
    actual_blake3=$(python3 - "${zip_path}" << 'ZIPBLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    h = b3()
    with open(sys.argv[1], "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    print(h.hexdigest())
except ImportError:
    print("skip")
ZIPBLAKE3EOF
    ) || actual_blake3="skip"

    if [[ "${actual_blake3}" == "skip" ]]; then
      warn_msg "blake3 module not installed — skipping zip BLAKE3 verification."
      warn_msg "Install with: pip install blake3"
    elif [[ "${actual_blake3}" != "${zip_blake3}" ]]; then
      rm -f "${zip_path}"
      error_exit "BLAKE3 mismatch — zip may be corrupt. Re-run --update to retry.
  Expected: ${zip_blake3}
  Got:      ${actual_blake3}"
    else
      ok_msg "BLAKE3 integrity verified."
    fi
  fi

  # ---- Prepare for extraction ------------------------------------------------
  # If any existing game files are read-only, extraction will fail with
  # "Permission denied" when the tool tries to overwrite them. This matches
  # the fix applied in Cluckers fix-35 (commit cd25d215): before extracting,
  # find all read-only regular files in GAME_DIR and make them user-writable.
  # This is safe because we are about to overwrite them with newer versions.
  if [[ -d "${GAME_DIR}" ]]; then
    info_msg "Ensuring game files are writable before extraction..."
    find "${GAME_DIR}" -type f ! -writable -exec chmod u+w {} + 2>/dev/null || true
  fi

  # ---- Extract in place -------------------------------------------------------
  info_msg "Extracting update (this may take several minutes)..."
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "${zip_path}" -C "${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  elif command -v 7z >/dev/null 2>&1; then
    7z x -y "${zip_path}" -o"${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  else
    UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip -o "${zip_path}" -d "${GAME_DIR}" \
      || error_exit "Extraction failed. Re-run with --update to retry."
  fi
  rm -f "${zip_path}"
  ok_msg "Game updated to ${target_version}."

  # Apply game patches (Deck or controller) if any flags were set.
  # Without this, --update --steam-deck would download the update but skip
  # re-applying input patches, leaving the game unconfigured for the Deck.
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    apply_game_patches "${GAME_DIR}" "${steam_deck_flag}" "${controller_flag}"
  fi
}

# Returns 0 if running on a Steam Deck, 1 otherwise.
# Checks DMI board vendor, /etc/os-release, and the default Deck home directory.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/gui/deck_linux.go
#
# Arguments:
#   None.
#
# Returns:
#   0 if Steam Deck, 1 otherwise.
is_steam_deck() {
  # Primary: DMI board vendor set to "Valve" by SteamOS.
  if [[ -r /sys/devices/virtual/dmi/id/board_vendor ]]; then
    local vendor
    vendor=$(tr -d '[:space:]' < /sys/devices/virtual/dmi/id/board_vendor)
    if [[ "${vendor}" == "Valve" ]]; then
      return 0
    fi
  fi
  # Secondary: /etc/os-release identifies SteamOS.
  if [[ -r /etc/os-release ]] && grep -q "ID=steamos" /etc/os-release; then
    return 0
  fi
  # Tertiary: /home/deck exists AND /etc/os-release contains SteamOS marker.
  # The bare /home/deck check is intentionally combined with an os-release
  # check to avoid false-positives on any machine that happens to have a
  # 'deck' user account (e.g. a developer's workstation).
  if [[ -d /home/deck ]] && [[ -r /etc/os-release ]] \
     && grep -qi "steamos\|valve" /etc/os-release 2>/dev/null; then
    return 0
  fi
  return 1
}

# Applies game patches (display, input, layout) for Steam Deck or generic controllers.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/deckconfig.go
#
# Patches applied:
#   RealmSystemSettings.ini — forces fullscreen at 1280x800 (Deck only).
#   DefaultInput.ini / RealmInput.ini — removes phantom mouse-axis counters
#     (Count bXAxis / Count bYAxis) to prevent the controller from switching
#     to keyboard/mouse mode under Wine. Wine is a compatibility layer that
#     allows Windows games to run on Linux by translating Windows API calls.
#     Under Wine, controller input needs special patches to work correctly.
#   controller_neptune_config.vdf — Steam Deck button layout (best-effort, Deck only).
#     controller_neptune_config.vdf is a Steam Deck controller configuration file
#     (VDF is Valve's text-based configuration format for Steam) that defines
#     custom button mappings for this game.
#
# Arguments:
#   $1 - game_dir: absolute path to the game data directory (GAME_DIR).
#   $2 - steam_deck_flag: "true" | "false"
#   $3 - controller_flag: "true" | "false"
#
# Returns:
#   0 on success; 1 if required config directories not found.
apply_game_patches() {
  local game_dir="$1"
  local -r steam_deck_flag="$2"
  local -r controller_flag="$3"
  local config_dir="${game_dir}/Realm-Royale/RealmGame/Config"
  local engine_config_dir="${game_dir}/Realm-Royale/Engine/Config"

  # Ensure the game's config directories exist before attempting to patch.
  if [[ ! -d "${config_dir}" || ! -d "${engine_config_dir}" ]]; then
    warn_msg "Game configuration directories not found in ${game_dir}"
    warn_msg "  (Run setup again after downloading the game.)"
    return 1
  fi

  local ini

  # List all applicable patches based on preferences
  info_msg "Evaluating applicable patches:"
  [[ "${steam_deck_flag}" == "true" ]] \
    && info_msg "  • [Steam Deck] Force 1280x800 resolution and fullscreen"
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    info_msg "  • [Controller] Force engine-level input to Gamepad"
    info_msg "  • [Controller] Neutralize phantom mouse-axis counters (fixes KB/M switching)"
  fi
  [[ "${steam_deck_flag}" == "true" ]] \
    && info_msg "  • [Steam Deck] Deploy custom button layout template"

  # Remember preference if requested.
  if [[ "${controller_flag}" == "true" ]]; then
    mkdir -p "${game_dir}"
    touch "${game_dir}/.controller_enabled"
  fi


  # -- Display: force fullscreen 1280x800 (Steam Deck only) ------------------
  if [[ "${steam_deck_flag}" == "true" ]]; then
    info_msg "Patch: Forcing 1280x800 fullscreen (Steam Deck)..."
    ini="${config_dir}/RealmSystemSettings.ini"
    if [[ -f "${ini}" ]]; then
      chmod u+w "${ini}"
      python3 - "${ini}" << 'DECK_DISPLAY_EOF'
import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    ("Fullscreen=false",        "Fullscreen=True"),
    ("FullscreenWindowed=false","FullscreenWindowed=True"),
    ("ResX=1920",               "ResX=1280"),
    ("ResY=1080",               "ResY=800"),
]
for old, new in patches:
    txt = txt.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(txt)
print("  Patched RealmSystemSettings.ini (1280x800 fullscreen)")
DECK_DISPLAY_EOF
    else
      warn_msg "RealmSystemSettings.ini not found — display patch skipped."
      warn_msg "  (Run setup again after downloading the game.)"
    fi
  fi

  # -- Input: remove phantom mouse-axis counters (Deck or Controller mode) ---
  if [[ "${steam_deck_flag}" == "true" || "${controller_flag}" == "true" ]]; then
    # CrossplayInputMethod=Gamepad forces the UE3 engine to treat all input as
    # gamepad, resolving "Unassigned" button labels and preventing the engine
    # from switching back to keyboard/mouse mode during map transitions.
    # Source: https://www.pcgamingwiki.com/wiki/Paladins#Controller_support
    #         (CrossplayInputMethod ini key documented under Controller support)
    info_msg "Patch: Forcing engine-level input to Gamepad (Controller mode)..."
    ini="${config_dir}/RealmGame.ini"
    if [[ -f "${ini}" ]]; then
      chmod u+w "${ini}"
      python3 - "${ini}" << 'ENGINE_OVERRIDE_EOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    ("CrossplayInputMethod=ECIM_Keyboard", "CrossplayInputMethod=ECIM_Gamepad"),
    ("CrossplayInputMethod=ECIM_None", "CrossplayInputMethod=ECIM_Gamepad")
]
changed = False
for old, new in patches:
    if old in txt:
        txt = txt.replace(old, new)
        changed = True

# If neither is found, we might need to add it, but replacing existing is safer
if "CrossplayInputMethod=ECIM_Gamepad" not in txt:
    # Just in case it's missing entirely in [TgGame.TgGameProfile]
    if "[TgGame.TgGameProfile]" in txt:
        txt = txt.replace("[TgGame.TgGameProfile]", "[TgGame.TgGameProfile]\nCrossplayInputMethod=ECIM_Gamepad")
        changed = True

if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    print("  Patched RealmGame.ini (CrossplayInputMethod)")
ENGINE_OVERRIDE_EOF
    fi

    info_msg "Patch: Neutralizing phantom mouse-axis counters (Controller mode)..."
    # "Count bXAxis" / "Count bYAxis" in mouse bindings cause UE3 to switch from
    # gamepad to KB/M mode whenever phantom mouse events arrive under Wine.
    # Removes phantom mouse-axis counters that cause the game to switch from
    # gamepad to KB/M mode under Wine.
    for ini in \
      "${engine_config_dir}/BaseInput.ini" \
      "${config_dir}/DefaultInput.ini" \
      "${config_dir}/RealmInput.ini"; do
      if [[ ! -f "${ini}" ]]; then
        continue
      fi
      chmod u+w "${ini}"
      python3 - "${ini}" << 'DECK_INPUT_EOF'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    txt = f.read()

patches = [
    (
        'Bindings=(Name="MouseX",Command="Count bXAxis | Axis aMouseX")',
        'Bindings=(Name="MouseX",Command="Axis aMouseX")',
    ),
    (
        'Bindings=(Name="MouseY",Command="Count bYAxis | Axis aMouseY")',
        'Bindings=(Name="MouseY",Command="Axis aMouseY")',
    ),
]

changed = False
for old, new in patches:
    if old in txt:
        txt = txt.replace(old, new)
        txt = txt.replace("+" + old, "+" + new)
        changed = True

# For DefaultInput.ini, add UE3 -Bindings= removal directives so coalescing
# does not re-add the Count commands from BaseInput.ini.
import os
if os.path.basename(path) == "DefaultInput.ini":
    for old, new in patches:
        remove = "-" + old
        if remove not in txt:
            add_line = "+" + new
            idx = txt.find(add_line)
            if idx > 0:
                txt = txt[:idx] + remove + "\n" + txt[idx:]
                changed = True
    # Ensure bUsingGamepad=True and AllowJoystickInput=True in input sections.
for section in ["[Engine.PlayerInput]", "[TgGame.TgPlayerInput]"]:
    if section not in txt:
        txt += f"\n{section}\nbUsingGamepad=True\nAllowJoystickInput=True\n"
        changed = True
    else:
        # If section exists, ensure keys are set
        lines = txt.splitlines()
        new_lines = []
        in_sect = False
        has_gamepad = False
        has_joystick = False
        for line in lines:
            if line.strip().lower() == section.lower():
                in_sect = True
            elif in_sect and line.strip().startswith("["):
                if not has_gamepad: new_lines.append("bUsingGamepad=True")
                if not has_joystick: new_lines.append("AllowJoystickInput=True")
                in_sect = False

            if in_sect:
                if line.strip().lower().startswith("businggamepad="):
                    line = "bUsingGamepad=True"
                    has_gamepad = True
                    changed = True
                if line.strip().lower().startswith("allowjoystickinput="):
                    line = "AllowJoystickInput=True"
                    has_joystick = True
                    changed = True
            new_lines.append(line)

        if in_sect: # Section was at end of file
            if not has_gamepad: new_lines.append("bUsingGamepad=True")
            if not has_joystick: new_lines.append("AllowJoystickInput=True")
            changed = True
        txt = "\n".join(new_lines)

if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    print("  Patched " + os.path.basename(path))
else:
    print("  " + os.path.basename(path) + " already patched — skipping.")
DECK_INPUT_EOF
    done
  fi

  # Make all INI files writable so the game can save user controller preferences.
  chmod u+w "${config_dir}"/*.ini 2>/dev/null || true

  # -- Controller layout: deploy controller_neptune_config.vdf (Deck only) ----
  if [[ "${steam_deck_flag}" == "true" ]]; then
    info_msg "Patch: Deploying Steam Deck controller layout template..."
    # Best-effort: deploy to every Steam userdata account directory found.
    # Preserves any existing user-customised layout (never overwrites).
    # Deploys the Steam Deck button layout template to Steam's controller config.
    local vdf_tmp
    vdf_tmp=$(mktemp /tmp/cluckers_neptune_XXXXXX --suffix=.vdf) \
      || { warn_msg "mktemp failed — skipping controller layout deploy."; return 0; }
    base64 -d << 'NEPTUNE_B64_EOF' > "${vdf_tmp}"
ImNvbnRyb2xsZXJfbWFwcGluZ3MiCnsKCSJ2ZXJzaW9uIiAiMyIKCSJnYW1lIiAiUmVhbG0gUm95
YWxlIChDbHVja2VycykiCgkidGl0bGUiICIjVGl0bGUiCgkiZGVzY3JpcHRpb24iICIjRGVzY3Jp
cHRpb24iCgkiY29udHJvbGxlcl90eXBlIgkJImNvbnRyb2xsZXJfbmVwdHVuZSIKCSJtYWpvcl9y
ZXZpc2lvbiIJCSIwIgoJIm1pbm9yX3JldmlzaW9uIgkJIjAiCgkibG9jYWxpemF0aW9uIgoJewoJ
CSJlbmdsaXNoIgoJCXsKCQkJIlRpdGxlIiAiUmVhbG0gUm95YWxlIC0gQ2x1Y2tlcnMiCgkJCSJE
ZXNjcmlwdGlvbiIgIkN1c3RvbSBsYXlvdXQgZm9yIFJlYWxtIFJveWFsZS4gTWFwcyBEZWNrIGNv
bnRyb2xzIHRvIGtleWJvYXJkL21vdXNlIGJpbmRpbmdzLiBSaWdodCB0cmFja3BhZCBhbmQgcmln
aHQgc3RpY2sgY29udHJvbCBjYW1lcmEuIFRyaWdnZXJzIGZpcmUvQURTLiBCdW1wZXJzIGZvciBh
YmlsaXRpZXMgMS8yLiBELXBhZCBmb3IgYWJpbGl0aWVzIDMvNCwgbW91bnQsIGNvc21ldGljIHdo
ZWVsLiIKCQl9Cgl9CgkiZ3JvdXAiCgl7CgkJImlkIgkJIjAiCgkJIm1vZGUiCQkiZm91cl9idXR0
b25zIgoJCSJpbnB1dHMiCgkJewoJCQkiYnV0dG9uX2EiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJ
CQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJ
CQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgU1BBQ0UiCgkJCQkJCX0KCQkJCQl9CgkJCQl9CgkJ
CX0KCQkJImJ1dHRvbl9iIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9Q
cmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQki
a2V5X3ByZXNzIEYiCgkJCQkJCX0KCQkJCQl9CgkJCQl9CgkJCX0KCQkJImJ1dHRvbl94IgoJCQl7
CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJi
aW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNzIEUiCgkJCQkJCX0K
CQkJCQl9CgkJCQl9CgkJCX0KCQkJImJ1dHRvbl95IgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJ
CXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJ
CQkJImJpbmRpbmciCQkibW91c2Vfd2hlZWwgU0NST0xMX1VQIgoJCQkJCQl9CgkJCQkJfQoJCQkJ
fQoJCQl9CgkJfQoJfQoJImdyb3VwIgoJewoJCSJpZCIJCSIxIgoJCSJtb2RlIgkJImRwYWQiCgkJ
ImlucHV0cyIKCQl7CgkJCSJkcGFkX25vcnRoIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsK
CQkJCQkiRnVsbF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJ
ImJpbmRpbmciCQkia2V5X3ByZXNzIEgiCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7
CgkJCQkJCQkiaGFwdGljX2ludGVuc2l0eSIJCSIxIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9
CgkJCSJkcGFkX3NvdXRoIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9Q
cmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQki
a2V5X3ByZXNzIEciCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiaGFw
dGljX2ludGVuc2l0eSIJCSIxIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJCSJkcGFkX2Vh
c3QiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJCQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsK
CQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgViIK
CQkJCQkJfQoJCQkJCQkic2V0dGluZ3MiCgkJCQkJCXsKCQkJCQkJCSJoYXB0aWNfaW50ZW5zaXR5
IgkJIjEiCgkJCQkJCX0KCQkJCQl9CgkJCQl9CgkJCX0KCQkJImRwYWRfd2VzdCIKCQkJewoJCQkJ
ImFjdGl2YXRvcnMiCgkJCQl7CgkJCQkJIkZ1bGxfUHJlc3MiCgkJCQkJewoJCQkJCQkiYmluZGlu
Z3MiCgkJCQkJCXsKCQkJCQkJCSJiaW5kaW5nIgkJImtleV9wcmVzcyBSIgoJCQkJCQl9CgkJCQkJ
CSJzZXR0aW5ncyIKCQkJCQkJewoJCQkJCQkJImhhcHRpY19pbnRlbnNpdHkiCQkiMSIKCQkJCQkJ
fQoJCQkJCX0KCQkJCX0KCQkJfQoJCX0KCQkic2V0dGluZ3MiCgkJewoJCQkicmVxdWlyZXNfY2xp
Y2siCQkiMCIKCQkJImVkZ2VfYmluZGluZ19yYWRpdXMiCQkiMjQ5OTYiCgkJfQoJfQoJImdyb3Vw
IgoJewoJCSJpZCIJCSIyIgoJCSJtb2RlIgkJImFic29sdXRlX21vdXNlIgoJCSJpbnB1dHMiCgkJ
ewoJCX0KCQkic2V0dGluZ3MiCgkJewoJCQkic2Vuc2l0aXZpdHkiCQkiMTQ1IgoJCQkiZG91YmV0
YXBfbWF4X2R1cmF0aW9uIgkJIjMyMCIKCQl9Cgl9CgkiZ3JvdXAiCgl7CgkJImlkIgkJIjMiCgkJ
Im1vZGUiCQkiZHBhZCIKCQkiaW5wdXRzIgoJCXsKCQkJImRwYWRfbm9ydGgiCgkJCXsKCQkJCSJh
Y3RpdmF0b3JzIgoJCQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdz
IgoJCQkJCQl7CgkJCQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgVyIKCQkJCQkJfQoJCQkJCQki
c2V0dGluZ3MiCgkJCQkJCXsKCQkJCQkJCSJoYXB0aWNfaW50ZW5zaXR5IgkJIjEiCgkJCQkJCX0K
CQkJCQl9CgkJCQl9CgkJCX0KCQkJImRwYWRfc291dGgiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJ
CQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJ
CQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgUyIKCQkJCQkJfQoJCQkJCQkic2V0dGluZ3MiCgkJ
CQkJCXsKCQkJCQkJCSJoYXB0aWNfaW50ZW5zaXR5IgkJIjEiCgkJCQkJCX0KCQkJCQl9CgkJCQl9
CgkJCX0KCQkJImRwYWRfZWFzdCIKCQkJewoJCQkJImFjdGl2YXRvcnMiCgkJCQl7CgkJCQkJIkZ1
bGxfUHJlc3MiCgkJCQkJewoJCQkJCQkiYmluZGluZ3MiCgkJCQkJCXsKCQkJCQkJCSJiaW5kaW5n
IgkJImtleV9wcmVzcyBEIgoJCQkJCQl9CgkJCQkJCSJzZXR0aW5ncyIKCQkJCQkJewoJCQkJCQkJ
ImhhcHRpY19pbnRlbnNpdHkiCQkiMSIKCQkJCQkJfQoJCQkJCX0KCQkJCX0KCQkJfQoJCQkiZHBh
ZF93ZXN0IgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJ
CQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNz
IEEiCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiaGFwdGljX2ludGVu
c2l0eSIJCSIxIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJfQoJCSJzZXR0aW5ncyIKCQl7
CgkJCSJyZXF1aXJlc19jbGljayIJCSIwIgoJCQkiZWRnZV9iaW5kaW5nX3JhZGl1cyIJCSIyNDk5
NSIKCQl9Cgl9CgkiZ3JvdXAiCgl7CgkJImlkIgkJIjQiCgkJIm1vZGUiCQkidHJpZ2dlciIKCQki
aW5wdXRzIgoJCXsKCQkJImVkZ2UiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJCQkJewoJCQkJCSJG
dWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiYmluZGlu
ZyIJCSJtb3VzZV9idXR0b24gUklHSFQiCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7
CgkJCQkJCQkiaGFwdGljX2ludGVuc2l0eSIJCSIyIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9
CgkJfQoJfQoJImdyb3VwIgoJewoJCSJpZCIJCSI1IgoJCSJtb2RlIgkJInRyaWdnZXIiCgkJImlu
cHV0cyIKCQl7CgkJCSJlZGdlIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVs
bF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmci
CQkibW91c2VfYnV0dG9uIExFRlQiCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7CgkJ
CQkJCQkiaGFwdGljX2ludGVuc2l0eSIJCSIyIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJ
fQoJfQoJImdyb3VwIgoJewoJCSJpZCIJCSI3IgoJCSJtb2RlIgkJImRwYWQiCgkJImlucHV0cyIK
CQl7CgkJCSJkcGFkX25vcnRoIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVs
bF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmci
CQkia2V5X3ByZXNzIEgiCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7CgkJCQkJCQki
aGFwdGljX2ludGVuc2l0eSIJCSIxIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJCSJkcGFk
X3NvdXRoIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJ
CQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNz
IEciCgkJCQkJCX0KCQkJCQkJInNldHRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiaGFwdGljX2ludGVu
c2l0eSIJCSIxIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJCSJkcGFkX2Vhc3QiCgkJCXsK
CQkJCSJhY3RpdmF0b3JzIgoJCQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJp
bmRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgWiIKCQkJCQkJfQoJ
CQkJCQkic2V0dGluZ3MiCgkJCQkJCXsKCQkJCQkJCSJoYXB0aWNfaW50ZW5zaXR5IgkJIjEiCgkJ
CQkJCX0KCQkJCQl9CgkJCQl9CgkJCX0KCQkJImRwYWRfd2VzdCIKCQkJewoJCQkJImFjdGl2YXRv
cnMiCgkJCQl7CgkJCQkJIkZ1bGxfUHJlc3MiCgkJCQkJewoJCQkJCQkiYmluZGluZ3MiCgkJCQkJ
CXsKCQkJCQkJCSJiaW5kaW5nIgkJImtleV9wcmVzcyBWIgoJCQkJCQl9CgkJCQkJCSJzZXR0aW5n
cyIKCQkJCQkJewoJCQkJCQkJImhhcHRpY19pbnRlbnNpdHkiCQkiMSIKCQkJCQkJfQoJCQkJCX0K
CQkJCX0KCQkJfQoJCX0KCQkic2V0dGluZ3MiCgkJewoJCQkicmVxdWlyZXNfY2xpY2siCQkiMCIK
CQl9Cgl9CgkiZ3JvdXAiCgl7CgkJImlkIgkJIjkiCgkJIm1vZGUiCQkiam95c3RpY2tfbW91c2Ui
CgkJImlucHV0cyIKCQl7CgkJfQoJCSJzZXR0aW5ncyIKCQl7CgkJCSJvdXRwdXRfam95c3RpY2si
CQkiMiIKCQl9Cgl9CgkiZ3JvdXAiCgl7CgkJImlkIgkJIjYiCgkJIm1vZGUiCQkic3dpdGNoZXMi
CgkJImlucHV0cyIKCQl7CgkJCSJidXR0b25fZXNjYXBlIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIK
CQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJ
CQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNzIEVTQ0FQRSIKCQkJCQkJfQoJCQkJCX0KCQkJCX0K
CQkJfQoJCQkiYnV0dG9uX21lbnUiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJCQkJewoJCQkJCSJG
dWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiYmluZGlu
ZyIJCSJrZXlfcHJlc3MgSSIKCQkJCQkJfQoJCQkJCX0KCQkJCX0KCQkJfQoJCQkibGVmdF9idW1w
ZXIiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJCQkJewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsK
CQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJCQkJCQkiYmluZGluZyIJCSJrZXlfcHJlc3MgMyIK
CQkJCQkJfQoJCQkJCX0KCQkJCX0KCQkJfQoJCQkicmlnaHRfYnVtcGVyIgoJCQl7CgkJCQkiYWN0
aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIK
CQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNzIDQiCgkJCQkJCX0KCQkJCQl9CgkJ
CQl9CgkJCX0KCQkJImJ1dHRvbl9iYWNrX2xlZnQiCgkJCXsKCQkJCSJhY3RpdmF0b3JzIgoJCQkJ
ewoJCQkJCSJGdWxsX1ByZXNzIgoJCQkJCXsKCQkJCQkJImJpbmRpbmdzIgoJCQkJCQl7CgkJCQkJ
CQkiYmluZGluZyIJCSJrZXlfcHJlc3MgVEFCIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJ
CSJidXR0b25fYmFja19yaWdodCIKCQkJewoJCQkJImFjdGl2YXRvcnMiCgkJCQl7CgkJCQkJIkZ1
bGxfUHJlc3MiCgkJCQkJewoJCQkJCQkiYmluZGluZ3MiCgkJCQkJCXsKCQkJCQkJCSJiaW5kaW5n
IgkJImtleV9wcmVzcyBYIgoJCQkJCQl9CgkJCQkJfQoJCQkJfQoJCQl9CgkJCSJidXR0b25fYmFj
a19sZWZ0X3VwcGVyIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVz
cyIKCQkJCQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5
X3ByZXNzIFIiCgkJCQkJCX0KCQkJCQl9CgkJCQl9CgkJCX0KCQkJImJ1dHRvbl9iYWNrX3JpZ2h0
X3VwcGVyIgoJCQl7CgkJCQkiYWN0aXZhdG9ycyIKCQkJCXsKCQkJCQkiRnVsbF9QcmVzcyIKCQkJ
CQl7CgkJCQkJCSJiaW5kaW5ncyIKCQkJCQkJewoJCQkJCQkJImJpbmRpbmciCQkia2V5X3ByZXNz
IExFRlRfQ09OVFJPTCIKCQkJCQkJfQoJCQkJCX0KCQkJCX0KCQkJfQoJCX0KCX0KCSJwcmVzZXQi
Cgl7CgkJImlkIgkJIjAiCgkJIm5hbWUiCQkiRGVmYXVsdCIKCQkiZ3JvdXBfc291cmNlX2JpbmRp
bmdzIgoJCXsKCQkJIjYiCQkic3dpdGNoIGFjdGl2ZSIKCQkJIjAiCQkiYnV0dG9uX2RpYW1vbmQg
YWN0aXZlIgoJCQkiMSIJCSJsZWZ0X3RyYWNrcGFkIGFjdGl2ZSIKCQkJIjIiCQkicmlnaHRfdHJh
Y2twYWQgYWN0aXZlIgoJCQkiMyIJCSJqb3lzdGljayBhY3RpdmUiCgkJCSI0IgkJImxlZnRfdHJp
Z2dlciBhY3RpdmUiCgkJCSI1IgkJInJpZ2h0X3RyaWdnZXIgYWN0aXZlIgoJCQkiOSIJCSJyaWdo
dF9qb3lzdGljayBhY3RpdmUiCgkJCSI3IgkJImRwYWQgYWN0aXZlIgoJCX0KCX0KCSJzZXR0aW5n
cyIKCXsKCQkibGVmdF90cmFja3BhZF9tb2RlIgkJIjAiCgkJInJpZ2h0X3RyYWNrcGFkX21vZGUi
CQkiMCIKCX0KfQo=
NEPTUNE_B64_EOF
  verify_sha256 "${vdf_tmp}" "${CONTROLLER_LAYOUT_SHA256}"

  python3 - "${vdf_tmp}" << 'DECK_LAYOUT_EOF'
import sys, os, struct

vdf_src = sys.argv[1]
home = os.path.expanduser("~")
userdata = os.path.join(home, ".local", "share", "Steam", "userdata")

if not os.path.isdir(userdata):
    print("  Steam userdata not found — controller layout skipped.")
    sys.exit(0)

with open(vdf_src, "rb") as f:
    layout_data = f.read()

deployed = 0
for uid in os.listdir(userdata):
    shortcuts_path = os.path.join(userdata, uid, "config", "shortcuts.vdf")
    if not os.path.isfile(shortcuts_path):
        continue
    with open(shortcuts_path, "rb") as f:
        data = f.read()
    # Find the Cluckers shortcut's appid in the binary VDF.
    exe_field = b"\x01exe\x00"
    appid_field = b"\x02appid\x00"
    offset = 0
    app_id = None
    while True:
        idx = data.find(exe_field, offset)
        if idx < 0:
            break
        str_start = idx + len(exe_field)
        str_end = data.find(b"\x00", str_start)
        if str_end < 0:
            break
        exe_path = data[str_start:str_end].decode("utf-8", errors="replace").lower()
        if "cluckers" in exe_path:
            region = data[:idx]
            aid_idx = region.rfind(appid_field)
            if aid_idx >= 0:
                val_start = aid_idx + len(appid_field)
                if val_start + 4 <= len(data):
                    app_id = struct.unpack_from("<I", data, val_start)[0]
            break
        offset = str_end + 1
    if app_id is None:
        continue
    deploy_dir = os.path.join(
        userdata, uid, "config", "controller_configs", "apps", str(app_id)
    )
    deploy_path = os.path.join(deploy_dir, "controller_neptune_config.vdf")
    if os.path.exists(deploy_path):
        print(f"  Controller layout already exists for uid {uid} — skipping.")
        continue
    os.makedirs(deploy_dir, exist_ok=True)
    with open(deploy_path, "wb") as f:
        f.write(layout_data)
    print(f"  OK: Deployed controller layout for uid {uid} (appid {app_id}).")
    deployed += 1

if deployed == 0:
    if app_id is None:
        print("  WARN: Cluckers shortcut not found in Steam — add it as a non-Steam game first.")
    else:
        print("  INFO: All found Steam accounts already have the controller layout template.")
DECK_LAYOUT_EOF

    rm -f "${vdf_tmp}"
  fi

  ok_msg "Game patches applied."
}
# Finds the best available Wine or Proton-GE binary on this system.
#
# Proton-GE is a community-built version of Proton (Valve's Windows-game
# compatibility layer) with additional patches and newer components than the
# version shipped with Steam. It typically provides better game compatibility
# and performance than the standard system Wine package.
#
# This function searches common install locations for Proton-GE (Steam,
# Lutris, and Bottles runner directories), picks the highest-version copy
# found, and verifies it can actually run before selecting it. Falls back
# to system Wine if no Proton-GE installation is found.
#
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/wine/detect.go
#
# Arguments:
#   $1  Name of the variable to receive the wine binary path.
#   $2  Name of the variable to receive a "true"/"false" is-Proton flag.
#   $3  Name of the variable to receive the tool name (e.g. "Proton-GE-9-5").
#   $4  Name of the variable to receive the wineserver binary path.
#   $5  Name of the variable to receive the proton script path.
#   $6  Name of the variable to receive a "true"/"false" is-SLR flag.
#
# Returns:
#   Always 0. Output is written to the named variables via nameref.
find_wine() {
  local -n _out_path=$1
  local -n _out_is_proton=$2
  local -n _out_tool_name=$3
  local -n _out_server=$4
  local -n _out_proton_script=$5
  local -n _out_is_slr=$6

  _out_path=""
  _out_is_proton="false"
  _out_tool_name="proton"
  _out_proton_script=""
  _out_is_slr="false"

  local search_dirs=(
    "/usr/share/steam/compatibilitytools.d"
    "/opt/proton-cachyos"
    "/opt/proton-cachyos-slr"
    "${HOME}/.steam/root/compatibilitytools.d"
    "${HOME}/.steam/steam/compatibilitytools.d"
    "${HOME}/.local/share/Steam/compatibilitytools.d"
    "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
    "${HOME}/snap/steam/common/.steam/steam/compatibilitytools.d"
    "${HOME}/.var/app/net.davidotek.pupgui2/data/Steam/compatibilitytools.d"
    "${HOME}/.local/share/Steam/steamapps/common/Proton - GE/compatibilitytools.d"
    "${HOME}/.local/share/lutris/runners/wine"
    "${HOME}/.local/share/bottles/runners"
  )

  if [[ -L "${HOME}/.steam/root" ]]; then
    search_dirs+=("$(readlink -f "${HOME}/.steam/root")/compatibilitytools.d")
  fi
  if [[ -L "${HOME}/.steam/steam" ]]; then
    search_dirs+=("$(readlink -f "${HOME}/.steam/steam")/compatibilitytools.d")
  fi

  local newest_proton=""
  local newest_version="00000-00000"
  local newest_script=""
  local newest_is_slr="false"

  local d p base major minor
  for d in "${search_dirs[@]}"; do
    if [[ ! -d "${d}" ]]; then continue; fi

    # 1. Check for common Proton and custom Wine prefixes
    # Use a broad glob to find GE-Proton, proton-cachyos, lutris-ge, etc.
    for p in "${d}"/GE-Proton* "${d}"/proton-cachyos* \
              "${d}"/proton-ge-custom "${d}"/lutris-* "${d}"/wine-ge-* "${d}"/Proton*; do
      local check_exe=""
      if [[ -f "${p}/files/bin/wine64" ]]; then
        check_exe="${p}/files/bin/wine64"
      elif [[ -f "${p}/bin/wine64" ]]; then
        check_exe="${p}/bin/wine64"
      fi

      if [[ -n "${check_exe}" ]] && [[ -x "${check_exe}" ]]; then
        base=$(basename "${p}")

        # Detect the companion 'proton' script. Official Valve Proton and many
        # community builds include this script to handle container initialization
        # (Steam Linux Runtime) and prefix setup.
        local proton_script=""
        local tool_root="${p}"
        if [[ -f "${tool_root}/proton" ]]; then
            proton_script="${tool_root}/proton"
        fi
        
        # Test if the Wine binary can actually run a simple command.
        # SLR builds fail outside Steam Runtime unless wrapped correctly.
        local env_adds bin_add lib_add loader_add
        env_adds=$(get_wine_env_additions "${check_exe}")
        bin_add="${env_adds%%|*}"; temp_adds="${env_adds#*|}"; 
        lib_add="${temp_adds%%|*}"; loader_add="${env_adds##*|}"
        
        local check_pfx
        check_pfx=$(mktemp -d /tmp/cluckers_pfx_check_XXXXXX)
        local can_run="false"
        local current_is_slr="false"

        # If a 'proton' script is present, mark this build as needing the wrapper.
        # This covers all Proton builds — whether they use the Steam Linux Runtime
        # container (SLR/Pressure Vessel) or run standalone. All are treated the
        # same: we use the 'proton run' script instead of calling wine directly.
        # GE-Proton, Proton-GE, proton-cachyos, and upstream Proton all qualify.
        if [[ -f "${proton_script}" ]]; then
          current_is_slr="true"
        fi

        local check_out="/dev/null"
        [[ "${VERBOSE_MODE:-false}" == "true" ]] && check_out="/dev/stderr"

        if env WINEPREFIX="${check_pfx}" \
           PATH="${bin_add}:${PATH}" \
           LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
           WINELOADER="${loader_add}" \
           WINEDLLOVERRIDES="mscoree,mshtml=" \
           DISPLAY="" \
           "${check_exe}" cmd.exe /c exit >"${check_out}" 2>&1; then
          can_run="true"
        elif [[ "${current_is_slr}" == "true" ]]; then
          # The Wine binary failed to run standalone, but a 'proton' script
          # exists. This is normal for container-based Proton builds (those
          # that rely on Steam Linux Runtime / Pressure Vessel). We still mark
          # them as usable because the 'proton run' wrapper handles everything.
          can_run="true"
        fi
        rm -rf "${check_pfx}" 2>/dev/null || true

        if [[ "${can_run}" == "true" ]]; then
          # Try to extract version from folder name or 'version' file.
          # Matches GE-ProtonX-Y, Proton-GE-X-Y, proton-cachyos, Proton 9.0, etc.
          local v_str=""
          if [[ "${base}" =~ ([0-9]+)\.([0-9]+) ]]; then
            # Matches "Proton 9.0", "Proton 8.0"
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            v_str=$(printf "%05d-%05d" "${major}" "${minor}")
          elif [[ "${base}" =~ ([0-9]+)-([0-9]+) ]]; then
            # Matches "GE-Proton9-20", "proton-cachyos-10-1"
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            v_str=$(printf "%05d-%05d" "${major}" "${minor}")
          elif [[ -f "${p}/version" ]]; then
            # Read version from Steam's 'version' file (e.g. "1712345678 proton-9.0-2")
            local v_file_content
            v_file_content=$(head -n1 "${p}/version" 2>/dev/null || true)
            if [[ "${v_file_content}" =~ ([0-9]+)\.([0-9]+) ]]; then
              major="${BASH_REMATCH[1]}"
              minor="${BASH_REMATCH[2]}"
              v_str=$(printf "%05d-%05d" "${major}" "${minor}")
            fi
          fi

          if [[ -n "${v_str}" ]]; then
            if [[ "${v_str}" > "${newest_version}" || -z "${newest_proton}" ]]; then
              newest_version="${v_str}"
              newest_proton="${check_exe}"
              newest_script="${proton_script}"
              newest_is_slr="${current_is_slr}"
            fi
          elif [[ -z "${newest_proton}" ]]; then
            # Fallback for builds without clear versioning.
            newest_proton="${check_exe}"
            newest_script="${proton_script}"
            newest_is_slr="${current_is_slr}"
          fi
        fi
      fi
    done
  done

  if [[ -n "${newest_proton}" ]] && [[ -x "${newest_proton}" ]]; then
    _out_path="${newest_proton}"
    _out_is_proton="true"
    _out_proton_script="${newest_script}"
    _out_is_slr="${newest_is_slr}"

    # Extract tool name for info message.
    local tool_dir
    tool_dir=$(dirname "$(dirname "${newest_proton}")")
    [[ "$(basename "${tool_dir}")" == "bin" || "$(basename "${tool_dir}")" == "files" ]] && tool_dir=$(dirname "${tool_dir}")
    _out_tool_name=$(basename "${tool_dir}")

    # Set the wineserver path associated with this Wine binary
    _out_server="$(dirname "${newest_proton}")/wineserver"
    [[ ! -x "${_out_server}" ]] && _out_server="wineserver"

    info_msg "Detected Proton build: ${_out_tool_name} (uses proton script: ${_out_is_slr})"
    [[ -n "${_out_proton_script}" ]] && info_msg "Proton script: ${_out_proton_script}"
    return 0
  fi

  # Check for system Wine and side-by-side installs
  local wine_candidates=(
    "wine64"
    "wine"
    "/opt/wine-cachyos/bin/wine64"
    "/opt/wine-cachyos/bin/wine"
    "/opt/wine-staging/bin/wine64"
    "/opt/wine-staging/bin/wine"
    "/usr/lib/wine/wine64"
    "/usr/lib/wine/wine"
  )

  local candidate path
  for candidate in "${wine_candidates[@]}"; do
    if [[ "${candidate}" == /* ]]; then
      path="${candidate}"
    else
      path=$(command -v "${candidate}" 2>/dev/null || true)
    fi

    if [[ -n "${path}" ]] && [[ -x "${path}" ]]; then
      # Verification test for system wine
      local env_adds bin_add lib_add loader_add
      env_adds=$(get_wine_env_additions "${path}")
      bin_add="${env_adds%%|*}"; temp_adds="${env_adds#*|}"; 
      lib_add="${temp_adds%%|*}"; loader_add="${env_adds##*|}"
      
      local check_pfx
      check_pfx=$(mktemp -d /tmp/cluckers_pfx_check_XXXXXX)
      if env WINEPREFIX="${check_pfx}" \
         PATH="${bin_add}:${PATH}" \
         LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
         WINELOADER="${loader_add}" \
         WINEDLLOVERRIDES="mscoree,mshtml=" \
         DISPLAY="" \
         "${path}" cmd.exe /c exit >/dev/null 2>&1; then
        rm -rf "${check_pfx}"
        _out_path="${path}"
        _out_tool_name="wine"
        _out_proton_script=""
        _out_is_slr="false"

        # Set the wineserver path associated with this Wine binary
        _out_server="$(dirname "${path}")/wineserver"
        [[ ! -x "${_out_server}" ]] && _out_server="wineserver"
        return 0
      else
        rm -rf "${check_pfx}"
      fi
    fi
  done

  return 1
}

# Parses command-line flags and runs all install steps in order.
#
# Arguments:
#   "$@" - Flags passed to the script.
#
# Returns:
#   0 on success; exits with error via error_exit() on failure.
main() {
  local verbose="false"
  local auto_mode="false"
  local use_gamescope="false"
  local steam_deck="false"
  local controller_mode="false"
  local resolved_version="${GAME_VERSION}"
  local VERSION_INFO_JSON=""
  local do_update="false"
  local WINETRICKS_BIN="winetricks"
  local GATEWAY_URL="${GATEWAY_URL:-https://gateway-dev.project-crown.com}"
  local CREDS_FILE="${CLUCKERS_ROOT}/credentials.enc"

  # Detect if the game EXE is in the current directory.
  # If found, we use the current directory as GAME_DIR and set relative path
  # to the EXE. This allows running the script from a manual game install.
  if [[ -f "ShippingPC-RealmGameNoEditor.exe" ]]; then
    GAME_DIR="$(pwd)"
    GAME_EXE_REL="ShippingPC-RealmGameNoEditor.exe"
    ok_msg "Found game EXE in current directory: ${GAME_EXE_REL}"
    ok_msg "Using current directory as GAME_DIR: ${GAME_DIR}"
  fi

  # Load saved preferences.
  local controller_pref_file="${GAME_DIR}/.controller_enabled"
  if [[ -f "${controller_pref_file}" ]]; then
    controller_mode="true"
  fi

  # Detected once early — available for Step 4 (DXVK decision) and
  # Step 8 (launcher creation). find_wine sets the variables passed as arguments.
  local _is_proton="false"
  local real_wine_path=""
  local real_wineserver="wineserver"
  local _proton_tool_name="proton"
  local real_proton_script=""
  local _is_slr="false"

  local arg
  for arg in "$@"; do
    case "${arg}" in
      --uninstall)
        printf "\n%b[WARN]%b This will permanently remove Cluckers Central, the Wine prefix,\n" \
          "${YELLOW}" "${NC}"
        printf "        all game files in ~/.cluckers, and Steam shortcuts.\n"
        printf "        This action cannot be undone.\n\n"
        printf "  Type 'yes' to confirm: "
        local _confirm=""
        read -r _confirm
        if [[ "${_confirm}" != "yes" ]]; then
          printf "  Uninstall cancelled.\n\n"
          exit 0
        fi
        run_uninstall; exit 0
        ;;
      --update|-u)       do_update="true" ;;
      --verbose|-v)      verbose="true" ;;
      --auto|-a)         auto_mode="true" ;;
      --gamescope|-g)    use_gamescope="true" ;;
      --no-gamescope)    use_gamescope="false" ;;
      # --gamescope-with-controller / -gc enables the Gamescope compositor AND
      # controller input support together in a single flag. Passing both -g and
      # -c separately has the same effect (detected after the argument loop).
      # This is the recommended mode for couch/TV setups on desktop Linux where
      # you want a cursor-locked fullscreen compositor and a working gamepad.
      # Steam Deck users: use --steam-deck / -d instead. SteamOS manages its
      # own Gamescope session and controller support automatically.
      --gamescope-with-controller|-gc)
        use_gamescope="true"
        controller_mode="true"
        ;;
      --steam-deck|-d)   steam_deck="true"; use_gamescope="false"; controller_mode="true" ;;
      --controller|-c)   controller_mode="true" ;;
      --no-controller)
        controller_mode="false"
        [[ -f "${controller_pref_file}" ]] && rm -f "${controller_pref_file}"
        ;;
      --help|-h)         print_help; exit 0 ;;
      *) warn_msg "Unknown flag ignored: '${arg}' (try --help for usage)" ;;
    esac
  done

  # If the user passed both --gamescope / -g and --controller / -c separately,
  # treat that as equivalent to --gamescope-with-controller / -gc. This means
  # you never have to remember the combined flag — -g -c just works.
  # We only apply this on non-Deck systems; Steam Deck manages its own compositor.
  if [[ "${use_gamescope}" == "true" ]] && [[ "${controller_mode}" == "true" ]] \
     && [[ "${steam_deck}" == "false" ]]; then
    : # Already in gamescope-with-controller mode — nothing extra needed.
  fi

  # Save preference if enabled.
  if [[ "${controller_mode}" == "true" ]]; then
    mkdir -p "${GAME_DIR}"
    touch "${controller_pref_file}"
  fi



  # Show the banner immediately so the user knows the script has started.
  # This must come before find_wine (which probes Wine binaries and can take
  # a few seconds), so there is no silent gap after pressing Enter.
  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║        Cluckers Central — Linux Setup Script         ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n\n" "${GREEN}" "${NC}"

  if [[ "${verbose}" == "true" ]]; then
    export WINEDEBUG=""
    export VERBOSE_MODE="true"
    set -x
    export CURL_FLAGS="-L"
    export CURL_SILENT=""
  else
    export WINEDEBUG="-all"
    export VERBOSE_MODE="false"
    export CURL_FLAGS="-sL"
    export CURL_SILENT="-s"
  fi

  # --------------------------------------------------------------------------
  # Gamescope Configuration
  # --------------------------------------------------------------------------
  if [[ "${use_gamescope}" == "true" ]]; then
    printf "Gamescope is enabled. We use '--force-grab-cursor' because it fixes\n"
    printf "the mouse bugging out (stuck/invisible) on many Linux setups.\n"
    if [[ "${controller_mode}" == "true" ]] && [[ "${steam_deck}" == "false" ]]; then
      printf "Controller support is also enabled (--gamescope-with-controller mode).\n"
      printf "SDL hints and the XInput remap DLL will be deployed for full gamepad support.\n"
    fi
    printf "\n"
    printf "Current flags: %s\n" "${GAMESCOPE_ARGS}"
    printf "Press ENTER to keep these, or type new flags: "
    local _new_gs_args=""
    read -r _new_gs_args
    if [[ -n "${_new_gs_args}" ]]; then
      GAMESCOPE_ARGS="${_new_gs_args}"
      ok_msg "Gamescope flags updated to: ${GAMESCOPE_ARGS}"
    fi
    printf "\n"
  fi

  # Auto-detect Steam Deck. If running on Deck hardware but -d was not passed,
  # warn the user so they know Deck-specific patches are available.
  if [[ "${steam_deck}" == "false" ]] && is_steam_deck; then
    warn_msg "Steam Deck detected (board_vendor=Valve)."
    warn_msg "Re-run with --steam-deck / -d to apply Deck-specific patches:"
    warn_msg "  • Fullscreen 1280x800  • Controller input fix  • Button layout"
    warn_msg "Example: ./cluckers-setup.sh -d"
    warn_msg "(Continuing without Deck patches...)"
    printf "\n"
  fi

  local skip_heavy_steps="false"
  if [[ "${do_update}" == "true" ]]; then
    run_update "${steam_deck}" "${controller_mode}"
    skip_heavy_steps="true"
  fi

  info_msg "Initialising — detecting Wine installation..."
  info_msg "(This may take a few seconds on first run while Wine is located.)"

  # Detect Wine/Proton once upfront — result is used in Step 3 (prefix),
  # Step 4 (DXVK), and Step 8 (launcher). find_wine sets the variables
  # passed as arguments.
  find_wine real_wine_path _is_proton _proton_tool_name real_wineserver real_proton_script _is_slr || true

  # Migrate old 'prefix' directory to 'pfx' if it exists.
  if [[ -d "${CLUCKERS_ROOT}/prefix" ]] && [[ ! -d "${WINEPREFIX}" ]]; then
    info_msg "Migrating Wine prefix from 'prefix' to 'pfx'..."
    mv "${CLUCKERS_ROOT}/prefix" "${WINEPREFIX}"
    ok_msg "Prefix migrated."
  fi

  # Proton tracks the compatdata schema version in ${CLUCKERS_ROOT}/version.
  # If an old system-Wine prefix already exists but this file does not,
  # Proton can fail during its initial prefix conversion (FileExistsError).
  # To avoid that hard failure, we preserve the legacy prefix as a backup and
  # let Proton build a clean pfx on first run.
  if [[ -n "${real_proton_script}" ]] && [[ -x "${real_proton_script}" ]] && \
     [[ -d "${WINEPREFIX}" ]] && [[ ! -f "${CLUCKERS_ROOT}/version" ]]; then
    info_msg "Proton version file missing — backing up existing prefix to avoid FileExistsError."
    info_msg "The prefix will be regenerated from the Proton template on next launch."
    mv "${WINEPREFIX}" "${WINEPREFIX}.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  # Maintenance Wine: used for winetricks and wineboot (prefix setup).
  # Container-based Proton builds (those that use the Steam Linux Runtime /
  # Pressure Vessel) cannot run wine directly without the container. For those,
  # we create thin wrapper scripts that call 'proton run' instead. This covers
  # GE-Proton, upstream Proton, and any other build with a 'proton' script.
  # Standalone Wine builds (system Wine, custom non-proton GE builds) are used
  # directly without any wrapper.
  local maint_wine="wine"
  local maint_server="wineserver"
  local is_proton_maint="false"

  # Use the detected Proton script if available (works for SLR and non-SLR).
  if [[ -n "${real_proton_script}" ]] && [[ -x "${real_proton_script}" ]]; then
    # For maintenance tasks (wineboot, winetricks) we MUST NOT call 'proton run'.
    # The 'proton' script launches the Steam Linux Runtime (pressure-vessel)
    # container, which requires Steam to be running and causes Steam to open
    # unexpectedly during install. This is wrong for setup tasks.
    #
    # Instead we call the Wine binary directly, with the Proton build's own
    # library paths prepended to LD_LIBRARY_PATH. This is the same approach
    # used by Heroic Games Launcher, Lutris, and Bottles for Proton maintenance.
    # The libraries in files/lib64 and files/lib provide the same DLLs/overrides
    # that the container would supply, so wineboot and winetricks work correctly.
    local proton_root
    proton_root="$(dirname "${real_proton_script}")"
    local proton_lib64="${proton_root}/files/lib64"
    local proton_lib="${proton_root}/files/lib"

    # Build the wrapper's LD_LIBRARY_PATH, prepending Proton's bundled libs so
    # that dlopen() picks up Proton's custom DXVK/VKD3D/FAudio/etc. over system
    # versions. This replicates what pressure-vessel does without the container.
    local proton_ld_path="${proton_lib64}:${proton_lib}"

    local wrapper_dir="${CLUCKERS_ROOT}/tools"
    mkdir -p "${wrapper_dir}"
    maint_wine="${wrapper_dir}/wine"

    cat << EOF > "${maint_wine}"
#!/usr/bin/env bash
# Maintenance Wine wrapper: calls Proton's wine64 binary directly, bypassing
# the Steam Linux Runtime container. This avoids launching Steam during setup.
export WINEPREFIX="\${WINEPREFIX}"
export LD_LIBRARY_PATH="${proton_ld_path}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WINEFSYNC=1
export WINEESYNC=1
exec "${real_wine_path}" "\$@"
EOF
    cp "${maint_wine}" "${wrapper_dir}/wine64"
    chmod +x "${maint_wine}" "${wrapper_dir}/wine64"

    # Wineserver wrapper: same direct-binary approach.
    maint_server="${wrapper_dir}/wineserver"
    cat << EOF > "${maint_server}"
#!/usr/bin/env bash
# Maintenance wineserver wrapper: direct binary, no SLR container.
export WINEPREFIX="\${WINEPREFIX}"
export LD_LIBRARY_PATH="${proton_ld_path}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WINEFSYNC=1
export WINEESYNC=1
exec "${real_wineserver}" "\$@"
EOF
    chmod +x "${maint_server}"

    is_proton_maint="true"
    info_msg "Using Proton Wine directly for maintenance (no SLR container): ${real_wine_path}"
    local maint_ver
    maint_ver=$("${real_wine_path}" --version 2>/dev/null || echo "unknown")
    info_msg "Maintenance Wine version: ${maint_ver}"
  elif [[ -n "${real_wine_path}" ]]; then
    # Use the detected Wine binary directly. All Proton builds that have a
    # 'proton' script are already handled above; this branch covers standalone
    # Wine builds (system Wine, custom GE builds without a proton script, etc.).
    maint_wine="${real_wine_path}"
    maint_server="${real_wineserver}"
    info_msg "Using Wine binary: ${real_wine_path}"
  else
    # Fallback to system Wine.
    if command_exists wine; then
      maint_wine=$(command -v wine)
      maint_server=$(command -v wineserver || echo "wineserver")
      info_msg "Falling back to system Wine for maintenance: ${maint_wine}"
    fi
  fi

  # --------------------------------------------------------------------------
  # Step 1 — System tools
  #
  # Detects your Linux distribution's package manager (apt for Ubuntu/Debian,
  # pacman for Arch, dnf for Fedora, zypper for openSUSE) and installs any
  # missing tools.
  #
  # Note: This step requires 'sudo' (administrator) privileges to install
  # system-wide tools like Wine.
  # --------------------------------------------------------------------------
  step_msg "Step 1 — Verifying system tools..."

  if [[ -e /dev/uinput ]] && [[ ! -w /dev/uinput ]]; then
    warn_msg "Access to /dev/uinput is restricted (systemd v258+ policy)."
    info_msg "Solution: sudo groupadd -r uinput && sudo usermod -aG uinput \$USER"
    info_msg "More info: https://gitlab.archlinux.org/archlinux/packaging/packages/systemd/-/issues/31"
  fi

  local pkg_mgr=""
  if   command_exists apt;    then pkg_mgr="apt"
  elif command_exists pacman; then pkg_mgr="pacman"
  elif command_exists dnf;    then pkg_mgr="dnf"
  elif command_exists zypper; then pkg_mgr="zypper"
  else
    error_exit "No supported package manager found (apt / pacman / dnf / zypper)."
  fi

  local -a extra_tools=()
  [[ "${use_gamescope}" == "true" ]] && extra_tools+=("gamescope")
  install_sys_deps "${pkg_mgr}" "${extra_tools[@]}"

  # Ensure winetricks is recent enough to know about vcrun2019 and dxvk 2.x.
  # Distro packages are often many months behind; we fetch the latest from the
  # official Winetricks GitHub repo so verb downloads use correct, live URLs.
  step_msg "Step 1b — Ensuring winetricks is up-to-date..."
  ensure_winetricks_fresh

  # ~/.local/bin is not in PATH by default on all distros. Add it now so the
  # launcher script we create in Step 12 can be found immediately.
  if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    export PATH="${HOME}/.local/bin:${PATH}"
    info_msg "Added ~/.local/bin to PATH for this session."
    info_msg "(Add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to ~/.bashrc to make it permanent.)"
  fi

  # Skip heavy steps (Steps 2-6) if we just performed an update.
  if [[ "${skip_heavy_steps}" == "false" ]]; then
    # --------------------------------------------------------------------------
    # Step 2 — Resolve game version
  #
  #   latest_version          — e.g. "0.36.2100.0"
  #   zip_url                 — direct URL to the game zip (~5.3 GB)
  #   zip_blake3              — BLAKE3 hash of the zip for integrity checking
  #   zip_size                — expected size in bytes
  #   gameversion_dat_path    — relative path to GameVersion.dat inside the zip
  #   gameversion_dat_blake3  — BLAKE3 hash of GameVersion.dat (used for update
  #                             detection — if this matches local, no download
  #                             is needed)
  #
  # Set GAME_VERSION=x.x.x.x on the command line to skip the server check and
  # use a specific build instead.
  # --------------------------------------------------------------------------
  step_msg "Step 2 — Resolving game version..."

  local zip_url=""
  local zip_blake3=""
  local dat_path_rel=""
  local dat_blake3=""

  if fetch_version_info; then
    local server_version
    server_version=$(parse_version_field "latest_version")
    zip_url=$(parse_version_field "zip_url")
    zip_blake3=$(parse_version_field "zip_blake3")
    dat_path_rel=$(parse_version_field "gameversion_dat_path")
    dat_blake3=$(parse_version_field "gameversion_dat_blake3")
    ok_msg "Server reports latest version: ${server_version}"

    if [[ "${resolved_version}" == "auto" ]]; then
      resolved_version="${server_version}"
      ok_msg "Using latest version: ${resolved_version}"
    else
      ok_msg "Using pinned version: ${resolved_version}"
      zip_url="https://updater.realmhub.io/builds/game-${resolved_version}.zip"
      zip_blake3=""
      dat_path_rel=""
      dat_blake3=""
    fi
  else
    warn_msg "Could not reach update server."
    if [[ "${resolved_version}" == "auto" ]]; then
      resolved_version="0.36.2100.0"
      warn_msg "Falling back to hardcoded version: ${resolved_version}"
    fi
    # resolved_version is either the hardcoded fallback above or was set from
    # GAME_VERSION env var, which was already validated as ^[0-9.]+$ by the
    # arg-parsing logic. Safe to interpolate directly into the URL.
    zip_url="https://updater.realmhub.io/builds/game-${resolved_version}.zip"
  fi

  # Validate resolved_version is a safe dotted-numeric string before it
  # is interpolated into any URL (covers both the server and offline paths).
  if [[ ! "${resolved_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error_exit "Resolved game version '${resolved_version}' is not a valid version string.
  Expected format: X.Y.Z.W (e.g. 0.36.2100.0). Aborting for safety."
  fi

  ok_msg "Game version: ${resolved_version}"

  # Validate the zip URL before use — reject anything not pointing to the
  # expected update host. Prevents a compromised version.json from redirecting
  # downloads to an attacker-controlled server.
  if [[ -n "${zip_url}" && ! "${zip_url}" =~ ^https://updater\.realmhub\.io/ ]]; then
    error_exit "Update server returned an unexpected download URL: '${zip_url}'
  Only https://updater.realmhub.io/ URLs are accepted. Aborting for safety."
  fi

  ok_msg "Download URL: ${zip_url}"

  is_game_up_to_date "${dat_path_rel}" "${dat_blake3}" || true

  # --------------------------------------------------------------------------
  # Step 3 — Create Wine prefix
  #
  # The Wine prefix is a self-contained fake-Windows installation. Think of it
  # as a virtual hard drive that only this game uses. It lives at
  # ~/.cluckers/prefix and is completely separate from any other Wine apps.
  #
  # 'wine wineboot' initialises the prefix (creates the fake registry, Program
  # Files, Windows directories, etc.). This takes about 30 seconds the first
  # time and is instant if the prefix already exists.
  # --------------------------------------------------------------------------
  step_msg "Step 3 — Initialising Wine prefix..."

  # If we are using Proton, ensure there are no conflicting real files
  # where Proton expects to place symlinks (e.g. iexplore.exe).
  # Proton will crash with FileExistsError if it can't create these symlinks.
  if [[ "${_is_proton}" == "true" ]] && [[ -d "${WINEPREFIX}/drive_c" ]]; then
    info_msg "Cleaning up existing prefix for Proton upgrade/use..."
    # Remove real files that should be symlinks in a Proton prefix.
    # We use a broad list of system files that Proton typically symlinks.
    find "${WINEPREFIX}/drive_c" -type f \( \
      -path "*/Internet Explorer/iexplore.exe" -o \
      -path "*/system32/notepad.exe" -o \
      -path "*/system32/winhlp32.exe" -o \
      -path "*/system32/winebrowser.exe" -o \
      -path "*/system32/wineconsole.exe" -o \
      -path "*/system32/winedbg.exe" -o \
      -path "*/system32/winefile.exe" -o \
      -path "*/system32/winemine.exe" -o \
      -path "*/system32/regedit.exe" -o \
      -path "*/system32/cmd.exe" -o \
      -path "*/system32/control.exe" \
    \) -not -type l -delete 2>/dev/null || true
  fi

  if [[ -d "${WINEPREFIX}/drive_c" ]]; then
    ok_msg "Wine prefix already exists at ${WINEPREFIX}."
  else
    info_msg "Creating Wine prefix at ${WINEPREFIX} (this takes ~30 seconds)..."
    mkdir -p "${WINEPREFIX}"

    # If we are using Proton, it's safer and faster to copy its bundled default_pfx
    # instead of running wineboot --init (which can hang with some Proton builds).
    local proton_template=""
    if [[ "${_is_proton}" == "true" ]]; then
      # find_wine resolves real_wine_path to something like .../Proton/files/bin/wine
      local proton_root
      proton_root="$(dirname "$(dirname "$(dirname "${real_wine_path}")")")"
      # Steam's Proton uses .../Proton/dist/share/default_pfx or .../Proton/files/share/default_pfx
      # The AUR proton-ge-custom-bin package uses files/share/default_pfx
      if [[ -d "${proton_root}/dist/share/default_pfx" ]]; then
        proton_template="${proton_root}/dist/share/default_pfx"
      elif [[ -d "${proton_root}/files/share/default_pfx" ]]; then
        proton_template="${proton_root}/files/share/default_pfx"
      elif [[ -d "${proton_root}/files/default_pfx" ]]; then
        proton_template="${proton_root}/files/default_pfx"
      elif [[ -d "${proton_root}/share/default_pfx" ]]; then
        proton_template="${proton_root}/share/default_pfx"
      elif [[ -d "${proton_root}/default_pfx" ]]; then
        proton_template="${proton_root}/default_pfx"
      fi
    fi

    if [[ -n "${proton_template}" ]]; then
      info_msg "Copying Proton prefix template from ${proton_template}..."
      cp -r "${proton_template}"/* "${WINEPREFIX}/"
    else

      # Suppress Wine GUI dialogs during prefix initialisation:
      #   DISPLAY=""                        — no X window for mono/gecko installers
      #   WINEDLLOVERRIDES=mscoree,mshtml=  — skip .NET and IE installers
      # env is used instead of inline VAR=value syntax because WINEPREFIX is
      # declared readonly and bash rejects inline re-assignment of readonly vars.
      local env_adds bin_add lib_add loader_add
      env_adds=$(get_wine_env_additions "${maint_wine}")
      bin_add="${env_adds%%|*}"; temp="${env_adds#*|}"; 
      lib_add="${temp%%|*}"; loader_add="${env_adds##*|}"
      env WINEPREFIX="${WINEPREFIX}" DISPLAY="" \
        PATH="${bin_add}:${PATH}" \
        LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        WINELOADER="${loader_add}" \
        WINEDLLOVERRIDES="mscoree,mshtml=" \
        WINE="${maint_wine}" WINESERVER="${maint_server}" \
        "${maint_wine}" wineboot --init || true
      # Stabilize the prefix — wait for all Wine children to exit cleanly.
      env WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
        PATH="${bin_add}:${PATH}" \
        LD_LIBRARY_PATH="${lib_add}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
        WINELOADER="${loader_add}" \
        "${maint_server}" -w || true
    fi
    ok_msg "Wine prefix created."
  fi

  # Install xinput1_3.dll into the Wine prefix system32 so Wine loads our
  # custom XInput remapper instead of the built-in stub when the game requests
  # XInput. This must happen AFTER wineboot has fully initialised the prefix.
  #
  # In a Proton prefix, drive_c/windows/system32 is a symlink to the real
  # Windows DLL directory inside the prefix. Copying into a symlink with plain
  # `cp` follows it and may fail with "not writing through dangling symlink" if
  # the link target does not yet exist. We resolve the real path with
  # `readlink -f` and copy directly into the resolved directory to avoid this.
  #
  # Wine resolves DLLs from the prefix system32 before its own built-in stubs,
  # so placing the remapper here ensures it intercepts all XInput calls.
  # Source: https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/xinput1_3/xinput_main.c
  if [[ "${controller_mode}" == "true" ]]; then
    local _xdll_src="${TOOLS_DIR}/xinput1_3.dll"
    local _wine_sys32_link="${WINEPREFIX}/drive_c/windows/system32"
    local _wine_sys32
    _wine_sys32=$(readlink -f "${_wine_sys32_link}" 2>/dev/null || echo "${_wine_sys32_link}")
    if [[ -f "${_xdll_src}" ]] && [[ -d "${_wine_sys32}" ]]; then
      cp -f "${_xdll_src}" "${_wine_sys32}/xinput1_3.dll" \
        && ok_msg "xinput1_3.dll placed in Wine system32 (${_wine_sys32})." \
        || warn_msg "Could not copy xinput1_3.dll into Wine system32 — controller remapping may not work."
    elif [[ -f "${_xdll_src}" ]]; then
      warn_msg "Wine system32 not yet initialised — xinput1_3.dll will be copied on next run."
    fi
  fi

  if [[ "${controller_mode}" == "true" ]]; then
    # Check that the user has read access to /dev/input/event* nodes.
    # Without this, Wine's SDL layer cannot enumerate the controller and it
    # will appear invisible to the game regardless of other settings.
    # The standard fix is to be a member of the 'input' group.
    # Source: https://wiki.archlinux.org/title/Gamepad#Setting_up_a_gamepad
    local _event_found="false"
    local _event_readable="false"
    local _ev
    for _ev in /dev/input/event*; do
      [[ -e "${_ev}" ]] || continue
      _event_found="true"
      [[ -r "${_ev}" ]] && { _event_readable="true"; break; }
    done
    if [[ "${_event_found}" == "false" ]]; then
      warn_msg "No /dev/input/event* nodes found — controller may not be connected."
    elif [[ "${_event_readable}" == "false" ]]; then
      warn_msg "You may not have read access to /dev/input/event* devices."
      warn_msg "Fix: sudo usermod -aG input \$USER  (then log out and back in)"
      warn_msg "Source: https://wiki.archlinux.org/title/Gamepad#Setting_up_a_gamepad"
    fi

    # Suggest SDL_GameControllerDB if not already installed.
    # This community database provides correct button mappings for thousands
    # of controllers, fixing mis-mapped triggers, bumpers, and face buttons
    # under Wine's SDL layer. Highly recommended for any non-Xbox controller.
    # Source: https://github.com/gabomdq/SDL_GameControllerDB
    local _sdl_db_found="false"
    for _db_path in \
      "${HOME}/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "${HOME}/.config/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "/usr/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
      "/usr/local/share/SDL_GameControllerDB/gamecontrollerdb.txt"; do
      if [[ -f "${_db_path}" ]]; then
        _sdl_db_found="true"
        ok_msg "SDL GameControllerDB found at ${_db_path} — will be loaded by launcher."
        break
      fi
    done
    if [[ "${_sdl_db_found}" == "false" ]]; then
      info_msg "Tip: Install SDL_GameControllerDB for correct controller button mappings:"
      info_msg "  mkdir -p ~/.local/share/SDL_GameControllerDB"
      info_msg "  curl -L https://raw.githubusercontent.com/gabomdq/SDL_GameControllerDB/master/gamecontrollerdb.txt \\"
      info_msg "       -o ~/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt"
      info_msg "Source: https://github.com/gabomdq/SDL_GameControllerDB"
    fi

    info_msg "Applying WineBus SDL mapping for controllers..."
    # Configure Wine's controller input backend to use SDL2 instead of hidraw.
    #
    # Wine can talk to controllers in two ways: through "hidraw" (a Linux kernel
    # interface that reads raw USB data) or through SDL2 (a cross-platform game
    # library with built-in controller support). When both are active at the same
    # time, the controller appears twice to the game — once from hidraw and once
    # from SDL2. Unreal Engine 3 adds both sets of axis events together, resulting
    # in phantom camera spin where the camera rotates by itself even without
    # touching the stick.
    #
    # DisableHidraw=1 — tells Wine's winebus.sys driver to stop reading the
    #   controller through the hidraw kernel interface, eliminating the duplicate.
    # EnableSDL=1 — tells Wine to use the SDL2 library as the sole controller
    #   input source, which correctly maps axes, buttons, and triggers.
    #
    # These are registry keys read by Wine's controller driver (winebus.sys).
    # Source: https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/winebus.sys/main.c
    #         (options.disable_hidraw ~line 518, options.disable_sdl ~line 541)
    local winebus_key
    winebus_key="HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus"
    env DISPLAY="" WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
      "${maint_wine}" reg add "${winebus_key}" \
      /v DisableHidraw /t REG_DWORD /d 1 /f 2>/dev/null || true
    env DISPLAY="" WINEPREFIX="${WINEPREFIX}" WINESERVER="${maint_server}" \
      "${maint_wine}" reg add "${winebus_key}" \
      /v EnableSDL /t REG_DWORD /d 1 /f 2>/dev/null || true
    # Wait for wineserver to finish processing registry writes before continuing.
    env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -w 2>/dev/null || true
    env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true
  fi

  # --------------------------------------------------------------------------
  # Step 4 — Windows runtime libraries
  #
  # The game is a Windows program running inside Wine on Linux. Wine provides
  # a compatibility layer that translates Windows system calls to Linux, but it
  # does not include the C++ standard library DLLs or the DirectX graphics
  # libraries that the game was compiled against. Those must be installed
  # separately into the Wine prefix — that is what this step does.
  #
  # Think of it like this: if you took a Windows game and tried to run it on a
  # fresh Windows install without the Visual C++ Redistributable packages, it
  # would fail to start with a "DLL not found" error. The same is true here.
  #
  # Each package is checked before downloading. If it is already installed
  # (from a previous run, or by Proton), the download is skipped entirely.
  #
  # vcrun2010  Visual C++ 2010 runtime (msvcp100.dll, msvcr100.dll).
  #            The core Unreal Engine 3 code was compiled with Microsoft Visual
  #            Studio 2010 and requires these DLLs at startup. Missing them
  #            causes the game to crash immediately with a "DLL not found" error.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2010 installed_file1=mfc100.dll
  #
  # vcrun2012  Visual C++ 2012 runtime (msvcp110.dll, msvcr110.dll).
  #            The game's networking and audio subsystems were compiled with a
  #            newer toolchain than the engine core and require these DLLs.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2012 installed_file1=mfc110.dll
  #
  # vcrun2019  Visual C++ 2015-2019 runtime (msvcp140.dll, vcruntime140.dll,
  #            vcruntime140_1.dll). The game launcher and EAC anti-cheat system
  #            require these DLLs. We install vcrun2019 rather than vcrun2022
  #            because vcrun2022 bundles extra localised MFC resource DLLs
  #            (mfc140chs.dll, mfc140deu.dll, etc.) that the game does not need,
  #            adding unnecessary download size. Both versions provide the same
  #            core runtime DLLs that matter.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata vcrun2019 installed_file1=vcruntime140.dll
  #
  # dxvk       Vulkan-based Direct3D implementation for Wine. Replaces Wine's
  #            built-in Direct3D 11 with a high-performance Vulkan translation
  #            layer. This dramatically improves frame rate and reduces CPU usage
  #            compared to Wine's own Direct3D implementation. Requires a
  #            Vulkan-capable GPU: NVIDIA (driver ≥ 470), AMD (Mesa ≥ 21.x),
  #            or Intel (ANV Vulkan driver).
  #            Source: https://github.com/doitsujin/dxvk
  #
  # d3dx11_43  A DirectX 11 helper DLL (d3dx11_43.dll) used by the game's
  #            shader compilation system at startup. Without it, the game may
  #            fail to load shaders and render incorrectly or not at all.
  #            Source: https://github.com/Winetricks/winetricks/blob/master/src/winetricks
  #                    w_metadata d3dx11_43 installed_file1=d3dx11_43.dll
  # --------------------------------------------------------------------------
  step_msg "Step 4 — Configuring Windows runtime environment..."

  # Kill any orphaned wineserver from previous steps before running winetricks.
  env WINEPREFIX="${WINEPREFIX}" "${maint_server}" -k 2>/dev/null || true

  install_winetricks_multi \
    "Windows runtime environment" \
    "${maint_wine}" \
    "${maint_server}" \
    "${auto_mode}" \
    "vcrun2010" "vcrun2012" "vcrun2019" "dxvk" "d3dx11_43"

  # --------------------------------------------------------------------------
  # Step 5 — Synchronizing game content
  #
  # Downloads the game zip (~5.3 GB) from the update server with resume
  # support (if a previous download was interrupted it continues from where
  # it stopped). After download the BLAKE3 hash is verified against the
  # value from version.json to confirm the download is intact.
  # --------------------------------------------------------------------------
  step_msg "Step 5 — Synchronizing game content..."

  mkdir -p "${GAME_DIR}"

  # Verify that the game directory is writable before attempting a multi-GB
  # download. A read-only or permission-denied directory causes a confusing
  # failure deep into the download rather than a clear error up front.
  # Common causes: the directory was created as root, or lives on a read-only
  # mount (e.g. an NTFS drive mounted without write permissions).
  if [[ ! -w "${GAME_DIR}" ]]; then
    error_exit "Game directory is not writable: ${GAME_DIR}
  Fix with: chmod u+w \"${GAME_DIR}\"
  Or check that the filesystem is mounted with write permissions."
  fi

  # Also verify that the parent filesystem is not mounted read-only.
  if ! touch "${GAME_DIR}/.write_test" 2>/dev/null; then
    error_exit "Cannot write to game directory: ${GAME_DIR}
  The filesystem may be mounted read-only. Check: mount | grep \$(df -P \"${GAME_DIR}\" | tail -1 | awk '{print \$1}')"
  fi
  rm -f "${GAME_DIR}/.write_test"

  local local_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
  if [[ -f "${local_game_exe}" ]]; then
    ok_msg "Game files already present at ${GAME_DIR} — skipping synchronization."
  else
    info_msg "Downloading game zip from ${zip_url}"
    info_msg "(This is ~5.3 GB — it may take a while on slower connections.)"
    info_msg "If interrupted, re-run the script to resume from where it stopped."

    local zip_path="${GAME_DIR}/game.zip"

    parallel_download "${zip_url}" "${zip_path}" \
      || error_exit "Game download failed. Check your internet connection."

    ok_msg "Download complete."

    # Verify BLAKE3 hash using Python (bash has no native BLAKE3 support).
    if [[ -n "${zip_blake3}" ]]; then
      info_msg "Verifying BLAKE3 integrity of game zip..."
      local actual_blake3
      actual_blake3=$(python3 - "${zip_path}" << 'BLAKE3EOF'
import sys
try:
    from blake3 import blake3 as b3
    fn = sys.argv[1]
    h = b3()
    with open(fn, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    print(h.hexdigest())
except ImportError:
    # blake3 module not available — skip verification
    print("skip")
BLAKE3EOF
      ) || actual_blake3="skip"

      if [[ "${actual_blake3}" == "skip" ]]; then
        warn_msg "blake3 Python module not installed — skipping BLAKE3 verification."
        warn_msg "Install with: pip install blake3"
      elif [[ "${actual_blake3}" != "${zip_blake3}" ]]; then
        rm -f "${zip_path}"
        error_exit "BLAKE3 mismatch — game zip may be corrupt.
  Expected: ${zip_blake3}
  Got:      ${actual_blake3}
  Re-run the script to re-download."
      else
        ok_msg "BLAKE3 integrity verified."
      fi
    fi

    # Extract the zip.
    info_msg "Extracting game files (this may take several minutes)..."
    if command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "${zip_path}" -C "${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    elif command -v 7z >/dev/null 2>&1; then
      7z x -y "${zip_path}" -o"${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    else
      UNZIP_DISABLE_ZIPBOMB_DETECTION=TRUE unzip -o "${zip_path}" -d "${GAME_DIR}" \
        || error_exit "Extraction failed. Try re-running to re-download."
    fi
    rm -f "${zip_path}"
    ok_msg "Game files extracted to ${GAME_DIR}"
  fi

  # --------------------------------------------------------------------------
  # Step 6 — Install helper binaries (shm_launcher.exe + xinput1_3.dll)
  #
  # Two small Windows helper binaries are required for full game functionality:
  #
  # shm_launcher.exe
  #   Creates a named Windows shared memory (IPC) region and copies the content
  #   bootstrap blob into it before launching the game executable. The game
  #   reads this region at startup via OpenFileMapping(). Without it the game
  #   starts but may not receive the bootstrap payload needed for EAC.
  #   Compile: x86_64-w64-mingw32-gcc -O2 -Wall -municode \
  #              -o shm_launcher.exe shm_launcher.c
  #   Note: -municode is required because the entry point is wmain() not main().
  #
  # xinput1_3.dll
  #   A drop-in replacement for the system XInput DLL that remaps controller
  #   input so all buttons (triggers, bumpers, face buttons) work correctly
  #   under Wine/Proton. Installed into the Wine prefix system32 folder so
  #   Wine loads it instead of the built-in stub.
  #   Compile: x86_64-w64-mingw32-gcc -O2 -Wall -shared \
  #              -o xinput1_3.dll xinput_remap.c xinput1_3.def
  #
  # REPRODUCIBLE BUILDS
  #   The base64 binaries embedded below were compiled from the C source code
  #   included in this script (see SOURCE CODE sections immediately below).
  #   You can reproduce the exact same binaries — and verify they match the
  #   embedded checksums — without trusting any pre-built binary from us or
  #   any third party. This protects against upstream supply-chain tampering.
  #
  #   WHY THIS MATTERS
  #   ─────────────────
  #   The binaries embedded in this script are small Windows helpers that run
  #   inside your Wine prefix. If a bad actor modified the upstream repository
  #   or the script itself, a reproducible build lets you detect that: your
  #   locally compiled binary will produce a different SHA-256 than the one
  #   embedded here, and the script will refuse to deploy it.
  #
  #   STEP-BY-STEP INSTRUCTIONS
  #   ──────────────────────────
  #   1. Install the MinGW cross-compiler on Ubuntu 24.04 LTS or Debian 12:
  #
  #        sudo apt-get update
  #        sudo apt-get install -y gcc-mingw-w64-x86-64
  #
  #      This installs exactly:
  #        x86_64-w64-mingw32-gcc (GCC) 13-win32 (version 13.2.0)
  #
  #   2. Save the source files from the SOURCE CODE sections below.
  #      You can extract them directly from this script with:
  #
  #        sed -n '/SOURCE CODE: shm_launcher.c/,/SOURCE CODE: xinput_remap.c/p' \
  #            cluckers-setup.sh | grep '^#   ' | sed 's/^#   //' \
  #            | head -n -1 > shm_launcher.c
  #
  #        sed -n '/SOURCE CODE: xinput_remap.c/,/SOURCE CODE: xinput1_3.def/p' \
  #            cluckers-setup.sh | grep '^#   ' | sed 's/^#   //' \
  #            | head -n -1 > xinput_remap.c
  #
  #        sed -n '/SOURCE CODE: xinput1_3.def/,/^  # =\{10\}/p' \
  #            cluckers-setup.sh | grep '^#   ' | sed 's/^#   //' \
  #            | head -n -1 > xinput1_3.def
  #
  #      Alternatively, download the canonical sources directly from GitHub:
  #        https://github.com/0xc0re/cluckers/blob/master/tools/shm_launcher.c
  #        https://github.com/0xc0re/cluckers/blob/master/tools/xinput_remap.c
  #        https://github.com/0xc0re/cluckers/blob/master/tools/xinput1_3.def
  #
  #   3. Compile using the exact flags below (flags affect binary output):
  #
  #        x86_64-w64-mingw32-gcc -O2 -Wall -municode \
  #            -o shm_launcher.exe shm_launcher.c
  #
  #        x86_64-w64-mingw32-gcc -O2 -Wall -shared \
  #            -o xinput1_3.dll xinput_remap.c xinput1_3.def
  #
  #      Note: -municode is required for shm_launcher because its entry point
  #      is wmain() (wide-character Unicode), not the standard main().
  #
  #   4. Verify the SHA-256 checksums of your compiled binaries:
  #
  #        sha256sum shm_launcher.exe xinput1_3.dll
  #
  #      Expected output (must match exactly — byte for byte):
  #        f7dfcbcd2f70089696267ad7c725adeddf4b677c79bfd4e0c3435f800ee40f41  shm_launcher.exe
  #        30c2cf5d35fb7489779ac6fa714c6f874868d58ec2e5f6623d9dd5a24ae503a9  xinput1_3.dll
  #
  #      If the checksums match, your compiled binary is identical to the one
  #      embedded in this script — confirming the source was not tampered with.
  #      If they do NOT match, do not use the embedded binary; report the
  #      discrepancy at https://github.com/0xc0re/cluckers/issues
  #
  #   5. (Optional) Replace the embedded binaries with your own compiled ones:
  #
  #        base64 -w0 shm_launcher.exe > shm_launcher.b64
  #        base64 -w0 xinput1_3.dll   > xinput1_3.b64
  #
  #      Then replace the base64 blocks in this script between the heredoc
  #      markers (SHM_LAUNCHER_B64EOF / XINPUT_B64EOF) with the contents of
  #      the .b64 files. Update the SHA-256 constants at the top of the script
  #      (SHM_LAUNCHER_SHA256 / XINPUT_DLL_SHA256) to match.
  #
  #   Compiler Environment: Ubuntu 24.04 LTS or Debian 12 (recommended)
  #   Compiler Version:     x86_64-w64-mingw32-gcc (GCC) 13-win32 (13.2.0)
  #   Source Repository:    https://github.com/0xc0re/cluckers/tree/main/tools
  #
  # ==============================================================================
  # SOURCE CODE: shm_launcher.c (https://github.com/0xc0re/cluckers/blob/master/tools/shm_launcher.c)
  # ==============================================================================
#   /*
#    * shm_launcher.c - Creates a named shared memory section with content bootstrap
#    * data, then launches the game executable. The game expects to find the bootstrap
#    * via OpenFileMapping() using the name passed in -content_bootstrap_shm=.
#    *
#    * Build: x86_64-w64-mingw32-gcc -o shm_launcher.exe shm_launcher.c
#    * Usage: shm_launcher.exe <bootstrap_file> <shm_name> <game_exe> [game_args...]
#    *
#    * The launcher:
#    *   1. Reads bootstrap data from <bootstrap_file>
#    *   2. Creates a named file mapping called <shm_name>
#    *   3. Copies the bootstrap data into the mapping
#    *   4. Launches <game_exe> with the remaining arguments
#    *   5. Waits for the game to exit
#    *   6. Cleans up the mapping
#    */
#
#   #include <windows.h>
#   #include <stdio.h>
#
#   int wmain(int argc, wchar_t *argv[]) {
#       if (argc < 4) {
#           fprintf(stderr, "Usage: shm_launcher.exe <bootstrap_file> <shm_name> <game_exe> [game_args...]\n");
#           return 1;
#       }
#
#       wchar_t *bootstrap_file = argv[1];
#       wchar_t *shm_name = argv[2];
#       wchar_t *game_exe = argv[3];
#
#       /* Read bootstrap data from file */
#       HANDLE hFile = CreateFileW(bootstrap_file, GENERIC_READ, FILE_SHARE_READ,
#                                  NULL, OPEN_EXISTING, 0, NULL);
#       if (hFile == INVALID_HANDLE_VALUE) {
#           fprintf(stderr, "Failed to open bootstrap file (err=%lu)\n", GetLastError());
#           return 1;
#       }
#
#       DWORD fileSize = GetFileSize(hFile, NULL);
#       if (fileSize == INVALID_FILE_SIZE || fileSize == 0) {
#           fprintf(stderr, "Invalid bootstrap file size (err=%lu)\n", GetLastError());
#           CloseHandle(hFile);
#           return 1;
#       }
#
#       BYTE *data = (BYTE *)malloc(fileSize);
#       if (!data) {
#           fprintf(stderr, "malloc failed\n");
#           CloseHandle(hFile);
#           return 1;
#       }
#
#       DWORD bytesRead;
#       if (!ReadFile(hFile, data, fileSize, &bytesRead, NULL) || bytesRead != fileSize) {
#           fprintf(stderr, "Failed to read bootstrap file (err=%lu)\n", GetLastError());
#           free(data);
#           CloseHandle(hFile);
#           return 1;
#       }
#       CloseHandle(hFile);
#
#       printf("[shm_launcher] Bootstrap data: %lu bytes\n", fileSize);
#
#       /* Create named shared memory */
#       HANDLE hMapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
#                                            0, fileSize, shm_name);
#       if (!hMapping) {
#           fprintf(stderr, "CreateFileMapping failed (err=%lu)\n", GetLastError());
#           free(data);
#           return 1;
#       }
#
#       LPVOID pView = MapViewOfFile(hMapping, FILE_MAP_WRITE, 0, 0, fileSize);
#       if (!pView) {
#           fprintf(stderr, "MapViewOfFile failed (err=%lu)\n", GetLastError());
#           CloseHandle(hMapping);
#           free(data);
#           return 1;
#       }
#
#       memcpy(pView, data, fileSize);
#       free(data);
#
#       printf("[shm_launcher] Shared memory '%ls' created (%lu bytes)\n", shm_name, fileSize);
#
#       /* Build command line for the game */
#       wchar_t cmdline[32768];
#       int pos = 0;
#
#       /* Quote the exe path */
#       pos += swprintf(cmdline + pos, sizeof(cmdline)/sizeof(wchar_t) - pos, L"\"%ls\"", game_exe);
#
#       /* Append remaining args */
#       for (int i = 4; i < argc; i++) {
#           pos += swprintf(cmdline + pos, sizeof(cmdline)/sizeof(wchar_t) - pos, L" %ls", argv[i]);
#       }
#
#       printf("[shm_launcher] Launching: %ls\n", cmdline);
#
#       /* Launch the game */
#       STARTUPINFOW si = { .cb = sizeof(si) };
#       PROCESS_INFORMATION pi = {0};
#
#       if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
#           fprintf(stderr, "CreateProcess failed (err=%lu)\n", GetLastError());
#           UnmapViewOfFile(pView);
#           CloseHandle(hMapping);
#           return 1;
#       }
#
#       printf("[shm_launcher] Game started (pid=%lu), waiting...\n", pi.dwProcessId);
#
#       /* Wait for game to exit */
#       WaitForSingleObject(pi.hProcess, INFINITE);
#
#       DWORD exitCode = 0;
#       GetExitCodeProcess(pi.hProcess, &exitCode);
#       printf("[shm_launcher] Game exited with code %lu\n", exitCode);
#
#       /* Cleanup */
#       CloseHandle(pi.hThread);
#       CloseHandle(pi.hProcess);
#       UnmapViewOfFile(pView);
#       CloseHandle(hMapping);
#
#       return (int)exitCode;
#   }
  # ==============================================================================
  # SOURCE CODE: xinput_remap.c (https://github.com/0xc0re/cluckers/blob/master/tools/xinput_remap.c)
  # ==============================================================================
#   #include <windows.h>
#   #include <stdio.h>
#
#   /*
#    * XInput index remapping proxy for UE3 games on Wine.
#    *
#    * Problem: UE3 reserves XInput index 0 for keyboard, polls indices 1-3.
#    *          Wine assigns the controller to XInput index 0.
#    * Fix:     Remap game's index N -> real index N-1.
#    *
#    * Tries xinput1_4, xinput9_1_0, xinput1_2, xinput1_1 as backends.
#    */
#
#   typedef DWORD (WINAPI *pfn_XInputGetState)(DWORD, void*);
#   typedef DWORD (WINAPI *pfn_XInputGetCapabilities)(DWORD, DWORD, void*);
#   typedef DWORD (WINAPI *pfn_XInputSetState)(DWORD, void*);
#   typedef void  (WINAPI *pfn_XInputEnable)(BOOL);
#
#   static HMODULE hReal = NULL;
#   static pfn_XInputGetState pGetState = NULL;
#   static pfn_XInputGetCapabilities pGetCaps = NULL;
#   static pfn_XInputSetState pSetState = NULL;
#   static pfn_XInputEnable pEnable = NULL;
#   static BOOL initialized = FALSE;
#   static CRITICAL_SECTION g_initLock;
#   static BOOL g_lockReady = FALSE;
#   static FILE *logf = NULL;
#   static int n = 0;
#
#   static void proxy_init(void) {
#       if (initialized) return;
#       if (g_lockReady) EnterCriticalSection(&g_initLock);
#       if (initialized) { if (g_lockReady) LeaveCriticalSection(&g_initLock); return; }
#
#       logf = fopen("Z:\\tmp\\xinput_remap.log", "w");
#
#       /* Try multiple xinput DLL variants as backends */
#       static const wchar_t *dlls[] = {
#           L"xinput1_4.dll",
#           L"xinput9_1_0.dll",
#           L"xinput1_2.dll",
#           L"xinput1_1.dll",
#           NULL
#       };
#
#       for (int i = 0; dlls[i]; i++) {
#           hReal = LoadLibraryW(dlls[i]);
#           if (hReal) {
#               pGetState = (pfn_XInputGetState)GetProcAddress(hReal, "XInputGetState");
#               if (pGetState) {
#                   /* Test if this DLL actually sees a controller at index 0 */
#                   BYTE state[64];
#                   ZeroMemory(state, sizeof(state));
#                   DWORD r = pGetState(0, state);
#                   if (logf) fprintf(logf, "REMAP: %ls loaded, GetState(0)=%lu\n", dlls[i], r);
#                   if (r == 0) {
#                       /* Found a working backend */
#                       pGetCaps = (pfn_XInputGetCapabilities)GetProcAddress(hReal, "XInputGetCapabilities");
#                       pSetState = (pfn_XInputSetState)GetProcAddress(hReal, "XInputSetState");
#                       pEnable = (pfn_XInputEnable)GetProcAddress(hReal, "XInputEnable");
#                       if (logf) { fprintf(logf, "REMAP: Using %ls as backend (controller at index 0)\n", dlls[i]); fflush(logf); }
#                       break;
#                   }
#               }
#               FreeLibrary(hReal);
#               hReal = NULL;
#               pGetState = NULL;
#           } else {
#               if (logf) fprintf(logf, "REMAP: Failed to load %ls (err=%lu)\n", dlls[i], GetLastError());
#           }
#       }
#
#       if (!hReal && logf) { fprintf(logf, "REMAP: No working backend found!\n"); fflush(logf); }
#
#       initialized = TRUE;
#       if (g_lockReady) LeaveCriticalSection(&g_initLock);
#   }
#
#   /* Remap: game's 1->0, 2->1, 3->2. Index 0 stays 0. */
#   static DWORD remap(DWORD idx) {
#       if (idx >= 1 && idx <= 3) return idx - 1;
#       return idx;
#   }
#
#   __declspec(dllexport) DWORD WINAPI XInputGetState(DWORD idx, void *state) {
#       proxy_init();
#       if (!pGetState) return 0x48F;
#       DWORD real_idx = remap(idx);
#       DWORD r = pGetState(real_idx, state);
#       n++;
#       if (logf && r == 0 && (n <= 50 || n % 500 == 0)) {
#           /* Log actual state data to verify controller values reach the game.
#            * XINPUT_STATE layout: DWORD packet, WORD buttons, BYTE LT, BYTE RT,
#            *                      SHORT LX, SHORT LY, SHORT RX, SHORT RY */
#           BYTE *s = (BYTE*)state;
#           WORD btns = *(WORD*)(s+4);
#           SHORT lx = *(SHORT*)(s+8);
#           SHORT ly = *(SHORT*)(s+10);
#           SHORT rx = *(SHORT*)(s+12);
#           SHORT ry = *(SHORT*)(s+14);
#           fprintf(logf, "GetState(%lu->%lu)=%lu btns=%04X LX=%d LY=%d RX=%d RY=%d [#%d]\n",
#                   idx, real_idx, r, btns, lx, ly, rx, ry, n);
#           fflush(logf);
#       }
#       return r;
#   }
#
#   __declspec(dllexport) DWORD WINAPI XInputGetCapabilities(DWORD idx, DWORD flags, void *caps) {
#       proxy_init();
#       if (!pGetCaps) return 0x48F;
#       return pGetCaps(remap(idx), flags, caps);
#   }
#
#   __declspec(dllexport) DWORD WINAPI XInputSetState(DWORD idx, void *vib) {
#       proxy_init();
#       if (!pSetState) return 0x48F;
#       return pSetState(remap(idx), vib);
#   }
#
#   /*
#    * XInputEnable(FALSE) no-op:
#    * UE3 calls XInputEnable(FALSE) on WM_ACTIVATEAPP when the window loses focus
#    * during ServerTravel map transitions (lobby -> match). Wine's compliant
#    * implementation zeros all XInput state data, causing invisible controller
#    * input loss for the entire match. This is the same pattern fixed in Proton
#    * 8.0-4 for Overwatch 2. We block FALSE to prevent disabling, but forward
#    * TRUE (harmless, keeps state consistent).
#    */
#   __declspec(dllexport) void WINAPI XInputEnable(BOOL e) {
#       proxy_init();
#       if (logf) { fprintf(logf, "XInputEnable(%d) called at n=%d\n", e, n); fflush(logf); }
#       if (e == FALSE) {
#           if (logf) { fprintf(logf, "BLOCKED XInputEnable(FALSE) - preventing UE3 ServerTravel input loss\n"); fflush(logf); }
#           return;
#       }
#       if (pEnable) pEnable(e);
#   }
#
#   __declspec(dllexport) DWORD WINAPI XInputGetStateEx(DWORD idx, void *state) {
#       return XInputGetState(idx, state);
#   }
#
#   BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID res) {
#       (void)h; (void)res;
#       /* Do NOT call proxy_init here - LoadLibrary inside DllMain causes loader lock deadlock */
#       if (reason == 1) {
#           /* DLL_PROCESS_ATTACH: initialize critical section for thread-safe proxy_init */
#           InitializeCriticalSection(&g_initLock);
#           g_lockReady = TRUE;
#       }
#       if (reason == 0) {
#           /* DLL_PROCESS_DETACH: clean up */
#           if (logf) { fprintf(logf, "REMAP: unloading after %d calls\n", n); fclose(logf); }
#           if (g_lockReady) { DeleteCriticalSection(&g_initLock); g_lockReady = FALSE; }
#       }
#       return TRUE;
#   }
  # ==============================================================================
  # SOURCE CODE: xinput1_3.def  (https://github.com/0xc0re/cluckers/blob/master/tools/xinput1_3.def)
  # ==============================================================================
#   LIBRARY xinput1_3
#   EXPORTS
#       XInputGetState @2
#       XInputSetState @3
#       XInputGetCapabilities @4
#       XInputEnable @5
#       XInputGetStateEx @100 NONAME
  step_msg "Step 6 — Installing helper binaries..."

  mkdir -p "${TOOLS_DIR}"

  # -- shm_launcher.exe ------------------------------------------------------
  local shm_dst="${TOOLS_DIR}/shm_launcher.exe"
  if [[ -f "${shm_dst}" ]] \
      && [[ "$(sha256sum "${shm_dst}" | awk '{print $1}')" == "${SHM_LAUNCHER_SHA256}" ]]; then
    ok_msg "shm_launcher.exe already installed and verified — skipping."
  else
    info_msg "Extracting shm_launcher.exe from embedded base64..."
    local shm_tmp
    shm_tmp=$(mktemp --suffix=.exe)
    base64 -d << 'SHM_B64_EOF' > "${shm_tmp}"
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AIPoAYlDDIX2fg32QwkQD4X6AgAADx8AhcB+P0WF5A+F2wEAAItTCPfCwAEAAA+ErAIAAI1I/4lLDIXJdCn2xgZ1JOnTAQAAQcdBDP////9B9kEJEA+FLQIAAEWF5A+F9AAAAItTCPbGAQ+F2AEAAIPiQHQTSInauSAAAADo1vD//2YPH0QAAItDDIXAfhWLUwiB4gAGAACB+gACAAAPhLwBAACF9g+ODAEAAA8fQAAPtge5MAAAAITAdAdIg8cBD77ISIna6I3w//+D7gF0MPZDCRB02maDeyAAdNNpxquqqqo9VVVVVXfGSI1LIEmJ2LoBAAAA6L3w///rsw8fAItDEIXAf2n2QwkID4W/AAAAg+gBiUMQSIPEIFteX0FcXcNmDx9EAACFwA+OGAIAAEGLURCD6AE50A+Ptf7//8dDDP////9FheQPhBX///9mDx+EAAAAAABIidq5LQAAAOjz7///6R7///9mDx9EAABIidno8Pz//+shZg8fRAAAD7YHuTAAAACEwHQHSIPHAQ++yEiJ2ui97///i0MQjVD/iVMQhcB/2EiDxCBbXl9BXF3DDx9EAABIidq5MAAAAOiT7///i0MQhcAPjqcBAABIidnokPz//4X2dL+LQxAB8IlDEA8fQABIidq5MAAAAOhj7///g8YBde7rnw8fQACNUP+JUwyF0g+ESv////dDCAAGAAAPhT3///+D6AKJQwwPH4AAAAAASInauSAAAADoI+///4tDDI1Q/4lTDIXAf+bpFP7//5BIidq5KwAAAOgD7///6S7+//9mDx9EAACD6AGJQwxmkEiJ2rkwAAAA6OPu//+LQwyNUP+JUwyFwH/m6R3+//+QZkGDeSAAD4TH/f//uP////+6q6qqqkSNRgJMD6/CicJJweghQY1I/ynBQYP4AXUY6Vv9//8PHwCD6gGJyAHQiVMMD4SgAAAAhdJ/7OmC/f//Dx+AAAAAAIDmBg+Fn/3//4PoAekt////Dx+AAAAAAEHHQQz/////uP/////2QwkQD4QJ/f//ZoN7IAAPhP78///pev///2YPH4QAAAAAAItTCPbGCA+Fzfz//4X2D47g/P//gOYQdc7p1vz//2aQD4Xx/f//QYtBEIXAD4nl/f//99hBiUEMQfZBCQgPhZb8///prPz//4nQ6aH8///2QwkID4VP/v//hfYP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bmNoZXJdIExhdW5jaGluZzogJWxzCgAAQ3JlYXRlUHJvY2VzcyBmYWlsZWQgKGVycj0lbHUpCgBbc2htX2xhdW5jaGVyXSBHYW1lIHN0YXJ0ZWQgKHBpZD0lbHUpLCB3YWl0aW5nLi4uCgAAAAAAAFtzaG1fbGF1bmNoZXJdIEdhbWUgZXhpdGVkIHdpdGggY29kZSAlbHUKAAAAAAAAAAAAAAAAAAAA8BoAQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAFAAQAAAAgwAUABAAAAfAABQAEAAAA4IAFAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQXJndW1lbnQgZG9tYWluIGVycm9yIChET01BSU4pAEFyZ3VtZW50IHNpbmd1bGFyaXR5IChTSUdOKQAAAAAAAE92ZXJmbG93IHJhbmdlIGVycm9yIChPVkVSRkxPVykAUGFydGlhbCBsb3NzIG9mIHNpZ25pZmljYW5jZSAoUExPU1MpAAAAAFRvdGFsIGxvc3Mgb2Ygc2lnbmlmaWNhbmNlIChUTE9TUykAAAAAAABUaGUgcmVzdWx0IGlzIHRvbyBzbWFsbCB0byBiZSByZXByZXNlbnRlZCAoVU5ERVJGTE9XKQBVbmtub3duIGVycm9yAAAAAABfbWF0aGVycigpOiAlcyBpbiAlcyglZywgJWcpICAocmV0dmFsPSVnKQoAAJhY//9MWP//5Ff//2xY//98WP//jFj//1xY//9NaW5ndy13NjQgcnVudGltZSBmYWlsdXJlOgoAAAAAAEFkZHJlc3MgJXAgaGFzIG5vIGltYWdlLXNlY3Rpb24AICBWaXJ0dWFsUXVlcnkgZmFpbGVkIGZvciAlZCBieXRlcyBhdCBhZGRyZXNzICVwAAAAAAAAAAAgIFZpcnR1YWxQcm90ZWN0IGZhaWxlZCB3aXRoIGNvZGUgMHgleAAAICBVbmtub3duIHBzZXVkbyByZWxvY2F0aW9uIHByb3RvY29sIHZlcnNpb24gJWQuCgAAAAAAAAAgIFVua25vd24gcHNldWRvIHJlbG9jYXRpb24gYml0IHNpemUgJWQuCgAAAAAAAAAlZCBiaXQgcHNldWRvIHJlbG9jYXRpb24gYXQgJXAgb3V0IG9mIHJhbmdlLCB0YXJnZXRpbmcgJXAsIHlpZWxkaW5nIHRoZSB2YWx1ZSAlcC4KAAAAAAAAOF3//zhd//84Xf//OF3//zhd//+wXf//OF3///Bd//+wXf//i13//wAAAAAAAAAAKG51bGwpAAAoAG4AdQBsAGwAKQAAAE5hTgBJbmYAAAB8hv//0IL//9CC//8Kif//0IL//zWI///Qgv//S4j//9CC///Qgv//toj//++I///Qgv//lIb//6+G///Qgv//yYb//9CC///Qgv//0IL//9CC///Qgv//0IL//9CC///Qgv//0IL//9CC///Qgv//0IL//9CC///Qgv//0IL//9CC///khv//0IL//4iH///Qgv//t4f//+GH//8LiP//0IL//7qE///Qgv//0IL///CE///Qgv//0IL//9CC///Qgv//0IL//9CC//9tif//0IL//9CC///Qgv//0IL//0CD///Qgv//0IL//9CC///Qgv//0IL//9CC///Qgv//0IL//wWF///Qgv//joX//7eD//9Uhv//LIb///GF//8shP//t4P//6CD///Qgv//moT//0yE//9ohP//QIP///+D///Qgv//0IL//8mF//+gg///QIP//9CC///Qgv//QIP//9CC//+gg///AAAAACUAKgAuACoAUwAAACUALQAqAC4AKgBTAAAAJQAuACoAUwAAAChudWxsKQAAJQAqAC4AKgBzAAAAJQAtACoALgAqAHMAAAAlAC4AKgBzAAAAKABuAHUAbABsACkAAAAlAAAATmFOAEluZgAAAJqq//+kpv//pKb//7Sq//+kpv//Hqj//6Sm//89qP//pKb//6Sm//+qqP//0qj//6Sm///vqP//DKn//6Sm//8pqf//pKb//6Sm//+kpv//pKb//6Sm//+kpv//pKb//6Sm//+kpv//pKb//6Sm//+kpv//pKb//6Sm//+kpv//pKb//1Op//+kpv//46n//6Sm//90qv//F6r//06q//+kpv//Zqv//6Sm//+kpv//tKv//6Sm//+kpv//pKb//6Sm//+kpv//pKb//2yt//+kpv//pKb//6Sm//+kpv//9Kb//6Sm//+kpv//pKb//6Sm//+kpv//pKb//6Sm//+kpv//y6v//6Sm///Zq///cqf//1us//8/rP//Taz//9Gq//9yp///Taf//6Sm///0qv//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bPEAAAAkAAB7JAAAePEAAIAkAAD/JAAAjPEAAAAlAACZJQAAnPEAAKAlAACSJgAArPEAAKAmAADMJgAAuPEAANAmAAAgJwAAvPEAACAnAADGJwAAwPEAANAnAABQKAAA0PEAAFAoAACHKAAA1PEAAJAoAAADKQAA2PEAABApAABGKQAA3PEAAFApAADZKQAA4PEAAOApAACeKgAA5PEAAOAqAAAoKwAA6PEAADArAACdKwAA+PEAAKArAACMLAAACPIAAJAsAADoLAAAFPIAAPAsAACOLgAAIPIAAJAuAADULwAAOPIAAOAvAAAvMAAASPIAADAwAADBMAAAWPIAANAwAADpNQAAZPIAAPA1AACZOQAAfPIAAKA5AADuOgAAlPIAAPA6AADGPgAAqPIAANA+AACnPwAAvPIAALA/AABPQAAAzPIAAFBAAAAvQQAA3PIAADBBAACIQgAA7PIAAJBCAABDRwAA/PIAAFBHAABbUQAAFPMAAGBRAAC7UQAAMPMAAMBRAAA+UwAAPPMAAEBTAADRUwAAUPMAAOBTAABWVAAAXPMAAGBUAACvVAAAbPMAALBUAACcVQAAfPMAAKBVAABtVwAAiPMAAHBXAABGWwAAnPMAAFBbAAA3XAAAsPMAAEBcAABpYQAAwPMAAHBhAAApZQAA2PMAADBlAADjaQAA8PMAAPBpAADHagAACPQAANBqAABvawAAGPQAAHBrAADIbAAAKPQAANBsAABddwAAOPQAAGB3AACgdwAAVPQAAKB3AAAceAAAYPQAACB4AABHeAAAcPQAAFB4AADNeQAAdPQAANB5AADjjwAAjPQAAPCPAAD6kAAAqPQAAACRAAA6kQAAvPQAAECRAAApkgAAwPQAADCSAAB7kgAA0PQAAICSAABzkwAA3PQAAICTAADskwAA7PQAAPCTAACplAAA+PQAALCUAABtlQAADPUAAHCVAADXlgAAGPUAAOCWAABimAAAMPUAAHCYAACWmQAARPUAAKCZAADomQAAXPUAAPCZAACzmwAAYPUAAMCbAADPnAAAePUAANCcAADqnQAAiPUAAPCdAAASngAAnPUAACCeAABIngAAoPUAAFCeAAB1ngAApPUAAICeAACLngAAqPUAAJCeAACbngAArPUAAKCeAAAQnwAAsPUAABCfAAB5nwAAvPUAAICfAACInwAA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Qnl0ZUV4AADWA0xlYXZlQ3JpdGljYWxTZWN0aW9uAAD5A01hcFZpZXdPZkZpbGUACgRNdWx0aUJ5dGVUb1dpZGVDaGFyAJAEUmVhZEZpbGUAAG8FU2V0VW5oYW5kbGVkRXhjZXB0aW9uRmlsdGVyAH8FU2xlZXAAogVUbHNHZXRWYWx1ZQCzBVVubWFwVmlld09mRmlsZQDRBVZpcnR1YWxQcm90ZWN0AADTBVZpcnR1YWxRdWVyeQAA3AVXYWl0Rm9yU2luZ2xlT2JqZWN0AAgGV2lkZUNoYXJUb011bHRpQnl0ZQA4AF9fQ19zcGVjaWZpY19oYW5kbGVyAABAAF9fX2xjX2NvZGVwYWdlX2Z1bmMAQwBfX19tYl9jdXJfbWF4X2Z1bmMAAFQAX19pb2JfZnVuYwAAYQBfX3NldF9hcHBfdHlwZQAAYwBfX3NldHVzZXJtYXRoZXJyAABuAF9fd2dldG1haW5hcmdzAABvAF9fd2luaXRlbnYAAHgAX2Ftc2dfZXhpdAAAiQBfY2V4aXQAAJUAX2NvbW1vZGUAALwAX2Vycm5vAADKA2Z3cHJpbnRmAADbAF9mbW9kZQAAHQFfaW5pdHRlcm0AgwFfbG9jawApAl9vbmV4aXQAygJfdW5sb2NrAIcDYWJvcnQAmANjYWxsb2MAAKUDZXhpdAAAuQNmcHJpbnRmALsDZnB1dGMAvQNmcHV0d2MAAMADZnJlZQAAzQNmd3JpdGUAAPYDbG9jYWxlY29udgAA/QNtYWxsb2MAAAUEbWVtY3B5AAAHBG1lbXNldAAAJQRzaWduYWwAADoEc3RyZXJyb3IAADwEc3RybGVuAAA/BHN0cm5jbXAAYAR2ZnByaW50ZgAAegR3Y3NsZW4AAAAAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQBLRVJORUwzMi5kbGwAAAAAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAbXN2Y3J0LmRsbAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQBEAQAEAAAAAAAAAAAAAAAAAAAAAAAAAEBAAQAEAAAAAAAAAAAAAAAAAAAAAAAAA8BoAQAEAAADAGgBAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAADAAAAPimAAAAsAAAHAAAAACggKCQoKCgsKC4oMCgyKDQoAAAAMAAAEwAAABgooCiiKKQopiiAKsQqyCrMKtAq1CrYKtwq4CrkKugq7CrwKvQq+Cr8KsArBCsIKwwrECsUKxgrHCsgKyQrKCssKwAAAAgAQAQAAAACKAgoDigQKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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ACgBU2VsZgBhEReVDAAAMAAF/QsAAAZOVF9USUIAYhEH/QsAAAZQTlRfVElCAGMRFbkMAAAFmgwAADJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAkwEAAAKKExKQDQAAA0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQNKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACA0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEA0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA5fSU1BR0VfRE9TX0hFQURFUgBA8xsU5Q4AAAFlX21hZ2ljAPQbDH8FAAAAAWVfY2JscAD1Gwx/BQAAAgFlX2NwAPYbDH8FAAAEAWVfY3JsYwD3Gwx/BQAABgFlX2NwYXJoZHIA+BsMfwUAAAgBZV9taW5hbGxvYwD5Gwx/BQAACgFlX21heGFsbG9jAPobDH8FAAAMAWVfc3MA+xsMfwUAAA4BZV9zcAD8Gwx/BQAAEAFlX2NzdW0A/RsMfwUAABIBZV9pcAD+Gwx/BQAAFAFlX2NzAP8bDH8FAAAWAWVfbGZhcmxjAAAcDH8FAAAYAWVfb3ZubwABHAx/BQAAGgFlX3JlcwACHAzlDgAAHAFlX29lbWlkAAMcDH8FAAAkAWVfb2VtaW5mbwAEHAx/BQAAJgFlX3JlczIABRwM9Q4AACgBZV9sZmFuZXcABhwMEgYAADwAFn8FAAD1DgAADw4BAAADABZ/BQAABQ8AAA8OAQAACQAGSU1BR0VfRE9TX0hFQURFUgAHHAeQDQAABlBJTUFHRV9ET1NfSEVBREVSAAccGTgPAAAFkA0AAA5fSU1BR0VfRklMRV9IRUFERVIAFGIcFAoQAAABTWFjaGluZQBjHAx/BQAAAAFOdW1iZXJPZlNlY3Rpb25zAGQcDH8FAAACAVRpbWVEYXRlU3RhbXAAZRwNjAUAAAQBUG9pbnRlclRvU3ltYm9sVGFibGUAZhwNjAUAAAgBTnVtYmVyT2ZTeW1ib2xzAGccDYwFAAAMAVNpemVPZk9wdGlvbmFsSGVhZGVyAGgcDH8FAAAQAUNoYXJhY3RlcmlzdGljcwBpHAx/BQAAEgAGSU1BR0VfRklMRV9IRUFERVIAahwHPQ8AAA5fSU1BR0VfREFUQV9ESVJFQ1RPUlkACJ8cFGoQAAABVmlydHVhbEFkZHJlc3MAoBwNjAUAAAABU2l6ZQChHA2MBQAABAAGSU1BR0VfREFUQV9ESVJFQ1RPUlkAohwHJBAAAA5fSU1BR0VfT1BUSU9OQUxfSEVBREVSAOCmHBREEgAAAU1hZ2ljAKgcDH8FAAAAAoYAAACpHAxyBQAAAgLlAAAAqhwMcgUAAAMCewAAAKscDYwFAAAEAqsAAACsHA2MBQAACAIQAQAArRwNjAUAAAwCKAEAAK4cDYwFAAAQAh8AAACvHA2MBQAAFAFCYXNlT2ZEYXRhALAcDYwFAAAYAnEAAACxHA2MBQAAHAIqAAAAshwNjAUAACACfAEAALMcDYwFAAAkAmABAAC0HAx/BQAAKALTAQAAtRwMfwUAACoCDQIAALYcDH8FAAAsAsEBAAC3HAx/BQAALgI8AQAAuBwMfwUAADACOwAAALkcDH8FAAAyAvsBAAC6HA2MBQAANAITAAAAuxwNjAUAADgCUgEAALwcDYwFAAA8AgoAAAC9HA2MBQAAQAIAAAAAvhwMfwUAAEQCrgEAAL8cDH8FAABGAsEAAADAHA2MBQAASAJfAAAAwRwNjAUAAEwCmQAAAMIcDYwFAABQAtQAAADDHA2MBQAAVALvAQAAxBwNjAUAAFgCigEAAMUcDYwFAABcAlEAAADGHBxEEgAAYAAWahAAAFQSAAAPDgEAAA8ABlBJTUFHRV9PUFRJT05BTF9IRUFERVIzMgDHHCB1EgAABYcQAAAOX0lNQUdFX09QVElPTkFMX0hFQURFUjY0APDZHBQlFAAAAU1hZ2ljANocDH8FAAAAAoYAAADbHAxyBQAAAgLlAAAA3BwMcgUAAAMCewAAAN0cDYwFAAAEAqsAAADeHA2MBQAACAIQAQAA3xwNjAUAAAwCKAEAAOAcDYwFAAAQAh8AAADhHA2MBQAAFAJxAAAA4hwRMAYAABgCKgAAAOMcDYwFAAAgAnwBAADkHA2MBQAAJAJgAQAA5RwMfwUAACgC0wEAAOYcDH8FAAAqAg0CAADnHAx/BQAALALBAQAA6BwMfwUAAC4CPAEAAOkcDH8FAAAwAjsAAADqHAx/BQAAMgL7AQAA6xwNjAUAADQCEwAAAOwcDYwFAAA4AlIBAADtHA2MBQAAPAIKAAAA7hwNjAUAAEACAAAAAO8cDH8FAABEAq4BAADwHAx/BQAARgLBAAAA8RwRMAYAAEgCXwAAAPIcETAGAABQApkAAADzHBEwBgAAWALUAAAA9BwRMAYAAGAC7wEAAPUcDYwFAABoAooBAAD2HA2MBQAAbAJRAAAA9xwcRBIAAHAABklNQUdFX09QVElPTkFMX0hFQURFUjY0APgcB3oSAAAGUElNQUdFX09QVElPTkFMX0hFQURFUjY0APgcIGYUAAAFehIAAENfSU1BR0VfTlRfSEVBREVSUzY0AAgBAg8dFMoUAAABU2lnbmF0dXJlABAdDYwFAAAAAUZpbGVIZWFkZXIAER0ZChAAAAQBT3B0aW9uYWxIZWFkZXIAEh0fJRQAABgABlBJTUFHRV9OVF9IRUFERVJTNjQAEx0b5hQAAAVrFAAABlBJTUFHRV9OVF9IRUFERVJTACIdIcoUAAAGUElNQUdFX1RMU19DQUxMQkFDSwBTIBomFQAAJAUVAAAFKxUAADBAFQAABAQGAAAEjAUAAAQEBgAAAAVFFQAAJRIGAABUFQAABEoLAAAACVBUT1BfTEVWRUxfRVhDRVBUSU9OX0ZJTFRFUgAIERdAFQAACUxQVE9QX0xFVkVMX0VYQ0VQVElPTl9GSUxURVIACBIlVBUAAER0YWdDT0lOSVRCQVNFAAcEkwEAAAmVDtUVAAADQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAMlZBUkVOVU0AkwEAAAoJAgZfGAAAA1ZUX0VNUFRZAAADVlRfTlVMTAABA1ZUX0kyAAIDVlRfSTQAAwNWVF9SNAAEA1ZUX1I4AAUDVlRfQ1kABgNWVF9EQVRFAAcDVlRfQlNUUgAIA1ZUX0RJU1BBVENIAAkDVlRfRVJST1IACgNWVF9CT09MAAsDVlRfVkFSSUFOVAAMA1ZUX1VOS05PV04ADQNWVF9ERUNJTUFMAA4DVlRfSTEAEANWVF9VSTEAEQNWVF9VSTIAEgNWVF9VSTQAEwNWVF9JOAAUA1ZUX1VJOAAVA1ZUX0lOVAAWA1ZUX1VJTlQAFwNWVF9WT0lEABgDVlRfSFJFU1VMVAAZA1ZUX1BUUgAaA1ZUX1NBRkVBUlJBWQAbA1ZUX0NBUlJBWQAcA1ZUX1VTRVJERUZJTkVEAB0DVlRfTFBTVFIAHgNWVF9MUFdTVFIAHwNWVF9SRUNPUkQAJANWVF9JTlRfUFRSACUDVlRfVUlOVF9QVFIAJgNWVF9GSUxFVElNRQBAA1ZUX0JMT0IAQQNWVF9TVFJFQU0AQgNWVF9TVE9SQUdFAEMDVlRfU1RSRUFNRURfT0JKRUNUAEQDVlRfU1RPUkVEX09CSkVDVABFA1ZUX0JMT0JfT0JKRUNUAEYDVlRfQ0YARwNWVF9DTFNJRABIA1ZUX1ZFUlNJT05FRF9TVFJFQU0ASRJWVF9CU1RSX0JMT0IA/w8SVlRfVkVDVE9SAAAQElZUX0FSUkFZAAAgElZUX0JZUkVGAABAElZUX1JFU0VSVkVEAACAElZUX0lMTEVHQUwA//8SVlRfSUxMRUdBTE1BU0tFRAD/DxJWVF9UWVBFTUFTSwD/DwAHX2Rvd2lsZGNhcmQADGAOdgEAAAdfbmV3bW9kZQAMYQ52AQAAB19faW1wX19fd2luaXRlbnYADGQUjQcAAEUEDHkLuBgAABluZXdtb2RlAAx6CXYBAAAAAAlfc3RhcnR1cGluZm8ADHsFnRgAAEb4AAAABwSTAQAADIQQExkAAANfX3VuaW5pdGlhbGl6ZWQAAANfX2luaXRpYWxpemluZwABA19faW5pdGlhbGl6ZWQAAgBH+AAAAAyGBc0YAAAtExkAAAdfX25hdGl2ZV9zdGFydHVwX3N0YXRlAAyIKx8ZAAAHX19uYXRpdmVfc3RhcnR1cF9sb2NrAAyJGWEZAAAFZhkAAEgJX1BWRlYADRQYOwcAAAlfUElGVgANFRcnBwAABWcZAABJX2V4Y2VwdGlvbgAoDqMK5RkAABl0eXBlAA6kCXYBAAAAGW5hbWUADqUR5RkAAAgZYXJnMQAOpgwxBwAAEBlhcmcyAA6nDDEHAAAYGXJldHZhbAAOqAwxBwAAIAAF+gAAAAlfVENIQVIAD24TSwEAAAdfX2ltYWdlX2Jhc2VfXwABKxkFDwAAB19mbW9kZQABMgx2AQAAB19jb21tb2RlAAEzDHYBAAAWdRkAADsaAAAzAAdfX3hpX2EAATokMBoAAAdfX3hpX3oAATskMBoAABZnGQAAZBoAADMAB19feGNfYQABPCRZGgAAB19feGNfegABPSRZGgAAB19fZHluX3Rsc19pbml0X2Nh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EABAAQAAAB8fAAA1JQAACgFSATEAHgwRAEABAAAArB4AABwBUgAAOF9fbWluZ3dfaW52YWxpZFBhcmFtZXRlckhhbmRsZXIAYgAQAEABAAAAAQAAAAAAAAABnNYlAAAgZXhwcmVzc2lvbgBiMogHAAABUiBmdW5jdGlvbgBjFogHAAABUSBmaWxlAGQWiAcAAAFYIGxpbmUAZRaTAQAAAVkgcFJlc2VydmVkAGYQOQEAAAKRIABYX1RFQgBZTnRDdXJyZW50VGViAAIdJx7zJQAAAwXWJQAALF9JbnRlcmxvY2tlZEV4Y2hhbmdlUG9pbnRlcgDTBgd4AgAAQCYAABNUYXJnZXQAA9MGM0AmAAATVmFsdWUAA9MGQHgCAAAABXoCAAAsX0ludGVybG9ja2VkQ29tcGFyZUV4Y2hhbmdlUG9pbnRlcgDIBgd4AgAAryYAABNEZXN0aW5hdGlvbgADyAY6QCYAABNFeENoYW5nZQADyAZNeAIAABNDb21wZXJhbmQAA8gGXXgCAAAALF9fcmVhZGdzcXdvcmQARgMBDgEAAOcmAAATT2Zmc2V0AANGAwGjAQAAEHJldAADRgMBDgEAAABabWVtY3B5AF9fYnVpbHRpbl9tZW1jcHkAFAAA2AYAAAUAAQiDBQAAC0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHd8BAAAdAgAA0BkAQAEAAADvAAAAAAAAAEoEAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAAEcHRyZGlmZl90AAVYIxQBAAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAACBAdsb25nIHVuc2lnbmVkIGludAACAQh1bnNpZ25lZCBjaGFyAAIEBGZsb2F0AAIBBnNpZ25lZCBjaGFyAAICBXNob3J0IGludAACEARsb25nIGRvdWJsZQACCARkb3VibGUABdkBAAAMAgIEX0Zsb2F0MTYAAgIEX19iZjE2AAZKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAYAEAAAKKExLCAgAAAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA10YWdDT0lOSVRCQVNFAAcEYAEAAAOVDvoCAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAABlZBUkVOVU0AYAEAAAQJAgaEBQAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQNWVF9CU1RSX0JMT0IA/w8DVlRfVkVDVE9SAAAQA1ZUX0FSUkFZAAAgA1ZUX0JZUkVGAABAA1ZUX1JFU0VSVkVEAACAA1ZUX0lMTEVHQUwA//8DVlRfSUxMRUdBTE1BU0tFRAD/DwNWVF9UWVBFTUFTSwD/DwAEZnVuY19wdHIAAQsQ1AEAAA6EBQAAoAUAAA8AB19fQ1RPUl9MSVNUX18ADJUFAAAHX19EVE9SX0xJU1RfXwANlQUAAAhpbml0aWFsaXplZAAyDE0BAAAJAzAAAUABAAAAEGF0ZXhpdAAGqQEPTQEAAP8FAAAR1AEAAAASX19tYWluAAE1AaAaAEABAAAAHwAAAAAAAAABnC4GAAATvxoAQAEAAAAuBgAAAAlfX2RvX2dsb2JhbF9jdG9ycwAgIBoAQAEAAAB6AAAAAAAAAAGcmAYAAApucHRycwAicAEAANoBAADUAQAACmkAI3ABAADyAQAA7gEAABR2GgBAAQAAAOUFAAAVAVIJA9AZAEABAAAAAAAJX19kb19nbG9iYWxfZHRvcnMAFNAZAEABAAAAQwAAAAAAAAABnNYGAAAIcAAWFNYGAAAJAwCwAEABAAAAAAWEBQAAAHkGAAAFAAEIwgYAAAhHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB3EAgAAAwMAAHIFAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAAGPgEAAAIEB2xvbmcgdW5zaWduZWQgaW50AAIBCHVuc2lnbmVkIGNoYXIAAgQEZmxvYXQAAgEGc2lnbmVkIGNoYXIAAgIFc2hvcnQgaW50AAIQBGxvbmcgZG91YmxlAAIIBGRvdWJsZQACAgRfRmxvYXQxNgACAgRfX2JmMTYAB0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwA+AQAAAYoTEp8CAAABSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcACXRhZ0NPSU5JVEJBU0UABwQ+AQAAApUO1wIAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAHVkFSRU5VTQA+AQAAAwkCBmEFAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJA1ZUX0JTVFJfQkxPQgD/DwNWVF9WRUNUT1IAABADVlRfQVJSQVkAACADVlRfQllSRUYAAEADVlRfUkVTRVJWRUQAAIADVlRfSUxMRUdBTAD//wNWVF9JTExFR0FMTUFTS0VEAP8PA1ZUX1RZUEVNQVNLAP8PAAofAgAABwQ+AQAABIQQpwUAAAFfX3VuaW5pdGlhbGl6ZWQAAAFfX2luaXRpYWxpemluZwABAV9faW5pdGlhbGl6ZWQAAgALHwIAAASGBWEFAAAGpwUAAARfX25hdGl2ZV9zdGFydHVwX3N0YXRlAIgrswUAAARfX25hdGl2ZV9zdGFydHVwX2xvY2sAiRnzBQAADAj5BQAADQRfX25hdGl2ZV9kbGxtYWluX3JlYXNvbgCLIE4BAAAEX19uYXRpdmVfdmNjbHJpdF9yZWFzb24AjCBOAQAABfoFAAALFwkDFLAAQAEAAAAFGQYAAAwXCQMQsABAAQAAAAW4BQAADSIJA0gAAUABAAAABdYFAAAOEAkDQAABQAEAAAAABAEAAAUAAQh4BwAAAUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHdwDAAAbBAAAyAUAAAJfZG93aWxkY2FyZAABIAUAAQAACQNQAAFAAQAAAAMEBWludAAAAQEAAAUAAQimBwAAAUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHXMEAACyBAAAAgYAAAJfbmV3bW9kZQABBwX9AAAACQNgAAFAAQAAAAMEBWludAAAPggAAAUAAQjUBwAAEkdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHREFAAAKBQAAwBoAQAEAAADDAAAAAAAAADwGAAABAQZjaGFyAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAADdWludHB0cl90AAJLLPoAAAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAjyAAAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIAEwgDVUxPTkcAAxgddQEAAANXSU5CT09MAAN/DU0BAAADQk9PTAADgw9NAQAAA0RXT1JEAAONHXUBAAABBARmbG9hdAADTFBWT0lEAAOZEZsBAAABAQZzaWduZWQgY2hhcgABAgVzaG9ydCBpbnQAA1VMT05HX1BUUgAEMS76AAAABFBWT0lEAAsBEZsBAAAESEFORExFAJ8BEZsBAAAEVUxPTkdMT05HAPUBLvoAAAABEARsb25nIGRvdWJsZQABCARkb3VibGUACGkCAAAUAQIEX0Zsb2F0MTYAAQIEX19iZjE2ABVKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwRlAQAABYoTElQDAAAJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABCUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcABFBJTUFHRV9UTFNfQ0FMTEJBQ0sAUyAadQMAAAxUAwAACHoDAAAWjwMAAAUcAgAABcgBAAAFHAIAAAAXX0lNQUdFX1RMU19ESVJFQ1RPUlk2NAAoBVUgFFIEAAAGU3RhcnRBZGRyZXNzT2ZSYXdEYXRhAFYgETkCAAAA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AAJfZnByZXNldAABCQagHABAAQAAAAMAAAAAAAAAAZwACQEAAAUAAQi2CwAAAUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHREJAAAKCQAAMAkAAAJfX21pbmd3X2FwcF90eXBlAAEIBQUBAAAJA5AAAUABAAAAAwQFaW50AADEFwAABQABCOQLAAAnR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdsAkAAPMJAACwHABAAQAAAD0FAAAAAAAAagkAAAZfX2dudWNfdmFfbGlzdAACGB0JAQAAKAhfX2J1aWx0aW5fdmFfbGlzdAAhAQAABwEGY2hhcgApIQEAAAZ2YV9saXN0AAIfGvIAAAAGc2l6ZV90AAMjLE0BAAAHCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAcIBWxvbmcgbG9uZyBpbnQABnB0cmRpZmZfdAADWCNnAQAABwIHc2hvcnQgdW5zaWduZWQgaW50AAcEBWludAAHBAVsb25nIGludAAJIQEAAAcEB3Vuc2lnbmVkIGludAAHBAdsb25nIHVuc2lnbmVkIGludAAHAQh1bnNpZ25lZCBjaGFyACoIBlVMT05HAAQYHcgBAAAGV0lOQk9PTAAEfw2gAQAABkJZVEUABIsZ3QEAAAZXT1JEAASMGooBAAAGRFdPUkQABI0dyAEAAAcEBGZsb2F0AAZQQllURQAEkBFNAgAACQ4CAAAGTFBCWVRFAASREU0CAAAGUERXT1JEAASXEnACAAAJKAIAAAZMUFZPSUQABJkR7gEAAAZMUENWT0lEAAScF5QCAAAJmQIAACsHAQZzaWduZWQgY2hhcgAHAgVzaG9ydCBpbnQABlVMT05HX1BUUgAFMS5NAQAABlNJWkVfVAAFkye2AgAAD1BWT0lEAAsBEe4BAAAPTE9ORwApARSnAQAABxAEbG9uZyBkb3VibGUABwgEZG91YmxlAAcCBF9GbG9hdDE2AAcCBF9fYmYxNgAeSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTALgBAAAGihMS8wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAVX01FTU9SWV9CQVNJQ19JTkZPUk1BVElPTgAw8xW1BAAAAkJhc2VBZGRyZXNzAPQVDdcCAAAAAkFsbG9jYXRpb25CYXNlAPUVDdcCAAAIAkFsbG9jYXRpb25Qcm90ZWN0APYVDSgCAAAQAlBhcnRpdGlvbklkAPgVDBsCAAAUAlJlZ2lvblNpemUA+hUOyAIAABgCU3RhdGUA+xUNKAIAACACUHJvdGVjdAD8FQ0oAgAAJAJUeXBlAP0VDSgCAAAoAA9NRU1PUllfQkFTSUNfSU5GT1JNQVRJT04A/hUH8wMAAA9QTUVNT1JZX0JBU0lDX0lORk9STUFUSU9OAP4VIfgEAAAJ8wMAABYOAgAADQUAABdNAQAABwAVX0lNQUdFX0RPU19IRUFERVIAQPMbYQYAAAJlX21hZ2ljAPQbDBsCAAAAAmVfY2JscAD1GwwbAgAAAgJlX2NwAPYbDBsCAAAEAmVfY3JsYwD3GwwbAgAABgJlX2NwYXJoZHIA+BsMGwIAAAgCZV9taW5hbGxvYwD5GwwbAgAACgJlX21heGFsbG9jAPobDBsCAAAMAmVfc3MA+xsMGwIAAA4CZV9zcAD8GwwbAgAAEAJlX2NzdW0A/RsMGwIAABICZV9pcAD+GwwbAgAAFAJlX2NzAP8bDBsCAAAWAmVfbGZhcmxjAAAcDBsCAAAYAmVfb3ZubwABHAwbAgAAGgJlX3JlcwACHAxhBgAAHAJlX29lbWlkAAMcDBsCAAAkAmVfb2VtaW5mbwAEHAwbAgAAJgJlX3JlczIABRwMcQYAACgCZV9sZmFuZXcABhwM5QIAADwAFhsCAABxBgAAF00BAAADABYbAgAAgQYAABdNAQAACQAPSU1BR0VfRE9TX0hFQURFUgAHHAcNBQAALAQGgB0HzwYAAB9QaHlzaWNhbEFkZHJlc3MAgR0oAgAAH1ZpcnR1YWxTaXplAIIdKAIAAAAVX0lNQUdFX1NFQ1RJT05fSEVBREVSACh+HeIHAAACTmFtZQB/HQz9BAAAAAJNaXNjAIMdCZoGAAAIAlZpcnR1YWxBZGRyZXNzAIQdDSgCAAAMAlNpemVPZlJhd0RhdGEAhR0NKAIAABACUG9pbnRlclRvUmF3RGF0YQCGHQ0oAgAAFAJQb2ludGVyVG9SZWxvY2F0aW9ucwCHHQ0oAgAAGAJQb2ludGVyVG9MaW5lbnVtYmVycwCIHQ0oAgAAHAJOdW1iZXJPZlJlbG9jYXRpb25zAIkdDBsCAAAgAk51bWJlck9mTGluZW51bWJlcnMAih0MGwIAACICQ2hhcmFjdGVyaXN0aWNzAIsdDSgCAAAkAA9QSU1BR0VfU0VDVElPTl9IRUFERVIAjB0dAAgAAAnPBgAALXRhZ0NPSU5JVEJBU0UABwS4AQAAB5UOPQgAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAeVkFSRU5VTQC4AQAACAkCBscKAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJDlZUX0JTVFJfQkxPQgD/Dw5WVF9WRUNUT1IAABAOVlRfQVJSQVkAACAOVlRfQllSRUYAAEAOVlRfUkVTRVJWRUQAAIAOVlRfSUxMRUdBTAD//w5WVF9JTExFR0FMTUFTS0VEAP8PDlZUX1RZUEVNQVNLAP8PAC5faW9idWYAMAkhClcLAAAFX3B0cgAJJQuzAQAAAAVfY250AAkmCaABAAAIBV9iYXNlAAknC7MBAAAQBV9mbGFnAAkoCaABAAAYBV9maWxlAAkpCaABAAAcBV9jaGFyYnVmAAkqCaABAAAgBV9idWZzaXoACSsJoAEAACQFX3RtcGZuYW1lAAksC7MBAAAoAAZGSUxFAAkvGccKAAAYX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AMQ0hAQAAGF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwAyDSEBAAAYX19pbWFnZV9iYXNlX18AMxmBBgAAGQg88AsAAAVhZGRlbmQAAT0JKAIAAAAFdGFyZ2V0AAE+CSgCAAAEAAZydW50aW1lX3BzZXVkb19yZWxvY19pdGVtX3YxAAE/A8gLAAAZDEdJDAAABXN5bQABSAkoAgAAAAV0YXJnZXQAAUkJKAIAAAQFZmxhZ3MAAUoJKAIAAAgABnJ1bnRpbWVfcHNldWRvX3JlbG9jX2l0ZW1fdjIAAUsDFQwAABkMTacMAAAFbWFnaWMxAAFOCSgCAAAABW1hZ2ljMgABTwkoAgAABAV2ZXJzaW9uAAFQCSgCAAAIAAZydW50aW1lX3BzZXVkb19yZWxvY192MgABUQNuDAAAL1YCAAAoAaoQNg0AAAVvbGRfcHJvdGVjdAAB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AABrCQAAA2EyAAxK8gAAAIQJAACACQAAEXJzbHQAAQ0P8gAAAAKRIAZleAAPqwEAAAKRQBIkIgBAAQAAAAcBUgKRQAAAAP8AAAAFAAEIzhAAAAFHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB3DCwAAAgwAAJgPAAACX2Ztb2RlAAEGBfsAAAAJA8AAAUABAAAAAwQFaW50AABYEAAABQABCPwQAAAZR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdWgwAAJwMAABAIgBAAQAAAL0BAAAAAAAA0g8AAAQBBmNoYXIABAgHbG9uZyBsb25nIHVuc2lnbmVkIGludAAECAVsb25nIGxvbmcgaW50AAQCB3Nob3J0IHVuc2lnbmVkIGludAAEBAVpbnQABAQFbG9uZyBpbnQABAQHdW5zaWduZWQgaW50AAQEB2xvbmcgdW5zaWduZWQgaW50AAQBCHVuc2lnbmVkIGNoYXIAC4kBAAAalAEAAA47AQAAAAuZAQAAEl9FWENFUFRJT05fUkVDT1JEAJhbC0ICAAABRXhjZXB0aW9uQ29kZQBcCw1RBQAAAAFFeGNlcHRpb25GbGFncwBdCw1RBQAABBNfAgAAXgshlAEAAAgBRXhjZXB0aW9uQWRkcmVzcwBfCw2mBQAAEAFOdW1iZXJQYXJhbWV0ZXJzAGALDVEFAAAYAUV4Y2VwdGlvbkluZm9ybWF0aW9uAGEL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dFNhdmUAOQfeBwAAIPYHAAAQAA8SBgAAZgkAAA36AAAAGQAIUENPTlRFWFQAVgcORAIAABaEBQAAhwkAAA36AAAADgAIRVhDRVBUSU9OX1JFQ09SRABiCweZAQAACFBFWENFUFRJT05fUkVDT1JEAGQLH7oJAAALhwkAABJfRVhDRVBUSU9OX1BPSU5URVJTABB5CwAKAAATXwIAAHoLGaAJAAAAAUNvbnRleHRSZWNvcmQAewsQZgkAAAgACEVYQ0VQVElPTl9QT0lOVEVSUwB8Cwe/CQAAC78JAAAYSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAE4BAAACihMS8goAAAJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAECSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAL9woAACG0BQAABgsAAA4bCgAAAAdQVE9QX0xFVkVMX0VYQ0VQVElPTl9GSUxURVIABREX8goAAAdMUFRPUF9MRVZFTF9FWENFUFRJT05fRklMVEVSAAUSJQYLAAAidGFnQ09JTklUQkFTRQAHBE4BAAAGlQ6HCwAAAkNPSU5JVEJBU0VfTVVMVElUSFJFQURFRAAAABhWQVJFTlVNAE4BAAAHCQIGEQ4AAAJWVF9FTVBUWQAAAlZUX05VTEwAAQJWVF9JMgACAlZUX0k0AAMCVlRfUjQABAJWVF9SOAAFAlZUX0NZAAYCVlRfREFURQAHAlZUX0JTVFIACAJWVF9ESVNQQVRDSAAJAlZUX0VSUk9SAAoCVlRfQk9PTAALAlZUX1ZBUklBTlQADAJWVF9VTktOT1dOAA0CVlRfREVDSU1BTAAOAlZUX0kxABACVlRfVUkxABECVlRfVUkyABICVlRfVUk0ABMCVlRfSTgAFAJWVF9VSTgAFQJWVF9JTlQAFgJWVF9VSU5UABcCVlRfVk9JRAAYAlZUX0hSRVNVTFQAGQJWVF9QVFIAGgJWVF9TQUZFQVJSQVkAGwJWVF9DQVJSQVkAHAJWVF9VU0VSREVGSU5FRAAdAlZUX0xQU1RSAB4CVlRfTFBXU1RSAB8CVlRfUkVDT1JEACQCVlRfSU5UX1BUUgAlAlZUX1VJTlRfUFRSACYCVlRfRklMRVRJTUUAQAJWVF9CTE9CAEECVlRfU1RSRUFNAEICVlRfU1RPUkFHRQBDAlZUX1NUUkVBTUVEX09CSkVDVABEAlZUX1NUT1JFRF9PQkpFQ1QARQJWVF9CTE9CX09CSkVDVABGAlZUX0NGAEcCVlRfQ0xTSUQASAJWVF9WRVJTSU9ORURfU1RSRUFNAEkJVlRfQlNUUl9CTE9CAP8PCVZUX1ZFQ1RPUgAAEAlWVF9BUlJBWQAAIAlWVF9CWVJFRgAAQAlWVF9SRVNFUlZFRAAAgAlWVF9JTExFR0FMAP//CVZUX0lMTEVHQUxNQVNLRUQA/w8JVlRfVFlQRU1BU0sA/w8AB19fcF9zaWdfZm5fdAAIMBKEAQAAI19fbWluZ3dfb2xkZXhjcHRfaGFuZGxlcgABsB4qCwAACQPQAAFAAQAAACRfZnByZXNldAABHw0lc2lnbmFsAAg8GBEOAAB8DgAADjsBAAAOEQ4AAAAmX2dudV9leGNlcHRpb25faGFuZGxlcgABuAFCAQAAQCIAQAEAAAC9AQAAAAAAAAGcVhAAACdleGNlcHRpb25fZGF0YQABuC1WEAAArwkAAKEJAAAQb2xkX2hhbmRsZXIAugqEAQAA9AkAAOQJAAAQYWN0aW9uALsIQgEAAEUKAAArCgAAEHJlc2V0X2ZwdQC8BzsBAAC/CgAAsQoAAAqkIgBAAQAAAF4OAAA2DwAAAwFSATgDAVEBMAAozyIAQAEAAABLDwAAAwFSA6MBUgAK9yIAQAEAAABeDgAAZw8AAAMBUgE0AwFRATAAEQ0jAEABAAAAeg8AAAMBUgE0AApcIwBAAQAAAF4OAACWDwAAAwFSATgDAVEBMAAKdSMAQAEAAABeDgAAsg8AAAMBUgE4AwFRATEACowjAEABAAAAXg4AAM4PAAADAVIBOwMBUQEwABGiIwBAAQAAAOEPAAADAVIBOwARtyMAQAEAAAD0DwAAAwFSATgACssjAEABAAAAXg4AABAQAAADAVIBOwMBUQExAArfIwBAAQAAAF4OAAAsEAAAAwFSATQDAVEBMQAK8yMAQAEAAABeDgAASBAAAAMBUgE4AwFRATEAKfgjAEABAAAAUQ4AAAALAAoAAABKCwAABQABCHoTAAAYR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdbw0AAGgNAAAAJABAAQAAAJICAAAAAAAAYBEAAAIBBmNoYXIABHNpemVfdAACIywJAQAAAggHbG9uZyBsb25nIHVuc2lnbmVkIGludAACCAVsb25nIGxvbmcgaW50AAICB3Nob3J0IHVuc2lnbmVkIGludAACBAVpbnQAE0oBAAACBAVsb25nIGludAACBAd1bnNpZ25lZCBpbnQAAgQHbG9uZyB1bnNpZ25lZCBpbnQAAgEIdW5zaWduZWQgY2hhcgAZCARXSU5CT09MAAN/DUoBAAAEV09SRAADjBo0AQAABERXT1JEAAONHXIBAAACBARmbG9hdAAETFBWT0lEAAOZEZgBAAACAQZzaWduZWQgY2hhcgACAgVzaG9ydCBpbnQABFVMT05HX1BUUgAEMS4JAQAAB0xPTkcAKQEUVgEAAAdIQU5ETEUAnwERmAEAAA9fTElTVF9FTlRSWQAQcQISWwIAAAFGbGluawByAhlbAgAAAAFCbGluawBzAhlbAgAACAAIJwIAAAdMSVNUX0VOVFJZAHQCBScCAAACEARsb25nIGRvdWJsZQACCARkb3VibGUAAgIEX0Zsb2F0MTYAAgIEX19iZjE2ABpKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwRiAQAABYoTEnYDAAALSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAILSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQLSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAD19SVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwAw0iMUbgQAAAFUeXBlANMjDKoBAAAAAUNyZWF0b3JCYWNrVHJhY2VJbmRleADUIwyqAQAAAgFDcml0aWNhbFNlY3Rpb24A1SMlDAUAAAgBUHJvY2Vzc0xvY2tzTGlzdADWIxJgAgAAEAFFbnRyeUNvdW50ANcjDbcBAAAgAUNvbnRlbnRpb25Db3VudADYIw23AQAAJAFGbGFncwDZIw23AQAAKAFDcmVhdG9yQmFja1RyYWNlSW5kZXhIaWdoANojDKoBAAAsAVNwYXJlV09SRADbIwyqAQAALgAPX1JUTF9DUklUSUNBTF9TRUNUSU9OACjtIxQMBQAAAURlYnVnSW5mbwDuIyMRBQAAAAFMb2NrQ291bnQA7yMMCwIAAAgBUmVjdXJzaW9uQ291bnQA8CMMCwIAAAwBT3duaW5nVGhyZWFkAPEjDhgCAAAQAUxvY2tTZW1hcGhvcmUA8iMOGAIAABgBU3BpbkNvdW50APMjEfkBAAAgAAhuBAAAB1BSVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwDcIyM1BQAACHYDAAAHUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMHbgQAAAdQUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMdDAUAAARDUklUSUNBTF9TRUNUSU9OAAarIDoFAAAETFBDUklUSUNBTF9TRUNUSU9OAAatIVcFAAAIrgUAABu5BQAABZgBAAAAEF9fbWluZ3d0aHJfY3MAGhl1BQAACQMAAQFAAQAAABBfX21pbmd3dGhyX2NzX2luaXQAGxVRAQAACQPoAAFAAQAAAARfX21pbmd3dGhyX2tleV90AAEdHxoGAAAT/AUAABxfX21pbmd3dGhyX2tleQAYASAIWQYAABFrZXkAIQm3AQAAABFkdG9yACIKqQUAAAgRbmV4dAAjHlkGAAAQAAgVBgAAEGtleV9kdG9yX2xpc3QAJyNZBgAACQPgAAFAAQAAAB1HZXRMYXN0RXJyb3IACjAbtwEAABRUbHNHZXRWYWx1ZQAJIwEczgEAALEGAAAFtwEAAAAeX2ZwcmVzZXQAARQlDERlbGV0ZUNyaXRpY2FsU2VjdGlvbgAu4AYAAAWOBQAAAAxJbml0aWFsaXplQ3JpdGljYWxTZWN0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BhwMPQIAADwAErcBAAD/AwAAE/IAAAADABK3AQAADwQAABPyAAAACQAHSU1BR0VfRE9TX0hFQURFUgAHHAebAgAAB1BJTUFHRV9ET1NfSEVBREVSAAccGUIEAAAMmwIAAA5fSU1BR0VfRklMRV9IRUFERVIAFGIc/QQAAAFNYWNoaW5lAGMcDLcBAAAAAU51bWJlck9mU2VjdGlvbnMAZBwMtwEAAAIPeAIAAGUcDcQBAAAEAVBvaW50ZXJUb1N5bWJvbFRhYmxlAGYcDcQBAAAIAU51bWJlck9mU3ltYm9scwBnHA3EAQAADAFTaXplT2ZPcHRpb25hbEhlYWRlcgBoHAy3AQAAEA+QAgAAaRwMtwEAABIAB0lNQUdFX0ZJTEVfSEVBREVSAGocB0cEAAAOX0lNQUdFX0RBVEFfRElSRUNUT1JZAAifHFEFAAAPqwIAAKAcDcQBAAAAAVNpemUAoRwNxAEAAAQAB0lNQUdFX0RBVEFfRElSRUNUT1JZAKIcBxcFAAASUQUAAH4FAAAT8gAAAA8ADl9JTUFHRV9PUFRJT05BTF9IRUFERVI2NADw2RyrCAAAAU1hZ2ljANocDLcBAAAAAU1ham9yTGlua2VyVmVyc2lvbgDbHAyqAQAAAgFNaW5vckxpbmtlclZlcnNpb24A3BwMqgEAAAMBU2l6ZU9mQ29kZQDdHA3EAQAABAFTaXplT2ZJbml0aWFsaXplZERhdGEA3hwNxAEAAAgBU2l6ZU9mVW5pbml0aWFsaXplZERhdGEA3xwNxAEAAAwBQWRkcmVzc09mRW50cnlQb2ludADgHA3EAQAAEAFCYXNlT2ZDb2RlAOEcDcQBAAAUAUltYWdlQmFzZQDiHBFKAgAAGAFTZWN0aW9uQWxpZ25tZW50AOMcDcQBAAAgAUZpbGVBbGlnbm1lbnQA5BwNxAEAACQBTWFqb3JPcGVyYXRpbmdTeXN0ZW1WZXJzaW9uAOUcDLcBAAAoAU1pbm9yT3BlcmF0aW5nU3lzdGVtVmVyc2lvbgDmHAy3AQAAKgFNYWpvckltYWdlVmVyc2lvbgDnHAy3AQAALAFNaW5vckltYWdlVmVyc2lvbgDoHAy3AQAALgFNYWpvclN1YnN5c3RlbVZlcnNpb24A6RwMtwEAADABTWlub3JTdWJzeXN0ZW1WZXJzaW9uAOocDLcBAAAyAVdpbjMyVmVyc2lvblZhbHVlAOscDcQBAAA0AVNpemVPZkltYWdlAOwcDcQBAAA4AVNpemVPZkhlYWRlcnMA7RwNxAEAADwBQ2hlY2tTdW0A7hwNxAEAAEABU3Vic3lzdGVtAO8cDLcBAABEAURsbENoYXJhY3RlcmlzdGljcwDwHAy3AQAARgFTaXplT2ZTdGFja1Jlc2VydmUA8RwRSgIAAEgBU2l6ZU9mU3RhY2tDb21taXQA8hwRSgIAAFABU2l6ZU9mSGVhcFJlc2VydmUA8xwRSgIAAFgBU2l6ZU9mSGVhcENvbW1pdAD0HBFKAgAAYAFMb2FkZXJGbGFncwD1HA3EAQAAaAFOdW1iZXJPZlJ2YUFuZFNpemVzAPYcDcQBAABsAURhdGFEaXJlY3RvcnkA9xwcbgUAAHAAB0lNQUdFX09QVElPTkFMX0hFQURFUjY0APgcB34FAAAHUElNQUdFX09QVElPTkFMX0hFQURFUjY0APgcIOwIAAAMfgUAAAdQSU1BR0VfT1BUSU9OQUxfSEVBREVSAAUdJssIAAAiX0lNQUdFX05UX0hFQURFUlM2NAAIAQUPHRRvCQAAAVNpZ25hdHVyZQAQHQ3EAQAAAAFGaWxlSGVhZGVyABEdGf0EAAAEAU9wdGlvbmFsSGVhZGVyABIdH6sIAAAYAAdQSU1BR0VfTlRfSEVBREVSUzY0ABMdG4sJAAAMEAkAAAdQSU1BR0VfTlRfSEVBREVSUwAiHSFvCQAAGoAdB90JAAAYUGh5c2ljYWxBZGRyZXNzAIEdxAEAABhWaXJ0dWFsU2l6ZQCCHcQBAAAADl9JTUFHRV9TRUNUSU9OX0hFQURFUgAofh3ZCgAAAU5hbWUAfx0MiwIAAAABTWlzYwCDHQmqCQAACA+rAgAAhB0NxAEAAAwBU2l6ZU9mUmF3RGF0YQCFHQ3EAQAAEAFQb2ludGVyVG9SYXdEYXRhAIYdDcQBAAAUAVBvaW50ZXJUb1JlbG9jYXRpb25zAIcdDcQBAAAYAVBvaW50ZXJUb0xpbmVudW1iZXJzAIgdDcQBAAAcAU51bWJlck9mUmVsb2NhdGlvbnMAiR0MtwEAACABTnVtYmVyT2ZMaW5lbnVtYmVycwCKHQy3AQAAIg+QAgAAix0NxAEAACQAB1BJTUFHRV9TRUNUSU9OX0hFQURF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dHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbkQAACyEAAAoxkAAAJfTUlOR1dfSU5TVEFMTF9ERUJVR19NQVRIRVJSAAEBBREBAAAJAzCwAEABAAAAAwQFaW50AACtAwAABQABCPEYAAAKR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdWhEAAKERAADgKgBAAQAAAEgAAAAAAAAA3RkAAAVfX2dudWNfdmFfbGlzdAACGB0JAQAACwhfX2J1aWx0aW5fdmFfbGlzdAAhAQAAAQEGY2hhcgAMIQEAAAV2YV9saXN0AAIfGvIAAAABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAAGIQEAAAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAA1faW9idWYAMAMhClUCAAACX3B0cgAlC5IBAAAAAl9jbnQAJgl/AQAACAJfYmFzZQAnC5IBAAAQAl9mbGFnACgJfwEAABgCX2ZpbGUAKQl/AQAAHAJfY2hhcmJ1ZgAqCX8BAAAgAl9idWZzaXoAKwl/AQAAJAJfdG1wZm5hbWUALAuSAQAAKAAFRklMRQADLxnNAQAACF91bmxvY2tfZmlsZQD2BXwCAAADfAIAAAAGVQIAAA5fX21pbmd3X3Bmb3JtYXQABGIN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aAACfAcPBgAAAC4iAwAAAn0FMgYAADIQh74GAAAEbG93AAKIFM8BAAAABGhpZ2gAAogZzwEAAAQvc2lnbl9leHBvbmVudACJowEAABBAL3JlczEAiqMBAAAQUC9yZXMwAIujAQAAIGAAM+ECAAAQhN8GAAAMeAAChhE1BQAADGxoAAKMB2sGAAAALuECAAACjQW+BgAAFCkBAAAj6wYAACRfX3RJMTI4ABABXSIXBwAABGRpZ2l0cwABXgsXBwAAAAAcgQUAACcHAAAfTQEAAAEAD19fdEkxMjgAAV8D9QYAAD/7AgAAEAFhIlcHAAAEZGlnaXRzMzIAAWIMVwcAAAAAHHAFAABnBwAAH00BAAADAC77AgAAAWMDNwcAAEBfX3VJMTI4ABABZSGhBwAADHQxMjgAAWYLJwcAAAx0MTI4XzIAAWcNZwcAAAAPX191STEyOAABaANzBwAAQRABuwm8CAAADF9fcGZvcm1hdF9sb25nX3QAAcAbqgEAAAxfX3Bmb3JtYXRfbGxvbmdfdAABwRtnAQAADF9fcGZvcm1hdF91bG9uZ190AAHCG98BAAAMX19wZm9ybWF0X3VsbG9uZ190AAHDG00BAAAMX19wZm9ybWF0X3VzaG9ydF90AAHEG40BAAAMX19wZm9ybWF0X3VjaGFyX3QAAcUbhwQAAAxfX3Bmb3JtYXRfc2hvcnRfdAABxhtTBQAADF9fcGZvcm1hdF9jaGFyX3QAAccbRAUAAAxfX3Bmb3JtYXRfcHRyX3QAAcgbvAgAAAxfX3Bmb3JtYXRfdTEyOF90AAHJG6EHAAAAQggPX19wZm9ybWF0X2ludGFyZ190AAHKA7EHAAAlzwEAAAHNAUcJAAAHUEZPUk1BVF9JTklUAAAHUEZPUk1BVF9TRVRfV0lEVEgAAQdQRk9STUFUX0dFVF9QUkVDSVNJT04AAgdQRk9STUFUX1NFVF9QUkVDSVNJT04AAwdQRk9STUFUX0VORAAEAA9fX3Bmb3JtYXRfc3RhdGVfdAAB1gPZCAAAJc8BAAAB2QH3CQAAB1BGT1JNQVRfTEVOR1RIX0lOVAAAB1BGT1JNQVRfTEVOR1RIX1NIT1JUAAEHUEZPUk1BVF9MRU5HVEhfTE9ORwACB1BGT1JNQVRfTEVOR1RIX0xMT05HAAMHUEZPUk1BVF9MRU5HVEhfTExPTkcxMjgABAdQRk9STUFUX0xFTkdUSF9DSEFSAAUAD19fcGZvcm1hdF9sZW5ndGhfdAAB4wNhCQAANDAXAQneCgAAEGRlc3QAAR4BErwIAAAAEGZsYWdzAAEfARKjAQAACBB3aWR0aAABIAESowEAAAxDDwMAAAEhARKjAQAAEBBycGxlbgABIgESowEAABQQcnBjaHIAASMBEngBAAAYEHRob3VzYW5kc19jaHJfbGVuAAEkARKjAQAAHBB0aG91c2FuZHNfY2hyAAElARJ4AQAAIBBjb3VudAABJgESowEAACQQcXVvdGEAAScBEqMBAAAoEGV4cG1pbgABKAESowEAACwALV9fcGZvcm1hdF90AAEpAQMSCgAANBANBANDCwAAEF9fcGZvcm1hdF9mcHJlZ19tYW50aXNzYQABDgQaTQEAAAAQX19wZm9ybWF0X2ZwcmVnX2V4cG9uZW50AAEPBBpTBQAACABEEAEFBAnOCwAAJl9fcGZvcm1hdF9mcHJlZ19kb3VibGVfdAALBJEFAAAmX19wZm9ybWF0X2ZwcmVnX2xkb3VibGVfdAAMBDUFAABF8woAACZfX3Bmb3JtYXRfZnByZWdfYml0bWFwABEEzgsAACZfX3Bmb3JtYXRfZnByZWdfYml0cwASBN8BAAAAHI0BAADeCwAAH00BAAAEAC1fX3Bmb3JtYXRfZnByZWdfdAABEwQDQwsAAA9VTG9uZwAJNRffAQAAJc8BAAAJOwb6DAAAB1NUUlRPR19aZXJvAAAHU1RSVE9HX05vcm1hbAABB1NUUlRPR19EZW5vcm1hbAACB1NUUlRPR19JbmZpbml0ZQADB1NUUlRPR19OYU4ABAdTVFJUT0dfTmFOYml0cwAFB1NUUlRPR19Ob051bWJlcgAGB1NUUlRPR19SZXRtYXNrAAcHU1RSVE9HX05lZwAIB1NUUlRPR19JbmV4bG8AEAdTVFJUT0dfSW5leGhpACAHU1RSVE9HX0luZXhhY3QAMAdTVFJUT0dfVW5kZXJmbG93AEAHU1RSVE9HX092ZXJmbG93AIAAJEZQSQAYCVABcA0AAARuYml0cwAJUQajAQAAAARlbWluAAlSBqMBAAAEBGVtYXgACVMGowEAAAgEcm91bmRpbmcACVQGowEAAAwEc3VkZGVuX3VuZGVyZmxvdwAJVQajAQAA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Uk1BVF9MRU5HVEhfTExPTkcxMjgABAhQRk9STUFUX0xFTkdUSF9DSEFSAAUADF9fcGZvcm1hdF9sZW5ndGhfdAAB4wOACQAANjAXAQn9CgAAEWRlc3QAAR4BEtsIAAAAEWZsYWdzAAEfARLCAQAACBF3aWR0aAABIAESwgEAAAxElwMAAAEhARLCAQAAEBFycGxlbgABIgESwgEAABQRcnBjaHIAASMBEogBAAAYEXRob3VzYW5kc19jaHJfbGVuAAEkARLCAQAAHBF0aG91c2FuZHNfY2hyAAElARKIAQAAIBFjb3VudAABJgESwgEAACQRcXVvdGEAAScBEsIBAAAoEWV4cG1pbgABKAESwgEAACwALV9fcGZvcm1hdF90AAEpAQMxCgAANhANBANiCwAAEV9fcGZvcm1hdF9mcHJlZ19tYW50aXNzYQABDgQaTQEAAAARX19wZm9ybWF0X2ZwcmVnX2V4cG9uZW50AAEPBBptBQAACABFEAEFBAntCwAAJl9fcGZvcm1hdF9mcHJlZ19kb3VibGVfdAALBKsFAAAmX19wZm9ybWF0X2ZwcmVnX2xkb3VibGVfdAAMBE8FAABGEgsAACZfX3Bmb3JtYXRfZnByZWdfYml0bWFwABEE7QsAACZfX3Bmb3JtYXRfZnByZWdfYml0cwASBPkBAAAAHp0BAAD9CwAAH00BAAAEAC1fX3Bmb3JtYXRfZnByZWdfdAABEwQDYgsAAAxVTG9uZwAJNRf5AQAAJekBAAAJOwYZDQAACFNUUlRPR19aZXJvAAAIU1RSVE9HX05vcm1hbAABCFNUUlRPR19EZW5vcm1hbAACCFNUUlRPR19JbmZpbml0ZQADCFNUUlRPR19OYU4ABAhTVFJUT0dfTmFOYml0cwAFCFNUUlRPR19Ob051bWJlcgAGCFNUUlRPR19SZXRtYXNrAAcIU1RSVE9HX05lZwAICFNUUlRPR19JbmV4bG8AEAhTVFJUT0dfSW5leGhpACAIU1RSVE9HX0luZXhhY3QAMAhTVFJUT0dfVW5kZXJmbG93AEAIU1RSVE9HX092ZXJmbG93AIAAJEZQSQAYCVABjw0AAANuYml0cwAJUQbCAQAAAANlbWluAAlSBsIBAAAEA2VtYXgACVMGwgEAAAgDcm91bmRpbmcACVQGwgEAAAwDc3VkZGVuX3Vu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AAAbR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdvxYAALgWAADQeQBAAQAAABMWAAAAAAAArWcAAAcBBmNoYXIAEXNpemVfdAADIywJAQAABwgHbG9uZyBsb25nIHVuc2lnbmVkIGludAAHCAVsb25nIGxvbmcgaW50AAcCB3Nob3J0IHVuc2lnbmVkIGludAAHBAVpbnQABwQFbG9uZyBpbnQACvIAAAAKSgEAAAcEB3Vuc2lnbmVkIGludAAHBAdsb25nIHVuc2lnbmVkIGludAAHAQh1bnNpZ25lZCBjaGFyAAcQBGxvbmcgZG91YmxlABFVTG9uZwAENRd3AQAAHAcEZwEAAAQ7Bq8CAAAFU1RSVE9HX1plcm8AAAVTVFJUT0dfTm9ybWFsAAEFU1RSVE9HX0Rlbm9ybWFsAAIFU1RSVE9HX0luZmluaXRlAAMFU1RSVE9HX05hTgAEBVNUUlRPR19OYU5iaXRzAAUFU1RSVE9HX05vTnVtYmVyAAYFU1RSVE9HX1JldG1hc2sABwVTVFJUT0dfTmVnAAgFU1RSVE9HX0luZXhsbwAQBVNUUlRPR19JbmV4aGkAIAVTVFJUT0dfSW5leGFjdAAwBVNUUlRPR19VbmRlcmZsb3cAQAVTVFJUT0dfT3ZlcmZsb3cAgAAdRlBJABgEUAEZAwAAC25iaXRzAFFKAQAAAAtlbWluAFJKAQAABAtlbWF4AFNKAQAACAtyb3VuZGluZwBUSgEAAAwLc3VkZGVuX3VuZGVyZmxvdwBVSgEAABALaW50X21heABWSgEAABQAEUZQSQAEVwOvAgAABwgEZG91YmxlABQlAwAABwQEZmxvYXQACl0BAAAeX2RibF91bmlvbgAIAhkBD2gDAAAVZAAjJQMAABVMACxoAwAAABKsAQAAeAMAABYJAQAAAQAf1AMAACAC1QEB1gMAAAxuZXh0ANYB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X2JmMTYAM0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwAHBHsBAAAHihMSeQMAABpKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAhpKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABBpKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAfX1JUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHADDSIxR6BAAABFR5cGUAB9MjDLMBAAAABENyZWF0b3JCYWNrVHJhY2VJbmRleAAH1CMMswEAAAIEQ3JpdGljYWxTZWN0aW9uAAfVIyUeBQAACARQcm9jZXNzTG9ja3NMaXN0AAfWIxJiAgAAEARFbnRyeUNvdW50AAfXIw3AAQAAIARDb250ZW50aW9uQ291bnQAB9gjDcABAAAkBEZsYWdzAAfZIw3AAQAAKARDcmVhdG9yQmFja1RyYWNlSW5kZXhIaWdoAAfaIwyzAQAALARTcGFyZVdPUkQAB9sjDLMBAAAuAB9fUlRMX0NSSVRJQ0FMX1NFQ1RJT04AKO0jFB4FAAAERGVidWdJbmZvAAfuIyMjBQAAAARMb2NrQ291bnQAB+8jDAsCAAAIBFJlY3Vyc2lvbkNvdW50AAfwIwwLAgAADARPd25pbmdUaHJlYWQAB/EjDhgCAAAQBExvY2tTZW1hcGhvcmUAB/IjDhgCAAAYBFNwaW5Db3VudAAH8yMR+QEAACAACXoEAAATUFJUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHANwjI0cFAAAJeQMAABNSVExfQ1JJVElDQUxfU0VDVElPTgD0Iwd6BAAAE1BSVExfQ1JJVElDQUxfU0VDVElPTgD0Ix0eBQAADkNSSVRJQ0FMX1NFQ1RJT04ACKsgTAUAAA5MUENSSVRJQ0FMX1NFQ1RJT04ACK0haQUAAA2HBQAAywUAAA8YAQAAAQAWZHRvYV9Dcml0U2VjADcZuwUAAAkDAAsBQAEAAAAWZHRvYV9DU19pbml0ADgNYAEAAAkD8AoBQAEAAAAOVUxvbmcACTUXiwEAAAnyAAAACQQBAAA0X2Ri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AQjTLgAAA0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHZYZAADVGQAAIJ4AQAEAAAAoAAAAAAAAACSJAAABAQZjaGFyAATyAAAABXNpemVfdAACIywOAQAAAQgHbG9uZyBsb25nIHVuc2lnbmVkIGludAABCAVsb25nIGxvbmcgaW50AAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABnN0cm5sZW4AAQQQ/wAAACCeAEABAAAAKAAAAAAAAAABnOsBAAACcwAl6wEAAAFSAm1heGxlbgAv/wAAAAFRB3MyAAEGD+sBAADrkQAA55EAAAAICPoAAAAABQIAAAUAAQhVLwAABEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHVYaAACVGgAAUJ4AQAEAAAAlAAAAAAAAAKWJAAABAQZjaGFyAAJzaXplX3QAIywIAQAAAQgHbG9uZyBsb25nIHVuc2lnbmVkIGludAABCAVsb25nIGxvbmcgaW50AAJ3Y2hhcl90AGIYRwEAAAUzAQAAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAABBAd1bnNpZ25lZCBpbnQAAQQHbG9uZyB1bnNpZ25lZCBpbnQAAQEIdW5zaWduZWQgY2hhcgAGd2NzbmxlbgABBQH6AAAAUJ4AQAEAAAAlAAAAAAAAAAGcAgIAAAN3ABgCAgAACJIAAAKSAAADbmNudAAi+gAAACySAAAmkgAAB24AAQcK+gAAAECSAAA8kgAAAAgIQgEAAABqAQAABQABCNsvAAADR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdFhsAAFgbAACAngBAAQAAAAsAAAAAAAAAPYoAAAEBBmNoYXIABF9faW1wX19mbW9kZQABCQ4PAQAAAhQBAAABBAVpbnQABQ8BAAAGX19pbXBfX19wX19mbW9kZQABERVDAQAACQOQsABAAQAAAAIbAQAAB19fcF9fZm1vZGUAAQwODwEAAICeAEABAAAACwAAAAAAAAABnABwAQAABQABCE4wAAADR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdtRsAAPkbAACQngBAAQAAAAsAAAAAAAAAm4oAAAEBBmNoYXIABF9faW1wX19jb21tb2RlAAEJDhEBAAACFgEAAAEEBWludAAFEQEAAAZfX2ltcF9fX3BfX2NvbW1vZGUAAREXRwEAAAkDoLAAQAEAAAACHQEAAAdfX3BfX2NvbW1vZGUAAQwOEQEAAJCeAEABAAAACwAAAAAAAAABnACWCwAABQABCMEwAAAUR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdYRwAAFocAACgngBAAQAAANkAAAAAAAAA+YoAAAMBBmNoYXIAAwgHbG9uZyBsb25nIHVuc2lnbmVkIGludAADCAVsb25nIGxvbmcgaW50AAMCB3Nob3J0IHVuc2lnbmVkIGludAADBAVpbnQAAwQFbG9uZyBpbnQACvIAAAADBAd1bnNpZ25lZCBpbnQAAwQHbG9uZyB1bnNpZ25lZCBpbnQAAwEIdW5zaWduZWQgY2hhcgAVX2lvYnVmADACIQoZAgAABF9wdHIAAiULTgEAAAAEX2NudAACJgk7AQAACARfYmFzZQACJwtOAQAAEARfZmxhZwACKAk7AQAAGARfZmlsZQACKQk7AQAAHARfY2hhcmJ1ZgACKgk7AQAAIARfYnVmc2l6AAIrCTsBAAAkBF90bXBmbmFtZQACLAtOAQAAKAAHRklMRQACLxmJAQAAB1dPUkQAA4waJQEAAAdEV09SRAADjR1jAQAAAwQEZmxvYXQAFggDAQZzaWduZWQgY2hhcgADAgVzaG9ydCBpbnQAB1VMT05HX1BUUgAEMS76AAAACExPTkcAKQEUQgEAAAhIQU5ETEUAnwERSgIAAA5fTElTVF9FTlRSWQAQcQISygIAAAJGbGluawByAhnKAgAAAAJCbGluawBzAhnKAgAACAAKlgIAAAhMSVNUX0VOVFJZAHQCBZYCAAADEARsb25nIGRvdWJsZQADCARkb3VibGUAAwIEX0Zsb2F0MTYAAwIEX19iZjE2AA9KT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAUwEAAAWKExLjAwAAAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA5fUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcAMNIjFNsEAAACVHlwZQDTIwwmAgAAAAJDcmVhdG9yQmFja1RyYWNlSW5kZXgA1CMMJgIAAAICQ3JpdGljYWxTZWN0aW9uANUjJXkFAAAIAlByb2Nlc3NMb2Nrc0xpc3QA1iMSzwIAABACRW50cnlDb3VudADXIw0zAgAAIAJDb250ZW50aW9uQ291bnQA2CMNMwIAACQCRmxhZ3MA2SMNMwIAACgCQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaADaIwwmAgAALAJTcGFyZVdPUkQA2yMMJgIAAC4ADl9SVExfQ1JJVElDQUxfU0VDVElPTgAo7SMUeQUAAAJEZWJ1Z0luZm8A7iMjfgUAAAACTG9ja0NvdW50AO8jDHoCAAAIAlJlY3Vyc2lvbkNvdW50APAjDHoCAAAMAk93bmluZ1RocmVhZADxIw6HAgAAEAJMb2NrU2VtYXBob3JlAPIjDocCAAAYAlNwaW5Db3VudADzIxFoAgAAIAAK2wQAAAhQUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcA3CMjogUAAArjAwAACFJUTF9DUklUSUNBTF9TRUNUSU9OAPQjB9sEAAAIUFJUTF9DUklUSUNBTF9TRUNUSU9OAPQjHXkFAAAHQ1JJVElDQUxfU0VDVElPTgAGqyCnBQAAB0xQQ1JJVElDQUxfU0VDVElPTgAGrSHEBQAAF3RhZ0NPSU5JVEJBU0UABwRTAQAAB5UOTgYAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAPVkFSRU5VTQBTAQAACAkCBtgIAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5U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Sk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAQdGFnQ09JTklUQkFTRQAHBHUBAAAGlQ5cAwAAAUNPSU5JVEJBU0VfTVVMVElUSFJFQURFRAAAAAdWQVJFTlVNAHUBAAAHCQIG5gUAAAFWVF9FTVBUWQAAAVZUX05VTEwAAQFWVF9JMgACAVZUX0k0AAMBVlRfUjQABAFWVF9SOAAFAVZUX0NZAAYBVlRfREFURQAHAVZUX0JTVFIACAFWVF9ESVNQQVRDSAAJAVZUX0VSUk9SAAoBVlRfQk9PTAALAVZUX1ZBUklBTlQADAFWVF9VTktOT1dOAA0BVlRfREVDSU1BTAAOAVZUX0kxABABVlRfVUkxABEBVlRfVUkyABIBVlRfVUk0ABMBVlRfSTgAFAFWVF9VSTgAFQFWVF9JTlQAFgFWVF9VSU5UABcBVlRfVk9JRAAYAVZUX0hSRVNVTFQAGQFWVF9QVFIAGgFWVF9TQUZFQVJSQVkAGwFWVF9DQVJSQVkAHAFWVF9VU0VSREVGSU5FRAAdAVZUX0xQU1RSAB4BVlRfTFBXU1RSAB8BVlRfUkVDT1JEACQBVlRfSU5UX1BUUgAlAVZUX1VJTlRfUFRSACYBVlRfRklMRVRJTUUAQAFWVF9CTE9CAEEBVlRfU1RSRUFNAEIBVlRfU1RPUkFHRQBDAVZUX1NUUkVBTUVEX09CSkVDVABEAVZUX1NUT1JFRF9PQkpFQ1QARQFWVF9CTE9CX09CSkVDVABGAVZUX0NGAEcBVlRfQ0xTSUQASAFWVF9WRVJTSU9ORURfU1RSRUFNAEkDVlRfQlNUUl9CTE9CAP8PA1ZUX1ZFQ1RPUgAAEANWVF9BUlJBWQAAIANWVF9CWVJFRgAAQANWVF9SRVNFUlZFRAAAgANWVF9JTExFR0FMAP//A1ZUX0lMTEVHQUxNQVNLRUQA/w8DVlRfVFlQRU1BU0sA/w8AEWhhbmRsZXIAAQUj8AEAAAkDYAsBQAEAAAAS8AEAAA8GAAAE8AEAAAAIX19pbXBfX3NldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAAxEBgAACQPIsABAAQAAAAUABgAAE/ABAAAIX19pbXBfX2dldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyABSDBgAACQPAsABAAQAAAAVJBgAAFG1pbmd3X2dldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAAEPK/ABAACAnwBAAQAAAAgAAAAAAAAAAZwVbWluZ3dfc2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIAAQcr8AEAAJCfAEABAAAACwAAAAAAAAABnFsHAAAWbmV3X2hhbmRsZXIAAQdq8AEAAAFSF1sHAACTnwBAAQAAAACTnwBAAQAAAAcAAAAAAAAAAQkMCZIHAAD1kgAA85IAAAmFBwAA/ZIAAPuSAAAAABhfSW50ZXJsb2NrZWRFeGNoYW5nZVBvaW50ZXIAAtMGB6sBAAADnwcAAApUYXJnZXQAM58HAAAKVmFsdWUAQKsBAAAABa0BAAAA1QIAAAUAAQgHNAAABUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHQYfAABMHwAAoJ8AQAEAAAAmAAAAAAAAAO6MAAABAQZjaGFyAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAPyAAAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABl9pb2J1ZgAwAiEKEQIAAAJfcHRyACULTgEAAAACX2NudAAmCTsBAAAIAl9iYXNlACcLTgEAABACX2ZsYWcAKAk7AQAAGAJfZmlsZQApCTsBAAAcAl9jaGFyYnVmACoJOwEAACACX2J1ZnNpegArCTsBAAAkAl90bXBmbmFtZQAsC04BAAAoAARGSUxFAAIviQEAAARfZl9fYWNydF9pb2JfZnVuYwABDjYCAAADOwIAAAdKAgAASgIAAAhTAQAAAAMRAgAACV9faW1wX19fYWNydF9pb2JfZnVuYwABDxMdAgAACQPQsABAAQAAAApfX2lvYl9mdW5jAAJgGUoCAAALX19hY3J0X2lvYl9mdW5jAAEJD0oCAACgnwBAAQAAACYAAAAAAAAAAZwMaW5kZXgAAQkoUwEAAB6TAAAYkwAADbKfAEABAAAAdwIAAAAAcAYAAAUAAQjVNAAAD0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHd8fAADYHwAA0J8AQAEAAADmAQAAAAAAAGWNAAABAQZjaGFyAAdzaXplX3QAAiMsCQEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAAHd2NoYXJfdAACYhhJAQAACjQBAAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AATyAAAABF8BAAABBAd1bnNpZ25lZCBpbnQACnwBAAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAAECBXNob3J0IGludAAIbWJzdGF0ZV90AAOlBQ9fAQAAAQgEZG91YmxlAAEEBGZsb2F0AAEQBGxvbmcgZG91YmxlAAREAQAAB1dJTkJPT0wABH8NXwEAAAT+AQAAB0xQQk9PTAAEhw8OAgAAB0RXT1JEAASNHZEBAAAHVUlOVAAEnxh8AQAAAQEGc2lnbmVkIGNoYXIACENIQVIABScBEPIAAAAKTAIAAAhXQ0hBUgAFMQETNAEAAApfAgAACExQQ1dDSAAFNAEYgwIAAARuAgAABEwCAAAITFBDQ0gABVkBF5wCAAAEWgIAAAhMUFNUUgAFWgEYiAIAAAECBF9GbG9hdDE2AAECBF9fYmYxNgAQV2lkZUNoYXJUb011bHRpQnl0ZQAIKhlfAQAADwMAAAUwAgAABSICAAAFcwIAAAVfAQAABaECAAAFXwEAAAWNAgAABRMCAAAAC19lcnJubwAGmh93AQAAC19fX2xjX2NvZGVwYWdlX2Z1bmMABwkWfAEAAAtfX19tYl9jdXJfbWF4X2Z1bmMABnkVXwEAAA13Y3NydG9tYnMAOAj6AAAAsKAAQAEAAAAGAQAAAAAAAAGcmgQAAANkc3QAOBlyAQAAQpMAADqTAAADc3JjADgumgQAAGeTAABfkwAAA2xlbgA4OvoAAACVkwAAh5MAAANwcwA5EZ8EAADUkwAA0JMAAAZyZXQAOwdfAQAA+JMAAOaTAAAGbgA8CvoAAABOlAAAPpQAAAZjcAA9FowBAACTlAAAjZQAAAZtYl9tYXgAPhaMAQAAsZQAAKmUAAAGcHdjAD8S+QEAANKUAADOlAAAEUoHAABfBAAADvwDAABXDKQEAAADkat/DImhAEABAAAAdAUAAAIBUgJ1AAIBWAJzAAIBWQJ0AAAACdagAEABAAAAHgMAAAndoABAAQAAADoDAAAML6EAQAEAAAB0BQAAAgFSAn8AAgFYAnMAAgFZAnQAAAAE+QEAAATEAQAAEvIAAAC0BAAAEwkBAAAEAA13Y3J0b21iADAB+gAAAGCgAEABAAAARQAAAAAAAAABnHQFAAADZHN0ADAQcgEAAOWUAADhlAAAA3djADAdNAEAAP2UAAD3lAAAA3BzADAtnwQAABqVAAAWlQAADvwDAAAyCKQEAAACkUsGdG1wX2RzdAAzCXIBAAAwlQAALJUAAAmCoABAAQAAADoDAAAJiaAAQAEAAAAeAwAADJqgAEABAAAAdAUAAAIBUgJzAAIBUQZ0AAr//xoCAVkCdQAAABRfX3djcnRvbWJfY3AAARICXwEAANCfAEABAAAAhgAAAAAAAAABnANkc3QAEhZyAQAAWJUAAE6VAAADd2MAEiM0AQAAgZUAAHmVAAADY3AAEjqMAQAAoJUAAJiVAAADbWJfbWF4ABMcjAEAAMaVAAC8lQAAFQCgAEABAAAAUAAAAAAAAAAWaW52YWxpZF9jaGFyAAEhC18BAAACkWwGc2l6ZQAjC18BAADqlQAA6JUAABc1oABAAQAAAMYCAABkBgAAAgFRATACAVgCkQgCAVkBMQICdyADowFSAgJ3KAOjAVkCAncwATACAnc4ApFsAAlFoABAAQAAAA8DAAAAAAAOCAAABQABCCQ2AAATR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAd2yAAABohAADAoQBAAQAAAEEDAAAAAAAAhI8AAAMBBmNoYXIADfIAAAAHc2l6ZV90AAIjLA4BAAADCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAMIBWxvbmcgbG9uZyBpbnQAB3djaGFyX3QAAmIYSQEAAAMCB3Nob3J0IHVuc2lnbmVkIGludAADBAVpbnQAAwQFbG9uZyBpbnQABTkBAAALcgEAAAVfAQAAAwQHdW5zaWduZWQgaW50AA2BAQAAAwQHbG9uZyB1bnNpZ25lZCBpbnQAAwEIdW5zaWduZWQgY2hhcgADAgVzaG9ydCBpbnQACW1ic3RhdGVfdAADpQUPXwEAAAMIBGRvdWJsZQADBARmbG9hdAADEARsb25nIGRvdWJsZQAHV0lOQk9PTAAEfw1fAQAAB0JZVEUABIsZqwEAAAdEV09SRAAEjR2WAQAAB1VJTlQABJ8YgQEAAAMBBnNpZ25lZCBjaGFyAAlDSEFSAAUnARDyAAAADUUCAAAJV0NIQVIABTEBEzkBAAAFWAIAAAlMUFdTVFIABTUBGmcCAAAJTFBDQ0gABVkBF4sCAAAFUwIAAAMCBF9GbG9hdDE2AAMCBF9fYmYxNgAUSXNEQkNTTGVhZEJ5dGVFeAAGsAMd/gEAAM8CAAAEKQIAAAQOAgAAAA5fZXJybm8ACJoffAEAABVNdWx0aUJ5dGVUb1dpZGVDaGFyAAcpGV8BAAAdAwAABCkCAAAEGwIAAAR8AgAABF8BAAAEbAIAAARfAQAAAA5fX19sY19jb2RlcGFnZV9mdW5jAAkJFoEBAAAOX19fbWJfY3VyX21heF9mdW5jAAh5FV8BAAAPbWJybGVuAJX/AAAAoKQAQAEAAABhAAAAAAAAAAGcHAQAAAJzAJUjIQQAAAKWAAD8lQAAAm4AlS3/AAAAIZYAABuWAAACcHMAlhsrBAAAQJYAADqWAAARc19tYnN0YXRlAJgUyQEAAAkDcAsBQAEAAAAKCAQAAJkLOQEAAAKRTgbDpABAAQAAADkDAAAGy6QAQAEAAAAdAwAADPSkAEABAAAAtgYAAAEBUgKRbgEBUQJ0AAEBWAJ1AAEBWQJzAAECdygCfAAAAAX6AAAACxwEAAAFyQEAAAsmBAAAD21ic3J0b3djcwBt/wAAAICjAEABAAAAFQEAAAAAAAABnLAFAAACZHN0AG0idwEAAGOWAABZlgAAAnNyYwBtQ7UFAACSlgAAipYAAAJsZW4Abgz/AAAAvpYAALKWAAACcHMAbikrBAAA85YAAO+WAAAIcmV0AHAHXwEAABWXAAAFlwAACG4AcQr/AAAAXpcAAFKXAAAKFAQAAHIUyQEAAAkDdAsBQAEAAAAIaW50ZXJuYWxfcHMAcw4mBAAAkpcAAIyXAAAIY3AAdBaRAQAAxJcAAL6XAAAIbWJfbWF4AHUWkQEAAOSXAADalwAAFmEHAABkBQAACggEAACLDzkBAAADka5/DIOkAEABAAAAtgYAAAEBUgJ1AAEBWAJ/AAEBWQJ0AAECdyACfQABAncoAnwAAAAGtKMAQAEAAAAdAwAABryjAEABAAAAOQMAAAwapABAAQAAALYGAAABAVICfwABAVgFdQB+ABwBAVkCdAABAncgAn0AAQJ3KAJ8AAAABRwEAAALsAUAAA9tYnJ0b3djAGD/AAAAEKMAQAEAAABvAAAAAAAAAAGctgYAAAJwd2MAYCF3AQAADJgAAAiYAAACcwBgQCEEAAAkmAAAHpgAAAJuAGEK/wAAAEOYAAA9mAAAAnBzAGElKwQAAGKYAABcmAAAChQEAABjFMkBAAAJA3gLAUABAAAACggEAABkDDkBAAADkb5/CGRzdABlDHIBAAB/mAAAe5gAAAZDowBAAQAAADkDAAAGS6MAQAEAAAAdAwAADHCjAEABAAAAtgYAAAEBUgJzAAEBUQJ1AAEBWAJ8AAEBWRR0AAN4CwFAAQAAAHQAMC4oAQAWEwECdygCfQAAABdfX21icnRvd2NfY3AAARABXwEAAMChAEABAAAARwEAAAAAAAABnAUIAAACcHdjABAmdwEAALGYAACdmAAAAnMAEEUhBAAADpkAAP6YAAACbgARD/8AAABZmQAATZkAAAJwcwARKisEAACSmQAAhpkAAAJjcAASG5EBAADFmQAAv5kAAAJtYl9tYXgAEjKRAQAA4pkAANyZAAAYBAEUA3EHAAASdmFsABUPyQEAABJtYmNzABYKBQgAAAARc2hpZnRfc3RhdGUAFwVQBwAAApFcEBuiAEABAAAApgIAAKEHAAABAVIEkTCUBAAQVaIAQAEAAADeAgAAwAcAAAEBUgSRMJQEAQFRATgAEOSiAEABAAAA3gIAAPcHAAABAVIEkTCUBAEBUQE4AQFYAnMAAQFZATEBAncgAnUAAQJ3KAExAAbtogBAAQAAAM8CAAAAGfIAAAAaDgEAAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ0AAwg6IQI7BTkLSRM4CwAAAg0AAw46IQI7BTkLSRM4CwAAAygAAwgcCwAABAUASRMAAAUPAAshCEkTAAAGFgADCDohAjsFOQtJEwAABzQAAwg6CzsLOQtJEz8ZPBkAAAgkAAsLPgsDCAAACRYAAwg6CzsLOQtJEwAACkkAAhh+GAAAC0gAfQF/EwAADA0AAwg6IQI7BTkLSROIASEQOAUAAA0NAAMIOiECOwU5C0kTiAEhEDgLAAAOEwEDCAsLOiECOwU5CwETAAAPIQBJEy8LAAAQNAADCDoLOwU5C0kTAAARSAF9AX8TARMAABIoAAMIHAUAABMFAAMIOgs7BTkLSRMAABQ0ADETAhe3QhcAABUNAAMIOiECOwU5C0kTOAUAABYBAUkTARMAABc0AAMIOiEBOws5C0kTAhgAABgNAAMIOiECOwU5C0kTAAAZDQADCDoLOws5C0kTOAsAABouAT8ZAwg6CzsLOQsnGUkTPBkBEwAAGwUAMRMCF7dCFwAAHEkAAhgAAB0uAT8ZAwg6CzsLOQsnGTwZARMAAB5IAX0BfxMAAB80AAMIOiEBOws5C0kTAhe3QhcAACAFAAMIOiEBOws5C0kTAhgAACEBAUkTiAEhEAETAAAiLgE/GQMIOgs7BTkLJxlJEzwZARMAACMuAD8ZAwg6CzsLOQsnGTwZAAAkJgBJEwAAJRUBJxlJEwETAAAmFwELIQg6IQI7BTkhFgETAAAnDQBJEzgLAAAoNAADCDohATsFOSEMSRM/GTwZAAApLgA/GQMIOgs7CzkLJxlJEzwZAAAqHQExE1IBuEILVRdYIQFZC1cLARMAACsLAVUXAAAsLgE/GQMIOiEDOwU5CycZSRMgIQMBEwAALTUASRMAAC4TAQMICwWIASEQOiECOwU5CwETAAAvFgADCDohAjsFOQtJE4gBIRAAADAVAScZARMAADENAAMIOiECOwU5IRdJE4gBIRAAADIEAQMIPiEHCyEESRM6CzsFOQsBEwAAMyEAAAA0NAADCDohATsLOSEeSRM/GQIYAAA1LgEDCDohATsLOSEBJxlJExEBEgdAGHoZARMAADYFADETAAA3LgE/GQMIOiEBOws5IQUnGUkTEQESB0AYehkBEwAAOC4BAwg6IQE7CzkhAScZEQESB0AYehkBEwAAOREBJQgTCwMfGx8RARIHEBcAADoPAAsLAAA7DQBJE4gBCzgFAAA8JgAAAD0TAQMICwuIAQs6CzsFOQsBEwAAPhUAJxlJEwAAPxUAJxkAAEATAQsFiAELOgs7BTkLARMAAEEXAQsFiAELOgs7BTkLARMAAEINAEkTiAELAABDEwEDCAsFOgs7BTkLARMAAEQEAQMIPgsLC0kTOgs7CzkLARMAAEUTAQsLOgs7CzkLARMAAEYEAQMOPgsLC0kTOgs7CzkLARMAAEcWAAMOOgs7CzkLSRMAAEg1AAAASRMBAwgLCzoLOws5CwETAABKNAADCDoLOws5C0kTAABLNAADCDoLOwU5C0kTPxkCGAAATC4BPxkDCDoLOwU5CycZhwEZPBkBEwAATS4BPxkDCDoLOwU5CycZSRMRARIHQBh6GQETAABOBQADCDoLOwU5C0kTAhe3QhcAAE8uAQMIOgs7BTkLJxkgCwETAABQCwEAAFEuAQMIOgs7BTkLJxlJEyALARMAAFIdATETUgG4QgtVF1gLWQVXCwAAUx0BMRNSAbhCC1UXWAtZBVcLARMAAFQLATETVRcBEwAAVR0BMRNSAbhCCxEBEgdYC1kLVwsBEwAAVkgBfQEBEwAAVzQAMRMAAFgTAAMIPBkAAFkuAD8ZAwg6CzsFOQsnGUkTIAsAAFouAD8ZPBluCAMIOgs7CwAAAAEoAAMIHAsAAAIkAAsLPgsDCAAAAygAAwgcBQAABBYAAwg6CzsLOQtJEwAABQ8ACyEISRMAAAYEAQMIPiEHCyEESRM6CzsFOQsBEwAABzQAAwg6IQE7CzkhEUkTPxk8GQAACDQAAwg6IQE7CzkLSRMCGAAACS4BPxkDCDohATsLOSEBJxkRARIHQBh8GQETAAAKNAADCDohATsLOSERSRMCF7dCFwAACxEBJQgTCwMfGx8RARIHEBcAAAwVACcZAAANBAEDCD4LCwtJEzoLOws5CwETAAAOAQFJEwETAAAPIQAAABAuAT8ZAwg6CzsFOQsnGUkTPBkBEwAAEQUASRMAABIuAT8ZAwg6CzsLOQsnGREBEgdAGHoZARMAABNIAH0BggEZfxMAABRIAX0BggEZfxMAABVJAAIYfhgAAAABKAADCBwLAAACJAALCz4LAwgAAAMoAAMIHAUAAAQ0AAMIOiEEOws5C0kTPxk8GQAABTQARxM6IQU7CzkLAhgAAAY1AEkTAAAHBAEDCD4hBwshBEkTOgs7BTkLARMAAAgRASUIEwsDHxsfEBcAAAkEAQMIPgsLC0kTOgs7CzkLARMAAAoEAQMOPgsLC0kTOgs7CzkLARMAAAsWAAMOOgs7CzkLSRMAAAwPAAsLSRMAAA01AAAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABEQElCBMLAx8bHxAXAAACNAADCDoLOws5C0kTPxkCGAAAAyQACws+CwMIAAAAASQACws+CwMIAAACNAADCDohATsLOQtJEz8ZAhgAAAMWAAMIOgs7CzkLSRMAAAQWAAMIOiEFOwU5C0kTAAAFBQBJEwAABg0AAwg6IQU7BTkLSRM4CwAABwUAMRMCF7dCFwAACA8ACyEISRMAAAkoAAMIHAsAAAoFAAMOOiEBOyGIATkLSRMCF7dCFwAACwUAAw46IQE7IcwAOQtJEwAADCYASRMAAA00AAMIOiEBOws5ISRJEwIYAAAOSAB9AX8TAAAPNAADCDohATsLOQtJEwAAEDQAMRMAABE0ADETAhe3QhcAABIRASUIEwsDHxsfEQESBxAXAAATDwALCwAAFBUAJxkAABUEAQMIPgsLC0kTOgs7BTkLARMAABYVAScZARMAABcTAQMICws6CzsFOQsBEwAAGDQAAwg6CzsLOQtJEz8ZPBkAABkuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAGi4BAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAGy4BPxkDCDoLOws5CycZSRMRARIHQBh6GQETAAAcBQADCDoLOws5C0kTAhgAAB0uAT8ZAwg6CzsLOQsnGUkTIAsBEwAAHi4BMRMRARIHQBh8GQAAHx0BMRNSAbhCCxEBEgdYC1kLVwsBEwAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABJAALCz4LAwgAAAI0AAMIOiEBOws5IR1JEz8ZAhgAAAMRASUIEwsDHxsfEBcAAAQWAAMIOgs7CzkLSRMAAAUPAAsLSRMAAAYVACcZAAAHAQFJEwETAAAIIQBJEy8LAAAAAQ0AAwg6CzsLOQtJEzgLAAACJAALCz4LAwgAAANJAAIYfhgAAAQPAAshCEkTAAAFBQBJEwAABhMBAwgLCzoLOws5IQoBEwAABzcASRMAAAgRASUIEwsDHxsfEQESBxAXAAAJJgBJEwAAChYAAwg6CzsLOQtJEwAACy4BPxkDCDoLOwU5CycZSRM8GQETAAAMGAAAAA0uAT8ZAwg6CzsLOQsnGUkTPBkBEwAADi4BPxkDCDoLOwU5CycZSRMRARIHQBh6GQETAAAPBQADCDoLOws5C0kTAhe3QhcAABA0AAMIOgs7CzkLSRMCF7dCFwAAEUgBfQF/EwETAAASSAF9AX8TAAAAASQACws+CwMIAAACEQElCBMLAx8bHxEBEgcQFwAAAy4APxkDCDoLOws5CycZSRMRARIHQBh6GQAAAAERASUIEwsDHxsfEQESBxAXAAACLgA/GQMIOgs7CzkLJxkRARIHQBh6GQAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABKAADCBwLAAACDQADCDohBjsFOQtJEzgLAAADBQAxEwIXt0IXAAAESQACGH4YAAAFDQADCDoLOws5C0kTOAsAAAYWAAMIOgs7CzkLSRMAAAckAAsLPgsDCAAACAUASRMAAAkPAAshCEkTAAAKNAAxEwIXt0IXAAALSAF9AX8TAAAMNAADCDohATsFOQtJEwAADUgBfQF/EwETAAAOKAADCBwFAAAPFgADCDohBjsFOQtJEwAAEAUAAwg6IQE7BTkLSRMAABEuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAEh0BMRNSAbhCCxEBEgdYIQFZBVcLAAATNAADCDohATsLOQtJEwIYAAAUSAB9AX8TAAAVEwEDCAsLOiEGOwU5IRQBEwAAFgEBSRMBEwAAFyEASRMvCwAAGDQAAwg6IQE7CzkLSRM/GTwZAAAZEwELCzohATsLOSEJARMAABouAD8ZAwg6CzsLOQsnGUkTPBkAABsFADETAAAcHQExE1IBuEILEQESB1ghAVkFVyEMARMAAB00AAMIOiEBOws5C0kTAhe3QhcAAB4EAQMIPiEHCyEESRM6CzsFOQsBEwAAHw0AAwg6IQY7BTkhCEkTAAAgNwBJEwAAIR0BMRNSAbhCC1UXWCEBWQVXCwETAAAiCwExE1UXARMAACMuAQMIOiEBOwU5IQEnGSAhAQETAAAkCwEAACU0AAMIOiEBOws5C0kTAAAmBQADCDohATsLOQtJEwIXt0IXAAAnEQElCBMLAx8bHxEBEgcQFwAAKA8ACwsDCEkTAAApJgBJEwAAKg8ACwsAACsmAAAALBcBCws6CzsFOQsBEwAALQQBAwg+CwsLSRM6CzsLOQsBEwAALhMBAwgLCzoLOws5CwETAAAvEwEDDgsLOgs7CzkLARMAADAWAAMOOgs7CzkLSRMAADEuAD8ZAwg6CzsFOQsnGYcBGTwZAAAyLgE/GQMIOgs7BTkLJxlJEzwZARMAADMuAT8ZAwg6CzsFOQsnGREBEgdAGHoZARMAADQ0AAMIOgs7BTkLSRMCGAAANTQAAwg6CzsFOQtJEwIXt0IXAAA2CwFVFwAANx0BMRNSAbhCC1UXWAtZBVcLAAA4CwExE1UXAAA5HQExExEBEgdYC1kFVwsBEwAAOjQAMRMCGAAAOwsBARMAADwuAQMIOgs7CzkLJxkgCwETAAA9LgEDCDoLOws5CycZEQESB0AYehkBEwAAPgsBEQESBwETAAA/LgEDCDoLOws5CycZhwEZEQESB0AYehkBEwAAQBgAAABBLgA/GTwZbggDCDoLOwsAAAABJAALCz4LAwgAAAINAAMIOiECOws5C0kTOAsAAAMFAAMIOiEBOws5C0kTAhe3QhcAAAQPAAshCEkTAAAFBQBJEwAABjQAAwg6IQE7CzkhFUkTAhgAAAdJAAIYfhgAAAgRASUIEwsDHxsfEQESBxAXAAAJJgBJEwAAChMBAwgLCzoLOws5CwETAAALFgADCDoLOws5C0kTAAAMFQEnGUkTARMAAA0uAT8ZAwg6CzsLOQsnGTwZARMAAA4uAT8ZAwg6CzsLOQsnGREBEgdAGHoZARMAAA9IAX0BggEZfxMAABAuAT8ZAwg6CzsLOQsnGREBEgdAGHoZAAARBQADCDoLOws5C0kTAhgAABJIAX0BAAAAAREBJQgTCwMfGx8QFwAAAjQAAwg6CzsLOQtJEz8ZAhgAAAMkAAsLPgsDCAAAAAENAAMIOiECOwU5C0kTOAsAAAIoAAMIHAsAAANJAAIYfhgAAAQkAAsLPgsDCAAABQ0AAwg6IQI7BTkLSROIASEQOAUAAAYNAAMIOiECOwU5C0kTiAEhEDgLAAAHFgADCDoLOws5C0kTAAAIFgADCDohAjsFOQtJEwAACSgAAwgcBQAACkgBfQF/EwETAAALDwALIQhJEwAADA0AAwg6IQI7BTkLSRM4BQAADSEASRMvCwAADgUASRMAAA8BAUkTiAEhEAETAAAQNAADCDohATsLOQtJEwIXt0IXAAARSAF9AQETAAASEwEDCAsLOiECOwU5IRQBEwAAEw0AAw46IQI7BTkLSRM4CwAAFBMBAwgLBYgBIRA6IQI7BTkLARMAABUWAAMIOiECOwU5C0kTiAEhEAAAFgEBSRMBEwAAFw0AAwg6IQI7BTkhF0kTiAEhEAAAGAQBAwg+IQcLIQRJEzoLOwU5CwETAAAZEQElCBMLAx8bHxEBEgcQFwAAGhUBJxkBEwAAGw8ACwsAABwNAEkTiAELOAUAAB0TAQMICwuIAQs6CzsFOQsBEwAAHhMBCwWIAQs6CzsFOQsBEwAAHxcBCwWIAQs6CzsFOQsBEwAAIA0ASROIAQsAACEVAScZSRMBEwAAIgQBAwg+CwsLSRM6CzsLOQsBEwAAIzQAAwg6CzsLOQtJEz8ZAhgAACQuAD8ZAwg6CzsLOQsnGTwZAAAlLgE/GQMIOgs7CzkLJxlJEzwZARMAACYuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAJwUAAwg6CzsLOQtJEwIXt0IXAAAoSAF9AYIBGQETAAApSAB9AX8TAAAAAQ0AAwg6IQU7BTkLSRM4CwAAAiQACws+CwMIAAADSQACGH4YAAAEFgADCDoLOws5C0kTAAAFBQBJEwAABkgAfQF/EwAABxYAAwg6IQU7BTkLSRMAAAgPAAshCEkTAAAJBQADCDohATsLOQtJEwIXt0IXAAAKNAADCDohATsLOQtJEwIXt0IXAAALKAADCBwLAAAMLgE/GQMIOiEHOws5IRonGTwZARMAAA1IAX0BfxMAAA5IAX0BfxMBEwAADxMBAwgLCzohBTsFOQsBEwAAEDQAAwg6IQE7CzkLSRMCGAAAEQ0AAwg6IQE7CzkLSRM4CwAAEi4BPxkDCDohATsLOSEBJxlJExEBEgdAGHoZARMAABM1AEkTAAAULgE/GQMIOgs7BTkLJxlJEzwZARMAABU0ADETAAAWNAADCDohATsLOQtJEwAAFzQAMRMCF7dCFwAAGBEBJQgTCwMfGx8RARIHEBcAABkPAAsLAAAaBAEDCD4LCwtJEzoLOwU5CwETAAAbFQEnGQETAAAcEwEDCAsLOgs7CzkLARMAAB0uAD8ZAwg6CzsLOQsnGUkTPBkAAB4uAD8ZAwg6CzsLOQsnGTwZAAAfLgE/GQMIOgs7BTkLJxk8GQETAAAgCwERARIHARMAACEdATETUgG4QgsRARIHWAtZC1cLARMAACIdATETUgG4QgtVF1gLWQtXCwETAAAjCwFVFwAAJC4BAwg6CzsLOQsnGSALARMAACULAQAAJi4BMRMRARIHQBh6GQAAJwsBMRMRARIHARMAAChIAX0BAAApSAF9AYIBGX8TAAAAAREBJQgTCwMfGx8QFwAAAjQAAwg6CzsLOQtJEz8ZAhgAAAMkAAsLPgsDCAAAAAE0AAMIOiEBOws5IQZJEz8ZAhgAAAIRASUIEwsDHxsfEBcAAAMkAAsLPgsDCAAAAAENAAMIOiEFOwU5C0kTOAsAAAI0ADETAAADNAAxEwIXt0IXAAAEBQAxEwAABSQACws+CwMIAAAGCwFVFwAABxYAAwg6IQU7BTkLSRMAAAg0AAMOOiEBOws5C0kTAAAJHQExE1IBuEILVRdYIQFZC1cLAAAKFgADCDoLOws5C0kTAAALNAADDjohATsLOQtJEwIXt0IXAAAMDwALIQhJEwAADS4BPxkDCDohATsLOSEBJxlJExEBEgdAGHoZARMAAA4TAQMICws6IQU7BTkhFAETAAAPDQADDjohBTsFOQtJEzgLAAAQBQAxEwIXt0IXAAARBQADCDohATsLOQtJEwIXt0IXAAASAQFJEwETAAATIQBJEy8LAAAUBQBJEwAAFTQAAwg6IQE7CzkLSRMCF7dCFwAAFh0BMRNSAbhCC1UXWCEBWQtXIQkBEwAAF0kAAhh+GAAAGA0AAwg6IQU7BTkhCEkTAAAZHQExE1IBuEILEQESB1ghAVkLVwsAABoXAQshBDohBTsFOQsBEwAAGy4BPxkDCDohBjsLOQsnGUkTPBkBEwAAHC4BPxkDCDohATsLOSEBJxlJEyAhAQETAAAdBQADDjohATsLOQtJEwAAHjQAAwg6IQE7CzkLSRMAAB8RASUIEwsDHxsfEQESBxAXAAAgJgBJEwAAIQ8ACwsAACITAQMICwU6CzsFOQsBEwAAIw0AAw46CzsFOQtJEwAAJA0ASRM4CwAAJTQAAwg6CzsLOQtJEz8ZPBkAACZIAX0BfxMBEwAAJ0gBfQF/EwAAKAUAAwg6CzsLOQtJEwAAKS4BMRMRARIHQBh6GQETAAAqLgExExEBEgdAGHoZAAArBQAxEwIYAAAAAREBJQgTCwMfGx8QFwAAAjQAAwg6CzsLOQtJEz8ZAhgAAAMkAAsLPgsDCAAAAAEkAAsLPgsDCAAAAg0AAwg6IQM7CzkLSRM4CwAAAwUASRMAAARJAAIYfhgAAAUWAAMIOgs7CzkLSRMAAAYPAAshCEkTAAAHBQADCDohATshMTkLSRMCF7dCFwAACC4BPxkDCDohAzsFOSEYJxk8GQETAAAJSAF9AX8TARMAAAoRASUIEwsDHxsfEQESBxAXAAALDwALCwMISRMAAAwmAEkTAAANEwEDCAsLOgs7CzkLARMAAA4uAT8ZAwg6CzsLOQsnGUkTPBkBEwAADw8ACwsAABAuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkAABE0AAMIOgs7CzkLSRMCF7dCFwAAEkgBfQF/EwAAAAFJAAIYfhgAAAIkAAsLPgsDCAAAAwUASRMAAAQWAAMIOgs7CzkLSRMAAAUFAAMIOiEBOyEgOQtJEwIXt0IXAAAGDwALIQhJEwAABxEBJQgTCwMfGx8RARIHEBcAAAgPAAsLAwhJEwAACSYASRMAAAouAT8ZAwg6CzsLOQsnGUkTPBkBEwAACw8ACwsAAAwuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkAAA00AAMIOgs7CzkLSRMCF7dCFwAADkgBfQF/EwETAAAPSAF9AX8TAAAAAUkAAhh+GAAAAkgBfQF/EwETAAADBQAxEwIXt0IXAAAEDQADCDoLOws5C0kTOAsAAAU0AAMIOgs7BTkLSRMAAAZIAX0BfxMAAAcoAAMIHAsAAAg0ADETAhe3QhcAAAkFAEkTAAAKBQADCDoLOwU5C0kTAAALHQExE1IBuEIFVRdYIQFZBVcLARMAAAwNAAMIOgs7CzkLSRMAAA0FAAMOOiEBOwU5C0kTAAAOBQADDjohATsFOQtJEwIXt0IXAAAPFgADCDoLOws5C0kTAAAQDQADCDoLOwU5C0kTOAsAABEFAAMIOiEBOwU5C0kTAhe3QhcAABI0AAMIOiEBOwU5C0kTAhe3QhcAABMkAAsLPgsDCAAAFA8ACyEISRMAABUFADETAAAWNAADCDohATsFOQtJEwIYAAAXSAB9AX8TAAAYNAADDjohATsFOQtJEwIYAAAZLgEDCDohATsFOSEGJxkRARIHQBh6GQETAAAaNAAxEwAAGy4BAwg6IQE7BTkhBicZICEBARMAABwBAUkTARMAAB0uAT8ZAwg6CzsLOQsnGUkTPBkBEwAAHgsBAAAfIQBJEy8LAAAgCwFVFwETAAAhNAADDjohATsFOQtJEwAAIjQAAw46IQE7BTkLSRMCF7dCFwAAIzcASRMAACQTAQMICws6CzsLOQsBEwAAJQQBPiEHCyEESRM6CzsLOQsBEwAAJg0AAwg6IQE7BTkhGkkTAAAnCwFVFwAAKB0BMRNSAbhCBREBEgdYIQFZBVcLARMAACkuAQMIOiEBOwU5CycZSRMgIQEBEwAAKi4BPxkDCDohAjsFOSEcJxlJEyAhAwETAAArLgExExEBEgdAGHoZARMAACwLATETVRcBEwAALRYAAwg6CzsFOQtJEwAALhYAAw46CzsLOQtJEwAALw0AAwg6IQI7CzkhC0kTDQtrCwAAMC4BPxkDCDoLOwU5CycZSRM8GQETAAAxJgBJEwAAMhMBCws6IQI7CzkhFAETAAAzFwEDDgsLOiECOws5IREBEwAANBMBCws6IQE7BTkLARMAADUuAD8ZAwg6CzsLOQsnGUkTPBkAADYLAREBEgcBEwAANx0BMRNSAbhCBVUXWCEBWQVXCwAAOAsBMRNVFwAAOUgBfQGCARl/EwETAAA6NAAxEwIYAAA7EQElCBMLAx8bHxEBEgcQFwAAPA8ACwsDCEkTAAA9EwEDDgsLOgs7BTkLARMAAD4WAAMOOgs7BTkLSRMAAD8TAQMOCws6CzsLOQsBEwAAQBcBAwgLCzoLOws5CwETAABBFwELCzoLOws5CwETAABCDwALCwAAQw0AAw46CzsFOQtJEzgLAABEFwELCzoLOwU5CwETAABFDQBJEwAARi4BPxkDCDoLOws5CycZPBkBEwAARy4BPxkDCDoLOwU5CycZSRMRARIHQBh6GQETAABICgADCDoLOwU5CwAASQsBMRMRARIHARMAAEoLAQETAABLSAF9AYIBGX8TAABMNABJEzQZAhe3QhcAAE0hAEkTLxMAAE4uAQMIOgs7BTkLJxlJExEBEgdAGHoZARMAAE8FAAMOOgs7BTkLSRMCGAAAUC4APxk8GW4IAwg6CzsLAAAAAUkAAhh+GAAAAkgBfQF/EwETAAADDQADCDoLOws5C0kTOAsAAAQFADETAhe3QhcAAAU0AAMIOgs7BTkLSRMAAAZIAX0BfxMAAAcFAEkTAAAIKAADCBwLAAAJNAAxEwIXt0IXAAAKBQADCDoLOwU5C0kTAAALHQExE1IBuEIFVRdYIQFZBVcLARMAAAwWAAMIOgs7CzkLSRMAAA0NAAMIOgs7CzkLSRMAAA40AAMIOiEBOwU5C0kTAhe3QhcAAA8FAAMOOiEBOwU5C0kTAAAQBQADDjohATsFOQtJEwIXt0IXAAARDQADCDoLOwU5C0kTOAsAABIFAAMIOiEBOwU5C0kTAhe3QhcAABMkAAsLPgsDCAAAFDQAAwg6IQE7BTkLSRMCGAAAFQ8ACyEISRMAABYFADETAAAXLgEDCDohATsFOSEGJxkRARIHQBh6GQETAAAYNAAxEwAAGUgAfQF/EwAAGi4BAwg6IQE7BTkhBicZICEBARMAABsuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAHDQAAw46IQE7BTkLSRMCGAAAHQsBAAAeAQFJEwETAAAfIQBJEy8LAAAgNAADDjohATsFOQtJEwAAITcASRMAACILAVUXARMAACMLAVUXAAAkEwEDCAsLOgs7CzkLARMAACUEAT4hBwshBEkTOgs7CzkLARMAACYNAAMIOiEBOwU5IRpJEwAAJx0BMRNSAbhCBREBEgdYIQFZBVcLARMAACg0AAMOOiEBOwU5C0kTAhe3QhcAACkuAQMIOiEBOwU5CycZSRMgIQEBEwAAKi4BPxkDCDohAjsFOSEcJxlJEyAhAwETAAArLgExExEBEgdAGHoZARMAACwLATETVRcBEwAALRYAAwg6CzsFOQtJEwAALhYAAw46CzsLOQtJEwAALw0AAwg6IQI7CzkhC0kTDQtrCwAAMC4BPxkDDjohATsFOSERJxlJEzwZARMAADEYAAAAMgsBEQESBwETAAAzJgBJEwAANBMBCws6IQI7CzkhFAETAAA1FwEDDgsLOiECOws5IREBEwAANhMBCws6IQE7BTkLARMAADcuAT8ZAwg6CzsFOSESJxlJEzwZARMAADguAD8ZAwg6CzsLOQsnGUkTPBkAADkLATETVRcAADpIAX0BggEZfxMBEwAAOzQAMRMCGAAAPBEBJQgTCwMfGx8RARIHEBcAAD0PAAsLAwhJEwAAPhMBAw4LCzoLOwU5CwETAAA/FgADDjoLOwU5C0kTAABAEwEDDgsLOgs7CzkLARMAAEEXAQMICws6CzsLOQsBEwAAQhcBCws6CzsLOQsBEwAAQw8ACwsAAEQNAAMOOgs7BTkLSRM4CwAARRcBCws6CzsFOQsBEwAARg0ASRMAAEcuAT8ZAwg6CzsLOQsnGTwZARMAAEguAT8ZAwg6CzsFOQsnGUkTEQESB0AYehkBEwAASQoAAwg6CzsFOQsAAEoLATETEQESBwETAABLCwEBEwAATEgBfQGCARl/EwAATUgAfQGCARl/EwAATi4BAwg6CzsFOQsnGUkTEQESB0AYehkBEwAATwUAAw46CzsFOQtJEwIYAABQLgA/GTwZbggDCDoLOwsAAAABNAADCDohATsLOQtJEwIXt0IXAAACJAALCz4LAwgAAANJAAIYfhgAAAQPAAshCEkTAAAFDQADCDohAjsFOQtJEzgLAAAGBQADCDohATsLOQtJEwIXt0IXAAAHNAAxEwIXt0IXAAAIBQBJEwAACUgBfQF/EwAACjQAAwg6IQE7ISg5C0kTAAALLgE/GQMIOiECOwU5CycZSRM8GQETAAAMLgE/GQMIOiEBOws5CycZSRMRARIHQBh6GQETAAANBQAxEwIXt0IXAAAOEQElCBMLAx8bHxEBEgcQFwAADxYAAwg6CzsLOQtJEwAAEBMBAw4LCzoLOwU5CwETAAARAQFJEwETAAASIQBJEy8LAAATFgADDjoLOwU5C0kTAAAULgE/GQMIOgs7BTkLJxk8GQETAAAVSAF9AX8TARMAABYuAT8ZAwg6CzsLOQsnGREBEgdAGHoZARMAABdIAX0BggEZfxMAABgdATETUgG4QgtVF1gLWQtXCwAAGQsBVRcAABouAT8ZAwg6CzsLOQsnGUkTIAsBEwAAGwUAAwg6CzsLOQtJEwAAHC4BMRMRARIHQBh6GQAAAAFJAAIYfhgAAAJIAX0BfxMBEwAAAzQAAwg6IQE7CzkLSRMCF7dCFwAABAUASRMAAAUoAAMIHAsAAAYuAT8ZAwg6IQI7BTkLJxlJEzwZARMAAAckAAsLPgsDCAAACAoAAwg6IQE7BTkhAhEBAAAJSAB9AX8TAAAKDwALIQhJEwAACw0AAwg6IQQ7CzkhBkkTOAsAAAwNAAMIOiECOwU5C0kTOAsAAA0FAAMIOiEBOyHqADkLSRMCF7dCFwAADjQAMRMCF7dCFwAADzQAAwg6IQE7CzkLSRMAABAFADETAhe3QhcAABEWAAMIOgs7CzkLSRMAABIBAUkTARMAABMFAAMIOiEBOyEiOQtJEwAAFCYASRMAABUNAAMIOiECOyGZAjkLSRMAABYhAEkTLwsAABc0AAMIOiECOyGoBDkLSRM/GTwZAAAYLgE/GQMIOiECOwU5IQ0nGTwZARMAABkFAAMIOiEBOws5C0kTAhgAABodATETUgG4QgVVF1ghAVkLVwsBEwAAGxEBJQgTCwMfGx8RARIHEBcAABwEAT4LCwtJEzoLOws5CwETAAAdEwEDCAsLOgs7CzkLARMAAB4XAQMICws6CzsFOQsBEwAAHxMBAw4LCzoLOwU5CwETAAAgFgADDjoLOwU5C0kTAAAhIQAAACIuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAIw8ACwsAACQmAAAAJS4BPxkDCDoLOws5CycZSRMRARIHQBh6GQETAAAmNAADCDoLOws5C0kTAhgAACcKAAMIOgs7CzkLEQEAACgLAVUXAAApCgAxExEBAAAqBQAxEwAAKx0BMRNSAbhCBVUXWAtZBVcLARMAACxIAH0BggEZfxMAAC1IAX0BfxMAAC4uAQMIOgs7CzkLJxlJEyALARMAAC8KAAMIOgs7CzkLAAAwLgEDCDoLOwU5CycZSRMgCwETAAAxBQADCDoLOwU5C0kTAAAyLgA/GTwZbggDCDoLOwsAAAABJAALCz4LAwgAAAI0AAMIOiEBOws5C0kTAhe3QhcAAAMNAAMIOiECOwU5C0kTOAsAAAQPAAshCEkTAAAFBQADCDohATsLOQtJEwIXt0IXAAAGEQElCBMLAx8bHxEBEgcQFwAABxYAAwg6CzsLOQtJEwAACBMBAw4LCzoLOwU5CwETAAAJAQFJEwETAAAKIQBJEy8LAAALFgADDjoLOwU5C0kTAAAMLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZARMAAA0dATETUgG4QgsRARIHWAtZC1cLAAAOBQAxEwIXt0IXAAAPNAAxEwIXt0IXAAAQLgE/GQMIOgs7CzkLJxkRARIHQBh6GQETAAARLgEDCDoLOwU5CycZSRMgCwAAEgUAAwg6CzsFOQtJEwAAEzQAAwg6CzsFOQtJEwAAAAE0AAMIOiEBOwU5C0kTAhe3QhcAAAJJAAIYfhgAAAM0ADETAhe3QhcAAAQNAAMIOgs7BTkLSRM4CwAABQUAMRMCF7dCFwAABiQACws+CwMIAAAHBQADCDohATsFOQtJEwIXt0IXAAAISAF9AX8TAAAJDwALIQhJEwAACkgBfQF/EwETAAALBQBJEwAADDQAAwg6CzsFOQtJEwAADQEBSRMBEwAADhYAAwg6CzsLOQtJEwAADyEASRMvCwAAEC4BPxkDCDohATsFOQsnGUkTEQESB0AYehkBEwAAEQUAAwg6CzsFOQtJEwAAEjQAAwg6IQE7CzkLSRMCF7dCFwAAExYAAwg6IQc7BTkLSRMAABRIAH0BfxMAABUmAEkTAAAWNAADCDohATsLOQtJEwIYAAAXLgE/GQMIOiELOws5IRonGTwZARMAABgLAVUXAAAZLgExExEBEgdAGHoZARMAABooAAMIHAsAABsdATETUgG4QgtVF1ghAVkFVwsBEwAAHAUAAwg6IQE7CzkLSRMCF7dCFwAAHTQAAwg6IQE7CzkLSRMAAB4dATETUgG4QgtVF1ghAVkLVwsBEwAAHxMBAwgLCzohBzsFOQsBEwAAIDQAAwg6IQM7IagEOQtJEz8ZPBkAACE0AEcTOiEBOwU5C0kTAhgAACIdATETUgG4QgsRARIHWCEBWQVXCwETAAAjLgE/GQMIOgs7BTkLJxlJEyALARMAACQFAAMIOiEBOws5C0kTAAAlDQADCDohAzshmQI5C0kTAAAmNAADCDohATsFOQtJEwIYAAAnLgE/GQMIOiEKOwU5CycZSRM8GQETAAAoBQAxEwAAKR0BMRNSAbhCC1UXWCEBWQVXIQYAACouAQMIOiEDOwU5IQEnGUkTICEDARMAACsuAQMIOiEBOws5IQ0nGSAhAQETAAAsSAF9AYIBGX8TAAAtLgA/GTwZbggDCDohDTshAAAALhEBJQgTCwMfGx8RARIHEBcAAC81AEkTAAAwDwALCwAAMSYAAAAyFQAnGQAAMwQBAwg+CwsLSRM6CzsFOQsBEwAANBcBAwgLCzoLOwU5CwETAAA1EwEDDgsLOgs7BTkLARMAADYWAAMOOgs7BTkLSRMAADchAAAAOCEASRMvBQAAOS4BPxkDCDoLOws5CycZSRM8GQETAAA6LgE/GQMIOgs7BTkLJxk8GQETAAA7CgADCDoLOwU5CxEBAAA8LgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZARMAAD0uAT8ZAwg6CzsLOQsnGSALARMAAD4uAT8ZAwg6CzsLOQsnGUkTIAsBEwAAPy4BAwg6CzsLOQsnGREBEgdAGHoZARMAAEALAVUXARMAAEE0AAMOOgs7CzkLSRMCF7dCFwAAQgsBEQESBwETAABDHQExE1IBuEILEQESB1gLWQtXCwAAREgAfQGCARl/EwAARTQAAw46CzsLOQtJEwAARgsBAABHHQExE1IBuEILEQESB1gLWQtXCwETAABIHQExE1IBuEILVRdYC1kLVwsAAEk0ADETAABKCwExE1UXAABLHQExE1UXWAtZC1cLAABMSAF9AYIBGX8TARMAAAABJAALCz4LAwgAAAIFAAMIOiEBOyEEOQtJEwIYAAADEQElCBMLAx8bHxEBEgcQFwAABCYASRMAAAUWAAMIOgs7CzkLSRMAAAYuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkBEwAABzQAAwg6CzsLOQtJEwIXt0IXAAAIDwALC0kTAAAAASQACws+CwMIAAACFgADCDohAjsLOQtJEwAAAwUAAwg6IQE7IQU5C0kTAhe3QhcAAAQRASUIEwsDHxsfEQESBxAXAAAFJgBJEwAABi4BPxkDCDoLOws5CycZSRMRARIHQBh6GQETAAAHNAADCDoLOws5C0kTAhe3QhcAAAgPAAsLSRMAAAABJAALCz4LAwgAAAIPAAshCEkTAAADEQElCBMLAx8bHxEBEgcQFwAABDQAAwg6CzsLOQtJEz8ZPBkAAAUVACcZSRMAAAY0AAMIOgs7CzkLSRM/GQIYAAAHLgA/GQMIOgs7CzkLJxlJExEBEgdAGHoZAAAAASQACws+CwMIAAACDwALIQhJEwAAAxEBJQgTCwMfGx8RARIHEBcAAAQ0AAMIOgs7CzkLSRM/GTwZAAAFFQAnGUkTAAAGNAADCDoLOws5C0kTPxkCGAAABy4APxkDCDoLOws5CycZSRMRARIHQBh6GQAAAAEoAAMIHAsAAAINAAMIOiEFOwU5C0kTOAsAAAMkAAsLPgsDCAAABA0AAwg6CzsLOQtJEzgLAAAFKAADCBwFAAAGSQACGH4YAAAHFgADCDoLOws5C0kTAAAIFgADCDohBTsFOQtJEwAACUgBfQF/EwETAAAKDwALIQhJEwAACwUASRMAAAwuAT8ZAwg6CzsLOQsnGTwZARMAAA0FADETAhe3QhcAAA4TAQMICws6IQU7BTkLARMAAA8EAQMIPiEHCyEESRM6CzsFOQsBEwAAEDQAAwg6IQE7CzkhB0kTPxkCGAAAES4BPxkDCDohATsLOSEOJxkgIQEBEwAAEgUAAwg6IQE7CzkLSRMAABNIAX0BggEZfxMAABQRASUIEwsDHxsfEQESBxAXAAAVEwEDCAsLOgs7CzkLARMAABYPAAsLAAAXBAEDCD4LCwtJEzoLOws5CwETAAAYEwELCzoLOws5CwETAAAZLgE/GQMIOgs7CzkLJxlJEzwZARMAABouATETEQESB0AYehkBEwAAGx0BMRNSAbhCCxEBEgdYC1kLVwsBEwAAHEgAfQF/EwAAHS4BMRMRARIHQBh6GQAAHh0BMRNSAbhCC1UXWAtZC1cLARMAAB9IAH0BggEZfxMAAAABKAADCBwLAAACJAALCz4LAwgAAAMoAAMIHAUAAAQFAEkTAAAFDwALIQhJEwAABhYAAwg6CzsLOQtJEwAABwQBAwg+IQcLIQRJEzoLOwU5CwETAAAINAADCDohATsLOSEmSRM/GQIYAAAJBQAxEwIXt0IXAAAKBQADCDohAjsh0w05C0kTAAALEQElCBMLAx8bHxEBEgcQFwAADCYASRMAAA0PAAsLAAAONQBJEwAADxUBJxkBEwAAEAQBAwg+CwsLSRM6CzsLOQsBEwAAETQAAwg6CzsLOQtJEwIYAAASFQEnGUkTARMAABMVACcZSRMAABQuAAMIOgs7CzkLJxlJExEBEgdAGHoZAAAVLgEDCDoLOws5CycZSRMRARIHQBh6GQETAAAWBQADCDoLOws5C0kTAhgAABcdATETUgG4QgsRARIHWAtZC1cLAAAYLgE/GQMIOgs7BTkLJxlJEyALARMAAAABJAALCz4LAwgAAAINAAMIOiECOws5C0kTOAsAAAMPAAshCEkTAAAEFgADCDoLOws5IRlJEwAABREBJQgTCwMfGx8RARIHEBcAAAYTAQMICws6CzsLOQsBEwAABxUBJxlJEwETAAAIBQBJEwAACTQAAwg6CzsLOQtJEz8ZAhgAAAouAD8ZAwg6CzsLOQsnGUkTPBkAAAsuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkAAAwFAAMIOgs7CzkLSRMCF7dCFwAADUgAfQF/EwAAAAEkAAsLPgsDCAAAAkkAAhh+GAAAAwUAAwg6IQE7CzkLSRMCF7dCFwAABA8ACyEISRMAAAUFAEkTAAAGNAADCDohATsLOQtJEwIXt0IXAAAHFgADCDoLOws5C0kTAAAIFgADCDoLOwU5C0kTAAAJSAB9AX8TAAAKJgBJEwAACy4APxkDCDoLOws5CycZSRM8GQAADEgBfQF/EwAADS4BPxkDCDohATsLOQsnGUkTEQESB0AYehkBEwAADjQAAw46IQE7CzkLSRMCGAAADxEBJQgTCwMfGx8RARIHEBcAABAuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAEQsBVRcBEwAAEgEBSRMBEwAAEyEASRMvCwAAFC4BAwg6CzsLOQsnGUkTEQESB0AYehkAABULAREBEgcAABY0AAMIOgs7CzkLSRMCGAAAF0gBfQF/EwETAAAAAUkAAhh+GAAAAgUAAwg6IQE7CzkLSRMCF7dCFwAAAyQACws+CwMIAAAEBQBJEwAABQ8ACyEISRMAAAZIAH0BfxMAAAcWAAMIOgs7CzkLSRMAAAg0AAMIOiEBOws5C0kTAhe3QhcAAAkWAAMIOgs7BTkLSRMAAAo0AAMOOiEBOws5C0kTAhgAAAs3AEkTAAAMSAF9AX8TAAANJgBJEwAADi4APxkDCDoLOws5CycZSRM8GQAADy4BPxkDCDohATsLOSEBJxlJExEBEgdAGHoZARMAABBIAX0BfxMBEwAAETQAAwg6IQE7CzkLSRMCGAAAEg0AAwg6IQE7CzkLSRMAABMRASUIEwsDHxsfEQESBxAXAAAULgE/GQMIOgs7BTkLJxlJEzwZARMAABUuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAFgsBVRcBEwAAFy4BAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAGBcBCws6CzsLOQsBEwAAGQEBSRMAABohAEkTLwsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABGBAAABQAIAJkAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8FRQAAAEwAAACAAAAAoAAAAMkAAAACAR8CDxUBAQAAAQsBAAABFAEAAAIcAQAAAyoBAAACNAEAAAJAAQAAAkoBAAACUwEAAAJkAQAAAnEBAAACegEAAAKCAQAABI0BAAACnwEAAAKmAQAAAq4BAAACtgEAAAK/AQAAAskBAAAC1AEAAAAFAQAJAgAQAEABAAAAA+YAAQYBBhf2BQODBQEDrgEBBQMUExMTFQUcBgEFDHoFHAN6LgUDBmcFGwYBBQMGyQUbBgEFAwbKEwURBgEFBnQFAwZ3BUIGAQUNSgUDBj0FBgYBggUHA8J+AQUOAAIEAXMFAwZnBQYGAQUFBmcFA6IFBQYBBRIAAgQBWAUDBq0FBQYBBRQAAgQBWAUDBq9cBSQGAQUGdAUDBl0FBRQFAxMFAQYTBQUGA226BQMDvgHyEwUWBgEFA0oFBwbdEwUKBgEFBwbKBQ4GAQiCBQcGA8N+AQUDvQUFFAUDEwUBBhMFBwYDrwG6BQoGAQUHBqAFDgYBBQEGA9N+CMgFA4MFFQYBBQx3BRUIRwUDBoUFDAYBBQEIsAYDxgCCBQUIExMEAgUeA8HMAAEFMwEEAwUBA6m4fwEBAQQBBQIGA6B7dAQDBQwD4wt0BQED/XguBpAGAQQBBQsAAgQBA5Z7AQUFBksTBQoGAQUCBjEFBQYBBQIGlQUXA3mCBAMFBwPpCwEFBRMFDAYBggQBBRcDlnQBBSADCVgFCQN1dAUFBgMLLgUgBgEFCC4FCgaUBSUGAQUNLgUHBogFEQYBBQUGoAUgBgEFCC4FBQaVEwUIBgEFBQaFBSEGAQUIngUHBlkFBbxZBSAGAQUeAAIEAcgFBXgFHgACBAFwBQUGQFpaBQ0DOmYFAhQTEwU7BgEFG3QFBbwFG3IFAgY+EwUOAAIEAQEFAwg+BSEGAQUKAAIEAZAFAwZZBRUGAQUDgwUIAAIEATsFAwZLBRUGSQUOAAIEATkFA04FFQACBAMGVAUOAAIEAQEFAwZeBQIGPAUHBgEFAgZ1BQYGAXQFBQYDuX8BWgUQBgEFD9oFEGIFBQZqBQ8GAQUIuwUNAAIEAWUFBQZnBQgGAQUFBoUFCAYBBQGiBSADUAg8BQ1vBQUGXQUgBgEFCC4FAgaSBQUDCp4FIAYBBQguBQIGkggvBRkGAQUFBmgTBQgGAQUHBoMEAwPYCwEFBRMFDAYBWGYEAQUHBgPBdAEFCgZaBQMGZgUBBhMFAgYDVghKBhMFGdUFAgZnBQ4AAgQBBgPbALoAAgQBPAACBAFYBQcGA0gBBQEDin+CBQODFBQFFAYBBQMGyQUJBgEFAwZaAwwuBQEGEwYDCgg8BQODFBQFFAYBBQMGyQUJBgEFAwZaAwwuBQEGEwYDhQEIPAYBBQUGgwUMBgEFKQACBAFYBQFnAgYAAQEkAQAABQAIAEsAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DJAIAACsCAABfAgAAAgEfAg8HfwIAAAGJAgAAAZMCAAACmwIAAAKoAgAAArECAAACuwIAAAIFAQAJAtAZAEABAAAAAxQBBQODFAUKAQUHCHYFCAYBBQcGLwUIBgEFCqkFCE0FCgZxBQEGXQYIMgUDuwVCBgEFEXQFAwZZFAUGBgEFFQACBAEGXQACBAEGSgACBAFYAAIEAXQFBwauBRwAAgQDLAUVAAIEAQEFA5UFAQZ1BQNzBRIDeOQFMAACBAEGggUrAAIEAQYBBTAAAgQBZgUrAAIEAVgFMAACBAE8BQEGAw+eBQMTBQYGAQUBowUHBmMFEwYBBQcGnwUBBhQFBxACBQABAVIAAAAFAAgASgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwQKAwAAEQMAAEUDAABlAwAAAgEfAg8GnQMAAAGoAwAAArADAAACvQMAAALGAwAAA9EDAAABNgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAiIEAAApBAAAAgEfAg8CXQQAAAFoBAAAATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwK5BAAAwAQAAAIBHwIPAvQEAAAB/wQAAAEQAQAABQAIAEsAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DTgUAAFUFAACJBQAAAgEfAg8HqQUAAAGyBQAAAbsFAAACxQUAAALRBQAAAtsFAAAC4wUAAAIFAQAJAsAaAEABAAAAA4gBAQYBBQMGiAUGBgEFAQMZkAUDBuJZBQEGEwYDpX+sBgEFAwa7ExUFDwYBBQZ0BQQGWQUMBgEFAwZoBQYGAQUHBloFCgYBBQEDDlgGA2fyBQMDEAETBQYGAQUDBnUFDgACBAEBBQcIFBMFCwYBBQo8BQIGWQUDBgEFKQYqBQ4AAgQBSgACBAEGWAUBGQUJBgNzyAUBBgMNWAYDCQieBgEFAwYTBQEGAxYBAgMAAQE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8COwYAAEIGAAACAR8CDwJ2BgAAAYEGAAABNgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAtIGAADZBgAAAgEfAg8CDQcAAAEYBwAAAboAAAAFAAgAPAAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwNlBwAAbAcAAKAHAAACAR8CDwTABwAAAccHAAABzgcAAALVBwAAAgUBAAkCkBsAQAEAAAADCwEGAQUDBgiDFAMfAiYBBgiCAAIEAVgIZgACBAE8BuYFAQYTCDwFBwNhZgUCBgMM8hMFBwYRBQJ1BosTBQcGEQUCdQYDC5ATBQcGEQUCdQaLEwUHBhEFAnUGXxMFBwYRBQJ1AgUAAQFSAAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CIwgAACoIAAACAR8CDwJeCAAAAWkIAAABBQEACQKQHABAAQAAAAMSAQUDEwUBBhMCAwABAVQAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwK5CAAAwAgAAAIBHwIPAvQIAAAB/wgAAAEFAQAJAqAcAEABAAAAAwkBBQMDCQEFAQYzAgEAAQE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CVQkAAFwJAAACAR8CDwKQCQAAAaAJAAABfAUAAAUACABzAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA/oJAAABCgAANQoAAAIBHwIPD1UKAAABZAoAAAFzCgAAAnwKAAAChgoAAAKSCgAAApwKAAACpAoAAAKxCgAAAroKAAACwgoAAALOCgAAAt8KAAAC6AoAAALxCgAAAAUBAAkCsBwAQAEAAAAD1AABBgEFAwYDProTBQEGA0EBBQMDPzxMBQEDv39YBQMDP7oGTAACBAEGWAggAAIEATwGWQACBAEG1jwAAgQBPAaHEwUBAxvIBgEFAwbJExMUBREAAgQBAQUBBm8FEQACBAFBBQrkBQcGoAUWBgEFCjwFT1kFN3QFCzwFIQACBAIGjQURAAIEAUoFA5YFBwYBPAUDBoMFBgYBBQMGlQULBgF0SgUUdAUDBksFGwYBBQMGZwUbBgEFMQACBAFYBQg+BS4AAgQBZAUZAAIEAUoFCHYFGQACBAFIBQMGWgUIBgEFBgACBAFmBQMGlwUIBgEFKzwFLgACBAE9BStXBS4AAgQBPQUDBgMPWHUFAQYTBQcGA3HIEwUVBhMFIz8FIksFFUYFBwbnBQ8GAQUgdAUHBksFDwYRBR89BQcGSwUMBgEFCgACBAFmBQIGTQUKBhMFAmUFCnUFAi2sBQoDXAEFBwYDEnQDdwieBvIFAQYACQKQHgBAAQAAAAOgAgEFAwhLFBUFBwYBBQZ0BQEDFFgFAwYDbghmoAULBgEFAwZZBRsGAS5KBQ0Dx34IEgUPA7oB1gUbnQUMAAIEAYIFAwZ1FQUBA8B+AQUDFBMFDQYBBQMGZxMTGAUGBgEFAwYDFmYFEAYTBQYtBQMGAw+eBQYGAQUkAAIEAZ4FGwACBAE8BQMGAxWCBQ0GAQUGPAUDBgMMkAUFBgEFAwZMBQwAAgQBAQUWBpMFFwM8dNYFBwNSAQUGBggoBR0GAQUGBj0FCQZmBQgGkQUGAxIBBQcWEwUQBgNpAQUPAxZ0PQUHBj4TBQoGAQULBlITEwUOBgGQkAUMBgMNAQUBA7J+AQUDFAUBEAUDGgMXggY8BQUGA7ABAQU1A7N/AQUMAAIEAUoFB5MFJgYXBREDCS4FKgNyPAUQQQUZAwk8BRADeDwFFAN6PAUHBkETGgaQBQYGAxWsExgFBxYTBQ8GEQUKQAUPKj0FBwY+EwUKBgEFCwbCExMFDgYBBQYGWQYIugUHA49/AQUnAAIEAYIFBz0FDQMKrEoFBgYDOmYFHQYBBQYGPQUJBmYFCAaRBQYDFwEFBxYTBRAGA2QBBQ8DG3Q9BQcGPhMFCgYBBQsGUhMTBQ4GAZBmBQwGAwoBBQEDtX4BBQMUBQEQBQMaBTUGA/oAPAUDA4Z/SgYDF1gGPAUFBgOtAQEFNQO2fwEFDAACBAEBAAIEAQbkBREAAgQBBgPlfgEFBwbaBREAAgQBcAUHMgaOBRMGAQUWngUKPAUHBloFIQACBALEBREAAgQBSgACBAEGCEoFBgYDuQEBBR0GAQUGBjAFCQZmBQgGSwUGAwwBBQcWEwUQBgNvAQUPAxDIPQUHBj4TBQoGAQULBlITEwUOBgGQCC4FDAYDEAEFAQOvfgEFAxQFARAFAxoDF4IGLgUFBgOzAQEFDOcFAQOrfgEFAxQFARAFAxoDF4IGPAUFBgO3AQEFBgNZWAUHFhMFDwYRPQUHBj4TBQoGAQUGBgN4CCAFBxYTBQ8GET0FBwY+EwUKBgEFBgYDeJ4FBxYTBQ8GET0FBwY+EwUKBgEFBwYDr38IIAUWBgMfkAUEBgNkdBMTBScGEQUoPQUNKgURTQUoPQUEBi8FAQOUfwEFAxQFARAFAxoDF4IGLgUNBgPIAAEFBxEGngUGBgPGAAETBQcDSdYCDQABAaoAAAAFAAgANwAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwNFCwAATAsAAIALAAACAR8CDwOgCwAAAa4LAAABvAsAAAIFAQAJAvAhAEABAAAAAw0BBgEFB4QFAwarEwUGBgEFAwZaBQ0GFgULVAUDBj0FBAYWBQtGBQMGSxMFCwYRBQMGTAUNBgEFAwZZBQQGAQUBPQa/BgEFAwYTBREGAQUDBnUFAQYTBQMRWAABATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwIJDAAAEAwAAAIBHwIPAkQMAAABTwwAAAGKAQAABQAIAFUAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DowwAAKoMAADeDAAAAgEfAg8J/gwAAAEMDQAAARoNAAACIg0AAAIuDQAAAjgNAAACSQ0AAAJWDQAAAl8NAAACBQEACQJAIgBAAQAAAAO4AQEGAQUDBq0TExUFFgYBBSc8BQEDei4FN0IuBQZmBQMGwQUHAy0CMQEXBRUGAQUHBrsFCgYBBQwGpQUPBgEFKwACBAEDFZAFBQa7BQ8GAQUBPlgFDx4FAwOwf0oFBwYDFwieBRUGAQUHBrsFCgYBBQwGpQUPBgEFBAZbBQUGAQUEBnUFAwMsAQUBBgOkfzwFBwb6BQoGAfIFAQPXAC5YBQMDrn+QBQcGAzLyBRUGAQUHBrsFCgYBBQQGoOUFBwNOrAUVBgEFBwa7BQoGAQUMBm0FDwYBBQQGkwUFBgEFBAZ1BQMDPwEFBANu1gUFBgEFBAZ1BQMDEQEFBAO6f1jlBQMDxQABBQQDTVjlBQMDMgEFBANmWOUFBhMCCgABAXQCAAAFAAgAXwAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwOtDQAAtA0AAOgNAAACAR8CDwsIDgAAARIOAAABHA4AAAImDgAAAjIOAAACPA4AAAJEDgAAAlEOAAACXA4AAAJlDgAAAnkOAAACBQEACQIAJABAAQAAAAPiAAEFAwgY9AUNBgEFHgACBAEGdAUHCHYFJwYBBRYuBQcGZwULBgEGMAUOBgFYBQ0GSwUTBgEFDkoFBwZaBQwGAUoFHgACBAEGA3gBBQMDC1gFAQY9WAUDcwUBBgO1f7oGAQUDBskUBRoGAQUBYwUGWwUMSwUBAw8udAUDBgNyrAUiBgFYWAUDBoMFBgYBBQMGWwURBhMFA0wFEHEFAwYvFJIFEQYBBQN3BRE6cwUDBksUZwUKBgEFDAN1LjwFAQYDEDwGAQUDBrsTFAUaBgEFAWIFBjIFAQMaSgUDBgNp8gaeBmgTBQsGAQUDBnYFEgEFDAZVBQcGAw+6EwUSA3MBBoIFBwY+BRMGAQUKLgUkMQUKRwULBjAFDgYBBQ0GWwUcBgEFCwZMWQUDGJEFAQYTdAUNBgNzyAUbBgEFAQYDKvIGAQUDBq0FB+cFHgYBBQpmBQcGhAUaBgEFBwafBQMDGAEFAQYTBQMDYdYFBwYDG1gFAQNKAQUDFBQFGgYBBQZmkLoFBwYDHwEFAQNdAQUDFBQFGgYBBQZmSgUHBgMgAQUeBgEFCmYFCwZaEwUVBgEFJgACBAEGdAUNvAUPBjwFDQZLWQUmAAIEAQ4FC14GFAUZcgULBq0FHgYBBQsGnwasBQcGFlkFAxcFAQYTCC5YPAUJBgNlAQZ0ZgIFAAEBNgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAs8OAADWDgAAAgEfAg8CCg8AAAEUDwAAATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwJtDwAAdA8AAAIBHwIPAqgPAAABvA8AAAFTBQAABQAIAEsAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DFBAAABsQAABPEAAAAgEfAg8HbxAAAAF4EAAAAYEQAAACixAAAAKXEAAAAqEQAAACqRAAAAIFAQAJAqAmAEABAAAAAxgBBgEFAwYTExMUEwUMBhMFBi0FAQYDeXQFAwMJAQVDBgEFDUoFAwY9BQYGAYIFARgFAwZ+EwUGBgEFAa8GXgYBBQMGExMTFAVRBgEFDUoFAwY+BSEGAQUlSwUfVwUOBlkGngUHBggVBRoGAQUKdAUmWQUEPAUPBlUFEAYBBQ4GSQUKBl8FAS8GJgYBBQMGyRMTExUFAQYDeQEFB0MFBgACBAFYBQMGaRMFAQNJAQUDFBMTFBMFEQYBBQwDLXQFBgNTLgUBBgN5dAUDAwkBBUMGAQUNSgUDBj0FBgYBBQMGhBMFBgYBggUDBgMtARQFIQYBBR9KBQ4GWQUlBgEFDkqCBQ8GCBMFEAYBBQ4GSQUHWwUMBgEFCgACBAEIEgUBTpAFDANwkAUBAxAukAbPBgEFAwYTExQTBQEDsH8BBQMUExMUEwURBgEFDAPKAHQFBgO2fy4FAQYDeXQFAwMJAQVDBgEFDUoFAwY9BQYGAZAFAQPLAAEFAwYDt3+CEwUGBgGQBQMGA8YAAQUhBgNKAQUiAzZYBQMGPQUBA0EBBQMUExMUFAUfBgEFDgZZBSUGAQUOWJ4FBwYIMQUaBgEFCnQFJlkFBDwFDwZVBRAGAQUOBkkGWAUMAzMBBQEyBiQFAxMTFBMFAQOifwEFAxQTExQTBREGAQUMA9gAdAUGA6h/LgUBBgN5dAUDAwkBBUMGAQUNSgUDBj0FBgYBggUBA9oAAQUDBgOof5ATBQYGAYIFAwYD1AABFAUKBgEFAUsuBqUGAQUDBhMTExMUEwUBA45/AQUDFBMTFBMFEQYBBQwD7AB0BQYDlH8uBQEGA3mCBQMDCQEFQwYBBQ1KBQMGPQUGBgGCBQED+QABBQMGA4l/ghMFBgYBggUDBgPoAAEUBSEGAQUlSwUfVwUOBlkGngUHBvUFCgYBBQIGaAUFBgEFAgZaBQ8DekoFEAYBBQ4GSQUMBlMFAQMQLgbcBQMTExMFAQP0fgEFAxQTExQTBREGAQUMA4YBdAUGA/p+LgUBBgN5dAUDAwkBBUMGAQUNSgUDBj0FBgYBggUBA4UBAQUDBgP9fpATBQoGA4EBAQUBnwbcBgEFAwYTExMUEwUBA+V+AQUDFBMTFBMFEQYBBQwDlQF0BQYD634uBQEGA3l0BQMDCQEFQwYBBQ1KBQMGPQUGBgGQBQEDmAEBBQMGA+p+ghMFBgYBkAUDBgOQAQEFFwYBBQMGPQUBA/d+AQUDFBMTFBQFJQYTBSFXBR9YBQ4GWQUHCL0FGgYBBQp0BSZZBQQ8BQ8GVQUQBgEFDgZJBQwGA/4AWAUBNAUDBh0UBTwGAQUBgwaJBgEFAwYTExMTExQTBQEDz34BBQMUExMUEwURBgEFDAOrAXQFBgPVfjwFAQOiAWYFBgPefjwFAQYDeS4FAwMJAQVDBgEFDUoFAwY9BQYGAYIFAQPEAQEFAwYDvn66EwUGBgGCBQMGA6cBARQFEwYBBQMGZwUGBgEFAwZNBQED234BBQMUExMUFAUhBgEFJUsFH1cFDgZZBp4FBwbZBRoGAQUKdAUmWQUEPAUPBlUFEAYBBQ4GSQZYBQwDlAEBBQEDHDwFAwYDbYIVBQ4GAQUDBj0FBwMKWEsFEQYBBQMGA3hKAQUHFAUKBgEFKgACBAF0BQcGdwUKBgEFCAZZBTAGAQUPSgUBQjwCAQABATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwL+EAAABREAAAIBHwIPAjoRAAABShEAAAGFAAAABQAIAEEAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DqBEAAK8RAADlEQAAAgEfAg8FBRIAAAEWEgAAAScSAAACMBIAAAI4EgAAAQUBAAkC4CoAQAEAAAADMQEGAQUDBskUBQEGDwUDkwZZBQwGAQUDCHUFDDsFAwYvWgUBBhN0ICACAgABAcgAAAAFAAgAQQAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwOYEgAAnxIAANUSAAACAR8CDwX1EgAAAQgTAAABGhMAAAIjEwAAAi0TAAABBQEACQIwKwBAAQAAAAMgAQYBBQMGuxQFAQYPBQU/BQMGAwtYBQwGAQUKWAUMSjxmLgUDBlkFBgYBBSYAAgQCSgUGAAIEAjwFNQACBAQ8BQMGaAUBBhNYIAUmAAIEAVUFBgACBAE8BQUGA3lYBQwGAYI8LjwFAQMKWGYCAgABAQElAAAFAAgAbQAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwSKEwAAkRMAAMcTAADnEwAAAgEfAg8NJhQAAAE2FAAAAUYUAAACTRQAAAJWFAAAAmAUAAACaRQAAAJxFAAAAnoUAAACghQAAAOKFAAAApMUAAACnBQAAAAFAQAJAqArAEABAAAAA8MIAQYBIAUDBnkFCgEFHgEFAxMTBQEGA3kBBRoGA1dmBQMUExQDHwEEAgUIBgPeegEEAQUBA6cFPAUKN3Q8BQMGAw4BBAIFHAPKegEFBRQTExMTBQgGAQUJBoQGPAZLBQwGAS4FDgZoBREGAYIEAQUHBgPEBQETBQoGAxABBQcAAgQEA17kBSEAAgQBAx48BQkAAgQEZgUDBmoFCgYBCDyQBQHlBAIFCgYDrXqQBQ0GAQUHBoMFHQYBPAUbn0oEAQUHAAIEBAOuBQEFAwYDHnQFBwACBAQGA2IBBSEAAgQCAx4uAAIEAi4AAgQCugACBAJKAAIEAroAAgQCngUDBgEGZlgFAQYDknqsBgEFAwawBQEGDgUOQAUFPAVDAAIEAVgFKQACBAE8BQUGXQUHBhY4BgMJWAUpBgEFMkoFCz4FAwY8BQEGZ1gFBwYDeFgFCwaJBQMGPAUBBmdYBgOZAZ4GAQUDBgMJCEoTEwUNBgEFAQN1ggUNAwtYBQEDdS4FDQMLPDw8BQMGkgUOBgEFIAACBAE8BQ0DCZAFIAACBAEDdzwFAwYDCTwFBQYBBQMGAwzkBRgDDAEFEAYBBRhKBQuEyAUjAAIEARAFGAACBAEIEgUSBoUGAQULOwUHBgO0fgg8BSkGAQUySgULPgUDBjwGZgUSBgPLAQEGAQUHBlkFDgYDpH4BBRkD3AE8BQYGA59+SgUDFwUFBgEFQwACBAFYBSkAAgQBPAACBAFYBRcD3AEBBQUGA6l+WAUHBhY4BlwFCwaJBQMGPAZmBRIGA8sBAQYBWAUYBg8GAUoFGgYDC8gFEAYBBRc8BRpmBQUGnwUaxwUQBgEFFzwFGmYFAQMySlgFBQYDsH+6BRMGAQUDBl8FGwACBAEGAQUMBmwFGQYBBQcGnwUMxwUSBgEFGTwFDGYFGAZQBRAGAQUYSgYIIAUQBgEFGEoFGgYDC4IFFwYBBRoGkAUXBgEFAQYDsn6sBgEFAwYDDcgFDgYBBQEDc0oFIAACBAEDDS4FAQNzSgUgAAIEAQMNPAUNAwlYBQEDakoFIAACBAEDDTwFAwYDCTwFBQYBBQMGAwzyBQoDCwEFDwYBBQo8gjwFBwYDTJAFKQYBBTJKBQs+BQMGPAZmBQoGAzIBBgFYBQUGQAUXBgEFBgYDtX9KBQMXBQUGAQVDAAIEAVgFKQACBAE8AAIEAVgFFQPGAAEFBQYDv39KBQcGFjgGXAULBl9mBQcGEAUpBgEFMkoFC0wFAwY8BmYFGgYDPAEFEAYBBRc8BRpmBQUGdQUGA65/AQUDFwUFBgEFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGpVgFGgYDPAEFFwYBBQEDwwB0WCAFBQYDoX9mBRMGAQUDBm0FEwYDeQEFLgACBAE1BRsAAgQBSgUMBl4FGQYBBQcGdQUMxwUSBgEFGTwFDGYFCgZPBQ8GAQUKPAYILgUPBgEFCjwFGgYDCoIFFwYBBQEGA8cACEoGAQUDBgMNugUVAAIEAQYBBQEDc3QFFQACBAEDDTwFAQNzPAUNAw88BRUAAgQBSAUDBkwFHAYTBQU7BksFHAYBBQUAAgQBWgUBg1ggBQUAAgQBHwaQBRwGAVgFAQYD+gU8BgEFAwaGExMZBRIGGgUVA3hKBQMGhAUFBgEFCAZQBQoGWAUIBpcFCgYBBQeqBQqCBTkDDTwFBQZmBSgGAQUWAAIEAwbVBREAAgQBAQACBAEGSgUDBmsFHgYBBQNKPAUBkWYFCgNuWAUHPAUJA2zySgUGBgPHfAg8BgEFAwYDCQhKEwUGBgN2AQUtAwpmBQMGkQUFA7l+AQUDGBMFEgYBBTdKBQ4vBTdJBQh0BQMGPQUGBgEFLQACBAIDvgG6BS4AAgQBA8J+WAUFBnUFEwYBPAUK1gUDBj0FGAYBSgUDBgO+AQEWEwUoBgO9fgF0BQkDwwEBBSsAAgQBAw/kBQkDcTwFKwACBAEDDzwFCQNxggUDBlkDDgEFKwACBAEGAQUDBoMFCgEFBQMT5AUTBgEFAwaSBQUGAQUUBpUFEQYBSgUMPTysZgUDBgMLWAUFBgEFIpgFAwZmBR4GAQUFLpAFAwYDDHQDEwEFBQYBBQwGAxOeBpAFDwNakAUDBgPzfQgSBRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUtAAIEAgN55AUrAAIEAgMWWAUJA3FmBQMGgwMOARMFCgEFKAYDCZAFBQNodAUoAxg8BQUGgBMFNwYBBRFmBTdKBRsuBR4ITAUVOgUFBj4GAQUKBgN2AQUFBgMOWAUDBkoFBQYBBQMGlwUFBgEFOQACBAGQBTQAAgQBPAU5AAIEATwFNAACBAE8BSkAAgQBLgUIBooFCgYBBQMGAxGeBQUGAQaVBRMGAQUDBnsFFAACBAEGEwACBAHCBREDGpAFEwACBAEDekoFEcAFBwa7BRTHBgFKBQwGMQUHA6F7CEoFKQYBBTJKBQs+BQMGPAZmBQwGA90EAQZYBQUGQQUGA4l7SgUDFwUFBgEFQwACBAGCBSkAAgQBPAUHXQUVA+0EZgUFBgOTezwFBwYWOAYyBQsGXwUDBjwGZgUMBgPdBAEFEgMLWAYBBQcGA5Z7rAUpBgEFMkoFC0wFAwY8BmYFEgYD6AQBBkouBQUGPQUGA4J7AQUDFwUFBgEFQwACBAGCBSkAAgQBPAUFBl0FBwYBajgGMgULBqUFAwY8BmYFEgYD6AQBBkoFATBYBQMGA/1+yAUFA7l+AQUDGBMFEgYBBTdKBQ4vBTdJBQh0BQMGPQUGBgEFLQACBAEDvgGCAAIEAVgFCAYDNOQFCgYBBQMGAxGeBTkAAgQBBgNnAQUFAxlmBpUFEwYBBQMGewYBBgPzfYIFGAYBSgUDBgO+AQEWEwUoBgO9fgF0BQkDwwEBBS0AAgQBA3nkBSsAAgQBAxZYBQkDcWYFAwaDAw4BBQUGAxasBRIAAgQBAxE8BQUGlgUHBgEFCkoFIj4FBzoFAwY+BSIGAQUePAUFLpAGQQUTBgEFAwZ7BhMFFAACBAGmBReRBQN0BRQGsgUMBhM88gUDBkwFDwYDbQEFGQACBAEDY6wFAwYDEboFOQACBAEGA2cBBR4DGWYFBS4FAwYDDLoDEwEFDAMTggUFA2HyBQsGAQUDBkwFBQYBBgMQkAUKBgEFBQY9BQcGAQUKSgUDBk0FDAMJAQUPBgMLukqCBQMGA090AxMBBRQAAgQBBgEFDwNtkAUUAAIEAQMTZgUFBjQFCgYBBQUGPQUHBgEFDwNmSgUKAxpmBQMGTQUUA0N0BREGATwFBQYDClgFCgYBBQc8SlgFFwMgWAUDdAUUBrIFDAYTBRQAAgQBCDAFAwaeBRQAAgQBBgEFBQZsBQoGAQUFBj0FCgYBBQdmBQpKBQMGTQUUAAIEAQYDbFgFAwYDClgFBRgFCgYBBQUGPQUHBgEFCkoFAwZNBRcGA21YBQN0BQYGA+198gYBBQMGCFIFBQNqAQUDGBMFNwYBBRIuBQ5LBTc7BQZ7BQgDeTwFAwY9BQYGAQUuAAIEAYIFAwauBRgGATwFAwYDEAETExQFKAYDbAFYBQkDFAEFAwYIZxMFBQYBBgMsZgUHBgEGAwuQBRUGAQUIBnYGkAUkAAIEAaQFO2sFJAACBAGZBQUGngUIBgEFEgACBAFYBTwAAgQCWAUQdQUJkAZoBQ4GAQULSgUFBrwFOwYBBQc8BTtKBRAIPAUFBmcFCAN0AQUDAxDkBQUGAQUsWQUnPAUsPAUnPAUDPAUYBpUFDAYT1jwFBVoFAwZmBRIAAgQBBgEFAwbPBQUGAQUzAAIEAUoFLgACBAFmAAIEAS4FGwACBAE8BQUGTwUHBgEFBQbABQcGAQUKBgMJkAUMBgEFAwYDCghKBQUGAQaiBQoGAQUHWAUMBgMOSgZYBQcGA7V8ggUpBgEFMkoFCz4FAwY8BmYFDAYDyQMBBQ4GA6d8WDwFBQYD3gMBBQYDnXxKBQMXBQUGAQVDAAIEAYIFKQACBAE8BQddBRUD2QNmBQUGA6d8PAUHBhY4BjIFCwZfBQMGPAZmBQwGA8kDAQUaXwUQBgEFBwYDrnysBSkGAQUySgULTAUDBmYGZgUaBgPQAwEFEAYBBRcuBRpmBQUGUgUGA5N8AQUDFwUOBgEFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGpdYFAQPZAwFYIDwuLi4gBQgGA2SCBQoGAQUFBoYFCgYBBQdYSgUIBuYFCgY8BQUGogUKBgEFB1hKBQUGA+J+ngUTBgEuBQrWLtYFAwYD6QABBQUGAQa/BQoGAQUHPEoGA1rIBQgaBSEGA3gBPAUHBgMxyAUUBgEFBQZoBQcGAQUZkQUFdAUeBrEFFAYBBRs8BR5mBQ6DCBJYBR4G+gUUBgEFGzwFHmYFCQblBR7HBRQGAQUbPAUeZgUNToIFAwYDUtYFBQYBBRM9BQU71gUBBgOpA7oGAQUDBukFBQYBBQFFBQVBBQ0DGWYFAwZKBQUGAQUTmAUDA3lKBQUGQwUOAQUTBgFKSgUQigUFRgUTfgUtAAIEAQZYBQUWFgUQBgEFBwACBAGCBRQGhwYBPAUHBgOZeboFKQYBBTJKBQs+BQMGPAZmBRQGA+UGAQYBBQkGWQUOBgOKeQEFGwP2BjwFBgYDhXlKBQMXBQUGAQVDAAIEAVgFKQACBAE8AAIEAVgFGQP2BgEFBQYDj3lKBQcGFjgGXAULBokFAwY8BmYFFAYD5QYBBgFYPAUBAw4BSi4FBQa5BQEG10oFBQYDSdYFDgEFHQEFBRaGBg4FIU4FEAACBAFYBQcAAgQCCEoGTgUVBgEFBQaHBRMGAdYFBwYDHwEGyKwFDQNkAQUBBgPvAIIGAQUDBukFDwYYBQEDdUoFBb8GlgUHBgEGXAU2AAIEAQYDEgEFFQNuSgUDBgMSPAUcAAIEAQYBBQUGAwqCBRMGAQUDBgMKWAUHBhMFBQaDBRIGAQUDBmgFBgYBBQ8AAgQBSgUDBgMNyAUFBgEFGwACBAFKBS4AAgQCkAUkAAIEAjwFBQa7BRIGAQUDBmsFBQYBBRsAAgQBSgUHBgNIngUVBgEFAwYDDYIFBQMPAQUDFwUPAAIEAQYWBQMGAxOsGAUFBgEFEpYFCAY8BQoGAQUIBpYFCgYBBQUGXAUDCDMFDwYBBQU8BRdLBQOQBsAFBQYBBsAFBxMFFwYBBQcAAgQCPFgFJgACBAFKBQcAAgQBSgACBAQ8BoMTBQoGATwFFAACBAEuBT4AAgQCZgULyQUJBnUFHgYBBQlKBQMGAw8IIAUOBgEFBTwFHwACBAFKBR4GAxWeBRsGAQUBaFhKBQgGA/h+ggUKBgEFBQaHBTYAAgQBBhcFEkUFAwZBBRwAAgQBBgEAAgQBggUDBgMUdBYDEwEYBQUGAQYIJAMzCHQFA4gFBQMPggUVBgEFBQACBAI8WAUkAAIEAUoFBQACBAFKAAIEBDwFHgaBBRAGAQUbPAUeZgUBTFguLgUFBgNjdAUDzgUOBgEFBTwGgwUDiAUFBgEFC1AFBQY8BRcGAQUFBpEFCAEFFQACBAHJAAIEAQYBAAIEATwFBQYDsH+CBRIGAQUDBmsFBQYBBRsAAgQBggUcBskFGQYBBQcGyQUcxwUSBgEFGTwFHGYFBQYDD54FHAMNCHQFGQYBBQcGgwUcxwUSBgEFGTwFHGYFOQACBAIDUJ4FBwYIFAUdBgEFF8kFHS0FBwZLBRcBBkouBQsG2AUTAQUgBgEFFzoFIEwFFwY6AAIEAQZmAAIEAfIFAwYDEAEFGwACBAEGAQUcBpEFGQYB5AUDBgNoghYFDgYDDQEFDwACBAEDc1gFOQACBAKeBTUAAgQBCH8FIwACBAE8BQMGkwUGBgEFDwACBAGCBQMGA2i6BQUGAQU2AAIEAWYFHAACBAFKBQUGAwqCBRMGAQUDBgMKZgUjAAIEAQYTAAIEAfIAAgQBdAUfAAIEAQPSAAEFAwalBQUGAQUBBgMUCGYGAQUDBs0TBSABBQcGEQU/ZwUBA3pKBT9sBQMGQAUUAQUNBgFKdAUUSjwFBQZnBQ0GEQUOZwUUBkkFDQYBBRSsLgUDBlEFDQYBBQY8BQUGWQUUBgEFAwa7BQUGAQUNQwUDAwtKBQUDbjwFIlEFBQN5PAUDBjUFEwYTBQMDCsgFEwN2ZgUDAwo8BmZeBQkGEwUVOwUDQQUVNwUDBj0FEQYBBQMyBRE4BQNcBRE4BQMGQAMJWAUeBgEFEUoFAwZQBQEGZ1guBQMfWAUBBgAJArA/AEABAAAAA4kCAQYBIAUDBrMFFQEFAxcFDQYBBQEDdEoFBQMMWAULXQUDBkoFBwOnegEFAxcFCgYBSkq6WFgFDgPWBQEFCgOqeko8BQMGA9YFAQUFBgEGAwmQBQPaBQEGkVggBQUGA2x0BRcGAQUFBgMK8gUDAwnWBQEGkVggBgPbfTwGASAFAwazBRUBBQMXBQ0GAQUBA3RKBQUDDFgGWQUXBgEFAwbMBQcDtHwBBQMXBQoGAUpKulhYBQ4DyQMBBQoDt3xKPAUDBgPJAwEFBQYBBgMJkNwFHAEFEgYBBQcGA7Z2yAUpBgEFMkoFC0wFAwZmBmYFHAYDyAkBBRIGAQUZLgUcZgUHBksFBgOidgEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBqXWBQUGA70JAQUDAxHWBQEGkVggBgOAAjwGASAFAwbCBRUBBQMXBQ0GAQUBA3NKBQUDDVgFCAaVBQoGAQUDBmsFBwP8eQEFAxcFCgYBSkq6WFgFDgOBBgEFCgP/eTw8BQMGA4EGAQUFBgEFCAbABRgGGjwFCgN4WAUuAAIEAVgFGgACBAE8BQUGUgUHBgEGiQUZBgEFBQYDE1gFBwiXBRzHBQUBBRwBBRIGAQUZPAUcZgUFBgMLngUHBgEGAxBKBRsGAQUrAAIEAYIAAgQBPAUFBkAFAwgXBQEGkVggBQcGA25mBRgGAQUFBgO5f4IFFwYBBQUGCG8FFwYBBQUGAw8IdAbWBQcGAxkuBSEGAQUxAAIEAYIFHwACBAEuBQkAAgQBPAURbAUHPAUJBoMFFwYBBQYGAzIIIAYBBQMGCDQTBSABBQMUBQ4GAxABBQYDZ0oFKwACBAEDCYIFBQbeBSQGAQUDBlIFBQYBBQMGAzSeBTMGA7cBAQVGAAIEAgPOfkoFBVMFKwACBAEDPZAFOAACBAEDcawFHANkPAU4AAIEAQMcPAUcA2RKBRMAAgQBAxTWBSAAAgQCWAVNAAIEArQFDgACBAQ8BQsAAgQELgUHBlAFJgYBSgVkAAIEBgYDUQEFYAACBAUBAAIEBQY8BQcGagUQBgEFBwZnBQkGAQUMBgMTkAUWBgEFDjwFCQZRBRoGAQUrAAIEAQMZZgUHBgNpPAUJBgEGUgUOBgEFIAACBAFYBScAAgQBPAACBAE8AAIEAboFBQYDrX8BGQU6BgEFLlgFJAN5WAU6QwU0PAUuPAUFBj0FBwYBPAYDD2YFMAYaBSYDeVhJBQcGSwUFGQUwBgEFMwO9ATwFKgPDfkoFJDwFAwZsBUYAAgQBBhcFYAACBAUGSgACBAUGggUDBgNHAQUFBgEGAw+eGQU6BgEFLlgFOqwFNDwFLjwFBQY9BQcYBQUDEQEFMAYBBSYDb1gFMAMRPAUqPAUkPDwFAwZCBQUGAQUmAAIEAVgFAwYDOFgFKwACBAEGFwUFBkoGSgUhAAIEATwFBwaRBQwGAQUJSgUFBkwFDQYVBQpHBQc8BQMGTQUFBmYFAwYDPJAFBQYBBQgGpAUKBgEFCAbOBQoGAQUDBgMJnskFKAYBBQM8BSg8BQM8BocFDgYBBQU8BRsAAgQBSgUcBmcFGQYBBQcGyQUcxwUSBgEFGTwFHGYFDAZPBQkGA9p4AQUMA6YHSlgFBwYD2HhYEwUYBgEFEEoFCkqQBQwGA6cHAQUFkQUGA8p4ggUDFwUFBgEFCAaWBQsGAQUFBgMJWAaCggUJBgOSBgEFCwYBBQlZBTgAAgQBWAUuAAIEATwFCwazBRAGAQUNPEoFIAACBAIDDVgFDgACBARSBQcGQgYBBWQAAgQGBgNRAQVgAAIEBQEFCwACBAQGAykBAAIEBFgFAwYDCgEFBQYBBQMGAwuQBQ0GAQUFngYDDZAFDwYaBRcDeDwFCT0FFwMOSgNxSgUFBj0ZBREGEwU1AAIEAWsFETcFBQZPBTUAAgQBBgEFDwACBARmBQUGZwUpAQUXBgEFDwACBASdBRc9BSlKPAUHBmwFFwYDegEFEGwFBwZLBSkDeQEFFwYBBSnWLgUQXwURA80AngUFBgO2f0oFBwYBBpUFFQYBBQcGQAUJBgEFIAbJBR0GAQULBp8FIMcFFgYBBR08BSBmBQ0DDEoFAwZKBQUGAQYIJAMkCHQFHscFEAYBBRs8BR5mBQMGUAUoBgEFAzwFKDwFAzwGiQURBgEFAwZLBhYFEWIFAwZ2ExMFAQYTWCAFA4EFBQYDvXjWBjxYBQkGhwasWIKCBRUD9AZmngUFBgMbAQUDA/d+CHQFJgACBAEGAQVGAAIEAtsAAgQCngUzA7IBAQUmAAIEAQPJfvIFBQYDjwHyBQcDl38IdAUJBgEIdAUFBgMXAQUHBgEFAwbtBSsAAgQBBhcFBQZKBSsAAgQBBgEAAgQBngUBBgOMAgggBgEIngUDBuUTBRUGAQULYAUPA3pmBQcAAgQBCCwFAwYwBSAAAgQBBgMXAQUPA2lKBRwAAgQBAxeeBQ8DaTwFHAACBAEDF3QFDwNpLgUkAAIEAQYDFwisAAIEAQYBBQwDFoIFCQMSSgUMA27IdAUHBgO8BgEFBgOqaQEFAxcFDgYBBUMAAgQBPAUFPAUpAAIEAVgFBQZdBQcGFkYGAwlYBSkGAQUyPAUDBkwGZgUcAAIEAQPvDwEFJAACBAEGSgUgAAIEAQYBBRoAAgQBSgUkAAIEATwFBQaJBQcGAQZcExMXFgMNAQUOBhUFFEcFBwY9BRQGAQUHBoQFDgEFDAYDcIIFIAACBAEDakoFGgMNPDsFCQYDHC4FGQY8BRNKBQk8CEoFBwYD4m8BBoKCBQ0GA4sWAQU1AAIEAQYBBQ8GCEwFEQYBBReGBQ8GAwlYBREGAQZcBRUGAQUTPAYDDoIFLQYBBTY8BREDsn2sBRkDwHxKBQ4GOgaQBRADvgYBBQMGPAUBBhO6BQ0GA616CBIFGgYBBQkGewULBgEFFAalBRYGAQUPBgMNngUrBgEFDwY9BREGPAUUBmwFKwACBAEGA3kBBSkAAgQBA3EIEgUNBgMgSgUPBgEGAwqQBroFEQOgAuQFFAMWSgUZA6p8ZgUTA9cDPFgFDQYD1H1YBRoGAQUNBnsFOgYDkH8BBQ8D8ABKBRQGowU6BgOLfwEFFgP1ADwFDwZuEwURBgEFFAajBUAGFkoFCQaHBQ0WBksFGQOtfjwFDQPSATwGWV4FDwYBBSkAAgQBSgUNBgMOkAYUBTY6BQ0GSxMFNgaOBRkDmX48BQ0D6QE8BlkD1gFYBREGAQUPSgUZA8B8kAUWA8wDPAUTaFgFDQYDkn1YBR0GAQUZA6B/PAUdA+AAPAUNAAIEAVgFHUoFDQACBAE8BlkDtQJYBR8GA8d9AQUvA70CPAUPRgUSBqQFFAYBBRIGpAUUBgEFEgZsBRQGAQUPBgMKngUmAAIEAQYBBQ0GA/MAdAURBgEFD0oFGQPbe5AFFgOxBDwFE2hYBQ8GA7R/WAUXBgEFEUoFDwaYBREGAQUjAAIEAZAFDwYDqQKeFNsFDQOdfoIFEQYDhH8BBRoD/ABKBQ0GSxMFGQYDwnsBBRMDvQQ8BQ1ZBgO+flgFGgYBBR8D4X08BRoDnwI8BQ0GAwlmBQ8GAQaGBgEFBgYDp3t0BQMXExYEAgUcA8ZyAQUFFRMUEwUiBhMFLjsFInUFLkkFIksFDXMFBQY9BQgGAQUFBj0FFwYBPAUULgUdPAUNPAUFBi8TBQ0GEQQBBQUAAgQBA7ANdAaXBQcGAQUFBqMEAgUcA6FxAQUFFBMTExMFCAYBWAUKBm4FBxMFGwYTBAEFCQYD7A7yBSQGAQUHBocGWAUNBgPJAQEGFwUeRQUNBngFOgYDDQEFDwNzdAYDDZAFKgACBAEGAQUPBj0GSgU61QUZA75/PDwFDQYD0QBYBRIGEwUfAwtKBToDZTwFDwMPSgYDDJAAAgQBBgEFH0oFGQOjfzwFDwACBAED3QA8AAIEAVgFDQYD8QFYBRoGAQUfA49+PAUaA/EBPAUMBgMaZgUOBgEFDwaGAAIEAQYBAAIEAWYFOgPWfQhKBRkDvn9KPAUNBgOhAlgFGgYBBR8DvH48BRoDxAE8BQ0GAxlmBQ8GAQaGAAIEAQYBAAIEAWYAAgQBugUNBgO0fy4FGgYBBR8D6348BRoDlQE8BQ0GAxtmBQ8GAQaGAAIEAQYBAAIEAWYAAgQBugUNBgPCAy4FDwYBBoMFEQYD7H0BBRwDlAJKBRkDrHpKBQ0GA7UFggUPBgEGgwURBgOKfgEFHAP2AUoFGQPKenQFDQYD1wSCBQ8GAQURA+l+kAUVA9IBSgUZA+56WAUNBgPdBYIFDwYBBoYFEQYD330BBRwDoQJKBQ8GdQUZBgOeegEFDwPiBTwFEwOIe1gFDQYDmwI8BR8GA9h9AQUPA6gCPAYDCYIFBgPgewEFAxcTFgQCBRwD4HEBBQUVExQTEwUPBj0uBQdlBQ09BQctBQUGdQUTBgEFBzwFBQY9EwYBBAEAAgQBA5UOAQUZ4AUFBgMLngUHBkoGWQUVBgEFBQZcBAIFHAP9cAEFBRQTFBMTBRkGAQUHPQUZcwUFBlkTFBQFBxMFGgYByDy6ZgQBBQcGA/oOAQUTBgN2AQUHAwpmSrqsBQ0GA6gBAQUeBgEFDQZ4BQ9QBSEAAgQBBgEFDz1KBSuPBRkDRTwFIQACBAEDOzwFDwZLBlgFEwMuWAUNBgOjATwFHwYD0H4BBQ8DsAE8BgMKggACBAEGAQACBAHkAAIEAYIFEwPTflgFDQYD0AE8BR8GA6N+AQUPA90BPAYDCoIAAgQBBgEAAgQB5AACBAGCBRMDpn5YBQwGA/4BPAUfBgP1fQEFDgOLAjwFDwYDCoIAAgQBBgEAAgQB5AACBAGCBQ0GA6B9WAUZBgNukAUNAxI8Bl0FDwOnBVgFEgYBBRGGBuIFHgYBBREGdQUaAQUpAQURE60FLQYBBRwAAgQBWAUUAAIEAghmBRUG5QUqBgEFEQaDBQ4GA7l6AQUqA8cFSgUZA7t6PAUNBgPzBIIFDwYBBQ2RBQ8GvwUiBgEFIAACBAF0BREAAgQBPAPHfoIFIgO5AUoFGQOHezwFGAOXBTw8BQ0GAxRYBQ8GAQaDBREGA5R+AQUcA+wBSgUZA9R6dAUNBgOiBYIFDwYBBoMFEQYDnX4BBRwD4wFKBRkD3Xp0BQcGA49/ghcFKwYBBQmsBggUBSsGAQUNSlgFCQY9BSQGAQUJBj0FJAYBLgUHBhUFCQMRAQUkBgEFBwZrFwUiBg0FB3kFAZNYSgUPBgOeAQEFIQYBBQYGA5pxPAUDAw8BBRUAAgQBBgEFAwbYBQ0GAQUFPAaDBR0GATwFBQACBAGCAAIEAUoAAgQBngUhA9QOAQUZA6l/PDwFDQYD7QVYBQ8GAQUUBt4FFwYXrAUFBgP/eFgGCGYFEQPHBAEFGAPXAUoFGQPpejwFFQOSBTxYBQcGA795WBMFCRgGCC4FGQOoAQEFGAP9AzwFFWhYBQcGA8N6WAUVBgGeBQ8GA6IDAQUcBgEFIC8FHHMFDwZnBQcDtn1YBQkGAQUKAxGQLnQFEQYDmAIBBUAGAQUPBgPoAZAFNAACBAEGAQUTBgPaAoIFIwYBBREDun08BRkDwHxKBSMDhgY8BQ8GA9d+ggURBgPjfgEFIAOdAUoFDwZ1EwUZBgOhewEFGgPeBDwFFUsFDwYDl3yeBSsGAQUPBgPPAoITBSoAAgQBBgMhAQUWA19KBQ9lBRMDCUpYBQ8GA0xYBScAAgQBBgEFBQYD6250BR0GAQUFAAIEAYIAAgQBSgACBAGeAAIEAVgFDwYDlg8BBnRYBgMbWAU4BgE8BSMAAgQBA7ECWAURBqMTBQ4GA5F8AQUYA+4DSgUVZwMSSgNuWAUPBgM9WBMFKgACBAEGA7x/AQUWA8QASgUPZQUTAwlKWAUJBgPuelgGgoIFDwYD/wMBBSgAAgQBBgEFDwYD3X2CBSsAAgQBBgEFEQYDgASCBRMGAQZPBSAGAQUTBnUFIgYBBREGA/F+ghMFDgYDiXwBBRgD9gNKBRVnAwpKA3ZYBRMGA5UBWAURBgO2fgEFIgO5AUoFGQOHezwFGAOXBTwFJANzPAURA7Z+dFgFBwYDi3tYBRMGA3YBBQcDCjxKBRMDdnQFBwMKZlgCBQABAWMkAAAFAAgAbQAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwT1FAAA/BQAADIVAABSFQAAAgEfAg8NkRUAAAGiFQAAAbIVAAACuRUAAALCFQAAAswVAAAC1RUAAALdFQAAAuYVAAAC7hUAAAP2FQAAAv8VAAACCBYAAAAFAQAJAmBRAEABAAAAA4QDAQYBBQMGsAUBBg4FDkAFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAYDCVgFKQYBBTJKBSlYBQMGPgUBBmdYBQcGA3g8BjwFC4kFAwY8BQEGZ1gGeAYBBQMGAzwIEhQFDgYBBQEDQkoFIAACBAEDPi4FAQNCSgUgAAIEAQM+PAUpWwUBA79/SgUPA8UAPEoFIAACBAEDeQEFAwY/BQUGAQUDBgMVyAUFBgEFAwa/BRIaBRwGAw8IWAUHBkkGEwUJZQUHBj0GWAUSBgNxAQUHTBMFCwYVBQc5BoM9EwULBgEAAgQBWJAAAgQBPAUHBlkFCgYBBQcGWgUKBgEFCQYwEwUQBgEFC0kFDllmBQUGA2gBBRMGAQUDBkAFGwACBAEGAQUMBlkFGQYBBQcGgwUMxwUSBgEFGTwFDGYFBQYDG54FGscFAwEFGgEFEAYBBRc8BRpmBQFOWCAg5AUFBgNJ8hQFLQYVBQc5BloFDwYTBQmBBlkFDwYBBQUGwgUHBgEGSwUVBgEFBQY9BRMGAQUFBnUFAQYDJwFYICAFBwYDVGYFDQYBCCAFCQYqBQ8GAboFAQYDwAZKBgEFAwaGExMZBRIGGgUVA3hKBQMGhAUFBgEFCAZQBQoGWAUIBpcFCgYBBQeqBQqCBTkDDTwFBQZmBSgGAQUWAAIEAwbVBREAAgQBAQACBAEGSgUDBmsFHgYBBQNKPAUBkWYFCgNuWAUHPAUJA2zySgUBBgOdfwg8BgEFAwa/BQUGAQUBRQUFQQUNAxkuBQMGSgUEBhgFBQN6PAYDIlgFAQZZBQVzBgNKrAUOAQUdAQUFFoYGDgUhTgUQAAIEAVgFBwACBAIISgZOBRUGAQUFBocFEwYBZgUNFQUBBgOzevIGAQUDBgMNugUVAAIEAQYBBQEDc3QFFQACBAEDDTwFAQNzPAUNAw88BRUAAgQBSAUDBkwFHAYTBQU7BksFHAYBBQUAAgQBWgUBg1ggBQUAAgQBHwaQBRwGAVgFAQYDlgQ8BgEgBQMGeQUKAQUeAQUDExMFAQYDeQEFGgYDV2YFAxQTFAMfAQQCBQgGA956AQQBBQEDpwU8BQo3dDwFAwYDDgEEAgUcA8p6AQUFFBMTExMFCAYBBQkGhAY8BksFDAYBLgUOBmgFEQYBggQBBQcGA8QFARMFCgYDEAEFBwACBAQDXuQFIQACBAEDHjwFCQACBARmBQMGagUKBgEIPJAFAeUEAgUKBgOtepAFDQYBBQcGgwUdBgE8BRufSgQBBQcAAgQEA64FAQUDBgMedAUHAAIEBAYDYgEFIQACBAIDHi4AAgQCLgACBAK6AAIEAkoAAgQCugACBAKeBQMGAQZmWAUBBgPAe6wGAQUDBgM+5BQFDgYBBQEDQEoFIAACBAEDwAAuBQEDQEoFIAACBAEDwAA8BSlbBQEDvX9KBQ8DxwA8SgUgAAIEAQN5AQUDBj8FBQYBBQMGAxXIBQUGAQUDBr8FExcFDAYBBRNKBQEDnn+CLkoFBwYD5H5mBSkGAQUySgUpWAUDBj4FEwYD/AE8BQMDhH5KPAUTBgP8AQEGAQUWAAIEAcgFEwACBAFKBQcGkgUGA+19AQUDFwUOBgEFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGiYIFBQYD8wEBBRMGAQUDBngFGwACBAEGAQUMBpEFGQYBBQcGgwUMxwUSBgEFGTwFDGYFEwZOBQwGAQUTSgUHBgOCfgggBSkGAQUySgUprAUDBj4GZgUaBgOBAgEFEAYBBRc8BRpmBQUGSwUGA+l9AQUDFwUOBgEFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGz2YFBQYD3wEBFAUtBhUFBzkGWgUPBhMFCYEGWQUPBgEFBQbCBQcGAQZLBRUGAQUFBj0FEwYBBQUGdQYBBQEDFgFYBRMGA3e6BQwGAQUTSgUaBocFFwYBBQcGA2lmBQ0GAQggBQkGKgUPBgG6LgUaBgMbAQUXBgEFAQYDvgW6BgEFAwbpBQ8GGAUBA3VKBQW/BpYFBwYBBlwFNgACBAEGAxIBBRUDbkoFAwYDEjwFHAACBAEGAQUFBgMKggUTBgEFAwYDClgFBwYTBQUGgwUSBgEFAwZoBQYGAQUPAAIEAUoFAwYDDcgFBQYBBRsAAgQBSgUuAAIEApAFJAACBAI8BQUGuwUSBgEFAwZrBQUGAQUbAAIEAUoFBwYDSJ4FFQYBBQMGAw2CBQUDDwEFAxcFDwACBAEGFgUDBgMTrBgFBQYBBRKWBQgGPAUKBgEFCAaWBQoGAQUFBlwFAwgzBQ8GAQUFPAUXSwUDkAbABQUGAQbABQcTBRcGAQUHAAIEAjxYBSYAAgQBSgUHAAIEAUoAAgQEPAaDEwUKBgE8BRQAAgQBLgU+AAIEAmYFC8kFCQZ1BR4GAQUJSgUDBgMPCCAFDgYBBQU8BR8AAgQBSgUeBgMVngUbBgEFAWhYSgUIBgP4foIFCgYBBQUGhwU2AAIEAQYXBRJFBQMGQQUcAAIEAQYBAAIEAYIFAwYDFHQWAxMBGAUFBgEGCCQDMwh0BQOIBQUDD4IFFQYBBQUAAgQCPFgFJAACBAFKBQUAAgQBSgACBAQ8BR4GgQUQBgEFGzwFHmYFAUxYLi4FBQYDY3QFA84FDgYBBQU8BoMFA4gFBQYBBQtQBQUGPAUXBgEFBQaRBQgBBRUAAgQByQACBAEGAQACBAE8BQUGA7B/ggUSBgEFAwZrBQUGAQUbAAIEAYIFHAbJBRkGAQUHBskFHMcFEgYBBRk8BRxmBQUGAw+eBRwDDQh0BRkGAQUHBoMFHMcFEgYBBRk8BRxmBTkAAgQCA1CeBQcGCBQFHQYBBRfJBR0tBQcGSwUXAQZKLgULBtgFEwEFIAYBBRc6BSBMBRcGOgACBAEGZgACBAHyBQMGAxABBRsAAgQBBgEFHAaRBRkGAeQFAwYDaIIWBQ4GAw0BBQ8AAgQBA3NYBTkAAgQCngU1AAIEAQh/BSMAAgQBPAUDBpMFBgYBBQ8AAgQBggUDBgNougUFBgEFNgACBAFmBRwAAgQBSgUFBgMKggUTBgEFAwYDCmYFIwACBAEGEwACBAHyAAIEAXQFHwACBAED0gABBQMGpQUFBgEFAQYD2AAIZgYBIAUDBrMFFQEFAxcFDQYBBQEDdEoFBQMMWAZZBRcGAQUDBswFBwO0fAEFAxcFCgYBSkq6WFgFDgPJAwEFCgO3fEo8BQMGA8kDAQUFBgEGAwmQ3AUcAQUSBgEFBwYDtnbIBSkGAQUySgUprAUDBj4GZgUcBgPICQEFEgYBBRkuBRxmBQcGSwUGA6J2AQUDFwUOBgEFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGz+QFBQYDvQkBBQMDEdYFAQaRWCAFBgYDjXqsBgEFAwYDCQhKEwUGBgN2AQUtAwpmBQMGkQUFA7l+AQUDGBMFEgYBBTdKBQ4vBTdJBQh0BQMGPQUGBgEFLQACBAIDvgG6BS4AAgQBA8J+WAUFBnUFEwYBPAUK1gUDBj0FGAYBSgUDBgO+AQEWEwUoBgO9fgF0BQkDwwEBBSsAAgQBAw/kBQkDcTwFKwACBAEDDzwFCQNxggUDBlkDDgEFKwACBAEGAQUDBoMFCgEFBQMT5AUTBgEFAwaSBQUGAQUUBpUFEQYBSgUMPTysZgUDBgMLWAUFBgEFIpgFAwZmBR4GAQUFLpAFAwYDDHQDEwEFBQYBBQwGAxOeBpAFDwNakAUDBgPzfQgSBRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUtAAIEAgN55AUrAAIEAgMWWAUJA3FmBQMGgwMOARMFCgEFKAYDCZAFBQNodAUoAxg8BQUGgBMFNwYBBRFmBTdKBRsuBR4ITAUVOgUFBj4GAQUKBgN2AQUFBgMOWAUDBkoFBQYBBQMGlwUFBgEFOQACBAGQBTQAAgQBPAU5AAIEATwFNAACBAE8BSkAAgQBLgUIBooFCgYBBQMGAxGeBQUGAQaVBRMGAQUDBnsFFAACBAEGEwACBAHCBREDGpAFEwACBAEDekoFEcAFBwa7BRTHBgFKBQwGMQUHA6F7CEoFKQYBBTJKBSlYBQMGPgZmBQwGA90EAQZYBQUGQQUGA4l7SgUDFwUFBgEFQwACBAGCBSkAAgQBPAUHXQUVA+0EZgUFBgOTezwFBwYWOAYyBQsGiQUDBjwGZgUMBgPdBAEFEgMLWAYBBQcGA5Z71gUpBgEFMkoFKawFAwY+BmYFEgYD6AQBBkouBQUGPQUGA4J7AQUDFwUFBgEFQwACBAGCBSkAAgQBPAUFBl0FBwYBajgGMgULBqUFAwY8BmYFEgYD6AQBBkoFATBYBQMGA/1+1gUFA7l+AQUDGBMFEgYBBTdKBQ4vBTdJBQh0BQMGPQUGBgEFLQACBAEDvgGCAAIEAVgFCAYDNOQFCgYBBQMGAxGeBTkAAgQBBgNnAQUFAxlmBpUFEwYBBQMGewYBBgPzfYIFGAYBSgUDBgO+AQEWEwUoBgO9fgF0BQkDwwEBBS0AAgQBA3nkBSsAAgQBAxZYBQkDcWYFAwaDAw4BBQUGAxasBRIAAgQBAxE8BQUGlgUHBgEFCkoFIj4FBzoFAwY+BSIGAQUePAUFLpAGQQUTBgEFAwZ7BhMFFAACBAGmBReRBQN0BRQGsgUMBhM88gUDBkwFDwYDbQEFGQACBAEDY6wFAwYDEboFOQACBAEGA2cBBR4DGWYFBS4FAwYDDLoDEwEFDAMTggUFA2HyBQsGAQUDBkwFBQYBBgMQkAUKBgEFBQY9BQcGAQUKSgUDBk0FDAMJAQUPBgMLukqCBQMGA090AxMBBRQAAgQBBgEFDwNtkAUUAAIEAQMTZgUFBjQFCgYBBQUGPQUHBgEFDwNmSgUKAxpmBQMGTQUUA0N0BREGATwFBQYDClgFCgYBBQc8SlgFFwMgWAUDdAUUBrIFDAYTBRQAAgQBCDAFAwaeBRQAAgQBBgEFBQZsBQoGAQUFBj0FCgYBBQdmBQpKBQMGTQUUAAIEAQYDbFgFAwYDClgFBRgFCgYBBQUGPQUHBgEFCkoFAwZNBRcGA21YBQN0BQYGA+198gYBBQMGCFIFBQNqAQUDGBMFNwYBBRIuBQ5LBTc7BQZ7BQgDeTwFAwY9BQYGAQUuAAIEAYIFAwauBRgGATwFAwYDEAETExQFKAYDbAFYBQkDFAEFAwYIZxMFBQYBBgMsZgUHBgEGAwuQBRUGAQUIBnYGkAUkAAIEAaQFO2sFJAACBAGZBQUGngUIBgEFEgACBAFYBTwAAgQCWAUQdQUJkAZoBQ4GAQULSgUFBrwFOwYBBQc8BTtKBRAIPAUFBmcFCAN0AQUDAxDkBQUGAQUsWQUnPAUsPAUnPAUDPAUYBpUFDAYT1jwFBVoFAwZmBRIAAgQBBgEFAwbPBQUGAQUzAAIEAUoFLgACBAFmAAIEAS4FGwACBAE8BQUGTwUHBgEFBQbABQcGAQUKBgMJkAUMBgEFAwYDCghKBQUGAQaiBQoGAQUHWAUMBgMOSgZYBQcGA7V8ggUpBgEFMkoFKVgFAwY+BmYFDAYDyQMBBQ4GA6d8WDwFBQYD3gMBBQYDnXxKBQMXBQUGAQVDAAIEAYIFKQACBAE8BQddBRUD2QNmBQUGA6d8PAUHBhY4BjIFCwaJBQMGPAZmBQwGA8kDAQUaXwUQBgEFBwYDrnzWBSkGAQUySgUprAUDBj4GZgUaBgPQAwEFEAYBBRcuBRpmBQUGUgUGA5N8AQUDFwUOBgEFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAZcBQsGz+QFAQPZAwFYIDwuLi4gBQgGA2SCBQoGAQUFBoYFCgYBBQdYSgUIBuYFCgY8BQUGogUKBgEFB1hKBQUGA+J+ngUTBgEuBQrWLtYFAwYD6QABBQUGAQa/BQoGAQUHPEoGA1rIBQgaBSEGA3gBPAUHBgMxyAUUBgEFBQZoBQcGAQUZkQUFdAUeBrEFFAYBBRs8BR5mBQ6DCBJYBR4G+gUUBgEFGzwFHmYFCQblBR7HBRQGAQUbPAUeZgUNToIFAwYDUtYFBQYBBRM9BQU71gUGBgO1CboGAQUDBgg0EwUgAQUDFAUOBgMQAQUGA2dKBSsAAgQBAwmCBQUG3gUkBgEFAwZSBQUGAQUDBgM0ngUzBgO3AQEFRgACBAIDzn5KBQVTBSsAAgQBAz2QBTgAAgQBA3GsBRwDZDwFOAACBAEDHDwFHANkSgUTAAIEAQMU1gUgAAIEAlgFTQACBAK0BQ4AAgQEPAULAAIEBC4FBwZQBSYGAUoFZAACBAYGA1EBBWAAAgQFAQACBAUGPAUHBmoFEAYBBQcGZwUJBgEFDAYDE5AFFgYBBQ48BQkGUQUaBgEFKwACBAEDGWYFBwYDaTwFCQYBBlIFDgYBBSAAAgQBWAUnAAIEATwAAgQBPAACBAG6BQUGA61/ARkFOgYBBS5YBSQDeVgFOkMFNDwFLjwFBQY9BQcGATwGAw9mBTAGGgUmA3lYSQUHBksFBRkFMAYBBTMDvQE8BSoDw35KBSQ8BQMGbAVGAAIEAQYXBWAAAgQFBkoAAgQFBoIFAwYDRwEFBQYBBgMPnhkFOgYBBS5YBTqsBTQ8BS48BQUGPQUHGAUFAxEBBTAGAQUmA29YBTADETwFKjwFJDw8BQMGQgUFBgEFJgACBAFYBQMGAzhYBSsAAgQBBhcFBQZKBkoFIQACBAE8BQcGkQUMBgEFCUoFBQZMBQ0GFQUKRwUHPAUDBk0FBQZmBQMGAzyQBQUGAQUIBqQFCgYBBQgGzgUKBgEFAwYDCZ7JBSgGAQUDPAUoPAUDPAaHBQ4GAQUFPAUbAAIEAUoFHAZnBRkGAQUHBskFHMcFEgYBBRk8BRxmBQwGTwUJBgPaeAEFDAOmB0pYBQcGA9h4WBMFGAYBBRBKBQpKkAUMBgOnBwEFBZEFBgPKeIIFAxcFBQYBBQgGlgULBgEFBQYDCVgGgoIFCQYDkgYBBQsGAQUJWQU4AAIEAVgFLgACBAE8BQsGswUQBgEFDTxKBSAAAgQCAw1YBQ4AAgQEUgUHBkIGAQVkAAIEBgYDUQEFYAACBAUBBQsAAgQEBgMpAQACBARYBQMGAwoBBQUGAQUDBgMLkAUNBgEFBZ4GAw2QBQ8GGgUXA3g8BQk9BRcDDkoDcUoFBQY9GQURBhMFNQACBAFrBRE3BQUGTwU1AAIEAQYBBQ8AAgQEZgUFBmcFKQEFFwYBBQ8AAgQEnQUXPQUpSjwFBwZsBRcGA3oBBRBsBQcGSwUpA3kBBRcGAQUp1i4FEF8FEQPNAJ4FBQYDtn9KBQcGAQaVBRUGAQUHBkAFCQYBBSAGyQUdBgEFCwafBSDHBRYGAQUdPAUgZgUNAwxKBQMGSgUFBgEGCCQDJAh0BR7HBRAGAQUbPAUeZgUDBlAFKAYBBQM8BSg8BQM8BokFEQYBBQMGSwYWBRFiBQMGdhMTBQEGE1ggBQOBBQUGA7141gY8WAUJBocGrFiCggUVA/QGZp4FBQYDGwEFAwP3fgh0BSYAAgQBBgEFRgACBALbAAIEAp4FMwOyAQEFJgACBAEDyX7yBQUGA48B8gUHA5d/CHQFCQYBCHQFBQYDFwEFBwYBBQMG7QUrAAIEAQYXBQUGSgUrAAIEAQYBAAIEAZ4FAQYDmnsIIAYBBQMGzRMFIAEFBwYRBT9nBQEDekoFP2wFAwZABRQBBQ0GAUp0BRRKPAUFBmcFDQYRBQ5nBRQGSQUNBgEFFKwuBQMGUQUNBgEFBjwFBQZZBRQGAQUDBrsFBQYBBQ1DBQMDC0oFBQNuPAUiUQUFA3k8BQMGNQUTBhMFAwMKyAUTA3ZmBQMDCjwGZl4FCQYTBRU7BQNBBRU3BQMGPQURBgEFAzIFETgFA1wFETgFAwZAAwlYBR4GAQURSgUDBlAFAQZnWC4FAx9YBQEGAAkC0GoAQAEAAAADiQIBBgEgBQMGswUVAQUDFwUNBgEFAQN0SgUFAwxYBQtdBQMGSgUHA6d6AQUDFwUKBgFKSrpYWAUOA9YFAQUKA6p6SjwFAwYD1gUBBQUGAQYDCZAFA9oFAQaRWCAFBQYDbHQFFwYBBQUGAwryBQMDCdYFAQaRWCAGQAYBIAUDBsIFFQEFAxcFDQYBBQEDc0oFBQMNWAUIBpUFCgYBBQMGawUHA/x5AQUDFwUKBgFKSrpYWAUOA4EGAQUKA/95PDwFAwYDgQYBBQUGAQUIBsAFGAYaPAUKA3hYBS4AAgQBWAUaAAIEATwFBQZSBQcGAQaJBRkGAQUFBgMTWAUHCJcFHMcFBQEFHAEFEgYBBRk8BRxmBQUGAwueBQcGAQYDEEoFGwYBBSsAAgQBggACBAE8BQUGQAUDCBcFAQaRWCAFBwYDbmYFGAYBBQUGA7l/ggUXBgEFBQYIbwUXBgEFBQYDDwh0BtYFBwYDGS4FIQYBBTEAAgQBggUfAAIEAS4FCQACBAE8BRFsBQc8BQkGgwUXBgEFAQYDyAMIIAYBCJ4FAwY9EwUBBhAFFYQFC2AFDwN6ZgUHAAIEASwFAwY+BQ8GAQUgAAIEAQMXPAUPA2lKBRoAAgQBAxcIPAUPA2k8BQMGAxQCJwEFJAACBAEVAAIEAQYBBQkDKIIFEgNVSgUMAxkuBQkDEkoILgUgAAIEAQNYAQUkAAIEAQY8BSAAAgQBBgEFJAACBAFKBQUGUQUHBgEGA80GWAUcAAIEAQYDrHkBBQoD1AY8BR5ZPAUHBgO2eVgTExcWFQUKBgEFCQZaBTgGEwUJPAUWSQUJBoMFOAYBBU9mBQk8BlkFBxgFDgYVBRQ5BQcGPQUUBgEFBwaEBQ4BBlgFIAACBAEDWgEFDAMWPAUaA3c8OwUJBgMcPAUZBjwFE0oFCTxm5AUDBgO1BgEFBgYBBQUGWgU0BhMFBTwFEkkFBQaDBTQGAQVLPAUFPAUQXAUDBjwFAQYTngUNBgOwfwg8BTUAAgQBBgEFDwYIaAURBgEFF5QFDwYDCWYFEQYBBlwFFQYBBRM8BgMOggUtBgEFNjwFEQOyfXQFGQPAfFgFDQYD6gCsBRoGAQUJBnsFKwYXBQtFBRQGpQUWBgEFDwYDDZ4FKwYBBQ8GLwURBjwFFAZsBSsAAgQBBgN5AQUpAAIEAQNxCBIFDQYDIEoFDwYBBgMKkAa6BREDoAJYBRQDFlgFGQOqfGYFEwPXAzwFDgYDp3yQBpAFDQYDrQFYBToGA5d/AQUaA+kASgUNBnsFOgYDkH8BBQ8D8ABKBRQGowU6BgOLfwEFFgP1AHQFDwZuEwURBgEFFAajBRYGAQURBmoFQAYBBThKBQkGTwVYBgEFDUAFWEYFDQaGWWwFDwYBBSkAAgQBWAUPBgMLWAUcBgEFIC8FHHMFDwZnBQ0UBTYGAQUNTAU0jwU2gTwFNAACBAFKBQ0GSxNZBTYGD7oFHAACBAED8X0BBQkGAzyeBhMFFvEFCQaDBQ1aBQ8DpwUuBRIGAQURlAbiBR4GAQURBnUFGgEFKQEFEROtBS0GAQUcAAIEAVgFFAACBAIIZgUVBuUFKgYBBREGgwUOBgO5egEFKgPHBVgFGQO7ejwFDQYD8wSCBQ8GAQUNWQURA8x+yAUYA9cBWAUZA+l6PAUVA5IFPGYFDQYDGVgFDwYBBpEFEQYDlH4BBRwD7AFYBRkD1Hp0BQ0GA7UFggUPBgEGkQURBgOKfgEFHAP2AVgFGQPKenQFDQYD1wSCBQ8GAQURA+l+ngUVA9IBWAUZA+56ZgUNBgPdBYIFDwYBBQ0GAxCQBQ8GAQUUBuwFFwYXyAUTA/B6WAUNBgObAjwFHwYD2H0BBQ8DqAJ0BoYGATwFBgYDp3s8BQMXExYEAgUcA8ZyAQUFFRMUEwUiBhMFLjsFInUFLkkFIksFDXMFBQZLBQgGAQUFBj0FFwYBBRRmBR08BQ1KBQUGPRMFDQYRBAEFBQACBAEDsA2QBqUFBwYBBlkFFQYBBQUGXAQCBRwDoXEBBQUUExMTEwUIBgFYBQoGbgUHEwUbBhMEAQUJBgPsDvIFJAYBBQcGXQYBA84AAQUBky4FDQYD+AABBR4GSgUNBngFD1AFIQACBAEGAQUPS0oFIQACBAGPBQ8GZwUrBlcFEwMvkAUNBgPQATwFHwYDo34BBQ8D3QF0BoYAAgQBBgEAAgQBZgU6A4R+CEoFEwMongUMBgP+ATwFHwYD9X0BBQ4DiwJ0BQ8GhgACBAEGAQACBAFmAAIEAboFEwP+fS4FDQYDowE8BR8GA9B+AQUPA7ABdAaGAAIEAQYBAAIEAWYAAgQBugUNBgPCAy4FDwYBBpEFEQYD7H0BBRwDlAJYBRkDrHpKBQ0GA6IFggUPBgEGkQURBgOdfgEFHAPjAVgFGQPdenQFDQYDwAOCBREGAQUPWAUZA8B8ngUWA8wDPAUTaGYFDQYD1wBYBREGAQUPWAUZA9t7ngUWA7EEPAUTaGYFDQYDrXxYBR0GATwFDQACBAFYBR1KBQ0AAgQBPAZZA7UCWAUfBgPHfQEFLwO9AkoFHwPDfUoFDwO5AjwFEgakBRQGAQUSBqQFFAYBBRIGbAUUBgEFDwYDCp4FJgACBAEGAQUPBgM1dAUXBgEFEVgFDwamBREGAQUjAAIEAZ4FDwYDqQK6BQsWBhMFE4sFGEAFCwaDBQ+8BQ0DnX6QBREGA4R/AQUaA/wAWAUNBksTBRkGA8J7AQUTA70EPAUNZwYDvn5YBRoGAQUNBgO1fdYFOgYDEQEFHgNvSgUNBngFOgYDDQEFDQN0ZgUPSQYDDZAFKgACBAEGAQUPBj0GSgU61QUNBgMPkAUfBgMMAQU6A2V0BRIDEEoFD0kGAwyQAAIEAQYBAAIEAUoFH1gFDQYDxAGQBRoGAQUNBgMt1gUaBgEFDQYDpH/WBRoGAQUPBgPSANYAAgQBBgEAAgQB5AACBAGCBgNTWAACBAEGAQACBAHkAAIEAYIGA/cAWAUGA+B7AQUDFxMWBAIFHAPgcQEFBRUTFBMTBQ8GPS4FB2UFDT0FBy0FBQZ1BRMGAQUHPAUFBj0TBgEEAQACBAEDlQ4BBRngBQUGAwueBQcGSgUFBpUEAgUcA/1wAQUFFBMUExMFGQYBBQc9BRlzBQUGWRMUFAUHEwUaBgHIPIJmBAEFBwYDgA8BFwUrBgEFCawGCBQFKwYBBQ1KWAUJBj0FJAYBBQkGPQUkBgEuBQcGFQUJAxEBBSQGAQUHBmsXBSIGDboFDwYDwQMBAAIEAQYBAAIEAeQAAgQBggACBAFYBgPlfYIFIQYBBQYGA5pxdAUDAw8BBRUAAgQBBgEFAwbYBQ0GAQUFPAZLBR0GAWYFBQACBAFYAAIEAUoAAgQBngACBAFYBQ8GA94TAQURBgPffQEFHAOhAlgFDwZ1BRkGA556AQUPA+IFPAYD+35YBREGA+N+AQUgA50BWAUPBnUTBRkGA6F7AQUaA94EPAUVSwUTBgOnAawFIwYBBREDun08BRkDwHxYBSMDhgY8BQUGA/9rggUdBgEFBQACBAGCAAIEAUoAAgQBngACBAFYBQ8GA7EPAQU4BgEFNgACBAE8BQ8GA/QCkBMFKgACBAEGA7x/AQUWA8QAWAUPZQUTAwlKZgUPBgPDfFgFKwYBBQ8GA88CghMFKgACBAEGAyEBBRYDX1gFD2UFEwMJSmYFIwACBAEDGVgFEQa/EwUOBgORfAEFGAPuA1gFFWcDEkoDbmYFDwYDrX9YBScAAgQBBgEFBQYD33t0BQcIbQUVBgGeBQ8GA6wEAQU0AAIEAQYBBQ8GA80BggUiBgGCBSAAAgQBLgURAAIEATwDx36CBSIDuQFYBRkDh3tKBRgDlwU8PAUPBgOEfFgGdFgFCQYDhn5YBoKCBQcGA7B/ARMFCRgG8gUZA6gBAQUYA/0DPAUVaGYFDwYD/nxYBSsAAgQBBgEFDwYDowJ0BSgAAgQBBgEAAgQBPAUHBgP7e1gFCQYBBQoDEVguugURBgOYAgEFQAYBBThKBREGA7kDkAUTBgEGXQUgBgEFEwZ1BSIGAQURBgPxfoITBQ4GA4l8AQUYA/YDWAUVZwMKSgN2ZgUHBgOUe1gFEwYDdgEFBwMKZkq6WAUTBgOBBgEFEQYDtn4BBSQDygFYBRkD9np0BRgDlwU8BSIDYjwFEQPHfkpmBQcGA4t7WAUTBgN2AQUHAwo8SgUTA3Z0BQcDCmZYAgUAAQELAwAABQAIADgAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CWBYAAF8WAAACAR8CDwSVFgAAAZ0WAAABpRYAAAGwFgAAAQUBAAkCYHcAQAEAAAADJgEGAQUCBq0UEwU8EwUIBhEFPC8FBFYG2gUFBhEvBjsFPBEFAncFDAYBLgUCBlkFBQYBBQIGLwUDBhYFAUsGdwYBBQIGyRQFBwNqAQUCFBQTBTwTBQEGAw0BBTwDc2YFBGQFCFkFBAYxBQUGES8GOwU8EQUChQUMBgEuBQIGWQUQBgMNAQUFA3NKBQIGLwUOBgMMAQUDA3g8SgUCBhoFFAEFDAYBBQQAAgQBOwUUPQUDBpEFDgYRBQQ9BRQGSQUQBgEFDEoFFC4FAgZMBQUGAQUDBlkFCAYBBQIGPQUBBhM8ZgUIA2lmBQEGAyCCBgEFAgYTEwUQBgEFAVYFGz4FEDwFGS4FCkkFGUsFAgbJBQEGFwUCDVgFAQYACQJQeABAAQAAABoGAQUCBghLExQaBQoGGAUEA3ouBQIGQQUBBgNvAQUFAxFmBQIGkgUGBhMFBTsFAgZLBQUGEwUETAUNKwULPAUGSgUCBksTBQYGAQUCBj0FEwYBBQYuBRM8BQQ8BQIGsQUFBgEFEV0FBQNyPD4FCQMJPAUKOwUDBoQFBBQFCQYBBQg+BQw6BQdOBQ9GBQdKBQQGPQUKBgEFEj0FBi4FCjsFBAZLBQYGAQUEBmcFDwYBBQo9BQ9JBQtKBQQGPQUOAAIEAQMUAQUDWgUGBgE8BQIGmAUGBgEFBQACBAGsBQZOBQo6BQMGhgUEFAUIBhQFCSwFDDwFBAZLEwUHBhQFBkgFBAZnBQ8GAQUKPQUPOwULSgUEBj0FDgACBAEDFAEFA1oTBQwGAQUHPAUDBksFBgYBBQQDXWY8BQIGAymsBQkGAQUBPWZYBRUAAgQBA3qeBQUGZwUVOwZKBQQGWgYDWgEFCwMmPAUEA1pKBRUAAgQBA3nkBQUGgwUVOwZKBQQGWgULBgEFAgZOBQYGAWYFBQACBAFYAgoAAQHgEQAABQAIAEsAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8D/RYAAAQXAAA6FwAAAgEfAg8HWhcAAAFiFwAAAWoXAAABdRcAAAJ/FwAAAYcXAAACkBcAAAAFAQAJAtB5AEABAAAAA+sAAQYBBQIGAyQInhMTExMTExMaEwUBBgNMAQUJAzQ8BQEDTDwFEAM0AisBBQIGgwUOBgEuBQI8BQMGCNsFAgMKAQUGBgEFEAYD8n48BQIUExMUExMFCgEFBAYQWQUKLwUDBtcFBQYBBQMGLwUEBgEFCgY6BQJgBQYGAQUWWQUbSgUGSQUCBj0FCQYTBRtzBQU8BQIGS4MFAxMFEAYBBREAAgQBQAUFRgUISgURAAIEAQZOAAIEAQYBAAIEAZAAAgQBSgACBAGCBQIGuwUIBgEFAgafBQcGAQUDBmcFBgYBBQgGxwasBQIGXgUbBhMFCTsFAgY9BAIFAQOtAwEFAhQEAQUUBgPRfAEEAgUJA68DPJAEAQUZAAIEAQPRfAEFAgZaBgEGA+wAARMFDAYBBQoAAgQBrAUFAAIEAWYFAgaHBQUGAQUCBs8FDQYBBQm7BT0DGTwFCwACBAEDZkoFAgZZBQwGEwUJOwUMTDsFEUkFAgZLEwUMBhEFPQMYZgUMA2m6yAUCBgMXPAUFBhYFEIwFBVwFECoFFYIFBYYFKEYFCYcFBW8FAgZNFAUFBgEFAwZZBQsGAQUGCBIFAgZMBQUGEwUESQUCBlkFBQYBBQIGoBMFIAYBBQw8BSAuBQxKkDx0BQIGZwUMBhcFBFgFBWEFAwafBQYGAQUWdAUGPJ4FAgaiEwULBg8FBngFBXMFAwZPBQYGAVlzBQMGWQUCFAUDZxMTBQYGAUpIBQIDrX/yLgUDBgMKWAUKBgFLSmZzBQMGZwUBBgOxBAGeLgUKA897dAUDBgMMrIQFCgYBS/8FAwZnBQoGAQUBA6IEggUDBgPLewi6BQoGAUtKxwUDBmcFBAOVf8gFCwYBBQQGdRMGkAUDBgPzAAGfBQYGAQUJgwUGOwUDBj0GAQUKAy6CBQIGexMFBQYBBQZLBQVzBQMGXQUGBgFZcwUDBlkFAhQFBQYBBQMGlhMFBgYBO0tnOwUDBj0FAhQFBQYBBQIGvBMFBQYBBQcGlAUaBgEFCnQFAgYIIhMUBQQDEgIuAQUQBgFmBRQuBRA8BQdpBRRxBQQGPRMTBQcGAVgFBqkFAgZCBQsGAQUFWgULqgUCBkwFBQYBWDwFAwZZBQkGE4IFBlkFCTs8BQMGLwUGBgEFBAZnBQkGAVgFAgZdBRAGAQUFPAUQdAUFZgUDkgbABQYGAx8BBQUDYUoFAwZ1BQYGAQUDBoMTExMFBAMQARMFAwMJAQUGBgEFDwACBAFYBQMGCCgFFAYBBQZMBRQ6BQ5KBQMGyQUPBgFYyAUDBj0FBgYBBQMGAwrWBRwGFgUndAUhWAUcPAUGfgUXsAUHhEwFF0YFB04FBAZGBSUGAQUEBksFBRMTBRIGAQUQgzwFDi0FBQZLEwUIBgEFEAMJCCAFBQb+BQkGAQUIZgUFBq4FDgYTBRIDdEoFB0sFEAMKSgUFBksFBANyAQUFEwUHBgEFBQZLBRIGAQUQSzwFDjsFBQZLEwUIBgEFBQajBQwGAQUIggUMA84AZoIFBwZZBQoGAQUMjwURSgY8BkoFBl5KBjwGAQUNA48CLgULA+p9dAUGewUHBgO7foIFGgYBBQp0BQgDei4FCnoFFPpKBQQGCEoFCAYBBR5KBQY8BQQGPRMFAgMTAQULBgEFBVoFC4AFAgZMBQUGAVg8BQwDapADeXQFD3UFB54FFAACBAEDWgguBQ4AAgQBkAUDBrsFBAYBSgUDBgMfdAUNBhMFCJ08BQMGPQUCFhMUBQgGA3gCIgEFBAYDZtYFCwYTBQVzSgUCBgO2AVgFBQYBBQwD8H48BQUDkAF0BQwD6X6CBQ91BQeeBQ4AAgQBA5YByAUDBtgFBgYBdUlYBQMGWQUGBgEFBAYIPRMFBwYBBSEAAgQBZgURAAIEAYIFDQO2AtYFBgPJfTwFDDwFDQO3Ai4FAwYD4H50EwUFBgEFCFgFAwY9EwUIBg8FAgYDlwF0gwUFBgEFAwZbBQKFgwUJBhMFBTsFCUsFBUkFAgY9BQkGAQUCBi8FBQYBBQMGkQUIBgEFAgY9BQkGAQUCBmcFCQYBBQMGA/98WAUUBgEFDoIFAwbJBQ8GAVjIBQMGPQUEExMFDQYBBQQGgwUTBgEFB1gFBAagBRMGAQUHggUDBgMznhMTEwUMBhAFAgaJBQUGAQUCBgM6rBMTEwUFBgEFAwatBQoGEwUNOwUDBj0FFQYBBQ1YBQpKBQ0uBQo8BQY8BSQAAgQBggUpAAIEAWYFBAaSBQsGAQUaLwULOwUXLgUNPQUaZgUGLQUEBj0FGgYBBR4AAgQBPAUFA3i6BQYDGzwFBQNmPAUGAxpKBQUDZS4FBgMbPAUJPQUDBsYTEwUJBgFYBQIGCCIFBQYBBQMGuwUUBgEFBpE+BQUrBQMGPRMFBgYBBQMGPQUGBgEFAgY+BQUGAQUDBpEFBgYBBQQGkQUHBgEFCAMKkDwFBAZ0BQgGAQUGvAUCBpAFBgYBBQVZBQZJBQIGPQUFBgEFAgaVEwUFBgEFJQACBAIDEJ4FMwACBARmBQpoBTgAAgQEOgU9AAIEBEoFCkwFBAACBAQ6BQIGSxMGAQUFPAUHSwUDBsgFBwYBBQpZBQerBQIGPQUKBgEFBXQFB0sFAwZ0BQcGAVgFAgZ1BQUGAQUYAwk8BQUDd4IFAgYDCYIFBQYBBQMGCD0FBgYBBR0AAgQBdAUTAAIEAfIFEAACBALkBQ0DqAGCdAUMA658rAUEBgMNdAUHBgE8BQQGoBMFEQYRBQRnBQktBQQ9BQYDyACCBQw8BQQGA9UBLhMTBQ0GA6MBAQUEA91+PAUJSQUNA6QBdAUEA91+WAUFA6N/yEkFBkwFAgYD5ACCBQ0GA5sBATwFBQPlfmYDZKwFAwYDHUoFBgYBBQpLBQQGrAUKBgEFAwb4EwUGBjwFAwaWBgh0BQQGYIQFGQACBAIGDwUEBgMSWAUHBgEFDgACBAGQAAIEAUoFCDAFBAYDKMgFBgYDCwEFBwN1dEoFBAYDC54FCQYBBQQGWQUHBgEFBAa8BQgGAQUR9AUIqgUEBj0FBwYBBQUGkwULBgFZqwUFBj0FCwYBWAUPBgOqfzwFBgYDzgA8BQ8Dsn88BQMGPAUKBhMFCXMFBAY9BQoGAQUIXAUKYgUIAAIEATwFBAZABQgGAQUMWQUIcwUEBj0FDAYBWAUEBj0FGQYBPAUbAAIEAYIFBAa7BRsAAgQBBkkFBD0GWgUHBgEFJgACBAHWBSsAAgQCugUIkQUFBqwFCAYBBQUGvAUIBgEFBgaVBQsGEwUJcwUGBksFBRQFCgYBBQU9BQc7BQUGSwUCA+0AkIMFBQYBBQMGkQUGBgEFBAafBQgGA2yCSkoFBQYDYVgFEQYBWDwFBwOIf4IFAwaeBQcGAQUGAAIEAZAFBfMFCD0FBeMFBAZ0BQUGAQUEBj0FCAYBBQdZBQhzBQQGPQULBhdmBRBYBQc3BQIGhwUFBgEFCeEFAwYD+wDIBQkGA4V/AYKCBQQGA/8AggUIBgFmngUQBjgGPAUDBjwFEQYTBQllBQQGPQUGAAIEAQYBBRFKBQ8AAgQBWAUJAAIEAUoFBAZLBQcGAQUMA7B+ZgUCBgPXAVgFBQYBBQMGrQUWAAIEAQYBBQY8BREAAgQBkAUpAAIEApAFIQACBAI8BRIAAgQBAxiCBRYAAgQBBuYFDgACBAEBAAIEAQZ0BQMGA8B+CBIFBwYBBQWxBQdFBQIGQBMFBQYBBQxlBAIFAQYDYTwFAhQEAQUNAAIEAQYDLgEEAgUJA1KQZkoEAQUDBgMfngUGBgEFJQACBAGeAAIEAVgFEgACBAE8BQQGkhMTBQIDCwEFBgYDcwFLngUIBgNOdAULBgEFBAagBQYGAQUHPQUGOwUEBj0FBwYBBQUGgwUIBgEFBAZsBQcGAQUFBoMFCAYBBQd1BQhzBQUGPQUMBgOYflgFBAYD+gC6BQ8GAUoFBAACBAEDoX9YBQoD4ABKBQ87BQQGSwUKBgEFHnQFCoIFEwaeBR4GAQUEBkoFEQYBBQhLBRE7BQUGSwUNBgEFCEoFBgZLBRMGAQUPSgUTPAUPSgUFBksFBwYBBRBKBQo8BQUGPQULBgEFCEoFBgbXEwUYBgEFCfIFCwagBR0GAQUOSgUDBgMMnhMTEwUCFwUFBgEFDgACBAGsBQMGygUGBgHWBQMGSxgFCAYTBQYDCYIFCQN2SgUEBnUFEQYBBQYDCUoFEQN3SgUGSgUEBksFEQYBBQ+KBQ0DqAJYPAURA9B9PAUNA7ACSgPQfTwFBAZSEwUHBgGeBR0DdWYFBwMLggUSBgN1rAUdBgEFAwZKBQQTBRAGEQUGAwo8BRADdkoFET0FBoIFBAZLBREGAQUPigURA3hmBQ1KBQQGUhMFBwYBBQQGvAUKBgEFBzwFBQZ1BQgGAQUGBq0FCQYBBQvKBQYDeXRKWIIFBAYDkAKeBQcGAQUOBo8FCQZ0BQ5mBQMGUAYBBQgDeTwFA3sFAgMQgkpKBQUGA5N+WAUNBgEFCFk9BQ06BQsyBQZCBQgDdjwFBQY9EwUEFAUFBgNrAQULAxU8BQZCBQUDZS4FBgMbPDwFAwYDH1gFBgYBBSUAAgQBngUSAAIEAVgFJQACBAE8BRIAAgQBPAUEBoQTEwUCAwsBBQYGA3MBS54FBQYDrQGsEwUKBgEFDQMWSgUIA2ZKBQp4BQUGPQULBgO7flg8BQUGngULBgEFCpEFC2UFBQY9BQoGAQUFBlkFCgY7BQVLBlkFBBQFBwYBgggSWAUGA61/SkoDhQJYBQIG8gUGBgFZcwUCBj0FBgYBBQIGXAUFBgEFDAACBAG6BRcAAgQCLgUDBgMP1gUGBgEFCUsFBnMFGQACBAFmBQgDoX/IBQUGCCAFCAYBBQ4AAgQBkAUGBp8FCQYBBQcGAiMXBQwGAQUHBlkFDgYBBQmrBQ49BQxaBQs+BQyABQtMBQ44BQcGPRQTBQsGAQUNWQULSAUNPgULOwUHBj0FDQYBBQsAAgQBWAUYBgN5SgUNBgEFCXUFDUkFGAACBAFYBQkDCUoFBgasBQkGAQULygUNcnQFBQYDFDwFCgYBBQUGPQUgAAIEAgYDxn1YBQQGgwUHBgFmBQQGhBMTBQ0GAQUUhQUFfgUUagUNRwUEBlkFAxQFDgYBBQMGyQUPBgFYyAUDBj0FCQYDeQEFCgPxAXQFBAZ0BQoGAQUEWQUKgQUEBj0GSgbJBQoGAQgSggUGA5V+rAUMPAUIA7ICdAUFBqwFCAYBBQUGwBMFEAYBBQVLBQo6BQV2BRA7BQUGPQZYnko8BQkDrX5YBQgGSgUJBgEFCAZLEwUFA7YBngUIBgEFCksFBgYIPAUKBgEFC1kFCnMFBgY9BQsGAQUGBlwFCQYBBQYIPgULoAUMcgUFBk4FCAYBngULPZ4FDwP9fJAFB54FBQOhAroFCWoFBQYDjn/WBQ4GAQUFBk4FDAYXBQhFBRcAAgQBngUCTQUXAAIEAX8FKgACBAJKBQsDDoIFGQACBAEG2AURAAIEAQEAAgQBBjwAAgQBSgUNA4oCZkoFBgYDmX26BQkGAWaQBQdIBQlMA9QAurpKBQgDQFgFBQMYkAM7dAUGSwUFLEpYBQsDFTwFBjQFCwN6PAUGQgUFA2UuBQYDGzw8BQUGAzlYBQsGAQUF9gULcAUCBkAFBQYBkAUJcQUHBgPeftYFCgYBZlhKBQwDOQhKBQQGAyEIEgUGBgEFBz0FBjsFBAY9BQcGAQUFBoMFCAYBBQUDcS4FBgMbPAULA3o8BQgDejwFBAZCBQUGA2sBBQsDFTxYBR0AAgQCA/4AWAUFBgMTrAUIBgGsdAUGBgPFflgTBQIGEAULhAUUAAIEAQPGAVgAAgQBkAULS/JKBQYGbgULBgEFCIIFBgY9EwUSAAIEAQYDb1gFHgACBAIuBQuiup4FFAACBAEwBQYGA1HkBQkGAQUMSwUJcwUVAAIEAWYCFAABAdQBAAAFAAgAOAAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwLgFwAA5xcAAAIBHwIPBB0YAAABJRgAAAEtGAAAATgYAAABBQEACQLwjwBAAQAAAAMiAQYBBQIGuxMUEwULBhMFBEkFATcFBEEFAgZLBQUGAQUCBgMRWAUOBgEFAwaDBQsGAQUBgwUJA2sIEgUDBk0FBQYTBQY7BQMGWQUFBgEFAwZZBQYGATwFBAYvBQYGEztZBQouBQZJBQQGLwUGBgEFBAY9BQwBBQkGA3iQBQUGAwlmBRYGAQUIWAULSwUWSQUHLwUQLQUFBmcFBwYBSgUMBjoFBMwFDQYBBQc8BQUGWQUHBgFKBQwGkwUJBgNwAQUMAxA8BQUGyQULBgEFDAYfBQLLBRMGATwFDkoFBUoFAYQFBAYDd+QFDQYBBQdKBQkDdJAFAQYDGKwGAQUCBhMTFAUMBhMFBEkFAgZLBQUGAQUCBksFFAACBAEBBQgGAQUUAAIEAS4FAwafBR0AAgQEBhEFBUsFHQACBAQGOwUUAAIEAQEAAgQDBlgFAgaEBQUGAQUDBlkTBAIFAQOfAwEFAhQFDAYBBQIGSxMGAQQBBQUAAgQBA918AQUCBjAFAQYTAgMAAQG3DQAABQAIAHIAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8EhBgAAIsYAADBGAAA6hgAAAIBHwIPDgoZAAABERkAAAEYGQAAAiYZAAABMRkAAAM7GQAAA0cZAAADURkAAANZGQAAA2YZAAABbhkAAAN3GQAAA4IZAAADixkAAAAFAQAJAkCRAEABAAAAA8gAAQYBBQIGyQUIBgEFAWUFBS8FBwaUBQoGAQULBgMNSgUD1wULcwUCsAUFBgEFAZJmBQMGA250BAIFCgPjDAEFBRMFDAYBrAQBBQMGA51zAQUGBgEFEgACBAEGTAUFEwYIEgUeAAIEAwYtBRIAAgQBAQUFEwUeAAIEA2UFEgACBAEBBQQUuwYBBREVBQsGoQUCFgUDA2wBBRkGAQUBAxa6ZgUDA2ouBQgGAwzWBQsGdAZcBmYIWAUBBgNk8gUCrQQCBQoD8gwBBQUTBQwGAawEAQUCBgOOcwEFBQYBBQFdBQ0GA3jIBREAAgQBFwUEEwUcAAIEA/EFEQACBAEBBQQTBQEGoAUEZAUBBgM3ggYBBQIGuxMUFQUBBgN5AQUCNS4GWwUFBgEFFwACBAFYBRAAAgQB1gUDBlkFDwYBBQUDXzwFDwMhdAUCBgMbSgUNA0IBBQIUBQUGAS4FAwZLBsieBgMjAQUFBgEFAwaWFAUdBhAFQFgFBIMGAwlmBRIGAQUEBpEFBwYBBQMGXAUFBgNHAQUJAzl0BQMGPQUOBgEFAgY+BQ0DQgEFAhQFBQYBLgUCBgM9AQULBgEFAgaDBQEGE1gFAwYDZZ4FBQYBBR4DCXQFBQN3dAUDBjQFHQYBPAVALgUehQUEcgUDBksFHgYTPAUsdAUHPAUEBpITBQ4GAQUBBgMSCJAGAQUCBq0FAQYRBQU9BQMGWQUGBgEFBAZnBQEGGgUEA3hmBpIGLgZZBRYGAQUFA7h/rAUMA8gAdAUTSwUMSQUEBj0TBQ0DtH8BBQIUBQUGAS4FAQPNAAFYBQYGA3RYBQMDQAEFAQYDzAB0WAUDA7R/IHQFAQYACQLwkwBAAQAAAAP/AAEGAQUCBuUUExkUBQYGAQUCBj0FAQYDcgEFAgYDDzwTBQgGAQUMPzwFAgZWBQMUBQcGAQUKSgUFSgUDBj0FCAYTBQlJBQ4AAgQBAw88BQkDcUoFAwZLBQ4AAgQBAw4BAAIEAQYBBQIGSwUFBjwFAwZZBQYGAQUDBmAFDwYBBQs8BQo9BQ87BQMGSwULBhEFAUCCICAFBAYDdawFCQYBPIIFBAY9BQcGAQUEBloGggYIEwUGBj0FBDsGWQUDFAUPBgEFCzwFCj0FDzsFAwZLBQsGEQUBBgMougYBBQIGrRQFCQO9fgEFAhQTFBUFAQYDuAEBBQIDyH4uLgZbBRcAAgQBBgEFEAACBAF0BQMGWQUPBgEFBQNfPAUPAyF0BQIGAxt0BQ0DQgEFAhQFBQYBLgUCBgM9ARMGAQYDmwEBFAULBgPifgEFCgOeAXQFAgY9BQsGA+F+AQUCBgOgAUoFAQYTWAUDBgPGfp4YFAUeBhN0BSwIEgUHSgUEBpcFEgYBBQQGnwUHBgEFAwZcEwUJBhEFBQNHdAUJAzl0BQIGTQUNA0IBBQIUBQUGAS4FAwZLBsh0BQQGAy4BEwUOBgEFAQYDsQHyBgEFAgYISxMTExQaBQcGAQUQSgUBA3JKBQUDDmYFAgYIQQUEBgEFAgZLExMFBQYBBQIGWQUFBgEFAwZnBQQGATwFAgZLBQYGAVgFAgY9BQUGAQUCBpIFCAYBBRdKBR8AAgQBPAUTSgUfAAIEAQZKBQYGWboIdAUCBksFBQYUSAUCBksFBgYUSAUCBksTExQFCwACBAEBBRUCNhIFCwACBAFKBQNZBQsGAQUQPAUGSgUHWgUGOwUKPgUEBlkFBRMFCQYBBRwuBQs8BQhMBQ5IBQdKBQUGZwULBgE9OwUFBksFDgACBAETBQRZBQgGAQUVA3ZKBQgDCkoFFQYDdlgFCwACBAEBBSgAAgQBAzxYBTMAAgQEggUoAAIEAQEAAgQBBjwAAgQDLgACBAN0BQIGSwUJBgEFAgY9BQEGE4IuBggzBgEFAgblExMUBQUGAQUBKQUFXTwFAgZsBQUGAQUKPQUFOwUCBjAFCgYBBQV0BQEDc5AFAwYDJ5AFBgYBLgUDBjAFDAYBBQY8BQEDV1gFAgYDHzwFAxMFBgYBBQQGWQUJBgEFBAbXBQcGAQUEBpIFBgY9BQQ7BlkFAxQFBgYBLgUBAxYuggUEBgNu1p8FDgYBBQc8BQQGXgUNA4N9AQUCFAUFBgEFAwaRBghKBQUGA/UCAQUWBgEFFAACBAGsBQUGPQUWBhEFCD0FBQZaBQ8GAQUDBgNXngUXBgEFBzx0WIIFAwY9BQYGAQUK1wUDBomfBQwGAQUGdAUDBl4FDQOefQEFAhQFBQYBBQMGyQYIIAUEBgPaAgEFCQP5fgEFAhQUBQYGAQUCBskFBQYBBQIGWhMFCQYBngUNAAIEAQP/AAEFCQOBf3QFAgZLBgEFBAYD/wABFAUNBgEAAgQBjQUEBq0FAQMt8gYBBQIGCEsTExQFAQYNBQRBBQUvBQEDejwFCUMFBEgFAgY9EwUIBhMFCUkFBS4FAgZLBRgAAgQBAQUD5QUfAAIEAwYRBQUvBR8AAgQDBjsFGAACBAEBBQJaBQcGAVgFAgY9BQUGAQUCBpIFBQYBBQIGSwUPAAIEAQEFCQZLSqwFAgZZBQwGEwUESQUCBksFBQYBBQIGSwUFBgFKBQMGaAUGBgEFBZEFBi0FAwY9WQUEEwUPBgEFB1gFCksFD0kFBi8FFDsFBAZnBQYGATwFDQACBAEGLwUDWQUMBgEFBgIpEgUFRQUCBgMVPAUKBgEFAgZLgwUBBhPWLi4FBwYDeoIFAxMFCQYBBQsAAgQBBiEFB1YFAxMFCQYBBQsAAgQBBiEFAQgZBgEFAgYTExQTBQQGAQUCBlEFBQYBdAUCBjAFCwYTBQaBBQIGSwUFBgEFAgZLEwUFBgFYBQMGagUGBgEFAgZVBQMTBQYGAUpKBQQGgwUaAAIEAQYBAAIEATwFAU8GvQYBBQIGCC8TExQaBQUDVgEFAhQTFBMFBAYBBQIGUQYBBQEDEAEFBQNwZgUCBpIFCwYTBQaBBQIGSwUFBgEFAgZLEwUFBgFYBQMGXAUGBgEFAgaNBQMTBQYGAUpKBQQGZwUFBgMiAQUaA15YLgUFAx4BQwN5LjwFAgZEBQYGAQUCBq0FBQYBBQIGkgUKBgEFAgY9BQUGAUtPBQmRBQUDeS4FAgY9EwUGBgEFAgZZExMFCwYBBQZKBQIGWRNMBQMTBRcGAQUHPAUFPAUDBmcFCQYTBQ5JBQ0AAgQBPgUJSQUOLQUNAAIEAUwFCkgFAwY9BQ0AAgQBEwACBAEG1gACBAF0AAIEATwAAgQBCJAFCwZLBjwFAwYILwUHBgEFCi4FBkwFBUgFAwY9BQ4GAQUJPQUOVwUKSgUDBj0FCw8GkDwFCAYDIoIFA4MFCAYRBQV1BQgGSQYBBQIGTAUJBgEFAgZLBQEGEwUCBgO4fwhKGgUFBhZUBQIGA3gILgUDEwUHBgEFAwafBQYGAQUDBloTBQoGEQUDBoQFCgYBkAUBBgPFAAjkBgEFAgaDExMWBQ4GEwUGSQUCBksFBQYBBQIGSwUEBgEFAgaGBAMFAQPQfgEFAhQFCQYBSgQBBQoDrwEuBAMFCQPRflg8BAEFAgYDrwEBBQoGAQUCBpIFBQYBBQIGXgUIBhMFFzsAAgQBWAUCBksFBQYBBQMGSwUiBgEFEi4FGzwFIi4FEjwFG0oFCloFFywFCjAFFwACBAEqBQZMBQMGkQUYBgEFE1lKPAUPPAUDBjwFAgMXAQUJBgEFAT+CBQIGA2NYBRcAAgQCBhEFBS8FAwZeBQYGAQUDBrsFAgMTAQUJBgEFAT8FAwYDXZ4FHAYBBRJYBRxmBRIuBQYuBQMGkQUYBgEFIlkFAwZ0BRkGAQUKPDwFHi4FAwY9BQIDHQEFCQYBBQE/ggUDBgNkZgUSBgEFBlgFEi4FBi4FAwaRBQIDGAEFCQYBBQE/dCAGPwYBBQIG8xMUFBMVFQUGBgEFAQNzWAUGAw2eWAUCBkAFBQYBBQIGkhQGWAUJdAUWQgUJA3o8BQIGdRcFBQYT8gUCBk0FBQYPPwUDBksEAwUBA/59AQUCFAUMBgEFAgaDBQoGATwFAgYvBgEEAQUGAAIEAQP+AQEFBAZZBRgGAQURWAUYPAURPAUGPQUNOwUEBj0FBgYBPAUDBkEFJAACBAEGFAUXugUPAAIEBEoFAgYDOTwFBQYBBQMGXwUSBhQFHjoEAwUJA799dAQBBQ0DwwJYBR46BQMGPgQDBQEDu30BBQIUBQkGATwEAQUQAAIEAQPDAgEFAQMJSkqCIAUDBgO4f3QEAwUBA/J9AQUCFAUMBgEuBAEFBQOPAgEEAwUMA/F9WAUCBlkTBgEEAQUDBgOLAgEFDwACBAQGDgQDBQoD+H08PAQBBQUDkQIBBAMFCgPvfUoEAQUDBgOOAkoVBQIDMAEFBQYBBQMGWgUaBgGCBQMGLwUNBgEFAQMPnkqCIAYDDoIGAQUCBhMFAQYRBQgGPQUQBgEFDkoFDDwFCC4FAwZLBQ4GEQUEPQUIBkkFEAYBBQxKBQguBQIGTAUBBhMCAQABAX0AAAAFAAgANwAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwPcGQAA4xkAABgaAAACAR8CDwM4GgAAAUIaAAABTBoAAAIFAQAJAiCeAEABAAAAFgYBBQMGExMFJQEFCgYBBQ87BSU9BQUGnwUlSQUXBgEFJWYAAgQBWAUBWzwCAQABAZQAAAAFAAgANwAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwOcGgAAoxoAANgaAAACAR8CDwP4GgAAAQIbAAABDBsAAAIFAQAJAlCeAEABAAAAFwYBBQMGExQFEwACBAEBBQoGEAUBOwUTAAIEAT8FIgACBAMGngUgAAIEAwYBBRMAAgQBBkoAAgQCBlgFAwavBQEGEwIBAAEBWgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAl8bAABmGwAAAgEfAg8CmxsAAAGoGwAAAQUBAAkCgJ4AQAEAAAADDAEFBRMFDAYBAAIEAXQFAT0CAQABAVoAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwIAHAAABxwAAAIBHwIPAjwcAAABSxwAAAEFAQAJApCeAEABAAAAAwwBBQUTBQwGAQACBAF0BQE9AgEAAQFOAQAABQAIAGMAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8EpBwAAKscAADhHAAAAR0AAAIBHwIPCzkdAAABRh0AAAFTHQAAAlsdAAACZx0AAAJxHQAAAnkdAAAChh0AAAKTHQAAApwdAAADpx0AAAIFAQAJAqCeAEABAAAAAyQBBgEFBQaxBQEGDQURQS4FCAACBAFYBS8AAgQBWAUlAAIEAZ4FCQYDD1gFHwYBBQFLWAUJHwUOBgNryAUJAwsBBSsGAQUpAAIEAZ4FCQACBAHyBoQFEwYBdAUBAwkBWAYDFS4GAQUFBrEFAQYNBRFBLgUIAAIEAVgFLwACBAFYBSUAAgQBngUJBgMPWAUfBgEFAUtYBQkfBQ4GA2vIBQkDDAEFEwYBBQkGdQUtBgEFKwACBAF0AAIEATwFCQACBAGeBQEDCTwFCQACBAEDd2YCBQABAZ8AAAAFAAgAVAAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwQKHgAAER4AAEYeAABvHgAAAgEfAg8Ijx4AAAGrHgAAAcceAAAC1R4AAAPfHgAAA+geAAAD8B4AAAP9HgAAAwUBAAkCgJ8AQAEAAAADDwEFBRMFAQYTBgN28gYBBQUGEwUBBhEEAgUHBgPLDTwFBRMFDAYBdAQBBQEDtnIBAgEAAQFzAAAABQAIADcAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DUx8AAFofAACQHwAAAgEfAg8DsB8AAAHAHwAAAdAfAAACBQEACQKgnwBAAQAAAAMJAQYBBQUGrQUBBhEFDi8FGgACBAFYBQwAAgQBngUBPVgCAgABARsCAAAFAAgAVQAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwMeIAAAJSAAAFogAAACAR8CDwl6IAAAAYQgAAABjiAAAAKYIAAAAqAgAAACrCAAAAK0IAAAAr0gAAABzCAAAAIFAQAJAtCfAEABAAAAAxMBBgEFAwaDBQEGEQUGnwUHBloFCgYBBQcGeQUOBgEFBwYvBQ4GAQUBAxBYBQcGA3SsBRIGFEqQZgULcgUHBnYFEgYBBQcGCD8FCgYBBRUAAgQBSgUEBnYFCgACBAEGWAUEBmcFCwYBBQFcBvYGAQUDBskTBR0AAgQBBgEFAToFHQACBAE+BQFIBR0AAgQBMAUDBksFCwYTWAUSLQACBAFYkAACBAE8BQoAAgQCWAUBMFggBtoGAQUDBghLExMFDAYXBQEDeDwFG5NYBQMGLwUfBgEFElkFH0kFAwYvFAUTAAIEAQYBBQMGWwUGBgEFEAZaBQQIMgUGBgEFCC8FBjsFBAY9EwUHBgEFBAaxBQcGAQUQBgN1SgUEWgUPBgEFBwACBAEILgUNSwUBAxt0giA8LkpKSgUEBgN4ugUGBgEFGT0FFDwFBi0FBAY9BQcGAQUEBnYFBwYBBQ0GA3lKBQcREwUEFAUPBgEFBwACBAEILgACBAFKAAIEATwGA3kBBQwGAQUDBgMQSgUKBgEFCAYDa7oFDQYBBQgGgwUTBgFKBQYGAw9KBRAGAUoCAgABARwDAAAFAAgAWgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwMhIQAAKCEAAF0hAAACAR8CDwp9IQAAAYchAAABkSEAAAKbIQAAAqMhAAACryEAAAK3IQAAAsAhAAACzyEAAALYIQAAAQUBAAkCwKEAQAEAAAADEgEGAQUDBrsYBQEGA3kBBQZtBQMGkwUGBgEFAwaWBRUGAQUIPwUHOgUTcwUDBj0UBQYGAQUDBogFBgYBBQcGaAUKBgEFEAMOujwFDAZKBRAGAQUPAAIEAWYFBAZOBQcGAQUJBggmBQ0GAQUIA2wIWAUHAAIEAdYFC4oFAQMjWFggBQMGA3WCBQYGAQUHBnUFDgYBBQoDCWYFAVlYIAUHBgNLggUMBgEFBwZZBQwGA3IBBQEDwgAuWCAFBAYDVDwFGAYBBQQGPQUIBgFmSgYDIwguBQwGAQULAAIEAQIkEgUIBgN1SgUOAAIEAQZYBQgGZwUPBgNtAQUIBgMKdAUYBgEFCAZnBQwGA10BBQEGA8IA8gYBBQMGCBMTBQwGAQUBLAUcAAIEAT8FDDsFAwZLBRwAAgQBBgEFAUcFHAACBAE/BQMGTAUBBg0FHGxYBRM7AAIEAlgAAgQEPAUKAAIEAQIiEgUBMFggIC4GXgYBBQMGCEsTExMFJAACBAIGAQUBcAUkAAIEAkAFATgFJAACBAJqBQMGSwUBBg0FG0FYBQMGPQUfBgFYBQMGPgUGBgEFFgACBAGQBRMAAgQBPAUDBpMFBgYBBQcGWwUKBgN0AQUHAww8BQQGvgUJBhMFBFcGSwUGBhMFCTsFBAZnBQcDegEFEQACBAEGWAUHAAIEAQieBgMJSgUKBgEFAgaRBQcGAQUBAwt0giA8LgUHBgN5ugUPBgEFFS88SgUKA2UBBQ8DGjwFBwZLBQ0GAQUCBoUFBAYBBTErBQQ/BQUGOwUVBhAFBQigyAUMA2oBPAUBBgMfyAYBBQMG5RMFCwYBBQEsBQuSBQMGSwUhBhNYBQo7AAIEAlgAAgQEPAACBAKCAAIEBHQAAgQCggACBARKAAIEAawFATBmIAIEAAEBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAFAAAAAAAAAAAEABAAQAAAAEAAAAAAAAANAAAAAAAAAAQEABAAQAAACYBAAAAAAAAQQ4QhgJDDQYCnwrGDAcIRQsCWwrGDAcIRQsAAAAAAAAkAAAAAAAAAEARAEABAAAATgAAAAAAAABBDhCGAkMNBgJJxgwHCAAAZAAAAAAAAACQEQBAAQAAAFACAAAAAAAAQQ4QhgJCDhiNA0IOIIwEQQ4ohQVBDjCEBkEOOIMHRA5gRQwGQAOIAQrDQcRBxULMQs1BxgwHCEgLAmgKw0HEQcVCzELNQcYMBwhJCwAAAAAkAAAAAAAAAOATAEABAAAAIgAAAAAAAABBDhCGAkMNBl3GDAcIAAAAJAAAAAAAAAAQFABAAQAAACIAAAAAAAAAQQ4QhgJDDQZdxgwHCAAAACQAAAAAAAAAQBQAQAEAAAAZAAAAAAAAAEEOEIYCQw0GVMYMBwgAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAkAAAAcAEAANAZAEABAAAAQwAAAAAAAABBDhCGAkMNBn7GDAcIAAAAPAAAAHABAAAgGgBAAQAAAHoAAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5ARQwGIAJDCsNBxEHGEgcBTwsAAAAAABQAAABwAQAAoBoAQAEAAAAfAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAACwAAAAIAgAAwBoAQAEAAAAwAAAAAAAAAEEOEIYCQw0GVwrGDAcIRQtPxgwHCAAAAEwAAAAIAgAA8BoAQAEAAACCAAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOQEUMBiBmCsNBxEHGEgcBRAt1CsNBxEHGEgcBQQtPw0HEQcYSBwEAFAAAAAgCAACAGwBAAQAAAAMAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAARAAAALgCAACQGwBAAQAAAPgAAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA6QAUUMBlBNlwqYCJkGAoAK2djXQcNBxEHGEgcLRAsAFAAAAP////8BAAF4IAwHCKABAAAAAAAAFAAAABgDAACQHABAAQAAAAMAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAFAAAAEgDAACgHABAAQAAAAMAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAALAAAAHgDAACwHABAAQAAAGkAAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5QRQwGIAAARAAAAHgDAAAgHQBAAQAAAGIBAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDoABRQwGMALLCsNBxEHFQcYSBwdFCwAAAAAAXAAAAHgDAACQHgBAAQAAAF0DAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUQOkAFFDAZQUQrDQcRBxULMQs1CzkLPQcYSBwFHCwAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAJAAAAGgEAADwIQBAAQAAADoAAAAAAAAAQQ4QhgJDDQZ1xgwHCAAAABQAAABoBAAAMCIAQAEAAAAMAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAADwAAADABAAAQCIAQAEAAAC9AQAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgAoAKw0HGEgcDRAsCZwrDQcYSBwNICwAUAAAA/////wEAAXggDAcIoAEAAAAAAABMAAAAGAUAAAAkAEABAAAAewAAAAAAAABBDhCGAkIOGI0DQg4gjARBDiiFBUEOMIQGQQ44gwdEDmBFDAZAAlzDQcRBxULMQs1BxgwHCAAAAEQAAAAYBQAAgCQAQAEAAAB/AAAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5QRQwGMFYKw0HEQcVBxhIHAUoLAAAAAAAAAEQAAAAYBQAAACUAQAEAAACZAAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOQEUMBiBTCsNBxEHGEgcBRwsCWwrDQcRBxhIHAUsLADwAAAAYBQAAoCUAQAEAAADyAAAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgcQrDQcYSBwNDCwKPCsNBxhIHA0gLAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAUAAAAUAYAAKAmAEABAAAALAAAAAAAAAAUAAAAUAYAANAmAEABAAAAUAAAAAAAAABMAAAAUAYAACAnAEABAAAApgAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjACgQrDQcRBxUHGEgcBRwtKw0HEQcVBxhIHAQAAABQAAABQBgAA0CcAQAEAAACAAAAAAAAAABQAAABQBgAAUCgAQAEAAAA3AAAAAAAAABQAAABQBgAAkCgAQAEAAABzAAAAAAAAABQAAABQBgAAECkAQAEAAAA2AAAAAAAAABQAAABQBgAAUCkAQAEAAACJAAAAAAAAABQAAABQBgAA4CkAQAEAAAC+AAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAADwAAAB4BwAA4CoAQAEAAABIAAAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5gRQwGMHfDQcRBxUHGEgcDAAAUAAAA/////wEAAXggDAcIoAEAAAAAAABEAAAA0AcAADArAEABAAAAbQAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDlBFDAYgdgrDQcRBxhIHA0QLYsNBxEHGEgcDAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAsAAAAMAgAAKArAEABAAAA7AAAAAAAAABBDhCGAkMNBgKICsYMBwhECwAAAAAAAAA8AAAAMAgAAJAsAEABAAAAWAAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIHAKw0HGEgcDRAtWw0HGEgcDAAAAAAAAXAAAADAIAADwLABAAQAAAJ4BAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUQOoAFFDAZQAxoBCsNBxEHFQsxCzULOQs9BxhIHA0ELRAAAADAIAACQLgBAAQAAAEQBAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDlBFDAYwAtQKw0HEQcVBxhIHAUQLAAAAAAAAPAAAADAIAADgLwBAAQAAAE8AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5ARQwGIHEKw0HEQcYSBwFJCwAAAAAAACwAAAAwCAAAMDAAQAEAAACRAAAAAAAAAEEOEIYCQw0GAmsKxgwHCEELAAAAAAAAAFwAAAAwCAAA0DAAQAEAAAAZBQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDoABRQwGUAPOAgrDQcRBxULMQs1CzkLPQcYMBwhCC1wAAAAwCAAA8DUAQAEAAACpAwAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDnBFDAZQAzgCCsNBxEHFQsxCzULOQs9BxgwHGEgLAFwAAAAwCAAAoDkAQAEAAABOAQAAAAAAAEEOEIYCQg4YjANBDiCFBEEOKIQFQQ4wgwZEDmBFDAYwArMKw0HEQcVCzEHGEgcBSQtSCsNBxEHFQsxBxhIHAUkLAAAAAAAAAFwAAAAwCAAA8DoAQAEAAADWAwAAAAAAAEEOEIYCQg4YjANBDiCFBEEOKIQFQQ4wgwZEDlBFDAYwA1UBCsNBxEHFQsxBxgwHCEcLAoUKw0HEQcVCzEHGDAcIRgsAAAAAADwAAAAwCAAA0D4AQAEAAADXAAAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5QRQwGMALCw0HEQcVBxhIHAQBEAAAAMAgAALA/AEABAAAAnwAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDnBFDAYgAlwKw0HEQcYSBwdGC2zDQcRBxhIHBwAAAAA0AAAAMAgAAFBAAEABAAAA3wAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDnBFDAYgAtDDQcRBxhIHB0QAAAAwCAAAMEEAQAEAAABYAQAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA6AAUUMBjAC1ArDQcRBxUHGEgcHRAsAAAAAAFwAAAAwCAAAkEIAQAEAAACzBAAAAAAAAEEOEIYCQg4YjgNCDiCNBEIOKIwFQQ4whQZBDjiEB0EOQIMIRA6QAUUMBkADpgMKw0HEQcVCzELNQs5BxhIHA04LAAAAAAAAAFwAAAAwCAAAUEcAQAEAAAALCgAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlHDoACSAwGUANyAQrDQcRBxULMQs1CzkLPQcYSBw9ICxQAAAD/////AQABeCAMBwigAQAAAAAAADwAAAAYDQAAYFEAQAEAAABbAAAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgcgrDQcYSBwNCC1nDQcYSBwMAAAAAAABkAAAAGA0AAMBRAEABAAAAfgEAAAAAAABBDhCGAkIOGI0DQg4gjARBDiiFBUEOMIQGQQ44gwdEDqABRQwGQALuCsNBxEHFQsxCzUHGEgcHSgsCRArDQcRBxULMQs1BxhIHB0ELAAAAACwAAAAYDQAAQFMAQAEAAACRAAAAAAAAAEEOEIYCQw0GAmsKxgwHCEELAAAAAAAAADwAAAAYDQAA4FMAQAEAAAB2AAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOUEUMBiBfCsNBxEHGEgcDSwsAAAAAAAA8AAAAGA0AAGBUAEABAAAATwAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDkBFDAYgcQrDQcRBxhIHAUkLAAAAAAAALAAAABgNAACwVABAAQAAAOwAAAAAAAAAQQ4QhgJDDQYCiArGDAcIRAsAAAAAAAAATAAAABgNAACgVQBAAQAAAM0BAAAAAAAAQQ4QhgJCDhiMA0EOIIUEQQ4ohAVBDjCDBkQOYEUMBjADdQEKw0HEQcVCzEHGEgcBRwsAAAAAAABcAAAAGA0AAHBXAEABAAAA1gMAAAAAAABBDhCGAkIOGIwDQQ4ghQRBDiiEBUEOMIMGRA5QRQwGMANVAQrDQcRBxULMQcYMBwhHCwKFCsNBxEHFQsxBxgwHCEYLAAAAAAA0AAAAGA0AAFBbAEABAAAA5wAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDnBFDAYgAtjDQcRBxhIHB1wAAAAYDQAAQFwAQAEAAAApBQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDoABRQwGUAPdAgrDQcRBxULMQs1CzkLPQcYMBwhDC1wAAAAYDQAAcGEAQAEAAAC5AwAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDnBFDAZQA0gCCsNBxEHFQsxCzULOQs9BxgwHGEgLAFwAAAAYDQAAMGUAQAEAAACzBAAAAAAAAEEOEIYCQg4YjgNCDiCNBEIOKIwFQQ4whQZBDjiEB0EOQIMIRA6QAUUMBkADpgMKw0HEQcVCzELNQs5BxhIHA04LAAAAAAAAADwAAAAYDQAA8GkAQAEAAADXAAAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5QRQwGMALCw0HEQcVBxhIHAQBEAAAAGA0AANBqAEABAAAAnwAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDnBFDAYgAlwKw0HEQcYSBwdGC2zDQcRBxhIHBwAAAABEAAAAGA0AAHBrAEABAAAAWAEAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOgAFFDAYwAtQKw0HEQcVBxhIHB0QLAAAAAABcAAAAGA0AANBsAEABAAAAjQoAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRw6AAkgMBlADLwEKw0HEQcVCzELNQs5Cz0HGEgcPSwsUAAAA/////wEAAXggDAcIoAEAAAAAAAAsAAAA8BEAAGB3AEABAAAAQAAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIHPDQcYSBwNEAAAA8BEAAKB3AEABAAAAfAAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjACZArDQcRBxUHGEgcBRAsAAAAAAAAUAAAA8BEAACB4AEABAAAAJwAAAAAAAABcAAAA8BEAAFB4AEABAAAAfQEAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA6AAUUMBlADAwEKw0HEQcVCzELNQs5Cz0HGDAcIRQsUAAAA/////wEAAXggDAcIoAEAAAAAAAB0AAAA+BIAANB5AEABAAAAExYAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRw6QAkgMBlADrwIKw0HEQcVCzELNQs5Cz0HGEgcRSwt2CsNBxEHFQsxCzULOQs9BxhIHEUcLAAAUAAAA/////wEAAXggDAcIoAEAAAAAAABcAAAAiBMAAPCPAEABAAAACgEAAAAAAABBDhCGAkIOGI0DQg4gjARBDiiFBUEOMIQGQQ44gwdEDQZkCsNBxEHFQsxCzUHGDAcwSQsCqgrDQcRBxULMQs1BxgwHMEcLAAAUAAAAiBMAAACRAEABAAAAOgAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAABUAAAAGBQAAECRAEABAAAA6QAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjACQwrDQcRBxUHGEgcBRQsCTwrDQcRBxUHGEgcBTgsAAAAAAAAAPAAAABgUAAAwkgBAAQAAAEsAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBVCsNBxhIHA0cLX8NBxhIHAwAAAAAAADwAAAAYFAAAgJIAQAEAAADzAAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOUEUMBiACkgrDQcRBxhIHA0gLAAAAAABEAAAAGBQAAICTAEABAAAAbAAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIFMKw0HGEgcDSQtrCsNBxhIHA0QLTMNBxhIHAwAAAABMAAAAGBQAAPCTAEABAAAAuQAAAAAAAABBDhCGAkIOGIwDQQ4ghQRBDiiEBUEOMIMGRA5QRQwGMAJUCsNBxEHFQsxBxgwHCEgLAAAAAAAAADQAAAAYFAAAsJQAQAEAAAC9AAAAAAAAAEEOEIYCQQ4YgwNEDlBFDAYgewrDQcYSBwVJCwAAAAAAXAAAABgUAABwlQBAAQAAAGcBAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUQOgAFFDAZQA0YBw0HEQcVCzELNQs5Cz0HGDAcIAAAATAAAABgUAADglgBAAQAAAIIBAAAAAAAAQQ4QhgJCDhiMA0EOIIUEQQ4ohAVBDjCDBkQOUEUMBjACcwrDQcRBxULMQcYMBwhJCwAAAAAAAABcAAAAGBQAAHCYAEABAAAAJgEAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA5wRQwGUALxCsNBxEHFQsxCzULOQs9BxgwHGEcLAAAUAAAAGBQAAKCZAEABAAAASAAAAAAAAABUAAAAGBQAAPCZAEABAAAAwwEAAAAAAABBDhCGAkIOGI4DQg4gjQRCDiiMBUEOMIUGQQ44hAdBDkCDCEQOYEUMBkADWAEKw0HEQcVCzELNQs5BxgwHGEQLZAAAABgUAADAmwBAAQAAAA8BAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDQYCgQrDQcRBxUHGDAcgRAtcCsNBxEHFQcYMByBBC3gKw0HEQcVBxgwHIEULW8NBxEHFQcYMByAAAABMAAAAGBQAANCcAEABAAAAGgEAAAAAAABBDhCGAkEOGIQDQQ4ggwREDlBFDAYwRJcGAr8K10HDQcRBxhIHA0YLftdBw0HEQcYSBwMAAAAAABQAAAAYFAAA8J0AQAEAAAAiAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAAAoGAAAIJ4AQAEAAAAoAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAABYGAAAUJ4AQAEAAAAlAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAACIGAAAgJ4AQAEAAAALAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAAC4GAAAkJ4AQAEAAAALAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAADwAAADoGAAAoJ4AQAEAAABwAAAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgZwrDQcYSBwNNC27DQcYSBwMAAAAAAAA8AAAA6BgAABCfAEABAAAAaQAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIGcKw0HGEgcDTQtjw0HGEgcDAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAFAAAAIAZAACAnwBAAQAAAAgAAAAAAAAAFAAAAIAZAACQnwBAAQAAAAsAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAALAAAAMgZAACgnwBAAQAAACYAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBZw0HGEgcDFAAAAP////8BAAF4IAwHCKABAAAAAAAALAAAABAaAADQnwBAAQAAAIYAAAAAAAAAQQ4QhgJDDQZmCsYMBwhGCwJVxgwHCAAAPAAAABAaAABgoABAAQAAAEUAAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDmBFDAYwdMNBxEHFQcYSBwMAAFwAAAAQGgAAsKAAQAEAAAAGAQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDoABRQwGUAJ9CsNBxEHFQsxCzULOQs9BxgwHCEMLABQAAAD/////AQABeCAMBwigAQAAAAAAAFQAAAD4GgAAwKEAQAEAAABHAQAAAAAAAEEOEIYCQQ4YhQNBDiCDBEQOYEUMBiACmwrDQcVBxhIHBUcLVwrDQcVBxhIHBUcLTArDQcVBxhIHBUILAAAAAABMAAAA+BoAABCjAEABAAAAbwAAAAAAAABBDhCGAkIOGI0DQg4gjARBDiiFBUEOMIQGQQ44gwdEDoABRQwGQAJWw0HEQcVCzELNQcYSBwMAAFwAAAD4GgAAgKMAQAEAAAAVAQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDpABRQwGUAKhCsNBxEHFQsxCzULOQs9BxhIHAUcLAEQAAAD4GgAAoKQAQAEAAABhAAAAAAAAAEEOEIYCQg4YjANBDiCFBEEOKIQFQQ4wgwZEDnBFDAYwAkzDQcRBxULMQcYSBwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAU3Vic3lzdGVtAENoZWNrU3VtAFNpemVPZkltYWdlAEJhc2VPZkNvZGUAU2VjdGlvbkFsaWdubWVudABNaW5vclN1YnN5c3RlbVZlcnNpb24ARGF0YURpcmVjdG9yeQBTaXplT2ZTdGFja0NvbW1pdABJbWFnZUJhc2UAU2l6ZU9mQ29kZQBNYWpvckxpbmtlclZlcnNpb24AU2l6ZU9mSGVhcFJlc2VydmUAU2l6ZU9mSW5pdGlhbGl6ZWREYXRhAFNpemVPZlN0YWNrUmVzZXJ2ZQBTaXplT2ZIZWFwQ29tbWl0AE1pbm9yTGlua2VyVmVyc2lvbgBfX2VuYXRpdmVfc3RhcnR1cF9zdGF0ZQBTaXplT2ZVbmluaXRpYWxpemVkRGF0YQBBZGRyZXNzT2ZFbnRyeVBvaW50AE1ham9yU3Vic3lzdGVtVmVyc2lvbgBTaXplT2ZIZWFkZXJzAE1ham9yT3BlcmF0aW5nU3lzdGVtVmVyc2lvbgBGaWxlQWxpZ25tZW50AE51bWJlck9mUnZhQW5kU2l6ZXMARXhjZXB0aW9uUmVjb3JkAERsbENoYXJhY3RlcmlzdGljcwBNaW5vckltYWdlVmVyc2lvbgBNaW5vck9wZXJhdGluZ1N5c3RlbVZlcnNpb24ATG9hZGVyRmxhZ3MAV2luMzJWZXJzaW9uVmFsdWUATWFqb3JJbWFnZVZlcnNpb24AX19lbmF0aXZlX3N0YXJ0dXBfc3RhdGUAaERsbEhhbmRsZQBscHJlc2VydmVkAGR3UmVhc29uAHNTZWNJbmZvAEV4Y2VwdGlvblJlY29yZABwU2VjdGlvbgBUaW1lRGF0ZVN0YW1wAHBOVEhlYWRlcgBDaGFyYWN0ZXJpc3RpY3MAcEltYWdlQmFzZQBWaXJ0dWFsQWRkcmVzcwBpU2VjdGlvbgBpbnRsZW4Ac3RyZWFtAHZhbHVlAGV4cF93aWR0aABfX21pbmd3X2xkYmxfdHlwZV90AHN0YXRlAF9fdEkxMjhfMgBfTWJzdGF0ZXQAcHJlY2lzaW9uAGV4cG9uZW50AF9fbWluZ3dfZGJsX3R5cGVfdABzaWduAHNpZ25fYml0AGludGxlbgBzdHJlYW0AdmFsdWUAZXhwX3dpZHRoAF9fbXNfZndwcmludGYAX19taW5nd19sZGJsX3R5cGVfdABfX3RJMTI4XzIAX01ic3RhdGV0AHByZWNpc2lvbgBleHBvbmVudABfX21pbmd3X2RibF90eXBlX3QAc2lnbgBzaWduX2JpdABfX0JpZ2ludABfX0JpZ2ludABfX0JpZ2ludABfX0JpZ2ludABsYXN0X0NTX2luaXQAYnl0ZV9idWNrZXQAYnl0ZV9idWNrZXQAaW50ZXJuYWxfbWJzdGF0ZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3VjcnRleGUuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUvcHNka19pbmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvaW5jbHVkZQB1Y3J0ZXhlLmMAY3J0ZXhlLmMAd2lubnQuaABpbnRyaW4taW1wbC5oAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAc3RkbGliLmgAZXJyaGFuZGxpbmdhcGkuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAY3R5cGUuaABpbnRlcm5hbC5oAGNvcmVjcnRfc3RhcnR1cC5oAG1hdGguaAB0Y2hhci5oAHdjaGFyLmgAc3RyaW5nLmgAcHJvY2Vzcy5oAHN5bmNoYXBpLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvZ2NjbWFpbi5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZ2NjbWFpbi5jAGdjY21haW4uYwB3aW5udC5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaABjb3JlY3J0LmgAc3RkbGliLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L25hdHN0YXJ0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9pbmNsdWRlAG5hdHN0YXJ0LmMAd2lubnQuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAaW50ZXJuYWwuaABuYXRzdGFydC5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC93aWxkY2FyZC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHdpbGRjYXJkLmMAd2lsZGNhcmQuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvX25ld21vZGUuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydABfbmV3bW9kZS5jAF9uZXdtb2RlLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC90bHNzdXAuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAdGxzc3VwLmMAdGxzc3VwLmMAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAGNvcmVjcnRfc3RhcnR1cC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC94bmNvbW1vZC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHhuY29tbW9kLmMAeG5jb21tb2QuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2Npbml0ZXhlLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydABjaW5pdGV4ZS5jAGNpbml0ZXhlLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9tZXJyLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAG1lcnIuYwBtZXJyLmMAbWF0aC5oAHN0ZGlvLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3VkbGxhcmdjLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAdWRsbGFyZ2MuYwBkbGxhcmd2LmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L0NSVF9mcDEwLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAQ1JUX2ZwMTAuYwBDUlRfZnAxMC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvbWluZ3dfaGVscGVycy5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAbWluZ3dfaGVscGVycy5jAG1pbmd3X2hlbHBlcnMuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcHNldWRvLXJlbG9jLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwc2V1ZG8tcmVsb2MuYwBwc2V1ZG8tcmVsb2MuYwB2YWRlZnMuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAHN0ZGlvLmgAbWVtb3J5YXBpLmgAZXJyaGFuZGxpbmdhcGkuaABzdHJpbmcuaABzdGRsaWIuaAA8YnVpbHQtaW4+AC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC91c2VybWF0aGVyci5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAdXNlcm1hdGhlcnIuYwB1c2VybWF0aGVyci5jAG1hdGguaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQveHR4dG1vZGUuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB4dHh0bW9kZS5jAHh0eHRtb2RlLmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2NydF9oYW5kbGVyLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBjcnRfaGFuZGxlci5jAGNydF9oYW5kbGVyLmMAd2lubnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAZXJyaGFuZGxpbmdhcGkuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAc2lnbmFsLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC90bHN0aHJkLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHRsc3RocmQuYwB0bHN0aHJkLmMAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABzeW5jaGFwaS5oAHN0ZGxpYi5oAHByb2Nlc3N0aHJlYWRzYXBpLmgAZXJyaGFuZGxpbmdhcGkuaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3Rsc21jcnQuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHRsc21jcnQuYwB0bHNtY3J0LmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3BzZXVkby1yZWxvYy1saXN0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAcHNldWRvLXJlbG9jLWxpc3QuYwBwc2V1ZG8tcmVsb2MtbGlzdC5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9wZXNlY3QuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHBlc2VjdC5jAHBlc2VjdC5jAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAd2lubnQuaABzdHJpbmcuaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYy9taW5nd19tYXRoZXJyLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAbWluZ3dfbWF0aGVyci5jAG1pbmd3X21hdGhlcnIuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby9taW5nd192ZnByaW50Zi5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8AL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBtaW5nd192ZnByaW50Zi5jAG1pbmd3X3ZmcHJpbnRmLmMAdmFkZWZzLmgAc3RkaW8uaABtaW5nd19wZm9ybWF0LmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfdnNucHJpbnRmdy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8AL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBtaW5nd192c25wcmludGZ3LmMAbWluZ3dfdnNucHJpbnRmLmMAdmFkZWZzLmgAY29yZWNydC5oAG1pbmd3X3Bmb3JtYXQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby9taW5nd19wZm9ybWF0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvLy4uL2dkdG9hAG1pbmd3X3Bmb3JtYXQuYwBtaW5nd19wZm9ybWF0LmMAbWF0aC5oAHZhZGVmcy5oAGNvcmVjcnQuaABsb2NhbGUuaABzdGRpby5oAHN0ZGludC5oAHdjaGFyLmgAZ2R0b2EuaABzdHJpbmcuaABzdGRkZWYuaAA8YnVpbHQtaW4+AC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL21pbmd3X3Bmb3JtYXR3LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvLy4uL2dkdG9hAG1pbmd3X3Bmb3JtYXR3LmMAbWluZ3dfcGZvcm1hdC5jAG1hdGguaAB2YWRlZnMuaABjb3JlY3J0LmgAbG9jYWxlLmgAc3RkaW8uaABzdGRpbnQuaAB3Y2hhci5oAGdkdG9hLmgAc3RyaW5nLmgAc3RkZGVmLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9kbWlzYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EAZG1pc2MuYwBkbWlzYy5jAGdkdG9haW1wLmgAZ2R0b2EuaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EvZ2R0b2EuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBnZHRvYS5jAGdkdG9hLmMAZ2R0b2FpbXAuaABjb3JlY3J0LmgAZ2R0b2EuaABzdHJpbmcuaAA8YnVpbHQtaW4+AC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hL2dtaXNjLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYQBnbWlzYy5jAGdtaXNjLmMAZ2R0b2FpbXAuaABnZHRvYS5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hL21pc2MuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUvcHNka19pbmMAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBtaXNjLmMAbWlzYy5jAGludHJpbi1pbXBsLmgAZ2R0b2FpbXAuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAbWlud2luYmFzZS5oAGdkdG9hLmgAc3RkbGliLmgAc3luY2hhcGkuaABzdHJpbmcuaAA8YnVpbHQtaW4+AC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2Mvc3Rybmxlbi5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHN0cm5sZW4uYwBzdHJubGVuLmMAY29yZWNydC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2Mvd2Nzbmxlbi5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHdjc25sZW4uYwB3Y3NubGVuLmMAY29yZWNydC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MvX19wX19mbW9kZS5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwBfX3BfX2Ztb2RlLmMAX19wX19mbW9kZS5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MvX19wX19jb21tb2RlLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjAF9fcF9fY29tbW9kZS5jAF9fcF9fY29tbW9kZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby9taW5nd19sb2NrLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvaW5jbHVkZQBtaW5nd19sb2NrLmMAbWluZ3dfbG9jay5jAHN0ZGlvLmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAbWlud2luYmFzZS5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaABpbnRlcm5hbC5oAHN5bmNoYXBpLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MvaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlci5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUvcHNka19pbmMAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBpbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyLmMAaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlci5jAGludHJpbi1pbXBsLmgAY29yZWNydC5oAHN0ZGxpYi5oAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL2FjcnRfaW9iX2Z1bmMuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAYWNydF9pb2JfZnVuYy5jAGFjcnRfaW9iX2Z1bmMuYwBzdGRpby5oAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djcnRvbWIuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHdjcnRvbWIuYwB3Y3J0b21iLmMAY29yZWNydC5oAHdjaGFyLmgAbWlud2luZGVmLmgAd2lubnQuaABzdGRsaWIuaABtYl93Y19jb21tb24uaABzdHJpbmdhcGlzZXQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL21icnRvd2MuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBtYnJ0b3djLmMAbWJydG93Yy5jAGNvcmVjcnQuaAB3Y2hhci5oAG1pbndpbmRlZi5oAHdpbm50LmgAd2lubmxzLmgAc3RyaW5nYXBpc2V0LmgAc3RkbGliLmgAbWJfd2NfY29tbW9uLmgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMQBAAAFAAgAAAAAAAAAAAAEwAjMCAFSBMwI2QgEowFSnwABAAAAAAAAAAShA8ADAjCfBMAD0AMBUATZA+kDAVAEsQbGBgFQAAAAAAAEvgPlAwFUBLEGvwYBVAABAAAAAAAAAAAABL4D5wMCMJ8E5wOBBQFVBLEGxAYCMJ8ExAaPBwFVBKgHzgcBVQAEAQShA7oDAwgwnwAAAQS6A7oDAVAAAQAE0QPZAwIwnwABAATRA9kDAVQAAQAAAATnBNsFCgMgAAFAAQAA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ZGF0YSQ0EAEAAAcAAAADAC5pZGF0YSQ29AUAAAcAAAADAC50ZXh0AAAAKJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3+AcAAAcAAAADAC5pZGF0YSQ1AAMAAAcAAAADAC5pZGF0YSQ0GAEAAAcAAAADAC5pZGF0YSQ2CgYAAAcAAAADAC50ZXh0AAAAMJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3/AcAAAcAAAADAC5pZGF0YSQ1CAMAAAcAAAADAC5pZGF0YSQ0IAEAAAcAAAADAC5pZGF0YSQ2GAYAAAcAAAADAC50ZXh0AAAAOJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3AAgAAAcAAAADAC5pZGF0YSQ1EAMAAAcAAAADAC5pZGF0YSQ0KAEAAAcAAAADAC5pZGF0YSQ2KgYAAAcAAAADAC50ZXh0AAAAQJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3BAgAAAcAAAADAC5pZGF0YSQ1GAMAAAcAAAADAC5pZGF0YSQ0MAEAAAcAAAADAC5pZGF0YSQ2PgYAAAcAAAADAC50ZXh0AAAASJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3CAgAAAcAAAADAC5pZGF0YSQ1IAMAAAcAAAADAC5pZGF0YSQ0OAEAAAcAAAADAC5pZGF0YSQ2UAYAAAcAAAADAC50ZXh0AAAASJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3DAgAAAcAAAADAC5pZGF0YSQ1KAMAAAcAAAADAC5pZGF0YSQ0QAEAAAcAAAADAC5pZGF0YSQ2XgYAAAcAAAADAC50ZXh0AAAAUJUAAAEAAAADAC5kYXRhAAAA4AAAAAIAAAADAC5ic3MAAAAAgAsAAAYAAAADAC5pZGF0YSQ3EAgAAAcAAAADAC5pZGF0YSQ1MAMAAAcAAAADAC5pZGF0YSQ0SAEAAAcAAAADAC5p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dXR3YwAAsJUAAAEAIAACAAAAAAD9GgAAoAMAAAcAAAACAGZyZWUAAAAAuJUAAAEAIAACAAAAAAAKGwAAkAAAAAYAAAACABsbAAAuZGVidWdfYXJhbmdlcwAuZGVidWdfaW5mbwAuZGVidWdfYWJicmV2AC5kZWJ1Z19saW5lAC5kZWJ1Z19mcmFtZQAuZGVidWdfc3RyAC5kZWJ1Z19saW5lX3N0cgAuZGVidWdfbG9jbGlzdHMALmRlYnVnX3JuZ2xpc3RzAF9fbWluZ3dfaW52YWxpZFBhcmFtZXRlckhhbmRsZXIAcHJlX2NfaW5pdAAucmRhdGEkLnJlZnB0ci5fX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAC5yZGF0YSQucmVmcHRyLl9fbWluZ3dfaW5pdGx0c2R5bl9mb3JjZQAucmRhdGEkLnJlZnB0ci5fX21pbmd3X2luaXRsdHNzdW9fZm9yY2UALnJkYXRhJC5yZWZwdHIuX19pbWFnZV9iYXNlX18ALnJkYXRhJC5yZWZwdHIuX19taW5nd19hcHBfdHlwZQBtYW5hZ2VkYXBwAC5yZGF0YSQucmVmcHRyLl9mbW9kZQAucmRhdGEkLnJlZnB0ci5fY29tbW9kZQAucmRhdGEkLnJlZnB0ci5fTUlOR1dfSU5TVEFMTF9ERUJVR19NQVRIRVJSAC5yZGF0YSQucmVmcHRyLl9tYXRoZXJyAHByZV9jcHBfaW5pdAAucmRhdGEkLnJlZnB0ci5fbmV3bW9kZQBzdGFydGluZm8ALnJkYXRhJC5yZWZwdHIuX2Rvd2lsZGNhcmQAX190bWFpbkNSVFN0YXJ0dXAALnJkYXRhJC5yZWZwdHIuX19uYXRpdmVfc3RhcnR1cF9sb2NrAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAaGFzX2NjdG9yAC5yZGF0YSQucmVmcHRyLl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZGF0YSQucmVmcHRyLl9nbnVfZXhjZXB0aW9uX2hhbmRsZXIALnJkYXRhJC5yZWZwdHIuX19taW5nd19vbGRleGNwdF9oYW5kbGVyAC5yZGF0YSQucmVmcHRyLl9faW1wX19fd2luaXRlbnYALnJkYXRhJC5yZWZwdHIuX194Y196AC5yZGF0YSQucmVmcHRyLl9feGNfYQAucmRhdGEkLnJlZnB0ci5fX3hpX3oALnJkYXRhJC5yZWZwdHIuX194aV9hAFdpbk1haW5DUlRTdGFydHVwAC5sX3N0YXJ0dwBtYWluQ1JUU3RhcnR1cAAuQ1JUJFhDQUEALkNSVCRYSUFBAC5kZWJ1Z19pbmZvAC5kZWJ1Z19hYmJyZXYALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19hcmFuZ2VzAC5kZWJ1Z19ybmdsaXN0cwAuZGVidWdfbGluZQAuZGVidWdfc3RyAC5kZWJ1Z19saW5lX3N0cgAucmRhdGEkenp6AC5kZWJ1Z19mcmFtZQBfX2djY19yZWdpc3Rlcl9mcmFtZQBfX2djY19kZXJlZ2lzdGVyX2ZyYW1lAF9fZG9fZ2xvYmFsX2R0b3JzAF9fZG9fZ2xvYmFsX2N0b3JzAC5yZGF0YSQucmVmcHRyLl9fQ1RPUl9MSVNUX18AaW5pdGlhbGl6ZWQAX19keW5fdGxzX2R0b3IAX19keW5fdGxzX2luaXQALnJkYXRhJC5yZWZwdHIuX0NSVF9NVABfX3RscmVnZHRvcgBfd3NldGFyZ3YAX19yZXBvcnRfZXJyb3IAbWFya19zZWN0aW9uX3dyaXRhYmxlAG1heFNlY3Rpb25zAF9wZWkzODZfcnVudGltZV9yZWxvY2F0b3IAd2FzX2luaXQuMAAucmRhdGEkLnJlZnB0ci5fX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfRU5EX18ALnJkYXRhJC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AX19taW5nd19yYWlzZV9tYXRoZXJyAHN0VXNlck1hdGhFcnIAX19taW5nd19zZXR1c2VybWF0aGVycgBfZ251X2V4Y2VwdGlvbl9oYW5kbGVyAF9fbWluZ3d0aHJfcnVuX2tleV9kdG9ycy5wYXJ0LjAAX19taW5nd3Rocl9jcwBrZXlfZHRvcl9saXN0AF9fX3c2NF9taW5nd3Rocl9hZGRfa2V5X2R0b3IAX19taW5nd3Rocl9jc19pbml0AF9fX3c2NF9taW5nd3Rocl9yZW1vdmVfa2V5X2R0b3IAX19taW5nd19UTFNjYWxsYmFjawBwc2V1ZG8tcmVsb2MtbGlzdC5jAF9WYWxpZGF0ZUltYWdlQmFzZQBfRmluZFBFU2VjdGlvbgBfRmluZFBFU2VjdGlvbkJ5TmFtZQBfX21pbmd3X0dldFNlY3Rpb25Gb3JBZGRyZXNzAF9fbWluZ3dfR2V0U2VjdGlvbkNvdW50AF9GaW5kUEVTZWN0aW9uRXhlYwBfR2V0UEVJbWFnZUJhc2UAX0lzTm9ud3JpdGFibGVJbkN1cnJlbnRJbWFnZQBfX21pbmd3X2VudW1faW1wb3J0X2xpYnJhcnlfbmFtZXMAX19taW5nd192ZnByaW50ZgBfX21pbmd3X3ZzbndwcmludGYAX19wZm9ybWF0X2N2dABfX3Bmb3JtYXRfcHV0YwBfX3Bmb3JtYXRfd3B1dGNoYXJzAF9fcGZvcm1hdF9wdXRjaGFycwBfX3Bmb3JtYXRfcHV0cwBfX3Bmb3JtYXRfZW1pdF9pbmZfb3JfbmFuAF9fcGZvcm1hdF94aW50LmlzcmEuMABfX3Bmb3JtYXRfaW50LmlzcmEuMABfX3Bmb3JtYXRfZW1pdF9yYWRpeF9wb2ludABfX3Bmb3JtYXRfZW1pdF9mbG9hdABfX3Bmb3JtYXRfZW1pdF9lZmxvYXQAX19wZm9ybWF0X2VmbG9hdABfX3Bmb3JtYXRfZmxvYXQAX19wZm9ybWF0X2dmbG9hdABfX3Bmb3JtYXRfZW1pdF94ZmxvYXQuaXNyYS4wAF9fbWluZ3dfcGZvcm1hdABfX21pbmd3X3dwZm9ybWF0AF9fcnZfYWxsb2NfRDJBAF9fbnJ2X2FsbG9jX0QyQQBfX2ZyZWVkdG9hAF9fcXVvcmVtX0QyQQAucmRhdGEkLnJlZnB0ci5fX3RlbnNfRDJBAF9fcnNoaWZ0X0QyQQBfX3RyYWlsel9EMkEAZHRvYV9sb2NrAGR0b2FfQ1NfaW5pdABkdG9hX0NyaXRTZWMAZHRvYV9sb2NrX2NsZWFudXAAX19CYWxsb2NfRDJBAHByaXZhdGVfbWVtAHBtZW1fbmV4dABfX0JmcmVlX0QyQQBfX211bHRhZGRfRDJBAF9faTJiX0QyQQBfX211bHRfRDJBAF9fcG93NW11bHRfRDJBAF9fbHNoaWZ0X0QyQQBfX2NtcF9EMkEAX19kaWZmX0QyQQBfX2IyZF9EMkEAX19kMmJfRDJBAF9fc3RyY3BfRDJBAF9fcF9fZm1vZGUALnJkYXRhJC5yZWZwdHIuX19pbXBfX2Ztb2RlAF9fcF9fY29tbW9kZQAucmRhdGEkLnJlZnB0ci5fX2ltcF9fY29tbW9kZQBfbG9ja19maWxlAF91bmxvY2tfZmlsZQBtaW5nd19nZXRfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgBfZ2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIAbWluZ3dfc2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIAX3NldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAGludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIuYwBfX2FjcnRfaW9iX2Z1bmMAX193Y3J0b21iX2NwAHdjc3J0b21icwBfX21icnRvd2NfY3AAaW50ZXJuYWxfbWJzdGF0ZS4yAG1ic3J0b3djcwBpbnRlcm5hbF9tYnN0YXRlLjEAc19tYnN0YXRlLjAAcmVnaXN0ZXJfZnJhbWVfY3RvcgAudGV4dC5zdGFydHVwAC54ZGF0YS5zdGFydHVwAC5wZGF0YS5zdGFydHVwAC5jdG9ycy42NTUzNQBfX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18ATWFwVmlld09mRmlsZQBfX2ltcF9hYm9ydABfX2xpYjY0X2xpYmtlcm5lbDMyX2FfaW5hbWUAX19kYXRhX3N0YXJ0X18AX19fRFRPUl9MSVNUX18AX19pbXBfX2Ztb2RlAF9faW1wX19fX21iX2N1cl9tYXhfZnVuYwBfX2ltcF9fbG9jawBJc0RCQ1NMZWFkQnl0ZUV4AFNldFVuaGFuZGxlZEV4Y2VwdGlvbkZpbHRlcgBfaGVhZF9saWI2NF9saWJtc3ZjcnRfZGVmX2EALnJlZnB0ci5fX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAF9faW1wX0dldEV4aXRDb2RlUHJvY2VzcwBfX2ltcF9DcmVhdGVGaWxlVwBfX2ltcF9jYWxsb2MAX19pbXBfX19wX19mbW9kZQBfX190bHNfc3RhcnRfXwAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAR2V0RmlsZVNpemUAR2V0TGFzdEVycm9yAF9fcnRfcHNyZWxvY3Nfc3RhcnQAX19kbGxfY2hhcmFjdGVyaXN0aWNzX18AX19zaXplX29mX3N0YWNrX2NvbW1pdF9fAF9fbWluZ3dfbW9kdWxlX2lzX2RsbABfX2lvYl9mdW5jAF9fc2l6ZV9vZl9zdGFja19yZXNlcnZlX18AX19tYWpvcl9zdWJzeXN0ZW1fdmVyc2lvbl9fAF9fX2NydF94bF9zdGFydF9fAF9faW1wX0RlbGV0ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9fc2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIALnJlZnB0ci5fX0NUT1JfTElTVF9fAF9faW1wX2ZwdXRjAFZpcnR1YWxRdWVyeQBfX19jcnRfeGlfc3RhcnRfXwAucmVmcHRyLl9faW1wX19mbW9kZQBfX2ltcF9fYW1zZ19leGl0AF9fX2NydF94aV9lbmRfXwBfX2ltcF9fZXJybm8AX19pbXBfQ3JlYXRlRmlsZU1hcHBpbmdXAF90bHNfc3RhcnQAX19pbXBfQ3JlYXRlUHJvY2Vzc1cALnJlZnB0ci5fbWF0aGVycgAucmVmcHRyLl9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9fbWluZ3dfb2xkZXhjcHRfaGFuZGxlcgBfX2ltcF9fdW5sb2NrX2ZpbGUAVGxzR2V0VmFsdWUAX19tc19md3ByaW50ZgBfX2Jzc19zdGFydF9fAF9faW1wX011bHRpQnl0ZVRvV2lkZUNoYXIAX19pbXBfX19DX3NwZWNpZmljX2hhbmRsZXIAX19fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX3NpemVfb2ZfaGVhcF9jb21taXRfXwBfX2ltcF9HZXRMYXN0RXJyb3IALnJlZnB0ci5fZG93aWxkY2FyZABfX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAF9faW1wX2ZyZWUAX19fbWJfY3VyX21heF9mdW5jAC5yZWZwdHIuX19taW5nd19hcHBfdHlwZQBfX21pbmd3X2luaXRsdHNzdW9fZm9yY2UAX190ZW5zX0QyQQBWaXJ0dWFsUHJvdGVjdABfX19jcnRfeHBfc3RhcnRfXwBfX2ltcF9MZWF2ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9SZWFkRmlsZQBfX0Nfc3BlY2lmaWNfaGFuZGxlcgAucmVmcHRyLl9fbWluZ3dfb2xkZXhjcHRfaGFuZGxlcgAucmVmcHRyLl9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX2ltcF9fX21zX2Z3cHJpbnRmAF9fX2NydF94cF9lbmRfXwBfX2ltcF9DbG9zZUhhbmRsZQBfX21pbm9yX29zX3ZlcnNpb25fXwBFbnRlckNyaXRpY2FsU2VjdGlvbgBfTUlOR1dfSU5TVEFMTF9ERUJVR19NQVRIRVJSAF9faW1wX0dldEZpbGVTaXplAC5yZWZwdHIuX194aV9hAC5yZWZwdHIuX0NSVF9NVABfX3NlY3Rpb25fYWxpZ25tZW50X18AX19uYXRpdmVfZGxsbWFpbl9yZWFzb24AX193Z2V0bWFpbmFyZ3MAX3Rsc191c2VkAF9faW1wX21lbXNldABfX0lBVF9lbmRfXwBfX2ltcF9fbG9ja19maWxlAF9faW1wX21lbWNweQBfX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfXwBfX2xpYjY0X2xpYm1zdmNydF9kZWZfYV9pbmFtZQBfX2ltcF9zdHJlcnJvcgAucmVmcHRyLl9uZXdtb2RlAF9fZGF0YV9lbmRfXwBfX2ltcF9md3JpdGUAX19DVE9SX0xJU1RfXwBfaGVhZF9saWI2NF9saWJrZXJuZWwzMl9hAF9fYnNzX2VuZF9fAF9fdGlueXRlbnNfRDJBAF9fbmF0aXZlX3ZjY2xyaXRfcmVhc29uAF9fX2NydF94Y19lbmRfXwAucmVmcHRyLl9fbWluZ3dfaW5pdGx0c3N1b19mb3JjZQAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawBfX2ltcF9FbnRlckNyaXRpY2FsU2VjdGlvbgBfdGxzX2luZGV4AF9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAX19fY3J0X3hjX3N0YXJ0X18AVW5tYXBWaWV3T2ZGaWxlAENyZWF0ZUZpbGVNYXBwaW5nVwBfX19DVE9SX0xJU1RfXwAucmVmcHRyLl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAF9faW1wX3NpZ25hbABHZXRFeGl0Q29kZVByb2Nlc3MALnJlZnB0ci5fX21pbmd3X2luaXRsdHNkeW5fZm9yY2UAX19ydF9wc3JlbG9jc19zaXplAF9faW1wX1dpZGVDaGFyVG9NdWx0aUJ5dGUAX19pbXBfVW5tYXBWaWV3T2ZGaWxlAF9faW1wX3N0cmxlbgBfX2JpZ3RlbnNfRDJBAF9faW1wX21hbGxvYwAucmVmcHRyLl9nbnVfZXhjZXB0aW9uX2hhbmRsZXIAX19pbXBfX193Z2V0bWFpbmFyZ3MAX19pbXBfTWFwVmlld09mRmlsZQBfX2ZpbGVfYWxpZ25tZW50X18AX19pbXBfSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbgBDbG9zZUhhbmRsZQBJbml0aWFsaXplQ3JpdGljYWxTZWN0aW9uAF9fX2xjX2NvZGVwYWdlX2Z1bmMAX19pbXBfZXhpdABfX2ltcF92ZnByaW50ZgBfX21ham9yX29zX3ZlcnNpb25fXwBfX21pbmd3X3BjaW5pdABfX2ltcF9Jc0RCQ1NMZWFkQnl0ZUV4AF9fSUFUX3N0YXJ0X18AX19pbXBfX2NleGl0AF9faW1wX1NldFVuaGFuZGxlZEV4Y2VwdGlvbkZpbHRlcgBfX2ltcF9fb25leGl0AF9fRFRPUl9MSVNUX18AV2lkZUNoYXJUb011bHRpQnl0ZQBfX3NldF9hcHBfdHlwZQBfX2ltcF9TbGVlcABMZWF2ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9fX3NldHVzZXJtYXRoZXJyAF9fc2l6ZV9vZl9oZWFwX3Jlc2VydmVfXwBfX19jcnRfeHRfc3RhcnRfXwBfX3N1YnN5c3RlbV9fAF9hbXNnX2V4aXQAX19pbXBfVGxzR2V0VmFsdWUAX19zZXR1c2VybWF0aGVycgAucmVmcHRyLl9jb21tb2RlAF9faW1wX2ZwcmludGYAX19taW5nd19wY3BwaW5pdABfX2ltcF9fX3BfX2NvbW1vZGUATXVsdGlCeXRlVG9XaWRlQ2hhcgBfX2ltcF9WaXJ0dWFsUHJvdGVjdABfX190bHNfZW5kX18AQ3JlYXRlUHJvY2Vzc1cAX19pbXBfVmlydHVhbFF1ZXJ5AF9faW1wX19pbml0dGVybQBfX21pbmd3X2luaXRsdHNkeW5fZm9yY2UAX2Rvd2lsZGNhcmQAX19pbXBfX19pb2JfZnVuYwBfX2ltcF9sb2NhbGVjb252AGxvY2FsZWNvbnYAX19keW5fdGxzX2luaXRfY2FsbGJhY2sALnJlZnB0ci5fX2ltYWdlX2Jhc2VfXwBfaW5pdHRlcm0AX19pbXBfV2FpdEZvclNpbmdsZU9iamVjdABfX2ltcF9zdHJuY21wAC5yZWZwdHIuX2Ztb2RlAF9faW1wX19fYWNydF9pb2JfZnVuYwBfX21ham9yX2ltYWdlX3ZlcnNpb25fXwBXYWl0Rm9yU2luZ2xlT2JqZWN0AF9fbG9hZGVyX2ZsYWdzX18ALnJlZnB0ci5fX3RlbnNfRDJBAC5yZWZwdHIuX19pbXBfX2NvbW1vZGUAX19fY2hrc3RrX21zAF9fbmF0aXZlX3N0YXJ0dXBfbG9jawBDcmVhdGVGaWxlVwBfX2ltcF93Y3NsZW4AX19pbXBfX19fbGNfY29kZXBhZ2VfZnVuYwBfX3J0X3BzcmVsb2NzX2VuZABfX2ltcF9fZ2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIAX19taW5vcl9zdWJzeXN0ZW1fdmVyc2lvbl9fAF9fbWlub3JfaW1hZ2VfdmVyc2lvbl9fAF9faW1wX191bmxvY2sAX19pbXBfX19zZXRfYXBwX3R5cGUALnJlZnB0ci5fX3hjX2EALnJlZnB0ci5fX3hpX3oALnJlZnB0ci5fTUlOR1dfSU5TVEFMTF9ERUJVR19NQVRIRVJSAF9faW1wX19jb21tb2RlAERlbGV0ZUNyaXRpY2FsU2VjdGlvbgBfX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfRU5EX18AX19pbXBfX193aW5pdGVudgAucmVmcHRyLl9faW1wX19fd2luaXRlbnYALnJlZnB0ci5fX3hjX3oAX19fY3J0X3h0X2VuZF9fAF9faW1wX2ZwdXR3YwBfX21pbmd3X2FwcF90eXBlAA==
SHM_B64_EOF
    verify_sha256 "${shm_tmp}" "${SHM_LAUNCHER_SHA256}"
    mv "${shm_tmp}" "${shm_dst}"
    ok_msg "shm_launcher.exe installed."
  fi

  # -- xinput1_3.dll ---------------------------------------------------------
  if [[ "${controller_mode}" == "true" ]]; then
    local xdll_dst="${TOOLS_DIR}/xinput1_3.dll"
    if [[ -f "${xdll_dst}" ]] \
        && [[ "$(sha256sum "${xdll_dst}" | awk '{print $1}')" == "${XINPUT_DLL_SHA256}" ]]; then
      ok_msg "xinput1_3.dll already installed and verified — skipping."
    else
      info_msg "Extracting xinput1_3.dll from embedded base64..."
      local xdll_tmp
      xdll_tmp=$(mktemp --suffix=.dll)
      base64 -d << 'XDLL_B64_EOF' > "${xdll_tmp}"
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gN1FgEiNVdBIjU2g232g6CTy///pP/7//4tF2EmLFqgED4VR/v//SIlVgN1FgEiNVdBIjU2g232g6Jry///pFf7//4tF2EmLFqgED4Xs/f//SIlVgN1FgEiNVdBIjU2g232g6FDz///p6/3//0iNVdC5JQAAAE2J5+ia3v//6Rv6//+F2w+Fvfr//0yNTcBMiZV4////RIldkIFN2AAQAABMiU2Ax0XAAAAAAOiXMgAATItNgEiNTb5BuBAAAABIi1AI6AAwAABEi12QTIuVeP///4XAfggPt1W+ZolV8A+2VgGJRexMiebpYfr//02F0g+E+f3///fD/f///w+FGwEAAEGLBkmNTghBiQKFwA+IZwIAAA+2VgFJic5MieZFMdLpKPr//4XbD4UZ+v//D7ZWAYFN2AABAABMiebpDfr//4XbD4X++f//D7ZWAYFN2AAIAABMiebp8vn//4nKSItFgGaB4v9/D4TuAQAAZoH6ADwPj/0AAABED7/CuQE8AABEKcFI0+gB0Y2RBMD//0jB6ANIicFMjUXQ6Hjz///ps/z//0mNdghNizZIjQVtSQAATYX2TA9E8ItF4IXAD4gpAQAASGPQTInx6AgpAABMjUXQTInxicLomt3//0mJ9k2J5+m1+P//g/sDD4cg+///uTAAAACD+wK4AwAAAA9E2Okj+f//TI1F0EiNFRxJAAAxyeif4P//6Tr8//8PtlYBRTHSTInmuwQAAADpHfn//02FwLgCwP//TInBD0XQ6VL///9MieZBuwMAAAC7BAAAAOn3+P//DICJRdjpPPv//4n4x0XgEAAAAIDMAolF2OnO+f//ZoXSD4TdAAAAidHpBP///2aQSA+/yemS+f//SIkR6b/7//+D6TAPtlYBTInmQYkK6aT4//8PtlYBx0XgAAAAAEyJ5kyNVeC7AgAAAOmI+P//SYsG6eH4//8PtlYCQbsFAAAASIPGArsEAAAA6Wj4//+IEelq+///TInx6JowAABMjUXQTInxicLodNz//+nV/v//SI1V0EiJwehj5f//6T77//9Jiw7pAfn//4B+AjQPheb5//8PtlYDQbsDAAAASIPGA7sEAAAA6Qv4//8PtlYCQbsDAAAASIPGArsEAAAA6fP3//9IhcC5Bfz//w9F0ekk/v//ZokR6eT6//9BiwbpNPj//4XbdSeBTdgA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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAADAAAAHitAAAAgAAAGAAAABCgYKBwoHiggKCQoJigoKAAkAAAOAAAAGCiaKJwonii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BwiuBgAAkAEAFa4GAADhCQAAEQkBAAABADkAAhADNwcUFAoAACZGbHRTYXZlADgHnAgAACZGbG9hdFNhdmUAOQecCAAAOrQIAAAQABWuBgAAJAoAABEJAQAAGQAWuQUAADQKAAARCQEAAA4AHEURVgoAABJOZXh0AEYRMIsKAAAScHJldgBHETCLCgAAABtfRVhDRVBUSU9OX1JFR0lTVFJBVElPTl9SRUNPUkQAEEQRFIsKAAAdNAoAAAAdkAoAAAgAB1YKAAAcSRG4CgAAEkhhbmRsZXIAShEcYAYAABJoYW5kbGVyAEsRHGAGAAAAHFwR4goAABJGaWJlckRhdGEAXREI2wUAABJWZXJzaW9uAF4RCHcFAAAAG19OVF9USUIAOFcRI3oLAAABRXhjZXB0aW9uTGlzdABYES6LCgAAAAFTdGFja0Jhc2UAWREN2wUAAAgBU3RhY2tMaW1pdABaEQ3bBQAAEAFTdWJTeXN0ZW1UaWIAWxEN2wUAABgduAoAACABQXJiaXRyYXJ5VXNlclBvaW50ZXIAYBEN2wUAACgBU2VsZgBhERd6CwAAMAAH4goAAApOVF9USUIAYhEH4goAAApQTlRfVElCAGMRFZ4LAAAHfwsAACdKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAXQEAAAOKExJ1DAAAAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAApQSU1BR0VfVExTX0NBTExCQUNLAFMgGpYMAAA7dQwAAAebDAAAPLAMAAAE2wUAAAR3BQAABNsFAAAAPXRhZ0NPSU5JVEJBU0UABwRdAQAACJUO6AwAAAJDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAnVkFSRU5VTQBdAQAACQkCBnIPAAACVlRfRU1QVFkAAAJWVF9OVUxMAAECVlRfSTIAAgJWVF9JNAADAlZUX1I0AAQCVlRfUjgABQJWVF9DWQAGAlZUX0RBVEUABwJWVF9CU1RSAAgCVlRfRElTUEFUQ0gACQJWVF9FUlJPUgAKAlZUX0JPT0wACwJWVF9WQVJJQU5UAAwCVlRfVU5LTk9XTgANAlZUX0RFQ0lNQUwADgJWVF9JMQAQAlZUX1VJMQARAlZUX1VJMgASAlZUX1VJNAATAlZUX0k4ABQCVlRfVUk4ABUCVlRfSU5UABYCVlRfVUlOVAAXAlZUX1ZPSUQAGAJWVF9IUkVTVUxUABkCVlRfUFRSABoCVlRfU0FGRUFSUkFZABsCVlRfQ0FSUkFZABwCVlRfVVNFUkRFRklORUQAHQJWVF9MUFNUUgAeAlZUX0xQV1NUUgAfAlZUX1JFQ09SRAAkAlZUX0lOVF9QVFIAJQJWVF9VSU5UX1BUUgAmAlZUX0ZJTEVUSU1FAEACVlRfQkxPQgBBAlZUX1NUUkVBTQBCAlZUX1NUT1JBR0UAQwJWVF9TVFJFQU1FRF9PQkpFQ1QARAJWVF9TVE9SRURfT0JKRUNUAEUCVlRfQkxPQl9PQkpFQ1QARgJWVF9DRgBHAlZUX0NMU0lEAEgCVlRfVkVSU0lPTkVEX1NUUkVBTQBJDlZUX0JTVFJfQkxPQgD/Dw5WVF9WRUNUT1IAABAOVlRfQVJSQVkAACAOVlRfQllSRUYAAEAOVlRfUkVTRVJWRUQAAIAOVlRfSUxMRUdBTAD//w5WVF9JTExFR0FMTUFTS0VEAP8PDlZUX1RZUEVNQVNLAP8PAD4QAAAABwRdAQAACoQQuA8AAAJfX3VuaW5pdGlhbGl6ZWQAAAJfX2luaXRpYWxpemluZwABAl9faW5pdGlhbGl6ZWQAAgAoEAAAAAqGBXIPAAAauA8AAAxfX25hdGl2ZV9zdGFydHVwX3N0YXRlAAqIK8QPAAAMX19uYXRpdmVfc3RhcnR1cF9sb2NrAAqJGQYQAAAHCxAAAD8MX19uYXRpdmVfZGxsbWFpbl9yZWFzb24ACosgbQEAAAhfUFZGVgALFBghBwAACF9QSUZWAAsVFw0HAABAAAAAABgLGBB9EAAAHl9maXJzdAAZfRAAAAAeX2xhc3QAGn0QAAAIHl9lbmQAG30QAAAQAAcsEAAAKAAAAAALHANIEAAAFjoQAACZEAAAKQAMX194aV9hAAEmJI4QAAAMX194aV96AAEnJI4QAAAWLBAAAMIQAAApAAxfX3hjX2EAASgktxAAAAxfX3hjX3oAASkktxAAAAxfX2R5bl90bHNfaW5pdF9jYWxsYmFjawABLSKRDAAAKl9fcHJvY19hdHRhY2hlZAAvDEoBAAAJAxjAOqQCAAAAKmF0ZXhpdF90YWJsZQAxGIIQAAAJAwDAOqQCAAAADF9fbWluZ3dfYXBwX3R5cGUAATMMSgEAACtwY2luaXQAOx46EAAACQMY8DqkAgAAACtfX21pbmd3X21vZHVsZV9pc19kbGwA0gbyAAAACQMAgDqkAgAAABRfcmVnaXN0ZXJfb25leGl0X2Z1bmN0aW9uAAshFUoBAADIEQAABMgRAAAE+wYAAAAHghAAABREbGxNYWluAAE1F00FAADxEQAABPYFAAAEdwUAAASOBQAAAEFfX21haW4AASQNAhIAAEIAFERsbEVudHJ5UG9pbnQAATcXTQUAACwSAAAE9gUAAAR3BQAABI4FAAAAQ19wZWkzODZfcnVudGltZV9yZWxvY2F0b3IAASUNFF9leGVjdXRlX29uZXhpdF90YWJsZQALIhVKAQAAchIAAATIEQAAAB9faW5pdHRlcm0AASMVjxIAAAR9EAAABH0QAAAAH19hbXNnX2V4aXQACm0YqBIAAARKAQAAAB9TbGVlcAAMfxq8EgAABHcFAAAAFF9pbml0aWFsaXplX29uZXhpdF90YWJsZQALIBVKAQAA5xIAAATIEQAAAERhdGV4aXQAB6kBD0oBAABgEzqkAgAAAA8AAAAAAAAAAZxFEwAARWZ1bmMAAc0bLBAAABIAAAAMAAAAIG8TOqQCAAAAlxEAAAMBUgkDAMA6pAIAAAADAVEDowFSAAAsX19EbGxNYWluQ1JUU3RhcnR1cACgTQUAAOAROqQCAAAAXAEAAAAAAAABnJAVAAANKAAAAKAd9gUAAD0AAAArAAAADTMAAACgL3cFAACSAAAAgAAAAA08AAAAoECOBQAA3QAAANUAAAAhcmV0Y29kZQCiC00FAAAZAQAA/QAAAEZpX19sZWF2ZQABxwFLEjqkAgAAABcXEjqkAgAAACwSAAAGJBI6pAIAAADNEQAAChQAAAMBUgJ0AAMBUQEwAwFYAnUAAAYxEjqkAgAAAAISAAAuFAAAAwFSAnQAAwFRAnMAAwFYAnUAAAZBEjqkAgAAABwWAABSFAAAAwFSAnQAAwFRAnMAAwFYAnUAABdtEjqkAgAAACwSAAAGghI6pAIAAAAcFgAAgxQAAAMBUgJ0AAMBUQJzAAMBWAJ1AAAGkxI6pAIAAAACEgAApxQAAAMBUgJ0AAMBUQJzAAMBWAJ1AAAGrBI6pAIAAADNEQAAyhQAAAMBUgJ0AAMBUQEyAwFYAnUAABe9EjqkAgAAAM0RAAAG5hI6pAIAAAAcFgAA+hQAAAMBUgJ0AAMBUQEwAwFYAnUAABf1EjqkAgAAAPERAAAGBRM6pAIAAADNEQAAKhUAAAMBUgJ0AAMBUQExAwFYAnUAAAYdEzqkAgAAAM0RAABNFQAAAwFSAnQAAwFRATADAVgCdQAABioTOqQCAAAAAhIAAHAVAAADAVICdAADAVEBMAMBWAJ1AAAiNxM6pAIAAAAcFgAAAwFSAnQAAwFRATADAVgCdQAAAC1EbGxNYWluQ1JUU3RhcnR1cACTAU0FAABAEzqkAgAAABIAAAAAAAAAAZwcFgAADSgAAACTG/YFAACDAQAAfwEAAA0zAAAAky13BQAAmQEAAJUBAAANPAAAAJM+jgUAAK8BAACrAQAAIFITOqQCAAAARRMAAAMBUgOjAVIDAVEDowFRAwFYA6MBWAAALV9DUlRfSU5JVABDEE0FAAAQEDqkAgAAAM8BAAAAAAAAAZziGAAADSgAAABDIvYFAADNAQAAwQEAAA0zAAAAQzR3BQAAAwIAAPsBAAANPAAAAENFjgUAAC8CAAAjAgAARyAAAAAQGAAALkcAAABOUwIAAGUCAABdAgAAIWZpYmVyaWQATw1TAgAAhwIAAIMCAAAhbmVzdGVkAFALSgEAAJ4CAACWAgAAIysZAAC1EDqkAgAAAAK1EDqkAgAAABAAAAAAAAAATyEmFwAASPcZAAC1EDqkAgAAAAS1EDqkAgAAABAAAAAAAAAAAx0nSRAPGgAAvwIAAL0CAABJHhoAAMsCAADJAgAAAAAvkRkAAOkQOqQCAAAAASsAAABSXRcAABDkGQAA1QIAANMCAAAQ0xkAAOACAADeAgAAGL8ZAAAAI0cZAACAETqkAgAAAAGAETqkAgAAABAAAAAAAAAAbQuUFwAAEH0ZAADqAgAA6AIAABhuGQAAAAbpEDqkAgAAAKgSAACtFwAAAwFSAwroAwBKPRE6pAIAAADMFwAAAwFSAnUAAwFRATIDAVgCfAAABqkROqQCAAAAchIAAOQXAAAZAVIZAVEABsMROqQCAAAAchIAAPwXAAAZAVIZAVEAItoROqQCAAAAjxIAAAMBUgFPAABLDAAAAC5HAAAAd1MCAAD/AgAA8wIAAC+RGQAAaBA6pAIAAAABGQAAAHheGAAAEOQZAAAoAwAAJgMAABDTGQAAMQMAAC8DAAAYvxkAAAAjRxkAAGIROqQCAAAAAWIROqQCAAAADgAAAAAAAACEC5UYAAAQfRkAADoDAAA4AwAAGG4ZAAAABmgQOqQCAAAAqBIAAK4YAAADAVIDCugDAAaUEDqkAgAAAI8SAADFGAAAAwFSAU8AIlwROqQCAAAAShIAAAMBUgkDAMA6pAIAAAAAAAAscHJlX2NfaW5pdAA+SgEAAAAQOqQCAAAADAAAAAAAAAABnCUZAAAgDBA6pAIAAAC8EgAAAwFSCQMAwDqkAgAAAAAATF9URUIATU50Q3VycmVudFRlYgADHSceQhkAAAMHJRkAADBfSW50ZXJsb2NrZWRFeGNoYW5nZVBvaW50ZXIA0wZTAgAAjBkAABNUYXJnZXQA0wYzjBkAABNWYWx1ZQDTBkBTAgAAAAdVAgAAMF9JbnRlcmxvY2tlZENvbXBhcmVFeGNoYW5nZVBvaW50ZXIAyAZTAgAA9xkAABNEZXN0aW5hdGlvbgDIBjqMGQAAE0V4Q2hhbmdlAMgGTVMCAAATQ29tcGVyYW5kAMgGXVMCAAAATl9fcmVhZGdzcXdvcmQAAkYDAQkBAAADE09mZnNldABGAwFyAQAAT3JldAACRgMBCQEAAAAA2AYAAAUAAQjABAAAC0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHY8BAADNAQAAIBk6pAIAAADvAAAAAAAAAHkDAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAAEcHRyZGlmZl90AAVYIxQBAAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAACBAdsb25nIHVuc2lnbmVkIGludAACAQh1bnNpZ25lZCBjaGFyAAIEBGZsb2F0AAIBBnNpZ25lZCBjaGFyAAICBXNob3J0IGludAACEARsb25nIGRvdWJsZQACCARkb3VibGUABdkBAAAMAgIEX0Zsb2F0MTYAAgIEX19iZjE2AAZKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAYAEAAAKKExLCAgAAAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA10YWdDT0lOSVRCQVNFAAcEYAEAAAOVDvoCAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAABlZBUkVOVU0AYAEAAAQJAgaEBQAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQNWVF9CU1RSX0JMT0IA/w8DVlRfVkVDVE9SAAAQA1ZUX0FSUkFZAAAgA1ZUX0JZUkVGAABAA1ZUX1JFU0VSVkVEAACAA1ZUX0lMTEVHQUwA//8DVlRfSUxMRUdBTE1BU0tFRAD/DwNWVF9UWVBFTUFTSwD/DwAEZnVuY19wdHIAAQsQ1AEAAA6EBQAAoAUAAA8AB19fQ1RPUl9MSVNUX18ADJUFAAAHX19EVE9SX0xJU1RfXwANlQUAAAhpbml0aWFsaXplZAAyDE0BAAAJA6DAOqQCAAAAEGF0ZXhpdAAGqQEPTQEAAP8FAAAR1AEAAAASX19tYWluAAE1AfAZOqQCAAAAHwAAAAAAAAABnC4GAAATDxo6pAIAAAAuBgAAAAlfX2RvX2dsb2JhbF9jdG9ycwAgcBk6pAIAAAB6AAAAAAAAAAGcmAYAAApucHRycwAicAEAAFUDAABPAwAACmkAI3ABAABtAwAAaQMAABTGGTqkAgAAAOUFAAAVAVIJAyAZOqQCAAAAAAAJX19kb19nbG9iYWxfZHRvcnMAFCAZOqQCAAAAQwAAAAAAAAABnNYGAAAIcAAWFNYGAAAJAxCAOqQCAAAAAAWEBQAAAHkGAAAFAAEI/wUAAAhHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB10AgAAswIAAKEEAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAAGPgEAAAIEB2xvbmcgdW5zaWduZWQgaW50AAIBCHVuc2lnbmVkIGNoYXIAAgQEZmxvYXQAAgEGc2lnbmVkIGNoYXIAAgIFc2hvcnQgaW50AAIQBGxvbmcgZG91YmxlAAIIBGRvdWJsZQACAgRfRmxvYXQxNgACAgRfX2JmMTYAB0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwA+AQAAAYoTEp8CAAABSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcACXRhZ0NPSU5JVEJBU0UABwQ+AQAAApUO1wIAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAHVkFSRU5VTQA+AQAAAwkCBmEFAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJA1ZUX0JTVFJfQkxPQgD/DwNWVF9WRUNUT1IAABADVlRfQVJSQVkAACADVlRfQllSRUYAAEADVlRfUkVTRVJWRUQAAIADVlRfSUxMRUdBTAD//wNWVF9JTExFR0FMTUFTS0VEAP8PA1ZUX1RZUEVNQVNLAP8PAApRAAAABwQ+AQAABIQQpwUAAAFfX3VuaW5pdGlhbGl6ZWQAAAFfX2luaXRpYWxpemluZwABAV9faW5pdGlhbGl6ZWQAAgALUQAAAASGBWEFAAAGpwUAAARfX25hdGl2ZV9zdGFydHVwX3N0YXRlAIgrswUAAARfX25hdGl2ZV9zdGFydHVwX2xvY2sAiRnzBQAADAj5BQAADQRfX25hdGl2ZV9kbGxtYWluX3JlYXNvbgCLIE4BAAAEX19uYXRpdmVfdmNjbHJpdF9yZWFzb24AjCBOAQAABfoFAAALFwkDJIA6pAIAAAAFGQYAAAwXCQMggDqkAgAAAAW4BQAADSIJA7jAOqQCAAAABdYFAAAOEAkDsMA6pAIAAAAAPggAAAUAAQi1BgAAEkdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHZMDAACMAwAAEBo6pAIAAADDAAAAAAAAAPcEAAABAQZjaGFyAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAADdWludHB0cl90AAJLLPoAAAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAjyAAAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIAEwgDVUxPTkcAAxgddQEAAANXSU5CT09MAAN/DU0BAAADQk9PTAADgw9NAQAAA0RXT1JEAAONHXUBAAABBARmbG9hdAADTFBWT0lEAAOZEZsBAAABAQZzaWduZWQgY2hhcgABAgVzaG9ydCBpbnQAA1VMT05HX1BUUgAEMS76AAAABFBWT0lEAAsBEZsBAAAESEFORExFAJ8BEZsBAAAEVUxPTkdMT05HAPUBLvoAAAABEARsb25nIGRvdWJsZQABCARkb3VibGUACGkCAAAUAQIEX0Zsb2F0MTYAAQIEX19iZjE2ABVKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwRlAQAABYoTElQDAAAJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABCUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcABFBJTUFHRV9UTFNfQ0FMTEJBQ0sAUyAadQMAAAxUAwAACHoDAAAWjwMAAAUcAgAABcgBAAAFHAIAAAAXX0lNQUdFX1RMU19ESVJFQ1RPUlk2NAAoBVUgFFIEAAAGU3RhcnRBZGRyZXNzT2ZSYXdEYXRhAFYgETkCAAAABkVuZEFkZHJlc3NPZlJhd0RhdGEAVyAROQIAAAgGQWRkcmVzc09mSW5kZXgAWCAROQIAABAGQWRkcmVzc09mQ2FsbEJhY2tzAFkgETkCAAAYBlNpemVPZlplcm9GaWxsAFogDcgBAAAgBkNoYXJhY3RlcmlzdGljcwBbIA3IAQAAJAAESU1BR0VfVExTX0RJUkVDVE9SWTY0AFwgB48DAAAESU1BR0VfVExTX0RJUkVDVE9SWQBvICNSBAAADHAEAAADX1BWRlYABhQYZAIAAAiRBAAAAl90bHNfaW5kZXgAIwedAQAACQPMwDqkAgAAAAJfdGxzX3N0YXJ0ACkZYAEAAAkDAAA7pAIAAAACX3Rsc19lbmQAKh1gAQAACQMIADukAgAAAAJfX3hsX2EALCtUAwAACQMo8DqkAgAAAAJfX3hsX3oALStUAwAACQNA8DqkAgAAAAJfdGxzX3VzZWQALxuMBAAACQPAkjqkAgAAAA1fX3hkX2EAP5EEAAAJA0jwOqQCAAAADV9feGRfegBAkQQAAAkDUPA6pAIAAAAYX0NSVF9NVAABRwxNAQAAAl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAGcbcAMAAAkDoJI6pAIAAAACX194bF9jAGgrVAMAAAkDMPA6pAIAAAACX194bF9kAKorVAMAAAkDOPA6pAIAAAACX19taW5nd19pbml0bHRzZHJvdF9mb3JjZQCtBU0BAAAJA8jAOqQCAAAAAl9fbWluZ3dfaW5pdGx0c2R5bl9mb3JjZQCuBU0BAAAJA8TAOqQCAAAAAl9fbWluZ3dfaW5pdGx0c3N1b19mb3JjZQCvBU0BAAAJA8DAOqQCAAAAGV9fbWluZ3dfVExTY2FsbGJhY2sAARkQqwEAAIcGAAAFKgIAAAXIAQAABd8BAAAAGl9fZHluX3Rsc19kdG9yAAGIAbsBAAAQGjqkAgAAADAAAAAAAAAAAZz4BgAACmkAAAAYKgIAAIgDAACEAwAACn8AAAAqyAEAAJoDAACWAwAACnQAAAA73wEAAKwDAACoAwAADjUaOqQCAAAAVwYAAAAbX190bHJlZ2R0b3IAAW0BTQEAANAaOqQCAAAAAwAAAAAAAAABnDIHAAAcZnVuYwABbRSRBAAAAVIAHV9fZHluX3Rsc19pbml0AAFMAbsBAAABhAcAAAtpAAAAGCoCAAALfwAAACrIAQAAC3QAAAA73wEAAA9wZnVuYwBOCp8EAAAPcHMATw0lAQAAAB4yBwAAQBo6pAIAAACCAAAAAAAAAAGcB04HAADCAwAAugMAAAdYBwAA6gMAAOIDAAAHYgcAABIEAAAKBAAAEGwHAAAQeQcAAB8yBwAAeBo6pAIAAAAAeBo6pAIAAAArAAAAAAAAAAFMATMIAAAHTgcAADYEAAAyBAAAB1gHAABHBAAARQQAAAdiBwAAUwQAAE8EAAARbAcAAGYEAABiBAAAEXkHAAB6BAAAdgQAAAAOtRo6pAIAAABXBgAAAADyAQAABQABCJwIAAADR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdfgQAAHcEAAALBgAAAQEGY2hhcgABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAABBAd1bnNpZ25lZCBpbnQAAQQHbG9uZyB1bnNpZ25lZCBpbnQAAQEIdW5zaWduZWQgY2hhcgAEX1BWRlYAAQgYggEAAAUIiAEAAAYHdAEAAJkBAAAI6gAAAAAAAl9feGlfYQAKiQEAAAkDEPA6pAIAAAACX194aV96AAuJAQAACQMg8DqkAgAAAAJfX3hjX2EADIkBAAAJAwDwOqQCAAAAAl9feGNfegANiQEAAAkDCPA6pAIAAAAACQEAAAUAAQj9CAAAAUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHRUFAAAOBQAARQYAAAJfX21pbmd3X2FwcF90eXBlAAEIBQUBAAAJA9DAOqQCAAAAAwQFaW50AADEFwAABQABCCsJAAAnR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdtAUAAPcFAADgGjqkAgAAAD0FAAAAAAAAfwYAAAZfX2dudWNfdmFfbGlzdAACGB0JAQAAKAhfX2J1aWx0aW5fdmFfbGlzdAAhAQAABwEGY2hhcgApIQEAAAZ2YV9saXN0AAIfGvIAAAAGc2l6ZV90AAMjLE0BAAAHCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAcIBWxvbmcgbG9uZyBpbnQABnB0cmRpZmZfdAADWCNnAQAABwIHc2hvcnQgdW5zaWduZWQgaW50AAcEBWludAAHBAVsb25nIGludAAJIQEAAAcEB3Vuc2lnbmVkIGludAAHBAdsb25nIHVuc2lnbmVkIGludAAHAQh1bnNpZ25lZCBjaGFyACoIBlVMT05HAAQYHcgBAAAGV0lOQk9PTAAEfw2gAQAABkJZVEUABIsZ3QEAAAZXT1JEAASMGooBAAAGRFdPUkQABI0dyAEAAAcEBGZsb2F0AAZQQllURQAEkBFNAgAACQ4CAAAGTFBCWVRFAASREU0CAAAGUERXT1JEAASXEnACAAAJKAIAAAZMUFZPSUQABJkR7gEAAAZMUENWT0lEAAScF5QCAAAJmQIAACsHAQZzaWduZWQgY2hhcgAHAgVzaG9ydCBpbnQABlVMT05HX1BUUgAFMS5NAQAABlNJWkVfVAAFkye2AgAAD1BWT0lEAAsBEe4BAAAPTE9ORwApARSnAQAABxAEbG9uZyBkb3VibGUABwgEZG91YmxlAAcCBF9GbG9hdDE2AAcCBF9fYmYxNgAeSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTALgBAAAGihMS8wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAVX01FTU9SWV9CQVNJQ19JTkZPUk1BVElPTgAw8xW1BAAAAkJhc2VBZGRyZXNzAPQVDdcCAAAAAkFsbG9jYXRpb25CYXNlAPUVDdcCAAAIAkFsbG9jYXRpb25Qcm90ZWN0APYVDSgCAAAQAlBhcnRpdGlvbklkAPgVDBsCAAAUAlJlZ2lvblNpemUA+hUOyAIAABgCU3RhdGUA+xUNKAIAACACUHJvdGVjdAD8FQ0oAgAAJAJUeXBlAP0VDSgCAAAoAA9NRU1PUllfQkFTSUNfSU5GT1JNQVRJT04A/hUH8wMAAA9QTUVNT1JZX0JBU0lDX0lORk9STUFUSU9OAP4VIfgEAAAJ8wMAABYOAgAADQUAABdNAQAABwAVX0lNQUdFX0RPU19IRUFERVIAQPMbYQYAAAJlX21hZ2ljAPQbDBsCAAAAAmVfY2JscAD1GwwbAgAAAgJlX2NwAPYbDBsCAAAEAmVfY3JsYwD3GwwbAgAABgJlX2NwYXJoZHIA+BsMGwIAAAgCZV9taW5hbGxvYwD5GwwbAgAACgJlX21heGFsbG9jAPobDBsCAAAMAmVfc3MA+xsMGwIAAA4CZV9zcAD8GwwbAgAAEAJlX2NzdW0A/RsMGwIAABICZV9pcAD+GwwbAgAAFAJlX2NzAP8bDBsCAAAWAmVfbGZhcmxjAAAcDBsCAAAYAmVfb3ZubwABHAwbAgAAGgJlX3JlcwACHAxhBgAAHAJlX29lbWlkAAMcDBsCAAAkAmVfb2VtaW5mbwAEHAwbAgAAJgJlX3JlczIABRwMcQYAACgCZV9sZmFuZXcABhwM5QIAADwAFhsCAABxBgAAF00BAAADABYbAgAAgQYAABdNAQAACQAPSU1BR0VfRE9TX0hFQURFUgAHHAcNBQAALAQGgB0HzwYAAB9QaHlzaWNhbEFkZHJlc3MAgR0oAgAAH1ZpcnR1YWxTaXplAIIdKAIAAAAVX0lNQUdFX1NFQ1RJT05fSEVBREVSACh+HeIHAAACTmFtZQB/HQz9BAAAAAJNaXNjAIMdCZoGAAAIAlZpcnR1YWxBZGRyZXNzAIQdDSgCAAAMAlNpemVPZlJhd0RhdGEAhR0NKAIAABACUG9pbnRlclRvUmF3RGF0YQCGHQ0oAgAAFAJQb2ludGVyVG9SZWxvY2F0aW9ucwCHHQ0oAgAAGAJQb2ludGVyVG9MaW5lbnVtYmVycwCIHQ0oAgAAHAJOdW1iZXJPZlJlbG9jYXRpb25zAIkdDBsCAAAgAk51bWJlck9mTGluZW51bWJlcnMAih0MGwIAACICQ2hhcmFjdGVyaXN0aWNzAIsdDSgCAAAkAA9QSU1BR0VfU0VDVElPTl9IRUFERVIAjB0dAAgAAAnPBgAALXRhZ0NPSU5JVEJBU0UABwS4AQAAB5UOPQgAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAeVkFSRU5VTQC4AQAACAkCBscKAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJDlZUX0JTVFJfQkxPQgD/Dw5WVF9WRUNUT1IAABAOVlRfQVJSQVkAACAOVlRfQllSRUYAAEAOVlRfUkVTRVJWRUQAAIAOVlRfSUxMRUdBTAD//w5WVF9JTExFR0FMTUFTS0VEAP8PDlZUX1RZUEVNQVNLAP8PAC5faW9idWYAMAkhClcLAAAFX3B0cgAJJQuzAQAAAAVfY250AAkmCaABAAAIBV9iYXNlAAknC7MBAAAQBV9mbGFnAAkoCaABAAAYBV9maWxlAAkpCaABAAAcBV9jaGFyYnVmAAkqCaABAAAgBV9idWZzaXoACSsJoAEAACQFX3RtcGZuYW1lAAksC7MBAAAoAAZGSUxFAAkvGccKAAAYX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AMQ0hAQAAGF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwAyDSEBAAAYX19pbWFnZV9iYXNlX18AMxmBBgAAGQg88AsAAAVhZGRlbmQAAT0JKAIAAAAFdGFyZ2V0AAE+CSgCAAAEAAZydW50aW1lX3BzZXVkb19yZWxvY19pdGVtX3YxAAE/A8gLAAAZDEdJDAAABXN5bQABSAkoAgAAAAV0YXJnZXQAAUkJKAIAAAQFZmxhZ3MAAUoJKAIAAAgABnJ1bnRpbWVfcHNldWRvX3JlbG9jX2l0ZW1fdjIAAUsDFQwAABkMTacMAAAFbWFnaWMxAAFOCSgCAAAABW1hZ2ljMgABTwkoAgAABAV2ZXJzaW9uAAFQCSgCAAAIAAZydW50aW1lX3BzZXVkb19yZWxvY192MgABUQNuDAAAL4gAAAAoAaoQNg0AAAVvbGRfcHJvdGVjdAABrAkoAgAAAAViYXNlX2FkZHJlc3MAAa0J1wIAAAgFcmVnaW9uX3NpemUAAa4KyAIAABAFc2VjX3N0YXJ0AAGvCT8CAAAYBWhhc2gAAbAZ4gcAACAAMIgAAAABsQPHDAAAE3RoZV9zZWNzALMSXA0AAAkD6MA6pAIAAAAJNg0AABNtYXhTZWN0aW9ucwC0DKABAAAJA+TAOqQCAAAAGkdldExhc3RFcnJvcgALMBsoAgAAEVZpcnR1YWxQcm90ZWN0AApFHf4BAADDDQAACHUCAAAIyAIAAAgoAgAACGECAAAAEVZpcnR1YWxRdWVyeQAKLRzIAgAA7A0AAAiEAgAACNYEAAAIyAIAAAAaX0dldFBFSW1hZ2VCYXNlAAGoDj8CAAARX19taW5nd19HZXRTZWN0aW9uRm9yQWRkcmVzcwABpx7iBwAAMw4AAAh1AgAAABFtZW1jcHkADDIS7gEAAFYOAAAI7gEAAAiUAgAACD4BAAAAMWFib3J0AA2VASgydmZwcmludGYACSkCD6ABAACHDgAACIwOAAAIlg4AAAguAQAAAAlXCwAAIIcOAAAJKQEAACCRDgAAEV9fYWNydF9pb2JfZnVuYwAJXReHDgAAvQ4AAAi4AQAAABpfX21pbmd3X0dldFNlY3Rpb25Db3VudAABpgygAQAAM19wZWkzODZfcnVudGltZV9yZWxvY2F0b3IAAeUBAcAcOqQCAAAAXQMAAAAAAAABnAgUAAA0d2FzX2luaXQAAecBFqABAAAJA+DAOqQCAAAANW1TZWNzAAHpAQegAQAAnQQAAJsEAAAhCBQAAEUdOqQCAAAAAkIAAAD1AQOyEwAAGx8UAAAbLRQAABs5FAAANkIAAAAKRhQAALUEAAClBAAAClcUAAAeBQAA7gQAAApnFAAANQYAAB0GAAAKfBQAALYGAACwBgAACosUAADaBgAAzgYAAAqVFAAAFwcAAAcHAAAiwxQAAFIAAAAQEAAACsQUAABkBwAAXAcAAArZFAAAlQcAAI0HAAALWR46pAIAAADdFgAABAFSCQMIlDqkAgAAAAQBWAJ1AAQCdyACdAAAABz9FAAA5x06pAIAAAAC5x06pAIAAAALAAAAAAAAANUBuRAAAAMsFQAAxgcAAMQHAAADIBUAANEHAADPBwAAAxMVAADgBwAA3gcAABL9FAAA5x06pAIAAAAE5x06pAIAAAALAAAAAAAAAAcBAQMsFQAA6gcAAOgHAAADIBUAAPUHAADzBwAAAxMVAAAECAAAAggAAAvvHTqkAgAAAHUVAAAEAVICdQAAAAAh/RQAALIeOqQCAAAAAmwAAADSAQxMEQAAAywVAAAOCAAADAgAAAMgFQAAGQgAABcIAAADExUAACgIAAAmCAAAN/0UAACyHjqkAgAAAARsAAAAAQcBAQMsFQAAMggAADAIAAADIBUAAD0IAAA7CAAAAxMVAABMCAAASggAAAu+HjqkAgAAAHUVAAAEAVICdQAAAAAc/RQAAGcfOqQCAAAAAmcfOqQCAAAACgAAAAAAAADYAfURAAADLBUAAFYIAABUCAAAAyAVAABhCAAAXwgAAAMTFQAAcAgAAG4IAAAS/RQAAGcfOqQCAAAABGcfOqQCAAAACgAAAAAAAAAHAQEDLBUAAHoIAAB4CAAAAyAVAACFCAAAgwgAAAMTFQAAlAgAAJIIAAALbx86pAIAAAB1FQAABAFSAnUAAAAAHP0UAACAHzqkAgAAAAGAHzqkAgAAAAsAAAAAAAAA3AGeEgAAAywVAACeCAAAnAgAAAMgFQAAqQgAAKcIAAADExUAALgIAAC2CAAAEv0UAACAHzqkAgAAAAOAHzqkAgAAAAsAAAAAAAAABwEBAywVAADCCAAAwAgAAAMgFQAAzQgAAMsIAAADExUAANwIAADaCAAAC4gfOqQCAAAAdRUAAAQBUgJ1AAAAACKiFAAAdwAAAHYTAAAKpxQAAOoIAADkCAAAOLEUAACCAAAACrIUAAAECQAAAgkAABL9FAAA7h86pAIAAAAB7h86pAIAAAAKAAAAAAAAAHMBBAMsFQAADgkAAAwJAAADIBUAABkJAAAXCQAAAxMVAAAoCQAAJgkAABL9FAAA7h86pAIAAAAD7h86pAIAAAAKAAAAAAAAAAcBAQMsFQAAMgkAADAJAAADIBUAAD0JAAA7CQAAAxMVAABMCQAASgkAAAv2HzqkAgAAAHUVAAAEAVICdAAAAAAAAA0QIDqkAgAAAN0WAACVEwAABAFSCQPYkzqkAgAAAAALHSA6pAIAAADdFgAABAFSCQOgkzqkAgAAAAAAADk5FQAA0B46pAIAAABYAAAAAAAAAAH+AQP6EwAAClwVAABYCQAAVAkAADplFQAAA5GsfwsPHzqkAgAAAJMNAAAEAVkCdQAAABQHHTqkAgAAAL0OAAAAI2RvX3BzZXVkb19yZWxvYwA1Ae4UAAAQc3RhcnQANQEZ7gEAABBlbmQANQEn7gEAABBiYXNlADUBM+4BAAAMYWRkcl9pbXAANwENeAEAAAxyZWxkYXRhADcBF3gBAAAMcmVsb2NfdGFyZ2V0ADgBDXgBAAAMdjJfaGRyADkBHO4UAAAMcgA6ASHzFAAADGJpdHMAOwEQuAEAADvDFAAADG8AawEm+BQAACQMbmV3dmFsAHABCigCAAAAACQMbWF4X3Vuc2lnbmVkAMYBFXgBAAAMbWluX3NpZ25lZADHARV4AQAAAAAJpwwAAAlJDAAACfALAAAjX193cml0ZV9tZW1vcnkABwE5FQAAEGFkZHIABwEX7gEAABBzcmMABwEplAIAABBsZW4ABwE1PgEAAAA8cmVzdG9yZV9tb2RpZmllZF9zZWN0aW9ucwAB6QEBdRUAACVpAOsHoAEAACVvbGRwcm90AOwJKAIAAAA9bWFya19zZWN0aW9uX3dyaXRhYmxlAAG3AVAbOqQCAAAAYgEAAAAAAAABnN0WAAAmYWRkcgC3H3UCAAB0CQAAaAkAABNiALkctQQAAAORoH8daAC6GeIHAACwCQAApAkAAB1pALsHoAEAAOEJAADbCQAAPjAcOqQCAAAAUAAAAAAAAABZFgAAHW5ld19wcm90ZWN0ANcN8AEAAPoJAAD4CQAADWIcOqQCAAAAkw0AADAWAAAEAVkCcwAAFGwcOqQCAAAAfg0AAAt6HDqkAgAAAN0WAAAEAVIJA3iTOqQCAAAAAAANsBs6pAIAAAAEDgAAcRYAAAQBUgJzAAAU3Rs6pAIAAADsDQAADQAcOqQCAAAAww0AAJwWAAAEAVECkUAEAVgCCDAADaIcOqQCAAAA3RYAALsWAAAEAVIJA0CTOqQCAAAAAAuyHDqkAgAAAN0WAAAEAVIJAyCTOqQCAAAABAFRAnMAAAA/X19yZXBvcnRfZXJyb3IAAVQB4Bo6pAIAAABpAAAAAAAAAAGcrBcAACZtc2cAVB2RDgAABgoAAAIKAABAE2FyZ3AAkwsuAQAAApFYDQ0bOqQCAAAAmw4AAEAXAAAEAVIBMgANJxs6pAIAAACsFwAAaRcAAAQBUgkDAJM6pAIAAAAEAVEBMQQBWAFLAA01GzqkAgAAAJsOAACAFwAABAFSATIADUMbOqQCAAAAYQ4AAJ4XAAAEAVECcwAEAVgCdAAAFEkbOqQCAAAAVg4AAABBZndyaXRlAF9fYnVpbHRpbl9md3JpdGUADgAASgsAAAUAAQgDDQAAGEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHQcHAAAABwAAICA6pAIAAACSAgAAAAAAAP8LAAACAQZjaGFyAARzaXplX3QAAiMsCQEAAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50ABNKAQAAAgQFbG9uZyBpbnQAAgQHdW5zaWduZWQgaW50AAIEB2xvbmcgdW5zaWduZWQgaW50AAIBCHVuc2lnbmVkIGNoYXIAGQgEV0lOQk9PTAADfw1KAQAABFdPUkQAA4waNAEAAAREV09SRAADjR1yAQAAAgQEZmxvYXQABExQVk9JRAADmRGYAQAAAgEGc2lnbmVkIGNoYXIAAgIFc2hvcnQgaW50AARVTE9OR19QVFIABDEuCQEAAAdMT05HACkBFFYBAAAHSEFORExFAJ8BEZgBAAAPX0xJU1RfRU5UUlkAEHECElsCAAABRmxpbmsAcgIZWwIAAAABQmxpbmsAcwIZWwIAAAgACCcCAAAHTElTVF9FTlRSWQB0AgUnAgAAAhAEbG9uZyBkb3VibGUAAggEZG91YmxlAAICBF9GbG9hdDE2AAICBF9fYmYxNgAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAAcEYgEAAAWKExJ2AwAAC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQtKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA9fUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcAMNIjFG4EAAABVHlwZQDTIwyqAQAAAAFDcmVhdG9yQmFja1RyYWNlSW5kZXgA1CMMqgEAAAIBQ3JpdGljYWxTZWN0aW9uANUjJQwFAAAIAVByb2Nlc3NMb2Nrc0xpc3QA1iMSYAIAABABRW50cnlDb3VudADXIw23AQAAIAFDb250ZW50aW9uQ291bnQA2CMNtwEAACQBRmxhZ3MA2SMNtwEAACgBQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaADaIwyqAQAALAFTcGFyZVdPUkQA2yMMqgEAAC4AD19SVExfQ1JJVElDQUxfU0VDVElPTgAo7SMUDAUAAAFEZWJ1Z0luZm8A7iMjEQUAAAABTG9ja0NvdW50AO8jDAsCAAAIAVJlY3Vyc2lvbkNvdW50APAjDAsCAAAMAU93bmluZ1RocmVhZADxIw4YAgAAEAFMb2NrU2VtYXBob3JlAPIjDhgCAAAYAVNwaW5Db3VudADzIxH5AQAAIAAIbgQAAAdQUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcA3CMjNQUAAAh2AwAAB1JUTF9DUklUSUNBTF9TRUNUSU9OAPQjB24EAAAHUFJUTF9DUklUSUNBTF9TRUNUSU9OAPQjHQwFAAAEQ1JJVElDQUxfU0VDVElP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LWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB22CAAA/ggAALEOAAABX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAAcUAQAACQNhwTqkAgAAAAMBBmNoYXIAAV9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAAgUAQAACQNgwTqkAgAAAABMFQAABQABCMIPAAAfR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdaAkAAKUJAADAIjqkAgAAAP4DAAAAAAAA6w4AAAUIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQABQEGY2hhcgAgDAEAAApzaXplX3QAAiMs8gAAAAUIBWxvbmcgbG9uZyBpbnQABQIHc2hvcnQgdW5zaWduZWQgaW50AAUEBWludAAFBAVsb25nIGludAAFBAd1bnNpZ25lZCBpbnQABQQHbG9uZyB1bnNpZ25lZCBpbnQABQEIdW5zaWduZWQgY2hhcgAhCApXSU5CT09MAAN/DU8BAAAKQllURQADixmHAQAACldPUkQAA4waOQEAAApEV09SRAADjR1yAQAABQQEZmxvYXQAClBCWVRFAAOQEekBAAAMqgEAAApMUFZPSUQAA5kRmAEAAAUBBnNpZ25lZCBjaGFyAAUCBXNob3J0IGludAAKVUxPTkdfUFRSAAQxLvIAAAAKRFdPUkRfUFRSAAS/JxkCAAAHTE9ORwApARRWAQAAB1VMT05HTE9ORwD1AS7yAAAABRAEbG9uZyBkb3VibGUABQgEZG91YmxlAAUCBF9GbG9hdDE2AAUCBF9fYmYxNgASqgEAAJsCAAAT8gAAAAcADl9JTUFHRV9ET1NfSEVBREVSAEDzG+8DAAABZV9tYWdpYwD0Gwy3AQAAAAFlX2NibHAA9RsMtwEAAAIBZV9jcAD2Gwy3AQAABAFlX2NybGMA9xsMtwEAAAYBZV9jcGFyaGRyAPgbDLcBAAAIAWVfbWluYWxsb2MA+RsMtwEAAAoBZV9tYXhhbGxvYwD6Gwy3AQAADAFlX3NzAPsbDLcBAAAOAWVfc3AA/BsMtwEAABABZV9jc3VtAP0bDLcBAAASAWVfaXAA/hsMtwEAABQBZV9jcwD/Gwy3AQAAFgFlX2xmYXJsYwAAHAy3AQAAGAFlX292bm8AARwMtwEAABoBZV9yZXMAAhwM7wMAABwBZV9vZW1pZAADHAy3AQAAJAFlX29lbWluZm8ABBwMtwEAACYBZV9yZXMyAAUcDP8DAAAoAWVfbGZhbmV3AAYcDD0CAAA8ABK3AQAA/wMAABPyAAAAAwAStwEAAA8EAAAT8gAAAAkAB0lNQUdFX0RPU19IRUFERVIABxwHmwIAAAdQSU1BR0VfRE9TX0hFQURFUgAHHBlCBAAADJsCAAAOX0lNQUdFX0ZJTEVfSEVBREVSABRiHP0EAAABTWFjaGluZQBjHAy3AQAAAAFOdW1iZXJPZlNlY3Rpb25zAGQcDLcBAAACD5oAAABlHA3EAQAABAFQb2ludGVyVG9TeW1ib2xUYWJsZQBmHA3EAQAACAFOdW1iZXJPZlN5bWJvbHMAZxwNxAEAAAwBU2l6ZU9mT3B0aW9uYWxIZWFkZXIAaBwMtwEAABAPsgAAAGkcDLcBAAASAAdJTUFHRV9GSUxFX0hFQURFUgBqHAdHBAAADl9JTUFHRV9EQVRBX0RJUkVDVE9SWQAInxxRBQAAD80AAACgHA3EAQAAAAFTaXplAKEcDcQBAAAEAAdJTUFHRV9EQVRBX0RJUkVDVE9SWQCiHAcXBQAAElEFAAB+BQAAE/IAAAAPAA5fSU1BR0VfT1BUSU9OQUxfSEVBREVSNjQA8NkcqwgAAAFNYWdpYwDaHAy3AQAAAAFNYWpvckxpbmtlclZlcnNpb24A2xwMqgEAAAIBTWlub3JMaW5rZXJWZXJzaW9uANwcDKoBAAADAVNpemVPZkNvZGUA3RwNxAEAAAQBU2l6ZU9mSW5pdGlhbGl6ZWREYXRhAN4cDcQBAAAIAVNpemVPZlVuaW5pdGlhbGl6ZWREYXRhAN8cDcQBAAAMAUFkZHJlc3NPZkVudHJ5UG9pbnQA4BwNxAEAABABQmFzZU9mQ29kZQDhHA3EAQAAFAFJbWFnZUJhc2UA4hwRSgIAABgBU2VjdGlvbkFsaWdubWVudADjHA3EAQAAIAFGaWxlQWxpZ25tZW50AOQcDcQBAAAkAU1ham9yT3BlcmF0aW5nU3lzdGVtVmVyc2lvbgDlHAy3AQAAKAFNaW5vck9wZXJhdGluZ1N5c3RlbVZlcnNpb24A5hwMtwEAACoBTWFqb3JJbWFnZVZlcnNpb24A5xwMtwEAACwBTWlub3JJbWFnZVZlcnNpb24A6BwMtwEAAC4BTWFqb3JTdWJzeXN0ZW1WZXJzaW9uAOkcDLcBAAAwAU1pbm9yU3Vic3lzdGVtVmVyc2lvbgDqHAy3AQAAMgFXaW4zMlZlcnNpb25WYWx1ZQDrHA3EAQAANAFTaXplT2ZJbWFnZQDsHA3EAQAAOAFTaXplT2ZIZWFkZXJzAO0cDcQBAAA8AUNoZWNrU3VtAO4cDcQBAABAAVN1YnN5c3RlbQDvHAy3AQAARAFEbGxDaGFyYWN0ZXJpc3RpY3MA8BwMtwEAAEYBU2l6ZU9mU3RhY2tSZXNlcnZlAPEcEUoCAABIAVNpemVPZlN0YWNrQ29tbWl0APIcEUoCAABQAVNpemVPZkhlYXBSZXNlcnZlAPMcEUoCAABYAVNpemVPZkhlYXBDb21taXQA9BwRSgIAAGABTG9hZGVyRmxhZ3MA9RwNxAEAAGgBTnVtYmVyT2ZSdmFBbmRTaXplcwD2HA3EAQAAbAFEYXRhRGlyZWN0b3J5APccHG4FAABwAAdJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HAd+BQAAB1BJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HCDsCAAADH4FAAAHUElNQUdFX09QVElPTkFMX0hFQURFUgAFHSbLCAAAIl9JTUFHRV9OVF9IRUFERVJTNjQACAEFDx0UbwkAAAFTaWduYXR1cmUAEB0NxAEAAAABRmlsZUhlYWRlcgARHRn9BAAABAFPcHRpb25hbEhlYWRlcgASHR+rCAAAGAAHUElNQUdFX05UX0hF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b3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABQgCQk9PTACDDzsBAAACRFdPUkQAjR1eAQAAAQQEZmxvYXQAAkxQVk9JRACZEYQBAAABAQZzaWduZWQgY2hhcgABAgVzaG9ydCBpbnQABkhBTkRMRQADnwERhAEAAAEQBGxvbmcgZG91YmxlAAEIBGRvdWJsZQABAgRfRmxvYXQxNgABAgRfX2JmMTYAB0RsbEVudHJ5UG9pbnQAAQ0NhgEAABAnOqQCAAAABgAAAAAAAAABnANoRGxsSGFuZGxlAA0j0gEAAAFSA2R3UmVhc29uAA4OkgEAAAFRA2xwcmVzZXJ2ZWQADw6oAQAAAVgAAK0DAAAFAAEI6xIAAApHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2sCwAA8wsAACAnOqQCAAAASAAAAAAAAAABFQAABV9fZ251Y192YV9saXN0AAIYHQkBAAALCF9fYnVpbHRpbl92YV9saXN0ACEBAAABAQZjaGFyAAwhAQAABXZhX2xpc3QAAh8a8gAAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAYhAQAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIADV9pb2J1ZgAwAyEKVQIAAAJfcHRyACULkgEAAAACX2NudAAmCX8BAAAIAl9iYXNlACcLkgEAABACX2ZsYWcAKAl/AQAAGAJfZmlsZQApCX8BAAAcAl9jaGFyYnVmACoJfwEAACACX2J1ZnNpegArCX8BAAAkAl90bXBmbmFtZQAsC5IBAAAoAAVGSUxFAAMvGc0BAAAIX3VubG9ja19maWxlAPYFfAIAAAN8AgAAAAZVAgAADl9fbWluZ3dfcGZvcm1hdAAEYg1/AQAAtwIAAAN/AQAAA7cCAAADfwEAAAO5AgAAAy4BAAAADwgGKQEAAAhfbG9ja19maWxlAPUF1gIAAAN8AgAAABBfX21pbmd3X3ZmcHJpbnRmAAExDX8BAAAgJzqkAgAAAEgAAAAAAAAAAZwHc3RyZWFtAB58AgAA6hAAAOQQAAAHZm10ADW5AgAAAxEAAP0QAAAHYXJndgBCLgEAABwRAAAWEQAAEXJldHZhbAABMxB/AQAANREAAC8RAAAJOyc6pAIAAAC+AgAAagMAAAQBUgJzAAAJUyc6pAIAAACBAgAAmwMAAAQBUgMKAGAEAVECcwAEAVgBMAQBWQJ0AAQCdyACdQAAEl0nOqQCAAAAYgIAAAQBUgJzAAAAACQxAAAFAAEI9hMAADtHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2aDAAA4AwAAHAnOqQCAAAAuyUAAAAAAACKFQAAD19fZ251Y192YV9saXN0AAMYHQkBAAA8CF9fYnVpbHRpbl92YV9saXN0ACEBAAATAQZjaGFyADEhAQAAD3ZhX2xpc3QAAx8a8gAAAA9zaXplX3QABCMsTQEAABMIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAEwgFbG9uZyBsb25nIGludAAPd2NoYXJfdAAEYhiNAQAAMXgBAAATAgdzaG9ydCB1bnNpZ25lZCBpbnQAEwQFaW50ABMEBWxvbmcgaW50ABQhAQAAI7YBAAAUeAEAACPAAQAAFKMBAAATBAd1bnNpZ25lZCBpbnQAEwQHbG9uZyB1bnNpZ25lZCBpbnQAJGxjb252AJgFLQqCBAAABGRlY2ltYWxfcG9pbnQABS4LtgEAAAAEdGhvdXNhbmRzX3NlcAAFLwu2AQAACARncm91cGluZwAFMAu2AQAAEARpbnRfY3Vycl9zeW1ib2wABTELtgEAABgEY3VycmVuY3lfc3ltYm9sAAUyC7YBAAAgBG1vbl9kZWNpbWFsX3BvaW50AAUzC7YBAAAoBG1vbl90aG91c2FuZHNfc2VwAAU0C7YBAAAwBG1vbl9ncm91cGluZwAFNQu2AQAAOARwb3NpdGl2ZV9zaWduAAU2C7YBAABABG5lZ2F0aXZlX3NpZ24ABTcLtgEAAEgEaW50X2ZyYWNfZGlnaXRzAAU4CiEBAABQBGZyYWNfZGlnaXRzAAU5CiEBAABRBHBfY3NfcHJlY2VkZXMABToKIQEAAFIEcF9zZXBfYnlfc3BhY2UABTsKIQEAAFMEbl9jc19wcmVjZWRlcwAFPAohAQAAVARuX3NlcF9ieV9zcGFjZQAFPQohAQAAVQRwX3NpZ25fcG9zbgAFPgohAQAAVgRuX3NpZ25fcG9zbgAFPwohAQAAVwRfV19kZWNpbWFsX3BvaW50AAVBDsABAABYBF9XX3Rob3VzYW5kc19zZXAABUIOwAEAAGAEX1dfaW50X2N1cnJfc3ltYm9sAAVDDsABAABoBF9XX2N1cnJlbmN5X3N5bWJvbAAFRA7AAQAAcARfV19tb25fZGVjaW1hbF9wb2ludAAFRQ7AAQAAeARfV19tb25fdGhvdXNhbmRzX3NlcAAFRg7AAQAAgARfV19wb3NpdGl2ZV9zaWduAAVHDsABAACIBF9XX25lZ2F0aXZlX3NpZ24ABUgOwAEAAJAAFPQBAAATAQh1bnNpZ25lZCBjaGFyACRfaW9idWYAMAYhCigFAAAEX3B0cgAGJQu2AQAAAARfY250AAYmCaMBAAAIBF9iYXNlAAYnC7YBAAAQBF9mbGFnAAYoCaMBAAAYBF9maWxlAAYpCaMBAAAcBF9jaGFyYnVmAAYqCaMBAAAgBF9idWZzaXoABisJowEAACQEX3RtcGZuYW1lAAYsC7YBAAAoAA9GSUxFAAYvGZgEAAATEARsb25nIGRvdWJsZQATAQZzaWduZWQgY2hhcgATAgVzaG9ydCBpbnQAD2ludDMyX3QABycOowEAAA91aW50MzJfdAAHKBTPAQAAD2ludDY0X3QABykmZwEAABMIBGRvdWJsZQATBARmbG9hdAAUiAEAABS2AQAAPScBAAAICJ8FEu8FAAAQX1djaGFyAAigBRPfAQAAABBfQnl0ZQAIoQUUjQEAAAQQX1N0YXRlAAihBRuNAQAABgA+JwEAAAiiBQWuBQAALW1ic3RhdGVfdAAIowUV7wUAADIIejIGAAAEbG93AAJ7FM8BAAAABGhpZ2gAAnsZzwEAAAQAM0QBAAAId18GAAAMeAACeAyRBQAADHZhbAACeRhNAQAADGxoAAJ8Bw8GAAAALkQBAAACfQUyBgAAMhCHvgYAAARsb3cAAogUzwEAAAAEaGlnaAACiBnPAQAABC9zaWduX2V4cG9uZW50AImjAQAAEEAvcmVzMQCKowEAABBQL3JlczAAi6MBAAAgYAAzAwEAABCE3wYAAAx4AAKGETUFAAAMbGgAAowHawYAAAAuAwEAAAKNBb4GAAAUKQEAACPrBgAAJF9fdEkxMjgAEAFdIhcHAAAEZGlnaXRzAAFeCxcHAAAAAByBBQAAJwcAAB9NAQAAAQAPX190STEyOAABXwP1BgAAPx0BAAAQAWEiVwcAAARkaWdpdHMzMgABYgxXBwAAAAAccAUAAGcHAAAfTQEAAAMALh0BAAABYwM3BwAAQF9fdUkxMjgAEAFlIaEHAAAMdDEyOAABZgsnBwAADHQxMjhfMgABZw1nBwAAAA9fX3VJMTI4AAFoA3MHAABBEAG7CbwIAAAMX19wZm9ybWF0X2xvbmdfdAABwBuqAQAADF9fcGZvcm1hdF9sbG9uZ190AAHBG2cBAAAMX19wZm9ybWF0X3Vsb25nX3QAAcIb3wEAAAxfX3Bmb3JtYXRfdWxsb25nX3QAAcMbTQEAAAxfX3Bmb3JtYXRfdXNob3J0X3QAAcQbjQEAAAxfX3Bmb3JtYXRfdWNoYXJfdAABxRuHBAAADF9fcGZvcm1hdF9zaG9ydF90AAHGG1MFAAAMX19wZm9ybWF0X2NoYXJfdAABxxtEBQAADF9fcGZvcm1hdF9wdHJfdAAByBu8CAAADF9fcGZvcm1hdF91MTI4X3QAAckboQcAAABCCA9fX3Bmb3JtYXRfaW50YXJnX3QAAcoDsQcAACXPAQAAAc0BRwkAAAdQRk9STUFUX0lOSVQAAAdQRk9STUFUX1NFVF9XSURUSAABB1BGT1JNQVRfR0VUX1BSRUNJU0lPTgACB1BGT1JNQVRfU0VUX1BSRUNJU0lPTgADB1BGT1JNQVRfRU5EAAQAD19fcGZvcm1hdF9zdGF0ZV90AAHWA9kIAAAlzwEAAAHZAfcJAAAHUEZPUk1BVF9MRU5HVEhfSU5UAAAHUEZPUk1BVF9MRU5HVEhfU0hPUlQAAQdQRk9STUFUX0xFTkdUSF9MT05HAAIHUEZPUk1BVF9MRU5HVEhfTExPTkcAAwdQRk9STUFUX0xFTkdUSF9MTE9ORzEyOAAEB1BGT1JNQVRfTEVOR1RIX0NIQVIABQAPX19wZm9ybWF0X2xlbmd0aF90AAHjA2EJAAA0MBcBCd4KAAAQZGVzdAABHgESvAgAAAAQZmxhZ3MAAR8BEqMBAAAIEHdpZHRoAAEgARKjAQAADEMxAQAAASEBEqMBAAAQEHJwbGVuAAEiARKjAQAAFBBycGNocgABIwESeAEAABgQdGhvdXNhbmRzX2Nocl9sZW4AASQBEqMBAAAcEHRob3VzYW5kc19jaHIAASUBEngBAAAgEGNvdW50AAEmARKjAQAAJBBxdW90YQABJwESowEAACgQZXhwbWluAAEoARKjAQAALAAtX19wZm9ybWF0X3QAASkBAxIKAAA0EA0EA0MLAAAQX19wZm9ybWF0X2ZwcmVnX21hbnRpc3NhAAEOBBpNAQAAABBfX3Bmb3JtYXRfZnByZWdfZXhwb25lbnQAAQ8EGlMFAAAIAEQQAQUECc4LAAAmX19wZm9ybWF0X2ZwcmVnX2RvdWJsZV90AAsEkQUAACZfX3Bmb3JtYXRfZnByZWdfbGRvdWJsZV90AAwENQUAAEXzCgAAJl9fcGZvcm1hdF9mcHJlZ19iaXRtYXAAEQTOCwAAJl9fcGZvcm1hdF9mcHJlZ19iaXRzABIE3wEAAAAcjQEAAN4LAAAfTQEAAAQALV9fcGZvcm1hdF9mcHJlZ190AAETBANDCwAAD1VMb25nAAk1F98BAAAlzwEAAAk7BvoMAAAHU1RSVE9HX1plcm8AAAdTVFJUT0dfTm9ybWFsAAEHU1RSVE9HX0Rlbm9ybWFsAAIHU1RSVE9HX0luZmluaXRlAAMHU1RSVE9HX05hTgAEB1NUUlRPR19OYU5iaXRzAAUHU1RSVE9HX05vTnVtYmVyAAYHU1RSVE9HX1JldG1hc2sABwdT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B14FAACINgAAhDYAAAdmBQAAmDYAAJQ2AAAJY006pAIAAACEAgAAAwFSAnMAAAAANBIAAAUAAQhnGgAAG0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbAOAACpDgAAoE86pAIAAAATFgAAAAAAAJ49AAAHAQZjaGFyABFzaXplX3QAAyMsCQEAAAcIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQABwgFbG9uZyBsb25nIGludAAHAgdzaG9ydCB1bnNpZ25lZCBpbnQABwQFaW50AAcEBWxvbmcgaW50AAryAAAACkoBAAAHBAd1bnNpZ25lZCBpbnQABwQHbG9uZyB1bnNpZ25lZCBpbnQABwEIdW5zaWduZWQgY2hhcgAHEARsb25nIGRvdWJsZQARVUxvbmcABDUXdwEAABwHBGcBAAAEOwavAgAABVNUUlRPR19aZXJvAAAFU1RSVE9HX05vcm1hbAABBVNUUlRPR19EZW5vcm1hbAACBVNUUlRPR19JbmZpbml0ZQADBVNUUlRPR19OYU4ABAVTVFJUT0dfTmFOYml0cwAFBVNUUlRPR19Ob051bWJlcgAGBVNUUlRPR19SZXRtYXNrAAcFU1RSVE9HX05lZwAIBVNUUlRPR19JbmV4bG8AEAVTVFJUT0dfSW5leGhpACAFU1RSVE9HX0luZXhhY3QAMAVTVFJUT0dfVW5kZXJmbG93AEAFU1RSVE9HX092ZXJmbG93AIAAHUZQSQAYBFABGQMAAAtuYml0cwBRSgEAAAALZW1pbgBSSgEAAAQLZW1heABTSgEAAAgLcm91bmRpbmcAVEoBAAAMC3N1ZGRlbl91bmRlcmZsb3cAVUoBAAAQC2ludF9tYXgAVkoBAAAUABFGUEkABFcDrwIAAAcIBGRvdWJsZQAUJQMAAAcEBGZsb2F0AApdAQAAHl9kYmxfdW5pb24ACAIZAQ9oAwAAFWQAIyUDAAAVTAAsaAMAAAASrAEAAHgDAAAWCQEAAAEAH24BAAAgAtUBAdYDAAAMbmV4dADWARHWAwAAAAxrANcBBkoBAAAIDG1heHdkcwDXAQlKAQAADAxzaWduANcBEUoBAAAQDHdkcwDXARdKAQAAFAx4ANgBCNsDAAAYAAp4AwAAEqwBAADrAwAAFgkBAAAAACBuAQAAAtoBF3gDAAASLwMAAAMEAAAhABT4AwAAF19fYmlndGVuc19EMkEAFQMEAAAXX190ZW5zX0QyQQAgAwQAAAZfX2RpZmZfRDJBADkCEE8EAABPBAAABE8EAAAETwQAAAAK6wMAAAZfX3F1b3JlbV9EMkEARwIMSgEAAHgEAAAETwQAAARPBAAAACJtZW1jcHkABTISmwQAAJsEAAAEmwQAAASdBAAABPoAAAAAIwgKogQAACQGX19CYWxsb2NfRDJBACsCEE8EAADCBAAABEoBAAAABl9fbXVsdGFkZF9EMkEARAIQTwQAAOwEAAAETwQAAARKAQAABEoBAAAABl9fY21wX0QyQQA1AgxKAQAADQUAAARPBAAABE8EAAAABl9fbHNoaWZ0X0QyQQBBAhBPBAAAMQUAAARPBAAABEoBAAAABl9fbXVsdF9EMkEAQwIQTwQAAFMFAAAETwQAAARPBAAAAAZfX3BvdzVtdWx0X0QyQQBGAhBPBAAAeQUAAARPBAAABEoBAAAABl9faTJiX0QyQQA+AhBPBAAAlQUAAARKAQAAAAZfX3J2X2FsbG9jX0QyQQBKAg5dAQAAtgUAAARKAQAAAAZfX2IyZF9EMkEANAIPJQMAANcFAAAETwQAAARiAQAAABhfX0JmcmVlX0QyQQAsAvAFAAAETwQAAAAYX19yc2hpZnRfRDJBAEkCDwYAAARPBAAABEoBAAAABl9fdHJhaWx6X0QyQQBPAgxKAQAALgYAAARPBAAAAAZfX25ydl9hbGxvY19EMkEARQIOXQEAAFoGAAAEXQEAAAQ9AwAABEoBAAAAJV9fZ2R0b2EAAWoHXQEAAKBPOqQCAAAAExYAAAAAAAABnHERAAANZnBpABVxEQAA/TYAALE2AAANYmUAHkoBAABoOAAAOjgAAA1iaXRzACl2EQAAiDkAACw5AAANa2luZHAANGIBAABROwAAEzsAAA1tb2RlAD9KAQAAbDwAAFI8AAANbmRpZ2l0cwBJSgEAAOQ8AADOPAAAGWRlY3B0AGsPYgEAAAKRMBlydmUAax09AwAAApE4A2JiaXRzAJAGSgEAAGA9AAA8PQAAA2IyAJANSgEAACA+AADgPQAAA2I1AJARSgEAAJc/AABnPwAAA2JlMACQFUoBAACHQAAAZ0AAAANkaWcAkBpKAQAAQkEAAAhBAAAmaQABkB9KAQAAA5GsfwNpZXBzAJAiSgEAACFCAAAZQgAAA2lsaW0AkChKAQAAjEIAAEJCAAADaWxpbTAAkC5KAQAA2kMAAMZDAAADaWxpbTEAkDVKAQAAQUQAAC9EAAADaW5leACQPEoBAADLRAAAkUQAAANqAJEGSgEAAPJFAAC6RQAAA2oyAJEJSgEAAGVHAABPRwAAA2sAkQ1KAQAA90cAAL1HAAADazAAkRBKAQAA80gAAOVIAAADa19jaGVjawCRFEoBAAA2SQAALEkAAANraW5kAJEdSgEAAHhJAABgSQAAA2xlZnRyaWdodACRI0oBAAAHSgAA9UkAAANtMgCRLkoBAABySgAAUkoAAANtNQCRMkoBAAAkSwAACEsAAANuYml0cwCRNkoBAAC0SwAAlksAAANyZGlyAJIGSgEAADlMAAAdTAAAA3MyAJIMSgEAAOhMAAC4TAAAA3M1AJIQSgEAAOhNAADGTQAAA3NwZWNfY2FzZQCSFEoBAAB2TgAAak4AAAN0cnlfcXVpY2sAkh9KAQAAr04AAKdOAAADTACTB1EBAADpTgAA0U4AAANiAJQKTwQAAHpPAABKTwAAA2IxAJQOTwQAACdQAAAlUAAAA2RlbHRhAJQTTwQAAD9QAAAxUAAAA21sbwCUG08EAADJUAAAeVAAAANtaGkAlCFPBAAAMVIAAOlRAAADbWhpMQCUJ08EAAA8UwAAOFMAAANTAJQuTwQAAHdTAABLUwAAA2QyAJUJJQMAAC5UAAAaVAAAA2RzAJUNJQMAAK9UAACDVAAAA3MAlghdAQAAVFYAAMJVAAADczAAlgxdAQAAqlgAAIxYAAADZACXE0IDAAA+WQAALlkAAANlcHMAlxZCAwAAnVkAAH9ZAAAncmV0X3plcm8AAbkCiFI6pAIAAAAIZmFzdF9mYWlsZWQAlAH4VzqkAgAAAAhvbmVfZGlnaXQANwJSVzqkAgAAAAhub19kaWdpdHMAMgIQWjqkAgAAAAhyZXQxANUCdlc6pAIAAAAIYnVtcF91cADBARdlOqQCAAAACGNsZWFyX3RyYWlsaW5nMADNAcljOqQCAAAACHNtYWxsX2lsaW0A4wHKXTqkAgAAAAhyZXQAzgLwWzqkAgAAAAhyb3VuZF85X3VwAJECS2U6pAIAAAAIYWNjZXB0AIsC5WE6pAIAAAAIcm91bmRvZmYAvQKsXzqkAgAAAAhjaG9wemVyb3MAyAL6YDqkAgAAABp7EQAAG1A6pAIAAAAAAOgDAACwBugLAAAQpxEAABpaAAAWWgAAEJsRAAA2WgAAMloAABCQEQAATloAAERaAAAo6AMAAA6zEQAAe1oAAHNaAAAOvBEAAJ1aAACZWgAADsURAACyWgAArFoAAA7OEQAAzloAAMhaAAAO2BEAAOpaAADoWgAADuERAAD2WgAA8loAACnrEQAA1FA6pAIAAAAa9BEAAMNQOqQCAAAAAQDyAwAAQxvZCwAAKhASAAAACT9QOqQCAAAAowQAAAAAK/QRAABzXTqkAgAAAAAA/QMAAAEgAg0RDAAAEBASAAALWwAACVsAAAAC3FA6pAIAAAAPBgAAKQwAAAEBUgJzAAACBlE6pAIAAAC2BQAARwwAAAEBUgJzAAEBUQKRbAAselI6pAIAAAAuBgAAAohSOqQCAAAA1wUAAGwMAAABAVICcwAAAqhSOqQCAAAALgYAAJcMAAABAVIJA/2VOqQCAAAAAQFRA5FQBgEBWAExAAIKUzqkAgAAAPAFAACvDAAAAQFSAnMAAAnzUzqkAgAAAJUFAAAJCFY6pAIAAACVBQAACWlXOqQCAAAA1wUAAAJ2VzqkAgAAANcFAADuDAAAAQFSAnUAAAJ+VzqkAgAAANcFAAAGDQAAAQFSAnMAAAKMWDqkAgAAAHkFAAAdDQAAAQFSATEAAutYOqQCAAAAUwUAAD4NAAABAVICcwABAVEFkfx+lAQAAgBZOqQCAAAAeQUAAFUNAAABAVIBMQACUVk6pAIAAAANBQAAeQ0AAAEBUgJzAAEBUQiRiH+UBHwAIgAJdlk6pAIAAAANBQAAArtZOqQCAAAAwgQAAKINAAABAVEBNQEBWAEwAALKWTqkAgAAAOwEAADBDQAAAQFSAnMAAQFRA5FIBgACbFo6pAIAAAANBQAA4g0AAAEBUgJ1AAEBUQV8AH0AIgAJqFo6pAIAAADXBQAAAv9aOqQCAAAAwgQAABEOAAABAVICcwABAVEBOgEBWAEwAAIbWzqkAgAAAMIEAAAzDgAAAQFSAnUAAQFRAToBAVgBMAACLls6pAIAAADCBAAAVQ4AAAEBUgJ9AAEBUQE6AQFYATAAAklbOqQCAAAAVAQAAHQOAAABAVICcwABAVEDkUAGAAJaWzqkAgAAAOwEAACSDgAAAQFSAnMAAQFRAnUAAAJpWzqkAgAAAC0EAACxDgAAAQFSA5FABgEBUQJ9AAACg1s6pAIAAADsBAAA0Q4AAAEBUgJzAAEBUQSRiH8GAAKPWzqkAgAAANcFAADrDgAAAQFSBJGIfwYACfhbOqQCAAAA1wUAAAITXDqkAgAAANcFAAAQDwAAAQFSAnQAAAklXDqkAgAAAMIEAAACQ1w6pAIAAADsBAAAPA8AAAEBUgJzAAEBUQORQAYAAnRcOqQCAAAAwgQAAF4PAAABAVICcwABAVEBOgEBWAEwAALYXDqkAgAAAMIEAACADwAAAQFSAnMAAQFRAToBAVgBMAAC81w6pAIAAABUBAAAng8AAAEBUgJzAAEBUQJ0AAACY106pAIAAABTBQAAuQ8AAAEBUQWRmH+UBAACdWA6pAIAAABTBQAA2g8AAAEBUgJ1AAEBUQWR8H6UBAACg2A6pAIAAAAxBQAA+A8AAAEBUgJ1AAEBUQJzAAACj2A6pAIAAADXBQAAEBAAAAEBUgJzAAACz2A6pAIAAAANBQAALRAAAAEBUgJzAAEBUQExAALeYDqkAgAAAOwEAABMEAAAAQFSAnMAAQFRA5FIBgACeGE6pAIAAADCBAAAbhAAAAEBUgJ9AAEBUQE6AQFYATAAApJhOqQCAAAAwgQAAJAQAAABAVICcwABAVEBOgEBWAEwAAKkYTqkAgAAAFQEAACvEAAAAQFSAnMAAQFRA5FIBgACuGE6pAIAAADsBAAAzhAAAAEBUgORSAYBAVECfQAACVdiOqQCAAAAowQAAAJzYjqkAgAAABwSAAD5EAAAAQFSAnwQAQFRAnUQAAKAYjqkAgAAAA0FAAAWEQAAAQFSAnwAAQFRATEAAhZjOqQCAAAADQUAADMRAAABAVICcwABAVEBMQACJWM6pAIAAADsBAAAUhEAAAEBUgJzAAEBUQORSAYALWxkOqQCAAAAwgQAAAEBUgJ1AAEBUQE6AQFYATAAAAoZAwAACqwBAAAuYml0c3RvYgABIhBPBAAAAfQRAAATYml0cwAgdhEAABNuYml0cwAqSgEAABNiYml0cwA2YgEAAA9pACQGSgEAAA9rACQJSgEAAA9iACUKTwQAAA9iZQAmCXYRAAAPeAAmDnYRAAAPeDAAJhJ2EQAAL3JldAABRAIAMF9faGkwYml0c19EMkEAAvABAUoBAAADHBIAADF5AALwARasAQAAADJtZW1jcHkAX19idWlsdGluX21lbWNweQAGAADLAwAABQABCFMdAAAGR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdjA8AAMoPAADAZTqkAgAAAEoBAAAAAAAAgk8AAAEBBmNoYXIAAQgHbG9uZyBsb25nIHVuc2lnbmVkIGludAABCAVsb25nIGxvbmcgaW50AAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIAARAEbG9uZyBkb3VibGUAB1VMb25nAAM1F14BAAABCARkb3VibGUAAQQEZmxvYXQACHcBAAAgAtUBARICAAADbmV4dADWARESAgAAAANrANcBBjsBAAAIA21heHdkcwDXAQk7AQAADANzaWduANcBETsBAAAQA3dkcwDXARc7AQAAFAN4ANgBCBcCAAAYAAS0AQAACZMBAAAnAgAACvoAAAAAAAt3AQAAAtoBF7QBAAAMX190cmFpbHpfRDJBAAE+BTsBAADQZjqkAgAAADoAAAAAAAAAAZzyAgAABWIAPhXyAgAAOVsAADNbAAACTABACJMBAABYWwAAVFsAAAJ4AEAM9wIAAHJbAABsWwAAAnhlAEAQ9wIAAIxbAACKWwAAAm4AQQY7AQAAmFsAAJRbAAANnQMAAAFnOqQCAAAAAgFnOqQCAAAABAAAAAAAAAABSQgOtQMAAKpbAACoWwAAD8ADAAC5WwAAt1sAAAAABCcCAAAEkwEAABBfX3JzaGlmdF9EMkEAASIGwGU6pAIAAAAKAQAAAAAAAAGcnQMAAAViACIW8gIAAM1bAADBWwAABWsAIh07AQAA91sAAPFbAAACeAAkCfcCAAAgXAAADFwAAAJ4MQAkDfcCAACAXAAAaFwAAAJ4ZQAkEvcCAADcXAAA2lwAAAJ5ACQWkwEAAOlcAADjXAAAAm4AJQY7AQAACF0AAP5cAAAAEV9fbG8wYml0c19EMkEAAugBATsBAAADEnkAAugBF/cCAAATcmV0AALqAQY7AQAAAAAxGwAABQABCJAeAAAuR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdMRAAAG4QAAAQZzqkAgAAANIMAAAAAAAAWlEAAAYIBGRvdWJsZQAGAQZjaGFyABX8AAAADnNpemVfdAAEIywYAQAABggHbG9uZyBsb25nIHVuc2lnbmVkIGludAAGCAVsb25nIGxvbmcgaW50AAYCB3Nob3J0IHVuc2lnbmVkIGludAAGBAVpbnQABgQFbG9uZyBpbnQAL2ABAAAJ/AAAAAlZAQAABgQHdW5zaWduZWQgaW50AAYEB2xvbmcgdW5zaWduZWQgaW50AAYBCHVuc2lnbmVkIGNoYXIAMAgOV09SRAAFjBpDAQAADkRXT1JEAAWNHYsBAAAGBARmbG9hdAAJ3AEAADEGAQZzaWduZWQgY2hhcgAGAgVzaG9ydCBpbnQADlVMT05HX1BUUgAGMS4YAQAAE0xPTkcAKQEUYAEAABNIQU5ETEUAnwERsQEAAB9fTElTVF9FTlRSWQAQcQISXQIAAARGbGluawAHcgIZXQIAAAAEQmxpbmsAB3MCGV0CAAAIAAknAgAAE0xJU1RfRU5UUlkAdAIFJwIAAAYQBGxvbmcgZG91YmxlABXyAAAACY4CAAAyBgIEX0Zsb2F0MTYABgIEX19iZjE2ADNKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwR7AQAAB4oTEnkDAAAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABGkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAH19SVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwAw0iMUegQAAARUeXBlAAfTIwyzAQAAAARDcmVhdG9yQmFja1RyYWNlSW5kZXgAB9QjDLMBAAACBENyaXRpY2FsU2VjdGlvbgAH1SMlHgUAAAgEUHJvY2Vzc0xvY2tzTGlzdAAH1iMSYgIAABAERW50cnlDb3VudAAH1yMNwAEAACAEQ29udGVudGlvbkNvdW50AAfYIw3AAQAAJARGbGFncwAH2SMNwAEAACgEQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaAAH2iMMswEAACwEU3BhcmVXT1JEAAfbIwyzAQAALgAfX1JUTF9DUklUSUNBTF9TRUNUSU9OACjtIxQeBQAABERlYnVnSW5mbwAH7iMjIwUAAAAETG9ja0NvdW50AAfvIwwLAgAACARSZWN1cnNpb25Db3VudAAH8CMMCwIAAAwET3duaW5nVGhyZWFkAAfxIw4YAgAAEARMb2NrU2VtYXBob3JlAAfyIw4YAgAAGARTcGluQ291bnQAB/MjEfkBAAAgAAl6BAAAE1BSVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwDcIyNHBQAACXkDAAATUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMHegQAABNQUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMdHgUAAA5DUklUSUNBTF9TRUNUSU9OAAirIEwFAAAOTFBDUklUSUNBTF9TRUNUSU9OAAitIWkFAAANhwUAAMsFAAAPGAEAAAEAFmR0b2FfQ3JpdFNlYwA3GbsFAAAJAyDLOqQCAAAA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AC1tZW1zZXQAX19idWlsdGluX21lbXNldAAtbWVtY3B5AF9fYnVpbHRpbl9tZW1jcHkAAO4BAAAFAAEIQSMAAANHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2HEQAAxhEAAPBzOqQCAAAAKAAAAAAAAAAVXwAAAQEGY2hhcgAE8gAAAAVzaXplX3QAAiMsDgEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAAZzdHJubGVuAAEEEP8AAADwczqkAgAAACgAAAAAAAAAAZzrAQAAAnMAJesBAAABUgJtYXhsZW4AL/8AAAABUQdzMgABBg/rAQAAkW4AAI1uAAAACAj6AAAAAAUCAAAFAAEIwyMAAARHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB1HEgAAhhIAACB0OqQCAAAAJQAAAAAAAACWXwAAAQEGY2hhcgACc2l6ZV90ACMsCAEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAACd2NoYXJfdABiGEcBAAAFMwEAAAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABndjc25sZW4AAQUB+gAAACB0OqQCAAAAJQAAAAAAAAABnAICAAADdwAYAgIAAK5uAACobgAAA25jbnQAIvoAAADSbgAAzG4AAAduAAEHCvoAAADmbgAA4m4AAAAICEIBAAAAlgsAAAUAAQhJJAAAFEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHQ4TAAAHEwAAUHQ6pAIAAADZAAAAAAAAAC5gAAADAQZjaGFyAAMIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAwgFbG9uZyBsb25nIGludAADAgdzaG9ydCB1bnNpZ25lZCBpbnQAAwQFaW50AAMEBWxvbmcgaW50AAryAAAAAwQHdW5zaWduZWQgaW50AAMEB2xvbmcgdW5zaWduZWQgaW50AAMBCHVuc2lnbmVkIGNoYXIAFV9pb2J1ZgAwAiEKGQIAAARfcHRyAAIlC04BAAAABF9jbnQAAiYJOwEAAAgEX2Jhc2UAAicLTgEAABAEX2ZsYWcAAigJOwEAABgEX2ZpbGUAAikJOwEAABwEX2NoYXJidWYAAioJOwEAACAEX2J1ZnNpegACKwk7AQAAJARfdG1wZm5hbWUAAiwLTgEAACgAB0ZJTEUAAi8ZiQEAAAdXT1JEAAOMGiUBAAAHRFdPUkQAA40dYwEAAAMEBGZsb2F0ABYIAwEGc2lnbmVkIGNoYXIAAwIFc2hvcnQgaW50AAdVTE9OR19QVFIABDEu+gAAAAhMT05HACkBFEIBAAAISEFORExFAJ8BEUoCAAAOX0xJU1RfRU5UUlkAEHECEsoCAAACRmxpbmsAcgIZygIAAAACQmxpbmsAcwIZygIAAAgACpYCAAAITElTVF9FTlRSWQB0AgWWAgAAAxAEbG9uZyBkb3VibGUAAwgEZG91YmxlAAMCBF9GbG9hdDE2AAMCBF9fYmYxNgAPSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAFMBAAAFihMS4wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAOX1JUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHADDSIxTbBAAAAlR5cGUA0yMMJgIAAAACQ3JlYXRvckJhY2tUcmFjZUluZGV4ANQjDCYCAAACAkNyaXRpY2FsU2VjdGlvbgDVIyV5BQAACAJQcm9jZXNzTG9ja3NMaXN0ANYjEs8CAAAQAkVudHJ5Q291bnQA1yMNMwIAACACQ29udGVudGlvbkNvdW50ANgjDTMCAAAkAkZsYWdzANkjDTMCAAAoAkNyZWF0b3JCYWNrVHJhY2VJbmRleEhpZ2gA2iMMJgIAACwCU3BhcmVXT1JEANsjDCYCAAAuAA5fUlRMX0NSSVRJQ0FMX1NFQ1RJT04AKO0jFHkFAAACRGVidWdJbmZvAO4jI34FAAAAAkxvY2tDb3VudADvIwx6AgAACAJSZWN1cnNpb25Db3VudADwIwx6AgAADAJPd25pbmdUaHJlYWQA8SMOhwIAABACTG9ja1NlbWFwaG9yZQDyIw6HAgAAGAJTcGluQ291bnQA8yMRaAIAACAACtsEAAAIUFJUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHANwjI6IFAAAK4wMAAAhSVExfQ1JJVElDQUxfU0VDVElPTgD0IwfbBAAACFBSVExfQ1JJVElDQUxfU0VDVElPTgD0Ix15BQAAB0NSSVRJQ0FMX1NFQ1RJT04ABqsgpwUAAAdMUENSSVRJQ0FMX1NFQ1RJT04ABq0hxAUAABd0YWdDT0lOSVRCQVNFAAcEUwEAAAeVDk4GAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAD1ZBUkVOVU0AUwEAAAgJAgbYCAAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQVWVF9CU1RSX0JMT0IA/w8FVlRfVkVDVE9SAAAQBVZUX0FSUkFZAAAgBVZUX0JZUkVGAABABVZUX1JFU0VSVkVEAACABVZUX0lMTEVHQUwA//8FVlRfSUxMRUdBTE1BU0tFRAD/DwVWVF9UWVBFTUFTSwD/DwAYWAlaC/sIAAAEZgAJWwoZAgAAAARsb2NrAAlcFuIFAAAwAAdfRklMRVgACV0F2AgAABBfX2ltcF9fbG9ja19maWxlADxKAgAACQN4gDqkAgAAABBfX2ltcF9fdW5sb2NrX2ZpbGUAZkoCAAAJA3CAOqQCAAAADExlYXZlQ3JpdGljYWxTZWN0aW9uAAosGnEJAAAL+wUAAAAMX3VubG9jawABEBaHCQAACzsBAAAADEVudGVyQ3JpdGljYWxTZWN0aW9uAAorGqoJAAAL+wUAAAAMX2xvY2sAAQ8WvgkAAAs7AQAAABlfX2FjcnRfaW9iX2Z1bmMAAl0X4AkAAOAJAAALUwEAAAAK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DiiEBUEOMIMGRA5wRQwGMAJMw0HEQcVCzEHGEgcDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAF9vbmV4aXRfdGFibGVfdABfX2VuYXRpdmVfc3RhcnR1cF9zdGF0ZQBoRGxsSGFuZGxlAGR3UmVhc29uAGxwcmVzZXJ2ZWQAbG9ja19mcmVlAF9fZW5hdGl2ZV9zdGFydHVwX3N0YXRlAGhEbGxIYW5kbGUAbHByZXNlcnZlZABkd1JlYXNvbgBzU2VjSW5mbwBwU2VjdGlvbgBUaW1lRGF0ZVN0YW1wAHBOVEhlYWRlcgBDaGFyYWN0ZXJpc3RpY3MAcEltYWdlQmFzZQBWaXJ0dWFsQWRkcmVzcwBpU2VjdGlvbgBpbnRsZW4Ac3RyZWFtAHZhbHVlAGV4cF93aWR0aABfX21pbmd3X2xkYmxfdHlwZV90AHN0YXRlAF9fdEkxMjhfMgBfTWJzdGF0ZXQAcHJlY2lzaW9uAGV4cG9uZW50AF9fbWluZ3dfZGJsX3R5cGVfdABzaWduAHNpZ25fYml0AF9fQmlnaW50AF9fQmlnaW50AF9fQmlnaW50AF9fQmlnaW50AGxhc3RfQ1NfaW5pdABieXRlX2J1Y2tldABfb25leGl0X3RhYmxlX3QAYnl0ZV9idWNrZXQAaW50ZXJuYWxfbWJzdGF0ZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2NydGRsbC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUvcHNka19pbmMAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9pbmNsdWRlAGNydGRsbC5jAGNydGRsbC5jAGludHJpbi1pbXBsLmgAd2lubnQuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHN0ZGxpYi5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaABpbnRlcm5hbC5oAGNvcmVjcnRfc3RhcnR1cC5oAHN5bmNoYXBpLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2djY21haW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAGdjY21haW4uYwBnY2NtYWluLmMAd2lubnQuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAY29yZWNydC5oAHN0ZGxpYi5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9uYXRzdGFydC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvaW5jbHVkZQBuYXRzdGFydC5jAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAGludGVybmFsLmgAbmF0c3RhcnQuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3Rsc3N1cC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB0bHNzdXAuYwB0bHNzdXAuYwBjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAY29yZWNydF9zdGFydHVwLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9jaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAY2luaXRleGUuYwBjaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvbWluZ3dfaGVscGVycy5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAbWluZ3dfaGVscGVycy5jAG1pbmd3X2hlbHBlcnMuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcHNldWRvLXJlbG9jLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwc2V1ZG8tcmVsb2MuYwBwc2V1ZG8tcmVsb2MuYwB2YWRlZnMuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAHN0ZGlvLmgAbWVtb3J5YXBpLmgAZXJyaGFuZGxpbmdhcGkuaABzdHJpbmcuaABzdGRsaWIuaAA8YnVpbHQtaW4+AC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvdGxzdGhyZC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB0bHN0aHJkLmMAdGxzdGhyZC5jAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAd2lubnQuaABtaW53aW5iYXNlLmgAc3luY2hhcGkuaABzdGRsaWIuaABwcm9jZXNzdGhyZWFkc2FwaS5oAGVycmhhbmRsaW5nYXBpLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC90bHNtY3J0LmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB0bHNtY3J0LmMAdGxzbWNydC5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9wc2V1ZG8tcmVsb2MtbGlzdC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHBzZXVkby1yZWxvYy1saXN0LmMAcHNldWRvLXJlbG9jLWxpc3QuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcGVzZWN0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwZXNlY3QuYwBwZXNlY3QuYwBjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAc3RyaW5nLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L0NSVF9mcDEwLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAQ1JUX2ZwMTAuYwBDUlRfZnAxMC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvZGxsZW50cnkuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZGxsZW50cnkuYwBkbGxlbnRyeS5jAG1pbndpbmRlZi5oAHdpbm50LmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfdmZwcmludGYuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWluZ3dfdmZwcmludGYuYwBtaW5nd192ZnByaW50Zi5jAHZhZGVmcy5oAHN0ZGlvLmgAbWluZ3dfcGZvcm1hdC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL21pbmd3X3Bmb3JtYXQuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vLi4vZ2R0b2EAbWluZ3dfcGZvcm1hdC5jAG1pbmd3X3Bmb3JtYXQuYwBtYXRoLmgAdmFkZWZzLmgAY29yZWNydC5oAGxvY2FsZS5oAHN0ZGlvLmgAc3RkaW50LmgAd2NoYXIuaABnZHRvYS5oAHN0cmluZy5oAHN0ZGRlZi5oADxidWlsdC1pbj4AL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EvZG1pc2MuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAGRtaXNjLmMAZG1pc2MuYwBnZHRvYWltcC5oAGdkdG9hLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hL2dkdG9hLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZ2R0b2EuYwBnZHRvYS5jAGdkdG9haW1wLmgAY29yZWNydC5oAGdkdG9hLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9nbWlzYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EAZ21pc2MuYwBnbWlzYy5jAGdkdG9haW1wLmgAZ2R0b2EuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9taXNjLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYQAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlL3BzZGtfaW5jAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWlzYy5jAG1pc2MuYwBpbnRyaW4taW1wbC5oAGdkdG9haW1wLmgAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABnZHRvYS5oAHN0ZGxpYi5oAHN5bmNoYXBpLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3N0cm5sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBzdHJubGVuLmMAc3Rybmxlbi5jAGNvcmVjcnQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djc25sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB3Y3NubGVuLmMAd2Nzbmxlbi5jAGNvcmVjcnQuaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfbG9jay5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2luY2x1ZGUAbWluZ3dfbG9jay5jAG1pbmd3X2xvY2suYwBzdGRpby5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAaW50ZXJuYWwuaABzeW5jaGFwaS5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL2FjcnRfaW9iX2Z1bmMuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAYWNydF9pb2JfZnVuYy5jAGFjcnRfaW9iX2Z1bmMuYwBzdGRpby5oAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djcnRvbWIuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHdjcnRvbWIuYwB3Y3J0b21iLmMAY29yZWNydC5oAHdjaGFyLmgAbWlud2luZGVmLmgAd2lubnQuaABzdGRsaWIuaABtYl93Y19jb21tb24uaABzdHJpbmdhcGlzZXQuaAAvdXNyL3NyYy9taW5ndy13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AwAuaWRhdGEkNTACAAAIAAAAAwAuaWRhdGEkNNgAAAAIAAAAAwAuaWRhdGEkNkYEAAAIAAAAAwAudGV4dAAAADBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN4wFAAAIAAAAAwAuaWRhdGEkNTgCAAAIAAAAAwAuaWRhdGEkNOAAAAAIAAAAAwAuaWRhdGEkNlQEAAAIAAAAAwAudGV4dAAAADhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5AFAAAIAAAAAwAuaWRhdGEkNUACAAAIAAAAAwAuaWRhdGEkNOgAAAAIAAAAAwAuaWRhdGEkNl4EAAAIAAAAAwAudGV4dAAAAEBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5QFAAAIAAAAAwAuaWRhdGEkNUgCAAAIAAAAAwAuaWRhdGEkNPAAAAAIAAAAAwAuaWRhdGEkNmoEAAAIAAAAAwAudGV4dAAAAEhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5gFAAAIAAAAAwAuaWRhdGEkNVACAAAIAAAAAwAuaWRhdGEkNPgAAAAIAAAAAwAuaWRhdGEkNnIEAAAIAAAAAwAudGV4dAAAAFBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5wFAAAIAAAAAwAuaWRhdGEkNVgCAAAIAAAAAwAuaWRhdGEkNAABAAAIAAAAAwAuaWRhdGEkNnwEAAAIAAAAAwAudGV4dAAAAFhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6AFAAAIAAAAAwAuaWRhdGEkNWACAAAIAAAAAwAuaWRhdGEkNAgBAAAIAAAAAwAuaWRhdGEkNoQEAAAIAAAAAwAudGV4dAAAAGBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6QFAAAIAAAAAwAuaWRhdGEkNWgCAAAIAAAAAwAuaWRhdGEkNBABAAAIAAAAAwAuaWRhdGEkNo4EAAAIAAAAAwAudGV4dAAAAGhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6gFAAAIAAAAAwAuaWRhdGEkNXACAAAIAAAAAwAuaWRhdGEkNBgBAAAIAAAAAwAuaWRhdGEkNpgEAAAIAAAAAwAudGV4dAAAAHBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6wFAAAIAAAAAwAuaWRhdGEkNXgCAAAIAAAAAwAuaWRhdGEkNCABAAAIAAAAAwAuaWRhdGEkNqIEAAAIAAAAAwAudGV4dAAAAHhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7AFAAAIAAAAAwAuaWRhdGEkNYACAAAIAAAAAwAuaWRhdGEkNCgBAAAIAAAAAwAuaWRhdGEkNqoEAAAIAAAAAwAudGV4dAAAAIBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7QFAAAIAAAAAwAuaWRhdGEkNYgCAAAIAAAAAwAuaWRhdGEkNDABAAAIAAAAAwAuaWRhdGEkNrIEAAAIAAAAAwAudGV4dAAAAIhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7gFAAAIAAAAAwAuaWRhdGEkNZACAAAIAAAAAwAuaWRhdGEkNDgBAAAIAAAAAwAuaWRhdGEkNroEAAAIAAAAAwAudGV4dAAAAJBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7wFAAAIAAAAAwAuaWRhdGEkNZgCAAAIAAAAAwAuaWRhdGEkNEABAAAIAAAAAwAuaWRhdGEkNsQEAAAIAAAAAwAudGV4dAAAAJhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8AFAAAIAAAAAwAuaWRhdGEkNaACAAAIAAAAAwAuaWRhdGEkNEgBAAAIAAAAAwAuaWRhdGEkNtIEAAAIAAAAAwAudGV4dAAAAKBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8QFAAAIAAAAAwAuaWRhdGEkNagCAAAIAAAAAwAuaWRhdGEkNFABAAAIAAAAAwAuaWRhdGEkNtwEAAAIAAAAAwAudGV4dAAAAKhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8gFAAAIAAAAAwAuaWRhdGEkNbACAAAIAAAAAwAuaWRhdGEkNFgBAAAIAAAAAwAuaWRhdGEkNuYEAAAIAAAAAwAudGV4dAAAALBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8wFAAAIAAAAAwAuaWRhdGEkNbgCAAAIAAAAAwAuaWRhdGEkNGABAAAIAAAAAwAuaWRhdGEkNvAEAAAIAAAAAwAudGV4dAAAALhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9AFAAAIAAAAAwAuaWRhdGEkNcACAAAIAAAAAwAuaWRhdGEkNGgBAAAIAAAAAwAuaWRhdGEkNvoEAAAIAAAAAwAudGV4dAAAAMBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9QFAAAIAAAAAwAuaWRhdGEkNcgCAAAIAAAAAwAuaWRhdGEkNHABAAAIAAAAAwAuaWRhdGEkNgYFAAAIAAAAAwAudGV4dAAAAMhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9gFAAAIAAAAAwAuaWRhdGEkNdACAAAIAAAAAwAuaWRhdGEkNHgBAAAIAAAAAwAuaWRhdGEkNhAFAAAIAAAAAwAudGV4dAAAANBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9wFAAAIAAAAAwAuaWRhdGEkNdgCAAAIAAAAAwAuaWRhdGEkNIABAAAIAAAAAwAuaWRhdGEkNhoFAAAIAAAAAwAudGV4dAAAANhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN+AFAAAIAAAAAwAuaWRhdGEkNeACAAAIAAAAAwAuaWRhdGEkNIgBAAAIAAAAAwAuaWRhdGEkNiYFAAAIAAAAAwAuZmlsZQAAAJgEAAD+/wAAZwFmYWtlAAAAAAAAAAAAAAAAAABobmFtZQAAAMAAAAAIAAAAAwBmdGh1bmsAABgCAAAIAAAAAwAudGV4dAAAAOBsAAABAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuZGF0YQAAALAAAAACAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuYnNzAAAAAJALAAAGAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkMhQAAAAIAAAAAwEUAAAAAwAAAAAAAAAAAAAAAAAuaWRhdGEkNMAAAAAIAAAAAwAuaWRhdGEkNRgCAAAIAAAAAwAuZmlsZQAAAA8FAAD+/wAAZwFmYWtlAAAAAAAAAAAAAAAAAAAudGV4dAAAAOBsAAABAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuZGF0YQAAALAAAAACAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuYnNzAAAAAJALAAAGAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkNJABAAAIAAAAAwEIAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkNegCAAAIAAAAAwEIAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkN+QFAAAIAAAAAwELAAAAAAAAAAAAAAAAAAAAAAAudGV4dAAAAOBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN2gFAAAIAAAAAwAuaWRhdGEkNQgCAAAIAAAAAwAuaWRhdGEkNLAAAAAIAAAAAwAuaWRhdGEkNvYDAAAIAAAAAwAudGV4dAAAAOhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN2QFAAAIAAAAAwAuaWRhdGEkNQACAAAIAAAAAwAuaWRhdGEkNKgAAAAIAAAAAwAuaWRhdGEkNuYDAAAIAAAAAwAudGV4dAAAAPBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN2AFAAAIAAAAAwAuaWRhdGEkNfgBAAAIAAAAAwAuaWRhdGEkNKAAAAAIAAAAAwAuaWRhdGEkNtQDAAAIAAAAAwAudGV4dAAAAPhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN1wFAAAIAAAAAwAuaWRhdGEkNfABAAAIAAAAAwAuaWRhdGEkNJgAAAAIAAAAAwAuaWRhdGEkNsYDAAAIAAAAAwAudGV4dAAAAABtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN1gFAAAIAAAAAwAuaWRhdGEkNegBAAAIAAAAAwAuaWRhdGEkNJAAAAAIAAAAAwAuaWRhdGEkNr4DAAAIAAAAAwAudGV4dAAAAAhtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN1QFAAAIAAAAAwAuaWRhdGEkNeABAAAIAAAAAwAuaWRhdGEkNIgAAAAIAAAAAwAuaWRhdGEkNqgDAAAIAAAAAwAudGV4dAAAABBtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN1AFAAAIAAAAAwAuaWRhdGEkNdgBAAAIAAAAAwAuaWRhdGEkNIAAAAAIAAAAAwAuaWRhdGEkNpgDAAAIAAAAAwAudGV4dAAAABhtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN0wFAAAIAAAAAwAuaWRhdGEkNdABAAAIAAAAAwAuaWRhdGEkNHgAAAAIAAAAAwAuaWRhdGEkNoADAAAIAAAAAwAudGV4dAAAACBtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN0gFAAAIAAAAAwAuaWRhdGEkNcgBAAAIAAAAAwAuaWRhdGEkNHAAAAAIAAAAAwAuaWRhdGEkNmwDAAAIAAAAAwAudGV4dAAAAChtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN0QFAAAIAAAAAwAuaWRhdGEkNcABAAAIAAAAAwAuaWRhdGEkNGgAAAAIAAAAAwAuaWRhdGEkNlADAAAIAAAAAwAudGV4dAAAADBtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN0AFAAAIAAAAAwAuaWRhdGEkNbgBAAAIAAAAAwAuaWRhdGEkNGAAAAAIAAAAAwAuaWRhdGEkNj4DAAAIAAAAAwAudGV4dAAAADhtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkNzwFAAAIAAAAAwAuaWRhdGEkNbABAAAIAAAAAwAuaWRhdGEkNFgAAAAIAAAAAwAuaWRhdGEkNi4DAAAIAAAAAwAudGV4dAAAAEBtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkNzgFAAAIAAAAAwAuaWRhdGEkNagBAAAIAAAAAwAuaWRhdGEkNFAAAAAIAAAAAwAuaWRhdGEkNiADAAAIAAAAAwAudGV4dAAAAEhtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkNzQFAAAIAAAAAwAuaWRhdGEkNaABAAAIAAAAAwAuaWRhdGEkNEgAAAAIAAAAAwAuaWRhdGEkNggDAAAIAAAAAwAudGV4dAAAAFBtAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkNzAFAAAIAAAAAwAuaWRhdGEkNZgBAAAIAAAAAwAuaWRhdGEkNEAAAAAIAAAAAwAuaWRhdGEkNvACAAAIAAAAAwAuZmlsZQAAAB0FAAD+/wAAZwFmYWtlAAAAAAAAAAAAAAAAAABobmFtZQAAAEAAAAAIAAAAAwBmdGh1bmsAAJgBAAAIAAAAAwAudGV4dAAAAGBtAAABAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuZGF0YQAAALAAAAACAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuYnNzAAAAAJALAAAGAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkMgAAAAAIAAAAAwEUAAAAAwAAAAAAAAAAAAAAAAAuaWRhdGEkNEAAAAAIAAAAAwAuaWRhdGEkNZgBAAAIAAAAAwAuZmlsZQAAACsFAAD+/wAAZwFmYWtlAAAAAAAAAAAAAAAAAAAudGV4dAAAAGBtAAABAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuZGF0YQAAALAAAAACAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuYnNzAAAAAJALAAAGAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkNLgAAAAIAAAAAwEIAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkNRACAAAIAAAAAwEIAAAAAAAAAAAAAAAAAAAAAAAuaWRhdGEkN2wFAAAIAAAAAwENAAAAAAAAAAAAAAAAAAAAAAAuZmlsZQAAAD8FAAD+/wAAZwFjeWdtaW5nLWNydGVuZAAAAAAAAAAAgwkAAGBtAAABACAAAwEAAAAAAAAAAAAAAAAAAAAAAAAudGV4dAAAAGBtAAABAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuZGF0YQAAALAAAAACAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAuYnNzAAAAAJALAAAGAAAAAwEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAlwkAAGBtAAABAAAAAwEFAAAAAQAAAAAAAAAAAAAAAAAAAAAApQkAAOAEAAAFAAAAAwEEAAAAAAAAAAAAAAAAAAAAAAAAAAAAtAkAAFAEAAAEAAAAAwEMAAAAAwAAAAAAAAAAAAAAAAAAAAAAwwkAAHhtAAABAAAAAwEIAAAAAQAAAAAAAAAAAAAAAAAAAAAAZAIAAHAMAAADAAAAAwEUAAAAAAAAAAAAAAAAAAAAAABfX3hjX3oAAAgAAAAJAAAAAgAAAAAA0AkAAJAMAAADAAAAAgAAAAAA7wkAAFgCAAAIAAAAAgAAAAAA+wkAAGwFAAAIAAAAAgAAAAAAFwoAAAAAAAACAAAAAgAAAAAAJgoAAIhtAAABAAAAAgAAAAAANQoAACACAAAIAAAAAgAAAAAATgoAAEgCAAAIAAAAAgAAAAAAWgoAACBtAAABAAAAAgAAAAAAawoAABQAAAAIAAAAAgBzdHJlcnJvcrhsAAABACAAAgAAAAAAhwoAAGACAAAIAAAAAgBfbG9jawAAAEBsAAABACAAAgAAAAAAlAoAANgBAAAIAAAAAgAAAAAApwoAAAAAAAAKAAAAAgAAAAAAtgoAAHAIAAADAAAAAgBfX3hsX2EAACgAAAAJAAAAAgAAAAAA1QoAADhtAAABAAAAAgAAAAAA4goAAJAMAAADAAAAAgB3Y3NsZW4AANhsAAABACAAAgAAAAAA9goAAGABAAD//wAAAgAAAAAADgsAAAAQAAD//wAAAgAAAAAAJwsAAAAAAAACAAAAAgAAAAAAPQsAACBsAAABACAAAgAAAAAASAsAAAAAIAD//wAAAgAAAAAAYgsAAAUAAAD//wAAAgAAAAAAfgsAACgAAAAJAAAAAgAAAAAAkAsAAJgBAAAIAAAAAgBfX3hsX2QAADgAAAAJAAAAAgBfdGxzX2VuZAgAAAAKAAAAAgAAAAAArAsAAPAHAAADAAAAAgAAAAAAwgsAAIACAAAIAAAAAgAAAAAAzgsAAOhsAAABAAAAAgAAAAAA2wsAABAAAAAJAAAAAgAAAAAA7QsAADACAAAIAAAAAgAAAAAA/gsAACgAAAAJAAAAAgAAAAAADgwAADgCAAAIAAAAAgAAAAAAGwwAAAAAAAAKAAAAAgBtZW1jcHkAAKBsAAABACAAAgAAAAAAJgwAABAIAAADAAAAAgBtYWxsb2MAAJhsAAABACAAAgAAAAAATAwAAHAAAAACAAAAAgBfQ1JUX01UADAAAAACAAAAAgAAAAAAXwwAAPhsAAABAAAAAgAAAAAAawwAAAAAAAAGAAAAAgAAAAAAeQwAAOABAAAIAAAAAgAAAAAAkwwAAJAMAAADAAAAAgAAAAAAtgwAAAAQAAD//wAAAgAAAAAAzgwAALABAAAIAAAAAgAAAAAA4QwAAMgAAAAGAAAAAgAAAAAA+wwAAIgCAAAIAAAAAgAAAAAABg0AABhsAAABACAAAgAAAAAAGQ0AAEAIAAADAAAAAgAAAAAAMg0AAMAAAAAGAAAAAgAAAAAASw0AAKAGAAADAAAAAgBmZmx1c2gAAGhsAAABACAAAgAAAAAAVg0AAPBsAAABAAAAAgAAAAAAZQ0AAEgAAAAJAAAAAgAAAAAAdw0AANABAAAIAAAAAgBhYm9ydAAAAFBsAAABACAAAgAAAAAAkg0AAAAIAAADAAAAAgAAAAAAvA0AAEgAAAAJAAAAAgBfX2RsbF9fAAAAAAD//wAAAgAAAAAAzA0AAAAAAAD//wAAAgAAAAAA4Q0AAEhtAAABAAAAAgAAAAAA9g0AALAIAAADAAAAAgAAAAAABQ4AAOAHAAADAAAAAgAAAAAAFQ4AAAAQAAD//wAAAgAAAAAAKw4AACQAAAACAAAAAgBjYWxsb2MAAFhsAAABACAAAgAAAAAAQw4AAMACAAADAAAAAgAAAAAATQ4AALACAAAIAAAAAgAAAAAAWg4AAPACAAAIAAAAAgAAAAAAZg4AAHgAAAACAAAAAgAAAAAAdw4AAKgCAAAIAAAAAgAAAAAAhA4AAJAMAAADAAAAAgAAAAAAog4AAOQFAAAIAAAAAgAAAAAAwA4AAMACAAAIAAAAAgBTbGVlcAAAAABtAAABAAAAAgAAAAAAzw4AALAAAAACAAAAAgAAAAAA3A4AAJACAAAIAAAAAgAAAAAA6Q4AAHBtAAABAAAAAgAAAAAA9w4AAAAAAAAIAAAAAgAAAAAAEQ8AAJALAAAGAAAAAgBfX3hpX3oAACAAAAAJAAAAAgAAAAAAHQ8AAGAHAAADAAAAAgBwY2luaXQAABgAAAAJAAAAAgAAAAAALA8AACAAAAACAAAAAgAAAAAARA8AABAAAAAJAAAAAgAAAAAAVA8AAGAIAAADAAAAAgAAAAAAcg8AAKABAAAIAAAAAgAAAAAAjQ8AAMwAAAAGAAAAAgAAAAAAmA8AALgAAAAGAAAAAgAAAAAArw8AAAAAAAAJAAAAAgBzdHJuY21wAMhsAAABACAAAgAAAAAAwQ8AALgBAAAIAAAAAgAAAAAA1g8AAHBtAAABAAAAAgAAAAAA5Q8AACAIAAADAAAAAgAAAAAABRAAAJgAAAACAAAAAgByZWFsbG9jALBsAAABACAAAgAAAAAAJRAAAAAAAAD//wAAAgAAAAAAOBAAAAgCAAAIAAAAAgAAAAAAUhAAAMgCAAAIAAAAAgAAAAAAXxAAAKAHAAADAAAAAgAAAAAAbRAAAKACAAAIAAAAAgAAAAAAehAAAAACAAD//wAAAgAAAAAAjRAAAMABAAAIAAAAAgAAAAAArRAAALgCAAAIAAAAAgAAAAAAuxAAAChtAAABAAAAAgAAAAAA1RAAABBsAAABACAAAgBmb3BlbgAAAHBsAAABACAAAgBtZW1zZXQAAKhsAAABACAAAgAAAAAA6RAAANgCAAAIAAAAAgAAAAAA+BAAAAQAAAD//wAAAgAAAAAADREAAMgBAAAIAAAAAgBmY2xvc2UAAGBsAAABACAAAgAAAAAAJBEAAJgBAAAIAAAAAgAAAAAAMhEAABBtAAABAAAAAgBfX3hsX3oAAEAAAAAJAAAAAgBfX2VuZF9fAAAAAAAAAAAAAgAAAAAAPxEAADBtAAABAAAAAgAAAAAAThEAAIhtAAABAAAAAgAAAAAAXBEAAKAAAAACAAAAAgBfX3hpX2EAABAAAAAJAAAAAgAAAAAAexEAAOBsAAABAAAAAgAAAAAAjxEAAOgBAAAIAAAAAgAAAAAAmxEAABhtAAABAAAAAgBfX3hjX2EAAAAAAAAJAAAAAgAAAAAAsBEAAAAAEAD//wAAAgAAAAAAyREAAEgAAAAJAAAAAgAAAAAA2xEAAAMAAAD//wAAAgAAAAAA6REAAChsAAABACAAAgAAAAAA9BEAAPABAAAIAAAAAgAAAAAABhIAAJAAAAACAAAAAgAAAAAAIhIAAAhtAAABAAAAAgAAAAAANhIAAKgBAAAIAAAAAgAAAAAASBIAAPgBAAAIAAAAAgBmcHV0YwAAAHhsAAABACAAAgBfX3hsX2MAADAAAAAJAAAAAgAAAAAAXRIAABAAAAAKAAAAAgAAAAAAahIAAAACAAAIAAAAAgAAAAAAfRIAAEACAAAIAAAAAgAAAAAAjRIAAGgCAAAIAAAAAgAAAAAAmhIAAMQAAAAGAAAAAgAAAAAAsxIAACgCAAAIAAAAAgAAAAAAxBIAAJgCAAAIAAAAAgAAAAAA1RIAAJBsAAABACAAAgAAAAAA4BIAAKACAAADAAAAAgAAAAAA+BIAADAIAAADAAAAAgAAAAAADxMAADhsAAABACAAAgBmd3JpdGUAAIhsAAABACAAAgAAAAAAGRMAANACAAAIAAAAAgAAAAAAJxMAAIAAAAACAAAAAgAAAAAAPRMAAAAAAAD//wAAAgAAAAAAVRMAAAAAAAD//wAAAgAAAAAAZhMAAIAIAAADAAAAAgAAAAAAeRMAANAWAAABAAAAAgAAAAAAhhMAALAAAAAGAAAAAgAAAAAAnBMAAFAIAAADAAAAAgAAAAAAvBMAAOACAAAIAAAAAgAAAAAAyRMAABgCAAAIAAAAAgAAAAAA4xMAAJAMAAADAAAAAgAAAAAA9RMAAAIAAAD//wAAAgAAAAAAERQAAHACAAAIAAAAAgAAAAAAHhQAAAAAAAD//wAAAgAAAAAANhQAAFACAAAIAAAAAgBfZXJybm8AADBsAAABACAAAgAAAAAARBQAAJAIAAADAAAAAgBzdHJsZW4AAMBsAAABACAAAgAAAAAAUxQAAMAIAAADAAAAAgAAAAAAYhQAAEBtAAABAAAAAgAAAAAAbhQAAFBtAAABAAAAAgAAAAAAhBQAAJAMAAADAAAAAgAAAAAAphQAAHgCAAAIAAAAAgBfdW5sb2NrAEhsAAABACAAAgAAAAAAshQAAKAIAAADAAAAAgAAAAAAwRQAAEgAAAAJAAAAAgB2ZnByaW50ZtBsAAABACAAAgBmcmVlAAAAAIBsAAABACAAAgAAAAAA0RQAANAAAAAGAAAAAgDiFAAALmRlYnVnX2FyYW5nZXMALmRlYnVnX2luZm8ALmRlYnVnX2FiYnJldgAuZGVidWdfbGluZQAuZGVidWdfZnJhbWUALmRlYnVnX3N0cgAuZGVidWdfbGluZV9zdHIALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19ybmdsaXN0cwBwcmVfY19pbml0AGF0ZXhpdF90YWJsZQBfQ1JUX0lOSVQAX19wcm9jX2F0dGFjaGVkAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawAucmRhdGEkLnJlZnB0ci5fX25hdGl2ZV9zdGFydHVwX3N0YXRlAC5yZGF0YSQucmVmcHRyLl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZGF0YSQucmVmcHRyLl9feGlfegAucmRhdGEkLnJlZnB0ci5fX3hpX2EALnJkYXRhJC5yZWZwdHIuX194Y196AC5yZGF0YSQucmVmcHRyLl9feGNfYQBfX0RsbE1haW5DUlRTdGFydHVwAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX2RsbG1haW5fcmVhc29uAERsbE1haW5DUlRTdGFydHVwAC5yZGF0YSQucmVmcHRyLl9fbWluZ3dfYXBwX3R5cGUALkNSVCRYSUFBAC5kZWJ1Z19pbmZvAC5kZWJ1Z19hYmJyZXYALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19hcmFuZ2VzAC5kZWJ1Z19ybmdsaXN0cwAuZGVidWdfbGluZQAuZGVidWdfc3RyAC5kZWJ1Z19saW5lX3N0cgAucmRhdGEkenp6AC5kZWJ1Z19mcmFtZQBfX2djY19yZWdpc3Rlcl9mcmFtZQBfX2djY19kZXJlZ2lzdGVyX2ZyYW1lAHByb3h5X2luaXQAaW5pdGlhbGl6ZWQAZ19sb2NrUmVhZHkAcEdldFN0YXRlAGdfaW5pdExvY2sAcFNldFN0YXRlAFhJbnB1dEdldFN0YXRlAFhJbnB1dEdldENhcGFiaWxpdGllcwBYSW5wdXRTZXRTdGF0ZQBYSW5wdXRFbmFibGUAWElucHV0R2V0U3RhdGVFeABfX2RvX2dsb2JhbF9kdG9ycwBfX2RvX2dsb2JhbF9jdG9ycwAucmRhdGEkLnJlZnB0ci5fX0NUT1JfTElTVF9fAF9fZHluX3Rsc19kdG9yAF9fZHluX3Rsc19pbml0AC5yZGF0YSQucmVmcHRyLl9DUlRfTVQAX190bHJlZ2R0b3IAX19yZXBvcnRfZXJyb3IAbWFya19zZWN0aW9uX3dyaXRhYmxlAG1heFNlY3Rpb25zAF9wZWkzODZfcnVudGltZV9yZWxvY2F0b3IAd2FzX2luaXQuMAAucmRhdGEkLnJlZnB0ci5fX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfRU5EX18ALnJkYXRhJC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18ALnJkYXRhJC5yZWZwdHIuX19pbWFnZV9iYXNlX18AX19taW5nd3Rocl9ydW5fa2V5X2R0b3JzLnBhcnQuMABfX21pbmd3dGhyX2NzAGtleV9kdG9yX2xpc3QAX19fdzY0X21pbmd3dGhyX2FkZF9rZXlfZHRvcgBfX21pbmd3dGhyX2NzX2luaXQAX19fdzY0X21pbmd3dGhyX3JlbW92ZV9rZXlfZHRvcgBfX21pbmd3X1RMU2NhbGxiYWNrAHBzZXVkby1yZWxvYy1saXN0LmMAX1ZhbGlkYXRlSW1hZ2VCYXNlAF9GaW5kUEVTZWN0aW9uAF9GaW5kUEVTZWN0aW9uQnlOYW1lAF9fbWluZ3dfR2V0U2VjdGlvbkZvckFkZHJlc3MAX19taW5nd19HZXRTZWN0aW9uQ291bnQAX0ZpbmRQRVNlY3Rpb25FeGVjAF9HZXRQRUltYWdlQmFzZQBfSXNOb253cml0YWJsZUluQ3VycmVudEltYWdlAF9fbWluZ3dfZW51bV9pbXBvcnRfbGlicmFyeV9uYW1lcwBEbGxFbnRyeVBvaW50AF9fbWluZ3dfdmZwcmludGYAX19wZm9ybWF0X2N2dABfX3Bmb3JtYXRfcHV0YwBfX3Bmb3JtYXRfd3B1dGNoYXJzAF9fcGZvcm1hdF9wdXRjaGFycwBfX3Bmb3JtYXRfcHV0cwBfX3Bmb3JtYXRfZW1pdF9pbmZfb3JfbmFuAF9fcGZvcm1hdF94aW50LmlzcmEuMABfX3Bmb3JtYXRfaW50LmlzcmEuMABfX3Bmb3JtYXRfZW1pdF9yYWRpeF9wb2ludABfX3Bmb3JtYXRfZW1pdF9mbG9hdABfX3Bmb3JtYXRfZW1pdF9lZmxvYXQAX19wZm9ybWF0X2VmbG9hdABfX3Bmb3JtYXRfZmxvYXQAX19wZm9ybWF0X2dmbG9hdABfX3Bmb3JtYXRfZW1pdF94ZmxvYXQuaXNyYS4wAF9fbWluZ3dfcGZvcm1hdABfX3J2X2FsbG9jX0QyQQBfX25ydl9hbGxvY19EMkEAX19mcmVlZHRvYQBfX3F1b3JlbV9EMkEALnJkYXRhJC5yZWZwdHIuX190ZW5zX0QyQQBfX3JzaGlmdF9EMkEAX190cmFpbHpfRDJBAGR0b2FfbG9jawBkdG9hX0NTX2luaXQAZHRvYV9Dcml0U2VjAGR0b2FfbG9ja19jbGVhbnVwAF9fQmFsbG9jX0QyQQBwcml2YXRlX21lbQBwbWVtX25leHQAX19CZnJlZV9EMkEAX19tdWx0YWRkX0QyQQBfX2kyYl9EMkEAX19tdWx0X0QyQQBfX3BvdzVtdWx0X0QyQQBfX2xzaGlmdF9EMkEAX19jbXBfRDJBAF9fZGlmZl9EMkEAX19iMmRfRDJBAF9fZDJiX0QyQQBfX3N0cmNwX0QyQQBfbG9ja19maWxlAF91bmxvY2tfZmlsZQBfX2FjcnRfaW9iX2Z1bmMAX193Y3J0b21iX2NwAHdjc3J0b21icwBfaW5pdGlhbGl6ZV9vbmV4aXRfdGFibGUAX3JlZ2lzdGVyX29uZXhpdF9mdW5jdGlvbgBfZXhlY3V0ZV9vbmV4aXRfdGFibGUAX19tYnJ0b3djX2NwAGludGVybmFsX21ic3RhdGUuMgBtYnNydG93Y3MAaW50ZXJuYWxfbWJzdGF0ZS4xAHNfbWJzdGF0ZS4wAHJlZ2lzdGVyX2ZyYW1lX2N0b3IALnRleHQuc3RhcnR1cAAueGRhdGEuc3RhcnR1cAAucGRhdGEuc3RhcnR1cAAuY3RvcnMuNjU1MzUAX19fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9faW1wX2Fib3J0AF9fbGliNjRfbGlia2VybmVsMzJfYV9pbmFtZQBfX2RhdGFfc3RhcnRfXwBfX19EVE9SX0xJU1RfXwBfX2ltcF9fX19tYl9jdXJfbWF4X2Z1bmMAX19pbXBfX2xvY2sASXNEQkNTTGVhZEJ5dGVFeABfaGVhZF9saWI2NF9saWJtc3ZjcnRfZGVmX2EAX19pbXBfY2FsbG9jAF9faW1wX0xvYWRMaWJyYXJ5VwBfX190bHNfc3RhcnRfXwAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAR2V0TGFzdEVycm9yAF9fcnRfcHNyZWxvY3Nfc3RhcnQAX19kbGxfY2hhcmFjdGVyaXN0aWNzX18AX19zaXplX29mX3N0YWNrX2NvbW1pdF9fAF9fbWluZ3dfbW9kdWxlX2lzX2RsbABfX2lvYl9mdW5jAF9fc2l6ZV9vZl9zdGFja19yZXNlcnZlX18AX19tYWpvcl9zdWJzeXN0ZW1fdmVyc2lvbl9fAF9fX2NydF94bF9zdGFydF9fAF9faW1wX0RlbGV0ZUNyaXRpY2FsU2VjdGlvbgAucmVmcHRyLl9fQ1RPUl9MSVNUX18AX19pbXBfZnB1dGMAVmlydHVhbFF1ZXJ5AF9fX2NydF94aV9zdGFydF9fAF9faW1wX19hbXNnX2V4aXQAX19fY3J0X3hpX2VuZF9fAF9faW1wX19lcnJubwBfdGxzX3N0YXJ0AC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AX19pbXBfX3VubG9ja19maWxlAFRsc0dldFZhbHVlAF9fYnNzX3N0YXJ0X18AX19pbXBfTXVsdGlCeXRlVG9XaWRlQ2hhcgBfX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAF9fc2l6ZV9vZl9oZWFwX2NvbW1pdF9fAF9faW1wX0dldExhc3RFcnJvcgBfX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAF9faW1wX2ZyZWUAX19fbWJfY3VyX21heF9mdW5jAC5yZWZwdHIuX19taW5nd19hcHBfdHlwZQBfX21pbmd3X2luaXRsdHNzdW9fZm9yY2UAX190ZW5zX0QyQQBWaXJ0dWFsUHJvdGVjdABfX19jcnRfeHBfc3RhcnRfXwBfX2ltcF9MZWF2ZUNyaXRpY2FsU2VjdGlvbgAucmVmcHRyLl9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX19jcnRfeHBfZW5kX18AX19taW5vcl9vc192ZXJzaW9uX18ARW50ZXJDcml0aWNhbFNlY3Rpb24ALnJlZnB0ci5fX3hpX2EALnJlZnB0ci5fQ1JUX01UAF9fc2VjdGlvbl9hbGlnbm1lbnRfXwBfX25hdGl2ZV9kbGxtYWluX3JlYXNvbgBfdGxzX3VzZWQAX19pbXBfbWVtc2V0AF9fSUFUX2VuZF9fAF9faW1wX19sb2NrX2ZpbGUAX19pbXBfbWVtY3B5AF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9fbGliNjRfbGlibXN2Y3J0X2RlZl9hX2luYW1lAF9faW1wX3N0cmVycm9yAF9fZGF0YV9lbmRfXwBfX2ltcF9md3JpdGUAX19DVE9SX0xJU1RfXwBfaGVhZF9saWI2NF9saWJrZXJuZWwzMl9hAF9fYnNzX2VuZF9fAF9fdGlueXRlbnNfRDJBAF9fbmF0aXZlX3ZjY2xyaXRfcmVhc29uAF9fX2NydF94Y19lbmRfXwAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawBfX2ltcF9FbnRlckNyaXRpY2FsU2VjdGlvbgBfdGxzX2luZGV4AF9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAX19fY3J0X3hjX3N0YXJ0X18AX19pbXBfR2V0UHJvY0FkZHJlc3MAX19fQ1RPUl9MSVNUX18ALnJlZnB0ci5fX2R5bl90bHNfaW5pdF9jYWxsYmFjawBfX2ltcF9fcmVnaXN0ZXJfb25leGl0X2Z1bmN0aW9uAF9fcnRfcHNyZWxvY3Nfc2l6ZQBfX2ltcF9XaWRlQ2hhclRvTXVsdGlCeXRlAF9faW1wX3N0cmxlbgBfX2JpZ3RlbnNfRDJBAF9faW1wX21hbGxvYwBfX2ZpbGVfYWxpZ25tZW50X18AX19pbXBfSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9yZWFsbG9jAEluaXRpYWxpemVDcml0aWNhbFNlY3Rpb24AX19fbGNfY29kZXBhZ2VfZnVuYwBfX2ltcF92ZnByaW50ZgBfX21ham9yX29zX3ZlcnNpb25fXwBfX2ltcF9Jc0RCQ1NMZWFkQnl0ZUV4AF9fSUFUX3N0YXJ0X18ATG9hZExpYnJhcnlXAEdldFByb2NBZGRyZXNzAF9fRFRPUl9MSVNUX18AX19pbXBfX2luaXRpYWxpemVfb25leGl0X3RhYmxlAFdpZGVDaGFyVG9NdWx0aUJ5dGUAX19pbXBfU2xlZXAATGVhdmVDcml0aWNhbFNlY3Rpb24AX19zaXplX29mX2hlYXBfcmVzZXJ2ZV9fAF9fX2NydF94dF9zdGFydF9fAF9fc3Vic3lzdGVtX18AX2Ftc2dfZXhpdABfX2ltcF9UbHNHZXRWYWx1ZQBfX2ltcF9fZXhlY3V0ZV9vbmV4aXRfdGFibGUATXVsdGlCeXRlVG9XaWRlQ2hhcgBfX2ltcF9GcmVlTGlicmFyeQBfX2ltcF9WaXJ0dWFsUHJvdGVjdABfX190bHNfZW5kX18AX19pbXBfVmlydHVhbFF1ZXJ5AF9faW1wX19pbml0dGVybQBfX2ltcF9mY2xvc2UAX19taW5nd19pbml0bHRzZHluX2ZvcmNlAF9faW1wX19faW9iX2Z1bmMAX19pbXBfbG9jYWxlY29udgBsb2NhbGVjb252AF9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZWZwdHIuX19pbWFnZV9iYXNlX18AX2luaXR0ZXJtAF9faW1wX3N0cm5jbXAAX19pbXBfX19hY3J0X2lvYl9mdW5jAF9fbWFqb3JfaW1hZ2VfdmVyc2lvbl9fAF9fbG9hZGVyX2ZsYWdzX18ALnJlZnB0ci5fX3RlbnNfRDJBAF9fX2Noa3N0a19tcwBfX25hdGl2ZV9zdGFydHVwX2xvY2sALnJlZnB0ci5fX25hdGl2ZV9kbGxtYWluX3JlYXNvbgBfX2ltcF93Y3NsZW4AX19pbXBfX19fbGNfY29kZXBhZ2VfZnVuYwBfX3J0X3BzcmVsb2NzX2VuZABfX21pbm9yX3N1YnN5c3RlbV92ZXJzaW9uX18AX19pbXBfZmZsdXNoAF9fbWlub3JfaW1hZ2VfdmVyc2lvbl9fAF9faW1wX191bmxvY2sALnJlZnB0ci5fX3hjX2EALnJlZnB0ci5fX3hpX3oARnJlZUxpYnJhcnkARGVsZXRlQ3JpdGljYWxTZWN0aW9uAF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX2ltcF9mb3BlbgAucmVmcHRyLl9feGNfegBfX19jcnRfeHRfZW5kX18AX19taW5nd19hcHBfdHlwZQA=
XDLL_B64_EOF
    verify_sha256 "${xdll_tmp}" "${XINPUT_DLL_SHA256}"
    mv "${xdll_tmp}" "${xdll_dst}"
    ok_msg "xinput1_3.dll installed."
    fi

    # NOTE: xinput1_3.dll is placed into the Wine prefix system32 in Step 3,
    # after wineboot has run and the prefix is fully initialised. Proton creates
    # system32 as a symlink during prefix initialisation; copying into it before
    # wineboot runs follows a dangling symlink and fails with:
    #   cp: not writing through dangling symlink '…/system32/xinput1_3.dll'
    # Step 3 calls install_xinput_dll() after wineboot completes.
  fi

    # --------------------------------------------------------------------------
  # Step 7 — Synchronizing game assets
  #
  # Fetches high-quality icons, grid art, and hero images from Steam's CDN.
  # These are used for both the desktop shortcut and the Steam non-Steam game
  # entry for a professional look.
  # --------------------------------------------------------------------------
  step_msg "Step 7 — Synchronizing game assets..."

  mkdir -p "${ICON_DIR}"
  mkdir -p "${STEAM_ASSETS_DIR}"

  if command_exists curl; then
    info_msg "Synchronizing assets from Steam CDN..."

    # Download each asset individually so a single failure doesn't abort the rest.
    # '|| true' ensures the script continues even if the CDN is temporarily down.
    curl ${CURL_FLAGS}f -o "${STEAM_LOGO_PATH}"   "${STEAM_LOGO_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_GRID_PATH}"   "${STEAM_GRID_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_HERO_PATH}"   "${STEAM_HERO_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_WIDE_PATH}"   "${STEAM_WIDE_URL}"   || true
    curl ${CURL_FLAGS}f -o "${STEAM_HEADER_PATH}" "${STEAM_HEADER_URL}" || true

    # Download the game's ICO from Steam's community assets (32×32, authoritative
    # icon Steam itself uses). The ICO is kept for the Steam shortcuts.vdf "icon"
    # Install the game icon into the XDG hicolor icon theme so desktop
    # environments (GNOME, KDE, XFCE) find it reliably by name. Icons must
    # live in a theme subdirectory — the DE resolves Icon=cluckers-central
    # (no path, no extension) through the theme cache at runtime.
    #
    # Icon source: 1.ico extracted from the game EXE via unzip.
    # The Realm Royale shipping EXE is packaged in a format that unzip can
    # read directly. The icon is stored at the path .rsrc/ICON/1.ico inside
    # the archive and contains multiple frames (32×32, 256×256, etc.),
    # giving a crisp native icon at every size slot without any upscaling.
    #
    # We install:
    #   hicolor/32x32/apps/cluckers-central.png  — taskbar / panel icon.
    #   hicolor/256x256/apps/cluckers-central.png — HiDPI application grid.
    #   ICON_PATH (flat PNG)                      — absolute-path fallback
    #     for desktop environments that resolve Icon= by path before theme.
    #
    # The Steam CDN ICO (STEAM_ICO_PATH) is still downloaded because Steam's
    # shortcuts.vdf requires a path to an ICO file in its "icon" field.
    # Download the Steam CDN ICO for shortcuts.vdf (not used as desktop icon).
    curl ${CURL_FLAGS}f -o "${STEAM_ICO_PATH}" "${STEAM_ICO_URL}" || true

    # Extract the game icon from the EXE and install it as the desktop icon.
    # The Realm Royale EXE stores its icon at .rsrc/ICON/1.ico in a format
    # that unzip can read directly. The ICO contains multiple frames
    # (32×32, 256×256, etc.). We convert the largest frame to PNG using
    # Pillow because most Linux DEs do not render ICO reliably via Icon=.
    # The PNG is installed to ICON_PATH and also into the hicolor theme so
    # the DE finds it by name (Icon=cluckers-central in the .desktop file).
    local _game_exe="${GAME_DIR}/${GAME_EXE_REL}"
    local _exe_ico="${STEAM_ASSETS_DIR}/icon_exe.ico"
    mkdir -p "${ICON_DIR}/hicolor/256x256/apps"
    if [[ ! -f "${_game_exe}" ]]; then
      warn_msg "Game EXE not found — desktop icon cannot be installed yet."
      warn_msg "Re-run setup after downloading the game to install the icon."
    elif ! command_exists unzip; then
      warn_msg "unzip not found — desktop icon cannot be installed."
      warn_msg "Install unzip: sudo apt install unzip  (or your distro's equivalent)"
    else
      # Extract the icon from the game EXE using a Python PE resource parser.
      # The EXE is a standard Windows PE binary — not a zip archive — so
      # tools like unzip or 7z cannot read its resources. We parse the PE
      # .rsrc section directly using Python's struct module (stdlib only),
      # extract RT_GROUP_ICON (type 14) and RT_ICON (type 3) frames, assemble
      # a valid ICO file in memory, and save the largest frame as PNG.
      PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}" \
      python3 - "${_game_exe}" "${ICON_PATH}" \
                 "${ICON_DIR}/hicolor/256x256/apps/cluckers-central.png" << 'ICOEXT_EOF'
import struct, sys, shutil, io
from PIL import Image

def extract_pe_group_icon(path, group_id=1):
    """Parse a Windows PE binary and extract an icon group as ICO bytes."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:2] != b'MZ':
        raise ValueError("Not a PE file")
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe_off:pe_off+4] != b'PE\x00\x00':
        raise ValueError("Bad PE signature")
    num_sects = struct.unpack_from('<H', data, pe_off + 6)[0]
    opt_sz    = struct.unpack_from('<H', data, pe_off + 20)[0]
    magic     = struct.unpack_from('<H', data, pe_off + 24)[0]
    dd_base   = pe_off + 24 + (112 if magic == 0x20B else 96)
    rsrc_rva  = struct.unpack_from('<I', data, dd_base + 16)[0]
    rsrc_vaddr = rsrc_foff = 0
    sect_base = pe_off + 24 + opt_sz
    for i in range(num_sects):
        s   = sect_base + i * 40
        va  = struct.unpack_from('<I', data, s + 12)[0]
        rsz = struct.unpack_from('<I', data, s + 16)[0]
        rof = struct.unpack_from('<I', data, s + 20)[0]
        if va <= rsrc_rva < va + rsz:
            rsrc_vaddr, rsrc_foff = va, rof
            break
    if rsrc_foff == 0:
        raise ValueError("No .rsrc section")
    def rva2off(rva): return rsrc_foff + (rva - rsrc_vaddr)
    def read_dir(off):
        named = struct.unpack_from('<H', data, off + 12)[0]
        ident = struct.unpack_from('<H', data, off + 14)[0]
        return [(struct.unpack_from('<I', data, off+16+i*8)[0] & 0x7FFFFFFF,
                 struct.unpack_from('<I', data, off+16+i*8+4)[0] & 0x7FFFFFFF,
                 bool(struct.unpack_from('<I', data, off+16+i*8+4)[0] & 0x80000000))
                for i in range(named + ident)]
    def get_res(type_id, res_id):
        root_dir = read_dir(rsrc_foff)
        td = next((rsrc_foff+o for i,o,s in root_dir if i==type_id and s), None)
        if td is None: return None
        type_dir = read_dir(td)
        # If requested res_id not found, pick the first available ID
        if not any(i == res_id for i,o,s in type_dir):
            if not type_dir: return None
            res_id = type_dir[0][0]
        id_dir = next((rsrc_foff+o for i,o,s in type_dir if i==res_id and s), None)
        if id_dir is None: return None
        langs = read_dir(id_dir)
        if not langs: return None
        _, doff, is_sub = langs[0]
        if is_sub: return None
        eoff = rsrc_foff + doff
        rva  = struct.unpack_from('<I', data, eoff)[0]
        size = struct.unpack_from('<I', data, eoff+4)[0]
        return data[rva2off(rva):rva2off(rva)+size]
    grp = get_res(14, group_id)
    if not grp: raise ValueError("No icon groups found in .rsrc")
    count = struct.unpack_from('<H', grp, 4)[0]
    frames = []
    for i in range(count):
        e = 6 + i*14
        w,h,col = struct.unpack_from('<BBB', grp, e)
        planes,bpp = struct.unpack_from('<HH', grp, e+4)
        icon_id = struct.unpack_from('<H', grp, e+12)[0]
        dib = get_res(3, icon_id)
        if dib: frames.append((w,h,col,planes,bpp,dib))
    if not frames: raise ValueError("No icon frames extracted")
    n = len(frames); data_off = 6 + 16*n
    hdr = struct.pack('<HHH', 0, 1, n)
    dirs = b''; imgs = b''
    for w,h,col,planes,bpp,dib in frames:
        dirs += struct.pack('<BBBBHHII', w,h,col,0,planes,bpp,len(dib),data_off+len(imgs))
        imgs += dib
    return hdr + dirs + imgs

try:
    exe   = sys.argv[1]
    flat  = sys.argv[2]
    hi    = sys.argv[3]
    ico   = extract_pe_group_icon(exe, 1)
    img   = Image.open(io.BytesIO(ico))
    # img.ico.sizes() might not exist in all PIL versions, fallback to img.size
    if hasattr(img, 'ico') and hasattr(img.ico, 'sizes') and img.ico.sizes():
        sizes = sorted(img.ico.sizes(), key=lambda s: s[0]*s[1], reverse=True)
    else:
        sizes = [img.size]
    
    if hasattr(img, 'ico') and hasattr(img.ico, 'getimage'):
        frame = img.ico.getimage(sizes[0]).convert('RGBA')
    else:
        frame = img.convert('RGBA')
        
    frame.save(flat, 'PNG')
    shutil.copy2(flat, hi)
    print(f"[icon] {frame.width}x{frame.height} PNG from PE .rsrc installed.")
    sys.exit(0)
except Exception as e:
    print(f"[icon] PE icon extraction failed: {e}", file=sys.stderr)
    sys.exit(1)
ICOEXT_EOF
      if [[ $? -eq 0 ]]; then
        ok_msg "Game icon installed at ${ICON_PATH}."
      else
        warn_msg "Could not extract icon from game EXE — desktop icon will be missing."
        warn_msg "Ensure python3 and Pillow (pip install pillow) are available."
      fi
    fi

    # Refresh the icon theme cache so the new icon appears immediately.
    if command_exists gtk-update-icon-cache; then
      gtk-update-icon-cache -f -t "${ICON_DIR}/hicolor" 2>/dev/null || true
    fi

    # Copy the portrait poster to ICON_POSTER_PATH for Steam grid artwork only.
    if [[ -f "${STEAM_GRID_PATH}" ]]; then
      cp "${STEAM_GRID_PATH}" "${ICON_POSTER_PATH}"
      ok_msg "High-quality Steam assets downloaded."
    else
      warn_msg "Grid poster unavailable — portrait poster slot will be empty."
    fi

  fi

  # --------------------------------------------------------------------------
  # Step 8 — Create launcher script
  #
  # Writes ~/.local/bin/cluckers-central.sh — a small shell script that:
  #   1. Writes the .env file so the launcher uses the local proxy.
  #   2. Starts the gateway proxy in the background and stops it on exit.
  #   3. Launches Cluckers Central under Wine, optionally wrapped in Gamescope.
  #
  # Two heredoc styles are used:
  #   Double-quoted (EOF)   — values expanded NOW at setup time (paths, flags).
  #   Single-quoted ('EOF') — code written literally, variables expand at
  #                           LAUNCH TIME when the generated script runs.
  #
  # Environment variables set in the launcher:
  #   WINE_NTSYNC=1 — enables NT sync primitives (requires a modern kernel).
  #   WINEFSYNC=1   — enables futex-based sync (standard GE-Proton fallback).
  # --------------------------------------------------------------------------
  step_msg "Step 8 — Creating launcher script..."

  # Wine/Proton was detected upfront in main() before Step 3.
  # real_wine_path, _is_proton, and _proton_tool_name are already set.
  [[ -z "${real_wine_path}" ]] && \
    error_exit "No Proton found. Install a Proton build via Steam or ProtonUp-Qt."
  ok_msg "Wine binary (Proton): ${real_wine_path}"
  ok_msg "Proton compat tool name: ${_proton_tool_name}"
  # Sync primitives: ntsync (modern) or fsync (standard Proton fallback).
  if [[ "${_is_proton}" == "true" ]]; then
    if [[ -c /dev/ntsync ]]; then
      ok_msg "WINE_NTSYNC=1 will be set in the launcher (compatible kernel found)."
    else
      ok_msg "WINEFSYNC=1 will be set in the launcher."
    fi
  fi

  if [[ "${use_gamescope}" == "true" ]]; then
    if [[ "${controller_mode}" == "true" ]] && [[ "${steam_deck}" == "false" ]]; then
      ok_msg "Gamescope + controller support will be used in the launcher (--gamescope-with-controller)."
    else
      ok_msg "Gamescope compositor will be used in the launcher."
    fi
  fi

  mkdir -p "$(dirname "${LAUNCHER_SCRIPT}")"

  local real_wineserver
  real_wineserver="$(dirname "${real_wine_path}")/wineserver"
  [[ ! -x "${real_wineserver}" ]] && real_wineserver="wineserver"

  # Part 1: setup-time values baked in as plain strings.
  cat > "${LAUNCHER_SCRIPT}" << EOF
#!/usr/bin/env bash
# Cluckers Central launcher — generated by cluckers-setup.sh on $(date)
# Re-run cluckers-setup.sh to regenerate after updating Wine or the game.

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# Set PATH and LD_LIBRARY_PATH to include Wine's internal libraries and
# binaries so it can find essential DLLs like kernel32.dll even when run
# outside of Steam. We prepend them to any existing paths.
# We skip this if using a Proton script, as Proton handles its own environment.
$(
  if [[ -z "${real_proton_script}" ]]; then
    _env_adds="$(get_wine_env_additions "${real_wine_path}")"
    _bin_add="${_env_adds%%|*}"; _temp="${_env_adds#*|}"
    _lib_add="${_temp%%|*}"; _loader_add="${_env_adds##*|}"
    # shellcheck disable=SC2016
    printf 'export PATH="%s:${PATH}"\n' "${_bin_add}"
    # shellcheck disable=SC2016
    printf 'export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"\n' "${_lib_add}"
    printf 'export WINELOADER="%s"\n' "${_loader_add}"
  fi
)

export CLUCKERS_ROOT="${CLUCKERS_ROOT}"
export WINEPREFIX="${WINEPREFIX}"
export WINEARCH="win64"

# Setup-time variables baked in as plain strings.
USE_GAMESCOPE="${use_gamescope}"
GS_ARGS="${GAMESCOPE_ARGS}"
GAME_DIR="${GAME_DIR}"
GAME_EXE_REL="${GAME_EXE_REL}"
TOOLS_DIR="${TOOLS_DIR}"
GATEWAY_URL="${GATEWAY_URL:-https://gateway-dev.project-crown.com}"
HOST_X="${HOST_X:-157.90.131.105}"
CREDS_FILE="${CLUCKERS_ROOT}/credentials.enc"

# Suppress noisy Wine debug output. Set to "" to see full Wine diagnostics.
export WINEDEBUG="-all"

# dxgi=n,b:      use DXVK's dxgi instead of Wine's built-in (required for DX11 performance).
# d3d11=n,b:    use DXVK's d3d11 — prevents the "file not found" ntdll crash caused by
#               Wine's stub d3d11 calling missing ntdll entry points when the game calls
#               Direct3D 11. Without this, the game crashes on startup with an ntdll error.
# d3d10core=n,b: use DXVK's d3d10 implementation alongside d3d11 (they share the same
#               DXVK library; both must be set native or neither will work).
# xinput1_3=n:  use our custom xinput remapper installed in Step 6.
# winex11.drv=: disables the X11 driver in Wine. This is a fix for the "cursor 
#               spinning" problem when running in fullscreen (-f) on some 
#               Wayland-based systems. NOTE: This is only applied when Gamescope
#               is NOT used, as Gamescope requires the X11 driver to function.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/process.go
$(if [[ "${controller_mode}" == "true" || "${steam_deck}" == "true" ]]; then
  _overrides="dxgi=n;xinput1_3=n"
  if [[ "${use_gamescope}" == "false" ]]; then
    _overrides="${_overrides};winex11.drv="
  fi
  printf 'export WINEDLLOVERRIDES="%s"\n' "${_overrides}"
  # SDL_HINT_JOYSTICK_HIDAPI — when set to "0" disables SDL's HIDAPI driver for
  # all joysticks. Without this, Wine's winebus.sys and SDL's HIDAPI layer both
  # enumerate the same physical device, causing duplicate axis events and phantom
  # camera spin in UE3 games. SDL_HINT_JOYSTICK_HIDAPI_PS4 / _PS5 are per-device
  # overrides for the same hint applied specifically to DualShock 4 / DualSense.
  # Source (hint definition): https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_hints.h
  #   SDL_HINT_JOYSTICK_HIDAPI          ~line 828
  #   SDL_HINT_JOYSTICK_HIDAPI_PS4      ~line 969
  # Source (Wine SDL joystick backend): https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/winebus.sys/main.c
  printf 'export SDL_JOYSTICK_HIDAPI=0\n'
  printf 'export SDL_JOYSTICK_HIDAPI_PS4=0\n'
  printf 'export SDL_JOYSTICK_HIDAPI_PS5=0\n'
  # SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS — when set to "1", SDL continues
  # delivering joystick events even when the application window does not have
  # focus. UE3's ServerTravel (lobby→match transition) briefly defocuses the
  # window; without this hint SDL silences all joystick axis/button events during
  # that window, compounding the XInputEnable(FALSE) issue our xinput1_3.dll fixes.
  # Source: https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_hints.h
  #         SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS ~line 693
  printf 'export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1\n'
  # SDL_HINT_GAMECONTROLLERCONFIG_FILE — path to a community gamecontrollerdb.txt
  # mapping file. SDL reads this file to override built-in button/axis mappings
  # for any controller GUID. Fixes mis-mapped triggers, bumpers, and face buttons
  # on non-Xbox controllers under Wine's SDL layer.
  # Source: https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_hints.h
  #         SDL_HINT_GAMECONTROLLERCONFIG_FILE ~line 513
  # Community mapping database: https://github.com/gabomdq/SDL_GameControllerDB
  # If the file exists in a standard location we export the path so Wine/SDL picks it up.
  cat << 'SDLEOF'
_sdl_db=""
for _db_path in \
  "${HOME}/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
  "${HOME}/.config/SDL_GameControllerDB/gamecontrollerdb.txt" \
  "/usr/share/SDL_GameControllerDB/gamecontrollerdb.txt" \
  "/usr/local/share/SDL_GameControllerDB/gamecontrollerdb.txt"; do
  if [[ -f "${_db_path}" ]]; then _sdl_db="${_db_path}"; break; fi
done
[[ -n "${_sdl_db}" ]] && export SDL_GAMECONTROLLERCONFIG_FILE="${_sdl_db}"
SDLEOF
else
  _overrides="dxgi=n"
  if [[ "${use_gamescope}" == "false" ]]; then
    _overrides="${_overrides};winex11.drv="
  fi
  printf 'export WINEDLLOVERRIDES="%s"\n' "${_overrides}"
fi)

# Wine binary and optional Proton script resolved by find_wine() at setup time.
WINE="${real_wine_path}"
WINESERVER="${real_wineserver}"
PROTON_SCRIPT="${real_proton_script}"

# Sync primitives: ntsync (modern) or fsync (standard Proton fallback).
# These improve game performance and reduce stutter by optimizing how
# the game synchronizes background tasks with your CPU.
# Supported by most modern Proton builds.
$(if [[ "${_is_proton}" == "true" ]]; then
  # Use ntsync if /dev/ntsync exists (requires a modern Linux kernel 6.10+).
  # Otherwise fall back to fsync (standard Proton fallback).
  if [[ -c /dev/ntsync ]]; then
    printf 'export WINE_NTSYNC=1\n'
  else
    printf 'export WINEFSYNC=1\n'
  fi
fi)

# Ensure we run from the game directory for consistency.
cd "\${GAME_DIR}"

# Gamescope PID (if used).
_GS_PID=""    # PID of gamescope process group leader (gamescope path)
_WINE_PID=""  # PID of wine process group leader (non-gamescope path)
EOF


  # Part 2: launch-time auth + game launch logic.
  # Variables written in Part 1 expand at run time; this block is single-quoted
  # so it is stored verbatim and NOT expanded now.
  cat >> "${LAUNCHER_SCRIPT}" << 'LAUNCHEOF'

# ---------------------------------------------------------------------------
# Authentication — direct calls to the Project Crown gateway API.
# Handles login, OIDC token, and content bootstrap without a Windows launcher.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/auth/login.go
# ---------------------------------------------------------------------------
_auth_result=$(python3 - "${CREDS_FILE}" "${GATEWAY_URL}" << 'AUTHEOF'
import base64, json, os, sys, urllib.request, urllib.error

creds_file = sys.argv[1]
gateway    = sys.argv[2].rstrip("/")

def _post(endpoint, payload):
    # URL format: /json/<command>
    url  = f"{gateway}/json/{endpoint}"
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        url, data=data,
        headers={
            "Content-Type": "application/json",
            # User-Agent must match the Windows launcher to avoid server rejection.
            # Set the expected User-Agent so the gateway accepts the request.
            "User-Agent": "CluckersCentral/1.1.68",
            "Accept": "*/*",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def _flex_bool(val):
    if isinstance(val, bool):   return val
    if isinstance(val, (int, float)): return val != 0
    if isinstance(val, str):    return val.lower() in ("true", "1", "yes")
    return False

# Load or prompt for credentials.
username = password = ""
if os.path.exists(creds_file):
    try:
        with open(creds_file) as f:
            line = f.read().strip()
        username, password = line.split(":", 1)
    except Exception:
        pass

if not username or not password:
    # stdin is consumed by the heredoc pipe, so read from /dev/tty directly.
    # Open separate fds for reading and writing to avoid seekability issues.
    import termios, tty as ttymod
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        tty_r = os.fdopen(os.dup(tty_fd), "r", buffering=1, closefd=True)
        tty_w = os.fdopen(tty_fd,          "w", buffering=1, closefd=True)
    except OSError as e:
        print(f"ERROR: Cannot open /dev/tty: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        tty_w.write("[cluckers] Enter your Project Crown credentials.\n")
        tty_w.write("Username: ")
        tty_w.flush()
        username = tty_r.readline().rstrip("\n")
        tty_w.write("Password: ")
        tty_w.flush()
        old = termios.tcgetattr(tty_r)
        try:
            ttymod.setraw(tty_r)
            password = ""
            while True:
                ch = tty_r.read(1)
                if ch in ("\n", "\r"):
                    break
                if ch == "\x7f":  # backspace
                    password = password[:-1]
                else:
                    password += ch
        finally:
            termios.tcsetattr(tty_r, termios.TCSADRAIN, old)
            tty_w.write("\n")
            tty_w.flush()
    finally:
        tty_r.close()
        tty_w.close()
    os.makedirs(os.path.dirname(creds_file), exist_ok=True)
    def secure_opener(path, flags):
        return os.open(path, flags, 0o600)
    with open(creds_file, "w", opener=secure_opener) as f:
        f.write(f"{username}:{password}")

# Login — exchange credentials for an access token.
try:
    print("[auth] Logging in...", file=sys.stderr)
    login = _post("LAUNCHER_LOGIN_OR_LINK",
                  {"user_name": username, "password": password})
except urllib.error.URLError as e:
    print(f"ERROR: Cannot reach gateway ({e})", file=sys.stderr)
    sys.exit(1)

if not _flex_bool(login.get("SUCCESS")):
    msg = login.get("TEXT_VALUE") or "unknown error"
    print(f"ERROR: Login failed: {msg}", file=sys.stderr)
    try:
        os.remove(creds_file)
    except OSError:
        pass
    sys.exit(1)

access_token = login.get("ACCESS_TOKEN", "")
if not access_token:
    print("ERROR: No access token in login response", file=sys.stderr)
    sys.exit(1)

# OIDC token — required by EAC for anti-cheat authentication.
try:
    print("[auth] Requesting OIDC token...", file=sys.stderr)
    oidc_resp = _post("LAUNCHER_EAC_OIDC_TOKEN",
                      {"user_name": username, "access_token": access_token})
    oidc_token = (oidc_resp.get("PORTAL_INFO_1")
                  or oidc_resp.get("STRING_VALUE")
                  or oidc_resp.get("TEXT_VALUE", ""))
except Exception as e:
    print(f"[auth] OIDC token failed: {e}", file=sys.stderr)
    oidc_token = ""

# Content bootstrap — 136-byte blob the game reads from shared memory at startup.
bootstrap_b64 = ""
try:
    print("[auth] Requesting content bootstrap...", file=sys.stderr)
    boot_resp = _post("LAUNCHER_CONTENT_BOOTSTRAP",
                      {"user_name": username, "access_token": access_token})
    raw = (boot_resp.get("PORTAL_INFO_1") or boot_resp.get("STRING_VALUE", ""))
    if raw:
        # Fix base64 padding if needed.
        missing_padding = len(raw) % 4
        if missing_padding:
            raw += "=" * (4 - missing_padding)

        decoded = base64.b64decode(raw)
        if len(decoded) != 136:
            print(f"[auth] WARNING: Unexpected bootstrap size: {len(decoded)} bytes (expected 136)", file=sys.stderr)

        if len(decoded) > 0:
            bootstrap_b64 = base64.b64encode(decoded).decode()
            print(f"[auth] Bootstrap received ({len(decoded)} bytes)", file=sys.stderr)
except Exception as e:
    print(f"[auth] Bootstrap failed: {e}", file=sys.stderr)
    pass

print(username)
print(access_token)
print(oidc_token)
print(bootstrap_b64)
AUTHEOF
)

if [[ $? -ne 0 ]]; then
  printf '\n[ERROR] Authentication failed. Check your credentials.\n' >&2
  exit 1
fi

_auth_username=$(printf '%s' "${_auth_result}" | sed -n '1p')
_auth_token=$(printf '%s'    "${_auth_result}" | sed -n '2p')
_auth_oidc=$(printf '%s'     "${_auth_result}" | sed -n '3p')
_auth_bootstrap=$(printf '%s' "${_auth_result}" | sed -n '4p')


# Temp files for OIDC token and bootstrap blob.
_oidc_tmp=$(mktemp /tmp/cluckers_oidc_XXXXXX)
_bootstrap_tmp=$(mktemp /tmp/cluckers_bootstrap_XXXXXX)

# Write OIDC token; game reads it via -eac_oidc_token_file.
printf '%s' "${_auth_oidc}" > "${_oidc_tmp}"

# Decode and write bootstrap blob (base64 → 136-byte binary file).
# shm_launcher.exe reads this file and maps it into shared memory.
if [[ -n "${_auth_bootstrap}" ]]; then
  printf '%s' "${_auth_bootstrap}" | base64 -d > "${_bootstrap_tmp}"
fi

# Convert Linux paths to Windows paths for Wine (Z: maps to /).
_oidc_wine=$(printf '%s' "${_oidc_tmp}" | sed 's|/|\\|g; s|^|Z:|')
_bootstrap_wine=$(printf '%s' "${_bootstrap_tmp}" | sed 's|/|\\|g; s|^|Z:|')
_game_exe="${GAME_DIR}/${GAME_EXE_REL}"
_game_exe_wine=$(printf '%s' "${_game_exe}" | sed 's|/|\\|g; s|^|Z:|')

# Shared-memory name — unique per session PID.
_shm_name="Local\\realm_content_bootstrap_$$"

# Game launch arguments — passed directly to the game executable.
# Source: https://github.com/0xc0re/cluckers/blob/master/internal/launch/process.go
_game_args=(
  "-user=${_auth_username}"
  "-token=${_auth_token}"
  "-eac_oidc_token_file=${_oidc_wine}"
  "-hostx=${HOST_X}"
  "-Language=INT"
  "-dx11"
  "-content_bootstrap_size=136"
  "-seekfreeloadingpcconsole"
  "-nohomedir"
)

# Append bootstrap shared memory argument if a bootstrap blob is present.
if [[ -s "${_bootstrap_tmp}" ]]; then
  _game_args+=("-content_bootstrap_shm=${_shm_name}")
fi

# Cleanup: kill all processes we spawned whenever the launcher exits — whether
# the game closed normally, was interrupted (Ctrl+C), or received SIGTERM.
# When the game exits, shm_launcher.exe returns and wait completes, but Wine
# background processes (winedevice.exe) stay alive until explicitly killed. 
# We always clean them up here.
#
# Wine is launched via setsid, making it a session leader.
# Its SID == its PID, so we kill by session: pkill -s PID sends the signal
# to every process in that session regardless of how many process groups Wine
# has spawned internally (winedevice.exe, services.exe, etc.).
_kill_session() {
  local pid="${1:-}"
  [[ -z "${pid}" || "${pid}" == "0" ]] && return

  # Kill the entire process group (negative PID = group leader).
  # setsid makes the launched process both session leader and process group
  # leader (PGID == PID), so kill -- -PID reaches all processes in the group.
  # We use -9 (SIGKILL) immediately for children to ensure Steam doesn't linger.
  kill -KILL -- "-${pid}" 2>/dev/null || true

  # Also kill by session ID — catches processes that called setsid themselves.
  pkill -KILL -s "${pid}" 2>/dev/null || true

  # Kill by parent PID as an additional sweep for any orphaned children.
  pkill -KILL -P "${pid}" 2>/dev/null || true

  # Wait up to 1 second for the process group leader to exit.
  local _w=0
  while kill -0 "${pid}" 2>/dev/null && (( _w < 10 )); do
    sleep 0.1; (( _w++ )) || true
  done

  # Force-kill leader if still alive.
  kill -KILL "${pid}" 2>/dev/null || true
}

_cleanup() {
  # Remove the trap to prevent recursion if _cleanup is called more than once.
  trap '' EXIT INT TERM HUP

  # Step 1: Kill gamescope components explicitly by name.
  # Steam tracks these; they MUST be gone for Steam to stop the 'Running' state.
  pkill -9 -x "gamescope-wl"    2>/dev/null || true
  pkill -9 -f "gamescopereaper" 2>/dev/null || true
  pkill -9 -x "Xwayland"        2>/dev/null || true

  # Step 2: Kill gamescope and Wine process groups and sessions.
  # By the time _cleanup runs gamescope may have already exited cleanly.
  # _kill_session handles dead PIDs safely.
  _kill_session "${_GS_PID:-}"
  _kill_session "${_WINE_PID:-}"

  # Step 3: Graceful wineserver shutdown — terminates winedevice.exe,
  # services.exe, plugplay.exe and all Wine helpers for our specific prefix.
  # Followed by -9 to ensure winedevice.exe doesn't hang Steam.
  WINEPREFIX="${WINEPREFIX}" "${WINESERVER}" -k 2>/dev/null || true
  pkill -9 -f "winedevice.exe" 2>/dev/null || true
  
  # Step 4: Wait for wineserver to fully stop.
  WINEPREFIX="${WINEPREFIX}" "${WINESERVER}" -w 2>/dev/null || true

  # Step 5: Final sweep for any orphans specifically in our session.
  _kill_session "${_WINE_PID:-}"

  # Step 6: Remove temp files created during this launcher session.
  [[ -n "${_bootstrap_tmp:-}" ]] && rm -f "${_bootstrap_tmp}"
  [[ -n "${_oidc_tmp:-}" ]] && rm -f "${_oidc_tmp}"
}

trap _cleanup EXIT INT TERM HUP

# ---- Launch ---------------------------------------------------------------

# Prepare final command.
# If a Proton script is available, we use 'proton run' to launch the game.
# This ensures the game runs within the Steam Linux Runtime (pressure-vessel)
# container, which provides modern networking and crypto libraries (like GnuTLS)
# required by the Unreal Engine 3 ServerTravel match transition. Without it,
# the game may hang on the loading screen when entering a match.
if [[ -n "${PROTON_SCRIPT}" ]]; then
  # Required by proton run
  export STEAM_COMPAT_DATA_PATH="${CLUCKERS_ROOT}"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="${HOME}/.steam/root"
  export SteamGameId="0"
  export SteamAppId="0"
  _launch_cmd=("python3" "${PROTON_SCRIPT}" "run")
else
  _launch_cmd=("${WINE}")
fi

_launch_gamescope() {
  # Launch gamescope wrapping the game.
  # gamescope -- <cmd> makes gamescope exit when gamescopereaper exits, but
  # gamescopereaper may outlive the game. We use a sentinel file to detect
  # when shm_launcher / wine has exited, then kill gamescope explicitly.
  local _gs_cmd=("$@")
  local _sentinel
  _sentinel=$(mktemp)

  # Wrap the launch command: when wine/shm_launcher exits, remove the
  # sentinel file so the poll loop below detects game exit.
  # bash -c 'script' argv0 arg1 arg2...: $0=argv0, $1..=args, "$@" expands
  # all positional args except $0. We pass the sentinel as the last arg and
  # strip it before passing the rest to the game command.
  # shellcheck disable=SC2086
  setsid env DBUS_SESSION_BUS_ADDRESS=/dev/null ${GS_ARGS} -- \
    bash -c 'sentinel=$1; shift; "$@"; rm -f "${sentinel}"' \
      -- "${_sentinel}" "${_gs_cmd[@]}" &
  _GS_PID=$!
  _WINE_PID=${_GS_PID}

  # Wait for the sentinel file to be removed (game exited) or gamescope to
  # exit on its own (whichever comes first).
  while kill -0 "${_GS_PID}" 2>/dev/null && [[ -f "${_sentinel}" ]]; do
    sleep 0.5
  done
  rm -f "${_sentinel}"

  # Game has exited — kill gamescope and its entire process group.
  _kill_session "${_GS_PID}"

  # Reap the background gamescope process to avoid a zombie.
  wait "${_GS_PID}" 2>/dev/null || true
}

if [[ -s "${_bootstrap_tmp}" ]]; then
  if [[ "${USE_GAMESCOPE}" == "true" ]]; then
    _launch_gamescope "${_launch_cmd[@]}" "${TOOLS_DIR}/shm_launcher.exe" \
      "${_bootstrap_wine}" "${_shm_name}" "${_game_exe_wine}" \
      "${_game_args[@]}"
  else
    setsid "${_launch_cmd[@]}" "${TOOLS_DIR}/shm_launcher.exe" \
      "${_bootstrap_wine}" "${_shm_name}" "${_game_exe_wine}" \
      "${_game_args[@]}" &
    _WINE_PID=$!
    wait "${_WINE_PID}" || true
  fi
else
  if [[ "${USE_GAMESCOPE}" == "true" ]]; then
    _launch_gamescope "${_launch_cmd[@]}" "${_game_exe}" "${_game_args[@]}"
  else
    setsid "${_launch_cmd[@]}" "${_game_exe}" "${_game_args[@]}" &
    _WINE_PID=$!
    wait "${_WINE_PID}" || true
  fi
fi


# The EXIT trap (_cleanup) fires here automatically when this script exits,
# killing any remaining gamescope/Wine processes and removing temp files.
exit 0

LAUNCHEOF

  chmod +x "${LAUNCHER_SCRIPT}"
  ok_msg "Launcher script created at: ${LAUNCHER_SCRIPT}"

  # --------------------------------------------------------------------------
  # Step 9 — Create .desktop shortcut
  #
  # The .desktop file tells your application menu (GNOME, KDE, etc.) about
  # the game: its name, icon, and how to launch it. After install you will
  # find "Cluckers Central" in your app grid / start menu.
  # --------------------------------------------------------------------------
  step_msg "Step 9 — Creating desktop shortcut..."

  # Remove any existing Cluckers Central desktop entries that may have been
  # created by a previous install or by the Windows launcher running under Wine.
  local _shortcut_dirs=(
    "${HOME}/.local/share/applications"
    "${HOME}/.local/share/applications/wine"
    "${HOME}/Desktop"
    "/usr/share/applications"
  )
  local _sdir
  for _sdir in "${_shortcut_dirs[@]}"; do
    [[ -d "${_sdir}" ]] || continue
    while IFS= read -r _old; do
      [[ -f "${_old}" ]] || continue
      info_msg "Removing existing shortcut: ${_old}"
      rm -f "${_old}"
    done < <(find "${_sdir}" -maxdepth 2 \
      \( -name "*[Cc]luckers*" -o -name "*[Rr]ealm*[Rr]oyale*" \) \
      2>/dev/null)
  done

  mkdir -p "$(dirname "${DESKTOP_FILE}")"
  cat > "${DESKTOP_FILE}" << EOF
[Desktop Entry]
Name=${APP_NAME}
Comment=Play Cluckers Central (Realm Royale) on Linux
Exec=${LAUNCHER_SCRIPT}
Path=${HOME}/.local/bin
Icon=cluckers-central
Terminal=false
Type=Application
Categories=Game;
StartupNotify=true
StartupWMClass=ShippingPC-RealmGameNoEditor.exe
EOF

  chmod +x "${DESKTOP_FILE}"

  # Refresh the desktop database so the launcher appears in menus immediately.
  if command_exists update-desktop-database; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi
  ok_msg "Desktop shortcut created at: ${DESKTOP_FILE}"

  # --------------------------------------------------------------------------
  step_msg "Step 10 — Configuring Steam integration (optional)..."

  local steam_root=""
  local skip_steam="false"

  # If Steam is currently running, its shortcuts.vdf is held open and will be
  # overwritten when Steam exits — wiping any changes we write now. We warn the
  # user and give them a chance to close Steam before we proceed. We never
  # launch or kill Steam ourselves; that's the user's decision.
  # Detect Steam running under any of: native, Flatpak, or Snap packaging.
  # pgrep -x "steam" only matches the native binary name. Flatpak Steam runs
  # as "steam" inside a container but its host-visible process may differ.
  # We also check for the Flatpak host process name.
  if pgrep -x "steam" > /dev/null 2>&1 \
     || pgrep -f "com.valvesoftware.Steam" > /dev/null 2>&1; then
    warn_msg "Steam is currently running."
    warn_msg "Steam holds shortcuts.vdf open and will overwrite it when it closes."
    warn_msg "For the shortcut to survive, close Steam first:"
    warn_msg "  Steam menu → Exit  (or right-click the tray icon → Exit Steam)"
    warn_msg "You can also re-run this script after closing Steam."
    if [[ "${auto_mode}" == "false" ]]; then
      printf "\n  [PROMPT] Press ENTER when Steam is closed (or type 'skip' to skip): "
      local choice=""
      read -r choice
      if [[ "${choice,,}" == "skip" ]]; then
        info_msg "Skipping Steam integration (user requested)."
        skip_steam="true"
      fi
    else
      # In auto mode, write the shortcut now. Steam will overwrite it when it
      # exits, but the files will be correct — the user can restart Steam and
      # the shortcut will appear on the next launch.
      info_msg "Auto mode: writing Steam shortcut now. Restart Steam afterwards to see it."
    fi
  fi

  if [[ "${skip_steam}" == "false" ]]; then
    local candidate
    # Search all known Steam installation locations, in priority order:
    # native first, then Flatpak, then Snap. Multiple may coexist on the same
    # system; we take the first one that passes the Steam validity check.
    #
    # We validate using canonical Steam marker files (steam.sh or
    # ubuntu12_32/steamclient.so), matching cluckers/internal/wine/steamdir.go.
    # Checking only for userdata/ is unreliable — Flatpak Steam at data/Steam
    # may have userdata/ nested differently depending on the version.
    for candidate in \
      "${HOME}/.local/share/Steam" \
      "${HOME}/.steam/steam" \
      "${HOME}/.steam/root" \
      "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
      "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
      "${HOME}/snap/steam/common/.local/share/Steam"; do
      local _r
      _r=$(readlink -f "${candidate}" 2>/dev/null) || continue
      if [[ -f "${_r}/steam.sh" ]] || [[ -f "${_r}/ubuntu12_32/steamclient.so" ]]; then
        steam_root="${_r}"
        break
      fi
    done

    if [[ -z "${steam_root}" ]]; then
      warn_msg "Steam installation not found — skipping Steam integration."
      warn_msg "To add manually: add ${LAUNCHER_SCRIPT} as a non-Steam game in Steam."
    elif ! command_exists python3; then
      warn_msg "Python 3 not available — skipping Steam integration."
    else
      local steam_userdata="${steam_root}/userdata"
      local steam_user=""
      if [[ -d "${steam_userdata}" ]]; then
        # Pick the most-recently-modified userdata subdirectory as the active
        # Steam account. stat -c %Y is more portable than find -printf '%T@'
        # (which is a GNU extension not available on all systems).
        steam_user=$(
          find "${steam_userdata}" -maxdepth 1 -mindepth 1 -type d \
            2>/dev/null \
          | while IFS= read -r _d; do
              printf '%s %s\n' "$(stat -c '%Y' "${_d}" 2>/dev/null || echo 0)" \
                               "$(basename "${_d}")"
            done \
          | sort -rn \
          | awk 'NR==1 {print $2}'
        )
      fi

      if [[ -z "${steam_user}" ]]; then
        warn_msg "No Steam user account found — skipping Steam integration."
      else
        info_msg "Configuring Steam for user ${steam_user}..."

        USER_CONFIG_DIR="${steam_userdata}/${steam_user}/config" \
        LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
        ICON_PATH_ENV="${ICON_PATH}" \
        APP_NAME_ENV="${APP_NAME}" \
        STEAM_GRID_PATH_ENV="${STEAM_GRID_PATH}" \
        STEAM_HERO_PATH_ENV="${STEAM_HERO_PATH}" \
        STEAM_LOGO_PATH_ENV="${STEAM_LOGO_PATH}" \
        STEAM_WIDE_PATH_ENV="${STEAM_WIDE_PATH}" \
        STEAM_HEADER_PATH_ENV="${STEAM_HEADER_PATH}" \
        STEAM_ICO_PATH_ENV="${STEAM_ICO_PATH}" \
        python3 - << 'PYEOF'
"""Adds Cluckers Central to Steam as a non-Steam shortcut."""

import binascii
import os
import shutil
import time

import vdf  # pip install vdf

USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER        = os.environ["LAUNCHER_ENV"]
ICON_PATH       = os.environ["ICON_PATH_ENV"]
APP_NAME        = os.environ["APP_NAME_ENV"]
STEAM_GRID      = os.environ.get("STEAM_GRID_PATH_ENV", "")
STEAM_HERO      = os.environ.get("STEAM_HERO_PATH_ENV", "")
STEAM_LOGO      = os.environ.get("STEAM_LOGO_PATH_ENV", "")
STEAM_WIDE      = os.environ.get("STEAM_WIDE_PATH_ENV", "")
STEAM_HEADER    = os.environ.get("STEAM_HEADER_PATH_ENV", "")
STEAM_ICO       = os.environ.get("STEAM_ICO_PATH_ENV", "")

_OK   = "  [\033[0;32m OK \033[0m]"
_WARN = "  [\033[1;33mWARN\033[0m]"


def compute_shortcut_id(exe: str, name: str) -> int:
    """Return the Steam non-Steam shortcut ID for the given exe + name pair.

    Steam computes the shortcut ID from the raw (unquoted) exe path concatenated
    with the app name. The Exe field in shortcuts.vdf is stored quoted, but the
    ID itself is derived from the unquoted path. Verified against the original
    working version of this script and the Steam source behaviour.
    """
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    return (crc | 0x80000000) & 0xFFFFFFFF


unsigned_id    = compute_shortcut_id(LAUNCHER, APP_NAME)
# For the shortcuts.vdf file, Steam expects a signed 32-bit integer.
shortcut_appid = (
    unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id
)

os.makedirs(USER_CONFIG_DIR, exist_ok=True)

# -- shortcuts.vdf: add non-Steam game entry --------------------------------
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
try:
    if os.path.exists(shortcuts_path):
        with open(shortcuts_path, "rb") as fh:
            shortcuts = vdf.binary_load(fh)
    else:
        shortcuts = {"shortcuts": {}}

    sc = shortcuts.setdefault("shortcuts", {})

    # Remove any existing entry for this launcher to avoid duplicates.
    keys_to_delete = [
        k for k, v in sc.items()
        if isinstance(v, dict)
        and LAUNCHER in v.get("Exe", v.get("exe", ""))
    ]
    for k in keys_to_delete:
        del sc[k]

    # Steam requires Exe and StartDir to be quoted strings in shortcuts.vdf.
    # Without quotes Steam may fail to launch the non-Steam shortcut.
    # Source: Valve's internal format, reproduced by steam-rom-manager.
    quoted_exe = f'"{LAUNCHER}"'
    start_dir  = f'"{os.path.dirname(LAUNCHER)}"'
    # Use the Steam community ICO as the Steam shortcut icon (shortcuts.vdf
    # "icon" field). Fall back to ICON_PATH if the ICO was not downloaded.
    # The desktop .desktop file uses Icon=cluckers-central (theme name lookup),
    # not an absolute path, so ICON_PATH is only used here as a fallback.
    icon_path = STEAM_ICO if STEAM_ICO and os.path.exists(STEAM_ICO) else ICON_PATH
    # LaunchOptions: leave empty — the launcher script handles
    # all launch arguments internally.
    launch_opts = ""

    next_key = str(len(sc))
    sc[next_key] = {
        "appid":              shortcut_appid,
        "AppName":            APP_NAME,
        "Exe":                quoted_exe,
        "StartDir":           start_dir,
        "icon":               icon_path,
        "ShortcutPath":       "",
        "LaunchOptions":      launch_opts,
        "IsHidden":           0,
        "AllowDesktopConfig": 1,
        "AllowOverlay":       1,
        "openvr":             0,
        "Devkit":             0,
        "DevkitGameID":       "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime":       int(time.time()),
        "FlatpakAppID":       "",
        "tags":               {},
    }

    with open(shortcuts_path, "wb") as fh:
        vdf.binary_dump(shortcuts, fh)

    # -- Steam Library Artwork: grid/hero/logo ------------------------------
    # Steam stores non-Steam game artwork in userdata/<uid>/config/grid/.
    # Files are named <appid><suffix>.<ext> where appid is derived from the
    # shortcut's CRC32. Two ID formats are in use depending on Steam version:
    #
    #   long_id  = (unsigned_crc << 32) | 0x02000000
    #     Modern Steam (post-2019) uses this 64-bit ID for grid/ filenames.
    #     This is what tools like Heroic, Lutris, and steam-rom-manager write.
    #
    #   unsigned_crc  = crc32(exe+name) | 0x80000000
    #     Older Steam versions used this 32-bit ID directly.
    #
    # We write both formats so the artwork appears regardless of Steam version.
    #
    # Suffix conventions (verified against Steam client source and community):
    #   p        — Vertical grid / portrait poster  (600×900)
    #   (none)   — Horizontal grid / wide cover     (616×353)
    #   _hero    — Library hero / banner background (3840×1240 for 2x)
    #   _logo    — Logo banner                      (1280×720 with background)
    #   _header  — Small header / capsule           (460×215)
    #
    # Sources:
    #   https://www.steamgriddb.com/blog/backgrounds-and-logos
    #   https://github.com/nicowillis/steam-rom-manager
    #   https://github.com/lutris/lutris/blob/master/lutris/services/steam.py
    # grid/ lives inside config/, not one level up — USER_CONFIG_DIR is
    # already userdata/<uid>/config so grid/ is a direct subdirectory.
    grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
    os.makedirs(grid_dir, exist_ok=True)

    # Artwork suffix mapping — verified from steam-rom-manager source and img-sauce.
    # Steam stores non-Steam game artwork under two ID formats (both written so
    # the correct image appears regardless of Steam client version):
    #
    #   unsigned_id  = crc32(exe+name) | 0x80000000   — legacy 32-bit prefix
    #   long_id      = (unsigned_id << 32) | 0x02000000 — modern 64-bit prefix
    #                  (used by Steam post-2019 / Big Picture / Steam Deck)
    #
    # community assets label → grid/ suffix → source file
    # library_capsule     2x → p            → library_600x900_2x.jpg  (600×900 portrait)
    # main_capsule           → (empty)      → capsule_616x353.jpg     (616×353 wide cover)
    # library_hero        2x → _hero        → library_hero_2x.jpg     (3840×1240 banner)
    # logo                2x → _logo        → logo_2x.png             (1280×720 logo banner)
    # header                 → _header      → header.jpg              (460×215 header)
    art_map = {
        STEAM_GRID:   "p",       # portrait poster  (600×900)
        STEAM_WIDE:   "",        # wide cover       (616×353)
        STEAM_HERO:   "_hero",   # hero background  (3840×1240)
        STEAM_LOGO:   "_logo",   # logo banner      (1280×720)
        STEAM_HEADER: "_header", # header tile      (460×215)
    }

    # Write artwork for both ID formats so the images appear in all Steam versions.
    long_id = (unsigned_id << 32) | 0x02000000
    for grid_id in (str(unsigned_id), str(long_id)):
        for src, suffix in art_map.items():
            if not src or not os.path.exists(src):
                continue
            ext = os.path.splitext(src)[1]
            dest = os.path.join(grid_dir, f"{grid_id}{suffix}{ext}")
            try:
                shutil.copy2(src, dest)
            except Exception:
                pass

    # -- localconfig.vdf: set logo position ---------------------------------
    localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
    if os.path.exists(localconfig_path):
        try:
            with open(localconfig_path, encoding="utf-8", errors="replace") as fh:
                lc = vdf.load(fh)
            
            apps = lc.setdefault("UserLocalConfigStore", {}).setdefault("Software", {}).setdefault("Valve", {}).setdefault("Steam", {}).setdefault("apps", {})
            # localconfig.vdf uses the UNSIGNED 32-bit CRC ID as the key.
            app = apps.setdefault(str(unsigned_id), {})
            app["logo_position"] = {
                "pinned_position": "BottomLeft",
                "width_pct": "36.44186046511628",
                "height_pct": "100"
            }
            
            with open(localconfig_path, "w", encoding="utf-8") as fh:
                vdf.dump(lc, fh, pretty=True)
        except Exception as exc:
            print(f"{_WARN} Could not update logo position in localconfig.vdf: {exc}")

    print(f"{_OK} Added Cluckers Central to Steam library (including artwork).")
except Exception as exc:  # pylint: disable=broad-except
    print(f"{_WARN} Could not update shortcuts.vdf: {exc}")

PYEOF
    fi
  fi
fi

# --------------------------------------------------------------------------
# Install complete
# --------------------------------------------------------------------------
  printf "\n"
  # --------------------------------------------------------------------------
  # Step 11 — Game patches (Steam Deck or controller)
  #
  # Applies patches to game config files for Steam Deck or generic controller
  # support:
  #
  #   1. RealmSystemSettings.ini — force fullscreen at 1280×800 (Steam Deck only).
  #
  #   2. DefaultInput.ini / RealmInput.ini / BaseInput.ini — remove the
  #      "Count bXAxis" and "Count bYAxis" mouse-axis counters. These counters
  #      cause the engine to switch from gamepad mode to keyboard/mouse mode
  #      under Wine whenever the mouse moves.
  #
  #   3. controller_neptune_config.vdf — deploy the custom Steam Deck button
  #      layout template (Steam Deck only).
  #
  # Safe to run multiple times — all patches are idempotent.
  # --------------------------------------------------------------------------
  step_msg "Step 11 — Applying game patches..."

  if [[ "${steam_deck}" == "true" ]] && ! is_steam_deck; then
    warn_msg "Steam Deck hardware not detected (board_vendor != Valve)."
    warn_msg "Applying patches anyway as --steam-deck / -d was passed."
  fi

  apply_game_patches "${GAME_DIR}" "${steam_deck}" "${controller_mode}"

  # --------------------------------------------------------------------------
  # Step 12 — Verifying account
  #
  # Ensures the user can log in before finishing. This step is skipped in
  # auto mode if credentials already exist.
  # --------------------------------------------------------------------------
  if [[ "${auto_mode}" == "false" ]] || [[ ! -f "${CREDS_FILE}" ]]; then
    step_msg "Step 12 — Verifying account..."
    
    while true; do
      if [[ -f "${CREDS_FILE}" ]]; then
        info_msg "Credentials found. Verifying existing account..."
      else
        info_msg "No credentials found. Please log in."
      fi

      # Run verification via Python (same logic as launcher).
      _auth_status=$(PYTHONPATH="${CLUCKERS_PYLIBS}${PYTHONPATH:+:${PYTHONPATH}}" \
      python3 - "${CREDS_FILE}" "${GATEWAY_URL}" << 'AUTHEOF'
import base64, json, os, sys, urllib.request, urllib.error, termios, tty as ttymod

creds_file = sys.argv[1]
gateway    = sys.argv[2].rstrip("/")

def _post(endpoint, payload):
    url  = f"{gateway}/json/{endpoint}"
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "User-Agent": "CluckersCentral/1.1.68", "Accept": "*/*"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def _flex_bool(val):
    if isinstance(val, bool): return val
    if isinstance(val, (int, float)): return val != 0
    if isinstance(val, str): return val.lower() in ("true", "1", "yes")
    return False

username = password = ""
if os.path.exists(creds_file):
    try:
        with open(creds_file) as f:
            line = f.read().strip()
        username, password = line.split(":", 1)
    except Exception: pass

if not username or not password:
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        tty_r = os.fdopen(os.dup(tty_fd), "r", buffering=1, closefd=True)
        tty_w = os.fdopen(tty_fd,          "w", buffering=1, closefd=True)
    except OSError:
        print("FAIL:Cannot open /dev/tty for input")
        sys.exit(1)
    try:
        tty_w.write("\nEnter your Project Crown credentials.\nUsername: ")
        tty_w.flush()
        username = tty_r.readline().rstrip("\n")
        tty_w.write("Password: ")
        tty_w.flush()
        old = termios.tcgetattr(tty_r)
        try:
            ttymod.setraw(tty_r)
            password = ""
            while True:
                ch = tty_r.read(1)
                if ch in ("\n", "\r"): break
                if ch == "\x7f": password = password[:-1]
                else: password += ch
        finally:
            termios.tcsetattr(tty_r, termios.TCSADRAIN, old)
            tty_w.write("\n")
            tty_w.flush()
    finally:
        tty_r.close()
        tty_w.close()

try:
    login = _post("LAUNCHER_LOGIN_OR_LINK", {"user_name": username, "password": password})
    if _flex_bool(login.get("SUCCESS")):
        os.makedirs(os.path.dirname(creds_file), exist_ok=True)
        def secure_opener(path, flags): return os.open(path, flags, 0o600)
        with open(creds_file, "w", opener=secure_opener) as f:
            f.write(f"{username}:{password}")
        print(f"OK:{username}")
    else:
        msg = login.get("TEXT_VALUE") or "invalid credentials"
        print(f"FAIL:{msg}")
        if os.path.exists(creds_file): os.remove(creds_file)
except Exception as e:
    print(f"FAIL:Connection error ({e})")
AUTHEOF
)
      if [[ "${_auth_status}" == OK:* ]]; then
        ok_msg "Account verified: ${_auth_status#OK:}"
        break
      else
        error_msg="${_auth_status#FAIL:}"
        warn_msg "Verification failed: ${error_msg:-unknown error}"
        if [[ "${auto_mode}" == "true" ]]; then
          warn_msg "Skipping account verification in auto mode."
          break
        fi
        printf "  Try again? (Y/n): "
        read -r _retry
        if [[ "${_retry}" =~ ^[Nn] ]]; then break; fi
      fi
    done
  fi

  fi # end skip_heavy_steps

  printf "\n"
  printf "%b╔══════════════════════════════════════════════════════╗%b\n" "${GREEN}" "${NC}"
  printf "%b║              Installation complete!                  ║%b\n" "${GREEN}" "${NC}"
  printf "%b╚══════════════════════════════════════════════════════╝%b\n" "${GREEN}" "${NC}"
  printf "\n"
  printf "  To start the game:\n"
  printf "    %b%s%b\n" "${BOLD}" "${LAUNCHER_SCRIPT}" "${NC}"
  printf "\n"
  printf "  Or launch from your application menu / Steam library.\n"
  printf "\n"
  printf "  If login fails, delete credentials and re-run:\n"
  printf "    rm ~/.cluckers/credentials.enc\n"
  printf "  If the game crashes, check the Wine log:\n"
  printf "    cat /tmp/cluckers_wine.log\n"
  printf "\n"
  printf "  To uninstall:\n"
  printf "    %b./cluckers-setup.sh --uninstall%b\n" "${BOLD}" "${NC}"
  printf "\n"
}

main "$@"
