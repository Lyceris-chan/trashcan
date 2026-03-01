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
#    ./cluckers-setup.sh --wayland-cursor-fix     # opt-in: disable winex11 to fix cursor warping under Proton on Wayland-only desktops (e.g., COSMIC)
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
readonly SHM_LAUNCHER_SHA256="923ff334fd0b0aa6be27d57bf11809d604abb7f6342c881328423f73efcb69fa"
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
#
# Returns:
#   0 on success; 1 on failure to install missing modules.
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
  local wayland_cursor_fix="false"
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
      --wayland-cursor-fix) wayland_cursor_fix="true" ;;
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
  #   Compile: x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows \
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
  #        x86_64-w64-mingw32-gcc -O2 -Wall -municode -Wl,--subsystem,windows \
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
  #        923ff334fd0b0aa6be27d57bf11809d604abb7f6342c881328423f73efcb69fa  shm_launcher.exe
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
  #
  # The embedded shm_launcher.c source and corresponding base64 payload
  # (found below under SHM_B64_EOF) are synced with the latest upstream
  # version to include launch-config.txt parsing support. 
  #
  # NOTE: The binary is compiled with -Wl,--subsystem,windows to ensure it
  #       is invisible (no console window pop-up) when launching the game.
  # ==============================================================================
#   /*
#    * shm_launcher.c - Creates a named shared memory section with content bootstrap
#    * data, then launches the game executable. The game expects to find the bootstrap
#    * via OpenFileMapping() using the name passed in -content_bootstrap_shm=.
#    *
#    * Build: x86_64-w64-mingw32-gcc -o shm_launcher.exe shm_launcher.c -municode -Wl,--subsystem,windows
#    * Usage: shm_launcher.exe <bootstrap_file> <shm_name> <game_exe> [game_args...]
#    *
#    * When no CLI arguments are given, reads arguments from launch-config.txt in the
#    * same directory as the executable. Each line in the config file is one argument
#    * (line 1 = bootstrap_file, line 2 = shm_name, line 3 = game_exe, rest = game args).
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
#   #define MAX_CONFIG_ARGS 64
#   #define MAX_LINE_LEN 4096
#
#   /*
#    * read_config_file - Reads launch-config.txt from the same directory as the
#    * running executable. Each non-empty line becomes one argument.
#    * Returns the number of arguments read, or 0 on failure.
#    */
#   static int read_config_file(wchar_t *args[], int max_args) {
#       /* Get the path of the running executable. */
#       wchar_t exe_path[MAX_PATH];
#       DWORD len = GetModuleFileNameW(NULL, exe_path, MAX_PATH);
#       if (len == 0 || len >= MAX_PATH) {
#           fprintf(stderr, "GetModuleFileName failed (err=%lu)\n", GetLastError());
#           return 0;
#       }
#
#       /* Replace the exe filename with launch-config.txt. */
#       wchar_t *last_slash = wcsrchr(exe_path, L'\\');
#       if (!last_slash) last_slash = wcsrchr(exe_path, L'/');
#       if (last_slash)
#           wcscpy(last_slash + 1, L"launch-config.txt");
#       else
#           wcscpy(exe_path, L"launch-config.txt");
#
#       FILE *f = _wfopen(exe_path, L"r, ccs=UTF-8");
#       if (!f) {
#           fprintf(stderr, "Could not open config file: %ls (err=%lu)\n", exe_path, GetLastError());
#           return 0;
#       }
#
#       printf("[shm_launcher] Reading config: %ls\n", exe_path);
#
#       int count = 0;
#       wchar_t line_buf[MAX_LINE_LEN];
#       while (count < max_args && fgetws(line_buf, MAX_LINE_LEN, f)) {
#           /* Strip trailing newline/carriage return. */
#           size_t line_len = wcslen(line_buf);
#           while (line_len > 0 && (line_buf[line_len - 1] == L'\n' || line_buf[line_len - 1] == L'\r')) {
#               line_buf[--line_len] = L'\0';
#           }
#
#           /* Skip empty lines. */
#           if (line_len == 0) continue;
#
#           args[count] = (wchar_t *)malloc((line_len + 1) * sizeof(wchar_t));
#           if (!args[count]) {
#               fprintf(stderr, "malloc failed for config line %d\n", count);
#               fclose(f);
#               return count;
#           }
#           wcscpy(args[count], line_buf);
#           count++;
#       }
#
#       fclose(f);
#       printf("[shm_launcher] Read %d args from config\n", count);
#       return count;
#   }
#
#   int wmain(int argc, wchar_t *argv[]) {
#       wchar_t *config_args[MAX_CONFIG_ARGS];
#       int config_argc = 0;
#       int use_config = 0;
#
#       if (argc < 4) {
#           /* No CLI args — try config file. */
#           config_argc = read_config_file(config_args, MAX_CONFIG_ARGS);
#           if (config_argc < 3) {
#               fprintf(stderr, "Usage: shm_launcher.exe <bootstrap_file> <shm_name> <game_exe> [game_args...]\n");
#               fprintf(stderr, "  Or place a launch-config.txt next to the executable.\n");
#               /* Free any partially read config args. */
#               for (int i = 0; i < config_argc; i++) free(config_args[i]);
#               return 1;
#           }
#           use_config = 1;
#       }
#
#       /* Select argument source: CLI or config file. */
#       int eff_argc = use_config ? config_argc : (argc - 1);
#       wchar_t **eff_argv = use_config ? config_args : (argv + 1);
#
#       wchar_t *bootstrap_file = eff_argv[0];
#       wchar_t *shm_name = eff_argv[1];
#       wchar_t *game_exe = eff_argv[2];
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
#       /* Append remaining args (index 3+ in effective argv) */
#       for (int i = 3; i < eff_argc; i++) {
#           pos += swprintf(cmdline + pos, sizeof(cmdline)/sizeof(wchar_t) - pos, L" %ls", eff_argv[i]);
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
#       /* Free config file args if used. */
#       if (use_config) {
#           for (int i = 0; i < config_argc; i++) free(config_args[i]);
#       }
#
#       return (int)exitCode;
#   }
#
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
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/4tF2EmLFqgED4VR/v//SIlVgN1FgEiNVdBIjU2g232g6Jry///pFf7//4tF2EmLFqgED4Xs/f//SIlVgN1FgEiNVdBIjU2g232g6FDz///p6/3//0iNVdC5JQAAAE2J5+ia3v//6Rv6//+F2w+Fvfr//0yNTcBMiZV4////RIldkIFN2AAQAABMiU2Ax0XAAAAAAOi3VwAATItNgEiNTb5BuBAAAABIi1AI6NBUAABEi12QTIuVeP///4XAfggPt1W+ZolV8A+2VgGJRexMiebpYfr//02F0g+E+f3///fD/f///w+FGwEAAEGLBkmNTghBiQKFwA+IZwIAAA+2VgFJic5MieZFMdLpKPr//4XbD4UZ+v//D7ZWAYFN2AABAABMiebpDfr//4XbD4X++f//D7ZWAYFN2AAIAABMiebp8vn//4nKSItFgGaB4v9/D4TuAQAAZoH6ADwPj/0AAABED7/CuQE8AABEKcFI0+gB0Y2RBMD//0jB6ANIicFMjUXQ6Hjz///ps/z//0mNdghNizZIjQUNdQAATYX2TA9E8ItF4IXAD4gpAQAASGPQTInx6AhPAABMjUXQTInxicLomt3//0mJ9k2J5+m1+P//g/sDD4cg+///uTAAAACD+wK4AwAAAA9E2Okj+f//TI1F0EiNFbx0AAAxyeif4P//6Tr8//8PtlYBRTHSTInmuwQAAADpHfn//02FwLgCwP//TInBD0XQ6VL///9MieZBuwMAAAC7BAAAAOn3+P//DICJRdjpPPv//4n4x0XgEAAAAIDMAolF2OnO+f//ZoXSD4TdAAAAidHpBP///2aQSA+/yemS+f//SIkR6b/7//+D6TAPtlYBTInmQYkK6aT4//8PtlYBx0XgAAAAAEyJ5kyNVeC7AgAAAOmI+P//SYsG6eH4//8PtlYCQbsFAAAASIPGArsEAAAA6Wj4//+IEelq+///TInx6MJVAABMjUXQTInxicLodNz//+nV/v//SI1V0EiJwehj5f//6T77//9Jiw7pAfn//4B+AjQPheb5//8PtlYDQbsDAAAASIPGA7sEAAAA6Qv4//8PtlYCQbsDAAAASIPGArsEAAAA6fP3//9IhcC5Bfz//w9F0ekk/v//ZokR6eT6//9BiwbpNPj//4XbdSeBTdgABAAA913c6Yb9//8PtlYDQbsCAAAASIPG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SInx6TH8//8PH4QAAAAAAItDEIXAD4/S/P//6cH8//9Fi1AIRTHkRTHASI194Omu/P//ZmYuDx+EAAAAAABmkFVXVlNIg+woSI1sJCBBugEAAABBg+gBQYnLTInLSWPwQcH4H0hpzmdmZmZIwfkiRCnBdB8PH0AASGPBwfkfQYPCAUhpwGdmZmZIwfgiKciJwXXli0Msg/j/dQzHQywCAAAAuAIAAABBOcJEi0MMSYnZQQ9Nwo1IAonHRInAKchBOci5/////0G4AQAAAA9OwUSJ2YlDDOjl7P//i0sIi0MsSInaiUMQiciD4SANwAEAAIPJRYlDCOi05v//RI1XAUQBUwxIidpIifFIg8QoW15fXemp9v//Zg8fhAAAAAAAVVZTSIPsUEiNbCRQRItCENspSInTRYXAeFZBg8ABSI1F+EiNVeC5AgAAANt94EyNTfxIiUQkIOik6f//RItF/EiJxkGB+ACA//90NItN+EmJ2UiJwujG/v//SInx6O4MAACQSIPEUFteXcMPH0QAAMdCEAYAAABBuAcAAADrn5CLTfhJidhIicLo4uf//0iJ8ei6DAAAkEiDxFBbXl3DkFVXVlNIg+xYSI1sJFBEi0IQ2ylIidNFhcAPiOkAAAAPhMsAAABIjUX4SI1V4LkCAAAA233gTI1N/EiJRCQg6P3o//+LffxIicaB/wCA//8PhMsAAACLQwglAAgAAIP//XxOi1MQOdd/R4XAD4S/AAAAKfqJUxCLTfhJidlBifhIifLoeev//+sUDx+AAAAAAEiJ2rkgAAAA6FPl//+LQwyNUP+JUwyFwH/m6ycPH0AAhcB1NEiJ8ejkOQAAg+gBiUMQi034SYnZQYn4SIny6K39//9IifHo1QsAAJBIg8RYW15fXcMPHwCLQxCD6AHrz8dCEAEAAABBuAEAAADpI////2YPH0QAAMdCEAYAAABBuAYAAADpC////2YPH0QAAItN+EmJ2EiJwuii5v//66NIifHoaDkAACn4iUMQD4kz////i1MMhdIPjij///8B0IlDDOke////Dx+EAAAAAABVQVdBVkFVQVRXVlNIgey4AAAASI2sJLAAAABMic5JidREicOJz+hdOAAAgecAYAAAMdJEiwiJXfhIjV4CSLj//////f///0iJReAxwGaJRegPtwZMiWXQiX3Yx0Xc/////8dF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AGYP79vrQQ8fRAAA8g9ZxIPBAUiDwgGJTfxmDxDI8g9eyvIPLMFmD+/J8g8qyI1IMIhK//IPWcryD1zBZg8uw3oGD4RBAQAAi038i3W4OfF1uot1yIX2D4QXBAAAg/4BD4QuBQAASIt1oMdFwBAAAABIiVWg6dj3//+LVajpB/v//0iLVaDrDQ8fQABJOdYPhI8AAABNifRNjXb/QQ+2RCT/PDl05oPAAcdFwCAAAABBiAbpFPz//0iLdaBMiWWg6Y33//+LfYyJwolFjEUxwCn6i324AX2wQQHTi1WYiX38AddBidWJfZjpaPj//0GD/gEPhVT9//9Bi0QkBItV0IPAATnQD41B/f//g0WYAUG7AQAAAINFsAHpMf3//2YPH0QAAEiLRaCDRcwBx0XAIAAAAMYAMemR+///RInCSIn5RImdeP///0SJRYDoOwwAAEiJ2kiJwUiJx+i9CgAASInZSIlFqOjBCAAARItFgEQpRYxIi12oRIudeP///w+ESvj//+kv+P//SIt1oEiJVaDpvPb//0iJ2boBAAAATIlN2ESJRdDocQ0AAEiLVdhIicFIicPokg4AAEyLTdiFwA+PvP7//3UORItF0EGD4AEPhaz+//+DexQBx0XAEAAAAA+PNfz//4tDGOke/P//Dx9EAABEi13ITYn6TItN0EGJ8EyLfZBFhdsPhMYBAACDexQBD464AwAAg33IAg+EEQIAAEyJfdBFicZNiddMiU3Y61FmDx+EAAAAAABFiHQk/0UxwEyJ6boKAAAATYnn6EgIAABMOe9Iidm6CgAAAEgPRPhFMcBIicboLggAAEiLVdhJifVIicFIicPofOz//0SNcDBIi03YTInqTY1nAei4DQAAhcB/pE2J+kyLTdhMi33QRYnwQYP+OQ+EcQMAAMdFwCAAAABIif5Bg8ABTInvRYgC6QP6//+FyQ+EsPX//4uNcP///4XJD4719f//8g9ZBa07AADyDxANrTsAAEG4//////IPWchmSQ9+wvIPWA2eOwAAZkgPfspIidCJ0kjB6CAtAABAA0jB4CBICcKJyOlz8v//i08ITIlN0Oj5BQAASI1XEEiNSBBJicRIY0cUTI0EhQgAAADoTRkAALoBAAAATInh6MALAABMi03QSYnF6ff3///HRcwCAAAASIt1oEUxyTH/6bH0//9NifpMi03Q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IChlcnI9JWx1KQoAW3NobV9sYXVuY2hlcl0gR2FtZSBzdGFydGVkIChwaWQ9JWx1KSwgd2FpdGluZy4uLgoAAAAAAABbc2htX2xhdW5jaGVyXSBHYW1lIGV4aXRlZCB3aXRoIGNvZGUgJWx1CgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsB0AQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAFAAQAAAAgwAUABAAAAfAABQAEAAAA4IAFAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQXJndW1lbnQgZG9tYWluIGVycm9yIChET01BSU4pAEFyZ3VtZW50IHNpbmd1bGFyaXR5IChTSUdOKQAAAAAAAE92ZXJmbG93IHJhbmdlIGVycm9yIChPVkVSRkxPVykAUGFydGlhbCBsb3NzIG9mIHNpZ25pZmljYW5jZSAoUExPU1MpAAAAAFRvdGFsIGxvc3Mgb2Ygc2lnbmlmaWNhbmNlIChUTE9TUykAAAAAAABUaGUgcmVzdWx0IGlzIHRvbyBzbWFsbCB0byBiZSByZXByZXNlbnRlZCAoVU5ERVJGTE9XKQBVbmtub3duIGVycm9yAAAAAABfbWF0aGVycigpOiAlcyBpbiAlcyglZywgJWcpICAocmV0dmFsPSVnKQoAAPhZ//+sWf//RFn//8xZ///cWf//7Fn//7xZ//9NaW5ndy13NjQgcnVudGltZSBmYWlsdXJlOgoAAAAAAEFkZHJlc3MgJXAgaGFzIG5vIGltYWdlLXNlY3Rpb24AICBWaXJ0dWFsUXVlcnkgZmFpbGVkIGZvciAlZCBieXRlcyBhdCBhZGRyZXNzICVwAAAAAAAAAAAgIFZpcnR1YWxQcm90ZWN0IGZhaWxlZCB3aXRoIGNvZGUgMHgleAAAICBVbmtub3duIHBzZXVkbyByZWxvY2F0aW9uIHByb3RvY29sIHZlcnNpb24gJWQuCgAAAAAAAAAgIFVua25vd24gcHNldWRvIHJlbG9jYXRpb24gYml0IHNpemUgJWQuCgAAAAAAAAAlZCBiaXQgcHNldWRvIHJlbG9jYXRpb24gYXQgJXAgb3V0IG9mIHJhbmdlLCB0YXJnZXRpbmcgJXAsIHlpZWxkaW5nIHRoZSB2YWx1ZSAlcC4KAAAAAAAAmF7//5he//+YXv//mF7//5he//8QX///mF7//1Bf//8QX///617//wAAAAAAAAAAKG51bGwpAAAoAG4AdQBsAGwAKQAAAE5hTgBJbmYAAADch///MIT//zCE//9qiv//MIT//5WJ//8whP//q4n//zCE//8whP//For//0+K//8whP//9If//w+I//8whP//KYj//zCE//8whP//MIT//zCE//8whP//MIT//zCE//8whP//MIT//zCE//8whP//MIT//zCE//8whP//MIT//zCE//9EiP//MIT//+iI//8whP//F4n//0GJ//9rif//MIT//xqG//8whP//MIT//1CG//8whP//MIT//zCE//8whP//MIT//zCE///Niv//MIT//zCE//8whP//MIT//6CE//8whP//MIT//zCE//8whP//MIT//zCE//8whP//MIT//2WG//8whP//7ob//xeF//+0h///jIf//1GH//+Mhf//F4X//wCF//8whP//+oX//6yF///Ihf//oIT//1+F//8whP//MIT//ymH//8Ahf//oIT//zCE//8whP//oIT//zCE//8Ahf//AAAAACUAKgAuACoAUwAAACUALQAqAC4AKgBTAAAAJQAuACoAUwAAAChudWxsKQAAJQAqAC4AKgBzAAAAJQAtACoALgAqAHMAAAAlAC4AKgBzAAAAKABuAHUAbABsACkAAAAlAAAATmFOAEluZgAAAPqr//8EqP//BKj//xSs//8EqP//fqn//wSo//+dqf//BKj//wSo//8Kqv//Mqr//wSo//9Pqv//bKr//wSo//+Jqv//BKj//wSo//8EqP//BKj//wSo//8EqP//BKj//wSo//8EqP//BKj//wSo//8EqP//BKj//wSo//8EqP//BKj//7Oq//8EqP//Q6v//wSo///Uq///d6v//66r//8EqP//xqz//wSo//8EqP//FK3//wSo//8EqP//BKj//wSo//8EqP//BKj//8yu//8EqP//BKj//wSo//8EqP//VKj//wSo//8EqP//BKj//wSo//8EqP//BKj//wSo//8EqP//K63//wSo//85rf//0qj//7ut//+frf//ra3//zGs///SqP//raj//wSo//9UrP//d6z//5Cs//9UqP//Kqn//wSo//8EqP//da3//62o//9UqP//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Mh4AAOzwAABAHgAAQx4AAPzwAABQHgAASB8AAADxAABQHwAAUx8AABzxAABgHwAAYx8AACDxAABwHwAA2R8AACTxAADgHwAAQiEAADTxAABQIQAArSQAAETxAACwJAAA6iQAAFzxAADwJAAA/CQAAGjxAAAAJQAAvSYAAGzxAADAJgAAOycAAHjxAABAJwAAvycAAIzxAADAJwAAWSgAAJzxAABgKAAAUikAAKzxAABgKQAAjCkAALjxAACQKQAA4CkAALzxAADgKQAAhioAAMDxAACQKgAAECsAANDxAAAQKwAARysAANTxAABQKwAAwysAANjxAADQKwAABiwAANzxAAAQLAAAmSwAAODxAACgLAAAXi0AAOTxAACgLQAA6C0AAOjxAADwLQAAXS4AAPjxAABgLgAATC8AAAjyAABQLwAAqC8AABTyAACwLwAATjEAACDyAABQMQAAlDIAADjyAACgMgAA7zIAAEjyAADwMgAAgTMAAFjyAACQMwAAqTgAAGTyAACwOAAAWTwAAHzyAABgPAAArj0AAJTyAACwPQAAhkEAAKjyAACQQQAAZ0IAALzyAABwQgAAD0MAAMzyAAAQQwAA70MAANzyAADwQwAASEUAAOzyAABQRQAAA0oAAPzyAAAQSgAAG1QAABTzAAAgVAAAe1QAADDzAACAVAAA/lUAADzzAAAAVgAAkVYAAFDzAACgVgAAFlcAAFzzAAAgVwAAb1cAAGzzAABwVwAAXFgAAHzzAABgWAAALVoAAIjzAAAwWgAABl4AAJzzAAAQXgAA914AALDzAAAAXwAAKWQAAMDzAAAwZAAA6WcAANjzAADwZwAAo2wAAPDzAACwbAAAh20AAAj0AACQbQAAL24AABj0AAAwbgAAiG8AACj0AACQbwAAHXoAADj0AAAgegAAYHoAAFT0AABgegAA3HoAAGD0AADgegAAB3sAAHD0AAAQewAAjXwAAHT0AACQfAAAo5IAAIz0AACwkgAAupMAAKj0AADAkwAA+pMAALz0AAAAlAAA6ZQAAMD0AADwlAAAO5UAAND0AABAlQAAM5YAANz0AABAlgAArJYAAOz0AACwlgAAaZcAAPj0AABwlwAALZgAAAz1AAAwmAAAl5kAABj1AACgmQAAIpsAADD1AAAwmwAAVpwAAET1AABgnAAAqJwAAFz1AACwnAAA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AAAAAAAAAAAAAAAAjQBDbG9zZUhhbmRsZQDRAENyZWF0ZUZpbGVNYXBwaW5nVwAA1ABDcmVhdGVGaWxlVwDtAENyZWF0ZVByb2Nlc3NXAAAZAURlbGV0ZUNyaXRpY2FsU2VjdGlvbgA9AUVudGVyQ3JpdGljYWxTZWN0aW9uAABOAkdldEV4aXRDb2RlUHJvY2VzcwAAXwJHZXRGaWxlU2l6ZQB0AkdldExhc3RFcnJvcgAAiAJHZXRNb2R1bGVGaWxlTmFtZVcAAHoDSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbgCVA0lzREJDU0xlYWRCeXRlRXgAANYDTGVhdmVDcml0aWNhbFNlY3Rpb24AAPkDTWFwVmlld09mRmlsZQAKBE11bHRpQnl0ZVRvV2lkZUNoYXIAkARSZWFkRmlsZQAAbwVTZXRVbmhhbmRsZWRFeGNlcHRpb25GaWx0ZXIAfwVTbGVlcACiBVRsc0dldFZhbHVlALMFVW5tYXBWaWV3T2ZGaWxlANEFVmlydHVhbFByb3RlY3QAANMFVmlydHVhbFF1ZXJ5AADcBVdhaXRGb3JTaW5nbGVPYmplY3QACAZXaWRlQ2hhclRvTXVsdGlCeXRlADgAX19DX3NwZWNpZmljX2hhbmRsZXIAAEAAX19fbGNfY29kZXBhZ2VfZnVuYwBDAF9fX21iX2N1cl9tYXhfZnVuYwAAVABfX2lvYl9mdW5jAABhAF9fc2V0X2FwcF90eXBlAABjAF9fc2V0dXNlcm1hdGhlcnIAAG4AX193Z2V0bWFpbmFyZ3MAAG8AX193aW5pdGVudgAAeABfYW1zZ19leGl0AACJAF9jZXhpdAAAlQBfY29tbW9kZQAAvABfZXJybm8AAMoDZndwcmludGYAANsAX2Ztb2RlAAAdAV9pbml0dGVybQCDAV9sb2NrACkCX29uZXhpdADKAl91bmxvY2sAPQNfd2ZvcGVuAIcDYWJvcnQAmANjYWxsb2MAAKUDZXhpdAAAqQNmY2xvc2UAALEDZmdldHdzAAC5A2ZwcmludGYAuwNmcHV0YwC9A2ZwdXR3YwAAwANmcmVlAADNA2Z3cml0ZQAA9gNsb2NhbGVjb252AAD9A21hbGxvYwAABQRtZW1jcHkAAAcEbWVtc2V0AAAlBHNpZ25hbAAAOgRzdHJlcnJvcgAAPARzdHJsZW4AAD8Ec3RybmNtcABgBHZmcHJpbnRmAAB2BHdjc2NweQAAegR3Y3NsZW4AAIIEd2NzcmNocgAAAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAAAQAQAAEAEAABABAEtFUk5FTDMyLmRsbAAAAAAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABABQQAQAUEAEAFBABAG1zdmNydC5kbGwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEARAEABAAAAAAAAAAAAAAAAAAAAAAAAABAQAEABAAAAAAAAAAAAAAAAAAAAAAAAALAdAEABAAAAgB0AQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKAAAAwAAADYqQAAALAAABwAAAAAoICgkKCgoLCguKDAoMig0KAAAADAAABMAAAAwKPgo+ij8KP4o2CscKyArJCsoKywrMCs0KzgrPCsAK0QrSCtMK1ArVCtYK1wrYCtkK2grbCtwK3QreCt8K0ArhCuAAAAIAEAEAAAAAigIKA4oECgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA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ESOVDAAAAUV4Y2VwdGlvbkxpc3QAWBEupgsAAAABU3RhY2tCYXNlAFkRDQQGAAAIAVN0YWNrTGltaXQAWhENBAYAABABU3ViU3lzdGVtVGliAFsRDQQGAAAYJ9MLAAAgAUFyYml0cmFyeVVzZXJQb2ludGVyAGARDQQGAAAoAVNlbGYAYREXlQwAADAABf0LAAAGTlRfVElCAGIRB/0LAAAGUE5UX1RJQgBjERW5DAAABZoMAAAySk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAJMBAAACihMSkA0AAANKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEDSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgNKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABANKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAOX0lNQUdFX0RPU19IRUFERVIAQPMbFOUOAAABZV9tYWdpYwD0Gwx/BQAAAAFlX2NibHAA9RsMfwUAAAIBZV9jcAD2Gwx/BQAABAFlX2NybGMA9xsMfwUAAAYBZV9jcGFyaGRyAPgbDH8FAAAIAWVfbWluYWxsb2MA+RsMfwUAAAoBZV9tYXhhbGxvYwD6Gwx/BQAADAFlX3NzAPsbDH8FAAAOAWVfc3AA/BsMfwUAABABZV9jc3VtAP0bDH8FAAASAWVfaXAA/hsMfwUAABQBZV9jcwD/Gwx/BQAAFgFlX2xmYXJsYwAAHAx/BQAAGAFlX292bm8AARwMfwUAABoBZV9yZXMAAhwM5Q4AABwBZV9vZW1pZAADHAx/BQAAJAFlX29lbWluZm8ABBwMfwUAACYBZV9yZXMyAAUcDPUOAAAoAWVfbGZhbmV3AAYcDBIGAAA8ABZ/BQAA9Q4AAA8OAQAAAwAWfwUAAAUPAAAPDgEAAAkABklNQUdFX0RPU19IRUFERVIABxwHkA0AAAZQSU1BR0VfRE9TX0hFQURFUgAHHBk4DwAABZANAAAOX0lNQUdFX0ZJTEVfSEVBREVSABRiHBQKEAAAAU1hY2hpbmUAYxwMfwUAAAABTnVtYmVyT2ZTZWN0aW9ucwBkHAx/BQAAAgFUaW1lRGF0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ABEDVlRfVUkyABIDVlRfVUk0ABMDVlRfSTgAFANWVF9VSTgAFQNWVF9JTlQAFgNWVF9VSU5UABcDVlRfVk9JRAAYA1ZUX0hSRVNVTFQAGQNWVF9QVFIAGgNWVF9TQUZFQVJSQVkAGwNWVF9DQVJSQVkAHANWVF9VU0VSREVGSU5FRAAdA1ZUX0xQU1RSAB4DVlRfTFBXU1RSAB8DVlRfUkVDT1JEACQDVlRfSU5UX1BUUgAlA1ZUX1VJTlRfUFRSACYDVlRfRklMRVRJTUUAQANWVF9CTE9CAEEDVlRfU1RSRUFNAEIDVlRfU1RPUkFHRQBDA1ZUX1NUUkVBTUVEX09CSkVDVABEA1ZUX1NUT1JFRF9PQkpFQ1QARQNWVF9CTE9CX09CSkVDVABGA1ZUX0NGAEcDVlRfQ0xTSUQASANWVF9WRVJTSU9ORURfU1RSRUFNAEkSVlRfQlNUUl9CTE9CAP8PElZUX1ZFQ1RPUgAAEBJWVF9BUlJBWQAAIBJWVF9CWVJFRgAAQBJWVF9SRVNFUlZFRAAAgBJWVF9JTExFR0FMAP//ElZUX0lMTEVHQUxNQVNLRUQA/w8SVlRfVFlQRU1BU0sA/w8AB19kb3dpbGRjYXJkAAxgDnYBAAAHX25ld21vZGUADGEOdgEAAAdfX2ltcF9fX3dpbml0ZW52AAxkFI0HAABFBAx5C7gYAAAZbmV3bW9kZQAMegl2AQAAAAAJX3N0YXJ0dXBpbmZvAAx7BZ0YAABG+AAAAAcEkwEAAAyEEBMZAAADX191bmluaXRpYWxpemVkAAADX19pbml0aWFsaXppbmcAAQNfX2luaXRpYWxpemVkAAIAR/gAAAAMhgXNGAAALRMZAAAHX19uYXRpdmVfc3RhcnR1cF9zdGF0ZQAMiCsfGQAAB19fbmF0aXZlX3N0YXJ0dXBfbG9jawAMiRlhGQAABWYZAABICV9QVkZWAA0UGDsHAAAJX1BJRlYADRUXJwcAAAVnGQAASV9leGNlcHRpb24AKA6jCuUZAAAZdHlwZQAOpAl2AQAAABluYW1lAA6lEeUZAAAIGWFyZzEADqYMMQcAABAZYXJnMgAOpwwxBwAAGBlyZXR2YWwADqgMMQcAACAABfoAAAAJX1RDSEFSAA9uE0sBAAAHX19pbWFnZV9iYXNlX18AASsZBQ8AAAdfZm1vZGUA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BHB0cmRpZmZfdAAFWCMUAQAAAgIHc2hvcnQgdW5zaWduZWQgaW50AAIEBWludAACBAVsb25nIGludAACBAd1bnNpZ25lZCBpbnQAAgQHbG9uZyB1bnNpZ25lZCBpbnQAAgEIdW5zaWduZWQgY2hhcgACBARmbG9hdAACAQZzaWduZWQgY2hhcgACAgVzaG9ydCBpbnQAAhAEbG9uZyBkb3VibGUAAggEZG91YmxlAAXZAQAADAICBF9GbG9hdDE2AAICBF9fYmYxNgAGSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAGABAAACihMSwgIAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwANdGFnQ09JTklUQkFTRQAHBGABAAADlQ76AgAAAUNPSU5JVEJBU0VfTVVMVElUSFJFQURFRAAAAAZWQVJFTlVNAGABAAAECQIGhAUAAAFWVF9FTVBUWQAAAVZUX05VTEwAAQFWVF9JMgACAVZUX0k0AAMBVlRfUjQABAFWVF9SOAAFAVZUX0NZAAYBVlRfREFURQAHAVZUX0JTVFIACAFWVF9ESVNQQVRDSAAJAVZUX0VSUk9SAAoBVlRfQk9PTAALAVZUX1ZBUklBTlQADAFWVF9VTktOT1dOAA0BVlRfREVDSU1BTAAOAVZUX0kxABABVlRfVUkxABEBVlRfVUkyABIBVlRfVUk0ABMBVlRfSTgAFAFWVF9VSTgAFQFWVF9JTlQAFgFWVF9VSU5UABcBVlRfVk9JRAAYAVZUX0hSRVNVTFQAGQFWVF9QVFIAGgFWVF9TQUZFQVJSQVkAGwFWVF9DQVJSQVkAHAFWVF9VU0VSREVGSU5FRAAdAVZUX0xQU1RSAB4BVlRfTFBXU1RSAB8BVlRfUkVDT1JEACQBVlRfSU5UX1BUUgAlAVZUX1VJTlRfUFRSACYBVlRfRklMRVRJTUUAQAFWVF9CTE9CAEEBVlRfU1RSRUFNAEIBVlRfU1RPUkFHRQBDAVZUX1NUUkVBTUVEX09CSkVDVABEAVZUX1NUT1JFRF9PQkpFQ1QARQFWVF9CTE9CX09CSkVDVABGAVZUX0NGAEcBVlRfQ0xTSUQASAFWVF9WRVJTSU9ORURfU1RSRUFNAEkDVlRfQlNUUl9CTE9CAP8PA1ZUX1ZFQ1RPUgAAEANWVF9BUlJBWQAAIANWVF9CWVJFRgAAQANWVF9SRVNFUlZFRAAAgANWVF9JTExFR0FMAP//A1ZUX0lMTEVHQUxNQVNLRUQA/w8DVlRfVFlQRU1BU0sA/w8ABGZ1bmNfcHRyAAELENQBAAAOhAUAAKAFAAAPAAdfX0NUT1JfTElTVF9fAAyVBQAAB19fRFRPUl9MSVNUX18ADZUFAAAIaW5pdGlhbGl6ZWQAMgxNAQAACQMwAAFAAQAAABBhdGV4aXQABqkBD00BAAD/BQAAEdQBAAAAEl9fbWFpbgABNQFgHQBAAQAAAB8AAAAAAAAAAZwuBgAAE38dAEABAAAALgYAAAAJX19kb19nbG9iYWxfY3RvcnMAIOAcAEABAAAAegAAAAAAAAABnJgGAAAKbnB0cnMAInABAADaAQAA1AEAAAppACNwAQAA8gEAAO4BAAAUNh0AQAEAAADlBQAAFQFSCQOQHABAAQAAAAAACV9fZG9fZ2xvYmFsX2R0b3JzABSQHABAAQAAAEMAAAAAAAAAAZzWBgAACHAAFhTWBgAACQMAsABAAQAAAAAFhAUAAAB5BgAABQABCMIGAAAIR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdxAIAAAMDAAByBQAAAgEGY2hhcgACCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAIIBWxvbmcgbG9uZyBpbnQAAgIHc2hvcnQgdW5zaWduZWQgaW50AAIEBWludAACBAVsb25nIGludAACBAd1bnNpZ25lZCBpbnQABj4BAAACBAdsb25nIHVuc2lnbmVkIGludAACAQh1bnNpZ25lZCBjaGFyAAIEBGZsb2F0AAIBBnNpZ25lZCBjaGFyAAICBXNob3J0IGludAACEARsb25nIGRvdWJsZQACCARkb3VibGUAAgIEX0Zsb2F0MTYAAgIEX19iZjE2AAdKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAPgEAAAGKExKfAgAAAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAAl0YWdDT0lOSVRCQVNFAAcEPgEAAAKVDtcCAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAB1ZBUkVOVU0APgEAAAMJAgZhBQAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQNWVF9CU1RSX0JMT0IA/w8DVlRfVkVDVE9SAAAQA1ZUX0FSUkFZAAAgA1ZUX0JZUkVGAABAA1ZUX1JFU0VSVkVEAACAA1ZUX0lMTEVHQUwA//8DVlRfSUxMRUdBTE1BU0tFRAD/DwNWVF9UWVBFTUFTSwD/DwAKHwIAAAcEPgEAAASEEKcFAAABX191bmluaXRpYWxpemVkAAABX19pbml0aWFsaXppbmcAAQFfX2luaXRpYWxpemVkAAIACx8CAAAEhgVhBQAABqcFAAAEX19uYXRpdmVfc3RhcnR1cF9zdGF0ZQCIK7MFAAAEX19uYXRpdmVfc3RhcnR1cF9sb2NrAIkZ8wUAAAwI+QUAAA0EX19uYXRpdmVfZGxsbWFpbl9yZWFzb24AiyBOAQAABF9fbmF0aXZlX3ZjY2xyaXRfcmVhc29uAIwgTgEAAAX6BQAACxcJAxSwAEABAAAABRkGAAAMFwkDELAAQAEAAAAFuAUAAA0iCQNIAAFAAQAAAAXWBQAADhAJA0AAAUABAAAAAAQBAAAFAAEIeAcAAAFHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB3cAwAAGwQAAMgFAAACX2Rvd2lsZGNhcmQAASAFAAEAAAkDUAABQAEAAAADBAVpbnQAAAEBAAAFAAEIpgcAAAFHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB1zBAAAsgQAAAIGAAACX25ld21vZGUAAQcF/QAAAAkDYAABQAEAAAADBAVpbnQAAD4IAAAFAAEI1AcAABJHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB0RBQAACgUAAIAdAEABAAAAwwAAAAAAAAA8BgAAAQEGY2hhcgABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAA3VpbnRwdHJfdAACSyz6AAAAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAAI8gAAAAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyABMIA1VMT05HAAMYHXUBAAADV0lOQk9PTAADfw1NAQAAA0JPT0wAA4MPTQEAAANEV09SRAADjR11AQAAAQQEZmxvYXQAA0xQVk9JRAADmRGbAQAAAQEGc2lnbmVkIGNoYXIAAQIFc2hvcnQgaW50AANVTE9OR19QVFIABDEu+gAAAARQVk9JRAALARGbAQAABEhBTkRMRQCfARGbAQAABFVMT05HTE9ORwD1AS76AAAAARAEbG9uZyBkb3VibGUAAQgEZG91YmxlAAhpAgAAFAECBF9GbG9hdDE2AAECBF9fYmYxNgAVSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAAcEZQEAAAWKExJUAwAACUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQlKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACCUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAECUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAH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aXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHXMIAACyCAAAYB8AQAEAAAADAAAAAAAAANgIAAACX2ZwcmVzZXQAAQkGYB8AQAEAAAADAAAAAAAAAAGcAAkBAAAFAAEItgsAAAFHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB0RCQAACgkAADAJAAACX19taW5nd19hcHBfdHlwZQABCAUFAQAACQOQAAFAAQAAAAMEBWludAAAxBcAAAUAAQjkCwAAJ0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbAJAADzCQAAcB8AQAEAAAA9BQAAAAAAAGoJAAAGX19nbnVjX3ZhX2xpc3QAAhgdCQEAACgIX19idWlsdGluX3ZhX2xpc3QAIQEAAAcBBmNoYXIAKSEBAAAGdmFfbGlzdAACHxryAAAABnNpemVfdAADIyxNAQAABwgHbG9uZyBsb25nIHVuc2lnbmVkIGludAAHCAVsb25nIGxvbmcgaW50AAZwdHJkaWZmX3QAA1gjZwEAAAcCB3Nob3J0IHVuc2lnbmVkIGludAAHBAVpbnQABwQFbG9uZyBpbnQACSEBAAAHBAd1bnNpZ25lZCBpbnQABwQHbG9uZyB1bnNpZ25lZCBpbnQABwEIdW5zaWduZWQgY2hhcgAqCAZVTE9ORwAEGB3IAQAABldJTkJPT0wABH8NoAEAAAZCWVRFAASLGd0BAAAGV09SRAAEjBqKAQAABkRXT1JEAASNHcgBAAAHBARmbG9hdAAGUEJZVEUABJARTQIAAAkOAgAABkxQQllURQAEkRFNAgAABlBEV09SRAAElxJwAgAACSgCAAAGTFBWT0lEAASZEe4BAAAGTFBDVk9JRAAEnBeUAgAACZkCAAArBwEGc2lnbmVkIGNoYXIABwIFc2hvcnQgaW50AAZVTE9OR19QVFIABTEuTQEAAAZTSVpFX1QABZMntgIAAA9QVk9JRAALARHuAQAAD0xPTkcAKQEUpwEAAAcQBGxvbmcgZG91YmxlAAcIBGRvdWJsZQAHAgRfRmxvYXQxNgAHAgRfX2JmMTYAHkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwC4AQAABooTEvMDAAABSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAFV9NRU1PUllfQkFTSUNfSU5GT1JNQVRJT04AMPMVtQQAAAJCYXNlQWRkcmVzcwD0FQ3XAgAAAAJBbGxvY2F0aW9uQmFzZQD1FQ3XAgAACAJBbGxvY2F0aW9uUHJvdGVjdAD2FQ0oAgAAEAJQYXJ0aXRpb25JZAD4FQwbAgAAFAJSZWdpb25TaXplAPoVDsgCAAAYAlN0YXRlAPsVDSgCAAAgAlByb3RlY3QA/BUNKAIAACQCVHlwZQD9FQ0oAgAAKAAPTUVNT1JZX0JBU0lDX0lORk9STUFUSU9OAP4VB/MDAAAPUE1FTU9SWV9CQVNJQ19JTkZPUk1BVElPTgD+FSH4BAAACfMDAAAWDgIAAA0FAAAXTQEAAAcAFV9JTUFHRV9ET1NfSEVBREVSAEDzG2EGAAACZV9tYWdpYwD0GwwbAgAAAAJlX2NibHAA9RsMGwIAAAICZV9jcAD2GwwbAgAABAJlX2NybGMA9xsMGwIAAAYCZV9jcGFyaGRyAPgbDBsCAAAIAmVfbWluYWxsb2MA+RsMGwIAAAoCZV9tYXhhbGxvYwD6GwwbAgAADAJlX3NzAPsbDBsCAAAOAmVfc3AA/BsMGwIAABACZV9jc3VtAP0bDBsCAAASAmVfaXAA/hsMGwIAABQCZV9jcwD/GwwbAgAAFgJlX2xmYXJsYwAAHAwbAgAAGAJlX292bm8AARwMGwIAABoCZV9yZXMAAhwMYQYAABwCZV9vZW1pZAADHAwbAgAAJAJlX29lbWluZm8ABBwMGwIAACYCZV9yZXMyAAUcDHEGAAAoAmVfbGZhbmV3AAYcDOUCAAA8ABYbAgAAcQYAABdNAQAAAwAWGwIAAIEGAAAXTQEAAAkAD0lNQUdFX0RPU19IRUFERVIABxwHDQUAACwEBoAdB88GAAAfUGh5c2ljYWxBZGRyZXNzAIEdKAIAAB9WaXJ0dWFsU2l6ZQCCHSgCAAAAFV9JTUFHRV9TRUNUSU9OX0hFQURFUgAofh3iBwAAAk5hbWUAfx0M/QQAAAACTWlzYwCDHQmaBgAACAJWaXJ0dWFsQWRkcmVzcwCEHQ0oAgAADAJTaXplT2ZSYXdEYXRhAIUdDSgCAAAQAlBvaW50ZXJUb1Jhd0RhdGEAhh0NKAIAABQCUG9pbnRlclRvUmVsb2NhdGlvbnMAhx0NKAIAABgCUG9pbnRlclRvTGluZW51bWJlcnMAiB0NKAIAABwCTnVtYmVyT2ZSZWxvY2F0aW9ucwCJHQwbAgAAIAJOdW1iZXJPZkxpbmVudW1iZXJzAIodDBsCAAAiAkNoYXJhY3RlcmlzdGljcwCLHQ0oAgAAJAAPUElNQUdFX1NFQ1RJT05fSEVBREVSAIwdHQAIAAAJzwYAAC10YWdDT0lOSVRCQVNFAAcEuAEAAAeVDj0IAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAHlZBUkVOVU0AuAEAAAgJAgbHCgAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQ5WVF9CU1RSX0JMT0IA/w8OVlRfVkVDVE9SAAAQDlZUX0FSUkFZAAAgDlZUX0JZUkVGAABADlZUX1JFU0VSVkVEAACADlZUX0lMTEVHQUwA//8OVlRfSUxMRUdBTE1BU0tFRAD/Dw5WVF9UWVBFTUFTSwD/DwAuX2lvYnVmADAJIQpXCwAABV9wdHIACSULswEAAAAFX2NudAAJJgmgAQAACAVfYmFzZQAJJwuzAQAAEAVfZmxhZwAJKAmgAQAAGAVfZmlsZQAJKQmgAQAAHAVfY2hhcmJ1ZgAJKgmgAQAAIAVfYnVmc2l6AAkrCaABAAAkBV90bXBmbmFtZQAJLAuzAQAAKAAGRklMRQAJLxnHCgAAGF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fADENIQEAABhfX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfRU5EX18AMg0hAQAAGF9faW1hZ2VfYmFzZV9fADMZgQYAABkIPPALAAAFYWRkZW5kAAE9CSgCAAAABXRhcmdldAABPgkoAgAABAAGcnVudGltZV9wc2V1ZG9fcmVsb2NfaXRlbV92MQABPwPICwAAGQxHSQwAAAVzeW0AAUgJKAIAAAAFdGFyZ2V0AAFJCSgCAAAEBWZsYWdzAAFKCSgCAAAIAAZydW50aW1lX3BzZXVkb19yZWxvY19pdGVtX3Yy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MQBIBwgSBgAAUAEFWG1tMTIASQcIEgYAAGABBVhtbTEzAEoHCBIGAABwAQVYbW0xNABLBwgSBgAAgAEFWG1tMTUATAcIEgYAAJABAA8SBgAAIwkAAA36AAAAAQAfAAIQAjcHFFYJAAAXRmx0U2F2ZQA4B94HAAAXRmxvYXRTYXZlADkH3gcAACD2BwAAEAAPEgYAAGYJAAAN+gAAABkACFBDT05URVhUAFYHDkQCAAAWhAUAAIcJAAAN+gAAAA4ACEVYQ0VQVElPTl9SRUNPUkQAYgsHmQEAAAhQRVhDRVBUSU9OX1JFQ09SRABkCx+6CQAAC4cJAAASX0VYQ0VQVElPTl9QT0lOVEVSUwAQeQsACgAAE18CAAB6CxmgCQAAAAFDb250ZXh0UmVjb3JkAHsLEGYJAAAIAAhFWENFUFRJT05fUE9JTlRFUlMAfAsHvwkAAAu/CQAAGEpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwBOAQAAAooTEvIKAAACSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAICSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQCSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAC/cKAAAhtAUAAAYLAAAOGwoAAAAHUFRPUF9MRVZFTF9FWENFUFRJT05fRklMVEVSAAURF/IKAAAHTFBUT1BfTEVWRUxfRVhDRVBUSU9OX0ZJTFRFUgAFEiUGCwAAInRhZ0NPSU5JVEJBU0UABwROAQAABpUOhwsAAAJDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAYVkFSRU5VTQBOAQAABwkCBhEOAAACVlRfRU1QVFkAAAJWVF9OVUxMAAECVlRfSTIAAgJWVF9JNAADAlZUX1I0AAQCVlRfUjgABQJWVF9DWQAGAlZUX0RBVEUABwJWVF9CU1RSAAgCVlRfRElTUEFUQ0gACQJWVF9FUlJPUgAKAlZUX0JPT0wACwJWVF9WQVJJQU5UAAwCVlRfVU5LTk9XTgANAlZUX0RFQ0lNQUwADgJWVF9JMQAQAlZUX1VJMQARAlZUX1VJMgASAlZUX1VJNAATAlZUX0k4ABQCVlRfVUk4ABUCVlRfSU5UABYCVlRfVUlOVAAXAlZUX1ZPSUQAGAJWVF9IUkVTVUxUABkCVlRfUFRSABoCVlRfU0FGRUFSUkFZABsCVlRfQ0FSUkFZABwCVlRfVVNFUkRFRklORUQAHQJWVF9MUFNUUgAeAlZUX0xQV1NUUgAfAlZUX1JFQ09SRAAkAlZUX0lOVF9QVFIAJQJWVF9VSU5UX1BUUgAmAlZUX0ZJTEVUSU1FAEACVlRfQkxPQgBBAlZUX1NUUkVBTQBCAlZUX1NUT1JBR0UAQwJWVF9TVFJFQU1FRF9PQkpFQ1QARAJWVF9TVE9SRURfT0JKRUNUAEUCVlRfQkxPQl9PQkpFQ1QARgJWVF9DRgBHAlZUX0NMU0lEAEgCVlRfVkVSU0lPTkVEX1NUUkVBTQBJCVZUX0JTVFJfQkxPQgD/DwlWVF9WRUNUT1IAABAJVlRfQVJSQVkAACAJVlRfQllSRUYAAEAJVlRfUkVTRVJWRUQAAIAJVlRfSUxMRUdBTAD//wlWVF9JTExFR0FMTUFTS0VEAP8PCVZUX1RZUEVNQVNLAP8PAAdfX3Bfc2lnX2ZuX3QACDAShAEAACNfX21pbmd3X29sZGV4Y3B0X2hhbmRsZXIAAbAeKgsAAAkD0AABQAEAAAAkX2ZwcmVzZXQAAR8NJXNpZ25hbAAIPBgRDgAAfA4AAA47AQAADhEOAAAAJl9nbnVfZXhjZXB0aW9uX2hhbmRsZXIAAbgBQgEAAAAlAEABAAAAvQEAAAAAAAABnFYQAAAnZXhjZXB0aW9uX2RhdGEAAbgtVhAAAK8JAAChCQAAEG9sZF9oYW5kbGVyALoKhAEAAPQJAADkCQAAEGFjdGlvbgC7CEIBAABFCgAAKwoAABByZXNldF9mcHUAvAc7AQAAvwoAALEKAAAKZCUAQAEAAABeDgAANg8AAAMBUgE4AwFRATAAKI8lAEABAAAASw8AAAMBUgOjAVIACrclAEABAAAAXg4AAGcPAAADAVIBNAMBUQEwABHNJQBAAQAAAHoPAAADAVIBNAAKHCYAQAEAAABeDgAAlg8AAAMBUgE4AwFRATAACjUmAEABAAAAXg4AALIPAAADAVIBOAMBUQExAApMJgBAAQAAAF4OAADODwAAAwFSATsDAVEBMAARYiYAQAEAAADhDwAAAwFSATsAEXcmAEABAAAA9A8AAAMBUgE4AAqLJgBAAQAAAF4OAAAQEAAAAwFSATsDAVEBMQAKnyYAQAEAAABeDgAALBAAAAMBUgE0AwFRATEACrMmAEABAAAAXg4AAEgQAAADAVIBOAMBUQExACm4JgBAAQAAAFEOAAAACwAKAAAASgsAAAUAAQh6EwAAGEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHW8NAABoDQAAwCYAQAEAAACSAgAAAAAAAGARAAACAQZjaGFyAARzaXplX3QAAiMsCQEAAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50ABNKAQAAAgQFbG9uZyBpbnQAAgQHdW5zaWduZWQgaW50AAIEB2xvbmcgdW5zaWduZWQgaW50AAIBCHVuc2lnbmVkIGNoYXIAGQgEV0lOQk9PTAADfw1KAQAABFdPUkQAA4waNAEAAAREV09SRAADjR1yAQAAAgQEZmxvYXQABExQVk9JRAADmRGYAQAAAgEGc2lnbmVkIGNoYXIAAgIFc2hvcnQgaW50AARVTE9OR19QVFIABDEuCQEAAAdMT05HACkBFFYBAAAHSEFORExFAJ8BEZgBAAAPX0xJU1RfRU5UUlkAEHECElsCAAABRmxpbmsAcgIZWwIAAAABQmxpbmsAcwIZWwIAAAgACCcCAAAHTElTVF9FTlRSWQB0AgUnAgAAAhAEbG9uZyBkb3VibGUAAggEZG91YmxlAAICBF9GbG9hdDE2AAICBF9fYmYxNgAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAAcEYgEAAAWKExJ2AwAAC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQtKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA9fUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcAMNIjFG4EAAABVHlwZQDTIwyqAQAAAAFDcmVhdG9yQmFja1RyYWNlSW5kZXgA1CMMqgEAAAIBQ3JpdGljYWxTZWN0aW9uANUjJQwFAAAIAVByb2Nlc3NMb2Nrc0xpc3QA1iMSYAIAABABRW50cnlDb3VudADXIw23AQAAIAFDb250ZW50aW9uQ291bnQA2CMNtwEAACQBRmxhZ3MA2SMNtwEAACgBQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaADaIwyqAQAALAFTcGFyZVdPUkQA2yMMqgEAAC4AD19SVExfQ1JJVElDQUxfU0VDVElPTgAo7SMUDAUAAAFEZWJ1Z0luZm8A7iMjEQUAAAABTG9ja0NvdW50AO8jDAsCAAAIAVJlY3Vyc2lvbkNvdW50APAjDAsCAAAMAU93bmluZ1RocmVhZADxIw4YAgAAEAFMb2NrU2VtYXBob3JlAPIjDhgCAAAYAVNwaW5Db3VudADzIxH5AQAAIAAIbgQAAAdQUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcA3CMjNQUAAAh2AwAAB1JUTF9DUklUSUNBTF9TRUNUSU9OAPQjB24EAAAHUFJUTF9DUklUSUNBTF9TRUNUSU9OAPQjHQwFAAAEQ1JJVElDQUxfU0VDVElPTgAGqyA6BQAABExQQ1JJVElDQUxfU0VDVElPTgAGrSFXBQAACK4FAAAbuQUAAAWYAQAAABBfX21pbmd3dGhyX2NzABoZdQUAAAkDAAEBQAEAAAAQX19taW5nd3Rocl9jc19pbml0ABsVUQEAAAkD6AABQAEAAAAEX19taW5nd3Rocl9rZXlfdAABHR8aBgAAE/wFAAAcX19taW5nd3Rocl9rZXkAGAEgCFkGAAARa2V5ACEJtwEAAAARZHRvcgAiCqkFAAAIEW5leHQAIx5ZBgAAEAAIFQYAABBrZXlfZHRvcl9saXN0ACcjWQYAAAkD4AABQAEA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ZV9jcwD/Gwy3AQAAFgFlX2xmYXJsYwAAHAy3AQAAGAFlX292bm8AARwMtwEAABoBZV9yZXMAAhwM7wMAABwBZV9vZW1pZAADHAy3AQAAJAFlX29lbWluZm8ABBwMtwEAACYBZV9yZXMyAAUcDP8DAAAoAWVfbGZhbmV3AAYcDD0CAAA8ABK3AQAA/wMAABPyAAAAAwAStwEAAA8EAAAT8gAAAAkAB0lNQUdFX0RPU19IRUFERVIABxwHmwIAAAdQSU1BR0VfRE9TX0hFQURFUgAHHBlCBAAADJsCAAAOX0lNQUdFX0ZJTEVfSEVBREVSABRiHP0EAAABTWFjaGluZQBjHAy3AQAAAAFOdW1iZXJPZlNlY3Rpb25zAGQcDLcBAAACD3gCAABlHA3EAQAABAFQb2ludGVyVG9TeW1ib2xUYWJsZQBmHA3EAQAACAFOdW1iZXJPZlN5bWJvbHMAZxwNxAEAAAwBU2l6ZU9mT3B0aW9uYWxIZWFkZXIAaBwMtwEAABAPkAIAAGkcDLcBAAASAAdJTUFHRV9GSUxFX0hFQURFUgBqHAdHBAAADl9JTUFHRV9EQVRBX0RJUkVDVE9SWQAInxxRBQAAD6sCAACgHA3EAQAAAAFTaXplAKEcDcQBAAAEAAdJTUFHRV9EQVRBX0RJUkVDVE9SWQCiHAcXBQAAElEFAAB+BQAAE/IAAAAPAA5fSU1BR0VfT1BUSU9OQUxfSEVBREVSNjQA8NkcqwgAAAFNYWdpYwDaHAy3AQAAAAFNYWpvckxpbmtlclZlcnNpb24A2xwMqgEAAAIBTWlub3JMaW5rZXJWZXJzaW9uANwcDKoBAAADAVNpemVPZkNvZGUA3RwNxAEAAAQBU2l6ZU9mSW5pdGlhbGl6ZWREYXRhAN4cDcQBAAAIAVNpemVPZlVuaW5pdGlhbGl6ZWREYXRhAN8cDcQBAAAMAUFkZHJlc3NPZkVudHJ5UG9pbnQA4BwNxAEAABABQmFzZU9mQ29kZQDhHA3EAQAAFAFJbWFnZUJhc2UA4hwRSgIAABgBU2VjdGlvbkFsaWdubWVudADjHA3EAQAAIAFGaWxlQWxpZ25tZW50AOQcDcQBAAAkAU1ham9yT3BlcmF0aW5nU3lzdGVtVmVyc2lvbgDlHAy3AQAAKAFNaW5vck9wZXJhdGluZ1N5c3RlbVZlcnNpb24A5hwMtwEAACoBTWFqb3JJbWFnZVZlcnNpb24A5xwMtwEAACwBTWlub3JJbWFnZVZlcnNpb24A6BwMtwEAAC4BTWFqb3JTdWJzeXN0ZW1WZXJzaW9uAOkcDLcBAAAwAU1pbm9yU3Vic3lzdGVtVmVyc2lvbgDqHAy3AQAAMgFXaW4zMlZlcnNpb25WYWx1ZQDrHA3EAQAANAFTaXplT2ZJbWFnZQDsHA3EAQAAOAFTaXplT2ZIZWFkZXJzAO0cDcQBAAA8AUNoZWNrU3VtAO4cDcQBAABAAVN1YnN5c3RlbQDvHAy3AQAARAFEbGxDaGFyYWN0ZXJpc3RpY3MA8BwMtwEAAEYBU2l6ZU9mU3RhY2tSZXNlcnZlAPEcEUoCAABIAVNpemVPZlN0YWNrQ29tbWl0APIcEUoCAABQAVNpemVPZkhlYXBSZXNlcnZlAPMcEUoCAABYAVNpemVPZkhlYXBDb21taXQA9BwRSgIAAGABTG9hZGVyRmxhZ3MA9RwNxAEAAGgBTnVtYmVyT2ZSdmFBbmRTaXplcwD2HA3EAQAAbAFEYXRhRGlyZWN0b3J5APccHG4FAABwAAdJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HAd+BQAAB1BJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HCDsCAAADH4FAAAHUElNQUdFX09QVElPTkFMX0hFQURFUgAFHSbLCAAAIl9JTUFHRV9OVF9IRUFERVJTNjQACAEFDx0UbwkAAAFTaWduYXR1cmUAEB0NxAEAAAABRmlsZUhlYWRlcgARHRn9BAAABAFPcHRpb25hbEhlYWRlcgASHR+rCAAAGAAHUElNQUdFX05UX0hFQURFUlM2NAATHRuLCQAADBAJAAAHUElNQUdFX05UX0hFQURFUlMAIh0hbwkAABqAHQfdCQAAGFBoeXNpY2FsQWRkcmVzcwCBHcQBAAAYVmlydHVhbFNpemUAgh3EAQAAAA5fSU1BR0VfU0VDVElPTl9IRUFERVIAKH4d2QoAAAFOYW1lAH8dDIsCAAAAAU1pc2MAgx0JqgkAAAgPqwIAAIQdDcQBAAAMAVNpemVPZlJhd0RhdGEAhR0NxAEAABABUG9pbnRlclRvUmF3RGF0YQCGHQ3EAQAAFAFQb2ludGVyVG9SZWxvY2F0aW9ucwCHHQ3EAQAA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EwAAkCkAQAEAAABQAAAAAAAAAAGcEOQTAAA4EQAANBEAACvvEwAAAVED+xMAAEsRAABHEQAAAwYUAABqEQAAaBEAAAMRFAAAdBEAAHARAAAAABUBAAAFAAEIwxgAAAFHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB25EAAAshAAAKMZAAACX01JTkdXX0lOU1RBTExfREVCVUdfTUFUSEVSUgABAQURAQAACQMwsABAAQAAAAMEBWludAAArQMAAAUAAQjxGAAACkdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHVoRAAChEQAAoC0AQAEAAABIAAAAAAAAAN0ZAAAFX19nbnVjX3ZhX2xpc3QAAhgdCQEAAAsIX19idWlsdGluX3ZhX2xpc3QAIQEAAAEBBmNoYXIADCEBAAAFdmFfbGlzdAACHxryAAAAAQgHbG9uZyBsb25nIHVuc2lnbmVkIGludAABCAVsb25nIGxvbmcgaW50AAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQABiEBAAABBAd1bnNpZ25lZCBpbnQAAQQHbG9uZyB1bnNpZ25lZCBpbnQAAQEIdW5zaWduZWQgY2hhcgANX2lvYnVmADADIQpVAgAAAl9wdHIAJQuSAQAAAAJfY250ACYJfwEAAAgCX2Jhc2UAJwuSAQAAEAJfZmxhZwAoCX8BAAAYAl9maWxl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MQu2AQAAGARjdXJyZW5jeV9zeW1ib2wABTILtgEAACAEbW9uX2RlY2ltYWxfcG9pbnQABTMLtgEAACgEbW9uX3Rob3VzYW5kc19zZXAABTQLtgEAADAEbW9uX2dyb3VwaW5nAAU1C7YBAAA4BHBvc2l0aXZlX3NpZ24ABTYLtgEAAEAEbmVnYXRpdmVfc2lnbgAFNwu2AQAASARpbnRfZnJhY19kaWdpdHMABTgKIQEAAFAEZnJhY19kaWdpdHMABTkKIQEAAFEEcF9jc19wcmVjZWRlcwAFOgohAQAAUgRwX3NlcF9ieV9zcGFjZQAFOwohAQAAUwRuX2NzX3ByZWNlZGVzAAU8CiEBAABUBG5fc2VwX2J5X3NwYWNlAAU9CiEBAABVBHBfc2lnbl9wb3NuAAU+CiEBAABWBG5fc2lnbl9wb3NuAAU/CiEBAABXBF9XX2RlY2ltYWxfcG9pbnQABUEOwAEAAFgEX1dfdGhvdXNhbmRzX3NlcAAFQg7AAQAAYARfV19pbnRfY3Vycl9zeW1ib2wABUMOwAEAAGgEX1dfY3VycmVuY3lfc3ltYm9sAAVEDsABAABwBF9XX21vbl9kZWNpbWFsX3BvaW50AAVFDsABAAB4BF9XX21vbl90aG91c2FuZHNfc2VwAAVGDsABAACABF9XX3Bvc2l0aXZlX3NpZ24ABUcOwAEAAIgEX1dfbmVnYXRpdmVfc2lnbgAFSA7AAQAAkAAU9AEAABMBCHVuc2lnbmVkIGNoYXIAJF9pb2J1ZgAwBiEKKAUAAARfcHRyAAYlC7YBAAAABF9jbnQABiYJowEAAAgEX2Jhc2UABicLtgEAABAEX2ZsYWcABigJowEAABgEX2ZpbGUABikJowEAABwEX2NoYXJidWYABioJowEAACAEX2J1ZnNpegAGKwmjAQAAJARfdG1wZm5hbWUABiwLtgEAACgAD0ZJTEUABi8ZmAQAABMQBGxvbmcgZG91YmxlABMBBnNpZ25lZCBjaGFyABMCBXNob3J0IGludAAPaW50MzJfdAAHJw6jAQAAD3VpbnQzMl90AAcoFM8BAAAPaW50NjRfdAAHKSZnAQAAEwgEZG91YmxlABMEBGZsb2F0ABSIAQAAFLYBAAA9BQMAAAgInwUS7wUAABBfV2NoYXIACKAFE98BAAAAEF9CeXRlAAihBRSNAQAABBBfU3RhdGUACKEFG40BAAAGAD4FAwAACKIFBa4FAAAtbWJzdGF0ZV90AAijBRXvBQAAMgh6MgYAAARsb3cAAnsUzwEAAAAEaGlnaAACexnPAQAABAAzIgMAAAh3XwYAAAx4AAJ4DJEFAAAMdmFsAAJ5GE0BAAAMbGgAAnwHDwYAAAAuIgMAAAJ9BTIGAAAyEIe+BgAABGxvdwACiBTPAQAAAARoaWdoAAKIGc8BAAAEL3NpZ25fZXhwb25lbnQAiaMBAAAQQC9yZXMxAIqjAQAAEFAvcmVzMACLowEAACBgADPhAgAAEITfBgAADHgAAoYRNQUAAAxsaAACjAdrBgAAAC7hAgAAAo0FvgYAABQpAQAAI+sGAAAkX190STEyOAAQAV0iFwcAAARkaWdpdHMAAV4LFwcAAAAAHIEFAAAnBwAAH00BAAABAA9fX3RJMTI4AAFfA/UGAAA/+wIAABABYSJXBwAABGRpZ2l0czMyAAFiDFcHAAAAABxwBQAAZwcAAB9NAQAAAwAu+wIAAAFjAzcHAABAX191STEyOAAQAWUhoQcAAAx0MTI4AAFmCycHAAAMdDEyOF8yAAFnDWcHAAAAD19fdUkxMjgAAWgDcwcAAEEQAbsJvAgAAAxfX3Bmb3JtYXRfbG9uZ190AAHAG6oBAAAMX19wZm9ybWF0X2xsb25nX3QAAcEbZwEAAAxfX3Bmb3JtYXRfdWxvbmdfdAABwhvfAQAADF9fcGZvcm1hdF91bGxvbmdfdAABwxtNAQAADF9fcGZvcm1hdF91c2hvcnRfdAABxBuNAQAADF9fcGZvcm1hdF91Y2hhcl90AAHFG4cEAAAMX19wZm9ybWF0X3Nob3J0X3QAAcYbUwUAAAxfX3Bmb3JtYXRfY2hhcl90AAHHG0QFAAAMX19wZm9ybWF0X3B0cl90AAHIG7wIAAAMX19wZm9ybWF0X3UxMjhfdAAByRuhBwAAAEIID19fcGZvcm1hdF9pbnRhcmdfdAABygOxBwAAJc8BAAABzQFHCQAAB1BGT1JNQVRfSU5JVAAAB1BGT1JNQVRfU0VUX1dJRFRIAAEHUEZPUk1BVF9HRVRfUFJFQ0lTSU9OAAIHUEZPUk1BVF9TRVRfUFJFQ0lTSU9OAAMHUEZPUk1BVF9FTkQABAAPX19wZm9ybWF0X3N0YXRlX3QAAdYD2QgAACXPAQAAAdkB9wkAAAdQRk9STUFUX0xFTkdUSF9JTlQAAAdQRk9STUFUX0xFTkdUSF9TSE9SVAABB1BGT1JNQVRfTEVOR1RIX0xPTkcAAgdQRk9STUFUX0xFTkdUSF9MTE9ORwADB1BGT1JNQVRfTEVOR1RIX0xMT05HMTI4AAQHUEZPUk1BVF9MRU5HVEhfQ0hBUgAFAA9fX3Bmb3JtYXRfbGVuZ3RoX3QAAeMDYQkAADQwFwEJ3goAABBkZXN0AAEeARK8CAAAABBmbGFncwABHwESowEAAAgQd2lkdGgAASABEqMBAAAMQw8DAAABIQESowEAABAQcnBsZW4AASIBEqMBAAAUEHJwY2hyAAEjARJ4AQAAGBB0aG91c2FuZHNfY2hyX2xlbgABJAESowEAABwQdGhvdXNhbmRzX2NocgABJQESeAEAACAQY291bnQAASYBEqMBAAAkEHF1b3RhAAEnARKjAQAAKBBleHBtaW4AASgBEqMBAAAsAC1fX3Bmb3JtYXRfdAABKQEDEgoAADQQDQQDQwsAABBfX3Bmb3JtYXRfZnByZWdfbWFudGlzc2EAAQ4EGk0BAAAAEF9fcGZvcm1hdF9mcHJlZ19leHBvbmVudAABDwQaUwUAAAgARBABBQQJzgsAACZfX3Bmb3JtYXRfZnByZWdfZG91YmxlX3QACwSRBQAAJl9fcGZvcm1hdF9mcHJlZ19sZG91YmxlX3QADAQ1BQAARfMKAAAmX19wZm9ybWF0X2ZwcmVnX2JpdG1hcAARBM4LAAAmX19wZm9ybWF0X2ZwcmVnX2JpdHMAEgTfAQAAAByNAQAA3gsAAB9NAQAABAAtX19wZm9ybWF0X2ZwcmVnX3QAARMEA0MLAAAPVUxvbmcACTUX3wEAACXPAQAACTsG+gwAAAdTVFJUT0dfWmVybwAAB1NUUlRPR19Ob3JtYWwAAQdTVFJUT0dfRGVub3JtYWwAAgdTVFJUT0dfSW5maW5pdGUAAwdTVFJUT0dfTmFOAAQHU1RSVE9HX05hTmJpdHMABQdTVFJUT0dfTm9OdW1iZXIABgdTVFJUT0dfUmV0bWFzawAHB1NUUlRPR19OZWcACAdTVFJUT0dfSW5leGxvABAHU1RSVE9HX0luZXhoaQAgB1NUUlRPR19JbmV4YWN0ADAHU1RSVE9HX1VuZGVy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cl9zeW1ib2wABTEL1QEAABgDY3VycmVuY3lfc3ltYm9sAAUyC9UBAAAgA21vbl9kZWNpbWFsX3BvaW50AAUzC9UBAAAoA21vbl90aG91c2FuZHNfc2VwAAU0C9UBAAAwA21vbl9ncm91cGluZwAFNQvVAQAAOANwb3NpdGl2ZV9zaWduAAU2C9UBAABAA25lZ2F0aXZlX3NpZ24ABTcL1QEAAEgDaW50X2ZyYWNfZGlnaXRzAAU4CiEBAABQA2ZyYWNfZGlnaXRzAAU5CiEBAABRA3BfY3NfcHJlY2VkZXMABToKIQEAAFIDcF9zZXBfYnlfc3BhY2UABTsKIQEAAFMDbl9jc19wcmVjZWRlcwAFPAohAQAAVANuX3NlcF9ieV9zcGFjZQAFPQohAQAAVQNwX3NpZ25fcG9zbgAFPgohAQAAVgNuX3NpZ25fcG9zbgAFPwohAQAAVwNfV19kZWNpbWFsX3BvaW50AAVBDtoBAABYA19XX3Rob3VzYW5kc19zZXAABUIO2gEAAGADX1dfaW50X2N1cnJfc3ltYm9sAAVDDtoBAABoA19XX2N1cnJlbmN5X3N5bWJvbAAFRA7aAQAAcANfV19tb25fZGVjaW1hbF9wb2ludAAFRQ7aAQAAeANfV19tb25fdGhvdXNhbmRzX3NlcAAFRg7aAQAAgANfV19wb3NpdGl2ZV9zaWduAAVHDtoBAACIA19XX25lZ2F0aXZlX3NpZ24ABUgO2gEAAJAAFQ4CAAATAQh1bnNpZ25lZCBjaGFyACRfaW9idWYAMAYhCkIFAAADX3B0cgAGJQvVAQAAAANfY250AAYmCcIBAAAIA19iYXNlAAYnC9UBAAAQA19mbGFnAAYoCcIBAAAYA19maWxlAAYpCcIBAAAcA19jaGFyYnVmAAYqCcIBAAAgA19idWZzaXoABisJwgEAACQDX3RtcGZuYW1lAAYsC9UBAAAoAAxGSUxFAAYvGbIEAAATEARsb25nIGRvdWJsZQATAQZzaWduZWQgY2hhcgATAgVzaG9ydCBpbnQADGludDMyX3QABycOwgEAAAx1aW50MzJfdAAHKBTpAQAADGludDY0X3QABykmdwEAABMIBGRvdWJsZQATBARmbG9hdAAVmAEAACG+BQAAFdUBAAA+jQMAAAgInwUSDgYAABFfV2NoYXIACKAFE/kBAAAAEV9CeXRlAAihBRSdAQAABBFfU3RhdGUACKEFG50BAAAGAD+NAwAACKIFBc0FAAAtbWJzdGF0ZV90AAijBRUOBgAANAh6UQYAAANsb3cAAnsU6QEAAAADaGlnaAACexnpAQAABAA1qgMAAAh3fgYAAA14AAJ4DKsFAAANdmFsAAJ5GE0BAAANbGgAAnwHLgYAAAAuqgMAAAJ9BVEGAAA0EIfdBgAAA2xvdwACiBTpAQAAAANoaWdoAAKIGekBAAAEL3NpZ25fZXhwb25lbnQAicIBAAAQQC9yZXMxAIrCAQAAEFAvcmVzMACLwgEAACBgADVvAwAAEIT+BgAADXgAAoYRTwUAAA1saAACjAeKBgAAAC5vAwAAAo0F3QYAABUpAQAAIQoHAAAkX190STEyOAAQAV0iNgcAAANkaWdpdHMAAV4LNgcAAAAAHpsFAABGBwAAH00BAAABAAxfX3RJMTI4AAFfAxQHAABAgwMAABABYSJ2BwAAA2RpZ2l0czMyAAFiDHYHAAAAAB6KBQAAhgcAAB9NAQAAAwAugwMAAAFjA1YHAABBX191STEyOAAQAWUhwAcAAA10MTI4AAFmC0YHAAANdDEyOF8yAAFnDYYHAAAADF9fdUkxMjgAAWgDkgcAAEIQAbsJ2wgAAA1fX3Bmb3JtYXRfbG9uZ190AAHAG8kBAAANX19wZm9ybWF0X2xsb25nX3QAAcEbdwEAAA1fX3Bmb3JtYXRfdWxvbmdfdAABwhv5AQAADV9fcGZvcm1hdF91bGxvbmdfdAABwxtNAQAADV9fcGZvcm1hdF91c2hvcnRfdAABxBudAQAADV9fcGZvcm1hdF91Y2hhcl90AAHFG6EEAAANX19wZm9ybWF0X3Nob3J0X3QAAcYbbQUAAA1fX3Bmb3JtYXRfY2hhcl90AAHHG14FAAANX19wZm9ybWF0X3B0cl90AAHIG9sIAAANX19wZm9ybWF0X3UxMjhfdAAByRvABwAAAEMIDF9fcGZvcm1hdF9pbnRhcmdfdAABygPQBwAAJekBAAABzQFmCQAACFBGT1JNQVRfSU5JVAAACFBGT1JNQVRfU0VUX1dJRFRIAAEIUEZPUk1BVF9HRVRfUFJFQ0lTSU9OAAIIUEZPUk1BVF9TRVRfUFJFQ0lTSU9OAAMIUEZPUk1BVF9FTkQABAAMX19wZm9ybWF0X3N0YXRlX3QAAdYD+AgAACXpAQAAAdkBFgoAAAhQRk9STUFUX0xFTkdUSF9JTlQAAAhQRk9STUFUX0xFTkdUSF9TSE9SVAABCFBGT1JNQVRfTEVOR1RIX0xPTkcAAghQRk9STUFUX0xFTkdUSF9MTE9ORwADCFBGT1JNQVRfTEVOR1RIX0xMT05HMTI4AAQIUEZPUk1BVF9MRU5HVEhfQ0hBUgAFAAxfX3Bmb3JtYXRfbGVuZ3RoX3QAAeMDgAkAADYwFwEJ/QoAABFkZXN0AAEeARLbCAAAABFmbGFncwABHwESwgEAAAgRd2lkdGgAASABEsIBAAAMRJcDAAABIQESwgEAABARcnBsZW4AASIBEsIBAAAUEXJwY2hyAAEjARKIAQAAGBF0aG91c2FuZHNfY2hyX2xlbgABJAESwgEAABwRdGhvdXNhbmRzX2NocgABJQESiAEAACARY291bnQAASYBEsIBAAAkEXF1b3RhAAEnARLCAQAAKBFleHBtaW4AASgBEsIBAAAsAC1fX3Bmb3JtYXRfdAABKQEDMQoAADYQDQQDYgsAABFfX3Bmb3JtYXRfZnByZWdfbWFudGlzc2EAAQ4EGk0BAAAAEV9fcGZvcm1hdF9mcHJlZ19leHBvbmVudAABDwQabQUAAAgARRABBQQJ7QsAACZfX3Bmb3JtYXRfZnByZWdfZG91YmxlX3QACwSrBQAAJl9fcGZvcm1hdF9mcHJlZ19sZG91YmxlX3QADARPBQAARhILAAAmX19wZm9ybWF0X2ZwcmVnX2JpdG1hcAARBO0LAAAmX19wZm9ybWF0X2ZwcmVnX2JpdHMAEgT5AQAAAB6dAQAA/QsAAB9NAQAABAAtX19wZm9ybWF0X2ZwcmVnX3QAARMEA2ILAAAMVUxvbmcACTUX+QEAACXpAQAACTsGGQ0AAAhTVFJUT0dfWmVybwAACFNUUlRPR19Ob3JtYWwAAQhTVFJUT0dfRGVub3JtYWwAAghTVFJUT0dfSW5maW5pdGUAAwhTVFJUT0dfTmFOAAQIU1RSVE9HX05hTmJpdHMABQhTVFJUT0dfTm9OdW1iZXIABghTVFJUT0dfUmV0bWFzawAHCFNUUlRPR19OZWcACAhTVFJUT0dfSW5leGxvABAIU1RSVE9HX0luZXhoaQAgCFNUUlRPR19JbmV4YWN0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CmsACTsBAAAKcgANUwEAAAAcMAUAACB6AEABAAAAQAAAAAAAAAABnA1MBQAAuVkAALVZAAAHVgUAAM1ZAADHWQAAB14FAADiWQAA3lkAAAdmBQAA8lkAAO5ZAAAJU3oAQAEAAACEAgAAAwFSAnMAAAAANBIAAAUAAQj5JQAAG0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHb8WAAC4FgAAkHwAQAEAAAATFgAAAAAAAK1nAAAHAQZjaGFyABFzaXplX3QAAyMsCQEAAAcIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQABwgFbG9uZyBsb25nIGludAAHAgdzaG9ydCB1bnNpZ25lZCBpbnQABwQFaW50AAcEBWxvbmcgaW50AAryAAAACkoBAAAHBAd1bnNpZ25lZCBpbnQABwQHbG9uZyB1bnNpZ25lZCBpbnQABwEIdW5zaWduZWQgY2hhcgAHEARsb25nIGRvdWJsZQARVUxvbmcABDUXdwEAABwHBGcBAAAEOwavAgAABVNUUlRPR19aZXJvAAAFU1RSVE9HX05vcm1hbAABBVNUUlRPR19EZW5vcm1hbAACBVNUUlRPR19JbmZpbml0ZQADBVNUUlRPR19OYU4ABAVTVFJUT0dfTmFOYml0cwAFBVNUUlRPR19Ob051bWJlcgAGBVNUUlRPR19SZXRtYXNrAAcFU1RSVE9HX05lZwAIBVNUUlRPR19JbmV4bG8AEAVTVFJUT0dfSW5leGhpACAFU1RSVE9HX0luZXhhY3QAMAVTVFJUT0dfVW5kZXJmbG93AEAFU1RSVE9HX092ZXJmbG93AIAAHUZQSQAYBFABGQMAAAtuYml0cwBRSgEAAAALZW1pbgBSSgEAAAQLZW1heABTSgEAAAgLcm91bmRpbmcAVEoBAAAMC3N1ZGRlbl91bmRlcmZsb3cAVUoBAAAQC2ludF9tYXgA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sQEAAB9fTElTVF9FTlRSWQAQcQISXQIAAARGbGluawAHcgIZXQIAAAAEQmxpbmsAB3MCGV0CAAAIAAknAgAAE0xJU1RfRU5UUlkAdAIFJwIAAAYQBGxvbmcgZG91YmxlABXyAAAACY4CAAAyBgIEX0Zsb2F0MTYABgIEX19iZjE2ADNKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwR7AQAAB4oTEnkDAAAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABGkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAH19SVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwAw0iMUegQAAARUeXBlAAfTIwyzAQAAAARDcmVhdG9yQmFja1RyYWNlSW5kZXgAB9QjDLMBAAACBENyaXRpY2FsU2VjdGlvbgAH1SMlHgUAAAgEUHJvY2Vzc0xvY2tzTGlzdAAH1iMSYgIAABAERW50cnlDb3VudAAH1yMNwAEAACAEQ29udGVudGlvbkNvdW50AAfYIw3AAQAAJARGbGFncwAH2SMNwAEAACgEQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaAAH2iMMswEAACwEU3BhcmVXT1JEAAfbIwyzAQAALgAfX1JUTF9DUklUSUNBTF9TRUNUSU9OACjtIxQeBQAABERlYnVnSW5mbwAH7iMjIwUAAAAETG9ja0NvdW50AAfvIwwLAgAACARSZWN1cnNpb25Db3VudAAH8CMMCwIAAAwET3duaW5nVGhyZWFkAAfxIw4YAgAAEARMb2NrU2VtYXBob3JlAAfyIw4YAgAAGARTcGluQ291bnQAB/MjEfkBAAAgAAl6BAAAE1BSVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwDcIyNHBQAACXkDAAATUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMHegQAABNQUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMdHgUAAA5DUklUSUNBTF9TRUNUSU9OAAirIEwFAAAOTFBDUklU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AAMRDgAAPZEAADuRAAADHg4AAEeRAABFkQAAAyoOAABTkQAAT5EAAAM3DgAAc5EAAGmRAAADQg4AAMCRAAC6kQAAAC1tZW1zZXQAX19idWlsdGluX21lbXNldAAtbWVtY3B5AF9fYnVpbHRpbl9tZW1jcHkAAO4BAAAFAAEI0y4AAANHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2WGQAA1RkAAOCgAEABAAAAKAAAAAAAAAAkiQAAAQEGY2hhcgAE8gAAAAVzaXplX3QAAiMsDgEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAAZzdHJubGVuAAEEEP8AAADgoABAAQAAACgAAAAAAAAAAZzrAQAAAnMAJesBAAABUgJtYXhsZW4AL/8AAAABUQdzMgABBg/rAQAA65EAAOeRAAAACAj6AAAAAAUCAAAFAAEIVS8AAARHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB1WGgAAlRoAABChAEABAAAAJQAAAAAAAACliQAAAQEGY2hhcgACc2l6ZV90ACMsCAEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAACd2NoYXJfdABiGEcBAAAFMwEAAAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABndjc25sZW4AAQUB+gAAABChAEABAAAAJQAAAAAAAAABnAICAAADdwAYAgIAAAiSAAACkgAAA25jbnQAIvoAAAAskgAAJpIAAAduAAEHCvoAAABAkgAAPJIAAAAICEIBAAAAagEAAAUAAQjbLwAAA0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHRYbAABYGwAAQKEAQAEAAAALAAAAAAAAAD2KAAABAQZjaGFyAARfX2ltcF9fZm1vZGUAAQkODwEAAAIUAQAAAQQFaW50AAUPAQAABl9faW1wX19fcF9fZm1vZGUAAREVQwEAAAkDkLAAQAEAAAACGwEAAAdfX3BfX2Ztb2RlAAEMDg8BAABAoQBAAQAAAAsAAAAAAAAAAZwAcAEAAAUAAQhOMAAAA0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbUbAAD5GwAAUKEAQAEAAAALAAAAAAAAAJuKAAABAQZjaGFyAARfX2ltcF9fY29tbW9kZQABCQ4RAQAAAhYBAAABBAVpbnQABREBAAAGX19pbXBfX19wX19jb21tb2RlAAERF0cBAAAJA6CwAEABAAAAAh0BAAAHX19wX19jb21tb2RlAAEMDhEBAABQoQBAAQAAAAsAAAAAAAAAAZwAlgsAAAUAAQjBMAAAFEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHWEcAABaHAAAYKEAQAEAAADZAAAAAAAAAPmKAAADAQZjaGFyAAMIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAwgFbG9uZyBsb25nIGludAADAgdzaG9ydCB1bnNpZ25lZCBpbnQAAwQFaW50AAMEBWxvbmcgaW50AAryAAAAAwQHdW5zaWduZWQgaW50AAMEB2xvbmcgdW5zaWduZWQgaW50AAMBCHVuc2lnbmVkIGNoYXIAFV9pb2J1ZgAwAiEKGQIAAARfcHRyAAIlC04BAAAABF9jbnQAAiYJOwEAAAgEX2Jhc2UAAicLTgEAABAEX2ZsYWcAAigJOwEAABgEX2ZpbGUAAikJOwEAABwEX2NoYXJidWYAAioJOwEAACAEX2J1ZnNpegACKwk7AQAAJARfdG1wZm5hbWUAAiwLTgEAACgAB0ZJTEUAAi8ZiQEAAAdXT1JEAAOMGiUBAAAHRFdPUkQAA40dYwEAAAMEBGZsb2F0ABYIAwEGc2lnbmVkIGNoYXIAAwIFc2hvcnQgaW50AAdVTE9OR19QVFIABDEu+gAAAAhMT05HACkBFEIBAAAISEFORExFAJ8BEUoCAAAOX0xJU1RfRU5UUlkAEHECEsoCAAACRmxpbmsAcgIZygIAAAACQmxpbmsAcwIZygIAAAgACpYCAAAITElTVF9FTlRSWQB0AgWWAgAAAxAEbG9uZyBkb3VibGUAAwgEZG91YmxlAAMCBF9GbG9hdDE2AAMCBF9fYmYxNgAPSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAFMBAAAFihMS4wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAOX1JUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHADDSIxTbBAAAAlR5cGUA0yMMJgIAAAACQ3JlYXRvckJhY2tUcmFjZUluZGV4ANQjDCYCAAACAkNyaXRpY2FsU2VjdGlvbgDVIyV5BQAACAJQcm9jZXNzTG9ja3NMaXN0ANYjEs8CAAAQAkVudHJ5Q291bnQA1yMNMwIAACACQ29udGVudGlvbkNvdW50ANgjDTMCAAAkAkZsYWdzANkjDTMCAAAoAkNyZWF0b3JCYWNrVHJhY2VJbmRleEhpZ2gA2iMMJgIAACwCU3BhcmVXT1JEANsjDCYCAAAuAA5fUlRMX0NSSVRJQ0FMX1NFQ1RJT04AKO0jFHkFAAACRGVidWdJbmZvAO4jI34FAAAAAkxvY2tDb3VudADvIwx6AgAACAJSZWN1cnNpb25Db3VudADwIwx6AgAADAJPd25pbmdUaHJlYWQA8SMOhwIAABACTG9ja1NlbWFwaG9yZQDyIw6HAgAAGAJTcGluQ291bnQA8yMRaAIAACAACtsEAAAIUFJUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHANwjI6IFAAAK4wMAAAhSVExfQ1JJVElDQUxfU0VDVElPTgD0IwfbBAAACFBSVExfQ1JJVElDQUxfU0VDVElPTgD0Ix15BQAAB0NSSVRJQ0FMX1NFQ1RJT04ABqsgpwUAAAdMUENSSVRJQ0FMX1NFQ1RJT04ABq0hxAUAABd0YWdDT0lOSVRCQVNFAAcEUwEAAAeVDk4GAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAD1ZBUkVOVU0AUwEAAAgJAgbYCAAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQVWVF9CU1RSX0JMT0IA/w8FVlRfVkVDVE9SAAAQBVZUX0FSUkFZAAAgBVZUX0JZUkVGAABABVZUX1JFU0VSVkVEAACABVZUX0lMTEVHQUwA//8FVlRfSUxMRUdBTE1BU0tFRAD/DwVWVF9UWVBFTUFTSwD/DwAYWAlaC/sIAAAEZgAJWwoZAgAAAARsb2NrAAlcFuIFAAAwAAdfRklMRVgACV0F2AgAABBfX2ltcF9fbG9ja19maWxlADxKAgAACQO4sABAAQAAABBfX2ltcF9fdW5sb2NrX2ZpbGUAZkoCAAAJA7CwAEABAAAADExlYXZlQ3JpdGljYWxTZWN0aW9uAAosGnEJAAAL+wUAAAAMX3VubG9jawABEBaHCQAACzsBAAAADEVudGVyQ3JpdGljYWxTZWN0aW9uAAorGqoJAAAL+wUAAAAMX2xvY2sAAQ8WvgkAAAs7AQAAABlfX2FjcnRfaW9iX2Z1bmMAAl0X4AkAAOAJAAALUwEAAAAKGQIAABFfdW5sb2NrX2ZpbGUATgMKAAAScGYATiLgCQAAABFfbG9ja19maWxlACQfCgAAEnBmACQg4AkAAAAaAwoAAGChAEABAAAAcAAAAAAAAAABnOQKAAANFAoAAGSSAABYkgAAGwMKAACgoQBAAQAAAACgoQBAAQAAACkAAAAAAAAAASQOngoAAA0UCgAAjZIAAIuSAAAJp6EAQAEAAAC+CQAAkAoAAAYBUgEwABzCoQBAAQAAAKoJAAAACXWhAEABAAAAvgkAALUKAAAGAVIBMAAJhKEAQAEAAAC+CQAAzAoAAAYBUgFDABOaoQBAAQAAAIcJAAAGAVIFowFSIzAAAB3lCQAA0KEAQAEAAABpAAAAAAAAAAGcDfgJAACfkgAAk5IAAB7lCQAAEKIAQAEAAAAAMwcAAAFODlMLAAAN+AkAANWSAADRkgAACR6iAEABAAAAvgkAAEULAAAGAVIBMAAfOaIAQAEAAABxCQAAAAnloQBAAQAAAL4JAABqCwAABgFSATAACfShAEABAAAAvgkAAIELAAAGAVIBQwATCqIAQAEAAABOCQAABgFSBaMBUiMwAAAAoQcAAAUAAQiiMgAAC0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbkdAACyHQAAQKIAQAEAAAAbAAAAAAAAAEuMAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAAGdWludHB0cl90AANLLPoAAAAGd2NoYXJfdAADYhhMAQAADDcBAAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAACBAdsb25nIHVuc2lnbmVkIGludAACAQh1bnNpZ25lZCBjaGFyAA0IDqsBAAACBARmbG9hdAACAQZzaWduZWQgY2hhcgACAgVzaG9ydCBpbnQAAhAEbG9uZyBkb3VibGUAAggEZG91YmxlAAZfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgAElBoTAgAABRgCAAAPNwIAAAQ3AgAABDcCAAAENwIAAAR1AQAABCUBAAAABUcBAAACAgRfRmxvYXQxNgACAgRfX2JmMTYAB0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwB1AQAABYoTEiQDAAABSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAEHRhZ0NPSU5JVEJBU0UABwR1AQAABpUOXAMAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAHVkFSRU5VTQB1AQAABwkCBuYFAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJA1ZUX0JTVFJfQkxPQgD/DwNWVF9WRUNUT1IAABADVlRfQVJSQVkAACADVlRfQllSRUYAAEADVlRfUkVTRVJWRUQAAIADVlRfSUxMRUdBTAD//wNWVF9JTExFR0FMTUFTS0VEAP8PA1ZUX1RZUEVNQVNLAP8PABFoYW5kbGVyAAEFI/ABAAAJA2ALAUABAAAAEvABAAAPBgAABPABAAAACF9faW1wX19zZXRfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgAMRAYAAAkDyLAAQAEAAAAFAAYAABPwAQAACF9faW1wX19nZXRfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgAUgwYAAAkDwLAAQAEAAAAFSQYAABRtaW5nd19nZXRfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgABDyvwAQAAQKIAQAEAAAAIAAAAAAAAAAGcFW1pbmd3X3NldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAAEHK/ABAABQogBAAQAAAAsAAAAAAAAAAZxbBwAAFm5ld19oYW5kbGVyAAEHavABAAABUhdbBwAAU6IAQAEAAAAAU6IAQAEAAAAHAAAAAAAAAAEJDAmSBwAA9ZIAAPOSAAAJhQcAAP2SAAD7kgAAAAAYX0ludGVybG9ja2VkRXhjaGFuZ2VQb2ludGVyAALTBgerAQAAA58HAAAKVGFyZ2V0ADOfBwAAClZhbHVlAECrAQAAAAWtAQAAANUCAAAFAAEIBzQAAAVHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB0GHwAATB8AAGCiAEABAAAAJgAAAAAAAADujAAAAQEGY2hhcgABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAAD8gAAAAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAAZfaW9idWYAMAIhChECAAACX3B0cgAlC04BAAAAAl9jbnQAJgk7AQAACAJfYmFzZQAnC04BAAAQAl9mbGFnACgJOwEAABgCX2ZpbGUAKQk7AQAAHAJfY2hhcmJ1ZgAqCTsBAAAgAl9idWZzaXoAKwk7AQAAJAJfdG1wZm5hbWUALAtOAQAAKAAERklMRQACL4kBAAAEX2ZfX2FjcnRfaW9iX2Z1bmMAAQ42AgAAAzsCAAAHSgIAAEoCAAAIUwEAAAADEQIAAAlfX2ltcF9fX2FjcnRfaW9iX2Z1bmMAAQ8THQIAAAkD0LAAQAEAAAAKX19pb2JfZnVuYwACYBlKAgAAC19fYWNydF9pb2JfZnVuYwABCQ9KAgAAYKIAQAEAAAAmAAAAAAAAAAGcDGluZGV4AAEJKFMBAAAekwAAGJMAAA1yogBAAQAAAHcCAAAAAHAGAAAFAAEI1TQAAA9HTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB3fHwAA2B8AAJCiAEABAAAA5gEAAAAAAABljQAAAQEGY2hhcgAHc2l6ZV90AAIjLAkBAAABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAB3djaGFyX3QAAmIYSQEAAAo0AQAAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAAE8gAAAARfAQAAAQQHdW5zaWduZWQgaW50AAp8AQAAAQQHbG9uZyB1bnNpZ25lZCBpbnQAAQEIdW5zaWduZWQgY2hhcgABAgVzaG9ydCBpbnQACG1ic3RhdGVfdAADpQUPXwEAAAEIBGRvdWJsZQABBARmbG9hdAABEARsb25nIGRvdWJsZQAERAEAAAdXSU5CT09MAAR/DV8BAAAE/gEAAAdMUEJPT0wABIcPDgIAAAdEV09SRAAEjR2RAQAAB1VJTlQABJ8YfAEAAAEBBnNpZ25lZCBjaGFyAAhDSEFSAAUnARDyAAAACkwCAAAIV0NIQVIABTEBEzQBAAAKXwIAAAhMUENXQ0gABTQBGIMCAAAEbgIAAARMAgAACExQQ0NIAAVZARecAgAABFoCAAAITFBTVFIABVoBGIgCAAABAgRfRmxvYXQxNgABAgRfX2JmMTYAEFdpZGVDaGFyVG9NdWx0aUJ5dGUACCoZXwEAAA8DAAAFMAIAAAUiAgAABXMCAAAFXwEAAAWhAgAABV8BAAAFjQIAAAUTAgAAAAtfZXJybm8ABpofdwEAAAtfX19sY19jb2RlcGFnZV9mdW5jAAcJFnwBAAALX19fbWJfY3VyX21heF9mdW5jAAZ5FV8BAAANd2NzcnRvbWJzADgI+gAAAHCjAEABAAAABgEAAAAAAAABnJoEAAADZHN0ADgZcgEAAEKTAAA6kwAAA3NyYwA4LpoEAABnkwAAX5MAAANsZW4AODr6AAAAlZMAAIeTAAADcHMAORGfBAAA1JMAANCTAAAGcmV0ADsHXwEAAPiTAADmkwAABm4APAr6AAAATpQAAD6UAAAGY3AAPRaMAQAAk5QAAI2UAAAGbWJfbWF4AD4WjAEAALGUAACplAAABnB3YwA/EvkBAADSlAAAzpQAABFKBwAAXwQAAA78AwAAVwykBAAAA5GrfwxJpABAAQAAAHQFAAACAVICdQACAVgCcwACAVkCdAAAAAmWowBAAQAAAB4DAAAJnaMAQAEAAAA6AwAADO+jAEABAAAAdAUAAAIBUgJ/AAIBWAJzAAIBWQJ0AAAABPkBAAAExAEAABLyAAAAtAQAABMJAQAABAANd2NydG9tYgAwAfoAAAAgowBAAQAAAEUAAAAAAAAAAZx0BQAAA2RzdAAwEHIBAADllAAA4ZQAAAN3YwAwHTQBAAD9lAAA95QAAANwcwAwLZ8EAAAalQAAFpUAAA78AwAAMgikBAAAApFLBnRtcF9kc3QAMwlyAQAAMJUAACyVAAAJQqMAQAEAAAA6AwAACUmjAEABAAAAHgMAAAxaowBAAQAAAHQFAAACAVICcwACAVEGdAAK//8aAgFZAnUAAAAUX193Y3J0b21iX2NwAAESAl8BAACQogBAAQAAAIYAAAAAAAAAAZwDZHN0ABIWcgEAAFiVAABOlQAAA3djABIjNAEAAIGVAAB5lQAAA2NwABI6jAEAAKCVAACYlQAAA21iX21heAATHIwBAADGlQAAvJUAABXAogBAAQAAAFAAAAAAAAAAFmludmFsaWRfY2hhcgABIQtfAQAAApFsBnNpemUAIwtfAQAA6pUAAOiVAAAX9aIAQAEAAADGAgAAZAYAAAIBUQEwAgFYApEIAgFZATECAncgA6MBUgICdygDowFZAgJ3MAEwAgJ3OAKRbAAJBaMAQAEAAAAPAwAAAAAADggAAAUAAQgkNgAAE0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHdsgAAAaIQAAgKQAQAEAAABBAwAAAAAAAISPAAADAQZjaGFyAA3yAAAAB3NpemVfdAACIywOAQAAAwgHbG9uZyBsb25nIHVuc2lnbmVkIGludAADCAVsb25nIGxvbmcgaW50AAd3Y2hhcl90AAJiGEkBAAADAgdzaG9ydCB1bnNpZ25lZCBpbnQAAwQFaW50AAMEBWxvbmcgaW50AAU5AQAAC3IBAAAFXwEAAAMEB3Vuc2lnbmVkIGludAANgQEAAAMEB2xvbmcgdW5zaWduZWQgaW50AAMBCHVuc2lnbmVkIGNoYXIAAwIFc2hvcnQgaW50AAltYnN0YXRlX3QAA6UFD18BAAADCARkb3VibGUAAwQEZmxvYXQAAxAEbG9uZyBkb3VibGUAB1dJTkJPT0wABH8NXwEAAAdCWVRFAASLGasBAAAHRFdPUkQABI0dlgEAAAdVSU5UAASfGIEBAAADAQZzaWduZWQgY2hhcgAJQ0hBUgAFJwEQ8gAAAA1FAgAACVdDSEFSAAUxARM5AQAABVgCAAAJTFBXU1RSAAU1ARpnAgAACUxQQ0NIAAVZAReLAgAABVMCAAADAgRfRmxvYXQxNgADAgRfX2JmMTYAFElzREJDU0xlYWRCeXRlRXgABrADHf4BAADPAgAABCkCAAAEDgIAAAAOX2Vycm5vAAiaH3wBAAAVTXVsdGlCeXRlVG9XaWRlQ2hhcgAHKRlfAQAAHQMAAAQpAgAABBsCAAAEfAIAAARfAQAABGwCAAAEXwEAAAAOX19fbGNfY29kZXBhZ2VfZnVuYwAJCRaBAQAADl9fX21iX2N1cl9tYXhfZnVuYwAIeRVfAQAAD21icmxlbgCV/wAAAGCnAEABAAAAYQAAAAAAAAABnBwEAAACcwCVIyEEAAAClgAA/JUAAAJuAJUt/wAAACGWAAAblgAAAnBzAJYbKwQAAECWAAA6lgAAEXNfbWJzdGF0ZQCYFMkBAAAJA3ALAUABAAAACggEAACZCzkBAAACkU4Gg6cAQAEAAAA5AwAABounAEABAAAAHQMAAAy0pwBAAQAAALYGAAABAVICkW4BAVECdAABAVgCdQABAVkCcwABAncoAnwAAAAF+gAAAAscBAAABckBAAALJgQAAA9tYnNydG93Y3MAbf8AAABApgBAAQAAABUBAAAAAAAAAZywBQAAAmRzdABtIncBAABjlgAAWZYAAAJzcmMAbUO1BQAAkpYAAIqWAAACbGVuAG4M/wAAAL6WAACylgAAAnBzAG4pKwQAAPOWAADvlgAACHJldABwB18BAAAVlwAABZcAAAhuAHEK/wAAAF6XAABSlwAAChQEAAByFMkBAAAJA3QLAUABAAAACGludGVybmFsX3BzAHMOJgQAAJKXAACMlwAACGNwAHQWkQEAAMSXAAC+lwAACG1iX21heAB1FpEBAADklwAA2pcAABZhBwAAZAUAAAoIBAAAiw85AQAAA5GufwxDpwBAAQAAALYGAAABAVICdQABAVgCfwABAVkCdAABAncgAn0AAQJ3KAJ8AAAABnSmAEABAAAAHQMAAAZ8pgBAAQAAADkDAAAM2qYAQAEAAAC2BgAAAQFSAn8AAQFYBXUAfgAcAQFZAnQAAQJ3IAJ9AAECdygCfAAAAAUcBAAAC7AFAAAPbWJydG93YwBg/wAAANClAEABAAAAbwAAAAAAAAABnLYGAAACcHdjAGAhdwEAAAyYAAAImAAAAnMAYEAhBAAAJJgAAB6YAAACbgBhCv8AAABDmAAAPZgAAAJwcwBhJSsEAABimAAAXJgAAAoUBAAAYxTJAQAACQN4CwFAAQAAAAoIBAAAZAw5AQAAA5G+fwhkc3QAZQxyAQAAf5gAAHuYAAAGA6YAQAEAAAA5AwAABgumAEABAAAAHQMAAAwwpgBAAQAAALYGAAABAVICcwABAVECdQABAVgCfAABAVkUdAADeAsBQAEAAAB0ADAuKAEAFhMBAncoAn0AAAAXX19tYnJ0b3djX2NwAAEQAV8BAACApABAAQAAAEcBAAAAAAAAAZwFCAAAAnB3YwAQJncBAACxmAAAnZgAAAJzABBFIQQAAA6ZAAD+mAAAAm4AEQ//AAAAWZkAAE2ZAAACcHMAESorBAAAkpkAAIaZAAACY3AAEhuRAQAAxZkAAL+ZAAACbWJfbWF4ABIykQEAAOKZAADcmQAAGAQBFANxBwAAEnZhbAAVD8kBAAASbWJjcwAWCgUIAAAAEXNoaWZ0X3N0YXRlABcFUAcAAAKRXBDbpABAAQAAAKYCAAChBwAAAQFSBJEwlAQAEBWlAEABAAAA3gIAAMAHAAABAVIEkTCUBAEBUQE4ABCkpQBAAQAAAN4CAAD3BwAAAQFSBJEwlAQBAVEBOAEBWAJzAAEBWQExAQJ3IAJ1AAECdygBMQAGraUAQAEAAADPAgAAABnyAAAAGg4BAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAENAAMIOiECOwU5C0kTOAsAAAINAAMOOiECOwU5C0kTOAsAAAMoAAMIHAsAAAQFAEkTAAAFDwALIQhJEwAABhYAAwg6IQI7BTkLSRMAAAc0AAMIOgs7CzkLSRM/GTwZAAAIJAALCz4LAwgAAAkWAAMIOgs7CzkLSRMAAApJAAIYfhgAAAtIAH0BfxMAAAwNAAMIOiECOwU5C0kTiAEhEDgFAAANDQADCDohAjsFOQtJE4gBIRA4CwAADhMBAwgLCzohAjsFOQsBEwAADyEASRMvCwAAEDQAAwg6CzsFOQtJEwAAEUgBfQF/EwETAAASKAADCBwFAAATBQADCDoLOwU5C0kTAAAUNAAxEwIXt0IXAAAVDQADCDohAjsFOQtJEzgFAAAWAQFJEwETAAAXNAADCDohATsLOQtJEwIYAAAYDQADCDohAjsFOQtJEwAAGQ0AAwg6CzsLOQtJEzgLAAAaLgE/GQMIOgs7CzkLJxlJEzwZARMAABsFADETAhe3QhcAABxJAAIYAAAdLgE/GQMIOgs7CzkLJxk8GQETAAAeSAF9AX8TAAAfNAADCDohATsLOQtJEwIXt0IXAAAgBQADCDohATsLOQtJEwIYAAAhAQFJE4gBIRABEwAAIi4BPxkDCDoLOwU5CycZSRM8GQETAAAjLgA/GQMIOgs7CzkLJxk8GQAAJCYASRMAACUVAScZSRMBEwAAJhcBCyEIOiECOwU5IRYBEwAAJw0ASRM4CwAAKDQAAwg6IQE7BTkhDEkTPxk8GQAAKS4APxkDCDoLOws5CycZSRM8GQAAKh0BMRNSAbhCC1UXWCEBWQtXCwETAAArCwFVFwAALC4BPxkDCDohAzsFOQsnGUkTICEDARMAAC01AEkTAAAuEwEDCAsFiAEhEDohAjsFOQsBEwAALxYAAwg6IQI7BTkLSROIASEQAAAwFQEnGQETAAAxDQADCDohAjsFOSEXSROIASEQAAAyBAEDCD4hBwshBEkTOgs7BTkLARMAADMhAAAANDQAAwg6IQE7CzkhHkkTPxkCGAAANS4BAwg6IQE7CzkhAScZSRMRARIHQBh6GQETAAA2BQAxEwAANy4BPxkDCDohATsLOSEFJxlJExEBEgdAGHoZARMAADguAQMIOiEBOws5IQEnGREBEgdAGHoZARMAADkRASUIEwsDHxsfEQESBxAXAAA6DwALCwAAOw0ASROIAQs4BQAAPCYAAAA9EwEDCAsLiAELOgs7BTkLARMAAD4VACcZSRMAAD8VACcZAABAEwELBYgBCzoLOwU5CwETAABBFwELBYgBCzoLOwU5CwETAABCDQBJE4gBCwAAQxMBAwgLBToLOwU5CwETAABEBAEDCD4LCwtJEzoLOws5CwETAABFEwELCzoLOws5CwETAABGBAEDDj4LCwtJEzoLOws5CwETAABHFgADDjoLOws5C0kTAABINQAAAEkTAQMICws6CzsLOQsBEwAASjQAAwg6CzsLOQtJEwAASzQAAwg6CzsFOQtJEz8ZAhgAAEwuAT8ZAwg6CzsFOQsnGYcBGTwZARMAAE0uAT8ZAwg6CzsFOQsnGUkTEQESB0AYehkBEwAATgUAAwg6CzsFOQtJEwIXt0IXAABPLgEDCDoLOwU5CycZIAsBEwAAUAsBAABRLgEDCDoLOwU5CycZSRMgCwETAABSHQExE1IBuEILVRdYC1kFVwsAAFMdATETUgG4QgtVF1gLWQVXCwETAABUCwExE1UXARMAAFUdATETUgG4QgsRARIHWAtZC1cLARMAAFZIAX0BARMAAFc0ADETAABYEwADCDwZAABZLgA/GQMIOgs7BTkLJxlJEyALAABaLgA/GTwZbggDCDoLOwsAAAABKAADCBwLAAACJAALCz4LAwgAAAMoAAMIHAUAAAQWAAMIOgs7CzkLSRMAAAUPAAshCEkTAAAGBAEDCD4hBwshBEkTOgs7BTkLARMAAAc0AAMIOiEBOws5IRFJEz8ZPBkAAAg0AAMIOiEBOws5C0kTAhgAAAkuAT8ZAwg6IQE7CzkhAScZEQESB0AYfBkBEwAACjQAAwg6IQE7CzkhEUkTAhe3QhcAAAsRASUIEwsDHxsfEQESBxAXAAAMFQAnGQAADQQBAwg+CwsLSRM6CzsLOQsBEwAADgEBSRMBEwAADyEAAAAQLgE/GQMIOgs7BTkLJxlJEzwZARMAABEFAEkTAAASLgE/GQMIOgs7CzkLJxkRARIHQBh6GQETAAATSAB9AYIBGX8TAAAUSAF9AYIBGX8TAAAVSQACGH4YAAAAASgAAwgcCwAAAiQACws+CwMIAAADKAADCBwFAAAENAADCDohBDsLOQtJEz8ZPBkAAAU0AEcTOiEFOws5CwIYAAAGNQBJEwAABwQBAwg+IQcLIQRJEzoLOwU5CwETAAAIEQElCBMLAx8bHxAXAAAJBAEDCD4LCwtJEzoLOws5CwETAAAKBAEDDj4LCwtJEzoLOws5CwETAAALFgADDjoLOws5C0kTAAAMDwALC0kTAAANNQAAAAABEQElCBMLAx8bHxAXAAACNAADCDoLOws5C0kTPxkCGAAAAyQACws+CwMIAAAAAREBJQgTCwMfGx8QFwAAAjQAAwg6CzsLOQtJEz8ZAhgAAAMkAAsLPgsDCAAAAAEkAAsLPgsDCAAAAjQAAwg6IQE7CzkLSRM/GQIYAAADFgADCDoLOws5C0kTAAAEFgADCDohBTsFOQtJEwAABQUASRMAAAYNAAMIOiEFOwU5C0kTOAsAAAcFADETAhe3QhcAAAgPAAshCEkTAAAJKAADCBwLAAAKBQADDjohATshiAE5C0kTAhe3QhcAAAsFAAMOOiEBOyHMADkLSRMAAAwmAEkTAAANNAADCDohATsLOSEkSRMCGAAADkgAfQF/EwAADzQAAwg6IQE7CzkLSRMAABA0ADETAAARNAAxEwIXt0IXAAASEQElCBMLAx8bHxEBEgcQFwAAEw8ACwsAABQVACcZAAAVBAEDCD4LCwtJEzoLOwU5CwETAAAWFQEnGQETAAAXEwEDCAsLOgs7BTkLARMAABg0AAMIOgs7CzkLSRM/GTwZAAAZLgE/GQMIOgs7CzkLJxlJEzwZARMAABouAQMIOgs7CzkLJxlJExEBEgdAGHoZARMAABsuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAHAUAAwg6CzsLOQtJEwIYAAAdLgE/GQMIOgs7CzkLJxlJEyALARMAAB4uATETEQESB0AYfBkAAB8dATETUgG4QgsRARIHWAtZC1cLARMAAAABEQElCBMLAx8bHxAXAAACNAADCDoLOws5C0kTPxkCGAAAAyQACws+CwMIAAAAASQACws+CwMIAAACNAADCDohATsLOSEdSRM/GQIYAAADEQElCBMLAx8bHxAXAAAEFgADCDoLOws5C0kTAAAFDwALC0kTAAAGFQAnGQAABwEBSRMBEwAACCEASRMvCwAAAAENAAMIOgs7CzkLSRM4CwAAAiQACws+CwMIAAADSQACGH4YAAAEDwALIQhJEwAABQUASRMAAAYTAQMICws6CzsLOSEKARMAAAc3AEkTAAAIEQElCBMLAx8bHxEBEgcQFwAACSYASRMAAAoWAAMIOgs7CzkLSRMAAAsuAT8ZAwg6CzsFOQsnGUkTPBkBEwAADBgAAAANLgE/GQMIOgs7CzkLJxlJEzwZARMAAA4uAT8ZAwg6CzsFOQsnGUkTEQESB0AYehkBEwAADwUAAwg6CzsLOQtJEwIXt0IXAAAQNAADCDoLOws5C0kTAhe3QhcAABFIAX0BfxMBEwAAEkgBfQF/EwAAAAEkAAsLPgsDCAAAAhEBJQgTCwMfGx8RARIHEBcAAAMuAD8ZAwg6CzsLOQsnGUkTEQESB0AYehkAAAABEQElCBMLAx8bHxEBEgcQFwAAAi4APxkDCDoLOws5CycZEQESB0AYehkAAAABEQElCBMLAx8bHxAXAAACNAADCDoLOws5C0kTPxkCGAAAAyQACws+CwMIAAAAASgAAwgcCwAAAg0AAwg6IQY7BTkLSRM4CwAAAwUAMRMCF7dCFwAABEkAAhh+GAAABQ0AAwg6CzsLOQtJEzgLAAAGFgADCDoLOws5C0kTAAAHJAALCz4LAwgAAAgFAEkTAAAJDwALIQhJEwAACjQAMRMCF7dCFwAAC0gBfQF/EwAADDQAAwg6IQE7BTkLSRMAAA1IAX0BfxMBEwAADigAAwgcBQAADxYAAwg6IQY7BTkLSRMAABAFAAMIOiEBOwU5C0kTAAARLgE/GQMIOgs7CzkLJxlJEzwZARMAABIdATETUgG4QgsRARIHWCEBWQVXCwAAEzQAAwg6IQE7CzkLSRMCGAAAFEgAfQF/EwAAFRMBAwgLCzohBjsFOSEUARMAABYBAUkTARMAABchAEkTLwsAABg0AAMIOiEBOws5C0kTPxk8GQAAGRMBCws6IQE7CzkhCQETAAAaLgA/GQMIOgs7CzkLJxlJEzwZAAAbBQAxEwAAHB0BMRNSAbhCCxEBEgdYIQFZBVchDAETAAAdNAADCDohATsLOQtJEwIXt0IXAAAeBAEDCD4hBwshBEkTOgs7BTkLARMAAB8NAAMIOiEGOwU5IQhJEwAAIDcASRMAACEdATETUgG4QgtVF1ghAVkFVwsBEwAAIgsBMRNVFwETAAAjLgEDCDohATsFOSEBJxkgIQEBEwAAJAsBAAAlNAADCDohATsLOQtJEwAAJgUAAwg6IQE7CzkLSRMCF7dCFwAAJxEBJQgTCwMfGx8RARIHEBcAACgPAAsLAwhJEwAAKSYASRMAACoPAAsLAAArJgAAACwXAQsLOgs7BTkLARMAAC0EAQMIPgsLC0kTOgs7CzkLARMAAC4TAQMICws6CzsLOQsBEwAALxMBAw4LCzoLOws5CwETAAAwFgADDjoLOws5C0kTAAAxLgA/GQMIOgs7BTkLJxmHARk8GQAAMi4BPxkDCDoLOwU5CycZSRM8GQETAAAzLgE/GQMIOgs7BTkLJxkRARIHQBh6GQETAAA0NAADCDoLOwU5C0kTAhgAADU0AAMIOgs7BTkLSRMCF7dCFwAANgsBVRcAADcdATETUgG4QgtVF1gLWQVXCwAAOAsBMRNVFwAAOR0BMRMRARIHWAtZBVcLARMAADo0ADETAhgAADsLAQETAAA8LgEDCDoLOws5CycZIAsBEwAAPS4BAwg6CzsLOQsnGREBEgdAGHoZARMAAD4LAREBEgcBEwAAPy4BAwg6CzsLOQsnGYcBGREBEgdAGHoZARMAAEAYAAAAQS4APxk8GW4IAwg6CzsLAAAAASQACws+CwMIAAACDQADCDohAjsLOQtJEzgLAAADBQADCDohATsLOQtJEwIXt0IXAAAEDwALIQhJEwAABQUASRMAAAY0AAMIOiEBOws5IRVJEwIYAAAHSQACGH4YAAAIEQElCBMLAx8bHxEBEgcQFwAACSYASRMAAAoTAQMICws6CzsLOQsBEwAACxYAAwg6CzsLOQtJEwAADBUBJxlJEwETAAANLgE/GQMIOgs7CzkLJxk8GQETAAAOLgE/GQMIOgs7CzkLJxkRARIHQBh6GQETAAAPSAF9AYIBGX8TAAAQLgE/GQMIOgs7CzkLJxkRARIHQBh6GQAAEQUAAwg6CzsLOQtJEwIYAAASSAF9AQAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABDQADCDohAjsFOQtJEzgLAAACKAADCBwLAAADSQACGH4YAAAEJAALCz4LAwgAAAUNAAMIOiECOwU5C0kTiAEhEDgFAAAGDQADCDohAjsFOQtJE4gBIRA4CwAABxYAAwg6CzsLOQtJEwAACBYAAwg6IQI7BTkLSRMAAAkoAAMIHAUAAApIAX0BfxMBEwAACw8ACyEISRMAAAwNAAMIOiECOwU5C0kTOAUAAA0hAEkTLwsAAA4FAEkTAAAPAQFJE4gBIRABEwAAEDQAAwg6IQE7CzkLSRMCF7dCFwAAEUgBfQEBEwAAEhMBAwgLCzohAjsFOSEUARMAABMNAAMOOiECOwU5C0kTOAsAABQTAQMICwWIASEQOiECOwU5CwETAAAVFgADCDohAjsFOQtJE4gBIRAAABYBAUkTARMAABcNAAMIOiECOwU5IRdJE4gBIRAAABgEAQMIPiEHCyEESRM6CzsFOQsBEwAAGREBJQgTCwMfGx8RARIHEBcAABoVAScZARMAABsPAAsLAAAcDQBJE4gBCzgFAAAdEwEDCAsLiAELOgs7BTkLARMAAB4TAQsFiAELOgs7BTkLARMAAB8XAQsFiAELOgs7BTkLARMAACANAEkTiAELAAAhFQEnGUkTARMAACIEAQMIPgsLC0kTOgs7CzkLARMAACM0AAMIOgs7CzkLSRM/GQIYAAAkLgA/GQMIOgs7CzkLJxk8GQAAJS4BPxkDCDoLOws5CycZSRM8GQETAAAmLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZARMAACcFAAMIOgs7CzkLSRMCF7dCFwAAKEgBfQGCARkBEwAAKUgAfQF/EwAAAAENAAMIOiEFOwU5C0kTOAsAAAIkAAsLPgsDCAAAA0kAAhh+GAAABBYAAwg6CzsLOQtJEwAABQUASRMAAAZIAH0BfxMAAAcWAAMIOiEFOwU5C0kTAAAIDwALIQhJEwAACQUAAwg6IQE7CzkLSRMCF7dCFwAACjQAAwg6IQE7CzkLSRMCF7dCFwAACygAAwgcCwAADC4BPxkDCDohBzsLOSEaJxk8GQETAAANSAF9AX8TAAAOSAF9AX8TARMAAA8TAQMICws6IQU7BTkLARMAABA0AAMIOiEBOws5C0kTAhgAABENAAMIOiEBOws5C0kTOAsAABIuAT8ZAwg6IQE7CzkhAScZSRMRARIHQBh6GQETAAATNQBJEwAAFC4BPxkDCDoLOwU5CycZSRM8GQETAAAVNAAxEwAAFjQAAwg6IQE7CzkLSRMAABc0ADETAhe3QhcAABgRASUIEwsDHxsfEQESBxAXAAAZDwALCwAAGgQBAwg+CwsLSRM6CzsFOQsBEwAAGxUBJxkBEwAAHBMBAwgLCzoLOws5CwETAAAdLgA/GQMIOgs7CzkLJxlJEzwZAAAeLgA/GQMIOgs7CzkLJxk8GQAAHy4BPxkDCDoLOwU5CycZPBkBEwAAIAsBEQESBwETAAAhHQExE1IBuEILEQESB1gLWQtXCwETAAAiHQExE1IBuEILVRdYC1kLVwsBEwAAIwsBVRcAACQuAQMIOgs7CzkLJxkgCwETAAAlCwEAACYuATETEQESB0AYehkAACcLATETEQESBwETAAAoSAF9AQAAKUgBfQGCARl/EwAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABNAADCDohATsLOSEGSRM/GQIYAAACEQElCBMLAx8bHxAXAAADJAALCz4LAwgAAAABDQADCDohBTsFOQtJEzgLAAACNAAxEwAAAzQAMRMCF7dCFwAABAUAMRMAAAUkAAsLPgsDCAAABgsBVRcAAAcWAAMIOiEFOwU5C0kTAAAINAADDjohATsLOQtJEwAACR0BMRNSAbhCC1UXWCEBWQtXCwAAChYAAwg6CzsLOQtJEwAACzQAAw46IQE7CzkLSRMCF7dCFwAADA8ACyEISRMAAA0uAT8ZAwg6IQE7CzkhAScZSRMRARIHQBh6GQETAAAOEwEDCAsLOiEFOwU5IRQBEwAADw0AAw46IQU7BTkLSRM4CwAAEAUAMRMCF7dCFwAAEQUAAwg6IQE7CzkLSRMCF7dCFwAAEgEBSRMBEwAAEyEASRMvCwAAFAUASRMAABU0AAMIOiEBOws5C0kTAhe3QhcAABYdATETUgG4QgtVF1ghAVkLVyEJARMAABdJAAIYfhgAABgNAAMIOiEFOwU5IQhJEwAAGR0BMRNSAbhCCxEBEgdYIQFZC1cLAAAaFwELIQQ6IQU7BTkLARMAABsuAT8ZAwg6IQY7CzkLJxlJEzwZARMAABwuAT8ZAwg6IQE7CzkhAScZSRMgIQEBEwAAHQUAAw46IQE7CzkLSRMAAB40AAMIOiEBOws5C0kTAAAfEQElCBMLAx8bHxEBEgcQFwAAICYASRMAACEPAAsLAAAiEwEDCAsFOgs7BTkLARMAACMNAAMOOgs7BTkLSRMAACQNAEkTOAsAACU0AAMIOgs7CzkLSRM/GTwZAAAmSAF9AX8TARMAACdIAX0BfxMAACgFAAMIOgs7CzkLSRMAACkuATETEQESB0AYehkBEwAAKi4BMRMRARIHQBh6GQAAKwUAMRMCGAAAAAERASUIEwsDHxsfEBcAAAI0AAMIOgs7CzkLSRM/GQIYAAADJAALCz4LAwgAAAABJAALCz4LAwgAAAINAAMIOiEDOws5C0kTOAsAAAMFAEkTAAAESQACGH4YAAAFFgADCDoLOws5C0kTAAAGDwALIQhJEwAABwUAAwg6IQE7ITE5C0kTAhe3QhcAAAguAT8ZAwg6IQM7BTkhGCcZPBkBEwAACUgBfQF/EwETAAAKEQElCBMLAx8bHxEBEgcQFwAACw8ACwsDCEkTAAAMJgBJEwAADRMBAwgLCzoLOws5CwETAAAOLgE/GQMIOgs7CzkLJxlJEzwZARMAAA8PAAsLAAAQLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZAAARNAADCDoLOws5C0kTAhe3QhcAABJIAX0BfxMAAAABSQACGH4YAAACJAALCz4LAwgAAAMFAEkTAAAEFgADCDoLOws5C0kTAAAFBQADCDohATshIDkLSRMCF7dCFwAABg8ACyEISRMAAAcRASUIEwsDHxsfEQESBxAXAAAIDwALCwMISRMAAAkmAEkTAAAKLgE/GQMIOgs7CzkLJxlJEzwZARMAAAsPAAsLAAAMLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZAAANNAADCDoLOws5C0kTAhe3QhcAAA5IAX0BfxMBEwAAD0gBfQF/EwAAAAFJAAIYfhgAAAJIAX0BfxMBEwAAAwUAMRMCF7dCFwAABA0AAwg6CzsLOQtJEzgLAAAFNAADCDoLOwU5C0kTAAAGSAF9AX8TAAAHKAADCBwLAAAINAAxEwIXt0IXAAAJBQBJEwAACgUAAwg6CzsFOQtJEwAACx0BMRNSAbhCBVUXWCEBWQVXCwETAAAMDQADCDoLOws5C0kTAAANBQADDjohATsFOQtJEwAADgUAAw46IQE7BTkLSRMCF7dCFwAADxYAAwg6CzsLOQtJEwAAEA0AAwg6CzsFOQtJEzgLAAARBQADCDohATsFOQtJEwIXt0IXAAASNAADCDohATsFOQtJEwIXt0IXAAATJAALCz4LAwgAABQPAAshCEkTAAAVBQAxEwAAFjQAAwg6IQE7BTkLSRMCGAAAF0gAfQF/EwAAGDQAAw46IQE7BTkLSRMCGAAAGS4BAwg6IQE7BTkhBicZEQESB0AYehkBEwAAGjQAMRMAABsuAQMIOiEBOwU5IQYnGSAhAQETAAAcAQFJEwETAAAdLgE/GQMIOgs7CzkLJxlJEzwZARMAAB4LAQAAHyEASRMvCwAAIAsBVRcBEwAAITQAAw46IQE7BTkLSRMAACI0AAMOOiEBOwU5C0kTAhe3QhcAACM3AEkTAAAkEwEDCAsLOgs7CzkLARMAACUEAT4hBwshBEkTOgs7CzkLARMAACYNAAMIOiEBOwU5IRpJEwAAJwsBVRcAACgdATETUgG4QgURARIHWCEBWQVXCwETAAApLgEDCDohATsFOQsnGUkTICEBARMAACouAT8ZAwg6IQI7BTkhHCcZSRMgIQMBEwAAKy4BMRMRARIHQBh6GQETAAAsCwExE1UXARMAAC0WAAMIOgs7BTkLSRMAAC4WAAMOOgs7CzkLSRMAAC8NAAMIOiECOws5IQtJEw0LawsAADAuAT8ZAwg6CzsFOQsnGUkTPBkBEwAAMSYASRMAADITAQsLOiECOws5IRQBEwAAMxcBAw4LCzohAjsLOSERARMAADQTAQsLOiEBOwU5CwETAAA1LgA/GQMIOgs7CzkLJxlJEzwZAAA2CwERARIHARMAADcdATETUgG4QgVVF1ghAVkFVwsAADgLATETVRcAADlIAX0BggEZfxMBEwAAOjQAMRMCGAAAOxEBJQgTCwMfGx8RARIHEBcAADwPAAsLAwhJEwAAPRMBAw4LCzoLOwU5CwETAAA+FgADDjoLOwU5C0kTAAA/EwEDDgsLOgs7CzkLARMAAEAXAQMICws6CzsLOQsBEwAAQRcBCws6CzsLOQsBEwAAQg8ACwsAAEMNAAMOOgs7BTkLSRM4CwAARBcBCws6CzsFOQsBEwAARQ0ASRMAAEYuAT8ZAwg6CzsLOQsnGTwZARMAAEcuAT8ZAwg6CzsFOQsnGUkTEQESB0AYehkBEwAASAoAAwg6CzsFOQsAAEkLATETEQESBwETAABKCwEBEwAAS0gBfQGCARl/EwAATDQASRM0GQIXt0IXAABNIQBJEy8TAABOLgEDCDoLOwU5CycZSRMRARIHQBh6GQETAABPBQADDjoLOwU5C0kTAhgAAFAuAD8ZPBluCAMIOgs7CwAAAAFJAAIYfhgAAAJIAX0BfxMBEwAAAw0AAwg6CzsLOQtJEzgLAAAEBQAxEwIXt0IXAAAFNAADCDoLOwU5C0kTAAAGSAF9AX8TAAAHBQBJEwAACCgAAwgcCwAACTQAMRMCF7dCFwAACgUAAwg6CzsFOQtJEwAACx0BMRNSAbhCBVUXWCEBWQVXCwETAAAMFgADCDoLOws5C0kTAAANDQADCDoLOws5C0kTAAAONAADCDohATsFOQtJEwIXt0IXAAAPBQADDjohATsFOQtJEwAAEAUAAw46IQE7BTkLSRMCF7dCFwAAEQ0AAwg6CzsFOQtJEzgLAAASBQADCDohATsFOQtJEwIXt0IXAAATJAALCz4LAwgAABQ0AAMIOiEBOwU5C0kTAhgAABUPAAshCEkTAAAWBQAxEwAAFy4BAwg6IQE7BTkhBicZEQESB0AYehkBEwAAGDQAMRMAABlIAH0BfxMAABouAQMIOiEBOwU5IQYnGSAhAQETAAAbLgE/GQMIOgs7CzkLJxlJEzwZARMAABw0AAMOOiEBOwU5C0kTAhgAAB0LAQAAHgEBSRMBEwAAHyEASRMvCwAAIDQAAw46IQE7BTkLSRMAACE3AEkTAAAiCwFVFwETAAAjCwFVFwAAJBMBAwgLCzoLOws5CwETAAAlBAE+IQcLIQRJEzoLOws5CwETAAAmDQADCDohATsFOSEaSRMAACcdATETUgG4QgURARIHWCEBWQVXCwETAAAoNAADDjohATsFOQtJEwIXt0IXAAApLgEDCDohATsFOQsnGUkTICEBARMAACouAT8ZAwg6IQI7BTkhHCcZSRMgIQMBEwAAKy4BMRMRARIHQBh6GQETAAAsCwExE1UXARMAAC0WAAMIOgs7BTkLSRMAAC4WAAMOOgs7CzkLSRMAAC8NAAMIOiECOws5IQtJEw0LawsAADAuAT8ZAw46IQE7BTkhEScZSRM8GQETAAAxGAAAADILAREBEgcBEwAAMyYASRMAADQTAQsLOiECOws5IRQBEwAANRcBAw4LCzohAjsLOSERARMAADYTAQsLOiEBOwU5CwETAAA3LgE/GQMIOgs7BTkhEicZSRM8GQETAAA4LgA/GQMIOgs7CzkLJxlJEzwZAAA5CwExE1UXAAA6SAF9AYIBGX8TARMAADs0ADETAhgAADwRASUIEwsDHxsfEQESBxAXAAA9DwALCwMISRMAAD4TAQMOCws6CzsFOQsBEwAAPxYAAw46CzsFOQtJEwAAQBMBAw4LCzoLOws5CwETAABBFwEDCAsLOgs7CzkLARMAAEIXAQsLOgs7CzkLARMAAEMPAAsLAABEDQADDjoLOwU5C0kTOAsAAEUXAQsLOgs7BTkLARMAAEYNAEkTAABHLgE/GQMIOgs7CzkLJxk8GQETAABILgE/GQMIOgs7BTkLJxlJExEBEgdAGHoZARMAAEkKAAMIOgs7BTkLAABKCwExExEBEgcBEwAASwsBARMAAExIAX0BggEZfxMAAE1IAH0BggEZfxMAAE4uAQMIOgs7BTkLJxlJExEBEgdAGHoZARMAAE8FAAMOOgs7BTkLSRMCGAAAUC4APxk8GW4IAwg6CzsLAAAAATQAAwg6IQE7CzkLSRMCF7dCFwAAAiQACws+CwMIAAADSQACGH4YAAAEDwALIQhJEwAABQ0AAwg6IQI7BTkLSRM4CwAABgUAAwg6IQE7CzkLSRMCF7dCFwAABzQAMRMCF7dCFwAACAUASRMAAAlIAX0BfxMAAAo0AAMIOiEBOyEoOQtJEwAACy4BPxkDCDohAjsFOQsnGUkTPBkBEwAADC4BPxkDCDohATsLOQsnGUkTEQESB0AYehkBEwAADQUAMRMCF7dCFwAADhEBJQgTCwMfGx8RARIHEBcAAA8WAAMIOgs7CzkLSRMAABATAQMOCws6CzsFOQsBEwAAEQEBSRMBEwAAEiEASRMvCwAAExYAAw46CzsFOQtJEwAAFC4BPxkDCDoLOwU5CycZPBkBEwAAFUgBfQF/EwETAAAWLgE/GQMIOgs7CzkLJxkRARIHQBh6GQETAAAXSAF9AYIBGX8TAAAYHQExE1IBuEILVRdYC1kLVwsAABkLAVUXAAAaLgE/GQMIOgs7CzkLJxlJEyALARMAABsFAAMIOgs7CzkLSRMAABwuATETEQESB0AYehkAAAABSQACGH4YAAACSAF9AX8TARMAAAM0AAMIOiEBOws5C0kTAhe3QhcAAAQFAEkTAAAFKAADCBwLAAAGLgE/GQMIOiECOwU5CycZSRM8GQETAAAHJAALCz4LAwgAAAgKAAMIOiEBOwU5IQIRAQAACUgAfQF/EwAACg8ACyEISRMAAAsNAAMIOiEEOws5IQZJEzgLAAAMDQADCDohAjsFOQtJEzgLAAANBQADCDohATsh6gA5C0kTAhe3QhcAAA40ADETAhe3QhcAAA80AAMIOiEBOws5C0kTAAAQBQAxEwIXt0IXAAARFgADCDoLOws5C0kTAAASAQFJEwETAAATBQADCDohATshIjkLSRMAABQmAEkTAAAVDQADCDohAjshmQI5C0kTAAAWIQBJEy8LAAAXNAADCDohAjshqAQ5C0kTPxk8GQAAGC4BPxkDCDohAjsFOSENJxk8GQETAAAZBQADCDohATsLOQtJEwIYAAAaHQExE1IBuEIFVRdYIQFZC1cLARMAABsRASUIEwsDHxsfEQESBxAXAAAcBAE+CwsLSRM6CzsLOQsBEwAAHRMBAwgLCzoLOws5CwETAAAeFwEDCAsLOgs7BTkLARMAAB8TAQMOCws6CzsFOQsBEwAAIBYAAw46CzsFOQtJEwAAISEAAAAiLgE/GQMIOgs7CzkLJxlJEzwZARMAACMPAAsLAAAkJgAAACUuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAJjQAAwg6CzsLOQtJEwIYAAAnCgADCDoLOws5CxEBAAAoCwFVFwAAKQoAMRMRAQAAKgUAMRMAACsdATETUgG4QgVVF1gLWQVXCwETAAAsSAB9AYIBGX8TAAAtSAF9AX8TAAAuLgEDCDoLOws5CycZSRMgCwETAAAvCgADCDoLOws5CwAAMC4BAwg6CzsFOQsnGUkTIAsBEwAAMQUAAwg6CzsFOQtJEwAAMi4APxk8GW4IAwg6CzsLAAAAASQACws+CwMIAAACNAADCDohATsLOQtJEwIXt0IXAAADDQADCDohAjsFOQtJEzgLAAAEDwALIQhJEwAABQUAAwg6IQE7CzkLSRMCF7dCFwAABhEBJQgTCwMfGx8RARIHEBcAAAcWAAMIOgs7CzkLSRMAAAgTAQMOCws6CzsFOQsBEwAACQEBSRMBEwAACiEASRMvCwAACxYAAw46CzsFOQtJEwAADC4BPxkDCDoLOws5CycZSRMRARIHQBh6GQETAAANHQExE1IBuEILEQESB1gLWQtXCwAADgUAMRMCF7dCFwAADzQAMRMCF7dCFwAAEC4BPxkDCDoLOws5CycZEQESB0AYehkBEwAAES4BAwg6CzsFOQsnGUkTIAsAABIFAAMIOgs7BTkLSRMAABM0AAMIOgs7BTkLSRMAAAABNAADCDohATsFOQtJEwIXt0IXAAACSQACGH4YAAADNAAxEwIXt0IXAAAEDQADCDoLOwU5C0kTOAsAAAUFADETAhe3QhcAAAYkAAsLPgsDCAAABwUAAwg6IQE7BTkLSRMCF7dCFwAACEgBfQF/EwAACQ8ACyEISRMAAApIAX0BfxMBEwAACwUASRMAAAw0AAMIOgs7BTkLSRMAAA0BAUkTARMAAA4WAAMIOgs7CzkLSRMAAA8hAEkTLwsAABAuAT8ZAwg6IQE7BTkLJxlJExEBEgdAGHoZARMAABEFAAMIOgs7BTkLSRMAABI0AAMIOiEBOws5C0kTAhe3QhcAABMWAAMIOiEHOwU5C0kTAAAUSAB9AX8TAAAVJgBJEwAAFjQAAwg6IQE7CzkLSRMCGAAAFy4BPxkDCDohCzsLOSEaJxk8GQETAAAYCwFVFwAAGS4BMRMRARIHQBh6GQETAAAaKAADCBwLAAAbHQExE1IBuEILVRdYIQFZBVcLARMAABwFAAMIOiEBOws5C0kTAhe3QhcAAB00AAMIOiEBOws5C0kTAAAeHQExE1IBuEILVRdYIQFZC1cLARMAAB8TAQMICws6IQc7BTkLARMAACA0AAMIOiEDOyGoBDkLSRM/GTwZAAAhNABHEzohATsFOQtJEwIYAAAiHQExE1IBuEILEQESB1ghAVkFVwsBEwAAIy4BPxkDCDoLOwU5CycZSRMgCwETAAAkBQADCDohATsLOQtJEwAAJQ0AAwg6IQM7IZkCOQtJEwAAJjQAAwg6IQE7BTkLSRMCGAAAJy4BPxkDCDohCjsFOQsnGUkTPBkBEwAAKAUAMRMAACkdATETUgG4QgtVF1ghAVkFVyEGAAAqLgEDCDohAzsFOSEBJxlJEyAhAwETAAArLgEDCDohATsLOSENJxkgIQEBEwAALEgBfQGCARl/EwAALS4APxk8GW4IAwg6IQ07IQAAAC4RASUIEwsDHxsfEQESBxAXAAAvNQBJEwAAMA8ACwsAADEmAAAAMhUAJxkAADMEAQMIPgsLC0kTOgs7BTkLARMAADQXAQMICws6CzsFOQsBEwAANRMBAw4LCzoLOwU5CwETAAA2FgADDjoLOwU5C0kTAAA3IQAAADghAEkTLwUAADkuAT8ZAwg6CzsLOQsnGUkTPBkBEwAAOi4BPxkDCDoLOwU5CycZPBkBEwAAOwoAAwg6CzsFOQsRAQAAPC4BPxkDCDoLOws5CycZSRMRARIHQBh6GQETAAA9LgE/GQMIOgs7CzkLJxkgCwETAAA+LgE/GQMIOgs7CzkLJxlJEyALARMAAD8uAQMIOgs7CzkLJxkRARIHQBh6GQETAABACwFVFwETAABBNAADDjoLOws5C0kTAhe3QhcAAEILAREBEgcBEwAAQx0BMRNSAbhCCxEBEgdYC1kLVwsAAERIAH0BggEZfxMAAEU0AAMOOgs7CzkLSRMAAEYLAQAARx0BMRNSAbhCCxEBEgdYC1kLVwsBEwAASB0BMRNSAbhCC1UXWAtZC1cLAABJNAAxEwAASgsBMRNVFwAASx0BMRNVF1gLWQtXCwAATEgBfQGCARl/EwETAAAAASQACws+CwMIAAACBQADCDohATshBDkLSRMCGAAAAxEBJQgTCwMfGx8RARIHEBcAAAQmAEkTAAAFFgADCDoLOws5C0kTAAAGLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZARMAAAc0AAMIOgs7CzkLSRMCF7dCFwAACA8ACwtJEwAAAAEkAAsLPgsDCAAAAhYAAwg6IQI7CzkLSRMAAAMFAAMIOiEBOyEFOQtJEwIXt0IXAAAEEQElCBMLAx8bHxEBEgcQFwAABSYASRMAAAYuAT8ZAwg6CzsLOQsnGUkTEQESB0AYehkBEwAABzQAAwg6CzsLOQtJEwIXt0IXAAAIDwALC0kTAAAAASQACws+CwMIAAACDwALIQhJEwAAAxEBJQgTCwMfGx8RARIHEBcAAAQ0AAMIOgs7CzkLSRM/GTwZAAAFFQAnGUkTAAAGNAADCDoLOws5C0kTPxkCGAAABy4APxkDCDoLOws5CycZSRMRARIHQBh6GQAAAAEkAAsLPgsDCAAAAg8ACyEISRMAAAMRASUIEwsDHxsfEQESBxAXAAAENAADCDoLOws5C0kTPxk8GQAABRUAJxlJEwAABjQAAwg6CzsLOQtJEz8ZAhgAAAcuAD8ZAwg6CzsLOQsnGUkTEQESB0AYehkAAAABKAADCBwLAAACDQADCDohBTsFOQtJEzgLAAADJAALCz4LAwgAAAQNAAMIOgs7CzkLSRM4CwAABSgAAwgcBQAABkkAAhh+GAAABxYAAwg6CzsLOQtJEwAACBYAAwg6IQU7BTkLSRMAAAlIAX0BfxMBEwAACg8ACyEISRMAAAsFAEkTAAAMLgE/GQMIOgs7CzkLJxk8GQETAAANBQAxEwIXt0IXAAAOEwEDCAsLOiEFOwU5CwETAAAPBAEDCD4hBwshBEkTOgs7BTkLARMAABA0AAMIOiEBOws5IQdJEz8ZAhgAABEuAT8ZAwg6IQE7CzkhDicZICEBARMAABIFAAMIOiEBOws5C0kTAAATSAF9AYIBGX8TAAAUEQElCBMLAx8bHxEBEgcQFwAAFRMBAwgLCzoLOws5CwETAAAWDwALCwAAFwQBAwg+CwsLSRM6CzsLOQsBEwAAGBMBCws6CzsLOQsBEwAAGS4BPxkDCDoLOws5CycZSRM8GQETAAAaLgExExEBEgdAGHoZARMAABsdATETUgG4QgsRARIHWAtZC1cLARMAABxIAH0BfxMAAB0uATETEQESB0AYehkAAB4dATETUgG4QgtVF1gLWQtXCwETAAAfSAB9AYIBGX8TAAAAASgAAwgcCwAAAiQACws+CwMIAAADKAADCBwFAAAEBQBJEwAABQ8ACyEISRMAAAYWAAMIOgs7CzkLSRMAAAcEAQMIPiEHCyEESRM6CzsFOQsBEwAACDQAAwg6IQE7CzkhJkkTPxkCGAAACQUAMRMCF7dCFwAACgUAAwg6IQI7IdMNOQtJEwAACxEBJQgTCwMfGx8RARIHEBcAAAwmAEkTAAANDwALCwAADjUASRMAAA8VAScZARMAABAEAQMIPgsLC0kTOgs7CzkLARMAABE0AAMIOgs7CzkLSRMCGAAAEhUBJxlJEwETAAATFQAnGUkTAAAULgADCDoLOws5CycZSRMRARIHQBh6GQAAFS4BAwg6CzsLOQsnGUkTEQESB0AYehkBEwAAFgUAAwg6CzsLOQtJEwIYAAAXHQExE1IBuEILEQESB1gLWQtXCwAAGC4BPxkDCDoLOwU5CycZSRMgCwETAAAAASQACws+CwMIAAACDQADCDohAjsLOQtJEzgLAAADDwALIQhJEwAABBYAAwg6CzsLOSEZSRMAAAURASUIEwsDHxsfEQESBxAXAAAGEwEDCAsLOgs7CzkLARMAAAcVAScZSRMBEwAACAUASRMAAAk0AAMIOgs7CzkLSRM/GQIYAAAKLgA/GQMIOgs7CzkLJxlJEzwZAAALLgE/GQMIOgs7CzkLJxlJExEBEgdAGHoZAAAMBQADCDoLOws5C0kTAhe3QhcAAA1IAH0BfxMAAAABJAALCz4LAwgAAAJJAAIYfhgAAAMFAAMIOiEBOws5C0kTAhe3QhcAAAQPAAshCEkTAAAFBQBJEwAABjQAAwg6IQE7CzkLSRMCF7dCFwAABxYAAwg6CzsLOQtJEwAACBYAAwg6CzsFOQtJEwAACUgAfQF/EwAACiYASRMAAAsuAD8ZAwg6CzsLOQsnGUkTPBkAAAxIAX0BfxMAAA0uAT8ZAwg6IQE7CzkLJxlJExEBEgdAGHoZARMAAA40AAMOOiEBOws5C0kTAhgAAA8RASUIEwsDHxsfEQESBxAXAAAQLgE/GQMIOgs7CzkLJxlJEzwZARMAABELAVUXARMAABIBAUkTARMAABMhAEkTLwsAABQuAQMIOgs7CzkLJxlJExEBEgdAGHoZAAAVCwERARIHAAAWNAADCDoLOws5C0kTAhgAABdIAX0BfxMBEwAAAAFJAAIYfhgAAAIFAAMIOiEBOws5C0kTAhe3QhcAAAMkAAsLPgsDCAAABAUASRMAAAUPAAshCEkTAAAGSAB9AX8TAAAHFgADCDoLOws5C0kTAAAINAADCDohATsLOQtJEwIXt0IXAAAJFgADCDoLOwU5C0kTAAAKNAADDjohATsLOQtJEwIYAAALNwBJEwAADEgBfQF/EwAADSYASRMAAA4uAD8ZAwg6CzsLOQsnGUkTPBkAAA8uAT8ZAwg6IQE7CzkhAScZSRMRARIHQBh6GQETAAAQSAF9AX8TARMAABE0AAMIOiEBOws5C0kTAhgAABINAAMIOiEBOws5C0kTAAATEQElCBMLAx8bHxEBEgcQFwAAFC4BPxkDCDoLOwU5CycZSRM8GQETAAAVLgE/GQMIOgs7CzkLJxlJEzwZARMAABYLAVUXARMAABcuAQMIOgs7CzkLJxlJExEBEgdAGHoZARMAABgXAQsLOgs7CzkLARMAABkBAUkTAAAaIQBJEy8LAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARgQAAAUACACZAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfBUUAAABMAAAAgAAAAKAAAADJAAAAAgEfAg8VAQEAAAELAQAAARQBAAACHAEAAAMqAQAAAjQBAAACQAEAAAJKAQAAAlMBAAACZAEAAAJxAQAAAnoBAAACggEAAASNAQAAAp8BAAACpgEAAAKuAQAAArYBAAACvwEAAALJAQAAAtQBAAAABQEACQIAEABAAQAAAAPmAAEGAQYX9gUDgwUBA64BAQUDFBMTExUFHAYBBQx6BRwDei4FAwZnBRsGAQUDBskFGwYBBQMGyhMFEQYBBQZ0BQMGdwVCBgEFDUoFAwY9BQYGAYIFBwPCfgEFDgACBAFzBQMGZwUGBgEFBQZnBQOiBQUGAQUSAAIEAVgFAwatBQUGAQUUAAIEAVgFAwavXAUkBgEFBnQFAwZdBQUUBQMTBQEGEwUFBgNtugUDA74B8hMFFgYBBQNKBQcG3RMFCgYBBQcGygUOBgEIggUHBgPDfgEFA70FBRQFAxMFAQYTBQcGA68BugUKBgEFBwagBQ4GAQUBBgPTfgjIBQODBRUGAQUMdwUVCEcFAwaFBQwGAQUBCLAGA8YAggUFCBMTBAIFHgPBzAABBTMBBAMFAQOpuH8BAQEEAQUCBgOge3QEAwUMA+MLdAUBA/14LgaQBgEEAQULAAIEAQOWewEFBQZLEwUKBgEFAgYxBQUGAQUCBpUFFwN5ggQDBQcD6QsBBQUTBQwGAYIEAQUXA5Z0AQUgAwlYBQkDdXQFBQYDCy4FIAYBBQguBQoGlAUlBgEFDS4FBwaIBREGAQUFBqAFIAYBBQguBQUGlRMFCAYBBQUGhQUhBgEFCJ4FBwZZBQW8WQUgBgEFHgACBAHIBQV4BR4AAgQBcAUFBkBaWgUNAzpmBQIUExMFOwYBBRt0BQW8BRtyBQIGPhMFDgACBAEBBQMIPgUhBgEFCgACBAGQBQMGWQUVBgEFA4MFCAACBAE7BQMGSwUVBkkFDgACBAE5BQNOBRUAAgQDBlQFDgACBAEBBQMGXgUCBjwFBwYBBQIGdQUGBgF0BQUGA7l/AVoFEAYBBQ/aBRBiBQUGagUPBgEFCLsFDQACBAFlBQUGZwUIBgEFBQaFBQgGAQUBogUgA1AIPAUNbwUFBl0FIAYBBQguBQIGkgUFAwqeBSAGAQUILgUCBpIILwUZBgEFBQZoEwUIBgEFBwaDBAMD2AsBBQUTBQwGAVhmBAEFBwYDwXQBBQoGWgUDBmYFAQYTBQIGA1YISgYTBRnVBQIGZwUOAAIEAQYD2wC6AAIEATwAAgQBWAUHBgNIAQUBA4p/ggUDgxQUBRQGAQUDBskFCQYBBQMGWgMMLgUBBhMGAwoIPAUDgxQUBRQGAQUDBskFCQYBBQMGWgMMLgUBBhMGA4UBCDwGAQUFBoMFDAYBBSkAAgQBWAUBZwIGAAEBJAEAAAUACABLAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAyQCAAArAgAAXwIAAAIBHwIPB38CAAABiQIAAAGTAgAAApsCAAACqAIAAAKxAgAAArsCAAACBQEACQKQHABAAQAAAAMUAQUDgxQFCgEFBwh2BQgGAQUHBi8FCAYBBQqpBQhNBQoGcQUBBl0GCDIFA7sFQgYBBRF0BQMGWRQFBgYBBRUAAgQBBl0AAgQBBkoAAgQBWAACBAF0BQcGrgUcAAIEAywFFQACBAEBBQOVBQEGdQUDcwUSA3jkBTAAAgQBBoIFKwACBAEGAQUwAAIEAWYFKwACBAFYBTAAAgQBPAUBBgMPngUDEwUGBgEFAaMFBwZjBRMGAQUHBp8FAQYUBQcQAgUAAQFSAAAABQAIAEoAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8ECgMAABEDAABFAwAAZQMAAAIBHwIPBp0DAAABqAMAAAKwAwAAAr0DAAACxgMAAAPRAwAAATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwIiBAAAKQQAAAIBHwIPAl0EAAABaAQAAAE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CuQQAAMAEAAACAR8CDwL0BAAAAf8EAAABEAEAAAUACABLAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA04FAABVBQAAiQUAAAIBHwIPB6kFAAABsgUAAAG7BQAAAsUFAAAC0QUAAALbBQAAAuMFAAACBQEACQKAHQBAAQAAAAOIAQEGAQUDBogFBgYBBQEDGZAFAwbiWQUBBhMGA6V/rAYBBQMGuxMVBQ8GAQUGdAUEBlkFDAYBBQMGaAUGBgEFBwZaBQoGAQUBAw5YBgNn8gUDAxABEwUGBgEFAwZ1BQ4AAgQBAQUHCBQTBQsGAQUKPAUCBlkFAwYBBSkGKgUOAAIEAUoAAgQBBlgFARkFCQYDc8gFAQYDDVgGAwkIngYBBQMGEwUBBgMWAQIDAAEBNgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAjsGAABCBgAAAgEfAg8CdgYAAAGBBgAAATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwLSBgAA2QYAAAIBHwIPAg0HAAABGAcAAAG6AAAABQAIADwAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DZQcAAGwHAACgBwAAAgEfAg8EwAcAAAHHBwAAAc4HAAAC1QcAAAIFAQAJAlAeAEABAAAAAwsBBgEFAwYIgxQDHwImAQYIggACBAFYCGYAAgQBPAbmBQEGEwg8BQcDYWYFAgYDDPITBQcGEQUCdQaLEwUHBhEFAnUGAwuQEwUHBhEFAnUGixMFBwYRBQJ1Bl8TBQcGEQUCdQIFAAEBUgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAiMIAAAqCAAAAgEfAg8CXggAAAFpCAAAAQUBAAkCUB8AQAEAAAADEgEFAxMFAQYTAgMAAQFUAAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CuQgAAMAIAAACAR8CDwL0CAAAAf8IAAABBQEACQJgHwBAAQAAAAMJAQUDAwkBBQEGMwIBAAEBNgAAAAUACAAuAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAlUJAABcCQAAAgEfAg8CkAkAAAGgCQAAAXwFAAAFAAgAcwAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwP6CQAAAQoAADUKAAACAR8CDw9VCgAAAWQKAAABcwoAAAJ8CgAAAoYKAAACkgoAAAKcCgAAAqQKAAACsQoAAAK6CgAAAsIKAAACzgoAAALfCgAAAugKAAAC8QoAAAAFAQAJAnAfAEABAAAAA9QAAQYBBQMGAz66EwUBBgNBAQUDAz88TAUBA79/WAUDAz+6BkwAAgQBBlgIIAACBAE8BlkAAgQBBtY8AAIEATwGhxMFAQMbyAYBBQMGyRMTFAURAAIEAQEFAQZvBREAAgQBQQUK5AUHBqAFFgYBBQo8BU9ZBTd0BQs8BSEAAgQCBo0FEQACBAFKBQOWBQcGATwFAwaDBQYGAQUDBpUFCwYBdEoFFHQFAwZLBRsGAQUDBmcFGwYBBTEAAgQBWAUIPgUuAAIEAWQFGQACBAFKBQh2BRkAAgQBSAUDBloFCAYBBQYAAgQBZgUDBpcFCAYBBSs8BS4AAgQBPQUrVwUuAAIEAT0FAwYDD1h1BQEGEwUHBgNxyBMFFQYTBSM/BSJLBRVGBQcG5wUPBgEFIHQFBwZLBQ8GEQUfPQUHBksFDAYBBQoAAgQBZgUCBk0FCgYTBQJlBQp1BQItrAUKA1wBBQcGAxJ0A3cIngbyBQEGAAkCUCEAQAEAAAADoAIBBQMISxQVBQcGAQUGdAUBAxRYBQMGA24IZqAFCwYBBQMGWQUbBgEuSgUNA8d+CBIFDwO6AdYFG50FDAACBAGCBQMGdRUFAQPAfgEFAxQTBQ0GAQUDBmcTExgFBgYBBQMGAxZmBRAGEwUGLQUDBgMPngUGBgEFJAACBAGeBRsAAgQBPAUDBgMVggUNBgEFBjwFAwYDDJAFBQYBBQMGTAUMAAIEAQEFFgaTBRcDPHTWBQcDUgEFBgYIKAUdBgEFBgY9BQkGZgUIBpEFBgMSAQUHFhMFEAYDaQEFDwMWdD0FBwY+EwUKBgEFCwZSExMFDgYBkJAFDAYDDQEFAQOyfgEFAxQFARAFAxoDF4IGPAUFBgOwAQEFNQOzfwEFDAACBAFKBQeTBSYGFwURAwkuBSoDcjwFEEEFGQMJPAUQA3g8BRQDejwFBwZBExoGkAUGBgMVrBMYBQcWEwUPBhEFCkAFDyo9BQcGPhMFCgYBBQsGwhMTBQ4GAQUGBlkGCLoFBwOPfwEFJwACBAGCBQc9BQ0DCqxKBQYGAzpmBR0GAQUGBj0FCQZmBQgGkQUGAxcBBQcWEwUQBgNkAQUPAxt0PQUHBj4TBQoGAQULBlITEwUOBgGQZgUMBgMKAQUBA7V+AQUDFAUBEAUDGgU1BgP6ADwFAwOGf0oGAxdYBjwFBQYDrQEBBTUDtn8BBQwAAgQBAQACBAEG5AURAAIEAQYD5X4BBQcG2gURAAIEAXAFBzIGjgUTBgEFFp4FCjwFBwZaBSEAAgQCxAURAAIEAUoAAgQBBghKBQYGA7kBAQUdBgEFBgYwBQkGZgUIBksFBgMMAQUHFhMFEAYDbwEFDwMQyD0FBwY+EwUKBgEFCwZSExMFDgYBkAguBQwGAxABBQEDr34BBQMUBQEQBQMaAxeCBi4FBQYDswEBBQznBQEDq34BBQMUBQEQBQMaAxeCBjwFBQYDtwEBBQYDWVgFBxYTBQ8GET0FBwY+EwUKBgEFBgYDeAggBQcWEwUPBhE9BQcGPhMFCgYBBQYGA3ieBQcWEwUPBhE9BQcGPhMFCgYBBQcGA69/CCAFFgYDH5AFBAYDZHQTEwUnBhEFKD0FDSoFEU0FKD0FBAYvBQEDlH8BBQMUBQEQBQMaAxeCBi4FDQYDyAABBQcRBp4FBgYDxgABEwUHA0nWAg0AAQGqAAAABQAIADcAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DRQsAAEwLAACACwAAAgEfAg8DoAsAAAGuCwAAAbwLAAACBQEACQKwJABAAQAAAAMNAQYBBQeEBQMGqxMFBgYBBQMGWgUNBhYFC1QFAwY9BQQGFgULRgUDBksTBQsGEQUDBkwFDQYBBQMGWQUEBgEFAT0GvwYBBQMGEwURBgEFAwZ1BQEGEwUDEVgAAQE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CCQwAABAMAAACAR8CDwJEDAAAAU8MAAABigEAAAUACABVAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA6MMAACqDAAA3gwAAAIBHwIPCf4MAAABDA0AAAEaDQAAAiINAAACLg0AAAI4DQAAAkkNAAACVg0AAAJfDQAAAgUBAAkCACUAQAEAAAADuAEBBgEFAwatExMVBRYGAQUnPAUBA3ouBTdCLgUGZgUDBsEFBwMtAjEBFwUVBgEFBwa7BQoGAQUMBqUFDwYBBSsAAgQBAxWQBQUGuwUPBgEFAT5YBQ8eBQMDsH9KBQcGAxcIngUVBgEFBwa7BQoGAQUMBqUFDwYBBQQGWwUFBgEFBAZ1BQMDLAEFAQYDpH88BQcG+gUKBgHyBQED1wAuWAUDA65/kAUHBgMy8gUVBgEFBwa7BQoGAQUEBqDlBQcDTqwFFQYBBQcGuwUKBgEFDAZtBQ8GAQUEBpMFBQYBBQQGdQUDAz8BBQQDbtYFBQYBBQQGdQUDAxEBBQQDun9Y5QUDA8UAAQUEA01Y5QUDAzIBBQQDZljlBQYTAgoAAQF0AgAABQAIAF8AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DrQ0AALQNAADoDQAAAgEfAg8LCA4AAAESDgAAARwOAAACJg4AAAIyDgAAAjwOAAACRA4AAAJRDgAAAlwOAAACZQ4AAAJ5DgAAAgUBAAkCwCYAQAEAAAAD4gABBQMIGPQFDQYBBR4AAgQBBnQFBwh2BScGAQUWLgUHBmcFCwYBBjAFDgYBWAUNBksFEwYBBQ5KBQcGWgUMBgFKBR4AAgQBBgN4AQUDAwtYBQEGPVgFA3MFAQYDtX+6BgEFAwbJFAUaBgEFAWMFBlsFDEsFAQMPLnQFAwYDcqwFIgYBWFgFAwaDBQYGAQUDBlsFEQYTBQNMBRBxBQMGLxSSBREGAQUDdwUROnMFAwZLFGcFCgYBBQwDdS48BQEGAxA8BgEFAwa7ExQFGgYBBQFiBQYyBQEDGkoFAwYDafIGngZoEwULBgEFAwZ2BRIBBQwGVQUHBgMPuhMFEgNzAQaCBQcGPgUTBgEFCi4FJDEFCkcFCwYwBQ4GAQUNBlsFHAYBBQsGTFkFAxiRBQEGE3QFDQYDc8gFGwYBBQEGAyryBgEFAwatBQfnBR4GAQUKZgUHBoQFGgYBBQcGnwUDAxgBBQEGEwUDA2HWBQcGAxtYBQEDSgEFAxQUBRoGAQUGZpC6BQcGAx8BBQEDXQEFAxQUBRoGAQUGZkoFBwYDIAEFHgYBBQpmBQsGWhMFFQYBBSYAAgQBBnQFDbwFDwY8BQ0GS1kFJgACBAEOBQteBhQFGXIFCwatBR4GAQULBp8GrAUHBhZZBQMXBQEGEwguWDwFCQYDZQEGdGYCBQABATYAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwLPDgAA1g4AAAIBHwIPAgoPAAABFA8AAAE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CbQ8AAHQPAAACAR8CDwKoDwAAAbwPAAABUwUAAAUACABLAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAxQQAAAbEAAATxAAAAIBHwIPB28QAAABeBAAAAGBEAAAAosQAAAClxAAAAKhEAAAAqkQAAACBQEACQJgKQBAAQAAAAMYAQYBBQMGExMTFBMFDAYTBQYtBQEGA3l0BQMDCQEFQwYBBQ1KBQMGPQUGBgGCBQEYBQMGfhMFBgYBBQGvBl4GAQUDBhMTExQFUQYBBQ1KBQMGPgUhBgEFJUsFH1cFDgZZBp4FBwYIFQUaBgEFCnQFJlkFBDwFDwZVBRAGAQUOBkkFCgZfBQEvBiYGAQUDBskTExMVBQEGA3kBBQdDBQYAAgQBWAUDBmkTBQEDSQEFAxQTExQTBREGAQUMAy10BQYDUy4FAQYDeXQFAwMJAQVDBgEFDUoFAwY9BQYGAQUDBoQTBQYGAYIFAwYDLQEUBSEGAQUfSgUOBlkFJQYBBQ5KggUPBggTBRAGAQUOBkkFB1sFDAYBBQoAAgQBCBIFAU6QBQwDcJAFAQMQLpAGzwYBBQMGExMUEwUBA7B/AQUDFBMTFBMFEQYBBQwDygB0BQYDtn8uBQEGA3l0BQMDCQEFQwYBBQ1KBQMGPQUGBgGQBQEDywABBQMGA7d/ghMFBgYBkAUDBgPGAAEFIQYDSgEFIgM2WAUDBj0FAQNBAQUDFBMTFBQFHwYBBQ4GWQUlBgEFDlieBQcGCDEFGgYBBQp0BSZZBQQ8BQ8GVQUQBgEFDgZJBlgFDAMzAQUBMgYkBQMTExQTBQEDon8BBQMUExMUEwURBgEFDAPYAHQFBgOofy4FAQYDeXQFAwMJAQVDBgEFDUoFAwY9BQYGAYIFAQPaAAEFAwYDqH+QEwUGBgGCBQMGA9QAARQFCgYBBQFLLgalBgEFAwYTExMTFBMFAQOOfwEFAxQTExQTBREGAQUMA+wAdAUGA5R/LgUBBgN5ggUDAwkBBUMGAQUNSgUDBj0FBgYBggUBA/kAAQUDBgOJf4ITBQYGAYIFAwYD6AABFAUhBgEFJUsFH1cFDgZZBp4FBwb1BQoGAQUCBmgFBQYBBQIGWgUPA3pKBRAGAQUOBkkFDAZTBQEDEC4G3AUDExMTBQED9H4BBQMUExMUEwURBgEFDAOGAXQFBgP6fi4FAQYDeXQFAwMJAQVDBgEFDUoFAwY9BQYGAYIFAQOFAQEFAwYD/X6QEwUKBgOBAQEFAZ8G3AYBBQMGExMTFBMFAQPlfgEFAxQTExQTBREGAQUMA5UBdAUGA+t+LgUBBgN5dAUDAwkBBUMGAQUNSgUDBj0FBgYBkAUBA5gBAQUDBgPqfoITBQYGAZAFAwYDkAEBBRcGAQUDBj0FAQP3fgEFAxQTExQUBSUGEwUhVwUfWAUOBlkFBwi9BRoGAQUKdAUmWQUEPAUPBlUFEAYBBQ4GSQUMBgP+AFgFATQFAwYdFAU8BgEFAYMGiQYBBQMGExMTExMUEwUBA89+AQUDFBMTFBMFEQYBBQwDqwF0BQYD1X48BQEDogFmBQYD3n48BQEGA3kuBQMDCQEFQwYBBQ1KBQMGPQUGBgGCBQEDxAEBBQMGA75+uhMFBgYBggUDBgOnAQEUBRMGAQUDBmcFBgYBBQMGTQUBA9t+AQUDFBMTFBQFIQYBBSVLBR9XBQ4GWQaeBQcG2QUaBgEFCnQFJlkFBDwFDwZVBRAGAQUOBkkGWAUMA5QBAQUBAxw8BQMGA22CFQUOBgEFAwY9BQcDClhLBREGAQUDBgN4SgEFBxQFCgYBBSoAAgQBdAUHBncFCgYBBQgGWQUwBgEFD0oFAUI8AgEAAQE2AAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8C/hAAAAURAAACAR8CDwI6EQAAAUoRAAABhQAAAAUACABBAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA6gRAACvEQAA5REAAAIBHwIPBQUSAAABFhIAAAEnEgAAAjASAAACOBIAAAEFAQAJAqAtAEABAAAAAzEBBgEFAwbJFAUBBg8FA5MGWQUMBgEFAwh1BQw7BQMGL1oFAQYTdCAgAgIAAQHIAAAABQAIAEEAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DmBIAAJ8SAADVEgAAAgEfAg8F9RIAAAEIEwAAARoTAAACIxMAAAItEwAAAQUBAAkC8C0AQAEAAAADIAEGAQUDBrsUBQEGDwUFPwUDBgMLWAUMBgEFClgFDEo8Zi4FAwZZBQYGAQUmAAIEAkoFBgACBAI8BTUAAgQEPAUDBmgFAQYTWCAFJgACBAFVBQYAAgQBPAUFBgN5WAUMBgGCPC48BQEDClhmAgIAAQEBJQAABQAIAG0AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8EihMAAJETAADHEwAA5xMAAAIBHwIPDSYUAAABNhQAAAFGFAAAAk0UAAACVhQAAAJgFAAAAmkUAAACcRQAAAJ6FAAAAoIUAAADihQAAAKTFAAAApwUAAAABQEACQJgLgBAAQAAAAPDCAEGASAFAwZ5BQoBBR4BBQMTEwUBBgN5AQUaBgNXZgUDFBMUAx8BBAIFCAYD3noBBAEFAQOnBTwFCjd0PAUDBgMOAQQCBRwDynoBBQUUExMTEwUIBgEFCQaEBjwGSwUMBgEuBQ4GaAURBgGCBAEFBwYDxAUBEwUKBgMQAQUHAAIEBANe5AUhAAIEAQMePAUJAAIEBGYFAwZqBQoGAQg8kAUB5QQCBQoGA616kAUNBgEFBwaDBR0GATwFG59KBAEFBwACBAQDrgUBBQMGAx50BQcAAgQEBgNiAQUhAAIEAgMeLgACBAIuAAIEAroAAgQCSgACBAK6AAIEAp4FAwYBBmZYBQEGA5J6rAYBBQMGsAUBBg4FDkAFBTwFQwACBAFYBSkAAgQBPAUFBl0FBwYWOAYDCVgFKQYBBTJKBQs+BQMGPAUBBmdYBQcGA3hYBQsGiQUDBjwFAQZnWAYDmQGeBgEFAwYDCQhKExMFDQYBBQEDdYIFDQMLWAUBA3UuBQ0DCzw8PAUDBpIFDgYBBSAAAgQBPAUNAwmQBSAAAgQBA3c8BQMGAwk8BQUGAQUDBgMM5AUYAwwBBRAGAQUYSgULhMgFIwACBAEQBRgAAgQBCBIFEgaFBgEFCzsFBwYDtH4IPAUpBgEFMkoFCz4FAwY8BmYFEgYDywEBBgEFBwZZBQ4GA6R+AQUZA9wBPAUGBgOffkoFAxcFBQYBBUMAAgQBWAUpAAIEATwAAgQBWAUXA9wBAQUFBgOpflgFBwYWOAZcBQsGiQUDBjwGZgUSBgPLAQEGAVgFGAYPBgFKBRoGAwvIBRAGAQUXPAUaZgUFBp8FGscFEAYBBRc8BRpmBQEDMkpYBQUGA7B/ugUTBgEFAwZfBRsAAgQBBgEFDAZsBRkGAQUHBp8FDMcFEgYBBRk8BQxmBRgGUAUQBgEFGEoGCCAFEAYBBRhKBRoGAwuCBRcGAQUaBpAFFwYBBQEGA7J+rAYBBQMGAw3IBQ4GAQUBA3NKBSAAAgQBAw0uBQEDc0oFIAACBAEDDTwFDQMJWAUBA2pKBSAAAgQBAw08BQMGAwk8BQUGAQUDBgMM8gUKAwsBBQ8GAQUKPII8BQcGA0yQBSkGAQUySgULPgUDBjwGZgUKBgMyAQYBWAUFBkAFFwYBBQYGA7V/SgUDFwUFBgEFQwACBAFYBSkAAgQBPAACBAFYBRUDxgABBQUGA79/SgUHBhY4BlwFCwZfZgUHBhAFKQYBBTJKBQtMBQMGPAZmBRoGAzwBBRAGAQUXPAUaZgUFBnUFBgOufwEFAxcFBQYBBUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBqVYBRoGAzwBBRcGAQUBA8MAdFggBQUGA6F/ZgUTBgEFAwZtBRMGA3kBBS4AAgQBNQUbAAIEAUoFDAZeBRkGAQUHBnUFDMcFEgYBBRk8BQxmBQoGTwUPBgEFCjwGCC4FDwYBBQo8BRoGAwqCBRcGAQUBBgPHAAhKBgEFAwYDDboFFQACBAEGAQUBA3N0BRUAAgQBAw08BQEDczwFDQMPPAUVAAIEAUgFAwZMBRwGEwUFOwZLBRwGAQUFAAIEAVoFAYNYIAUFAAIEAR8GkAUcBgFYBQEGA/oFPAYBBQMGhhMTGQUSBhoFFQN4SgUDBoQFBQYBBQgGUAUKBlgFCAaXBQoGAQUHqgUKggU5Aw08BQUGZgUoBgEFFgACBAMG1QURAAIEAQEAAgQBBkoFAwZrBR4GAQUDSjwFAZFmBQoDblgFBzwFCQNs8koFBgYDx3wIPAYBBQMGAwkIShMFBgYDdgEFLQMKZgUDBpEFBQO5fgEFAxgTBRIGAQU3SgUOLwU3SQUIdAUDBj0FBgYBBS0AAgQCA74BugUuAAIEAQPCflgFBQZ1BRMGATwFCtYFAwY9BRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUrAAIEAQMP5AUJA3E8BSsAAgQBAw88BQkDcYIFAwZZAw4BBSsAAgQBBgEFAwaDBQoBBQUDE+QFEwYBBQMGkgUFBgEFFAaVBREGAUoFDD08rGYFAwYDC1gFBQYBBSKYBQMGZgUeBgEFBS6QBQMGAwx0AxMBBQUGAQUMBgMTngaQBQ8DWpAFAwYD830IEgUYBgFKBQMGA74BARYTBSgGA71+AXQFCQPDAQEFLQACBAIDeeQFKwACBAIDFlgFCQNxZgUDBoMDDgETBQoBBSgGAwmQBQUDaHQFKAMYPAUFBoATBTcGAQURZgU3SgUbLgUeCEwFFToFBQY+BgEFCgYDdgEFBQYDDlgFAwZKBQUGAQUDBpcFBQYBBTkAAgQBkAU0AAIEATwFOQACBAE8BTQAAgQBPAUpAAIEAS4FCAaKBQoGAQUDBgMRngUFBgEGlQUTBgEFAwZ7BRQAAgQBBhMAAgQBwgURAxqQBRMAAgQBA3pKBRHABQcGuwUUxwYBSgUMBjEFBwOhewhKBSkGAQUySgULPgUDBjwGZgUMBgPdBAEGWAUFBkEFBgOJe0oFAxcFBQYBBUMAAgQBggUpAAIEATwFB10FFQPtBGYFBQYDk3s8BQcGFjgGMgULBl8FAwY8BmYFDAYD3QQBBRIDC1gGAQUHBgOWe6wFKQYBBTJKBQtMBQMGPAZmBRIGA+gEAQZKLgUFBj0FBgOCewEFAxcFBQYBBUMAAgQBggUpAAIEATwFBQZdBQcGAWo4BjIFCwalBQMGPAZmBRIGA+gEAQZKBQEwWAUDBgP9fsgFBQO5fgEFAxgTBRIGAQU3SgUOLwU3SQUIdAUDBj0FBgYBBS0AAgQBA74BggACBAFYBQgGAzTkBQoGAQUDBgMRngU5AAIEAQYDZwEFBQMZZgaVBRMGAQUDBnsGAQYD832CBRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUtAAIEAQN55AUrAAIEAQMWWAUJA3FmBQMGgwMOAQUFBgMWrAUSAAIEAQMRPAUFBpYFBwYBBQpKBSI+BQc6BQMGPgUiBgEFHjwFBS6QBkEFEwYBBQMGewYTBRQAAgQBpgUXkQUDdAUUBrIFDAYTPPIFAwZMBQ8GA20BBRkAAgQBA2OsBQMGAxG6BTkAAgQBBgNnAQUeAxlmBQUuBQMGAwy6AxMBBQwDE4IFBQNh8gULBgEFAwZMBQUGAQYDEJAFCgYBBQUGPQUHBgEFCkoFAwZNBQwDCQEFDwYDC7pKggUDBgNPdAMTAQUUAAIEAQYBBQ8DbZAFFAACBAEDE2YFBQY0BQoGAQUFBj0FBwYBBQ8DZkoFCgMaZgUDBk0FFANDdAURBgE8BQUGAwpYBQoGAQUHPEpYBRcDIFgFA3QFFAayBQwGEwUUAAIEAQgwBQMGngUUAAIEAQYBBQUGbAUKBgEFBQY9BQoGAQUHZgUKSgUDBk0FFAACBAEGA2xYBQMGAwpYBQUYBQoGAQUFBj0FBwYBBQpKBQMGTQUXBgNtWAUDdAUGBgPtffIGAQUDBghSBQUDagEFAxgTBTcGAQUSLgUOSwU3OwUGewUIA3k8BQMGPQUGBgEFLgACBAGCBQMGrgUYBgE8BQMGAxABExMUBSgGA2wBWAUJAxQBBQMGCGcTBQUGAQYDLGYFBwYBBgMLkAUVBgEFCAZ2BpAFJAACBAGkBTtrBSQAAgQBmQUFBp4FCAYBBRIAAgQBWAU8AAIEAlgFEHUFCZAGaAUOBgEFC0oFBQa8BTsGAQUHPAU7SgUQCDwFBQZnBQgDdAEFAwMQ5AUFBgEFLFkFJzwFLDwFJzwFAzwFGAaVBQwGE9Y8BQVaBQMGZgUSAAIEAQYBBQMGzwUFBgEFMwACBAFKBS4AAgQBZgACBAEuBRsAAgQBPAUFBk8FBwYBBQUGwAUHBgEFCgYDCZAFDAYBBQMGAwoISgUFBgEGogUKBgEFB1gFDAYDDkoGWAUHBgO1fIIFKQYBBTJKBQs+BQMGPAZmBQwGA8kDAQUOBgOnfFg8BQUGA94DAQUGA518SgUDFwUFBgEFQwACBAGCBSkAAgQBPAUHXQUVA9kDZgUFBgOnfDwFBwYWOAYyBQsGXwUDBjwGZgUMBgPJAwEFGl8FEAYBBQcGA658rAUpBgEFMkoFC0wFAwZmBmYFGgYD0AMBBRAGAQUXLgUaZgUFBlIFBgOTfAEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBqXWBQED2QMBWCA8Li4uIAUIBgNkggUKBgEFBQaGBQoGAQUHWEoFCAbmBQoGPAUFBqIFCgYBBQdYSgUFBgPifp4FEwYBLgUK1i7WBQMGA+kAAQUFBgEGvwUKBgEFBzxKBgNayAUIGgUhBgN4ATwFBwYDMcgFFAYBBQUGaAUHBgEFGZEFBXQFHgaxBRQGAQUbPAUeZgUOgwgSWAUeBvoFFAYBBRs8BR5mBQkG5QUexwUUBgEFGzwFHmYFDU6CBQMGA1LWBQUGAQUTPQUFO9YFAQYDqQO6BgEFAwbpBQUGAQUBRQUFQQUNAxlmBQMGSgUFBgEFE5gFAwN5SgUFBkMFDgEFEwYBSkoFEIoFBUYFE34FLQACBAEGWAUFFhYFEAYBBQcAAgQBggUUBocGATwFBwYDmXm6BSkGAQUySgULPgUDBjwGZgUUBgPlBgEGAQUJBlkFDgYDinkBBRsD9gY8BQYGA4V5SgUDFwUFBgEFQwACBAFYBSkAAgQBPAACBAFYBRkD9gYBBQUGA495SgUHBhY4BlwFCwaJBQMGPAZmBRQGA+UGAQYBWDwFAQMOAUouBQUGuQUBBtdKBQUGA0nWBQ4BBR0BBQUWhgYOBSFOBRAAAgQBWAUHAAIEAghKBk4FFQYBBQUGhwUTBgHWBQcGAx8BBsisBQ0DZAEFAQYD7wCCBgEFAwbpBQ8GGAUBA3VKBQW/BpYFBwYBBlwFNgACBAEGAxIBBRUDbkoFAwYDEjwFHAACBAEGAQUFBgMKggUTBgEFAwYDClgFBwYTBQUGgwUSBgEFAwZoBQYGAQUPAAIEAUoFAwYDDcgFBQYBBRsAAgQBSgUuAAIEApAFJAACBAI8BQUGuwUSBgEFAwZrBQUGAQUbAAIEAUoFBwYDSJ4FFQYBBQMGAw2CBQUDDwEFAxcFDwACBAEGFgUDBgMTrBgFBQYBBRKWBQgGPAUKBgEFCAaWBQoGAQUFBlwFAwgzBQ8GAQUFPAUXSwUDkAbABQUGAQbABQcTBRcGAQUHAAIEAjxYBSYAAgQBSgUHAAIEAUoAAgQEPAaDEwUKBgE8BRQAAgQBLgU+AAIEAmYFC8kFCQZ1BR4GAQUJSgUDBgMPCCAFDgYBBQU8BR8AAgQBSgUeBgMVngUbBgEFAWhYSgUIBgP4foIFCgYBBQUGhwU2AAIEAQYXBRJFBQMGQQUcAAIEAQYBAAIEAYIFAwYDFHQWAxMBGAUFBgEGCCQDMwh0BQOIBQUDD4IFFQYBBQUAAgQCPFgFJAACBAFKBQUAAgQBSgACBAQ8BR4GgQUQBgEFGzwFHmYFAUxYLi4FBQYDY3QFA84FDgYBBQU8BoMFA4gFBQYBBQtQBQUGPAUXBgEFBQaRBQgBBRUAAgQByQACBAEGAQACBAE8BQUGA7B/ggUSBgEFAwZrBQUGAQUbAAIEAYIFHAbJBRkGAQUHBskFHMcFEgYBBRk8BRxmBQUGAw+eBRwDDQh0BRkGAQUHBoMFHMcFEgYBBRk8BRxmBTkAAgQCA1CeBQcGCBQFHQYBBRfJBR0tBQcGSwUXAQZKLgULBtgFEwEFIAYBBRc6BSBMBRcGOgACBAEGZgACBAHyBQMGAxABBRsAAgQBBgEFHAaRBRkGAeQFAwYDaIIWBQ4GAw0BBQ8AAgQBA3NYBTkAAgQCngU1AAIEAQh/BSMAAgQBPAUDBpMFBgYBBQ8AAgQBggUDBgNougUFBgEFNgACBAFmBRwAAgQBSgUFBgMKggUTBgEFAwYDCmYFIwACBAEGEwACBAHyAAIEAXQFHwACBAED0gABBQMGpQUFBgEFAQYDFAhmBgEFAwbNEwUgAQUHBhEFP2cFAQN6SgU/bAUDBkAFFAEFDQYBSnQFFEo8BQUGZwUNBhEFDmcFFAZJBQ0GAQUUrC4FAwZRBQ0GAQUGPAUFBlkFFAYBBQMGuwUFBgEFDUMFAwMLSgUFA248BSJRBQUDeTwFAwY1BRMGEwUDAwrIBRMDdmYFAwMKPAZmXgUJBhMFFTsFA0EFFTcFAwY9BREGAQUDMgUROAUDXAUROAUDBkADCVgFHgYBBRFKBQMGUAUBBmdYLgUDH1gFAQYACQJwQgBAAQAAAAOJAgEGASAFAwazBRUBBQMXBQ0GAQUBA3RKBQUDDFgFC10FAwZKBQcDp3oBBQMXBQoGAUpKulhYBQ4D1gUBBQoDqnpKPAUDBgPWBQEFBQYBBgMJkAUD2gUBBpFYIAUFBgNsdAUXBgEFBQYDCvIFAwMJ1gUBBpFYIAYD2308BgEgBQMGswUVAQUDFwUNBgEFAQN0SgUFAwxYBlkFFwYBBQMGzAUHA7R8AQUDFwUKBgFKSrpYWAUOA8kDAQUKA7d8SjwFAwYDyQMBBQUGAQYDCZDcBRwBBRIGAQUHBgO2dsgFKQYBBTJKBQtMBQMGZgZmBRwGA8gJAQUSBgEFGS4FHGYFBwZLBQYDonYBBQMXBQ4GAQUFPAVDAAIEAVgFKQACBAE8BQUGXQUHBhY4BlwFCwal1gUFBgO9CQEFAwMR1gUBBpFYIAYDgAI8BgEgBQMGwgUVAQUDFwUNBgEFAQNzSgUFAw1YBQgGlQUKBgEFAwZrBQcD/HkBBQMXBQoGAUpKulhYBQ4DgQYBBQoD/3k8PAUDBgOBBgEFBQYBBQgGwAUYBho8BQoDeFgFLgACBAFYBRoAAgQBPAUFBlIFBwYBBokFGQYBBQUGAxNYBQcIlwUcxwUFAQUcAQUSBgEFGTwFHGYFBQYDC54FBwYBBgMQSgUbBgEFKwACBAGCAAIEATwFBQZABQMIFwUBBpFYIAUHBgNuZgUYBgEFBQYDuX+CBRcGAQUFBghvBRcGAQUFBgMPCHQG1gUHBgMZLgUhBgEFMQACBAGCBR8AAgQBLgUJAAIEATwFEWwFBzwFCQaDBRcGAQUGBgMyCCAGAQUDBgg0EwUgAQUDFAUOBgMQAQUGA2dKBSsAAgQBAwmCBQUG3gUkBgEFAwZSBQUGAQUDBgM0ngUzBgO3AQEFRgACBAIDzn5KBQVTBSsAAgQBAz2QBTgAAgQBA3GsBRwDZDwFOAACBAEDHDwFHANkSgUTAAIEAQMU1gUgAAIEAlgFTQACBAK0BQ4AAgQEPAULAAIEBC4FBwZQBSYGAUoFZAACBAYGA1EBBWAAAgQFAQACBAUGPAUHBmoFEAYBBQcGZwUJBgEFDAYDE5AFFgYBBQ48BQkGUQUaBgEFKwACBAEDGWYFBwYDaTwFCQYBBlIFDgYBBSAAAgQBWAUnAAIEATwAAgQBPAACBAG6BQUGA61/ARkFOgYBBS5YBSQDeVgFOkMFNDwFLjwFBQY9BQcGATwGAw9mBTAGGgUmA3lYSQUHBksFBRkFMAYBBTMDvQE8BSoDw35KBSQ8BQMGbAVGAAIEAQYXBWAAAgQFBkoAAgQFBoIFAwYDRwEFBQYBBgMPnhkFOgYBBS5YBTqsBTQ8BS48BQUGPQUHGAUFAxEBBTAGAQUmA29YBTADETwFKjwFJDw8BQMGQgUFBgEFJgACBAFYBQMGAzhYBSsAAgQBBhcFBQZKBkoFIQACBAE8BQcGkQUMBgEFCUoFBQZMBQ0GFQUKRwUHPAUDBk0FBQZmBQMGAzyQBQUGAQUIBqQFCgYBBQgGzgUKBgEFAwYDCZ7JBSgGAQUDPAUoPAUDPAaHBQ4GAQUFPAUbAAIEAUoFHAZnBRkGAQUHBskFHMcFEgYBBRk8BRxmBQwGTwUJBgPaeAEFDAOmB0pYBQcGA9h4WBMFGAYBBRBKBQpKkAUMBgOnBwEFBZEFBgPKeIIFAxcFBQYBBQgGlgULBgEFBQYDCVgGgoIFCQYDkgYBBQsGAQUJWQU4AAIEAVgFLgACBAE8BQsGswUQBgEFDTxKBSAAAgQCAw1YBQ4AAgQEUgUHBkIGAQVkAAIEBgYDUQEFYAACBAUBBQsAAgQEBgMpAQACBARYBQMGAwoBBQUGAQUDBgMLkAUNBgEFBZ4GAw2QBQ8GGgUXA3g8BQk9BRcDDkoDcUoFBQY9GQURBhMFNQACBAFrBRE3BQUGTwU1AAIEAQYBBQ8AAgQEZgUFBmcFKQEFFwYBBQ8AAgQEnQUXPQUpSjwFBwZsBRcGA3oBBRBsBQcGSwUpA3kBBRcGAQUp1i4FEF8FEQPNAJ4FBQYDtn9KBQcGAQaVBRUGAQUHBkAFCQYBBSAGyQUdBgEFCwafBSDHBRYGAQUdPAUgZgUNAwxKBQMGSgUFBgEGCCQDJAh0BR7HBRAGAQUbPAUeZgUDBlAFKAYBBQM8BSg8BQM8BokFEQYBBQMGSwYWBRFiBQMGdhMTBQEGE1ggBQOBBQUGA7141gY8WAUJBocGrFiCggUVA/QGZp4FBQYDGwEFAwP3fgh0BSYAAgQBBgEFRgACBALbAAIEAp4FMwOyAQEFJgACBAEDyX7yBQUGA48B8gUHA5d/CHQFCQYBCHQFBQYDFwEFBwYBBQMG7QUrAAIEAQYXBQUGSgUrAAIEAQYBAAIEAZ4FAQYDjAIIIAYBCJ4FAwblEwUVBgEFC2AFDwN6ZgUHAAIEAQgsBQMGMAUgAAIEAQYDFwEFDwNpSgUcAAIEAQMXngUPA2k8BRwAAgQBAxd0BQ8DaS4FJAACBAEGAxcIrAACBAEGAQUMAxaCBQkDEkoFDANuyHQFBwYDvAYBBQYDqmkBBQMXBQ4GAQVDAAIEATwFBTwFKQACBAFYBQUGXQUHBhZGBgMJWAUpBgEFMjwFAwZMBmYFHAACBAED7w8BBSQAAgQBBkoFIAACBAEGAQUaAAIEAUoFJAACBAE8BQUGiQUHBgEGXBMTFxYDDQEFDgYVBRRHBQcGPQUUBgEFBwaEBQ4BBQwGA3CCBSAAAgQBA2pKBRoDDTw7BQkGAxwuBRkGPAUTSgUJPAhKBQcGA+JvAQaCggUNBgOLFgEFNQACBAEGAQUPBghMBREGAQUXhgUPBgMJWAURBgEGXAUVBgEFEzwGAw6CBS0GAQU2PAURA7J9rAUZA8B8SgUOBjoGkAUQA74GAQUDBjwFAQYTugUNBgOteggSBRoGAQUJBnsFCwYBBRQGpQUWBgEFDwYDDZ4FKwYBBQ8GPQURBjwFFAZsBSsAAgQBBgN5AQUpAAIEAQNxCBIFDQYDIEoFDwYBBgMKkAa6BREDoALkBRQDFkoFGQOqfGYFEwPXAzxYBQ0GA9R9WAUaBgEFDQZ7BToGA5B/AQUPA/AASgUUBqMFOgYDi38BBRYD9QA8BQ8GbhMFEQYBBRQGowVABhZKBQkGhwUNFgZLBRkDrX48BQ0D0gE8BlleBQ8GAQUpAAIEAUoFDQYDDpAGFAU2OgUNBksTBTYGjgUZA5l+PAUNA+kBPAZZA9YBWAURBgEFD0oFGQPAfJAFFgPMAzwFE2hYBQ0GA5J9WAUdBgEFGQOgfzwFHQPgADwFDQACBAFYBR1KBQ0AAgQBPAZZA7UCWAUfBgPHfQEFLwO9AjwFD0YFEgakBRQGAQUSBqQFFAYBBRIGbAUUBgEFDwYDCp4FJgACBAEGAQUNBgPzAHQFEQYBBQ9KBRkD23uQBRYDsQQ8BRNoWAUPBgO0f1gFFwYBBRFKBQ8GmAURBgEFIwACBAGQBQ8GA6kCnhTbBQ0DnX6CBREGA4R/AQUaA/wASgUNBksTBRkGA8J7AQUTA70EPAUNWQYDvn5YBRoGAQUfA+F9PAUaA58CPAUNBgMJZgUPBgEGhgYBBQYGA6d7dAUDFxMWBAIFHAPGcgEFBRUTFBMFIgYTBS47BSJ1BS5JBSJLBQ1zBQUGPQUIBgEFBQY9BRcGATwFFC4FHTwFDTwFBQYvEwUNBhEEAQUFAAIEAQOwDXQGlwUHBgEFBQajBAIFHAOhcQEFBRQTExMTBQgGAVgFCgZuBQcTBRsGEwQBBQkGA+wO8gUkBgEFBwaHBlgFDQYDyQEBBhcFHkUFDQZ4BToGAw0BBQ8Dc3QGAw2QBSoAAgQBBgEFDwY9BkoFOtUFGQO+fzw8BQ0GA9EAWAUSBhMFHwMLSgU6A2U8BQ8DD0oGAwyQAAIEAQYBBR9KBRkDo388BQ8AAgQBA90APAACBAFYBQ0GA/EBWAUaBgEFHwOPfjwFGgPxATwFDAYDGmYFDgYBBQ8GhgACBAEGAQACBAFmBToD1n0ISgUZA75/SjwFDQYDoQJYBRoGAQUfA7x+PAUaA8QBPAUNBgMZZgUPBgEGhgACBAEGAQACBAFmAAIEAboFDQYDtH8uBRoGAQUfA+t+PAUaA5UBPAUNBgMbZgUPBgEGhgACBAEGAQACBAFmAAIEAboFDQYDwgMuBQ8GAQaDBREGA+x9AQUcA5QCSgUZA6x6SgUNBgO1BYIFDwYBBoMFEQYDin4BBRwD9gFKBRkDynp0BQ0GA9cEggUPBgEFEQPpfpAFFQPSAUoFGQPuelgFDQYD3QWCBQ8GAQaGBREGA999AQUcA6ECSgUPBnUFGQYDnnoBBQ8D4gU8BRMDiHtYBQ0GA5sCPAUfBgPYfQEFDwOoAjwGAwmCBQYD4HsBBQMXExYEAgUcA+BxAQUFFRMUExMFDwY9LgUHZQUNPQUHLQUFBnUFEwYBBQc8BQUGPRMGAQQBAAIEAQOVDgEFGeAFBQYDC54FBwZKBlkFFQYBBQUGXAQCBRwD/XABBQUUExQTEwUZBgEFBz0FGXMFBQZZExQUBQcTBRoGAcg8umYEAQUHBgP6DgEFEwYDdgEFBwMKZkq6rAUNBgOoAQEFHgYBBQ0GeAUPUAUhAAIEAQYBBQ89SgUrjwUZA0U8BSEAAgQBAzs8BQ8GSwZYBRMDLlgFDQYDowE8BR8GA9B+AQUPA7ABPAYDCoIAAgQBBgEAAgQB5AACBAGCBRMD035YBQ0GA9ABPAUfBgOjfgEFDwPdATwGAwqCAAIEAQYBAAIEAeQAAgQBggUTA6Z+WAUMBgP+ATwFHwYD9X0BBQ4DiwI8BQ8GAwqCAAIEAQYBAAIEAeQAAgQBggUNBgOgfVgFGQYDbpAFDQMSPAZdBQ8DpwVYBRIGAQURhgbiBR4GAQURBnUFGgEFKQEFEROtBS0GAQUcAAIEAVgFFAACBAIIZgUVBuUFKgYBBREGgwUOBgO5egEFKgPHBUoFGQO7ejwFDQYD8wSCBQ8GAQUNkQUPBr8FIgYBBSAAAgQBdAURAAIEATwDx36CBSIDuQFKBRkDh3s8BRgDlwU8PAUNBgMUWAUPBgEGgwURBgOUfgEFHAPsAUoFGQPUenQFDQYDogWCBQ8GAQaDBREGA51+AQUcA+MBSgUZA916dAUHBgOPf4IXBSsGAQUJrAYIFAUrBgEFDUpYBQkGPQUkBgEFCQY9BSQGAS4FBwYVBQkDEQEFJAYBBQcGaxcFIgYNBQd5BQGTWEoFDwYDngEBBSEGAQUGBgOacTwFAwMPAQUVAAIEAQYBBQMG2AUNBgEFBTwGgwUdBgE8BQUAAgQBggACBAFKAAIEAZ4FIQPUDgEFGQOpfzw8BQ0GA+0FWAUPBgEFFAbeBRcGF6wFBQYD/3hYBghmBREDxwQBBRgD1wFKBRkD6Xo8BRUDkgU8WAUHBgO/eVgTBQkYBgguBRkDqAEBBRgD/QM8BRVoWAUHBgPDelgFFQYBngUPBgOiAwEFHAYBBSAvBRxzBQ8GZwUHA7Z9WAUJBgEFCgMRkC50BREGA5gCAQVABgEFDwYD6AGQBTQAAgQBBgEFEwYD2gKCBSMGAQURA7p9PAUZA8B8SgUjA4YGPAUPBgPXfoIFEQYD434BBSADnQFKBQ8GdRMFGQYDoXsBBRoD3gQ8BRVLBQ8GA5d8ngUrBgEFDwYDzwKCEwUqAAIEAQYDIQEFFgNfSgUPZQUTAwlKWAUPBgNMWAUnAAIEAQYBBQUGA+tudAUdBgEFBQACBAGCAAIEAUoAAgQBngACBAFYBQ8GA5YPAQZ0WAYDG1gFOAYBPAUjAAIEAQOxAlgFEQajEwUOBgORfAEFGAPuA0oFFWcDEkoDblgFDwYDPVgTBSoAAgQBBgO8fwEFFgPEAEoFD2UFEwMJSlgFCQYD7npYBoKCBQ8GA/8DAQUoAAIEAQYBBQ8GA919ggUrAAIEAQYBBREGA4AEggUTBgEGTwUgBgEFEwZ1BSIGAQURBgPxfoITBQ4GA4l8AQUYA/YDSgUVZwMKSgN2WAUTBgOVAVgFEQYDtn4BBSIDuQFKBRkDh3s8BRgDlwU8BSQDczwFEQO2fnRYBQcGA4t7WAUTBgN2AQUHAwo8SgUTA3Z0BQcDCmZYAgUAAQFjJAAABQAIAG0AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8E9RQAAPwUAAAyFQAAUhUAAAIBHwIPDZEVAAABohUAAAGyFQAAArkVAAACwhUAAALMFQAAAtUVAAAC3RUAAALmFQAAAu4VAAAD9hUAAAL/FQAAAggWAAAABQEACQIgVABAAQAAAAOEAwEGAQUDBrAFAQYOBQ5ABQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGAwlYBSkGAQUySgUpWAUDBj4FAQZnWAUHBgN4PAY8BQuJBQMGPAUBBmdYBngGAQUDBgM8CBIUBQ4GAQUBA0JKBSAAAgQBAz4uBQEDQkoFIAACBAEDPjwFKVsFAQO/f0oFDwPFADxKBSAAAgQBA3kBBQMGPwUFBgEFAwYDFcgFBQYBBQMGvwUSGgUcBgMPCFgFBwZJBhMFCWUFBwY9BlgFEgYDcQEFB0wTBQsGFQUHOQaDPRMFCwYBAAIEAViQAAIEATwFBwZZBQoGAQUHBloFCgYBBQkGMBMFEAYBBQtJBQ5ZZgUFBgNoAQUTBgEFAwZABRsAAgQBBgEFDAZZBRkGAQUHBoMFDMcFEgYBBRk8BQxmBQUGAxueBRrHBQMBBRoBBRAGAQUXPAUaZgUBTlggIOQFBQYDSfIUBS0GFQUHOQZaBQ8GEwUJgQZZBQ8GAQUFBsIFBwYBBksFFQYBBQUGPQUTBgEFBQZ1BQEGAycBWCAgBQcGA1RmBQ0GAQggBQkGKgUPBgG6BQEGA8AGSgYBBQMGhhMTGQUSBhoFFQN4SgUDBoQFBQYBBQgGUAUKBlgFCAaXBQoGAQUHqgUKggU5Aw08BQUGZgUoBgEFFgACBAMG1QURAAIEAQEAAgQBBkoFAwZrBR4GAQUDSjwFAZFmBQoDblgFBzwFCQNs8koFAQYDnX8IPAYBBQMGvwUFBgEFAUUFBUEFDQMZLgUDBkoFBAYYBQUDejwGAyJYBQEGWQUFcwYDSqwFDgEFHQEFBRaGBg4FIU4FEAACBAFYBQcAAgQCCEoGTgUVBgEFBQaHBRMGAWYFDRUFAQYDs3ryBgEFAwYDDboFFQACBAEGAQUBA3N0BRUAAgQBAw08BQEDczwFDQMPPAUVAAIEAUgFAwZMBRwGEwUFOwZLBRwGAQUFAAIEAVoFAYNYIAUFAAIEAR8GkAUcBgFYBQEGA5YEPAYBIAUDBnkFCgEFHgEFAxMTBQEGA3kBBRoGA1dmBQMUExQDHwEEAgUIBgPeegEEAQUBA6cFPAUKN3Q8BQMGAw4BBAIFHAPKegEFBRQTExMTBQgGAQUJBoQGPAZLBQwGAS4FDgZoBREGAYIEAQUHBgPEBQETBQoGAxABBQcAAgQEA17kBSEAAgQBAx48BQkAAgQEZgUDBmoFCgYBCDyQBQHlBAIFCgYDrXqQBQ0GAQUHBoMFHQYBPAUbn0oEAQUHAAIEBAOuBQEFAwYDHnQFBwACBAQGA2IBBSEAAgQCAx4uAAIEAi4AAgQCugACBAJKAAIEAroAAgQCngUDBgEGZlgFAQYDwHusBgEFAwYDPuQUBQ4GAQUBA0BKBSAAAgQBA8AALgUBA0BKBSAAAgQBA8AAPAUpWwUBA71/SgUPA8cAPEoFIAACBAEDeQEFAwY/BQUGAQUDBgMVyAUFBgEFAwa/BRMXBQwGAQUTSgUBA55/gi5KBQcGA+R+ZgUpBgEFMkoFKVgFAwY+BRMGA/wBPAUDA4R+SjwFEwYD/AEBBgEFFgACBAHIBRMAAgQBSgUHBpIFBgPtfQEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBomCBQUGA/MBAQUTBgEFAwZ4BRsAAgQBBgEFDAaRBRkGAQUHBoMFDMcFEgYBBRk8BQxmBRMGTgUMBgEFE0oFBwYDgn4IIAUpBgEFMkoFKawFAwY+BmYFGgYDgQIBBRAGAQUXPAUaZgUFBksFBgPpfQEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBs9mBQUGA98BARQFLQYVBQc5BloFDwYTBQmBBlkFDwYBBQUGwgUHBgEGSwUVBgEFBQY9BRMGAQUFBnUGAQUBAxYBWAUTBgN3ugUMBgEFE0oFGgaHBRcGAQUHBgNpZgUNBgEIIAUJBioFDwYBui4FGgYDGwEFFwYBBQEGA74FugYBBQMG6QUPBhgFAQN1SgUFvwaWBQcGAQZcBTYAAgQBBgMSAQUVA25KBQMGAxI8BRwAAgQBBgEFBQYDCoIFEwYBBQMGAwpYBQcGEwUFBoMFEgYBBQMGaAUGBgEFDwACBAFKBQMGAw3IBQUGAQUbAAIEAUoFLgACBAKQBSQAAgQCPAUFBrsFEgYBBQMGawUFBgEFGwACBAFKBQcGA0ieBRUGAQUDBgMNggUFAw8BBQMXBQ8AAgQBBhYFAwYDE6wYBQUGAQUSlgUIBjwFCgYBBQgGlgUKBgEFBQZcBQMIMwUPBgEFBTwFF0sFA5AGwAUFBgEGwAUHEwUXBgEFBwACBAI8WAUmAAIEAUoFBwACBAFKAAIEBDwGgxMFCgYBPAUUAAIEAS4FPgACBAJmBQvJBQkGdQUeBgEFCUoFAwYDDwggBQ4GAQUFPAUfAAIEAUoFHgYDFZ4FGwYBBQFoWEoFCAYD+H6CBQoGAQUFBocFNgACBAEGFwUSRQUDBkEFHAACBAEGAQACBAGCBQMGAxR0FgMTARgFBQYBBggkAzMIdAUDiAUFAw+CBRUGAQUFAAIEAjxYBSQAAgQBSgUFAAIEAUoAAgQEPAUeBoEFEAYBBRs8BR5mBQFMWC4uBQUGA2N0BQPOBQ4GAQUFPAaDBQOIBQUGAQULUAUFBjwFFwYBBQUGkQUIAQUVAAIEAckAAgQBBgEAAgQBPAUFBgOwf4IFEgYBBQMGawUFBgEFGwACBAGCBRwGyQUZBgEFBwbJBRzHBRIGAQUZPAUcZgUFBgMPngUcAw0IdAUZBgEFBwaDBRzHBRIGAQUZPAUcZgU5AAIEAgNQngUHBggUBR0GAQUXyQUdLQUHBksFFwEGSi4FCwbYBRMBBSAGAQUXOgUgTAUXBjoAAgQBBmYAAgQB8gUDBgMQAQUbAAIEAQYBBRwGkQUZBgHkBQMGA2iCFgUOBgMNAQUPAAIEAQNzWAU5AAIEAp4FNQACBAEIfwUjAAIEATwFAwaTBQYGAQUPAAIEAYIFAwYDaLoFBQYBBTYAAgQBZgUcAAIEAUoFBQYDCoIFEwYBBQMGAwpmBSMAAgQBBhMAAgQB8gACBAF0BR8AAgQBA9IAAQUDBqUFBQYBBQEGA9gACGYGASAFAwazBRUBBQMXBQ0GAQUBA3RKBQUDDFgGWQUXBgEFAwbMBQcDtHwBBQMXBQoGAUpKulhYBQ4DyQMBBQoDt3xKPAUDBgPJAwEFBQYBBgMJkNwFHAEFEgYBBQcGA7Z2yAUpBgEFMkoFKawFAwY+BmYFHAYDyAkBBRIGAQUZLgUcZgUHBksFBgOidgEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBs/kBQUGA70JAQUDAxHWBQEGkVggBQYGA416rAYBBQMGAwkIShMFBgYDdgEFLQMKZgUDBpEFBQO5fgEFAxgTBRIGAQU3SgUOLwU3SQUIdAUDBj0FBgYBBS0AAgQCA74BugUuAAIEAQPCflgFBQZ1BRMGATwFCtYFAwY9BRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUrAAIEAQMP5AUJA3E8BSsAAgQBAw88BQkDcYIFAwZZAw4BBSsAAgQBBgEFAwaDBQoBBQUDE+QFEwYBBQMGkgUFBgEFFAaVBREGAUoFDD08rGYFAwYDC1gFBQYBBSKYBQMGZgUeBgEFBS6QBQMGAwx0AxMBBQUGAQUMBgMTngaQBQ8DWpAFAwYD830IEgUYBgFKBQMGA74BARYTBSgGA71+AXQFCQPDAQEFLQACBAIDeeQFKwACBAIDFlgFCQNxZgUDBoMDDgETBQoBBSgGAwmQBQUDaHQFKAMYPAUFBoATBTcGAQURZgU3SgUbLgUeCEwFFToFBQY+BgEFCgYDdgEFBQYDDlgFAwZKBQUGAQUDBpcFBQYBBTkAAgQBkAU0AAIEATwFOQACBAE8BTQAAgQBPAUpAAIEAS4FCAaKBQoGAQUDBgMRngUFBgEGlQUTBgEFAwZ7BRQAAgQBBhMAAgQBwgURAxqQBRMAAgQBA3pKBRHABQcGuwUUxwYBSgUMBjEFBwOhewhKBSkGAQUySgUpWAUDBj4GZgUMBgPdBAEGWAUFBkEFBgOJe0oFAxcFBQYBBUMAAgQBggUpAAIEATwFB10FFQPtBGYFBQYDk3s8BQcGFjgGMgULBokFAwY8BmYFDAYD3QQBBRIDC1gGAQUHBgOWe9YFKQYBBTJKBSmsBQMGPgZmBRIGA+gEAQZKLgUFBj0FBgOCewEFAxcFBQYBBUMAAgQBggUpAAIEATwFBQZdBQcGAWo4BjIFCwalBQMGPAZmBRIGA+gEAQZKBQEwWAUDBgP9ftYFBQO5fgEFAxgTBRIGAQU3SgUOLwU3SQUIdAUDBj0FBgYBBS0AAgQBA74BggACBAFYBQgGAzTkBQoGAQUDBgMRngU5AAIEAQYDZwEFBQMZZgaVBRMGAQUDBnsGAQYD832CBRgGAUoFAwYDvgEBFhMFKAYDvX4BdAUJA8MBAQUtAAIEAQN55AUrAAIEAQMWWAUJA3FmBQMGgwMOAQUFBgMWrAUSAAIEAQMRPAUFBpYFBwYBBQpKBSI+BQc6BQMGPgUiBgEFHjwFBS6QBkEFEwYBBQMGewYTBRQAAgQBpgUXkQUDdAUUBrIFDAYTPPIFAwZMBQ8GA20BBRkAAgQBA2OsBQMGAxG6BTkAAgQBBgNnAQUeAxlmBQUuBQMGAwy6AxMBBQwDE4IFBQNh8gULBgEFAwZMBQUGAQYDEJAFCgYBBQUGPQUHBgEFCkoFAwZNBQwDCQEFDwYDC7pKggUDBgNPdAMTAQUUAAIEAQYBBQ8DbZAFFAACBAEDE2YFBQY0BQoGAQUFBj0FBwYBBQ8DZkoFCgMaZgUDBk0FFANDdAURBgE8BQUGAwpYBQoGAQUHPEpYBRcDIFgFA3QFFAayBQwGEwUUAAIEAQgwBQMGngUUAAIEAQYBBQUGbAUKBgEFBQY9BQoGAQUHZgUKSgUDBk0FFAACBAEGA2xYBQMGAwpYBQUYBQoGAQUFBj0FBwYBBQpKBQMGTQUXBgNtWAUDdAUGBgPtffIGAQUDBghSBQUDagEFAxgTBTcGAQUSLgUOSwU3OwUGewUIA3k8BQMGPQUGBgEFLgACBAGCBQMGrgUYBgE8BQMGAxABExMUBSgGA2wBWAUJAxQBBQMGCGcTBQUGAQYDLGYFBwYBBgMLkAUVBgEFCAZ2BpAFJAACBAGkBTtrBSQAAgQBmQUFBp4FCAYBBRIAAgQBWAU8AAIEAlgFEHUFCZAGaAUOBgEFC0oFBQa8BTsGAQUHPAU7SgUQCDwFBQZnBQgDdAEFAwMQ5AUFBgEFLFkFJzwFLDwFJzwFAzwFGAaVBQwGE9Y8BQVaBQMGZgUSAAIEAQYBBQMGzwUFBgEFMwACBAFKBS4AAgQBZgACBAEuBRsAAgQBPAUFBk8FBwYBBQUGwAUHBgEFCgYDCZAFDAYBBQMGAwoISgUFBgEGogUKBgEFB1gFDAYDDkoGWAUHBgO1fIIFKQYBBTJKBSlYBQMGPgZmBQwGA8kDAQUOBgOnfFg8BQUGA94DAQUGA518SgUDFwUFBgEFQwACBAGCBSkAAgQBPAUHXQUVA9kDZgUFBgOnfDwFBwYWOAYyBQsGiQUDBjwGZgUMBgPJAwEFGl8FEAYBBQcGA6581gUpBgEFMkoFKawFAwY+BmYFGgYD0AMBBRAGAQUXLgUaZgUFBlIFBgOTfAEFAxcFDgYBBQU8BUMAAgQBWAUpAAIEATwFBQZdBQcGFjgGXAULBs/kBQED2QMBWCA8Li4uIAUIBgNkggUKBgEFBQaGBQoGAQUHWEoFCAbmBQoGPAUFBqIFCgYBBQdYSgUFBgPifp4FEwYBLgUK1i7WBQMGA+kAAQUFBgEGvwUKBgEFBzxKBgNayAUIGgUhBgN4ATwFBwYDMcgFFAYBBQUGaAUHBgEFGZEFBXQFHgaxBRQGAQUbPAUeZgUOgwgSWAUeBvoFFAYBBRs8BR5mBQkG5QUexwUUBgEFGzwFHmYFDU6CBQMGA1LWBQUGAQUTPQUFO9YFBgYDtQm6BgEFAwYINBMFIAEFAxQFDgYDEAEFBgNnSgUrAAIEAQMJggUFBt4FJAYBBQMGUgUFBgEFAwYDNJ4FMwYDtwEBBUYAAgQCA85+SgUFUwUrAAIEAQM9kAU4AAIEAQNxrAUcA2Q8BTgAAgQBAxw8BRwDZEoFEwACBAEDFNYFIAACBAJYBU0AAgQCtAUOAAIEBDwFCwACBAQuBQcGUAUmBgFKBWQAAgQGBgNRAQVgAAIEBQEAAgQFBjwFBwZqBRAGAQUHBmcFCQYBBQwGAxOQBRYGAQUOPAUJBlEFGgYBBSsAAgQBAxlmBQcGA2k8BQkGAQZSBQ4GAQUgAAIEAVgFJwACBAE8AAIEATwAAgQBugUFBgOtfwEZBToGAQUuWAUkA3lYBTpDBTQ8BS48BQUGPQUHBgE8BgMPZgUwBhoFJgN5WEkFBwZLBQUZBTAGAQUzA70BPAUqA8N+SgUkPAUDBmwFRgACBAEGFwVgAAIEBQZKAAIEBQaCBQMGA0cBBQUGAQYDD54ZBToGAQUuWAU6rAU0PAUuPAUFBj0FBxgFBQMRAQUwBgEFJgNvWAUwAxE8BSo8BSQ8PAUDBkIFBQYBBSYAAgQBWAUDBgM4WAUrAAIEAQYXBQUGSgZKBSEAAgQBPAUHBpEFDAYBBQlKBQUGTAUNBhUFCkcFBzwFAwZNBQUGZgUDBgM8kAUFBgEFCAakBQoGAQUIBs4FCgYBBQMGAwmeyQUoBgEFAzwFKDwFAzwGhwUOBgEFBTwFGwACBAFKBRwGZwUZBgEFBwbJBRzHBRIGAQUZPAUcZgUMBk8FCQYD2ngBBQwDpgdKWAUHBgPYeFgTBRgGAQUQSgUKSpAFDAYDpwcBBQWRBQYDyniCBQMXBQUGAQUIBpYFCwYBBQUGAwlYBoKCBQkGA5IGAQULBgEFCVkFOAACBAFYBS4AAgQBPAULBrMFEAYBBQ08SgUgAAIEAgMNWAUOAAIEBFIFBwZCBgEFZAACBAYGA1EBBWAAAgQFAQULAAIEBAYDKQEAAgQEWAUDBgMKAQUFBgEFAwYDC5AFDQYBBQWeBgMNkAUPBhoFFwN4PAUJPQUXAw5KA3FKBQUGPRkFEQYTBTUAAgQBawURNwUFBk8FNQACBAEGAQUPAAIEBGYFBQZnBSkBBRcGAQUPAAIEBJ0FFz0FKUo8BQcGbAUXBgN6AQUQbAUHBksFKQN5AQUXBgEFKdYuBRBfBREDzQCeBQUGA7Z/SgUHBgEGlQUVBgEFBwZABQkGAQUgBskFHQYBBQsGnwUgxwUWBgEFHTwFIGYFDQMMSgUDBkoFBQYBBggkAyQIdAUexwUQBgEFGzwFHmYFAwZQBSgGAQUDPAUoPAUDPAaJBREGAQUDBksGFgURYgUDBnYTEwUBBhNYIAUDgQUFBgO9eNYGPFgFCQaHBqxYgoIFFQP0BmaeBQUGAxsBBQMD934IdAUmAAIEAQYBBUYAAgQC2wACBAKeBTMDsgEBBSYAAgQBA8l+8gUFBgOPAfIFBwOXfwh0BQkGAQh0BQUGAxcBBQcGAQUDBu0FKwACBAEGFwUFBkoFKwACBAEGAQACBAGeBQEGA5p7CCAGAQUDBs0TBSABBQcGEQU/ZwUBA3pKBT9sBQMGQAUUAQUNBgFKdAUUSjwFBQZnBQ0GEQUOZwUUBkkFDQYBBRSsLgUDBlEFDQYBBQY8BQUGWQUUBgEFAwa7BQUGAQUNQwUDAwtKBQUDbjwFIlEFBQN5PAUDBjUFEwYTBQMDCsgFEwN2ZgUDAwo8BmZeBQkGEwUVOwUDQQUVNwUDBj0FEQYBBQMyBRE4BQNcBRE4BQMGQAMJWAUeBgEFEUoFAwZQBQEGZ1guBQMfWAUBBgAJApBtAEABAAAAA4kCAQYBIAUDBrMFFQEFAxcFDQYBBQEDdEoFBQMMWAULXQUDBkoFBwOnegEFAxcFCgYBSkq6WFgFDgPWBQEFCgOqeko8BQMGA9YFAQUFBgEGAwmQBQPaBQEGkVggBQUGA2x0BRcGAQUFBgMK8gUDAwnWBQEGkVggBkAGASAFAwbCBRUBBQMXBQ0GAQUBA3NKBQUDDVgFCAaVBQoGAQUDBmsFBwP8eQEFAxcFCgYBSkq6WFgFDgOBBgEFCgP/eTw8BQMGA4EGAQUFBgEFCAbABRgGGjwFCgN4WAUuAAIEAVgFGgACBAE8BQUGUgUHBgEGiQUZBgEFBQYDE1gFBwiXBRzHBQUBBRwBBRIGAQUZPAUcZgUFBgMLngUHBgEGAxBKBRsGAQUrAAIEAYIAAgQBPAUFBkAFAwgXBQEGkVggBQcGA25mBRgGAQUFBgO5f4IFFwYBBQUGCG8FFwYBBQUGAw8IdAbWBQcGAxkuBSEGAQUxAAIEAYIFHwACBAEuBQkAAgQBPAURbAUHPAUJBoMFFwYBBQEGA8gDCCAGAQieBQMGPRMFAQYQBRWEBQtgBQ8DemYFBwACBAEsBQMGPgUPBgEFIAACBAEDFzwFDwNpSgUaAAIEAQMXCDwFDwNpPAUDBgMUAicBBSQAAgQBFQACBAEGAQUJAyiCBRIDVUoFDAMZLgUJAxJKCC4FIAACBAEDWAEFJAACBAEGPAUgAAIEAQYBBSQAAgQBSgUFBlEFBwYBBgPNBlgFHAACBAEGA6x5AQUKA9QGPAUeWTwFBwYDtnlYExMXFhUFCgYBBQkGWgU4BhMFCTwFFkkFCQaDBTgGAQVPZgUJPAZZBQcYBQ4GFQUUOQUHBj0FFAYBBQcGhAUOAQZYBSAAAgQBA1oBBQwDFjwFGgN3PDsFCQYDHDwFGQY8BRNKBQk8ZuQFAwYDtQYBBQYGAQUFBloFNAYTBQU8BRJJBQUGgwU0BgEFSzwFBTwFEFwFAwY8BQEGE54FDQYDsH8IPAU1AAIEAQYBBQ8GCGgFEQYBBReUBQ8GAwlmBREGAQZcBRUGAQUTPAYDDoIFLQYBBTY8BREDsn10BRkDwHxYBQ0GA+oArAUaBgEFCQZ7BSsGFwULRQUUBqUFFgYBBQ8GAw2eBSsGAQUPBi8FEQY8BRQGbAUrAAIEAQYDeQEFKQACBAEDcQgSBQ0GAyBKBQ8GAQYDCpAGugURA6ACWAUUAxZYBRkDqnxmBRMD1wM8BQ4GA6d8kAaQBQ0GA60BWAU6BgOXfwEFGgPpAEoFDQZ7BToGA5B/AQUPA/AASgUUBqMFOgYDi38BBRYD9QB0BQ8GbhMFEQYBBRQGowUWBgEFEQZqBUAGAQU4SgUJBk8FWAYBBQ1ABVhGBQ0GhllsBQ8GAQUpAAIEAVgFDwYDC1gFHAYBBSAvBRxzBQ8GZwUNFAU2BgEFDUwFNI8FNoE8BTQAAgQBSgUNBksTWQU2Bg+6BRwAAgQBA/F9AQUJBgM8ngYTBRbxBQkGgwUNWgUPA6cFLgUSBgEFEZQG4gUeBgEFEQZ1BRoBBSkBBRETrQUtBgEFHAACBAFYBRQAAgQCCGYFFQblBSoGAQURBoMFDgYDuXoBBSoDxwVYBRkDu3o8BQ0GA/MEggUPBgEFDVkFEQPMfsgFGAPXAVgFGQPpejwFFQOSBTxmBQ0GAxlYBQ8GAQaRBREGA5R+AQUcA+wBWAUZA9R6dAUNBgO1BYIFDwYBBpEFEQYDin4BBRwD9gFYBRkDynp0BQ0GA9cEggUPBgEFEQPpfp4FFQPSAVgFGQPuemYFDQYD3QWCBQ8GAQUNBgMQkAUPBgEFFAbsBRcGF8gFEwPwelgFDQYDmwI8BR8GA9h9AQUPA6gCdAaGBgE8BQYGA6d7PAUDFxMWBAIFHAPGcgEFBRUTFBMFIgYTBS47BSJ1BS5JBSJLBQ1zBQUGSwUIBgEFBQY9BRcGAQUUZgUdPAUNSgUFBj0TBQ0GEQQBBQUAAgQBA7ANkAalBQcGAQZZBRUGAQUFBlwEAgUcA6FxAQUFFBMTExMFCAYBWAUKBm4FBxMFGwYTBAEFCQYD7A7yBSQGAQUHBl0GAQPOAAEFAZMuBQ0GA/gAAQUeBkoFDQZ4BQ9QBSEAAgQBBgEFD0tKBSEAAgQBjwUPBmcFKwZXBRMDL5AFDQYD0AE8BR8GA6N+AQUPA90BdAaGAAIEAQYBAAIEAWYFOgOEfghKBRMDKJ4FDAYD/gE8BR8GA/V9AQUOA4sCdAUPBoYAAgQBBgEAAgQBZgACBAG6BRMD/n0uBQ0GA6MBPAUfBgPQfgEFDwOwAXQGhgACBAEGAQACBAFmAAIEAboFDQYDwgMuBQ8GAQaRBREGA+x9AQUcA5QCWAUZA6x6SgUNBgOiBYIFDwYBBpEFEQYDnX4BBRwD4wFYBRkD3Xp0BQ0GA8ADggURBgEFD1gFGQPAfJ4FFgPMAzwFE2hmBQ0GA9cAWAURBgEFD1gFGQPbe54FFgOxBDwFE2hmBQ0GA618WAUdBgE8BQ0AAgQBWAUdSgUNAAIEATwGWQO1AlgFHwYDx30BBS8DvQJKBR8Dw31KBQ8DuQI8BRIGpAUUBgEFEgakBRQGAQUSBmwFFAYBBQ8GAwqeBSYAAgQBBgEFDwYDNXQFFwYBBRFYBQ8GpgURBgEFIwACBAGeBQ8GA6kCugULFgYTBROLBRhABQsGgwUPvAUNA51+kAURBgOEfwEFGgP8AFgFDQZLEwUZBgPCewEFEwO9BDwFDWcGA75+WAUaBgEFDQYDtX3WBToGAxEBBR4Db0oFDQZ4BToGAw0BBQ0DdGYFD0kGAw2QBSoAAgQBBgEFDwY9BkoFOtUFDQYDD5AFHwYDDAEFOgNldAUSAxBKBQ9JBgMMkAACBAEGAQACBAFKBR9YBQ0GA8QBkAUaBgEFDQYDLdYFGgYBBQ0GA6R/1gUaBgEFDwYD0gDWAAIEAQYBAAIEAeQAAgQBggYDU1gAAgQBBgEAAgQB5AACBAGCBgP3AFgFBgPgewEFAxcTFgQCBRwD4HEBBQUVExQTEwUPBj0uBQdlBQ09BQctBQUGdQUTBgEFBzwFBQY9EwYBBAEAAgQBA5UOAQUZ4AUFBgMLngUHBkoFBQaVBAIFHAP9cAEFBRQTFBMTBRkGAQUHPQUZcwUFBlkTFBQFBxMFGgYByDyCZgQBBQcGA4APARcFKwYBBQmsBggUBSsGAQUNSlgFCQY9BSQGAQUJBj0FJAYBLgUHBhUFCQMRAQUkBgEFBwZrFwUiBg26BQ8GA8EDAQACBAEGAQACBAHkAAIEAYIAAgQBWAYD5X2CBSEGAQUGBgOacXQFAwMPAQUVAAIEAQYBBQMG2AUNBgEFBTwGSwUdBgFmBQUAAgQBWAACBAFKAAIEAZ4AAgQBWAUPBgPeEwEFEQYD330BBRwDoQJYBQ8GdQUZBgOeegEFDwPiBTwGA/t+WAURBgPjfgEFIAOdAVgFDwZ1EwUZBgOhewEFGgPeBDwFFUsFEwYDpwGsBSMGAQURA7p9PAUZA8B8WAUjA4YGPAUFBgP/a4IFHQYBBQUAAgQBggACBAFKAAIEAZ4AAgQBWAUPBgOxDwEFOAYBBTYAAgQBPAUPBgP0ApATBSoAAgQBBgO8fwEFFgPEAFgFD2UFEwMJSmYFDwYDw3xYBSsGAQUPBgPPAoITBSoAAgQBBgMhAQUWA19YBQ9lBRMDCUpmBSMAAgQBAxlYBREGvxMFDgYDkXwBBRgD7gNYBRVnAxJKA25mBQ8GA61/WAUnAAIEAQYBBQUGA997dAUHCG0FFQYBngUPBgOsBAEFNAACBAEGAQUPBgPNAYIFIgYBggUgAAIEAS4FEQACBAE8A8d+ggUiA7kBWAUZA4d7SgUYA5cFPDwFDwYDhHxYBnRYBQkGA4Z+WAaCggUHBgOwfwETBQkYBvIFGQOoAQEFGAP9AzwFFWhmBQ8GA/58WAUrAAIEAQYBBQ8GA6MCdAUoAAIEAQYBAAIEATwFBwYD+3tYBQkGAQUKAxFYLroFEQYDmAIBBUAGAQU4SgURBgO5A5AFEwYBBl0FIAYBBRMGdQUiBgEFEQYD8X6CEwUOBgOJfAEFGAP2A1gFFWcDCkoDdmYFBwYDlHtYBRMGA3YBBQcDCmZKulgFEwYDgQYBBREGA7Z+AQUkA8oBWAUZA/Z6dAUYA5cFPAUiA2I8BREDx35KZgUHBgOLe1gFEwYDdgEFBwMKPEoFEwN2dAUHAwpmWAIFAAEBCwMAAAUACAA4AAAAAQEB+w4NAAEBAQEAAAABAAABAQEfAlgWAABfFgAAAgEfAg8ElRYAAAGdFgAAAaUWAAABsBYAAAEFAQAJAiB6AEABAAAAAyYBBgEFAgatFBMFPBMFCAYRBTwvBQRWBtoFBQYRLwY7BTwRBQJ3BQwGAS4FAgZZBQUGAQUCBi8FAwYWBQFLBncGAQUCBskUBQcDagEFAhQUEwU8EwUBBgMNAQU8A3NmBQRkBQhZBQQGMQUFBhEvBjsFPBEFAoUFDAYBLgUCBlkFEAYDDQEFBQNzSgUCBi8FDgYDDAEFAwN4PEoFAgYaBRQBBQwGAQUEAAIEATsFFD0FAwaRBQ4GEQUEPQUUBkkFEAYBBQxKBRQuBQIGTAUFBgEFAwZZBQgGAQUCBj0FAQYTPGYFCANpZgUBBgMgggYBBQIGExMFEAYBBQFWBRs+BRA8BRkuBQpJBRlLBQIGyQUBBhcFAg1YBQEGAAkCEHsAQAEAAAAaBgEFAgYISxMUGgUKBhgFBAN6LgUCBkEFAQYDbwEFBQMRZgUCBpIFBgYTBQU7BQIGSwUFBhMFBEwFDSsFCzwFBkoFAgZLEwUGBgEFAgY9BRMGAQUGLgUTPAUEPAUCBrEFBQYBBRFdBQUDcjw+BQkDCTwFCjsFAwaEBQQUBQkGAQUIPgUMOgUHTgUPRgUHSgUEBj0FCgYBBRI9BQYuBQo7BQQGSwUGBgEFBAZnBQ8GAQUKPQUPSQULSgUEBj0FDgACBAEDFAEFA1oFBgYBPAUCBpgFBgYBBQUAAgQBrAUGTgUKOgUDBoYFBBQFCAYUBQksBQw8BQQGSxMFBwYUBQZIBQQGZwUPBgEFCj0FDzsFC0oFBAY9BQ4AAgQBAxQBBQNaEwUMBgEFBzwFAwZLBQYGAQUEA11mPAUCBgMprAUJBgEFAT1mWAUVAAIEAQN6ngUFBmcFFTsGSgUEBloGA1oBBQsDJjwFBANaSgUVAAIEAQN55AUFBoMFFTsGSgUEBloFCwYBBQIGTgUGBgFmBQUAAgQBWAIKAAEB4BEAAAUACABLAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA/0WAAAEFwAAOhcAAAIBHwIPB1oXAAABYhcAAAFqFwAAAXUXAAACfxcAAAGHFwAAApAXAAAABQEACQKQfABAAQAAAAPrAAEGAQUCBgMkCJ4TExMTExMTGhMFAQYDTAEFCQM0PAUBA0w8BRADNAIrAQUCBoMFDgYBLgUCPAUDBgjbBQIDCgEFBgYBBRAGA/J+PAUCFBMTFBMTBQoBBQQGEFkFCi8FAwbXBQUGAQUDBi8FBAYBBQoGOgUCYAUGBgEFFlkFG0oFBkkFAgY9BQkGEwUbcwUFPAUCBkuDBQMTBRAGAQURAAIEAUAFBUYFCEoFEQACBAEGTgACBAEGAQACBAGQAAIEAUoAAgQBggUCBrsFCAYBBQIGnwUHBgEFAwZnBQYGAQUIBscGrAUCBl4FGwYTBQk7BQIGPQQCBQEDrQMBBQIUBAEFFAYD0XwBBAIFCQOvAzyQBAEFGQACBAED0XwBBQIGWgYBBgPsAAETBQwGAQUKAAIEAawFBQACBAFmBQIGhwUFBgEFAgbPBQ0GAQUJuwU9Axk8BQsAAgQBA2ZKBQIGWQUMBhMFCTsFDEw7BRFJBQIGSxMFDAYRBT0DGGYFDANpusgFAgYDFzwFBQYWBRCMBQVcBRAqBRWCBQWGBShGBQmHBQVvBQIGTRQFBQYBBQMGWQULBgEFBggSBQIGTAUFBhMFBEkFAgZZBQUGAQUCBqATBSAGAQUMPAUgLgUMSpA8dAUCBmcFDAYXBQRYBQVhBQMGnwUGBgEFFnQFBjyeBQIGohMFCwYPBQZ4BQVzBQMGTwUGBgFZcwUDBlkFAhQFA2cTEwUGBgFKSAUCA61/8i4FAwYDClgFCgYBS0pmcwUDBmcFAQYDsQQBni4FCgPPe3QFAwYDDKyEBQoGAUv/BQMGZwUKBgEFAQOiBIIFAwYDy3sIugUKBgFLSscFAwZnBQQDlX/IBQsGAQUEBnUTBpAFAwYD8wABnwUGBgEFCYMFBjsFAwY9BgEFCgMuggUCBnsTBQUGAQUGSwUFcwUDBl0FBgYBWXMFAwZZBQIUBQUGAQUDBpYTBQYGATtLZzsFAwY9BQIUBQUGAQUCBrwTBQUGAQUHBpQFGgYBBQp0BQIGCCITFAUEAxICLgEFEAYBZgUULgUQPAUHaQUUcQUEBj0TEwUHBgFYBQapBQIGQgULBgEFBVoFC6oFAgZMBQUGAVg8BQMGWQUJBhOCBQZZBQk7PAUDBi8FBgYBBQQGZwUJBgFYBQIGXQUQBgEFBTwFEHQFBWYFA5IGwAUGBgMfAQUFA2FKBQMGdQUGBgEFAwaDExMTBQQDEAETBQMDCQEFBgYBBQ8AAgQBWAUDBggoBRQGAQUGTAUUOgUOSgUDBskFDwYBWMgFAwY9BQYGAQUDBgMK1gUcBhYFJ3QFIVgFHDwFBn4FF7AFB4RMBRdGBQdOBQQGRgUlBgEFBAZLBQUTEwUSBgEFEIM8BQ4tBQUGSxMFCAYBBRADCQggBQUG/gUJBgEFCGYFBQauBQ4GEwUSA3RKBQdLBRADCkoFBQZLBQQDcgEFBRMFBwYBBQUGSwUSBgEFEEs8BQ47BQUGSxMFCAYBBQUGowUMBgEFCIIFDAPOAGaCBQcGWQUKBgEFDI8FEUoGPAZKBQZeSgY8BgEFDQOPAi4FCwPqfXQFBnsFBwYDu36CBRoGAQUKdAUIA3ouBQp6BRT6SgUEBghKBQgGAQUeSgUGPAUEBj0TBQIDEwEFCwYBBQVaBQuABQIGTAUFBgFYPAUMA2qQA3l0BQ91BQeeBRQAAgQBA1oILgUOAAIEAZAFAwa7BQQGAUoFAwYDH3QFDQYTBQidPAUDBj0FAhYTFAUIBgN4AiIBBQQGA2bWBQsGEwUFc0oFAgYDtgFYBQUGAQUMA/B+PAUFA5ABdAUMA+l+ggUPdQUHngUOAAIEAQOWAcgFAwbYBQYGAXVJWAUDBlkFBgYBBQQGCD0TBQcGAQUhAAIEAWYFEQACBAGCBQ0DtgLWBQYDyX08BQw8BQ0DtwIuBQMGA+B+dBMFBQYBBQhYBQMGPRMFCAYPBQIGA5cBdIMFBQYBBQMGWwUChYMFCQYTBQU7BQlLBQVJBQIGPQUJBgEFAgYvBQUGAQUDBpEFCAYBBQIGPQUJBgEFAgZnBQkGAQUDBgP/fFgFFAYBBQ6CBQMGyQUPBgFYyAUDBj0FBBMTBQ0GAQUEBoMFEwYBBQdYBQQGoAUTBgEFB4IFAwYDM54TExMFDAYQBQIGiQUFBgEFAgYDOqwTExMFBQYBBQMGrQUKBhMFDTsFAwY9BRUGAQUNWAUKSgUNLgUKPAUGPAUkAAIEAYIFKQACBAFmBQQGkgULBgEFGi8FCzsFFy4FDT0FGmYFBi0FBAY9BRoGAQUeAAIEATwFBQN4ugUGAxs8BQUDZjwFBgMaSgUFA2UuBQYDGzwFCT0FAwbGExMFCQYBWAUCBggiBQUGAQUDBrsFFAYBBQaRPgUFKwUDBj0TBQYGAQUDBj0FBgYBBQIGPgUFBgEFAwaRBQYGAQUEBpEFBwYBBQgDCpA8BQQGdAUIBgEFBrwFAgaQBQYGAQUFWQUGSQUCBj0FBQYBBQIGlRMFBQYBBSUAAgQCAxCeBTMAAgQEZgUKaAU4AAIEBDoFPQACBARKBQpMBQQAAgQEOgUCBksTBgEFBTwFB0sFAwbIBQcGAQUKWQUHqwUCBj0FCgYBBQV0BQdLBQMGdAUHBgFYBQIGdQUFBgEFGAMJPAUFA3eCBQIGAwmCBQUGAQUDBgg9BQYGAQUdAAIEAXQFEwACBAHyBRAAAgQC5AUNA6gBgnQFDAOufKwFBAYDDXQFBwYBPAUEBqATBREGEQUEZwUJLQUEPQUGA8gAggUMPAUEBgPVAS4TEwUNBgOjAQEFBAPdfjwFCUkFDQOkAXQFBAPdflgFBQOjf8hJBQZMBQIGA+QAggUNBgObAQE8BQUD5X5mA2SsBQMGAx1KBQYGAQUKSwUEBqwFCgYBBQMG+BMFBgY8BQMGlgYIdAUEBmCEBRkAAgQCBg8FBAYDElgFBwYBBQ4AAgQBkAACBAFKBQgwBQQGAyjIBQYGAwsBBQcDdXRKBQQGAwueBQkGAQUEBlkFBwYBBQQGvAUIBgEFEfQFCKoFBAY9BQcGAQUFBpMFCwYBWasFBQY9BQsGAVgFDwYDqn88BQYGA84APAUPA7J/PAUDBjwFCgYTBQlzBQQGPQUKBgEFCFwFCmIFCAACBAE8BQQGQAUIBgEFDFkFCHMFBAY9BQwGAVgFBAY9BRkGATwFGwACBAGCBQQGuwUbAAIEAQZJBQQ9BloFBwYBBSYAAgQB1gUrAAIEAroFCJEFBQasBQgGAQUFBrwFCAYBBQYGlQULBhMFCXMFBgZLBQUUBQoGAQUFPQUHOwUFBksFAgPtAJCDBQUGAQUDBpEFBgYBBQQGnwUIBgNsgkpKBQUGA2FYBREGAVg8BQcDiH+CBQMGngUHBgEFBgACBAGQBQXzBQg9BQXjBQQGdAUFBgEFBAY9BQgGAQUHWQUIcwUEBj0FCwYXZgUQWAUHNwUCBocFBQYBBQnhBQMGA/sAyAUJBgOFfwGCggUEBgP/AIIFCAYBZp4FEAY4BjwFAwY8BREGEwUJZQUEBj0FBgACBAEGAQURSgUPAAIEAVgFCQACBAFKBQQGSwUHBgEFDAOwfmYFAgYD1wFYBQUGAQUDBq0FFgACBAEGAQUGPAURAAIEAZAFKQACBAKQBSEAAgQCPAUSAAIEAQMYggUWAAIEAQbmBQ4AAgQBAQACBAEGdAUDBgPAfggSBQcGAQUFsQUHRQUCBkATBQUGAQUMZQQCBQEGA2E8BQIUBAEFDQACBAEGAy4BBAIFCQNSkGZKBAEFAwYDH54FBgYBBSUAAgQBngACBAFYBRIAAgQBPAUEBpITEwUCAwsBBQYGA3MBS54FCAYDTnQFCwYBBQQGoAUGBgEFBz0FBjsFBAY9BQcGAQUFBoMFCAYBBQQGbAUHBgEFBQaDBQgGAQUHdQUIcwUFBj0FDAYDmH5YBQQGA/oAugUPBgFKBQQAAgQBA6F/WAUKA+AASgUPOwUEBksFCgYBBR50BQqCBRMGngUeBgEFBAZKBREGAQUISwUROwUFBksFDQYBBQhKBQYGSwUTBgEFD0oFEzwFD0oFBQZLBQcGAQUQSgUKPAUFBj0FCwYBBQhKBQYG1xMFGAYBBQnyBQsGoAUdBgEFDkoFAwYDDJ4TExMFAhcFBQYBBQ4AAgQBrAUDBsoFBgYB1gUDBksYBQgGEwUGAwmCBQkDdkoFBAZ1BREGAQUGAwlKBREDd0oFBkoFBAZLBREGAQUPigUNA6gCWDwFEQPQfTwFDQOwAkoD0H08BQQGUhMFBwYBngUdA3VmBQcDC4IFEgYDdawFHQYBBQMGSgUEEwUQBhEFBgMKPAUQA3ZKBRE9BQaCBQQGSwURBgEFD4oFEQN4ZgUNSgUEBlITBQcGAQUEBrwFCgYBBQc8BQUGdQUIBgEFBgatBQkGAQULygUGA3l0SliCBQQGA5ACngUHBgEFDgaPBQkGdAUOZgUDBlAGAQUIA3k8BQN7BQIDEIJKSgUFBgOTflgFDQYBBQhZPQUNOgULMgUGQgUIA3Y8BQUGPRMFBBQFBQYDawEFCwMVPAUGQgUFA2UuBQYDGzw8BQMGAx9YBQYGAQUlAAIEAZ4FEgACBAFYBSUAAgQBPAUSAAIEATwFBAaEExMFAgMLAQUGBgNzAUueBQUGA60BrBMFCgYBBQ0DFkoFCANmSgUKeAUFBj0FCwYDu35YPAUFBp4FCwYBBQqRBQtlBQUGPQUKBgEFBQZZBQoGOwUFSwZZBQQUBQcGAYIIElgFBgOtf0pKA4UCWAUCBvIFBgYBWXMFAgY9BQYGAQUCBlwFBQYBBQwAAgQBugUXAAIEAi4FAwYDD9YFBgYBBQlLBQZzBRkAAgQBZgUIA6F/yAUFBgggBQgGAQUOAAIEAZAFBgafBQkGAQUHBgIjFwUMBgEFBwZZBQ4GAQUJqwUOPQUMWgULPgUMgAULTAUOOAUHBj0UEwULBgEFDVkFC0gFDT4FCzsFBwY9BQ0GAQULAAIEAVgFGAYDeUoFDQYBBQl1BQ1JBRgAAgQBWAUJAwlKBQYGrAUJBgEFC8oFDXJ0BQUGAxQ8BQoGAQUFBj0FIAACBAIGA8Z9WAUEBoMFBwYBZgUEBoQTEwUNBgEFFIUFBX4FFGoFDUcFBAZZBQMUBQ4GAQUDBskFDwYBWMgFAwY9BQkGA3kBBQoD8QF0BQQGdAUKBgEFBFkFCoEFBAY9BkoGyQUKBgEIEoIFBgOVfqwFDDwFCAOyAnQFBQasBQgGAQUFBsATBRAGAQUFSwUKOgUFdgUQOwUFBj0GWJ5KPAUJA61+WAUIBkoFCQYBBQgGSxMFBQO2AZ4FCAYBBQpLBQYGCDwFCgYBBQtZBQpzBQYGPQULBgEFBgZcBQkGAQUGCD4FC6AFDHIFBQZOBQgGAZ4FCz2eBQ8D/XyQBQeeBQUDoQK6BQlqBQUGA45/1gUOBgEFBQZOBQwGFwUIRQUXAAIEAZ4FAk0FFwACBAF/BSoAAgQCSgULAw6CBRkAAgQBBtgFEQACBAEBAAIEAQY8AAIEAUoFDQOKAmZKBQYGA5l9ugUJBgFmkAUHSAUJTAPUALq6SgUIA0BYBQUDGJADO3QFBksFBSxKWAULAxU8BQY0BQsDejwFBkIFBQNlLgUGAxs8PAUFBgM5WAULBgEFBfYFC3AFAgZABQUGAZAFCXEFBwYD3n7WBQoGAWZYSgUMAzkISgUEBgMhCBIFBgYBBQc9BQY7BQQGPQUHBgEFBQaDBQgGAQUFA3EuBQYDGzwFCwN6PAUIA3o8BQQGQgUFBgNrAQULAxU8WAUdAAIEAgP+AFgFBQYDE6wFCAYBrHQFBgYDxX5YEwUCBhAFC4QFFAACBAEDxgFYAAIEAZAFC0vySgUGBm4FCwYBBQiCBQYGPRMFEgACBAEGA29YBR4AAgQCLgULorqeBRQAAgQBMAUGBgNR5AUJBgEFDEsFCXMFFQACBAFmAhQAAQHUAQAABQAIADgAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8C4BcAAOcXAAACAR8CDwQdGAAAASUYAAABLRgAAAE4GAAAAQUBAAkCsJIAQAEAAAADIgEGAQUCBrsTFBMFCwYTBQRJBQE3BQRBBQIGSwUFBgEFAgYDEVgFDgYBBQMGgwULBgEFAYMFCQNrCBIFAwZNBQUGEwUGOwUDBlkFBQYBBQMGWQUGBgE8BQQGLwUGBhM7WQUKLgUGSQUEBi8FBgYBBQQGPQUMAQUJBgN4kAUFBgMJZgUWBgEFCFgFC0sFFkkFBy8FEC0FBQZnBQcGAUoFDAY6BQTMBQ0GAQUHPAUFBlkFBwYBSgUMBpMFCQYDcAEFDAMQPAUFBskFCwYBBQwGHwUCywUTBgE8BQ5KBQVKBQGEBQQGA3fkBQ0GAQUHSgUJA3SQBQEGAxisBgEFAgYTExQFDAYTBQRJBQIGSwUFBgEFAgZLBRQAAgQBAQUIBgEFFAACBAEuBQMGnwUdAAIEBAYRBQVLBR0AAgQEBjsFFAACBAEBAAIEAwZYBQIGhAUFBgEFAwZZEwQCBQEDnwMBBQIUBQwGAQUCBksTBgEEAQUFAAIEAQPdfAEFAgYwBQEGEwIDAAEBtw0AAAUACAByAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfBIQYAACLGAAAwRgAAOoYAAACAR8CDw4KGQAAAREZAAABGBkAAAImGQAAATEZAAADOxkAAANHGQAAA1EZAAADWRkAAANmGQAAAW4ZAAADdxkAAAOCGQAAA4sZAAAABQEACQIAlABAAQAAAAPIAAEGAQUCBskFCAYBBQFlBQUvBQcGlAUKBgEFCwYDDUoFA9cFC3MFArAFBQYBBQGSZgUDBgNudAQCBQoD4wwBBQUTBQwGAawEAQUDBgOdcwEFBgYBBRIAAgQBBkwFBRMGCBIFHgACBAMGLQUSAAIEAQEFBRMFHgACBANlBRIAAgQBAQUEFLsGAQURFQULBqEFAhYFAwNsAQUZBgEFAQMWumYFAwNqLgUIBgMM1gULBnQGXAZmCFgFAQYDZPIFAq0EAgUKA/IMAQUFEwUMBgGsBAEFAgYDjnMBBQUGAQUBXQUNBgN4yAURAAIEARcFBBMFHAACBAPxBREAAgQBAQUEEwUBBqAFBGQFAQYDN4IGAQUCBrsTFBUFAQYDeQEFAjUuBlsFBQYBBRcAAgQBWAUQAAIEAdYFAwZZBQ8GAQUFA188BQ8DIXQFAgYDG0oFDQNCAQUCFAUFBgEuBQMGSwbIngYDIwEFBQYBBQMGlhQFHQYQBUBYBQSDBgMJZgUSBgEFBAaRBQcGAQUDBlwFBQYDRwEFCQM5dAUDBj0FDgYBBQIGPgUNA0IBBQIUBQUGAS4FAgYDPQEFCwYBBQIGgwUBBhNYBQMGA2WeBQUGAQUeAwl0BQUDd3QFAwY0BR0GATwFQC4FHoUFBHIFAwZLBR4GEzwFLHQFBzwFBAaSEwUOBgEFAQYDEgiQBgEFAgatBQEGEQUFPQUDBlkFBgYBBQQGZwUBBhoFBAN4ZgaSBi4GWQUWBgEFBQO4f6wFDAPIAHQFE0sFDEkFBAY9EwUNA7R/AQUCFAUFBgEuBQEDzQABWAUGBgN0WAUDA0ABBQEGA8wAdFgFAwO0fyB0BQEGAAkCsJYAQAEAAAAD/wABBgEFAgblFBMZFAUGBgEFAgY9BQEGA3IBBQIGAw88EwUIBgEFDD88BQIGVgUDFAUHBgEFCkoFBUoFAwY9BQgGEwUJSQUOAAIEAQMPPAUJA3FKBQMGSwUOAAIEAQMOAQACBAEGAQUCBksFBQY8BQMGWQUGBgEFAwZgBQ8GAQULPAUKPQUPOwUDBksFCwYRBQFAgiAgBQQGA3WsBQkGATyCBQQGPQUHBgEFBAZaBoIGCBMFBgY9BQQ7BlkFAxQFDwYBBQs8BQo9BQ87BQMGSwULBhEFAQYDKLoGAQUCBq0UBQkDvX4BBQIUExQVBQEGA7gBAQUCA8h+Li4GWwUXAAIEAQYBBRAAAgQBdAUDBlkFDwYBBQUDXzwFDwMhdAUCBgMbdAUNA0IBBQIUBQUGAS4FAgYDPQETBgEGA5sBARQFCwYD4n4BBQoDngF0BQIGPQULBgPhfgEFAgYDoAFKBQEGE1gFAwYDxn6eGBQFHgYTdAUsCBIFB0oFBAaXBRIGAQUEBp8FBwYBBQMGXBMFCQYRBQUDR3QFCQM5dAUCBk0FDQNCAQUCFAUFBgEuBQMGSwbIdAUEBgMuARMFDgYBBQEGA7EB8gYBBQIGCEsTExMUGgUHBgEFEEoFAQNySgUFAw5mBQIGCEEFBAYBBQIGSxMTBQUGAQUCBlkFBQYBBQMGZwUEBgE8BQIGSwUGBgFYBQIGPQUFBgEFAgaSBQgGAQUXSgUfAAIEATwFE0oFHwACBAEGSgUGBlm6CHQFAgZLBQUGFEgFAgZLBQYGFEgFAgZLExMUBQsAAgQBAQUVAjYSBQsAAgQBSgUDWQULBgEFEDwFBkoFB1oFBjsFCj4FBAZZBQUTBQkGAQUcLgULPAUITAUOSAUHSgUFBmcFCwYBPTsFBQZLBQ4AAgQBEwUEWQUIBgEFFQN2SgUIAwpKBRUGA3ZYBQsAAgQBAQUoAAIEAQM8WAUzAAIEBIIFKAACBAEBAAIEAQY8AAIEAy4AAgQDdAUCBksFCQYBBQIGPQUBBhOCLgYIMwYBBQIG5RMTFAUFBgEFASkFBV08BQIGbAUFBgEFCj0FBTsFAgYwBQoGAQUFdAUBA3OQBQMGAyeQBQYGAS4FAwYwBQwGAQUGPAUBA1dYBQIGAx88BQMTBQYGAQUEBlkFCQYBBQQG1wUHBgEFBAaSBQYGPQUEOwZZBQMUBQYGAS4FAQMWLoIFBAYDbtafBQ4GAQUHPAUEBl4FDQODfQEFAhQFBQYBBQMGkQYISgUFBgP1AgEFFgYBBRQAAgQBrAUFBj0FFgYRBQg9BQUGWgUPBgEFAwYDV54FFwYBBQc8dFiCBQMGPQUGBgEFCtcFAwaJnwUMBgEFBnQFAwZeBQ0Dnn0BBQIUBQUGAQUDBskGCCAFBAYD2gIBBQkD+X4BBQIUFAUGBgEFAgbJBQUGAQUCBloTBQkGAZ4FDQACBAED/wABBQkDgX90BQIGSwYBBQQGA/8AARQFDQYBAAIEAY0FBAatBQEDLfIGAQUCBghLExMUBQEGDQUEQQUFLwUBA3o8BQlDBQRIBQIGPRMFCAYTBQlJBQUuBQIGSwUYAAIEAQEFA+UFHwACBAMGEQUFLwUfAAIEAwY7BRgAAgQBAQUCWgUHBgFYBQIGPQUFBgEFAgaSBQUGAQUCBksFDwACBAEBBQkGS0qsBQIGWQUMBhMFBEkFAgZLBQUGAQUCBksFBQYBSgUDBmgFBgYBBQWRBQYtBQMGPVkFBBMFDwYBBQdYBQpLBQ9JBQYvBRQ7BQQGZwUGBgE8BQ0AAgQBBi8FA1kFDAYBBQYCKRIFBUUFAgYDFTwFCgYBBQIGS4MFAQYT1i4uBQcGA3qCBQMTBQkGAQULAAIEAQYhBQdWBQMTBQkGAQULAAIEAQYhBQEIGQYBBQIGExMUEwUEBgEFAgZRBQUGAXQFAgYwBQsGEwUGgQUCBksFBQYBBQIGSxMFBQYBWAUDBmoFBgYBBQIGVQUDEwUGBgFKSgUEBoMFGgACBAEGAQACBAE8BQFPBr0GAQUCBggvExMUGgUFA1YBBQIUExQTBQQGAQUCBlEGAQUBAxABBQUDcGYFAgaSBQsGEwUGgQUCBksFBQYBBQIGSxMFBQYBWAUDBlwFBgYBBQIGjQUDEwUGBgFKSgUEBmcFBQYDIgEFGgNeWC4FBQMeAUMDeS48BQIGRAUGBgEFAgatBQUGAQUCBpIFCgYBBQIGPQUFBgFLTwUJkQUFA3kuBQIGPRMFBgYBBQIGWRMTBQsGAQUGSgUCBlkTTAUDEwUXBgEFBzwFBTwFAwZnBQkGEwUOSQUNAAIEAT4FCUkFDi0FDQACBAFMBQpIBQMGPQUNAAIEARMAAgQBBtYAAgQBdAACBAE8AAIEAQiQBQsGSwY8BQMGCC8FBwYBBQouBQZMBQVIBQMGPQUOBgEFCT0FDlcFCkoFAwY9BQsPBpA8BQgGAyKCBQODBQgGEQUFdQUIBkkGAQUCBkwFCQYBBQIGSwUBBhMFAgYDuH8IShoFBQYWVAUCBgN4CC4FAxMFBwYBBQMGnwUGBgEFAwZaEwUKBhEFAwaEBQoGAZAFAQYDxQAI5AYBBQIGgxMTFgUOBhMFBkkFAgZLBQUGAQUCBksFBAYBBQIGhgQDBQED0H4BBQIUBQkGAUoEAQUKA68BLgQDBQkD0X5YPAQBBQIGA68BAQUKBgEFAgaSBQUGAQUCBl4FCAYTBRc7AAIEAVgFAgZLBQUGAQUDBksFIgYBBRIuBRs8BSIuBRI8BRtKBQpaBRcsBQowBRcAAgQBKgUGTAUDBpEFGAYBBRNZSjwFDzwFAwY8BQIDFwEFCQYBBQE/ggUCBgNjWAUXAAIEAgYRBQUvBQMGXgUGBgEFAwa7BQIDEwEFCQYBBQE/BQMGA12eBRwGAQUSWAUcZgUSLgUGLgUDBpEFGAYBBSJZBQMGdAUZBgEFCjw8BR4uBQMGPQUCAx0BBQkGAQUBP4IFAwYDZGYFEgYBBQZYBRIuBQYuBQMGkQUCAxgBBQkGAQUBP3QgBj8GAQUCBvMTFBQTFRUFBgYBBQEDc1gFBgMNnlgFAgZABQUGAQUCBpIUBlgFCXQFFkIFCQN6PAUCBnUXBQUGE/IFAgZNBQUGDz8FAwZLBAMFAQP+fQEFAhQFDAYBBQIGgwUKBgE8BQIGLwYBBAEFBgACBAED/gEBBQQGWQUYBgEFEVgFGDwFETwFBj0FDTsFBAY9BQYGATwFAwZBBSQAAgQBBhQFF7oFDwACBARKBQIGAzk8BQUGAQUDBl8FEgYUBR46BAMFCQO/fXQEAQUNA8MCWAUeOgUDBj4EAwUBA7t9AQUCFAUJBgE8BAEFEAACBAEDwwIBBQEDCUpKgiAFAwYDuH90BAMFAQPyfQEFAhQFDAYBLgQBBQUDjwIBBAMFDAPxfVgFAgZZEwYBBAEFAwYDiwIBBQ8AAgQEBg4EAwUKA/h9PDwEAQUFA5ECAQQDBQoD731KBAEFAwYDjgJKFQUCAzABBQUGAQUDBloFGgYBggUDBi8FDQYBBQEDD55KgiAGAw6CBgEFAgYTBQEGEQUIBj0FEAYBBQ5KBQw8BQguBQMGSwUOBhEFBD0FCAZJBRAGAQUMSgUILgUCBkwFAQYTAgEAAQF9AAAABQAIADcAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8D3BkAAOMZAAAYGgAAAgEfAg8DOBoAAAFCGgAAAUwaAAACBQEACQLgoABAAQAAABYGAQUDBhMTBSUBBQoGAQUPOwUlPQUFBp8FJUkFFwYBBSVmAAIEAVgFAVs8AgEAAQGUAAAABQAIADcAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DnBoAAKMaAADYGgAAAgEfAg8D+BoAAAECGwAAAQwbAAACBQEACQIQoQBAAQAAABcGAQUDBhMUBRMAAgQBAQUKBhAFATsFEwACBAE/BSIAAgQDBp4FIAACBAMGAQUTAAIEAQZKAAIEAgZYBQMGrwUBBhMCAQABAVoAAAAFAAgALgAAAAEBAfsODQABAQEBAAAAAQAAAQEBHwJfGwAAZhsAAAIBHwIPApsbAAABqBsAAAEFAQAJAkChAEABAAAAAwwBBQUTBQwGAQACBAF0BQE9AgEAAQFaAAAABQAIAC4AAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8CABwAAAccAAACAR8CDwI8HAAAAUscAAABBQEACQJQoQBAAQAAAAMMAQUFEwUMBgEAAgQBdAUBPQIBAAEBTgEAAAUACABjAAAAAQEB+w4NAAEBAQEAAAABAAABAQEfBKQcAACrHAAA4RwAAAEdAAACAR8CDws5HQAAAUYdAAABUx0AAAJbHQAAAmcdAAACcR0AAAJ5HQAAAoYdAAACkx0AAAKcHQAAA6cdAAACBQEACQJgoQBAAQAAAAMkAQYBBQUGsQUBBg0FEUEuBQgAAgQBWAUvAAIEAVgFJQACBAGeBQkGAw9YBR8GAQUBS1gFCR8FDgYDa8gFCQMLAQUrBgEFKQACBAGeBQkAAgQB8gaEBRMGAXQFAQMJAVgGAxUuBgEFBQaxBQEGDQURQS4FCAACBAFYBS8AAgQBWAUlAAIEAZ4FCQYDD1gFHwYBBQFLWAUJHwUOBgNryAUJAwwBBRMGAQUJBnUFLQYBBSsAAgQBdAACBAE8BQkAAgQBngUBAwk8BQkAAgQBA3dmAgUAAQGfAAAABQAIAFQAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8ECh4AABEeAABGHgAAbx4AAAIBHwIPCI8eAAABqx4AAAHHHgAAAtUeAAAD3x4AAAPoHgAAA/AeAAAD/R4AAAMFAQAJAkCiAEABAAAAAw8BBQUTBQEGEwYDdvIGAQUFBhMFAQYRBAIFBwYDyw08BQUTBQwGAXQEAQUBA7ZyAQIBAAEBcwAAAAUACAA3AAAAAQEB+w4NAAEBAQEAAAABAAABAQEfA1MfAABaHwAAkB8AAAIBHwIPA7AfAAABwB8AAAHQHwAAAgUBAAkCYKIAQAEAAAADCQEGAQUFBq0FAQYRBQ4vBRoAAgQBWAUMAAIEAZ4FAT1YAgIAAQEbAgAABQAIAFUAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DHiAAACUgAABaIAAAAgEfAg8JeiAAAAGEIAAAAY4gAAACmCAAAAKgIAAAAqwgAAACtCAAAAK9IAAAAcwgAAACBQEACQKQogBAAQAAAAMTAQYBBQMGgwUBBhEFBp8FBwZaBQoGAQUHBnkFDgYBBQcGLwUOBgEFAQMQWAUHBgN0rAUSBhRKkGYFC3IFBwZ2BRIGAQUHBgg/BQoGAQUVAAIEAUoFBAZ2BQoAAgQBBlgFBAZnBQsGAQUBXAb2BgEFAwbJEwUdAAIEAQYBBQE6BR0AAgQBPgUBSAUdAAIEATAFAwZLBQsGE1gFEi0AAgQBWJAAAgQBPAUKAAIEAlgFATBYIAbaBgEFAwYISxMTBQwGFwUBA3g8BRuTWAUDBi8FHwYBBRJZBR9JBQMGLxQFEwACBAEGAQUDBlsFBgYBBRAGWgUECDIFBgYBBQgvBQY7BQQGPRMFBwYBBQQGsQUHBgEFEAYDdUoFBFoFDwYBBQcAAgQBCC4FDUsFAQMbdIIgPC5KSkoFBAYDeLoFBgYBBRk9BRQ8BQYtBQQGPQUHBgEFBAZ2BQcGAQUNBgN5SgUHERMFBBQFDwYBBQcAAgQBCC4AAgQBSgACBAE8BgN5AQUMBgEFAwYDEEoFCgYBBQgGA2u6BQ0GAQUIBoMFEwYBSgUGBgMPSgUQBgFKAgIAAQEcAwAABQAIAFoAAAABAQH7Dg0AAQEBAQAAAAEAAAEBAR8DISEAACghAABdIQAAAgEfAg8KfSEAAAGHIQAAAZEhAAACmyEAAAKjIQAAAq8hAAACtyEAAALAIQAAAs8hAAAC2CEAAAEFAQAJAoCkAEABAAAAAxIBBgEFAwa7GAUBBgN5AQUGbQUDBpMFBgYBBQMGlgUVBgEFCD8FBzoFE3MFAwY9FAUGBgEFAwaIBQYGAQUHBmgFCgYBBRADDro8BQwGSgUQBgEFDwACBAFmBQQGTgUHBgEFCQYIJgUNBgEFCANsCFgFBwACBAHWBQuKBQEDI1hYIAUDBgN1ggUGBgEFBwZ1BQ4GAQUKAwlmBQFZWCAFBwYDS4IFDAYBBQcGWQUMBgNyAQUBA8IALlggBQQGA1Q8BRgGAQUEBj0FCAYBZkoGAyMILgUMBgEFCwACBAECJBIFCAYDdUoFDgACBAEGWAUIBmcFDwYDbQEFCAYDCnQFGAYBBQgGZwUMBgNdAQUBBgPCAPIGAQUDBggTEwUMBgEFASwFHAACBAE/BQw7BQMGSwUcAAIEAQYBBQFHBRwAAgQBPwUDBkwFAQYNBRxsWAUTOwACBAJYAAIEBDwFCgACBAECIhIFATBYICAuBl4GAQUDBghLExMTBSQAAgQCBgEFAXAFJAACBAJABQE4BSQAAgQCagUDBksFAQYNBRtBWAUDBj0FHwYBWAUDBj4FBgYBBRYAAgQBkAUTAAIEATwFAwaTBQYGAQUHBlsFCgYDdAEFBwMMPAUEBr4FCQYTBQRXBksFBgYTBQk7BQQGZwUHA3oBBREAAgQBBlgFBwACBAEIngYDCUoFCgYBBQIGkQUHBgEFAQMLdIIgPC4FBwYDeboFDwYBBRUvPEoFCgNlAQUPAxo8BQcGSwUNBgEFAgaFBQQGAQUxKwUEPwUFBjsFFQYQBQUIoMgFDANqATwFAQYDH8gGAQUDBuUTBQsGAQUBLAULkgUDBksFIQYTWAUKOwACBAJYAAIEBDwAAgQCggACBAR0AAIEAoIAAgQESgACBAGsBQEwZiACBAABAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAAAAAAAAABAAQAEAAAABAAAAAAAAADQAAAAAAAAAEBAAQAEAAAAmAQAAAAAAAEEOEIYCQw0GAp8KxgwHCEULAlsKxgwHCEULAAAAAAAAJAAAAAAAAABAEQBAAQAAAE4AAAAAAAAAQQ4QhgJDDQYCScYMBwgAAGQAAAAAAAAAkBEAQAEAAABQAgAAAAAAAEEOEIYCQg4YjQNCDiCMBEEOKIUFQQ4whAZBDjiDB0QOYEUMBkADiAEKw0HEQcVCzELNQcYMBwhICwJoCsNBxEHFQsxCzUHGDAcISQsAAAAAJAAAAAAAAADgEwBAAQAAACIAAAAAAAAAQQ4QhgJDDQZdxgwHCAAAACQAAAAAAAAAEBQAQAEAAAAiAAAAAAAAAEEOEIYCQw0GXcYMBwgAAAAkAAAAAAAAAEAUAEABAAAAGQAAAAAAAABBDhCGAkMNBlTGDAcIAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAJAAAAHABAACQHABAAQAAAEMAAAAAAAAAQQ4QhgJDDQZ+xgwHCAAAADwAAABwAQAA4BwAQAEAAAB6AAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOQEUMBiACQwrDQcRBxhIHAU8LAAAAAAAUAAAAcAEAAGAdAEABAAAAHwAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAsAAAACAIAAIAdAEABAAAAMAAAAAAAAABBDhCGAkMNBlcKxgwHCEULT8YMBwgAAABMAAAACAIAALAdAEABAAAAggAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDkBFDAYgZgrDQcRBxhIHAUQLdQrDQcRBxhIHAUELT8NBxEHGEgcBABQAAAAIAgAAQB4AQAEAAAADAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAAEQAAAC4AgAAUB4AQAEAAAD4AAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOkAFFDAZQTZcKmAiZBgKACtnY10HDQcRBxhIHC0QLABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAAAYAwAAUB8AQAEAAAADAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAABIAwAAYB8AQAEAAAADAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAACwAAAB4AwAAcB8AQAEAAABpAAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOUEUMBiAAAEQAAAB4AwAA4B8AQAEAAABiAQAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA6AAUUMBjACywrDQcRBxUHGEgcHRQsAAAAAAFwAAAB4AwAAUCEAQAEAAABdAwAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDpABRQwGUFEKw0HEQcVCzELNQs5Cz0HGEgcBRwsAABQAAAD/////AQABeCAMBwigAQAAAAAAACQAAABoBAAAsCQAQAEAAAA6AAAAAAAAAEEOEIYCQw0GdcYMBwgAAAAUAAAAaAQAAPAkAEABAAAADAAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAA8AAAAwAQAAAAlAEABAAAAvQEAAAAAAABBDhCGAkEOGIMDRA5ARQwGIAKACsNBxhIHA0QLAmcKw0HGEgcDSAsAFAAAAP////8BAAF4IAwHCKABAAAAAAAATAAAABgFAADAJgBAAQAAAHsAAAAAAAAAQQ4QhgJCDhiNA0IOIIwEQQ4ohQVBDjCEBkEOOIMHRA5gRQwGQAJcw0HEQcVCzELNQcYMBwgAAABEAAAAGAUAAEAnAEABAAAAfwAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjBWCsNBxEHFQcYSBwFKCwAAAAAAAABEAAAAGAUAAMAnAEABAAAAmQAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDkBFDAYgUwrDQcRBxhIHAUcLAlsKw0HEQcYSBwFLCwA8AAAAGAUAAGAoAEABAAAA8gAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIHEKw0HGEgcDQwsCjwrDQcYSBwNICwAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAFAAAAFAGAABgKQBAAQAAACwAAAAAAAAAFAAAAFAGAACQKQBAAQAAAFAAAAAAAAAATAAAAFAGAADgKQBAAQAAAKYAAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDlBFDAYwAoEKw0HEQcVBxhIHAUcLSsNBxEHFQcYSBwEAAAAUAAAAUAYAAJAqAEABAAAAgAAAAAAAAAAUAAAAUAYAABArAEABAAAANwAAAAAAAAAUAAAAUAYAAFArAEABAAAAcwAAAAAAAAAUAAAAUAYAANArAEABAAAANgAAAAAAAAAUAAAAUAYAABAsAEABAAAAiQAAAAAAAAAUAAAAUAYAAKAsAEABAAAAvgAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAA8AAAAeAcAAKAtAEABAAAASAAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOYEUMBjB3w0HEQcVBxhIHAwAAFAAAAP////8BAAF4IAwHCKABAAAAAAAARAAAANAHAADwLQBAAQAAAG0AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5QRQwGIHYKw0HEQcYSBwNEC2LDQcRBxhIHAwAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAALAAAADAIAABgLgBAAQAAAOwAAAAAAAAAQQ4QhgJDDQYCiArGDAcIRAsAAAAAAAAAPAAAADAIAABQLwBAAQAAAFgAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBwCsNBxhIHA0QLVsNBxhIHAwAAAAAAAFwAAAAwCAAAsC8AQAEAAACeAQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDqABRQwGUAMaAQrDQcRBxULMQs1CzkLPQcYSBwNBC0QAAAAwCAAAUDEAQAEAAABEAQAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5QRQwGMALUCsNBxEHFQcYSBwFECwAAAAAAADwAAAAwCAAAoDIAQAEAAABPAAAAAAAAAEEOEIYCQQ4YhANBDiCDBEQOQEUMBiBxCsNBxEHGEgcBSQsAAAAAAAAsAAAAMAgAAPAyAEABAAAAkQAAAAAAAABBDhCGAkMNBgJrCsYMBwhBCwAAAAAAAABcAAAAMAgAAJAzAEABAAAAGQUAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA6AAUUMBlADzgIKw0HEQcVCzELNQs5Cz0HGDAcIQgtcAAAAMAgAALA4AEABAAAAqQMAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA5wRQwGUAM4AgrDQcRBxULMQs1CzkLPQcYMBxhICwBcAAAAMAgAAGA8AEABAAAATgEAAAAAAABBDhCGAkIOGIwDQQ4ghQRBDiiEBUEOMIMGRA5gRQwGMAKzCsNBxEHFQsxBxhIHAUkLUgrDQcRBxULMQcYSBwFJCwAAAAAAAABcAAAAMAgAALA9AEABAAAA1gMAAAAAAABBDhCGAkIOGIwDQQ4ghQRBDiiEBUEOMIMGRA5QRQwGMANVAQrDQcRBxULMQcYMBwhHCwKFCsNBxEHFQsxBxgwHCEYLAAAAAAA8AAAAMAgAAJBBAEABAAAA1wAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjACwsNBxEHFQcYSBwEARAAAADAIAABwQgBAAQAAAJ8AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5wRQwGIAJcCsNBxEHGEgcHRgtsw0HEQcYSBwcAAAAANAAAADAIAAAQQwBAAQAAAN8AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5wRQwGIALQw0HEQcYSBwdEAAAAMAgAAPBDAEABAAAAWAEAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOgAFFDAYwAtQKw0HEQcVBxhIHB0QLAAAAAABcAAAAMAgAAFBFAEABAAAAswQAAAAAAABBDhCGAkIOGI4DQg4gjQRCDiiMBUEOMIUGQQ44hAdBDkCDCEQOkAFFDAZAA6YDCsNBxEHFQsxCzULOQcYSBwNOCwAAAAAAAABcAAAAMAgAABBKAEABAAAACwoAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRw6AAkgMBlADcgEKw0HEQcVCzELNQs5Cz0HGEgcPSAsUAAAA/////wEAAXggDAcIoAEAAAAAAAA8AAAAGA0AACBUAEABAAAAWwAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIHIKw0HGEgcDQgtZw0HGEgcDAAAAAAAAZAAAABgNAACAVABAAQAAAH4BAAAAAAAAQQ4QhgJCDhiNA0IOIIwEQQ4ohQVBDjCEBkEOOIMHRA6gAUUMBkAC7grDQcRBxULMQs1BxhIHB0oLAkQKw0HEQcVCzELNQcYSBwdBCwAAAAAsAAAAGA0AAABWAEABAAAAkQAAAAAAAABBDhCGAkMNBgJrCsYMBwhBCwAAAAAAAAA8AAAAGA0AAKBWAEABAAAAdgAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDlBFDAYgXwrDQcRBxhIHA0sLAAAAAAAAPAAAABgNAAAgVwBAAQAAAE8AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5ARQwGIHEKw0HEQcYSBwFJCwAAAAAAACwAAAAYDQAAcFcAQAEAAADsAAAAAAAAAEEOEIYCQw0GAogKxgwHCEQLAAAAAAAAAEwAAAAYDQAAYFgAQAEAAADNAQAAAAAAAEEOEIYCQg4YjANBDiCFBEEOKIQFQQ4wgwZEDmBFDAYwA3UBCsNBxEHFQsxBxhIHAUcLAAAAAAAAXAAAABgNAAAwWgBAAQAAANYDAAAAAAAAQQ4QhgJCDhiMA0EOIIUEQQ4ohAVBDjCDBkQOUEUMBjADVQEKw0HEQcVCzEHGDAcIRwsChQrDQcRBxULMQcYMBwhGCwAAAAAANAAAABgNAAAQXgBAAQAAAOcAAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5wRQwGIALYw0HEQcYSBwdcAAAAGA0AAABfAEABAAAAKQUAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA6AAUUMBlAD3QIKw0HEQcVCzELNQs5Cz0HGDAcIQwtcAAAAGA0AADBkAEABAAAAuQMAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA5wRQwGUANIAgrDQcRBxULMQs1CzkLPQcYMBxhICwBcAAAAGA0AAPBnAEABAAAAswQAAAAAAABBDhCGAkIOGI4DQg4gjQRCDiiMBUEOMIUGQQ44hAdBDkCDCEQOkAFFDAZAA6YDCsNBxEHFQsxCzULOQcYSBwNOCwAAAAAAAAA8AAAAGA0AALBsAEABAAAA1wAAAAAAAABBDhCGAkEOGIUDQQ4ghARBDiiDBUQOUEUMBjACwsNBxEHFQcYSBwEARAAAABgNAACQbQBAAQAAAJ8AAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5wRQwGIAJcCsNBxEHGEgcHRgtsw0HEQcYSBwcAAAAARAAAABgNAAAwbgBAAQAAAFgBAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDoABRQwGMALUCsNBxEHFQcYSBwdECwAAAAAAXAAAABgNAACQbwBAAQAAAI0KAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUcOgAJIDAZQAy8BCsNBxEHFQsxCzULOQs9BxhIHD0sLFAAAAP////8BAAF4IAwHCKABAAAAAAAALAAAAPARAAAgegBAAQAAAEAAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBzw0HGEgcDRAAAAPARAABgegBAAQAAAHwAAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDlBFDAYwAmQKw0HEQcVBxhIHAUQLAAAAAAAAFAAAAPARAADgegBAAQAAACcAAAAAAAAAXAAAAPARAAAQewBAAQAAAH0BAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUQOgAFFDAZQAwMBCsNBxEHFQsxCzULOQs9BxgwHCEULFAAAAP////8BAAF4IAwHCKABAAAAAAAAdAAAAPgSAACQfABAAQAAABMWAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUcOkAJIDAZQA68CCsNBxEHFQsxCzULOQs9BxhIHEUsLdgrDQcRBxULMQs1CzkLPQcYSBxFHCwAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAXAAAAIgTAACwkgBAAQAAAAoBAAAAAAAAQQ4QhgJCDhiNA0IOIIwEQQ4ohQVBDjCEBkEOOIMHRA0GZArDQcRBxULMQs1BxgwHMEkLAqoKw0HEQcVCzELNQcYMBzBHCwAAFAAAAIgTAADAkwBAAQAAADoAAAAAAAAAFAAAAP////8BAAF4IAwHCKABAAAAAAAAVAAAABgUAAAAlABAAQAAAOkAAAAAAAAAQQ4QhgJBDhiFA0EOIIQEQQ4ogwVEDlBFDAYwAkMKw0HEQcVBxhIHAUULAk8Kw0HEQcVBxhIHAU4LAAAAAAAAADwAAAAYFAAA8JQAQAEAAABLAAAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgVQrDQcYSBwNHC1/DQcYSBwMAAAAAAAA8AAAAGBQAAECVAEABAAAA8wAAAAAAAABBDhCGAkEOGIQDQQ4ggwREDlBFDAYgApIKw0HEQcYSBwNICwAAAAAARAAAABgUAABAlgBAAQAAAGwAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBTCsNBxhIHA0kLawrDQcYSBwNEC0zDQcYSBwMAAAAATAAAABgUAACwlgBAAQAAALkAAAAAAAAAQQ4QhgJCDhiMA0EOIIUEQQ4ohAVBDjCDBkQOUEUMBjACVArDQcRBxULMQcYMBwhICwAAAAAAAAA0AAAAGBQAAHCXAEABAAAAvQAAAAAAAABBDhCGAkEOGIMDRA5QRQwGIHsKw0HGEgcFSQsAAAAAAFwAAAAYFAAAMJgAQAEAAABnAQAAAAAAAEEOEIYCQg4YjwNCDiCOBEIOKI0FQg4wjAZBDjiFB0EOQIQIQQ5IgwlEDoABRQwGUANGAcNBxEHFQsxCzULOQs9BxgwHCAAAAEwAAAAYFAAAoJkAQAEAAACCAQAAAAAAAEEOEIYCQg4YjANBDiCFBEEOKIQFQQ4wgwZEDlBFDAYwAnMKw0HEQcVCzEHGDAcISQsAAAAAAAAAXAAAABgUAAAwmwBAAQAAACYBAAAAAAAAQQ4QhgJCDhiPA0IOII4EQg4ojQVCDjCMBkEOOIUHQQ5AhAhBDkiDCUQOcEUMBlAC8QrDQcRBxULMQs1CzkLPQcYMBxhHCwAAFAAAABgUAABgnABAAQAAAEgAAAAAAAAAVAAAABgUAACwnABAAQAAAMMBAAAAAAAAQQ4QhgJCDhiOA0IOII0EQg4ojAVBDjCFBkEOOIQHQQ5AgwhEDmBFDAZAA1gBCsNBxEHFQsxCzULOQcYMBxhEC2QAAAAYFAAAgJ4AQAEAAAAPAQAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA0GAoEKw0HEQcVBxgwHIEQLXArDQcRBxUHGDAcgQQt4CsNBxEHFQcYMByBFC1vDQcRBxUHGDAcgAAAATAAAABgUAACQnwBAAQAAABoBAAAAAAAAQQ4QhgJBDhiEA0EOIIMERA5QRQwGMESXBgK/CtdBw0HEQcYSBwNGC37XQcNBxEHGEgcDAAAAAAAUAAAAGBQAALCgAEABAAAAIgAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAUAAAAKBgAAOCgAEABAAAAKAAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAUAAAAWBgAABChAEABAAAAJQAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAUAAAAiBgAAEChAEABAAAACwAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAAUAAAAuBgAAFChAEABAAAACwAAAAAAAAAUAAAA/////wEAAXggDAcIoAEAAAAAAAA8AAAA6BgAAGChAEABAAAAcAAAAAAAAABBDhCGAkEOGIMDRA5ARQwGIGcKw0HGEgcDTQtuw0HGEgcDAAAAAAAAPAAAAOgYAADQoQBAAQAAAGkAAAAAAAAAQQ4QhgJBDhiDA0QOQEUMBiBnCsNBxhIHA00LY8NBxhIHAwAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAABQAAACAGQAAQKIAQAEAAAAIAAAAAAAAABQAAACAGQAAUKIAQAEAAAALAAAAAAAAABQAAAD/////AQABeCAMBwigAQAAAAAAACwAAADIGQAAYKIAQAEAAAAmAAAAAAAAAEEOEIYCQQ4YgwNEDkBFDAYgWcNBxhIHAxQAAAD/////AQABeCAMBwigAQAAAAAAACwAAAAQGgAAkKIAQAEAAACGAAAAAAAAAEEOEIYCQw0GZgrGDAcIRgsCVcYMBwgAADwAAAAQGgAAIKMAQAEAAABFAAAAAAAAAEEOEIYCQQ4YhQNBDiCEBEEOKIMFRA5gRQwGMHTDQcRBxUHGEgcDAABcAAAAEBoAAHCjAEABAAAABgEAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA6AAUUMBlACfQrDQcRBxULMQs1CzkLPQcYMBwhDCwAUAAAA/////wEAAXggDAcIoAEAAAAAAABUAAAA+BoAAICkAEABAAAARwEAAAAAAABBDhCGAkEOGIUDQQ4ggwREDmBFDAYgApsKw0HFQcYSBwVHC1cKw0HFQcYSBwVHC0wKw0HFQcYSBwVCCwAAAAAATAAAAPgaAADQpQBAAQAAAG8AAAAAAAAAQQ4QhgJCDhiNA0IOIIwEQQ4ohQVBDjCEBkEOOIMHRA6AAUUMBkACVsNBxEHFQsxCzUHGEgcDAABcAAAA+BoAAECmAEABAAAAFQEAAAAAAABBDhCGAkIOGI8DQg4gjgRCDiiNBUIOMIwGQQ44hQdBDkCECEEOSIMJRA6QAUUMBlACoQrDQcRBxULMQs1CzkLPQcYSBwFHCwBEAAAA+BoAAGCnAEABAAAAYQAAAAAAAABBDhCGAkIOGIwDQQ4ghQRBDiiEBUEOMIMGRA5wRQwGMAJMw0HEQcVCzEHGEgcDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFN1YnN5c3RlbQBDaGVja1N1bQBTaXplT2ZJbWFnZQBCYXNlT2ZDb2RlAFNlY3Rpb25BbGlnbm1lbnQATWlub3JTdWJzeXN0ZW1WZXJzaW9uAERhdGFEaXJlY3RvcnkAU2l6ZU9mU3RhY2tDb21taXQASW1hZ2VCYXNlAFNpemVPZkNvZGUATWFqb3JMaW5rZXJWZXJzaW9uAFNpemVPZkhlYXBSZXNlcnZlAFNpemVPZkluaXRpYWxpemVkRGF0YQBTaXplT2ZTdGFja1Jlc2VydmUAU2l6ZU9mSGVhcENvbW1pdABNaW5vckxpbmtlclZlcnNpb24AX19lbmF0aXZlX3N0YXJ0dXBfc3RhdGUAU2l6ZU9mVW5pbml0aWFsaXplZERhdGEAQWRkcmVzc09mRW50cnlQb2ludABNYWpvclN1YnN5c3RlbVZlcnNpb24AU2l6ZU9mSGVhZGVycwBNYWpvck9wZXJhdGluZ1N5c3RlbVZlcnNpb24ARmlsZUFsaWdubWVudABOdW1iZXJPZlJ2YUFuZFNpemVzAEV4Y2VwdGlvblJlY29yZABEbGxDaGFyYWN0ZXJpc3RpY3MATWlub3JJbWFnZVZlcnNpb24ATWlub3JPcGVyYXRpbmdTeXN0ZW1WZXJzaW9uAExvYWRlckZsYWdzAFdpbjMyVmVyc2lvblZhbHVlAE1ham9ySW1hZ2VWZXJzaW9uAF9fZW5hdGl2ZV9zdGFydHVwX3N0YXRlAGhEbGxIYW5kbGUAbHByZXNlcnZlZABkd1JlYXNvbgBzU2VjSW5mbwBFeGNlcHRpb25SZWNvcmQAcFNlY3Rpb24AVGltZURhdGVTdGFtcABwTlRIZWFkZXIAQ2hhcmFjdGVyaXN0aWNzAHBJbWFnZUJhc2UAVmlydHVhbEFkZHJlc3MAaVNlY3Rpb24AaW50bGVuAHN0cmVhbQB2YWx1ZQBleHBfd2lkdGgAX19taW5nd19sZGJsX3R5cGVfdABzdGF0ZQBfX3RJMTI4XzIAX01ic3RhdGV0AHByZWNpc2lvbgBleHBvbmVudABfX21pbmd3X2RibF90eXBlX3QAc2lnbgBzaWduX2JpdABpbnRsZW4Ac3RyZWFtAHZhbHVlAGV4cF93aWR0aABfX21zX2Z3cHJpbnRmAF9fbWluZ3dfbGRibF90eXBlX3QAX190STEyOF8yAF9NYnN0YXRldABwcmVjaXNpb24AZXhwb25lbnQAX19taW5nd19kYmxfdHlwZV90AHNpZ24Ac2lnbl9iaXQAX19CaWdpbnQAX19CaWdpbnQAX19CaWdpbnQAX19CaWdpbnQAbGFzdF9DU19pbml0AGJ5dGVfYnVja2V0AGJ5dGVfYnVja2V0AGludGVybmFsX21ic3RhdGUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC91Y3J0ZXhlLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlL3BzZGtfaW5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2luY2x1ZGUAdWNydGV4ZS5jAGNydGV4ZS5jAHdpbm50LmgAaW50cmluLWltcGwuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHN0ZGxpYi5oAGVycmhhbmRsaW5nYXBpLmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAGN0eXBlLmgAaW50ZXJuYWwuaABjb3JlY3J0X3N0YXJ0dXAuaABtYXRoLmgAdGNoYXIuaAB3Y2hhci5oAHN0cmluZy5oAHByb2Nlc3MuaABzeW5jaGFwaS5oADxidWlsdC1pbj4AL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2djY21haW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAGdjY21haW4uYwBnY2NtYWluLmMAd2lubnQuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAY29yZWNydC5oAHN0ZGxpYi5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9uYXRzdGFydC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvaW5jbHVkZQBuYXRzdGFydC5jAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAGludGVybmFsLmgAbmF0c3RhcnQuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvd2lsZGNhcmQuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB3aWxkY2FyZC5jAHdpbGRjYXJkLmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L19uZXdtb2RlLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAX25ld21vZGUuYwBfbmV3bW9kZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvdGxzc3VwLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHRsc3N1cC5jAHRsc3N1cC5jAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAd2lubnQuaABjb3JlY3J0X3N0YXJ0dXAuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQveG5jb21tb2QuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB4bmNvbW1vZC5jAHhuY29tbW9kLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9jaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAY2luaXRleGUuYwBjaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvbWVyci5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBtZXJyLmMAbWVyci5jAG1hdGguaABzdGRpby5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC91ZGxsYXJnYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHVkbGxhcmdjLmMAZGxsYXJndi5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9DUlRfZnAxMC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AENSVF9mcDEwLmMAQ1JUX2ZwMTAuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L21pbmd3X2hlbHBlcnMuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AG1pbmd3X2hlbHBlcnMuYwBtaW5nd19oZWxwZXJzLmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3BzZXVkby1yZWxvYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAcHNldWRvLXJlbG9jLmMAcHNldWRvLXJlbG9jLmMAdmFkZWZzLmgAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaABzdGRpby5oAG1lbW9yeWFwaS5oAGVycmhhbmRsaW5nYXBpLmgAc3RyaW5nLmgAc3RkbGliLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvdXNlcm1hdGhlcnIuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHVzZXJtYXRoZXJyLmMAdXNlcm1hdGhlcnIuYwBtYXRoLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3h0eHRtb2RlLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAeHR4dG1vZGUuYwB4dHh0bW9kZS5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9jcnRfaGFuZGxlci5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAY3J0X2hhbmRsZXIuYwBjcnRfaGFuZGxlci5jAHdpbm50LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAGVycmhhbmRsaW5nYXBpLmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAHNpZ25hbC5oAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvdGxzdGhyZC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB0bHN0aHJkLmMAdGxzdGhyZC5jAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAd2lubnQuaABtaW53aW5iYXNlLmgAc3luY2hhcGkuaABzdGRsaWIuaABwcm9jZXNzdGhyZWFkc2FwaS5oAGVycmhhbmRsaW5nYXBpLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC90bHNtY3J0LmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB0bHNtY3J0LmMAdGxzbWNydC5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9wc2V1ZG8tcmVsb2MtbGlzdC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHBzZXVkby1yZWxvYy1saXN0LmMAcHNldWRvLXJlbG9jLWxpc3QuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcGVzZWN0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwZXNlY3QuYwBwZXNlY3QuYwBjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAc3RyaW5nLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MvbWluZ3dfbWF0aGVyci5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjAG1pbmd3X21hdGhlcnIuYwBtaW5nd19tYXRoZXJyLmMAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfdmZwcmludGYuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWluZ3dfdmZwcmludGYuYwBtaW5nd192ZnByaW50Zi5jAHZhZGVmcy5oAHN0ZGlvLmgAbWluZ3dfcGZvcm1hdC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL21pbmd3X3ZzbnByaW50ZncuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWluZ3dfdnNucHJpbnRmdy5jAG1pbmd3X3ZzbnByaW50Zi5jAHZhZGVmcy5oAGNvcmVjcnQuaABtaW5nd19wZm9ybWF0LmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfcGZvcm1hdC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8AL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby8uLi9nZHRvYQBtaW5nd19wZm9ybWF0LmMAbWluZ3dfcGZvcm1hdC5jAG1hdGguaAB2YWRlZnMuaABjb3JlY3J0LmgAbG9jYWxlLmgAc3RkaW8uaABzdGRpbnQuaAB3Y2hhci5oAGdkdG9hLmgAc3RyaW5nLmgAc3RkZGVmLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby9taW5nd19wZm9ybWF0dy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8AL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby8uLi9nZHRvYQBtaW5nd19wZm9ybWF0dy5jAG1pbmd3X3Bmb3JtYXQuYwBtYXRoLmgAdmFkZWZzLmgAY29yZWNydC5oAGxvY2FsZS5oAHN0ZGlvLmgAc3RkaW50LmgAd2NoYXIuaABnZHRvYS5oAHN0cmluZy5oAHN0ZGRlZi5oADxidWlsdC1pbj4AL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EvZG1pc2MuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAGRtaXNjLmMAZG1pc2MuYwBnZHRvYWltcC5oAGdkdG9hLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hL2dkdG9hLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZ2R0b2EuYwBnZHRvYS5jAGdkdG9haW1wLmgAY29yZWNydC5oAGdkdG9hLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9nbWlzYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EAZ21pc2MuYwBnbWlzYy5jAGdkdG9haW1wLmgAZ2R0b2EuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9taXNjLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYQAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlL3BzZGtfaW5jAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWlzYy5jAG1pc2MuYwBpbnRyaW4taW1wbC5oAGdkdG9haW1wLmgAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABnZHRvYS5oAHN0ZGxpYi5oAHN5bmNoYXBpLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3N0cm5sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBzdHJubGVuLmMAc3Rybmxlbi5jAGNvcmVjcnQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djc25sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB3Y3NubGVuLmMAd2Nzbmxlbi5jAGNvcmVjcnQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL19fcF9fZm1vZGUuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAX19wX19mbW9kZS5jAF9fcF9fZm1vZGUuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL19fcF9fY29tbW9kZS5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwBfX3BfX2NvbW1vZGUuYwBfX3BfX2NvbW1vZGUuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfbG9jay5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2luY2x1ZGUAbWluZ3dfbG9jay5jAG1pbmd3X2xvY2suYwBzdGRpby5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAaW50ZXJuYWwuaABzeW5jaGFwaS5oAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlL3BzZGtfaW5jAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlci5jAGludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIuYwBpbnRyaW4taW1wbC5oAGNvcmVjcnQuaABzdGRsaWIuaAB3aW5udC5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpby9hY3J0X2lvYl9mdW5jLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAGFjcnRfaW9iX2Z1bmMuYwBhY3J0X2lvYl9mdW5jLmMAc3RkaW8uaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYy93Y3J0b21iLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB3Y3J0b21iLmMAd2NydG9tYi5jAGNvcmVjcnQuaAB3Y2hhci5oAG1pbndpbmRlZi5oAHdpbm50LmgAc3RkbGliLmgAbWJfd2NfY29tbW9uLmgAc3RyaW5nYXBpc2V0LmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYy9tYnJ0b3djLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWJydG93Yy5jAG1icnRvd2MuYwBjb3JlY3J0LmgAd2NoYXIuaABtaW53aW5kZWYuaAB3aW5udC5oAHdpbm5scy5oAHN0cmluZ2FwaXNldC5oAHN0ZGxpYi5oAG1iX3djX2NvbW1vbi5oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADEAQAABQAIAAAAAAAAAAAABMAIzAgBUgTMCNkIBKMBUp8AAQAAAAAAAAAEoQPAAwIwnwTAA9ADAVAE2QPpAwFQBLEGxgYBUAAAAAAA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dGEkNtQGAAAHAAAAAwAudGV4dAAAABCYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN7wIAAAHAAAAAwAuaWRhdGEkNWgDAAAHAAAAAwAuaWRhdGEkNFABAAAHAAAAAwAuaWRhdGEkNuIGAAAHAAAAAwAudGV4dAAAABiYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN8AIAAAHAAAAAwAuaWRhdGEkNXADAAAHAAAAAwAuaWRhdGEkNFgBAAAHAAAAAwAuaWRhdGEkNuwGAAAHAAAAAwAudGV4dAAAABiYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN8QIAAAHAAAAAwAuaWRhdGEkNXgDAAAHAAAAAwAuaWRhdGEkNGABAAAHAAAAAwAuaWRhdGEkNvgGAAAHAAAAAwAudGV4dAAAACCYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN8gIAAAHAAAAAwAuaWRhdGEkNYADAAAHAAAAAwAuaWRhdGEkNGgBAAAHAAAAAwAuaWRhdGEkNgIHAAAHAAAAAwAudGV4dAAAACiYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN8wIAAAHAAAAAwAuaWRhdGEkNYgDAAAHAAAAAwAuaWRhdGEkNHABAAAHAAAAAwAuaWRhdGEkNg4HAAAHAAAAAwAudGV4dAAAACiYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN9AIAAAHAAAAAwAuaWRhdGEkNZADAAAHAAAAAwAuaWRhdGEkNHgBAAAHAAAAAwAuaWRhdGEkNhgHAAAHAAAAAwAudGV4dAAAADCYAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN9QIAAAHAAAAAwAuaWRhdGEkNZgDAAAHAAAAAwAuaWRhdGEkNIABAAAHAAAAAwAuaWRhdGEkNiQHAAAHAAAAAwAudGV4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AAAAAAAAAAAAAAAAAAAuaWRhdGEkNzwJAAAHAAAAAwELAAAAAAAAAAAAAAAAAAAAAAAudGV4dAAAAACZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN4QIAAAHAAAAAwAuaWRhdGEkNRADAAAHAAAAAwAuaWRhdGEkNPgAAAAHAAAAAwAuaWRhdGEkNiYGAAAHAAAAAwAudGV4dAAAAAiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN4AIAAAHAAAAAwAuaWRhdGEkNQgDAAAHAAAAAwAuaWRhdGEkNPAAAAAHAAAAAwAuaWRhdGEkNhAGAAAHAAAAAwAudGV4dAAAABCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN3wIAAAHAAAAAwAuaWRhdGEkNQADAAAHAAAAAwAuaWRhdGEkNOgAAAAHAAAAAwAuaWRhdGEkNgAGAAAHAAAAAwAudGV4dAAAABiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN3gIAAAHAAAAAwAuaWRhdGEkNfgCAAAHAAAAAwAuaWRhdGEkNOAAAAAHAAAAAwAuaWRhdGEkNu4FAAAHAAAAAwAudGV4dAAAACCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN3QIAAAHAAAAAwAuaWRhdGEkNfACAAAHAAAAAwAuaWRhdGEkNNgAAAAHAAAAAwAuaWRhdGEkNtwFAAAHAAAAAwAudGV4dAAAACiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN3AIAAAHAAAAAwAuaWRhdGEkNegCAAAHAAAAAwAuaWRhdGEkNNAAAAAHAAAAAwAuaWRhdGEkNs4FAAAHAAAAAwAudGV4dAAAADCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN2wIAAAHAAAAAwAuaWRhdGEkNeACAAAHAAAAAwAuaWRhdGEkNMgAAAAHAAAAAwAuaWRhdGEkNsYFAAAHAAAAAwAudGV4dAAAADiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN2gIAAAHAAAAAwAuaWRhdGEkNdgCAAAHAAAAAwAuaWRhdGEkNMAAAAAHAAAAAwAuaWRhdGEkNqgFAAAHAAAAAwAudGV4dAAAAECZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN2QIAAAHAAAAAwAuaWRhdGEkNdACAAAHAAAAAwAuaWRhdGEkNLgAAAAHAAAAAwAuaWRhdGEkNpwFAAAHAAAAAwAudGV4dAAAAEiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN2AIAAAHAAAAAwAuaWRhdGEkNcgCAAAHAAAAAwAuaWRhdGEkNLAAAAAHAAAAAwAuaWRhdGEkNoYFAAAHAAAAAwAudGV4dAAAAFCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN1wIAAAHAAAAAwAuaWRhdGEkNcACAAAHAAAAAwAuaWRhdGEkNKgAAAAHAAAAAwAuaWRhdGEkNnYFAAAHAAAAAwAudGV4dAAAAFiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN1gIAAAHAAAAAwAuaWRhdGEkNbgCAAAHAAAAAwAuaWRhdGEkNKAAAAAHAAAAAwAuaWRhdGEkNl4FAAAHAAAAAwAudGV4dAAAAGCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN1QIAAAHAAAAAwAuaWRhdGEkNbACAAAHAAAAAwAuaWRhdGEkNJgAAAAHAAAAAwAuaWRhdGEkNkoFAAAHAAAAAwAudGV4dAAAAGiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN1AIAAAHAAAAAwAuaWRhdGEkNagCAAAHAAAAAwAuaWRhdGEkNJAAAAAHAAAAAwAuaWRhdGEkNi4FAAAHAAAAAwAudGV4dAAAAHCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN0wIAAAHAAAAAwAuaWRhdGEkNaACAAAHAAAAAwAuaWRhdGEkNIgAAAAHAAAAAwAuaWRhdGEkNhgFAAAHAAAAAwAudGV4dAAAAHiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN0gIAAAHAAAAAwAuaWRhdGEkNZgCAAAHAAAAAwAuaWRhdGEkNIAAAAAHAAAAAwAuaWRhdGEkNggFAAAHAAAAAwAudGV4dAAAAICZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN0QIAAAHAAAAAwAuaWRhdGEkNZACAAAHAAAAAwAuaWRhdGEkNHgAAAAHAAAAAwAuaWRhdGEkNvoEAAAHAAAAAwAudGV4dAAAAIiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkN0AIAAAHAAAAAwAuaWRhdGEkNYgCAAAHAAAAAwAuaWRhdGEkNHAAAAAHAAAAAwAuaWRhdGEkNuQEAAAHAAAAAwAudGV4dAAAAJCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkNzwIAAAHAAAAAwAuaWRhdGEkNYACAAAHAAAAAwAuaWRhdGEkNGgAAAAHAAAAAwAuaWRhdGEkNswEAAAHAAAAAwAudGV4dAAAAJiZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkNzgIAAAHAAAAAwAuaWRhdGEkNXgCAAAHAAAAAwAuaWRhdGEkNGAAAAAHAAAAAwAuaWRhdGEkNrQEAAAHAAAAAwAudGV4dAAAAKCZAAABAAAAAwAuZGF0YQAAAOAAAAACAAAAAwAuYnNzAAAAAIALAAAGAAAAAwAuaWRhdGEkNzQIAAAHAAAAAwAuaWRhdGEkNXACAAAHAAAAAwAuaWRhdGEkNFgAAAAHAAAAAwAuaWRhdGEkNqIEAAAHAAAAAwAudGV4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qBoAALANAAADAAAAAgAAAAAAtxoAAHAMAAADAAAAAgAAAAAA3BoAAHADAAAHAAAAAgAAAAAA6xoAAJiZAAABAAAAAgAAAAAAARsAAGATAAADAAAAAgAAAAAAIxsAAFgDAAAHAAAAAgBfdW5sb2NrAECYAAABACAAAgAAAAAANBsAANAMAAADAAAAAgAAAAAATRsAAJANAAADAAAAAgAAAAAAXBsAAFAAAAAIAAAAAgB2ZnByaW50ZuCYAAABACAAAgBmcHV0d2MAAIiYAAABACAAAgAAAAAAbBsAAPADAAAHAAAAAgBmcmVlAAAAAJCYAAABACAAAgAAAAAAeRsAAJAAAAAGAAAAAgCKGwAALmRlYnVnX2FyYW5nZXMALmRlYnVnX2luZm8ALmRlYnVnX2FiYnJldgAuZGVidWdfbGluZQAuZGVidWdfZnJhbWUALmRlYnVnX3N0cgAuZGVidWdfbGluZV9zdHIALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19ybmdsaXN0cwBfX21pbmd3X2ludmFsaWRQYXJhbWV0ZXJIYW5kbGVyAHByZV9jX2luaXQALnJkYXRhJC5yZWZwdHIuX19taW5nd19pbml0bHRzZHJvdF9mb3JjZQAucmRhdGEkLnJlZnB0ci5fX21pbmd3X2luaXRsdHNkeW5fZm9yY2UALnJkYXRhJC5yZWZwdHIuX19taW5nd19pbml0bHRzc3VvX2ZvcmNlAC5yZGF0YSQucmVmcHRyLl9faW1hZ2VfYmFzZV9fAC5yZGF0YSQucmVmcHRyLl9fbWluZ3dfYXBwX3R5cGUAbWFuYWdlZGFwcAAucmRhdGEkLnJlZnB0ci5fZm1vZGUALnJkYXRhJC5yZWZwdHIuX2NvbW1vZGUALnJkYXRhJC5yZWZwdHIuX01JTkdXX0lOU1RBTExfREVCVUdfTUFUSEVSUgAucmRhdGEkLnJlZnB0ci5fbWF0aGVycgBwcmVfY3BwX2luaXQALnJkYXRhJC5yZWZwdHIuX25ld21vZGUAc3RhcnRpbmZvAC5yZGF0YSQucmVmcHRyLl9kb3dpbGRjYXJkAF9fdG1haW5DUlRTdGFydHVwAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawAucmRhdGEkLnJlZnB0ci5fX25hdGl2ZV9zdGFydHVwX3N0YXRlAGhhc19jY3RvcgAucmRhdGEkLnJlZnB0ci5fX2R5bl90bHNfaW5pdF9jYWxsYmFjawAucmRhdGEkLnJlZnB0ci5fZ251X2V4Y2VwdGlvbl9oYW5kbGVyAC5yZGF0YSQucmVmcHRyLl9fbWluZ3dfb2xkZXhjcHRfaGFuZGxlcgAucmRhdGEkLnJlZnB0ci5fX2ltcF9fX3dpbml0ZW52AC5yZGF0YSQucmVmcHRyLl9feGNfegAucmRhdGEkLnJlZnB0ci5fX3hjX2EALnJkYXRhJC5yZWZwdHIuX194aV96AC5yZGF0YSQucmVmcHRyLl9feGlfYQBXaW5NYWluQ1JUU3RhcnR1cAAubF9zdGFydHcAbWFpbkNSVFN0YXJ0dXAALkNSVCRYQ0FBAC5DUlQkWElBQQAuZGVidWdfaW5mbwAuZGVidWdfYWJicmV2AC5kZWJ1Z19sb2NsaXN0cwAuZGVidWdfYXJhbmdlcwAuZGVidWdfcm5nbGlzdHMALmRlYnVnX2xpbmUALmRlYnVnX3N0cgAuZGVidWdfbGluZV9zdHIALnJkYXRhJHp6egAuZGVidWdfZnJhbWUAX19nY2NfcmVnaXN0ZXJfZnJhbWUAX19nY2NfZGVyZWdpc3Rlcl9mcmFtZQBfX2RvX2dsb2JhbF9kdG9ycwBfX2RvX2dsb2JhbF9jdG9ycwAucmRhdGEkLnJlZnB0ci5fX0NUT1JfTElTVF9fAGluaXRpYWxpemVkAF9fZHluX3Rsc19kdG9yAF9fZHluX3Rsc19pbml0AC5yZGF0YSQucmVmcHRyLl9DUlRfTVQAX190bHJlZ2R0b3IAX3dzZXRhcmd2AF9fcmVwb3J0X2Vycm9yAG1hcmtfc2VjdGlvbl93cml0YWJsZQBtYXhTZWN0aW9ucwBfcGVpMzg2X3J1bnRpbWVfcmVsb2NhdG9yAHdhc19pbml0LjAALnJkYXRhJC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAC5yZGF0YSQucmVmcHRyLl9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9fbWluZ3dfcmFpc2VfbWF0aGVycgBzdFVzZXJNYXRoRXJyAF9fbWluZ3dfc2V0dXNlcm1hdGhlcnIAX2dudV9leGNlcHRpb25faGFuZGxlcgBfX21pbmd3dGhyX3J1bl9rZXlfZHRvcnMucGFydC4wAF9fbWluZ3d0aHJfY3MAa2V5X2R0b3JfbGlzdABfX193NjRfbWluZ3d0aHJfYWRkX2tleV9kdG9yAF9fbWluZ3d0aHJfY3NfaW5pdABfX193NjRfbWluZ3d0aHJfcmVtb3ZlX2tleV9kdG9yAF9fbWluZ3dfVExTY2FsbGJhY2sAcHNldWRvLXJlbG9jLWxpc3QuYwBfVmFsaWRhdGVJbWFnZUJhc2UAX0ZpbmRQRVNlY3Rpb24AX0ZpbmRQRVNlY3Rpb25CeU5hbWUAX19taW5nd19HZXRTZWN0aW9uRm9yQWRkcmVzcwBfX21pbmd3X0dldFNlY3Rpb25Db3VudABfRmluZFBFU2VjdGlvbkV4ZWMAX0dldFBFSW1hZ2VCYXNlAF9Jc05vbndyaXRhYmxlSW5DdXJyZW50SW1hZ2UAX19taW5nd19lbnVtX2ltcG9ydF9saWJyYXJ5X25hbWVzAF9fbWluZ3dfdmZwcmludGYAX19taW5nd192c253cHJpbnRmAF9fcGZvcm1hdF9jdnQAX19wZm9ybWF0X3B1dGMAX19wZm9ybWF0X3dwdXRjaGFycwBfX3Bmb3JtYXRfcHV0Y2hhcnMAX19wZm9ybWF0X3B1dHMAX19wZm9ybWF0X2VtaXRfaW5mX29yX25hbgBfX3Bmb3JtYXRfeGludC5pc3JhLjAAX19wZm9ybWF0X2ludC5pc3JhLjAAX19wZm9ybWF0X2VtaXRfcmFkaXhfcG9pbnQAX19wZm9ybWF0X2VtaXRfZmxvYXQAX19wZm9ybWF0X2VtaXRfZWZsb2F0AF9fcGZvcm1hdF9lZmxvYXQAX19wZm9ybWF0X2Zsb2F0AF9fcGZvcm1hdF9nZmxvYXQAX19wZm9ybWF0X2VtaXRfeGZsb2F0LmlzcmEuMABfX21pbmd3X3Bmb3JtYXQAX19taW5nd193cGZvcm1hdABfX3J2X2FsbG9jX0QyQQBfX25ydl9hbGxvY19EMkEAX19mcmVlZHRvYQBfX3F1b3JlbV9EMkEALnJkYXRhJC5yZWZwdHIuX190ZW5zX0QyQQBfX3JzaGlmdF9EMkEAX190cmFpbHpfRDJBAGR0b2FfbG9jawBkdG9hX0NTX2luaXQAZHRvYV9Dcml0U2VjAGR0b2FfbG9ja19jbGVhbnVwAF9fQmFsbG9jX0QyQQBwcml2YXRlX21lbQBwbWVtX25leHQAX19CZnJlZV9EMkEAX19tdWx0YWRkX0QyQQBfX2kyYl9EMkEAX19tdWx0X0QyQQBfX3BvdzVtdWx0X0QyQQBfX2xzaGlmdF9EMkEAX19jbXBfRDJBAF9fZGlmZl9EMkEAX19iMmRfRDJBAF9fZDJiX0QyQQBfX3N0cmNwX0QyQQBfX3BfX2Ztb2RlAC5yZGF0YSQucmVmcHRyLl9faW1wX19mbW9kZQBfX3BfX2NvbW1vZGUALnJkYXRhJC5yZWZwdHIuX19pbXBfX2NvbW1vZGUAX2xvY2tfZmlsZQBfdW5sb2NrX2ZpbGUAbWluZ3dfZ2V0X2ludmFsaWRfcGFyYW1ldGVyX2hhbmRsZXIAX2dldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAG1pbmd3X3NldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAF9zZXRfaW52YWxpZF9wYXJhbWV0ZXJfaGFuZGxlcgBpbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyLmMAX19hY3J0X2lvYl9mdW5jAF9fd2NydG9tYl9jcAB3Y3NydG9tYnMAX19tYnJ0b3djX2NwAGludGVybmFsX21ic3RhdGUuMgBtYnNydG93Y3MAaW50ZXJuYWxfbWJzdGF0ZS4xAHNfbWJzdGF0ZS4wAHJlZ2lzdGVyX2ZyYW1lX2N0b3IALnRleHQuc3RhcnR1cAAueGRhdGEuc3RhcnR1cAAucGRhdGEuc3RhcnR1cAAuY3RvcnMuNjU1MzUAX19fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAE1hcFZpZXdPZkZpbGUAX19pbXBfYWJvcnQAX19saWI2NF9saWJrZXJuZWwzMl9hX2luYW1lAF9fZGF0YV9zdGFydF9fAF9fX0RUT1JfTElTVF9fAF9faW1wX19mbW9kZQBfX2ltcF9fX19tYl9jdXJfbWF4X2Z1bmMAX19pbXBfX2xvY2sASXNEQkNTTGVhZEJ5dGVFeABTZXRVbmhhbmRsZWRFeGNlcHRpb25GaWx0ZXIAX2hlYWRfbGliNjRfbGlibXN2Y3J0X2RlZl9hAC5yZWZwdHIuX19taW5nd19pbml0bHRzZHJvdF9mb3JjZQBfX2ltcF9HZXRFeGl0Q29kZVByb2Nlc3MAX19pbXBfQ3JlYXRlRmlsZVcAX19pbXBfY2FsbG9jAF9faW1wX19fcF9fZm1vZGUAX19fdGxzX3N0YXJ0X18ALnJlZnB0ci5fX25hdGl2ZV9zdGFydHVwX3N0YXRlAEdldEZpbGVTaXplAEdldExhc3RFcnJvcgBfX3J0X3BzcmVsb2NzX3N0YXJ0AF9fZGxsX2NoYXJhY3RlcmlzdGljc19fAF9fc2l6ZV9vZl9zdGFja19jb21taXRfXwBfX21pbmd3X21vZHVsZV9pc19kbGwAX19pb2JfZnVuYwBfX3NpemVfb2Zfc3RhY2tfcmVzZXJ2ZV9fAF9fbWFqb3Jfc3Vic3lzdGVtX3ZlcnNpb25fXwBfX19jcnRfeGxfc3RhcnRfXwBfX2ltcF9EZWxldGVDcml0aWNhbFNlY3Rpb24AX19pbXBfX3NldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAC5yZWZwdHIuX19DVE9SX0xJU1RfXwBfX2ltcF9mcHV0YwBWaXJ0dWFsUXVlcnkAX19fY3J0X3hpX3N0YXJ0X18ALnJlZnB0ci5fX2ltcF9fZm1vZGUAX19pbXBfX2Ftc2dfZXhpdABfX19jcnRfeGlfZW5kX18AX19pbXBfX2Vycm5vAF9faW1wX0NyZWF0ZUZpbGVNYXBwaW5nVwBfdGxzX3N0YXJ0AF9faW1wX0NyZWF0ZVByb2Nlc3NXAEdldE1vZHVsZUZpbGVOYW1lVwAucmVmcHRyLl9tYXRoZXJyAC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AX19pbXBfZmdldHdzAF9fbWluZ3dfb2xkZXhjcHRfaGFuZGxlcgBfX2ltcF9fdW5sb2NrX2ZpbGUAVGxzR2V0VmFsdWUAX19tc19md3ByaW50ZgBfX2Jzc19zdGFydF9fAF9faW1wX011bHRpQnl0ZVRvV2lkZUNoYXIAX19pbXBfX19DX3NwZWNpZmljX2hhbmRsZXIAX19fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX3NpemVfb2ZfaGVhcF9jb21taXRfXwBfX2ltcF9HZXRMYXN0RXJyb3IALnJlZnB0ci5fZG93aWxkY2FyZABfX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAF9faW1wX2ZyZWUAX19fbWJfY3VyX21heF9mdW5jAC5yZWZwdHIuX19taW5nd19hcHBfdHlwZQBfX21pbmd3X2luaXRsdHNzdW9fZm9yY2UAX190ZW5zX0QyQQBWaXJ0dWFsUHJvdGVjdABfX19jcnRfeHBfc3RhcnRfXwBfX2ltcF9MZWF2ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9SZWFkRmlsZQBfX0Nfc3BlY2lmaWNfaGFuZGxlcgBfX2ltcF9fd2ZvcGVuAC5yZWZwdHIuX19taW5nd19vbGRleGNwdF9oYW5kbGVyAC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAF9faW1wX19fbXNfZndwcmludGYAX19pbXBfd2NzY3B5AF9fX2NydF94cF9lbmRfXwBfX2ltcF9DbG9zZUhhbmRsZQBfX21pbm9yX29zX3ZlcnNpb25fXwBFbnRlckNyaXRpY2FsU2VjdGlvbgBfTUlOR1dfSU5TVEFMTF9ERUJVR19NQVRIRVJSAF9faW1wX0dldEZpbGVTaXplAC5yZWZwdHIuX194aV9hAC5yZWZwdHIuX0NSVF9NVABfX3NlY3Rpb25fYWxpZ25tZW50X18AX19uYXRpdmVfZGxsbWFpbl9yZWFzb24AX193Z2V0bWFpbmFyZ3MAX3Rsc191c2VkAF9faW1wX21lbXNldABfX0lBVF9lbmRfXwBfX2ltcF9fbG9ja19maWxlAF9faW1wX21lbWNweQBfX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfXwBfX2xpYjY0X2xpYm1zdmNydF9kZWZfYV9pbmFtZQBfX2ltcF9zdHJlcnJvcgAucmVmcHRyLl9uZXdtb2RlAF9fZGF0YV9lbmRfXwBfX2ltcF9md3JpdGUAX19DVE9SX0xJU1RfXwBfaGVhZF9saWI2NF9saWJrZXJuZWwzMl9hAF9fYnNzX2VuZF9fAF9fdGlueXRlbnNfRDJBAF9fbmF0aXZlX3ZjY2xyaXRfcmVhc29uAF9fX2NydF94Y19lbmRfXwAucmVmcHRyLl9fbWluZ3dfaW5pdGx0c3N1b19mb3JjZQAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawBfX2ltcF9FbnRlckNyaXRpY2FsU2VjdGlvbgBfdGxzX2luZGV4AF9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAX19fY3J0X3hjX3N0YXJ0X18AVW5tYXBWaWV3T2ZGaWxlAENyZWF0ZUZpbGVNYXBwaW5nVwBfX19DVE9SX0xJU1RfXwAucmVmcHRyLl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAF9faW1wX3NpZ25hbABHZXRFeGl0Q29kZVByb2Nlc3MALnJlZnB0ci5fX21pbmd3X2luaXRsdHNkeW5fZm9yY2UAX19ydF9wc3JlbG9jc19zaXplAF9faW1wX1dpZGVDaGFyVG9NdWx0aUJ5dGUAX19pbXBfVW5tYXBWaWV3T2ZGaWxlAF9faW1wX3N0cmxlbgBfX2JpZ3RlbnNfRDJBAF9faW1wX21hbGxvYwAucmVmcHRyLl9nbnVfZXhjZXB0aW9uX2hhbmRsZXIAX19pbXBfX193Z2V0bWFpbmFyZ3MAX19pbXBfTWFwVmlld09mRmlsZQBfX2ZpbGVfYWxpZ25tZW50X18AX19pbXBfSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbgBDbG9zZUhhbmRsZQBJbml0aWFsaXplQ3JpdGljYWxTZWN0aW9uAF9fX2xjX2NvZGVwYWdlX2Z1bmMAX19pbXBfZXhpdABfX2ltcF92ZnByaW50ZgBfX21ham9yX29zX3ZlcnNpb25fXwBfX21pbmd3X3BjaW5pdABfX2ltcF9Jc0RCQ1NMZWFkQnl0ZUV4AF9fSUFUX3N0YXJ0X18AX19pbXBfX2NleGl0AF9faW1wX1NldFVuaGFuZGxlZEV4Y2VwdGlvbkZpbHRlcgBfX2ltcF93Y3NyY2hyAF9faW1wX19vbmV4aXQAX19EVE9SX0xJU1RfXwBXaWRlQ2hhclRvTXVsdGlCeXRlAF9fc2V0X2FwcF90eXBlAF9faW1wX1NsZWVwAExlYXZlQ3JpdGljYWxTZWN0aW9uAF9faW1wX19fc2V0dXNlcm1hdGhlcnIAX19zaXplX29mX2hlYXBfcmVzZXJ2ZV9fAF9fX2NydF94dF9zdGFydF9fAF9fc3Vic3lzdGVtX18AX2Ftc2dfZXhpdABfX2ltcF9UbHNHZXRWYWx1ZQBfX3NldHVzZXJtYXRoZXJyAC5yZWZwdHIuX2NvbW1vZGUAX19pbXBfZnByaW50ZgBfX21pbmd3X3BjcHBpbml0AF9faW1wX19fcF9fY29tbW9kZQBNdWx0aUJ5dGVUb1dpZGVDaGFyAF9faW1wX0dldE1vZHVsZUZpbGVOYW1lVwBfX2ltcF9WaXJ0dWFsUHJvdGVjdABfX190bHNfZW5kX18AQ3JlYXRlUHJvY2Vzc1cAX19pbXBfVmlydHVhbFF1ZXJ5AF9faW1wX19pbml0dGVybQBfX2ltcF9mY2xvc2UAX19taW5nd19pbml0bHRzZHluX2ZvcmNlAF9kb3dpbGRjYXJkAF9faW1wX19faW9iX2Z1bmMAX19pbXBfbG9jYWxlY29udgBsb2NhbGVjb252AF9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZWZwdHIuX19pbWFnZV9iYXNlX18AX2luaXR0ZXJtAF9faW1wX1dhaXRGb3JTaW5nbGVPYmplY3QAX19pbXBfc3RybmNtcAAucmVmcHRyLl9mbW9kZQBfX2ltcF9fX2FjcnRfaW9iX2Z1bmMAX19tYWpvcl9pbWFnZV92ZXJzaW9uX18AV2FpdEZvclNpbmdsZU9iamVjdABfX2xvYWRlcl9mbGFnc19fAC5yZWZwdHIuX190ZW5zX0QyQQAucmVmcHRyLl9faW1wX19jb21tb2RlAF9fX2Noa3N0a19tcwBfX25hdGl2ZV9zdGFydHVwX2xvY2sAQ3JlYXRlRmlsZVcAX19pbXBfd2NzbGVuAF9faW1wX19fX2xjX2NvZGVwYWdlX2Z1bmMAX19ydF9wc3JlbG9jc19lbmQAX19pbXBfX2dldF9pbnZhbGlkX3BhcmFtZXRlcl9oYW5kbGVyAF9fbWlub3Jfc3Vic3lzdGVtX3ZlcnNpb25fXwBfX21pbm9yX2ltYWdlX3ZlcnNpb25fXwBfX2ltcF9fdW5sb2NrAF9faW1wX19fc2V0X2FwcF90eXBlAC5yZWZwdHIuX194Y19hAC5yZWZwdHIuX194aV96AC5yZWZwdHIuX01JTkdXX0lOU1RBTExfREVCVUdfTUFUSEVSUgBfX2ltcF9fY29tbW9kZQBEZWxldGVDcml0aWNhbFNlY3Rpb24AX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAF9faW1wX19fd2luaXRlbnYALnJlZnB0ci5fX2ltcF9fX3dpbml0ZW52AC5yZWZwdHIuX194Y196AF9fX2NydF94dF9lbmRfXwBfX2ltcF9mcHV0d2MAX19taW5nd19hcHBfdHlwZQA=
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
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gN1FgEiNVdBIjU2g232g6CTy///pP/7//4tF2EmLFqgED4VR/v//SIlVgN1FgEiNVdBIjU2g232g6Jry///pFf7//4tF2EmLFqgED4Xs/f//SIlVgN1FgEiNVdBIjU2g232g6FDz///p6/3//0iNVdC5JQAAAE2J5+ia3v//6Rv6//+F2w+Fvfr//0yNTcBMiZV4////RIldkIFN2AAQAABMiU2Ax0XAAAAAAOiXMgAATItNgEiNTb5BuBAAAABIi1AI6AAwAABEi12QTIuVeP///4XAfggPt1W+ZolV8A+2VgGJRexMiebpYfr//02F0g+E+f3///fD/f///w+FGwEAAEGLBkmNTghBiQKFwA+IZwIAAA+2VgFJic5MieZFMdLpKPr//4XbD4UZ+v//D7ZWAYFN2AABAABMiebpDfr//4XbD4X++f//D7ZWAYFN2AAIAABMiebp8vn//4nKSItFgGaB4v9/D4TuAQAAZoH6ADwPj/0AAABED7/CuQE8AABEKcFI0+gB0Y2RBMD//0jB6ANIicFMjUXQ6Hjz///ps/z//0mNdghNizZIjQVtSQAATYX2TA9E8ItF4IXAD4gpAQAASGPQTInx6AgpAABMjUXQTInxicLomt3//0mJ9k2J5+m1+P//g/sDD4cg+///uTAAAACD+wK4AwAAAA9E2Okj+f//TI1F0EiNFRxJAAAxyeif4P//6Tr8//8PtlYBRTHSTInmuwQAAADpHfn//02FwLgCwP//TInBD0XQ6VL///9MieZBuwMAAAC7BAAAAOn3+P//DICJRdjpPPv//4n4x0XgEAAAAIDMAolF2OnO+f//ZoXSD4TdAAAAidHpBP///2aQSA+/yemS+f//SIkR6b/7//+D6TAPtlYBTInmQYkK6aT4//8PtlYBx0XgAAAAAEyJ5kyNVeC7AgAAAOmI+P//SYsG6eH4//8PtlYCQbsFAAAASIPGArsEAAAA6Wj4//+IEelq+///TInx6JowAABMjUXQTInxicLodNz//+nV/v//SI1V0EiJwehj5f//6T77//9Jiw7pAfn//4B+AjQPheb5//8PtlYDQbsDAAAASIPGA7sEAAAA6Qv4//8PtlYCQbsDAAAASIPGArsEAAAA6fP3//9IhcC5Bfz//w9F0ekk/v//ZokR6eT6//9BiwbpNPj//4XbdSeBTdgA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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcAAADAAAAHitAAAAgAAAGAAAABCgYKBwoHiggKCQoJigoKAAkAAAOAAAAGCiaKJwonii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BwiuBgAAkAEAFa4GAADhCQAAEQkBAAABADkAAhADNwcUFAoAACZGbHRTYXZlADgHnAgAACZGbG9hdFNhdmUAOQecCAAAOrQIAAAQABWuBgAAJAoAABEJAQAAGQAWuQUAADQKAAARCQEAAA4AHEURVgoAABJOZXh0AEYRMIsKAAAScHJldgBHETCLCgAAABtfRVhDRVBUSU9OX1JFR0lTVFJBVElPTl9SRUNPUkQAEEQRFIsKAAAdNAoAAAAdkAoAAAgAB1YKAAAcSRG4CgAAEkhhbmRsZXIAShEcYAYAABJoYW5kbGVyAEsRHGAGAAAAHFwR4goAABJGaWJlckRhdGEAXREI2wUAABJWZXJzaW9uAF4RCHcFAAAAG19OVF9USUIAOFcRI3oLAAABRXhjZXB0aW9uTGlzdABYES6LCgAAAAFTdGFja0Jhc2UAWREN2wUAAAgBU3RhY2tMaW1pdABaEQ3bBQAAEAFTdWJTeXN0ZW1UaWIAWxEN2wUAABgduAoAACABQXJiaXRyYXJ5VXNlclBvaW50ZXIAYBEN2wUAACgBU2VsZgBhERd6CwAAMAAH4goAAApOVF9USUIAYhEH4goAAApQTlRfVElCAGMRFZ4LAAAHfwsAACdKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAXQEAAAOKExJ1DAAAAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQJKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAApQSU1BR0VfVExTX0NBTExCQUNLAFMgGpYMAAA7dQwAAAebDAAAPLAMAAAE2wUAAAR3BQAABNsFAAAAPXRhZ0NPSU5JVEJBU0UABwRdAQAACJUO6AwAAAJDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAnVkFSRU5VTQBdAQAACQkCBnIPAAACVlRfRU1QVFkAAAJWVF9OVUxMAAECVlRfSTIAAgJWVF9JNAADAlZUX1I0AAQCVlRfUjgABQJWVF9DWQAGAlZUX0RBVEUABwJWVF9CU1RSAAgCVlRfRElTUEFUQ0gACQJWVF9FUlJPUgAKAlZUX0JPT0wACwJWVF9WQVJJQU5UAAwCVlRfVU5LTk9XTgANAlZUX0RFQ0lNQUwADgJWVF9JMQAQAlZUX1VJMQARAlZUX1VJMgASAlZUX1VJNAATAlZUX0k4ABQCVlRfVUk4ABUCVlRfSU5UABYCVlRfVUlOVAAXAlZUX1ZPSUQAGAJWVF9IUkVTVUxUABkCVlRfUFRSABoCVlRfU0FGRUFSUkFZABsCVlRfQ0FSUkFZABwCVlRfVVNFUkRFRklORUQAHQJWVF9MUFNUUgAeAlZUX0xQV1NUUgAfAlZUX1JFQ09SRAAkAlZUX0lOVF9QVFIAJQJWVF9VSU5UX1BUUgAmAlZUX0ZJTEVUSU1FAEACVlRfQkxPQgBBAlZUX1NUUkVBTQBCAlZUX1NUT1JBR0UAQwJWVF9TVFJFQU1FRF9PQkpFQ1QARAJWVF9TVE9SRURfT0JKRUNUAEUCVlRfQkxPQl9PQkpFQ1QARgJWVF9DRgBHAlZUX0NMU0lEAEgCVlRfVkVSU0lPTkVEX1NUUkVBTQBJDlZUX0JTVFJfQkxPQgD/Dw5WVF9WRUNUT1IAABAOVlRfQVJSQVkAACAOVlRfQllSRUYAAEAOVlRfUkVTRVJWRUQAAIAOVlRfSUxMRUdBTAD//w5WVF9JTExFR0FMTUFTS0VEAP8PDlZUX1RZUEVNQVNLAP8PAD4QAAAABwRdAQAACoQQuA8AAAJfX3VuaW5pdGlhbGl6ZWQAAAJfX2luaXRpYWxpemluZwABAl9faW5pdGlhbGl6ZWQAAgAoEAAAAAqGBXIPAAAauA8AAAxfX25hdGl2ZV9zdGFydHVwX3N0YXRlAAqIK8QPAAAMX19uYXRpdmVfc3RhcnR1cF9sb2NrAAqJGQYQAAAHCxAAAD8MX19uYXRpdmVfZGxsbWFpbl9yZWFzb24ACosgbQEAAAhfUFZGVgALFBghBwAACF9QSUZWAAsVFw0HAABAAAAAABgLGBB9EAAAHl9maXJzdAAZfRAAAAAeX2xhc3QAGn0QAAAIHl9lbmQAG30QAAAQAAcsEAAAKAAAAAALHANIEAAAFjoQAACZEAAAKQAMX194aV9hAAEmJI4QAAAMX194aV96AAEnJI4QAAAWLBAAAMIQAAApAAxfX3hjX2EAASgktxAA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AAVYIxQBAAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAACBAdsb25nIHVuc2lnbmVkIGludAACAQh1bnNpZ25lZCBjaGFyAAIEBGZsb2F0AAIBBnNpZ25lZCBjaGFyAAICBXNob3J0IGludAACEARsb25nIGRvdWJsZQACCARkb3VibGUABdkBAAAMAgIEX0Zsb2F0MTYAAgIEX19iZjE2AAZKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MAYAEAAAKKExLCAgAAAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA10YWdDT0lOSVRCQVNFAAcEYAEAAAOVDvoCAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAABlZBUkVOVU0AYAEAAAQJAgaEBQAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQNWVF9CU1RSX0JMT0IA/w8DVlRfVkVDVE9SAAAQA1ZUX0FSUkFZAAAgA1ZUX0JZUkVGAABAA1ZUX1JFU0VSVkVEAACAA1ZUX0lMTEVHQUwA//8DVlRfSUxMRUdBTE1BU0tFRAD/DwNWVF9UWVBFTUFTSwD/DwAEZnVuY19wdHIAAQsQ1AEAAA6EBQAAoAUAAA8AB19fQ1RPUl9MSVNUX18ADJUFAAAHX19EVE9SX0xJU1RfXwANlQUAAAhpbml0aWFsaXplZAAyDE0BAAAJA6DAOqQCAAAAEGF0ZXhpdAAGqQEPTQEAAP8FAAAR1AEAAAASX19tYWluAAE1AfAZOqQCAAAAHwAAAAAAAAABnC4GAAATDxo6pAIAAAAuBgAAAAlfX2RvX2dsb2JhbF9jdG9ycwAgcBk6pAIAAAB6AAAAAAAAAAGcmAYAAApucHRycwAicAEAAFUDAABPAwAACmkAI3ABAABtAwAAaQMAABTGGTqkAgAAAOUFAAAVAVIJAyAZOqQCAAAAAAAJX19kb19nbG9iYWxfZHRvcnMAFCAZOqQCAAAAQwAAAAAAAAABnNYGAAAIcAAWFNYGAAAJAxCAOqQCAAAAAAWEBQAAAHkGAAAFAAEI/wUAAAhHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB10AgAAswIAAKEEAAACAQZjaGFyAAIIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAggFbG9uZyBsb25nIGludAACAgdzaG9ydCB1bnNpZ25lZCBpbnQAAgQFaW50AAIEBWxvbmcgaW50AAIEB3Vuc2lnbmVkIGludAAGPgEAAAIEB2xvbmcgdW5zaWduZWQgaW50AAIBCHVuc2lnbmVkIGNoYXIAAgQEZmxvYXQAAgEGc2lnbmVkIGNoYXIAAgIFc2hvcnQgaW50AAIQBGxvbmcgZG91YmxlAAIIBGRvdWJsZQACAgRfRmxvYXQxNgACAgRfX2JmMTYAB0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9GTEFHUwA+AQAAAYoTEp8CAAABSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABAUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcACXRhZ0NPSU5JVEJBU0UABwQ+AQAAApUO1wIAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAHVkFSRU5VTQA+AQAAAwkCBmEFAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJA1ZUX0JTVFJfQkxPQgD/DwNWVF9WRUNUT1IAABADVlRfQVJSQVkAACADVlRfQllSRUYAAEADVlRfUkVTRVJWRUQAAIADVlRfSUxMRUdBTAD//wNWVF9JTExFR0FMTUFTS0VEAP8PA1ZUX1RZUEVNQVNLAP8PAApRAAAABwQ+AQAABIQQpwUAAAFfX3VuaW5pdGlhbGl6ZWQAAAFfX2luaXRpYWxpemluZwABAV9faW5pdGlhbGl6ZWQAAgALUQAAAASGBWEFAAAGpwUAAARfX25hdGl2ZV9zdGFydHVwX3N0YXRlAIgrswUAAARfX25hdGl2ZV9zdGFydHVwX2xvY2sAiRnzBQAADAj5BQAADQRfX25hdGl2ZV9kbGxtYWluX3JlYXNvbgCLIE4BAAAEX19uYXRpdmVfdmNjbHJpdF9yZWFzb24AjCBOAQAABfoFAAALFwkDJIA6pAIAAAAFGQYAAAwXCQMggDqkAgAAAAW4BQAADSIJA7jAOqQCAAAABdYFAAAOEAkDsMA6pAIAAAAAPggAAAUAAQi1BgAAEkdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHZMDAACMAwAAEBo6pAIAAADDAAAAAAAAAPcEAAABAQZjaGFyAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAADdWludHB0cl90AAJLLPoAAAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAjyAAAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIAEwgDVUxPTkcAAxgddQEAAANXSU5CT09MAAN/DU0BAAADQk9PTAADgw9NAQAAA0RXT1JEAAONHXUBAAABBARmbG9hdAADTFBWT0lEAAOZEZsBAAABAQZzaWduZWQgY2hhcgABAgVzaG9ydCBpbnQAA1VMT05HX1BUUgAEMS76AAAABFBWT0lEAAsBEZsBAAAESEFORExFAJ8BEZsBAAAEVUxPTkdMT05HAPUBLvoAAAABEARsb25nIGRvdWJsZQABCARkb3VibGUACGkCAAAUAQIEX0Zsb2F0MTYAAQIEX19iZjE2ABVKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwRlAQAABYoTElQDAAAJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABCUpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQJSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcABFBJTUFHRV9UTFNfQ0FMTEJBQ0sAUyAadQMAAAxUAwAACHoDAAAWjwMAAAUcAgAABcgBAAAFHAIAAAAXX0lNQUdFX1RMU19ESVJFQ1RPUlk2NAAoBVUgFFIEAAAGU3RhcnRBZGRyZXNzT2ZSYXdEYXRhAFYgETkCAAAABkVuZEFkZHJlc3NPZlJhd0RhdGEAVyAROQIAAAgGQWRkcmVzc09mSW5kZXgAWCAROQIAABAGQWRkcmVzc09mQ2FsbEJhY2tzAFkgETkCAAAYBlNpemVPZlplcm9GaWxsAFogDcgBAAAgBkNoYXJhY3RlcmlzdGljcwBbIA3IAQAAJAAESU1BR0VfVExTX0RJUkVDVE9SWTY0AFwgB48DAAAESU1BR0VfVExTX0RJUkVDVE9SWQBvICNSBAAADHAEAAADX1BWRlYABhQYZAIAAAiRBAAAAl90bHNfaW5kZXgAIwedAQAACQPMwDqkAgAAAAJfdGxzX3N0YXJ0ACkZYAEAAAkDAAA7pAIAAAACX3Rsc19lbmQAKh1gAQAACQMIADukAgAAAAJfX3hsX2EALCtUAwAACQMo8DqkAgAAAAJfX3hsX3oALStUAwAACQNA8DqkAgAAAAJfdGxzX3VzZWQALxuMBAAACQPAkjqkAgAAAA1fX3hkX2EAP5EEAAAJA0jwOqQCAAAADV9feGRfegBAkQQAAAkDUPA6pAIAAAAYX0NSVF9NVAABRwxNAQAAAl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAGcbcAMAAAkDoJI6pAIAAAACX194bF9jAGgrVAMAAAkDMPA6pAIAAAACX194bF9kAKorVAMAAAkDOPA6pAIAAAACX19taW5nd19pbml0bHRzZHJvdF9mb3JjZQCtBU0BAAAJA8jAOqQCAAAAAl9fbWluZ3dfaW5pdGx0c2R5bl9mb3JjZQCuBU0BAAAJA8TAOqQCAAAAAl9fbWluZ3dfaW5pdGx0c3N1b19mb3JjZQCvBU0BAAAJA8DAOqQCAAAAGV9fbWluZ3dfVExTY2FsbGJhY2sAARkQqwEAAIcGAAAFKgIAAAXIAQAABd8BAAAAGl9fZHluX3Rsc19kdG9yAAGIAbsBAAAQGjqkAgAAADAAAAAAAAAAAZz4BgAACmkAAAAYKgIAAIgDAACEAwAACn8AAAAqyAEAAJoDAACWAwAACnQAAAA73wEAAKwDAACoAwAADjUaOqQCAAAAVwYAAAAbX190bHJlZ2R0b3IAAW0BTQEAANAaOqQCAAAAAwAAAAAAAAABnDIHAAAcZnVuYwABbRSRBAAAAVIAHV9fZHluX3Rsc19pbml0AAFMAbsBAAABhAcAAAtpAAAAGCoCAAALfwAAACrIAQAAC3QAAAA73wEAAA9wZnVuYwBOCp8EAAAPcHMATw0lAQAAAB4yBwAAQBo6pAIAAACCAAAAAAAAAAGcB04HAADCAwAAugMAAAdYBwAA6gMAAOIDAAAHYgcAABIEAAAKBAAAEGwHAAAQeQcAAB8yBwAAeBo6pAIAAAAAeBo6pAIAAAArAAAAAAAAAAFMATMIAAAHTgcAADYEAAAyBAAAB1gHAABHBAAARQQAAAdiBwAAUwQAAE8EAAARbAcAAGYEAABiBAAAEXkHAAB6BAAAdgQAAAAOtRo6pAIAAABXBgAAAADyAQAABQABCJwIAAADR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdfgQAAHcEAAALBgAAAQEGY2hhcgABCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAEIBWxvbmcgbG9uZyBpbnQAAQIHc2hvcnQgdW5zaWduZWQgaW50AAEEBWludAABBAVsb25nIGludAABBAd1bnNpZ25lZCBpbnQAAQQHbG9uZyB1bnNpZ25lZCBpbnQAAQEIdW5zaWduZWQgY2hhcgAEX1BWRlYAAQgYggEAAAUIiAEAAAYHdAEAAJkBAAAI6gAAAAAAAl9feGlfYQAKiQEAAAkDEPA6pAIAAAACX194aV96AAuJAQAACQMg8DqkAgAAAAJfX3hjX2EADIkBAAAJAwDwOqQCAAAAAl9feGNfegANiQEAAAkDCPA6pAIAAAAACQEAAAUAAQj9CAAAAUdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHRUFAAAOBQAARQYAAAJfX21pbmd3X2FwcF90eXBlAAEIBQUBAAAJA9DAOqQCAAAAAwQFaW50AADEFwAABQABCCsJAAAnR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdtAUAAPcFAADgGjqkAgAAAD0FAAAAAAAAfwYAAAZfX2dudWNfdmFfbGlzdAACGB0JAQAAKAhfX2J1aWx0aW5fdmFfbGlzdAAhAQAABwEGY2hhcgApIQEAAAZ2YV9saXN0AAIfGvIAAAAGc2l6ZV90AAMjLE0BAAAHCAdsb25nIGxvbmcgdW5zaWduZWQgaW50AAcIBWxvbmcgbG9uZyBpbnQABnB0cmRpZmZfdAADWCNnAQAABwIHc2hvcnQgdW5zaWduZWQgaW50AAcEBWludAAHBAVsb25nIGludAAJIQEAAAcEB3Vuc2lnbmVkIGludAAHBAdsb25nIHVuc2lnbmVkIGludAAHAQh1bnNpZ25lZCBjaGFyACoIBlVMT05HAAQYHcgBAAAGV0lOQk9PTAAEfw2gAQAABkJZVEUABIsZ3QEAAAZXT1JEAASMGooBAAAGRFdPUkQABI0dyAEAAAcEBGZsb2F0AAZQQllURQAEkBFNAgAACQ4CAAAGTFBCWVRFAASREU0CAAAGUERXT1JEAASXEnACAAAJKAIAAAZMUFZPSUQABJkR7gEAAAZMUENWT0lEAAScF5QCAAAJmQIAACsHAQZzaWduZWQgY2hhcgAHAgVzaG9ydCBpbnQABlVMT05HX1BUUgAFMS5NAQAABlNJWkVfVAAFkye2AgAAD1BWT0lEAAsBEe4BAAAPTE9ORwApARSnAQAABxAEbG9uZyBkb3VibGUABwgEZG91YmxlAAcCBF9GbG9hdDE2AAcCBF9fYmYxNgAeSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTALgBAAAGihMS8wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAVX01FTU9SWV9CQVNJQ19JTkZPUk1BVElPTgAw8xW1BAAAAkJhc2VBZGRyZXNzAPQVDdcCAAAAAkFsbG9jYXRpb25CYXNlAPUVDdcCAAAIAkFsbG9jYXRpb25Qcm90ZWN0APYVDSgCAAAQAlBhcnRpdGlvbklkAPgVDBsCAAAUAlJlZ2lvblNpemUA+hUOyAIAABgCU3RhdGUA+xUNKAIAACACUHJvdGVjdAD8FQ0oAgAAJAJUeXBlAP0VDSgCAAAoAA9NRU1PUllfQkFTSUNfSU5GT1JNQVRJT04A/hUH8wMAAA9QTUVNT1JZX0JBU0lDX0lORk9STUFUSU9OAP4VIfgEAAAJ8wMAABYOAgAADQUAABdNAQAABwAVX0lNQUdFX0RPU19IRUFERVIAQPMbYQYAAAJlX21hZ2ljAPQbDBsCAAAAAmVfY2JscAD1GwwbAgAAAgJlX2NwAPYbDBsCAAAEAmVfY3JsYwD3GwwbAgAABgJlX2NwYXJoZHIA+BsMGwIAAAgCZV9taW5hbGxvYwD5GwwbAgAACgJlX21heGFsbG9jAPobDBsCAAAMAmVfc3MA+xsMGwIAAA4CZV9zcAD8GwwbAgAAEAJlX2NzdW0A/RsMGwIAABICZV9pcAD+GwwbAgAAFAJlX2NzAP8bDBsCAAAWAmVfbGZhcmxjAAAcDBsCAAAYAmVfb3ZubwABHAwbAgAAGgJlX3JlcwACHAxhBgAAHAJlX29lbWlkAAMcDBsCAAAkAmVfb2VtaW5mbwAEHAwbAgAAJgJlX3JlczIABRwMcQYAACgCZV9sZmFuZXcABhwM5QIAADwAFhsCAABxBgAAF00BAAADABYbAgAAgQYAABdNAQAACQAPSU1BR0VfRE9TX0hFQURFUgAHHAcNBQAALAQGgB0HzwYAAB9QaHlzaWNhbEFkZHJlc3MAgR0oAgAAH1ZpcnR1YWxTaXplAIIdKAIAAAAVX0lNQUdFX1NFQ1RJT05fSEVBREVSACh+HeIHAAACTmFtZQB/HQz9BAAAAAJNaXNjAIMdCZoGAAAIAlZpcnR1YWxBZGRyZXNzAIQdDSgCAAAMAlNpemVPZlJhd0RhdGEAhR0NKAIAABACUG9pbnRlclRvUmF3RGF0YQCGHQ0oAgAAFAJQb2ludGVyVG9SZWxvY2F0aW9ucwCHHQ0oAgAAGAJQb2ludGVyVG9MaW5lbnVtYmVycwCIHQ0oAgAAHAJOdW1iZXJPZlJlbG9jYXRpb25zAIkdDBsCAAAgAk51bWJlck9mTGluZW51bWJlcnMAih0MGwIAACICQ2hhcmFjdGVyaXN0aWNzAIsdDSgCAAAkAA9QSU1BR0VfU0VDVElPTl9IRUFERVIAjB0dAAgAAAnPBgAALXRhZ0NPSU5JVEJBU0UABwS4AQAAB5UOPQgAAAFDT0lOSVRCQVNFX01VTFRJVEhSRUFERUQAAAAeVkFSRU5VTQC4AQAACAkCBscKAAABVlRfRU1QVFkAAAFWVF9OVUxMAAEBVlRfSTIAAgFWVF9JNAADAVZUX1I0AAQBVlRfUjgABQFWVF9DWQAGAVZUX0RBVEUABwFWVF9CU1RSAAgBVlRfRElTUEFUQ0gACQFWVF9FUlJPUgAKAVZUX0JPT0wACwFWVF9WQVJJQU5UAAwBVlRfVU5LTk9XTgANAVZUX0RFQ0lNQUwADgFWVF9JMQAQAVZUX1VJMQARAVZUX1VJMgASAVZUX1VJNAATAVZUX0k4ABQBVlRfVUk4ABUBVlRfSU5UABYBVlRfVUlOVAAXAVZUX1ZPSUQAGAFWVF9IUkVTVUxUABkBVlRfUFRSABoBVlRfU0FGRUFSUkFZABsBVlRfQ0FSUkFZABwBVlRfVVNFUkRFRklORUQAHQFWVF9MUFNUUgAeAVZUX0xQV1NUUgAfAVZUX1JFQ09SRAAkAVZUX0lOVF9QVFIAJQFWVF9VSU5UX1BUUgAmAVZUX0ZJTEVUSU1FAEABVlRfQkxPQgBBAVZUX1NUUkVBTQBCAVZUX1NUT1JBR0UAQwFWVF9TVFJFQU1FRF9PQkpFQ1QARAFWVF9TVE9SRURfT0JKRUNUAEUBVlRfQkxPQl9PQkpFQ1QARgFWVF9DRgBHAVZUX0NMU0lEAEgBVlRfVkVSU0lPTkVEX1NUUkVBTQBJDlZUX0JTVFJfQkxPQgD/Dw5WVF9WRUNUT1IAABAOVlRfQVJSQVkAACAOVlRfQllSRUYAAEAOVlRfUkVTRVJWRUQAAIAOVlRfSUxMRUdBTAD//w5WVF9JTExFR0FMTUFTS0VEAP8PDlZUX1RZUEVNQVNLAP8PAC5faW9idWYAMAkhClcLAAAFX3B0cgAJJQuzAQAAAAVfY250AAkmCaABAAAIBV9iYXNlAAknC7MBAAAQBV9mbGFnAAkoCaABAAAYBV9maWxlAAkpCaABAAAcBV9jaGFyYnVmAAkqCaABAAAgBV9idWZzaXoACSsJoAEAACQFX3RtcGZuYW1lAAksC7MBAAAoAAZGSUxFAAkvGccKAAAYX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AMQ0hAQAAGF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwAyDSEBAAAYX19pbWFn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VFIABDEuCQEAAAdMT05HACkBFFYBAAAHSEFORExFAJ8BEZgBAAAPX0xJU1RfRU5UUlkAEHECElsCAAABRmxpbmsAcgIZWwIAAAABQmxpbmsAcwIZWwIAAAgACCcCAAAHTElTVF9FTlRSWQB0AgUnAgAAAhAEbG9uZyBkb3VibGUAAggEZG91YmxlAAICBF9GbG9hdDE2AAICBF9fYmYxNgAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAAcEYgEAAAWKExJ2AwAAC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9FTkFCTEUAAQtKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfTUFYX0JBTkRXSURUSAACC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9EU0NQX1RBRwAEC0pPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9WQUxJRF9GTEFHUwAHAA9fUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcAMNIjFG4EAAABVHlwZQDTIwyqAQAAAAFDcmVhdG9yQmFja1RyYWNlSW5kZXgA1CMMqgEAAAIBQ3JpdGljYWxTZWN0aW9uANUjJQwFAAAIAVByb2Nlc3NMb2Nrc0xpc3QA1iMSYAIAABABRW50cnlDb3VudADXIw23AQAAIAFDb250ZW50aW9uQ291bnQA2CMNtwEAACQBRmxhZ3MA2SMNtwEAACgBQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaADaIwyqAQAALAFTcGFyZVdPUkQA2yMMqgEAAC4AD19SVExfQ1JJVElDQUxfU0VDVElPTgAo7SMUDAUAAAFEZWJ1Z0luZm8A7iMjEQUAAAABTG9ja0NvdW50AO8jDAsCAAAIAVJlY3Vyc2lvbkNvdW50APAjDAsCAAAMAU93bmluZ1RocmVhZADxIw4YAgAAEAFMb2NrU2VtYXBob3JlAPIjDhgCAAAYAVNwaW5Db3VudADzIxH5AQAAIAAIbgQAAAdQUlRMX0NSSVRJQ0FMX1NFQ1RJT05fREVCVUcA3CMjNQUAAAh2AwAAB1JUTF9DUklUSUNBTF9TRUNUSU9OAPQjB24EAAAHUFJUTF9DUklUSUNBTF9TRUNUSU9OAPQjHQwFAAAEQ1JJVElDQUxfU0VDVElP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LWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB22CAAA/ggAALEOAAABX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAAcUAQAACQNhwTqkAgAAAAMBBmNoYXIAAV9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAAgUAQAACQNgwTqkAgAAAABMFQAABQABCMIPAAAfR05VIEMxNyAxMy13aW4zMiAtbTY0IC1tYXNtPWF0dCAtbW5vLW9taXQtbGVhZi1mcmFtZS1wb2ludGVyIC1tdHVuZT1nZW5lcmljIC1tYXJjaD14ODYtNjQgLWcgLU8yIC1mbm8tb21pdC1mcmFtZS1wb2ludGVyIC1mbm8tc3RhY2stcHJvdGVjdG9yIC1mbm8tc3RhY2stY2xhc2gtcHJvdGVjdGlvbiAtZmNmLXByb3RlY3Rpb249bm9uZSAtZm5vLVBJRQAdaAkAAKUJAADAIjqkAgAAAP4DAAAAAAAA6w4AAAUIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQABQEGY2hhcgAgDAEAAApzaXplX3QAAiMs8gAAAAUIBWxvbmcgbG9uZyBpbnQABQIHc2hvcnQgdW5zaWduZWQgaW50AAUEBWludAAFBAVsb25nIGludAAFBAd1bnNpZ25lZCBpbnQABQQHbG9uZyB1bnNpZ25lZCBpbnQABQEIdW5zaWduZWQgY2hhcgAhCApXSU5CT09MAAN/DU8BAAAKQllURQADixmHAQAACldPUkQAA4waOQEAAApEV09SRAADjR1yAQAABQQEZmxvYXQAClBCWVRFAAOQEekBAAAMqgEAAApMUFZPSUQAA5kRmAEAAAUBBnNpZ25lZCBjaGFyAAUCBXNob3J0IGludAAKVUxPTkdfUFRSAAQxLvIAAAAKRFdPUkRfUFRSAAS/JxkCAAAHTE9ORwApARRWAQAAB1VMT05HTE9ORwD1AS7yAAAABRAEbG9uZyBkb3VibGUABQgEZG91YmxlAAUCBF9GbG9hdDE2AAUCBF9fYmYxNgASqgEAAJsCAAAT8gAAAAcADl9JTUFHRV9ET1NfSEVBREVSAEDzG+8DAAABZV9tYWdpYwD0Gwy3AQAAAAFlX2NibHAA9RsMtwEAAAIBZV9jcAD2Gwy3AQAABAFlX2NybGMA9xsMtwEAAAYBZV9jcGFyaGRyAPgbDLcBAAAIAWVfbWluYWxsb2MA+RsMtwEAAAoBZV9tYXhhbGxvYwD6Gwy3AQAADAFlX3NzAPsbDLcBAAAOAWVfc3AA/BsMtwEAABABZV9jc3VtAP0bDLcBAAASAWVfaXAA/hsMtwEAABQBZV9jcwD/Gwy3AQAAFgFlX2xmYXJsYwAAHAy3AQAAGAFlX292bm8AARwMtwEAABoBZV9yZXMAAhwM7wMAABwBZV9vZW1pZAADHAy3AQAAJAFlX29lbWluZm8ABBwMtwEAACYBZV9yZXMyAAUcDP8DAAAoAWVfbGZhbmV3AAYcDD0CAAA8ABK3AQAA/wMAABPyAAAAAwAStwEAAA8EAAAT8gAAAAkAB0lNQUdFX0RPU19IRUFERVIABxwHmwIAAAdQSU1BR0VfRE9TX0hFQURFUgAHHBlCBAAADJsCAAAOX0lNQUdFX0ZJTEVfSEVBREVSABRiHP0EAAABTWFjaGluZQBjHAy3AQAAAAFOdW1iZXJPZlNlY3Rpb25zAGQcDLcBAAACD5oAAABlHA3EAQAABAFQb2ludGVyVG9TeW1ib2xUYWJsZQBmHA3EAQAACAFOdW1iZXJPZlN5bWJvbHMAZxwNxAEAAAwBU2l6ZU9mT3B0aW9uYWxIZWFkZXIAaBwMtwEAABAPsgAAAGkcDLcBAAASAAdJTUFHRV9GSUxFX0hFQURFUgBqHAdHBAAADl9JTUFHRV9EQVRBX0RJUkVDVE9SWQAInxxRBQAAD80AAACgHA3EAQAAAAFTaXplAKEcDcQBAAAEAAdJTUFHRV9EQVRBX0RJUkVDVE9SWQCiHAcXBQAAElEFAAB+BQAAE/IAAAAPAA5fSU1BR0VfT1BUSU9OQUxfSEVBREVSNjQA8NkcqwgAAAFNYWdpYwDaHAy3AQAAAAFNYWpvckxpbmtlclZlcnNpb24A2xwMqgEAAAIBTWlub3JMaW5rZXJWZXJzaW9uANwcDKoBAAADAVNpemVPZkNvZGUA3RwNxAEAAAQBU2l6ZU9mSW5pdGlhbGl6ZWREYXRhAN4cDcQBAAAIAVNpemVPZlVuaW5pdGlhbGl6ZWREYXRhAN8cDcQBAAAMAUFkZHJlc3NPZkVudHJ5UG9pbnQA4BwNxAEAABABQmFzZU9mQ29kZQDhHA3EAQAAFAFJbWFnZUJhc2UA4hwRSgIAABgBU2VjdGlvbkFsaWdubWVudADjHA3EAQAAIAFGaWxlQWxpZ25tZW50AOQcDcQBAAAkAU1ham9yT3BlcmF0aW5nU3lzdGVtVmVyc2lvbgDlHAy3AQAAKAFNaW5vck9wZXJhdGluZ1N5c3RlbVZlcnNpb24A5hwMtwEAACoBTWFqb3JJbWFnZVZlcnNpb24A5xwMtwEAACwBTWlub3JJbWFnZVZlcnNpb24A6BwMtwEAAC4BTWFqb3JTdWJzeXN0ZW1WZXJzaW9uAOkcDLcBAAAwAU1pbm9yU3Vic3lzdGVtVmVyc2lvbgDqHAy3AQAAMgFXaW4zMlZlcnNpb25WYWx1ZQDrHA3EAQAANAFTaXplT2ZJbWFnZQDsHA3EAQAAOAFTaXplT2ZIZWFkZXJzAO0cDcQBAAA8AUNoZWNrU3VtAO4cDcQBAABAAVN1YnN5c3RlbQDvHAy3AQAARAFEbGxDaGFyYWN0ZXJpc3RpY3MA8BwMtwEAAEYBU2l6ZU9mU3RhY2tSZXNlcnZlAPEcEUoCAABIAVNpemVPZlN0YWNrQ29tbWl0APIcEUoCAABQAVNpemVPZkhlYXBSZXNlcnZlAPMcEUoCAABYAVNpemVPZkhlYXBDb21taXQA9BwRSgIAAGABTG9hZGVyRmxhZ3MA9RwNxAEAAGgBTnVtYmVyT2ZSdmFBbmRTaXplcwD2HA3EAQAAbAFEYXRhRGlyZWN0b3J5APccHG4FAABwAAdJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HAd+BQAAB1BJTUFHRV9PUFRJT05BTF9IRUFERVI2NAD4HCDsCAAADH4FAAAHUElNQUdFX09QVElPTkFMX0hFQURFUgAFHSbLCAAAIl9JTUFHRV9OVF9IRUFERVJTNjQACAEFDx0UbwkAAAFTaWduYXR1cmUAEB0NxAEAAAABRmlsZUhlYWRlcgARHRn9BAAABAFPcHRpb25hbEhlYWRlcgASHR+rCAAAGAAHUElNQUdFX05UX0hF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b3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABQgCQk9PTACDDzsBAAACRFdPUkQAjR1eAQAAAQQEZmxvYXQAAkxQVk9JRACZEYQBAAABAQZzaWduZWQgY2hhcgABAgVzaG9ydCBpbnQABkhBTkRMRQADnwERhAEAAAEQBGxvbmcgZG91YmxlAAEIBGRvdWJsZQABAgRfRmxvYXQxNgABAgRfX2JmMTYAB0RsbEVudHJ5UG9pbnQAAQ0NhgEAABAnOqQCAAAABgAAAAAAAAABnANoRGxsSGFuZGxlAA0j0gEAAAFSA2R3UmVhc29uAA4OkgEAAAFRA2xwcmVzZXJ2ZWQADw6oAQAAAVgAAK0DAAAFAAEI6xIAAApHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2sCwAA8wsAACAnOqQCAAAASAAAAAAAAAABFQAABV9fZ251Y192YV9saXN0AAIYHQkBAAALCF9fYnVpbHRpbl92YV9saXN0ACEBAAABAQZjaGFyAAwhAQAABXZhX2xpc3QAAh8a8gAAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAYhAQAAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIADV9pb2J1ZgAwAyEKVQIAAAJfcHRyACULkgEAAAACX2NudAAmCX8BAAAIAl9iYXNlACcLkgEAABACX2ZsYWcAKAl/AQAAGAJfZmlsZQApCX8BAAAcAl9jaGFyYnVmACoJfwEAACACX2J1ZnNpegArCX8BAAAkAl90bXBmbmFtZQAsC5IBAAAoAAVGSUxFAAMvGc0BAAAIX3VubG9ja19maWxlAPYFfAIAAAN8AgAAAAZVAgAADl9fbWluZ3dfcGZvcm1hdAAEYg1/AQAAtwIAAAN/AQAAA7cCAAADfwEAAAO5AgAAAy4BAAAADwgGKQEAAAhfbG9ja19maWxlAPUF1gIAAAN8AgAAABBfX21pbmd3X3ZmcHJpbnRmAAExDX8BAAAgJzqkAgAAAEgAAAAAAAAAAZwHc3RyZWFtAB58AgAA6hAAAOQQAAAHZm10ADW5AgAAAxEAAP0QAAAHYXJndgBCLgEAABwRAAAWEQAAEXJldHZhbAABMxB/AQAANREAAC8RAAAJOyc6pAIAAAC+AgAAagMAAAQBUgJzAAAJUyc6pAIAAACBAgAAmwMAAAQBUgMKAGAEAVECcwAEAVgBMAQBWQJ0AAQCdyACdQAAEl0nOqQCAAAAYgIAAAQBUgJzAAAAACQxAAAFAAEI9hMAADtHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2aDAAA4AwAAHAnOqQCAAAAuyUAAAAAAACKFQAAD19fZ251Y192YV9saXN0AAMYHQkBAAA8CF9fYnVpbHRpbl92YV9saXN0ACEBAAATAQZjaGFyADEhAQAAD3ZhX2xpc3QAAx8a8gAAAA9zaXplX3QABCMsTQEAABMIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAEwgFbG9uZyBsb25nIGludAAPd2NoYXJfdAAEYhiNAQAAMXgBAAATAgdzaG9ydCB1bnNpZ25lZCBpbnQAEwQFaW50ABMEBWxvbmcgaW50ABQhAQAAI7YBAAAUeAEAACPAAQAAFKMBAAATBAd1bnNpZ25lZCBpbnQAEwQHbG9uZyB1bnNpZ25lZCBpbnQAJGxjb252AJgFLQqCBAAABGRlY2ltYWxfcG9pbnQABS4LtgEAAAAEdGhvdXNhbmRzX3NlcAAFLwu2AQAACARncm91cGluZwAFMAu2AQAAEARpbnRfY3Vycl9zeW1ib2wABTELtgEAABgEY3VycmVuY3lfc3ltYm9sAAUyC7YBAAAgBG1vbl9kZWNpbWFsX3BvaW50AAUzC7YBAAAoBG1vbl90aG91c2FuZHNfc2VwAAU0C7YBAAAwBG1vbl9ncm91cGluZwAFNQu2AQAAOARwb3NpdGl2ZV9zaWduAAU2C7YBAABABG5lZ2F0aXZlX3NpZ24ABTcLtgEAAEgEaW50X2ZyYWNfZGlnaXRzAAU4CiEBAABQBGZyYWNfZGlnaXRzAAU5CiEBAABRBHBfY3NfcHJlY2VkZXMABToKIQEAAFIEcF9zZXBfYnlfc3BhY2UABTsKIQEAAFMEbl9jc19wcmVjZWRlcwAFPAohAQAAVARuX3NlcF9ieV9zcGFjZQAFPQohAQAAVQRwX3NpZ25fcG9zbgAFPgohAQAAVgRuX3NpZ25fcG9zbgAFPwohAQAAVwRfV19kZWNpbWFsX3BvaW50AAVBDsABAABYBF9XX3Rob3VzYW5kc19zZXAABUIOwAEAAGAEX1dfaW50X2N1cnJfc3ltYm9sAAVDDsABAABoBF9XX2N1cnJlbmN5X3N5bWJvbAAFRA7AAQAAcARfV19tb25fZGVjaW1hbF9wb2ludAAFRQ7AAQAAeARfV19tb25fdGhvdXNhbmRzX3NlcAAFRg7AAQAAgARfV19wb3NpdGl2ZV9zaWduAAVHDsABAACIBF9XX25lZ2F0aXZlX3NpZ24ABUgOwAEAAJAAFPQBAAATAQh1bnNpZ25lZCBjaGFyACRfaW9idWYAMAYhCigFAAAEX3B0cgAGJQu2AQAAAARfY250AAYmCaMBAAAIBF9iYXNlAAYnC7YBAAAQBF9mbGFnAAYoCaMBAAAYBF9maWxlAAYpCaMBAAAcBF9jaGFyYnVmAAYqCaMBAAAgBF9idWZzaXoABisJowEAACQEX3RtcGZuYW1lAAYsC7YBAAAoAA9GSUxFAAYvGZgEAAATEARsb25nIGRvdWJsZQATAQZzaWduZWQgY2hhcgATAgVzaG9ydCBpbnQAD2ludDMyX3QABycOowEAAA91aW50MzJfdAAHKBTPAQAAD2ludDY0X3QABykmZwEAABMIBGRvdWJsZQATBARmbG9hdAAUiAEAABS2AQAAPScBAAAICJ8FEu8FAAAQX1djaGFyAAigBRPfAQAAABBfQnl0ZQAIoQUUjQEAAAQQX1N0YXRlAAihBRuNAQAABgA+JwEAAAiiBQWuBQAALW1ic3RhdGVfdAAIowUV7wUAADIIejIGAAAEbG93AAJ7FM8BAAAABGhpZ2gAAnsZzwEAAAQAM0QBAAAId18GAAAMeAACeAyRBQAADHZhbAACeRhNAQAADGxoAAJ8Bw8GAAAALkQBAAACfQUyBgAAMhCHvgYAAARsb3cAAogUzwEAAAAEaGlnaAACiBnPAQAABC9zaWduX2V4cG9uZW50AImjAQAAEEAvcmVzMQCKowEAABBQL3JlczAAi6MBAAAgYAAzAwEAABCE3wYAAAx4AAKGETUFAAAMbGgAAowHawYAAAAuAwEAAAKNBb4GAAAUKQEAACPrBgAAJF9fdEkxMjgAEAFdIhcHAAAEZGlnaXRzAAFeCxcHAAAAAByBBQAAJwcAAB9NAQAAAQAPX190STEyOAABXwP1BgAAPx0BAAAQAWEiVwcAAARkaWdpdHMzMgABYgxXBwAAAAAccAUAAGcHAAAfTQEAAAMALh0BAAABYwM3BwAAQF9fdUkxMjgAEAFlIaEHAAAMdDEyOAABZgsnBwAADHQxMjhfMgABZw1nBwAAAA9fX3VJMTI4AAFoA3MHAABBEAG7CbwIAAAMX19wZm9ybWF0X2xvbmdfdAABwBuqAQAADF9fcGZvcm1hdF9sbG9uZ190AAHBG2cBAAAMX19wZm9ybWF0X3Vsb25nX3QAAcIb3wEAAAxfX3Bmb3JtYXRfdWxsb25nX3QAAcMbTQEAAAxfX3Bmb3JtYXRfdXNob3J0X3QAAcQbjQEAAAxfX3Bmb3JtYXRfdWNoYXJfdAABxRuHBAAADF9fcGZvcm1hdF9zaG9ydF90AAHGG1MFAAAMX19wZm9ybWF0X2NoYXJfdAABxxtEBQAADF9fcGZvcm1hdF9wdHJfdAAByBu8CAAADF9fcGZvcm1hdF91MTI4X3QAAckboQcAAABCCA9fX3Bmb3JtYXRfaW50YXJnX3QAAcoDsQcAACXPAQAAAc0BRwkAAAdQRk9STUFUX0lOSVQAAAdQRk9STUFUX1NFVF9XSURUSAABB1BGT1JNQVRfR0VUX1BSRUNJU0lPTgACB1BGT1JNQVRfU0VUX1BSRUNJU0lPTgADB1BGT1JNQVRfRU5EAAQAD19fcGZvcm1hdF9zdGF0ZV90AAHWA9kIAAAlzwEAAAHZAfcJAAAHUEZPUk1BVF9MRU5HVEhfSU5UAAAHUEZPUk1BVF9MRU5HVEhfU0hPUlQAAQdQRk9STUFUX0xFTkdUSF9MT05HAAIHUEZPUk1BVF9MRU5HVEhfTExPTkcAAwdQRk9STUFUX0xFTkdUSF9MTE9ORzEyOAAEB1BGT1JNQVRfTEVOR1RIX0NIQVIABQAPX19wZm9ybWF0X2xlbmd0aF90AAHjA2EJAAA0MBcBCd4KAAAQZGVzdAABHgESvAgAAAAQZmxhZ3MAAR8BEqMBAAAIEHdpZHRoAAEgARKjAQAADEMxAQAAASEBEqMBAAAQEHJwbGVuAAEiARKjAQAAFBBycGNocgABIwESeAEAABgQdGhvdXNhbmRzX2Nocl9sZW4AASQBEqMBAAAcEHRob3VzYW5kc19jaHIAASUBEngBAAAgEGNvdW50AAEmARKjAQAAJBBxdW90YQABJwESowEAACgQZXhwbWluAAEoARKjAQAALAAtX19wZm9ybWF0X3QAASkBAxIKAAA0EA0EA0MLAAAQX19wZm9ybWF0X2ZwcmVnX21hbnRpc3NhAAEOBBpNAQAAABBfX3Bmb3JtYXRfZnByZWdfZXhwb25lbnQAAQ8EGlMFAAAIAEQQAQUECc4LAAAmX19wZm9ybWF0X2ZwcmVnX2RvdWJsZV90AAsEkQUAACZfX3Bmb3JtYXRfZnByZWdfbGRvdWJsZV90AAwENQUAAEXzCgAAJl9fcGZvcm1hdF9mcHJlZ19iaXRtYXAAEQTOCwAAJl9fcGZvcm1hdF9mcHJlZ19iaXRzABIE3wEAAAAcjQEAAN4LAAAfTQEAAAQALV9fcGZvcm1hdF9mcHJlZ190AAETBANDCwAAD1VMb25nAAk1F98BAAAlzwEAAAk7BvoMAAAHU1RSVE9HX1plcm8AAAdTVFJUT0dfTm9ybWFsAAEHU1RSVE9HX0Rlbm9ybWFsAAIHU1RSVE9HX0luZmluaXRlAAMHU1RSVE9HX05hTgAEB1NUUlRPR19OYU5iaXRzAAUHU1RSVE9HX05vTnVtYmVyAAYHU1RSVE9HX1JldG1hc2sABwdT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B14FAACINgAAhDYAAAdmBQAAmDYAAJQ2AAAJY006pAIAAACEAgAAAwFSAnMAAAAANBIAAAUAAQhnGgAAG0dOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHbAOAACpDgAAoE86pAIAAAATFgAAAAAAAJ49AAAHAQZjaGFyABFzaXplX3QAAyMsCQEAAAcIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQABwgFbG9uZyBsb25nIGludAAHAgdzaG9ydCB1bnNpZ25lZCBpbnQABwQFaW50AAcEBWxvbmcgaW50AAryAAAACkoBAAAHBAd1bnNpZ25lZCBpbnQABwQHbG9uZyB1bnNpZ25lZCBpbnQABwEIdW5zaWduZWQgY2hhcgAHEARsb25nIGRvdWJsZQARVUxvbmcABDUXdwEAABwHBGcBAAAEOwavAgAABVNUUlRPR19aZXJvAAAFU1RSVE9HX05vcm1hbAABBVNUUlRPR19EZW5vcm1hbAACBVNUUlRPR19JbmZpbml0ZQADBVNUUlRPR19OYU4ABAVTVFJUT0dfTmFOYml0cwAFBVNUUlRPR19Ob051bWJlcgAGBVNUUlRPR19SZXRtYXNrAAcFU1RSVE9HX05lZwAIBVNUUlRPR19JbmV4bG8AEAVTVFJUT0dfSW5leGhpACAFU1RSVE9HX0luZXhhY3QAMAVTVFJUT0dfVW5kZXJmbG93AEAFU1RSVE9HX092ZXJmbG93AIAAHUZQSQAYBFABGQMAAAtuYml0cwBRSgEAAAALZW1pbgBSSgEAAAQLZW1heABTSgEAAAgLcm91bmRpbmcAVEoBAAAMC3N1ZGRlbl91bmRlcmZsb3cAVUoBAAAQC2ludF9tYXgAVkoBAAAUABFGUEkABFcDrwIAAAcIBGRvdWJsZQAUJQMAAAcEBGZsb2F0AApdAQAAHl9kYmxfdW5pb24ACAIZAQ9o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U1RfRU5UUlkAdAIFJwIAAAYQBGxvbmcgZG91YmxlABXyAAAACY4CAAAyBgIEX0Zsb2F0MTYABgIEX19iZjE2ADNKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRkxBR1MABwR7AQAAB4oTEnkDAAAaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0VOQUJMRQABGkpPQl9PQkpFQ1RfTkVUX1JBVEVfQ09OVFJPTF9NQVhfQkFORFdJRFRIAAIaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0RTQ1BfVEFHAAQaSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX1ZBTElEX0ZMQUdTAAcAH19SVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwAw0iMUegQAAARUeXBlAAfTIwyzAQAAAARDcmVhdG9yQmFja1RyYWNlSW5kZXgAB9QjDLMBAAACBENyaXRpY2FsU2VjdGlvbgAH1SMlHgUAAAgEUHJvY2Vzc0xvY2tzTGlzdAAH1iMSYgIAABAERW50cnlDb3VudAAH1yMNwAEAACAEQ29udGVudGlvbkNvdW50AAfYIw3AAQAAJARGbGFncwAH2SMNwAEAACgEQ3JlYXRvckJhY2tUcmFjZUluZGV4SGlnaAAH2iMMswEAACwEU3BhcmVXT1JEAAfbIwyzAQAALgAfX1JUTF9DUklUSUNBTF9TRUNUSU9OACjtIxQeBQAABERlYnVnSW5mbwAH7iMjIwUAAAAETG9ja0NvdW50AAfvIwwLAgAACARSZWN1cnNpb25Db3VudAAH8CMMCwIAAAwET3duaW5nVGhyZWFkAAfxIw4YAgAAEARMb2NrU2VtYXBob3JlAAfyIw4YAgAAGARTcGluQ291bnQAB/MjEfkBAAAgAAl6BAAAE1BSVExfQ1JJVElDQUxfU0VDVElPTl9ERUJVRwDcIyNHBQAACXkDAAATUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMHegQAABNQUlRMX0NSSVRJQ0FMX1NFQ1RJT04A9CMdHgUAAA5DUklUSUNBTF9TRUNUSU9OAAirIEwFAAAOTFBDUklUSUNBTF9TRUNUSU9OAAitIWkFAAANhwUAAMsFAAAPGAEAAAEAFmR0b2FfQ3JpdFNlYwA3GbsFAAAJAyDLOqQCAAAA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AC1tZW1zZXQAX19idWlsdGluX21lbXNldAAtbWVtY3B5AF9fYnVpbHRpbl9tZW1jcHkAAO4BAAAFAAEIQSMAAANHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB2HEQAAxhEAAPBzOqQCAAAAKAAAAAAAAAAVXwAAAQEGY2hhcgAE8gAAAAVzaXplX3QAAiMsDgEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAABAgdzaG9ydCB1bnNpZ25lZCBpbnQAAQQFaW50AAEEBWxvbmcgaW50AAEEB3Vuc2lnbmVkIGludAABBAdsb25nIHVuc2lnbmVkIGludAABAQh1bnNpZ25lZCBjaGFyAAZzdHJubGVuAAEEEP8AAADwczqkAgAAACgAAAAAAAAAAZzrAQAAAnMAJesBAAABUgJtYXhsZW4AL/8AAAABUQdzMgABBg/rAQAAkW4AAI1uAAAACAj6AAAAAAUCAAAFAAEIwyMAAARHTlUgQzE3IDEzLXdpbjMyIC1tNjQgLW1hc209YXR0IC1tbm8tb21pdC1sZWFmLWZyYW1lLXBvaW50ZXIgLW10dW5lPWdlbmVyaWMgLW1hcmNoPXg4Ni02NCAtZyAtTzIgLWZuby1vbWl0LWZyYW1lLXBvaW50ZXIgLWZuby1zdGFjay1wcm90ZWN0b3IgLWZuby1zdGFjay1jbGFzaC1wcm90ZWN0aW9uIC1mY2YtcHJvdGVjdGlvbj1ub25lIC1mbm8tUElFAB1HEgAAhhIAACB0OqQCAAAAJQAAAAAAAACWXwAAAQEGY2hhcgACc2l6ZV90ACMsCAEAAAEIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAQgFbG9uZyBsb25nIGludAACd2NoYXJfdABiGEcBAAAFMwEAAAECB3Nob3J0IHVuc2lnbmVkIGludAABBAVpbnQAAQQFbG9uZyBpbnQAAQQHdW5zaWduZWQgaW50AAEEB2xvbmcgdW5zaWduZWQgaW50AAEBCHVuc2lnbmVkIGNoYXIABndjc25sZW4AAQUB+gAAACB0OqQCAAAAJQAAAAAAAAABnAICAAADdwAYAgIAAK5uAACobgAAA25jbnQAIvoAAADSbgAAzG4AAAduAAEHCvoAAADmbgAA4m4AAAAICEIBAAAAlgsAAAUAAQhJJAAAFEdOVSBDMTcgMTMtd2luMzIgLW02NCAtbWFzbT1hdHQgLW1uby1vbWl0LWxlYWYtZnJhbWUtcG9pbnRlciAtbXR1bmU9Z2VuZXJpYyAtbWFyY2g9eDg2LTY0IC1nIC1PMiAtZm5vLW9taXQtZnJhbWUtcG9pbnRlciAtZm5vLXN0YWNrLXByb3RlY3RvciAtZm5vLXN0YWNrLWNsYXNoLXByb3RlY3Rpb24gLWZjZi1wcm90ZWN0aW9uPW5vbmUgLWZuby1QSUUAHQ4TAAAHEwAAUHQ6pAIAAADZAAAAAAAAAC5gAAADAQZjaGFyAAMIB2xvbmcgbG9uZyB1bnNpZ25lZCBpbnQAAwgFbG9uZyBsb25nIGludAADAgdzaG9ydCB1bnNpZ25lZCBpbnQAAwQFaW50AAMEBWxvbmcgaW50AAryAAAAAwQHdW5zaWduZWQgaW50AAMEB2xvbmcgdW5zaWduZWQgaW50AAMBCHVuc2lnbmVkIGNoYXIAFV9pb2J1ZgAwAiEKGQIAAARfcHRyAAIlC04BAAAABF9jbnQAAiYJOwEAAAgEX2Jhc2UAAicLTgEAABAEX2ZsYWcAAigJOwEAABgEX2ZpbGUAAikJOwEAABwEX2NoYXJidWYAAioJOwEAACAEX2J1ZnNpegACKwk7AQAAJARfdG1wZm5hbWUAAiwLTgEAACgAB0ZJTEUAAi8ZiQEAAAdXT1JEAAOMGiUBAAAHRFdPUkQAA40dYwEAAAMEBGZsb2F0ABYIAwEGc2lnbmVkIGNoYXIAAwIFc2hvcnQgaW50AAdVTE9OR19QVFIABDEu+gAAAAhMT05HACkBFEIBAAAISEFORExFAJ8BEUoCAAAOX0xJU1RfRU5UUlkAEHECEsoCAAACRmxpbmsAcgIZygIAAAACQmxpbmsAcwIZygIAAAgACpYCAAAITElTVF9FTlRSWQB0AgWWAgAAAxAEbG9uZyBkb3VibGUAAwgEZG91YmxlAAMCBF9GbG9hdDE2AAMCBF9fYmYxNgAPSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX0ZMQUdTAFMBAAAFihMS4wMAAAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRU5BQkxFAAEBSk9CX09CSkVDVF9ORVRfUkFURV9DT05UUk9MX01BWF9CQU5EV0lEVEgAAgFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfRFNDUF9UQUcABAFKT0JfT0JKRUNUX05FVF9SQVRFX0NPTlRST0xfVkFMSURfRkxBR1MABwAOX1JUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHADDSIxTbBAAAAlR5cGUA0yMMJgIAAAACQ3JlYXRvckJhY2tUcmFjZUluZGV4ANQjDCYCAAACAkNyaXRpY2FsU2VjdGlvbgDVIyV5BQAACAJQcm9jZXNzTG9ja3NMaXN0ANYjEs8CAAAQAkVudHJ5Q291bnQA1yMNMwIAACACQ29udGVudGlvbkNvdW50ANgjDTMCAAAkAkZsYWdzANkjDTMCAAAoAkNyZWF0b3JCYWNrVHJhY2VJbmRleEhpZ2gA2iMMJgIAACwCU3BhcmVXT1JEANsjDCYCAAAuAA5fUlRMX0NSSVRJQ0FMX1NFQ1RJT04AKO0jFHkFAAACRGVidWdJbmZvAO4jI34FAAAAAkxvY2tDb3VudADvIwx6AgAACAJSZWN1cnNpb25Db3VudADwIwx6AgAADAJPd25pbmdUaHJlYWQA8SMOhwIAABACTG9ja1NlbWFwaG9yZQDyIw6HAgAAGAJTcGluQ291bnQA8yMRaAIAACAACtsEAAAIUFJUTF9DUklUSUNBTF9TRUNUSU9OX0RFQlVHANwjI6IFAAAK4wMAAAhSVExfQ1JJVElDQUxfU0VDVElPTgD0IwfbBAAACFBSVExfQ1JJVElDQUxfU0VDVElPTgD0Ix15BQAAB0NSSVRJQ0FMX1NFQ1RJT04ABqsgpwUAAAdMUENSSVRJQ0FMX1NFQ1RJT04ABq0hxAUAABd0YWdDT0lOSVRCQVNFAAcEUwEAAAeVDk4GAAABQ09JTklUQkFTRV9NVUxUSVRIUkVBREVEAAAAD1ZBUkVOVU0AUwEAAAgJAgbYCAAAAVZUX0VNUFRZAAABVlRfTlVMTAABAVZUX0kyAAIBVlRfSTQAAwFWVF9SNAAEAVZUX1I4AAUBVlRfQ1kABgFWVF9EQVRFAAcBVlRfQlNUUgAIAVZUX0RJU1BBVENIAAkBVlRfRVJST1IACgFWVF9CT09MAAsBVlRfVkFSSUFOVAAMAVZUX1VOS05PV04ADQFWVF9ERUNJTUFMAA4BVlRfSTEAEAFWVF9VSTEAEQFWVF9VSTIAEgFWVF9VSTQAEwFWVF9JOAAUAVZUX1VJOAAVAVZUX0lOVAAWAVZUX1VJTlQAFwFWVF9WT0lEABgBVlRfSFJFU1VMVAAZAVZUX1BUUgAaAVZUX1NBRkVBUlJBWQAbAVZUX0NBUlJBWQAcAVZUX1VTRVJERUZJTkVEAB0BVlRfTFBTVFIAHgFWVF9MUFdTVFIAHwFWVF9SRUNPUkQAJAFWVF9JTlRfUFRSACUBVlRfVUlOVF9QVFIAJgFWVF9GSUxFVElNRQBAAVZUX0JMT0IAQQFWVF9TVFJFQU0AQgFWVF9TVE9SQUdFAEMBVlRfU1RSRUFNRURfT0JKRUNUAEQBVlRfU1RPUkVEX09CSkVDVABFAVZUX0JMT0JfT0JKRUNUAEYBVlRfQ0YARwFWVF9DTFNJRABIAVZUX1ZFUlNJT05FRF9TVFJFQU0ASQVWVF9CU1RSX0JMT0IA/w8FVlRfVkVDVE9SAAAQBVZUX0FSUkFZAAAgBVZUX0JZUkVGAABABVZUX1JFU0VSVkVEAACABVZUX0lMTEVHQUwA//8FVlRfSUxMRUdBTE1BU0tFRAD/DwVWVF9UWVBFTUFTSwD/DwAYWAlaC/sIAAAEZgAJWwoZAgAAAARsb2NrAAlcFuIFAAAwAAdfRklMRVgACV0F2AgAABBfX2ltcF9fbG9ja19maWxlADxKAgAACQN4gDqkAgAAABBfX2ltcF9fdW5sb2NrX2ZpbGUAZkoCAAAJA3CAOqQCAAAADExlYXZlQ3JpdGljYWxTZWN0aW9uAAosGnEJAAAL+wUAAAAMX3VubG9jawABEBaHCQAACzsBAAAADEVudGVyQ3JpdGljYWxTZWN0aW9uAAorGqoJAAAL+wUAAAAMX2xvY2sAAQ8WvgkAAAs7AQAAABlfX2FjcnRfaW9iX2Z1bmMAAl0X4AkAAOAJAAALUwEAAAAK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DiiEBUEOMIMGRA5wRQwGMAJMw0HEQcVCzEHGEgcDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAF9vbmV4aXRfdGFibGVfdABfX2VuYXRpdmVfc3RhcnR1cF9zdGF0ZQBoRGxsSGFuZGxlAGR3UmVhc29uAGxwcmVzZXJ2ZWQAbG9ja19mcmVlAF9fZW5hdGl2ZV9zdGFydHVwX3N0YXRlAGhEbGxIYW5kbGUAbHByZXNlcnZlZABkd1JlYXNvbgBzU2VjSW5mbwBwU2VjdGlvbgBUaW1lRGF0ZVN0YW1wAHBOVEhlYWRlcgBDaGFyYWN0ZXJpc3RpY3MAcEltYWdlQmFzZQBWaXJ0dWFsQWRkcmVzcwBpU2VjdGlvbgBpbnRsZW4Ac3RyZWFtAHZhbHVlAGV4cF93aWR0aABfX21pbmd3X2xkYmxfdHlwZV90AHN0YXRlAF9fdEkxMjhfMgBfTWJzdGF0ZXQAcHJlY2lzaW9uAGV4cG9uZW50AF9fbWluZ3dfZGJsX3R5cGVfdABzaWduAHNpZ25fYml0AF9fQmlnaW50AF9fQmlnaW50AF9fQmlnaW50AF9fQmlnaW50AGxhc3RfQ1NfaW5pdABieXRlX2J1Y2tldABfb25leGl0X3RhYmxlX3QAYnl0ZV9idWNrZXQAaW50ZXJuYWxfbWJzdGF0ZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2NydGRsbC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUvcHNka19pbmMAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9pbmNsdWRlAGNydGRsbC5jAGNydGRsbC5jAGludHJpbi1pbXBsLmgAd2lubnQuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHN0ZGxpYi5oAGNvbWJhc2VhcGkuaAB3dHlwZXMuaABpbnRlcm5hbC5oAGNvcmVjcnRfc3RhcnR1cC5oAHN5bmNoYXBpLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L2djY21haW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAGdjY21haW4uYwBnY2NtYWluLmMAd2lubnQuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAY29yZWNydC5oAHN0ZGxpYi5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9uYXRzdGFydC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvaW5jbHVkZQBuYXRzdGFydC5jAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAGludGVybmFsLmgAbmF0c3RhcnQuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L3Rsc3N1cC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB0bHNzdXAuYwB0bHNzdXAuYwBjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAY29yZWNydF9zdGFydHVwLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9jaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAY2luaXRleGUuYwBjaW5pdGV4ZS5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvbWluZ3dfaGVscGVycy5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAbWluZ3dfaGVscGVycy5jAG1pbmd3X2hlbHBlcnMuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcHNldWRvLXJlbG9jLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwc2V1ZG8tcmVsb2MuYwBwc2V1ZG8tcmVsb2MuYwB2YWRlZnMuaABjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAY29tYmFzZWFwaS5oAHd0eXBlcy5oAHN0ZGlvLmgAbWVtb3J5YXBpLmgAZXJyaGFuZGxpbmdhcGkuaABzdHJpbmcuaABzdGRsaWIuaAA8YnVpbHQtaW4+AC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvdGxzdGhyZC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB0bHN0aHJkLmMAdGxzdGhyZC5jAGNvcmVjcnQuaABtaW53aW5kZWYuaABiYXNldHNkLmgAd2lubnQuaABtaW53aW5iYXNlLmgAc3luY2hhcGkuaABzdGRsaWIuaABwcm9jZXNzdGhyZWFkc2FwaS5oAGVycmhhbmRsaW5nYXBpLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC90bHNtY3J0LmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydAB0bHNtY3J0LmMAdGxzbWNydC5jAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2NydC9wc2V1ZG8tcmVsb2MtbGlzdC5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AHBzZXVkby1yZWxvYy1saXN0LmMAcHNldWRvLXJlbG9jLWxpc3QuYwAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvcGVzZWN0LmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBwZXNlY3QuYwBwZXNlY3QuYwBjb3JlY3J0LmgAbWlud2luZGVmLmgAYmFzZXRzZC5oAHdpbm50LmgAc3RyaW5nLmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0L0NSVF9mcDEwLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQAQ1JUX2ZwMTAuYwBDUlRfZnAxMC5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9jcnQvZGxsZW50cnkuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvY3J0AC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZGxsZW50cnkuYwBkbGxlbnRyeS5jAG1pbndpbmRlZi5oAHdpbm50LmgAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfdmZwcmludGYuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWluZ3dfdmZwcmludGYuYwBtaW5nd192ZnByaW50Zi5jAHZhZGVmcy5oAHN0ZGlvLmgAbWluZ3dfcGZvcm1hdC5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL21pbmd3X3Bmb3JtYXQuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vLi4vZ2R0b2EAbWluZ3dfcGZvcm1hdC5jAG1pbmd3X3Bmb3JtYXQuYwBtYXRoLmgAdmFkZWZzLmgAY29yZWNydC5oAGxvY2FsZS5oAHN0ZGlvLmgAc3RkaW50LmgAd2NoYXIuaABnZHRvYS5oAHN0cmluZy5oAHN0ZGRlZi5oADxidWlsdC1pbj4AL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EvZG1pc2MuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAGRtaXNjLmMAZG1pc2MuYwBnZHRvYWltcC5oAGdkdG9hLmgAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hL2dkdG9hLmMAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2dkdG9hAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAZ2R0b2EuYwBnZHRvYS5jAGdkdG9haW1wLmgAY29yZWNydC5oAGdkdG9hLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9nbWlzYy5jAC9idWlsZAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvZ2R0b2EAZ21pc2MuYwBnbWlzYy5jAGdkdG9haW1wLmgAZ2R0b2EuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYS9taXNjLmMAL2J1aWxkAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9nZHRvYQAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlL3BzZGtfaW5jAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAbWlzYy5jAG1pc2MuYwBpbnRyaW4taW1wbC5oAGdkdG9haW1wLmgAY29yZWNydC5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABnZHRvYS5oAHN0ZGxpYi5oAHN5bmNoYXBpLmgAc3RyaW5nLmgAPGJ1aWx0LWluPgAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3N0cm5sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQBzdHJubGVuLmMAc3Rybmxlbi5jAGNvcmVjcnQuaAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djc25sZW4uYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L21pc2MAL3Vzci94ODZfNjQtdzY0LW1pbmd3MzIvaW5jbHVkZQB3Y3NubGVuLmMAd2Nzbmxlbi5jAGNvcmVjcnQuaAAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvc3RkaW8vbWluZ3dfbG9jay5jAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9zdGRpbwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L2luY2x1ZGUAbWluZ3dfbG9jay5jAG1pbmd3X2xvY2suYwBzdGRpby5oAG1pbndpbmRlZi5oAGJhc2V0c2QuaAB3aW5udC5oAG1pbndpbmJhc2UuaABjb21iYXNlYXBpLmgAd3R5cGVzLmgAaW50ZXJuYWwuaABzeW5jaGFwaS5oAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvL2FjcnRfaW9iX2Z1bmMuYwAvYnVpbGQAL2J1aWxkAC91c3Ivc3JjL21pbmd3LXc2NC0xMS4wLjEtM2J1aWxkMS9taW5ndy13NjQtY3J0L3N0ZGlvAC91c3IveDg2XzY0LXc2NC1taW5ndzMyL2luY2x1ZGUAYWNydF9pb2JfZnVuYy5jAGFjcnRfaW9iX2Z1bmMuYwBzdGRpby5oAC9idWlsZAAvdXNyL3NyYy9taW5ndy13NjQtMTEuMC4xLTNidWlsZDEvbWluZ3ctdzY0LWNydC9taXNjL3djcnRvbWIuYwAvYnVpbGQAL3Vzci9zcmMvbWluZ3ctdzY0LTExLjAuMS0zYnVpbGQxL21pbmd3LXc2NC1jcnQvbWlzYwAvdXNyL3g4Nl82NC13NjQtbWluZ3czMi9pbmNsdWRlAHdjcnRvbWIuYwB3Y3J0b21iLmMAY29yZWNydC5oAHdjaGFyLmgAbWlud2luZGVmLmgAd2lubnQuaABzdGRsaWIuaABtYl93Y19jb21tb24uaABzdHJpbmdhcGlzZXQuaAAvdXNyL3NyYy9taW5ndy13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AwAuaWRhdGEkNTACAAAIAAAAAwAuaWRhdGEkNNgAAAAIAAAAAwAuaWRhdGEkNkYEAAAIAAAAAwAudGV4dAAAADBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN4wFAAAIAAAAAwAuaWRhdGEkNTgCAAAIAAAAAwAuaWRhdGEkNOAAAAAIAAAAAwAuaWRhdGEkNlQEAAAIAAAAAwAudGV4dAAAADhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5AFAAAIAAAAAwAuaWRhdGEkNUACAAAIAAAAAwAuaWRhdGEkNOgAAAAIAAAAAwAuaWRhdGEkNl4EAAAIAAAAAwAudGV4dAAAAEBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5QFAAAIAAAAAwAuaWRhdGEkNUgCAAAIAAAAAwAuaWRhdGEkNPAAAAAIAAAAAwAuaWRhdGEkNmoEAAAIAAAAAwAudGV4dAAAAEhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5gFAAAIAAAAAwAuaWRhdGEkNVACAAAIAAAAAwAuaWRhdGEkNPgAAAAIAAAAAwAuaWRhdGEkNnIEAAAIAAAAAwAudGV4dAAAAFBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN5wFAAAIAAAAAwAuaWRhdGEkNVgCAAAIAAAAAwAuaWRhdGEkNAABAAAIAAAAAwAuaWRhdGEkNnwEAAAIAAAAAwAudGV4dAAAAFhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6AFAAAIAAAAAwAuaWRhdGEkNWACAAAIAAAAAwAuaWRhdGEkNAgBAAAIAAAAAwAuaWRhdGEkNoQEAAAIAAAAAwAudGV4dAAAAGBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6QFAAAIAAAAAwAuaWRhdGEkNWgCAAAIAAAAAwAuaWRhdGEkNBABAAAIAAAAAwAuaWRhdGEkNo4EAAAIAAAAAwAudGV4dAAAAGhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6gFAAAIAAAAAwAuaWRhdGEkNXACAAAIAAAAAwAuaWRhdGEkNBgBAAAIAAAAAwAuaWRhdGEkNpgEAAAIAAAAAwAudGV4dAAAAHBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN6wFAAAIAAAAAwAuaWRhdGEkNXgCAAAIAAAAAwAuaWRhdGEkNCABAAAIAAAAAwAuaWRhdGEkNqIEAAAIAAAAAwAudGV4dAAAAHhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7AFAAAIAAAAAwAuaWRhdGEkNYACAAAIAAAAAwAuaWRhdGEkNCgBAAAIAAAAAwAuaWRhdGEkNqoEAAAIAAAAAwAudGV4dAAAAIBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7QFAAAIAAAAAwAuaWRhdGEkNYgCAAAIAAAAAwAuaWRhdGEkNDABAAAIAAAAAwAuaWRhdGEkNrIEAAAIAAAAAwAudGV4dAAAAIhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7gFAAAIAAAAAwAuaWRhdGEkNZACAAAIAAAAAwAuaWRhdGEkNDgBAAAIAAAAAwAuaWRhdGEkNroEAAAIAAAAAwAudGV4dAAAAJBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN7wFAAAIAAAAAwAuaWRhdGEkNZgCAAAIAAAAAwAuaWRhdGEkNEABAAAIAAAAAwAuaWRhdGEkNsQEAAAIAAAAAwAudGV4dAAAAJhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8AFAAAIAAAAAwAuaWRhdGEkNaACAAAIAAAAAwAuaWRhdGEkNEgBAAAIAAAAAwAuaWRhdGEkNtIEAAAIAAAAAwAudGV4dAAAAKBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8QFAAAIAAAAAwAuaWRhdGEkNagCAAAIAAAAAwAuaWRhdGEkNFABAAAIAAAAAwAuaWRhdGEkNtwEAAAIAAAAAwAudGV4dAAAAKhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8gFAAAIAAAAAwAuaWRhdGEkNbACAAAIAAAAAwAuaWRhdGEkNFgBAAAIAAAAAwAuaWRhdGEkNuYEAAAIAAAAAwAudGV4dAAAALBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN8wFAAAIAAAAAwAuaWRhdGEkNbgCAAAIAAAAAwAuaWRhdGEkNGABAAAIAAAAAwAuaWRhdGEkNvAEAAAIAAAAAwAudGV4dAAAALhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9AFAAAIAAAAAwAuaWRhdGEkNcACAAAIAAAAAwAuaWRhdGEkNGgBAAAIAAAAAwAuaWRhdGEkNvoEAAAIAAAAAwAudGV4dAAAAMBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9QFAAAIAAAAAwAuaWRhdGEkNcgCAAAIAAAAAwAuaWRhdGEkNHABAAAIAAAAAwAuaWRhdGEkNgYFAAAIAAAAAwAudGV4dAAAAMhsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9gFAAAIAAAAAwAuaWRhdGEkNdACAAAIAAAAAwAuaWRhdGEkNHgBAAAIAAAAAwAuaWRhdGEkNhAFAAAIAAAAAwAudGV4dAAAANBsAAABAAAAAwAuZGF0YQAAALAAAAACAAAAAwAuYnNzAAAAAJALAAAGAAAAAwAuaWRhdGEkN9wFAAAIAAAAAwAuaWRhdGEkNdgCAAAIAAAAAwAuaWRhdGEkNIABAAAIAAAAAwAuaWRhdGEkNhoFAAAIAAAA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AgAAAAAA9RMAAAIAAAD//wAAAgAAAAAAERQAAHACAAAIAAAAAgAAAAAAHhQAAAAAAAD//wAAAgAAAAAANhQAAFACAAAIAAAAAgBfZXJybm8AADBsAAABACAAAgAAAAAARBQAAJAIAAADAAAAAgBzdHJsZW4AAMBsAAABACAAAgAAAAAAUxQAAMAIAAADAAAAAgAAAAAAYhQAAEBtAAABAAAAAgAAAAAAbhQAAFBtAAABAAAAAgAAAAAAhBQAAJAMAAADAAAAAgAAAAAAphQAAHgCAAAIAAAAAgBfdW5sb2NrAEhsAAABACAAAgAAAAAAshQAAKAIAAADAAAAAgAAAAAAwRQAAEgAAAAJAAAAAgB2ZnByaW50ZtBsAAABACAAAgBmcmVlAAAAAIBsAAABACAAAgAAAAAA0RQAANAAAAAGAAAAAgDiFAAALmRlYnVnX2FyYW5nZXMALmRlYnVnX2luZm8ALmRlYnVnX2FiYnJldgAuZGVidWdfbGluZQAuZGVidWdfZnJhbWUALmRlYnVnX3N0cgAuZGVidWdfbGluZV9zdHIALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19ybmdsaXN0cwBwcmVfY19pbml0AGF0ZXhpdF90YWJsZQBfQ1JUX0lOSVQAX19wcm9jX2F0dGFjaGVkAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawAucmRhdGEkLnJlZnB0ci5fX25hdGl2ZV9zdGFydHVwX3N0YXRlAC5yZGF0YSQucmVmcHRyLl9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZGF0YSQucmVmcHRyLl9feGlfegAucmRhdGEkLnJlZnB0ci5fX3hpX2EALnJkYXRhJC5yZWZwdHIuX194Y196AC5yZGF0YSQucmVmcHRyLl9feGNfYQBfX0RsbE1haW5DUlRTdGFydHVwAC5yZGF0YSQucmVmcHRyLl9fbmF0aXZlX2RsbG1haW5fcmVhc29uAERsbE1haW5DUlRTdGFydHVwAC5yZGF0YSQucmVmcHRyLl9fbWluZ3dfYXBwX3R5cGUALkNSVCRYSUFBAC5kZWJ1Z19pbmZvAC5kZWJ1Z19hYmJyZXYALmRlYnVnX2xvY2xpc3RzAC5kZWJ1Z19hcmFuZ2VzAC5kZWJ1Z19ybmdsaXN0cwAuZGVidWdfbGluZQAuZGVidWdfc3RyAC5kZWJ1Z19saW5lX3N0cgAucmRhdGEkenp6AC5kZWJ1Z19mcmFtZQBfX2djY19yZWdpc3Rlcl9mcmFtZQBfX2djY19kZXJlZ2lzdGVyX2ZyYW1lAHByb3h5X2luaXQAaW5pdGlhbGl6ZWQAZ19sb2NrUmVhZHkAcEdldFN0YXRlAGdfaW5pdExvY2sAcFNldFN0YXRlAFhJbnB1dEdldFN0YXRlAFhJbnB1dEdldENhcGFiaWxpdGllcwBYSW5wdXRTZXRTdGF0ZQBYSW5wdXRFbmFibGUAWElucHV0R2V0U3RhdGVFeABfX2RvX2dsb2JhbF9kdG9ycwBfX2RvX2dsb2JhbF9jdG9ycwAucmRhdGEkLnJlZnB0ci5fX0NUT1JfTElTVF9fAF9fZHluX3Rsc19kdG9yAF9fZHluX3Rsc19pbml0AC5yZGF0YSQucmVmcHRyLl9DUlRfTVQAX190bHJlZ2R0b3IAX19yZXBvcnRfZXJyb3IAbWFya19zZWN0aW9uX3dyaXRhYmxlAG1heFNlY3Rpb25zAF9wZWkzODZfcnVudGltZV9yZWxvY2F0b3IAd2FzX2luaXQuMAAucmRhdGEkLnJlZnB0ci5fX1JVTlRJTUVfUFNFVURPX1JFTE9DX0xJU1RfRU5EX18ALnJkYXRhJC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18ALnJkYXRhJC5yZWZwdHIuX19pbWFnZV9iYXNlX18AX19taW5nd3Rocl9ydW5fa2V5X2R0b3JzLnBhcnQuMABfX21pbmd3dGhyX2NzAGtleV9kdG9yX2xpc3QAX19fdzY0X21pbmd3dGhyX2FkZF9rZXlfZHRvcgBfX21pbmd3dGhyX2NzX2luaXQAX19fdzY0X21pbmd3dGhyX3JlbW92ZV9rZXlfZHRvcgBfX21pbmd3X1RMU2NhbGxiYWNrAHBzZXVkby1yZWxvYy1saXN0LmMAX1ZhbGlkYXRlSW1hZ2VCYXNlAF9GaW5kUEVTZWN0aW9uAF9GaW5kUEVTZWN0aW9uQnlOYW1lAF9fbWluZ3dfR2V0U2VjdGlvbkZvckFkZHJlc3MAX19taW5nd19HZXRTZWN0aW9uQ291bnQAX0ZpbmRQRVNlY3Rpb25FeGVjAF9HZXRQRUltYWdlQmFzZQBfSXNOb253cml0YWJsZUluQ3VycmVudEltYWdlAF9fbWluZ3dfZW51bV9pbXBvcnRfbGlicmFyeV9uYW1lcwBEbGxFbnRyeVBvaW50AF9fbWluZ3dfdmZwcmludGYAX19wZm9ybWF0X2N2dABfX3Bmb3JtYXRfcHV0YwBfX3Bmb3JtYXRfd3B1dGNoYXJzAF9fcGZvcm1hdF9wdXRjaGFycwBfX3Bmb3JtYXRfcHV0cwBfX3Bmb3JtYXRfZW1pdF9pbmZfb3JfbmFuAF9fcGZvcm1hdF94aW50LmlzcmEuMABfX3Bmb3JtYXRfaW50LmlzcmEuMABfX3Bmb3JtYXRfZW1pdF9yYWRpeF9wb2ludABfX3Bmb3JtYXRfZW1pdF9mbG9hdABfX3Bmb3JtYXRfZW1pdF9lZmxvYXQAX19wZm9ybWF0X2VmbG9hdABfX3Bmb3JtYXRfZmxvYXQAX19wZm9ybWF0X2dmbG9hdABfX3Bmb3JtYXRfZW1pdF94ZmxvYXQuaXNyYS4wAF9fbWluZ3dfcGZvcm1hdABfX3J2X2FsbG9jX0QyQQBfX25ydl9hbGxvY19EMkEAX19mcmVlZHRvYQBfX3F1b3JlbV9EMkEALnJkYXRhJC5yZWZwdHIuX190ZW5zX0QyQQBfX3JzaGlmdF9EMkEAX190cmFpbHpfRDJBAGR0b2FfbG9jawBkdG9hX0NTX2luaXQAZHRvYV9Dcml0U2VjAGR0b2FfbG9ja19jbGVhbnVwAF9fQmFsbG9jX0QyQQBwcml2YXRlX21lbQBwbWVtX25leHQAX19CZnJlZV9EMkEAX19tdWx0YWRkX0QyQQBfX2kyYl9EMkEAX19tdWx0X0QyQQBfX3BvdzVtdWx0X0QyQQBfX2xzaGlmdF9EMkEAX19jbXBfRDJBAF9fZGlmZl9EMkEAX19iMmRfRDJBAF9fZDJiX0QyQQBfX3N0cmNwX0QyQQBfbG9ja19maWxlAF91bmxvY2tfZmlsZQBfX2FjcnRfaW9iX2Z1bmMAX193Y3J0b21iX2NwAHdjc3J0b21icwBfaW5pdGlhbGl6ZV9vbmV4aXRfdGFibGUAX3JlZ2lzdGVyX29uZXhpdF9mdW5jdGlvbgBfZXhlY3V0ZV9vbmV4aXRfdGFibGUAX19tYnJ0b3djX2NwAGludGVybmFsX21ic3RhdGUuMgBtYnNydG93Y3MAaW50ZXJuYWxfbWJzdGF0ZS4xAHNfbWJzdGF0ZS4wAHJlZ2lzdGVyX2ZyYW1lX2N0b3IALnRleHQuc3RhcnR1cAAueGRhdGEuc3RhcnR1cAAucGRhdGEuc3RhcnR1cAAuY3RvcnMuNjU1MzUAX19fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9faW1wX2Fib3J0AF9fbGliNjRfbGlia2VybmVsMzJfYV9pbmFtZQBfX2RhdGFfc3RhcnRfXwBfX19EVE9SX0xJU1RfXwBfX2ltcF9fX19tYl9jdXJfbWF4X2Z1bmMAX19pbXBfX2xvY2sASXNEQkNTTGVhZEJ5dGVFeABfaGVhZF9saWI2NF9saWJtc3ZjcnRfZGVmX2EAX19pbXBfY2FsbG9jAF9faW1wX0xvYWRMaWJyYXJ5VwBfX190bHNfc3RhcnRfXwAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAR2V0TGFzdEVycm9yAF9fcnRfcHNyZWxvY3Nfc3RhcnQAX19kbGxfY2hhcmFjdGVyaXN0aWNzX18AX19zaXplX29mX3N0YWNrX2NvbW1pdF9fAF9fbWluZ3dfbW9kdWxlX2lzX2RsbABfX2lvYl9mdW5jAF9fc2l6ZV9vZl9zdGFja19yZXNlcnZlX18AX19tYWpvcl9zdWJzeXN0ZW1fdmVyc2lvbl9fAF9fX2NydF94bF9zdGFydF9fAF9faW1wX0RlbGV0ZUNyaXRpY2FsU2VjdGlvbgAucmVmcHRyLl9fQ1RPUl9MSVNUX18AX19pbXBfZnB1dGMAVmlydHVhbFF1ZXJ5AF9fX2NydF94aV9zdGFydF9fAF9faW1wX19hbXNnX2V4aXQAX19fY3J0X3hpX2VuZF9fAF9faW1wX19lcnJubwBfdGxzX3N0YXJ0AC5yZWZwdHIuX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX18AX19pbXBfX3VubG9ja19maWxlAFRsc0dldFZhbHVlAF9fYnNzX3N0YXJ0X18AX19pbXBfTXVsdGlCeXRlVG9XaWRlQ2hhcgBfX19SVU5USU1FX1BTRVVET19SRUxPQ19MSVNUX0VORF9fAF9fc2l6ZV9vZl9oZWFwX2NvbW1pdF9fAF9faW1wX0dldExhc3RFcnJvcgBfX21pbmd3X2luaXRsdHNkcm90X2ZvcmNlAF9faW1wX2ZyZWUAX19fbWJfY3VyX21heF9mdW5jAC5yZWZwdHIuX19taW5nd19hcHBfdHlwZQBfX21pbmd3X2luaXRsdHNzdW9fZm9yY2UAX190ZW5zX0QyQQBWaXJ0dWFsUHJvdGVjdABfX19jcnRfeHBfc3RhcnRfXwBfX2ltcF9MZWF2ZUNyaXRpY2FsU2VjdGlvbgAucmVmcHRyLl9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX19jcnRfeHBfZW5kX18AX19taW5vcl9vc192ZXJzaW9uX18ARW50ZXJDcml0aWNhbFNlY3Rpb24ALnJlZnB0ci5fX3hpX2EALnJlZnB0ci5fQ1JUX01UAF9fc2VjdGlvbl9hbGlnbm1lbnRfXwBfX25hdGl2ZV9kbGxtYWluX3JlYXNvbgBfdGxzX3VzZWQAX19pbXBfbWVtc2V0AF9fSUFUX2VuZF9fAF9faW1wX19sb2NrX2ZpbGUAX19pbXBfbWVtY3B5AF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9fAF9fbGliNjRfbGlibXN2Y3J0X2RlZl9hX2luYW1lAF9faW1wX3N0cmVycm9yAF9fZGF0YV9lbmRfXwBfX2ltcF9md3JpdGUAX19DVE9SX0xJU1RfXwBfaGVhZF9saWI2NF9saWJrZXJuZWwzMl9hAF9fYnNzX2VuZF9fAF9fdGlueXRlbnNfRDJBAF9fbmF0aXZlX3ZjY2xyaXRfcmVhc29uAF9fX2NydF94Y19lbmRfXwAucmVmcHRyLl9fbmF0aXZlX3N0YXJ0dXBfbG9jawBfX2ltcF9FbnRlckNyaXRpY2FsU2VjdGlvbgBfdGxzX2luZGV4AF9fbmF0aXZlX3N0YXJ0dXBfc3RhdGUAX19fY3J0X3hjX3N0YXJ0X18AX19pbXBfR2V0UHJvY0FkZHJlc3MAX19fQ1RPUl9MSVNUX18ALnJlZnB0ci5fX2R5bl90bHNfaW5pdF9jYWxsYmFjawBfX2ltcF9fcmVnaXN0ZXJfb25leGl0X2Z1bmN0aW9uAF9fcnRfcHNyZWxvY3Nfc2l6ZQBfX2ltcF9XaWRlQ2hhclRvTXVsdGlCeXRlAF9faW1wX3N0cmxlbgBfX2JpZ3RlbnNfRDJBAF9faW1wX21hbGxvYwBfX2ZpbGVfYWxpZ25tZW50X18AX19pbXBfSW5pdGlhbGl6ZUNyaXRpY2FsU2VjdGlvbgBfX2ltcF9yZWFsbG9jAEluaXRpYWxpemVDcml0aWNhbFNlY3Rpb24AX19fbGNfY29kZXBhZ2VfZnVuYwBfX2ltcF92ZnByaW50ZgBfX21ham9yX29zX3ZlcnNpb25fXwBfX2ltcF9Jc0RCQ1NMZWFkQnl0ZUV4AF9fSUFUX3N0YXJ0X18ATG9hZExpYnJhcnlXAEdldFByb2NBZGRyZXNzAF9fRFRPUl9MSVNUX18AX19pbXBfX2luaXRpYWxpemVfb25leGl0X3RhYmxlAFdpZGVDaGFyVG9NdWx0aUJ5dGUAX19pbXBfU2xlZXAATGVhdmVDcml0aWNhbFNlY3Rpb24AX19zaXplX29mX2hlYXBfcmVzZXJ2ZV9fAF9fX2NydF94dF9zdGFydF9fAF9fc3Vic3lzdGVtX18AX2Ftc2dfZXhpdABfX2ltcF9UbHNHZXRWYWx1ZQBfX2ltcF9fZXhlY3V0ZV9vbmV4aXRfdGFibGUATXVsdGlCeXRlVG9XaWRlQ2hhcgBfX2ltcF9GcmVlTGlicmFyeQBfX2ltcF9WaXJ0dWFsUHJvdGVjdABfX190bHNfZW5kX18AX19pbXBfVmlydHVhbFF1ZXJ5AF9faW1wX19pbml0dGVybQBfX2ltcF9mY2xvc2UAX19taW5nd19pbml0bHRzZHluX2ZvcmNlAF9faW1wX19faW9iX2Z1bmMAX19pbXBfbG9jYWxlY29udgBsb2NhbGVjb252AF9fZHluX3Rsc19pbml0X2NhbGxiYWNrAC5yZWZwdHIuX19pbWFnZV9iYXNlX18AX2luaXR0ZXJtAF9faW1wX3N0cm5jbXAAX19pbXBfX19hY3J0X2lvYl9mdW5jAF9fbWFqb3JfaW1hZ2VfdmVyc2lvbl9fAF9fbG9hZGVyX2ZsYWdzX18ALnJlZnB0ci5fX3RlbnNfRDJBAF9fX2Noa3N0a19tcwBfX25hdGl2ZV9zdGFydHVwX2xvY2sALnJlZnB0ci5fX25hdGl2ZV9kbGxtYWluX3JlYXNvbgBfX2ltcF93Y3NsZW4AX19pbXBfX19fbGNfY29kZXBhZ2VfZnVuYwBfX3J0X3BzcmVsb2NzX2VuZABfX21pbm9yX3N1YnN5c3RlbV92ZXJzaW9uX18AX19pbXBfZmZsdXNoAF9fbWlub3JfaW1hZ2VfdmVyc2lvbl9fAF9faW1wX191bmxvY2sALnJlZnB0ci5fX3hjX2EALnJlZnB0ci5fX3hpX3oARnJlZUxpYnJhcnkARGVsZXRlQ3JpdGljYWxTZWN0aW9uAF9fUlVOVElNRV9QU0VVRE9fUkVMT0NfTElTVF9FTkRfXwBfX2ltcF9mb3BlbgAucmVmcHRyLl9feGNfegBfX19jcnRfeHRfZW5kX18AX19taW5nd19hcHBfdHlwZQA=
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

  # Pre-compute launcher strings to avoid subshell expansion issues inside the heredoc.
  local _launcher_wine_env=""
  if [[ -z "${real_proton_script}" ]]; then
    local _env_adds="$(get_wine_env_additions "${real_wine_path}")"
    local _bin_add="${_env_adds%%|*}"
    local _temp="${_env_adds#*|}"
    local _lib_add="${_temp%%|*}"
    local _loader_add="${_env_adds##*|}"
    _launcher_wine_env="export PATH=\"${_bin_add}:\${PATH}\"
export LD_LIBRARY_PATH=\"${_lib_add}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}\"
export WINELOADER=\"${_loader_add}\""
  fi

  local _launcher_overrides="dxgi=n"
  if [[ "${controller_mode}" == "true" || "${steam_deck}" == "true" ]]; then
    _launcher_overrides="dxgi=n;xinput1_3=n"
  fi
  if [[ "${wayland_cursor_fix}" == "true" ]]; then
    _launcher_overrides="${_launcher_overrides};winex11.drv="
  fi

  local _launcher_sdl_logic=""
  if [[ "${controller_mode}" == "true" || "${steam_deck}" == "true" ]]; then
    _launcher_sdl_logic="export SDL_JOYSTICK_HIDAPI=0
export SDL_JOYSTICK_HIDAPI_PS4=0
export SDL_JOYSTICK_HIDAPI_PS5=0
export SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1

_sdl_db=\"\"
for _db_path in \\
  \"\${HOME}/.local/share/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"\${HOME}/.config/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"/usr/share/SDL_GameControllerDB/gamecontrollerdb.txt\" \\
  \"/usr/local/share/SDL_GameControllerDB/gamecontrollerdb.txt\"; do
  if [[ -f \"\${_db_path}\" ]]; then _sdl_db=\"\${_db_path}\"; break; fi
done
[[ -n \"\${_sdl_db}\" ]] && export SDL_GAMECONTROLLERCONFIG_FILE=\"\${_sdl_db}\""
  fi

  local _launcher_sync_logic=""
  if [[ "${_is_proton}" == "true" ]]; then
    if [[ -c /dev/ntsync ]]; then
      _launcher_sync_logic="export WINE_NTSYNC=1"
    else
      _launcher_sync_logic="export WINEFSYNC=1"
    fi
  fi

  mkdir -p "$(dirname "${LAUNCHER_SCRIPT}")"

  local real_wineserver
  real_wineserver="$(dirname "${real_wine_path}")/wineserver"
  [[ ! -x "${real_wineserver}" ]] && real_wineserver="wineserver"

  local _steam_root="${HOME}/.steam/root"
  local _cand
  for _cand in "${HOME}/.local/share/Steam" "${HOME}/.steam/steam" "${HOME}/.steam/root" "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" "${HOME}/snap/steam/common/.local/share/Steam"; do
    if [[ -d "${_cand}" ]]; then _steam_root="${_cand}"; break; fi
  done

  # Part 1: setup-time values baked in as plain strings.
  # We use a sed pipe to strip the 2-space indentation so the shebang is valid.
  sed 's/^  //' > "${LAUNCHER_SCRIPT}" << EOF
  #!/usr/bin/env bash
  # Cluckers Central launcher — generated by cluckers-setup.sh on $(date)
  # Re-run cluckers-setup.sh to regenerate after updating Wine or the game.

  # Exit on error, undefined variable, or pipe failure.
  set -euo pipefail

  # Legacy Steam environment variables required by ProtonFixes and some
  # networking components to correctly identify the game and user.
  export SteamAppId="813820"
  export SteamGameId="813820"
  export STEAM_COMPAT_APP_ID="813820"
  export SteamUser="${USER}"
  export SteamAppUser="${USER}"
  export SteamClientLaunch="1"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="${_steam_root}"
  export STEAM_COMPAT_DATA_PATH="${CLUCKERS_ROOT}"

  # Set PATH and LD_LIBRARY_PATH to include Wine's internal libraries and
  # binaries. Prepend them to any existing paths.
  ${_launcher_wine_env}

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

  # Force native overrides for performance and crash prevention.
  export WINEDLLOVERRIDES="${_launcher_overrides}"

  # SDL and controller configuration.
  ${_launcher_sdl_logic}

  # Wine binary and optional Proton script resolved by find_wine() at setup time.
  WINE="${real_wine_path}"
  WINESERVER="${real_wineserver}"
  PROTON_SCRIPT="${real_proton_script}"

  # Sync primitives (ntsync/fsync).
  ${_launcher_sync_logic}

  # Ensure we run from the game directory for consistency.
  cd "${GAME_DIR}"

  # Gamescope PID (if used).
  _GS_PID=""    # PID of gamescope process group leader (gamescope path)
  _WINE_PID=""  # PID of wine process group leader (non-gamescope path)
EOF

  # Part 2: launch-time auth + game launch logic.
  # We also strip the indentation for the appended literal block.
  sed 's/^  //' >> "${LAUNCHER_SCRIPT}" << 'LAUNCHEOF'
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

# ---- Launch ---------------------------------------------------------------

# Prepare final command.
# If a Proton script is available, we use 'proton run' to launch the game.
# This ensures the game runs within the Steam Linux Runtime (pressure-vessel)
# container, which provides modern networking and crypto libraries (like GnuTLS)
# required by the Unreal Engine 3 ServerTravel match transition. Without it,
# the game may hang on the loading screen when entering a match.
if [[ -n "${PROTON_SCRIPT}" ]]; then
  # Prepare the launch command. We use 'env -u' to strip environment variables 
  # that conflict with Proton's internal management without unsetting them
  # globally, so they remain available for the cleanup section at the end.
  _launch_cmd=(env -u WINEPREFIX -u WINE -u LD_LIBRARY_PATH -u WINEFSYNC -u WINEESYNC "python3" "${PROTON_SCRIPT}" "run")
else
  _launch_cmd=("${WINE}")
fi
if [[ -s "${_bootstrap_tmp}" ]]; then
  _game_args=("${TOOLS_DIR}/shm_launcher.exe" "${_bootstrap_wine}" "${_shm_name}" "${_game_exe_wine}" "${_game_args[@]}")
else
  _game_args=("${_game_exe}" "${_game_args[@]}")
fi

if [[ "${USE_GAMESCOPE}" == "true" ]]; then
  # shellcheck disable=SC2086
  env DBUS_SESSION_BUS_ADDRESS=/dev/null ${GS_ARGS} -- "${_launch_cmd[@]}" "${_game_args[@]}" &
  _PID=$!
else
  "${_launch_cmd[@]}" "${_game_args[@]}" &
  _PID=$!
fi

# Pass termination signals to the child process so it can shut down gracefully.
#
# Arguments:
#   None.
#
# Returns:
#   Always 0.
_term() {
  trap '' INT TERM HUP
  if [[ -n "${_PID:-}" ]]; then
    kill -TERM "${_PID}" 2>/dev/null || true
    wait "${_PID}" 2>/dev/null || true
  fi
}
trap _term INT TERM HUP

# Wait for the game (or gamescope) to exit normally.
if [[ -n "${_PID:-}" ]]; then
  wait "${_PID}" 2>/dev/null || true
fi

# ---- Cleanup --------------------------------------------------------------
trap '' EXIT INT TERM HUP

# Graceful wineserver shutdown — terminates winedevice.exe, services.exe, 
# plugplay.exe and all Wine helpers for our specific prefix.
WINEPREFIX="${WINEPREFIX:-}" "${WINESERVER:-}" -k 2>/dev/null || true
# Wait for wineserver to fully stop so Steam doesn't see it as "Running".
WINEPREFIX="${WINEPREFIX:-}" "${WINESERVER:-}" -w 2>/dev/null || true

# Kill gamescope components explicitly by name as a fallback.
# These UI components can sometimes survive if gamescope crashed.
pkill -9 -x "gamescope-wl"    2>/dev/null || true
pkill -9 -f "gamescopereaper" 2>/dev/null || true

# Remove temp files created during this launcher session.
[[ -n "${_bootstrap_tmp:-}" ]] && rm -f "${_bootstrap_tmp}"
[[ -n "${_oidc_tmp:-}" ]] && rm -f "${_oidc_tmp}"

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
