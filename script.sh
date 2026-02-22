#!/usr/bin/env bash
# ==============================================================================
#  CLUCKERS CENTRAL — LINUX SETUP SCRIPT
#  Installs everything needed to run the Realm Royale launcher on Linux.
#
#  HOW TO USE:
#    chmod +x cluckers-setup.sh
#    ./cluckers-setup.sh              # Standard interactive install
#    ./cluckers-setup.sh -a           # Auto-install (skips the Gamescope prompt)
#    ./cluckers-setup.sh -v           # Verbose mode
#    ./cluckers-setup.sh -g           # Disable Gamescope (bare wine, for debugging)
#    ./cluckers-setup.sh -u           # Uninstall everything safely
#
# ==============================================================================

# EXPLANATION FOR NEW USERS:
# These settings ensure that if any command fails, the script stops immediately
# instead of continuing and potentially causing unintended system issues.
set -euo pipefail

# ==============================================================================
# ── GLOBALS & SETTINGS ────────────────────────────────────────────────────────
# ==============================================================================

# EXPLANATION FOR NEW USERS:
# WINEPREFIX acts as an isolated sandbox. It holds a self-contained, fake Windows
# environment just for this app, ensuring it won't interfere with your other programs.
readonly WINEPREFIX="${HOME}/.wine-cluckers"

readonly INSTALLER_URL="https://updater.realmhub.io/cluckers-central_1.1.68_x64-setup.exe"
readonly INSTALLER_PATH="/tmp/cluckers-central-setup.exe"
readonly LAUNCHER_SCRIPT="${HOME}/.local/bin/cluckers-central.sh"
readonly DESKTOP_FILE="${HOME}/.local/share/applications/cluckers-central.desktop"
readonly ICON_DIR="${HOME}/.local/share/icons"
readonly ICON_PATH="${ICON_DIR}/cluckers-central.png"
readonly APP_NAME="Cluckers Central"
readonly REALM_ROYALE_APPID="813820"

# Default Gamescope options (can be overridden by the user during setup)
readonly DEFAULT_GAMESCOPE_OPTS="gamescope -f --force-grab-cursor -W 1920 -H 1080 -r 240 --adaptive-sync --borderless -- %command%"

# Export Wine variables globally so subprocesses catch them securely.
export WINEPREFIX
export WINEARCH="win64"

# Colors for terminal output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ==============================================================================
# ── HELPER FUNCTIONS ──────────────────────────────────────────────────────────
# ==============================================================================

step_msg()   { printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BLUE}[STEP]${NC} ${GREEN}%s${NC}\n" "$1"; }
info_msg()   { printf "  ${CYAN}[INFO]${NC}  %s\n" "$1"; }
ok_msg()     { printf "  ${GREEN}[ OK ]${NC}  %s\n" "$1"; }
warn_msg()   { printf "  ${YELLOW}[WARN]${NC}  %s\n" "$1"; }
error_exit() { printf "\n${RED}[ERROR]${NC} %s\n\n" "$1" >&2; exit 1; }

command_exists() {
  command -v "$1" > /dev/null 2>&1
}

# EXPLANATION FOR NEW USERS:
# Winetricks is a helper tool that downloads missing Windows components (like
# libraries or fonts) into our sandbox. This function installs them only if needed.
install_winetricks_pkg() {
  local pkg="$1"
  local desc="$2"
  local log="${WINEPREFIX}/winetricks.log"

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

install_sys_deps() {
  local pkg_mgr="$1"
  local to_install=()
  
  if ! command_exists wine; then to_install+=("wine"); fi
  if ! command_exists winetricks; then to_install+=("winetricks"); fi
  if ! command_exists curl; then to_install+=("curl"); fi
  if ! command_exists python3; then to_install+=("python3"); fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    ok_msg "All required system tools are already installed."
    return
  fi

  info_msg "Missing required tools: ${to_install[*]}. Installing..."
  case "${pkg_mgr}" in
    apt)
      sudo dpkg --add-architecture i386
      sudo apt-get update -qq
      sudo apt-get install -y "${to_install[@]}" python3-pip wine32 wine64 libwine fonts-wine
      ;;
    pacman) sudo pacman -Sy --noconfirm "${to_install[@]}" python-pip wine-mono wine-gecko ;;
    dnf)    sudo dnf install -y "${to_install[@]}" python3-pip ;;
    zypper) sudo zypper install -y "${to_install[@]}" python3-pip ;;
  esac
}

# ==============================================================================
# ── UNINSTALL MODE ────────────────────────────────────────────────────────────
# ==============================================================================
run_uninstall() {
  step_msg "Uninstalling Cluckers Central..."

  if [[ -d "${WINEPREFIX}" && -n "${WINEPREFIX}" ]]; then
    info_msg "Trashing the Wine prefix sandbox (${WINEPREFIX})..."
    rm -rf "${WINEPREFIX}"
    ok_msg "Wine prefix deleted."
  fi

  if [[ -f "${LAUNCHER_SCRIPT}" ]]; then
    rm -f "${LAUNCHER_SCRIPT}"
    ok_msg "Launcher script deleted."
  fi

  if [[ -f "${DESKTOP_FILE}" ]]; then
    rm -f "${DESKTOP_FILE}"
    ok_msg "Desktop shortcut deleted."
  fi

  if [[ -f "${ICON_PATH}" ]]; then
    rm -f "${ICON_PATH}"
    ok_msg "Icon deleted."
  fi

  info_msg "Checking for Steam to clean up shortcuts..."
  local steam_root=""
  local candidate=""
  for candidate in "${HOME}/.steam/steam" "${HOME}/.local/share/Steam" "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -d "${candidate}" ]]; then
      steam_root="${candidate}"
      break
    fi
  done

  if [[ -n "${steam_root}" ]] && command_exists python3; then
    local userdata_dir="${steam_root}/userdata"
    local steam_user=""
    local _ts=""
    local name=""
    if [[ -d "${userdata_dir}" ]]; then
      while IFS=' ' read -r _ts name; do
        steam_user="${name}"
        break
      done < <(find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn)
    fi

    if [[ -n "${steam_user}" ]]; then
      info_msg "Cleaning Steam configuration for user ${steam_user}..."
      local user_config_dir="${userdata_dir}/${steam_user}/config"

      STEAM_ROOT="${steam_root}" \
      USER_CONFIG_DIR="${user_config_dir}" \
      LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
      REALM_APPID="${REALM_ROYALE_APPID}" \
      APP_NAME_ENV="${APP_NAME}" \
      python3 - << 'PYEOF'
import os, vdf, binascii, shutil

USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER = os.environ["LAUNCHER_ENV"]
REALM_APPID = os.environ["REALM_APPID"]
STEAM_ROOT = os.environ["STEAM_ROOT"]
APP_NAME = os.environ["APP_NAME_ENV"]

def compute_shortcut_id(exe, name):
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    unsigned_id = (crc | 0x80000000) & 0xFFFFFFFF
    return unsigned_id

unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
grid_appid = str(unsigned_id)
shortcut_appid = unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id

shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as f:
            shortcuts = vdf.binary_load(f)
        sc = shortcuts.get("shortcuts", {})
        keys_to_delete = [k for k, v in sc.items() if isinstance(v, dict) and LAUNCHER in v.get("Exe", v.get("exe", ""))]
        for k in keys_to_delete:
            del sc[k]
        with open(shortcuts_path, "wb") as f:
            vdf.binary_dump(shortcuts, f)
        print("  [\033[0;32m OK \033[0m] Removed Cluckers Central shortcut from Steam.")
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not clean shortcuts.vdf: {e}")

localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(localconfig_path, "r", encoding="utf-8", errors="replace") as f:
            lc = vdf.load(f)
        apps = lc.get("UserLocalConfigStore", {}).get("Software", {}).get("Valve", {}).get("Steam", {}).get("apps", {})
        if REALM_APPID in apps and "LaunchOptions" in apps[REALM_APPID]:
            del apps[REALM_APPID]["LaunchOptions"]
            with open(localconfig_path, "w", encoding="utf-8") as f:
                vdf.dump(lc, f, pretty=True)
            print("  [\033[0;32m OK \033[0m] Removed launch options from Realm Royale.")
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not clean localconfig.vdf: {e}")

config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8", errors="replace") as f:
            cfg = vdf.load(f)
        mapping = cfg.get("InstallConfigStore", {}).get("Software", {}).get("Valve", {}).get("Steam", {}).get("CompatToolMapping", {})
        
        if str(shortcut_appid) in mapping:
            del mapping[str(shortcut_appid)]
        if REALM_APPID in mapping:
            del mapping[REALM_APPID]
            
        with open(config_path, "w", encoding="utf-8") as f:
            vdf.dump(cfg, f, pretty=True)
        print("  [\033[0;32m OK \033[0m] Removed Proton compatibility mappings.")
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not clean config.vdf (Proton): {e}")

grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
for suffix in ["p.jpg", "p.png", ".jpg", ".png", "_hero.jpg", "_hero.png", "_logo.png"]:
    p = os.path.join(grid_dir, f"{grid_appid}{suffix}")
    if os.path.exists(p):
        os.remove(p)
print("  [\033[0;32m OK \033[0m] Removed custom grid artwork.")

PYEOF
    fi
  fi

  printf "\n${GREEN}Uninstall complete! Everything has been scrubbed clean.${NC}\n\n"
}

# ==============================================================================
# ── MAIN INSTALLATION SCRIPT ──────────────────────────────────────────────────
# ==============================================================================

main() {
  local verbose="false"
  local auto_mode="false"
  local no_gamescope="false"
  local final_gamescope_opts="${DEFAULT_GAMESCOPE_OPTS}"
  local arg=""

  # Parse operational flags
  for arg in "$@"; do
    case "${arg}" in
      --uninstall|-u)     run_uninstall; exit 0 ;;
      --verbose|-v)       verbose="true" ;;
      --auto|-a)          auto_mode="true" ;;
      --no-gamescope|-g)  no_gamescope="true" ;;
    esac
  done

  # Control Wine verbosity based on the flag
  if [[ "${verbose}" == "true" ]]; then
    export WINEDEBUG=""
  else
    export WINEDEBUG="-all"
  fi

  printf "\n"
  printf "${GREEN}╔══════════════════════════════════════════════════════╗${NC}\n"
  printf "${GREEN}║        Cluckers Central — Linux Setup Script         ║${NC}\n"
  printf "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n\n"

  # ── 1. DEPENDENCIES ──
  step_msg "Checking system tools..."
  local local_pkg_manager=""
  if command_exists apt; then local_pkg_manager="apt"
  elif command_exists pacman; then local_pkg_manager="pacman"
  elif command_exists dnf; then local_pkg_manager="dnf"
  elif command_exists zypper; then local_pkg_manager="zypper"
  else error_exit "Could not find a package manager (apt/pacman/dnf/zypper)."; fi

  install_sys_deps "${local_pkg_manager}"

  if ! python3 -c "import vdf" > /dev/null 2>&1; then
    info_msg "Installing Python 'vdf' library (for Steam config)..."
    python3 -m pip install --quiet --break-system-packages vdf 2>/dev/null \
      || python3 -m pip install --quiet --user vdf \
      || error_exit "Could not install Python 'vdf' library."
  fi

  # ── 2. GAMESCOPE CONFIGURATION PROMPT ──
  if [[ "${auto_mode}" == "false" ]]; then
    step_msg "Configure Gamescope Launch Options"
    printf "  Gamescope is a magic window manager that isolates the game to prevent\n"
    printf "  your mouse from escaping and breaking your aim on Linux.\n\n"
    printf "  ${YELLOW}Flag Explanations:${NC}\n"
    printf "    ${CYAN}-f${NC}                  : Run in Fullscreen mode\n"
    printf "    ${CYAN}--force-grab-cursor${NC} : Locks the mouse completely to the game (CRITICAL)\n"
    printf "    ${CYAN}-W 1920 -H 1080${NC}     : Target resolution (Change to match your monitor)\n"
    printf "    ${CYAN}-r 240${NC}              : Maximum frame rate cap (Change to your monitor's Hz)\n"
    printf "    ${CYAN}--adaptive-sync${NC}     : Enables FreeSync/G-Sync for smooth tearing-free gameplay\n"
    printf "    ${CYAN}--borderless${NC}        : Runs as a borderless window\n"
    printf "    ${CYAN}-- %%command%%${NC}        : Required separator (DO NOT REMOVE)\n\n"
    
    printf "  ${GREEN}Current Default Options:${NC}\n"
    printf "  %s\n\n" "${final_gamescope_opts}"
    
    local user_opts=""
    read -rp "  Enter new options (or press Enter to keep defaults): " user_opts
    if [[ -n "${user_opts}" ]]; then
      final_gamescope_opts="${user_opts}"
      ok_msg "Saved custom Gamescope options."
    else
      ok_msg "Keeping default Gamescope options."
    fi
  fi

  # ── 3. INITIALIZE WINE PREFIX ──
  step_msg "Setting up the magic sandbox (Wine Prefix)..."
  if [[ -f "${WINEPREFIX}/system.reg" ]]; then
    ok_msg "Sandbox already exists."
  else
    info_msg "Creating new sandbox (takes ~30 seconds)..."
    wineboot --init || true
    ok_msg "Sandbox created."
  fi

  # ── 4. INSTALL WEBVIEW2 ──
  step_msg "Installing WebView2 (UI drawing engine)..."
  local webview_exe=""
  local f=""
  while IFS= read -r -d '' f; do
    webview_exe="${f}"
    break
  done < <(find "${WINEPREFIX}/drive_c" -name "msedgewebview2.exe" -print0 2>/dev/null)

  if [[ -n "${webview_exe}" ]]; then
    ok_msg "WebView2 already installed."
  else
    local wv2_installer="/tmp/MicrosoftEdgeWebview2Setup.exe"
    if [[ ! -f "${wv2_installer}" ]]; then
      info_msg "Downloading WebView2 from Microsoft..."
      curl -fLS --progress-bar -o "${wv2_installer}" "https://go.microsoft.com/fwlink/p/?LinkId=2124703" \
        || warn_msg "Failed to download WebView2. UI might be blank."
    fi

    if [[ -f "${wv2_installer}" ]]; then
      info_msg "Pretending to be Windows 8.1 so it installs nicely..."
      winetricks -q win81
      info_msg "Installing WebView2..."
      
      if [[ "${verbose}" == "true" ]]; then
        wine "${wv2_installer}" /silent /install 2>&1 | tee "${WINEPREFIX}/webview2_install.log" || warn_msg "WebView2 install hiccuped."
      else
        wine "${wv2_installer}" /silent /install > /dev/null 2>&1 || warn_msg "WebView2 install hiccuped."
      fi

      info_msg "Putting translator back to Windows 10 mode..."
      winetricks -q win10
      
      # Explicitly stabilize the background server after a Windows version change
      wineserver -w || true
    fi
  fi

  # ── 5. INSTALL GAME DEPENDENCIES ──
  step_msg "Installing game background libraries (VC++ & DirectX)..."
  install_winetricks_pkg "vcrun2010" "Visual C++ 2010"
  install_winetricks_pkg "vcrun2012" "Visual C++ 2012"
  install_winetricks_pkg "vcrun2019" "Visual C++ 2019"
  install_winetricks_pkg "d3dx9"     "DirectX 9"

  local dxvk_dll="${WINEPREFIX}/drive_c/windows/system32/dxgi.dll"
  if [[ -f "${dxvk_dll}" ]]; then
    ok_msg "DXVK (fast graphics layer) already installed."
  else
    info_msg "Installing DXVK (fast graphics layer)..."
    winetricks -q dxvk || warn_msg "DXVK failed. Game will run, but maybe slower."
  fi

  # ── 6. DOWNLOAD & INSTALL CLUCKERS CENTRAL ──
  step_msg "Installing Cluckers Central..."
  if [[ ! -f "${INSTALLER_PATH}" ]]; then
    info_msg "Downloading launcher..."
    curl -fLS --progress-bar -o "${INSTALLER_PATH}" "${INSTALLER_URL}" \
      || error_exit "Download failed."
  fi

  info_msg "Running installer silently (this may take a minute or two)..."
  
  if [[ "${verbose}" == "true" ]]; then
    info_msg "Verbose mode is writing installer logs to: ${WINEPREFIX}/cluckers_install.log"
    wine "${INSTALLER_PATH}" /S 2>&1 | tee "${WINEPREFIX}/cluckers_install.log" || true
  else
    wine "${INSTALLER_PATH}" /S > /dev/null 2>&1 || true
  fi
  
  info_msg "Waiting for Wine to finish background extraction..."
  # Wait for all background NSIS payload processes to cleanly exit
  wineserver -w || true
  sleep 3

  info_msg "Querying Windows Registry to determine exact installation path..."
  local app_exe_linux=""
  local app_exe_wine=""
  
  local keys_to_check=(
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
    "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Cluckers Central"
    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\cluckers-central"
  )

  for key in "${keys_to_check[@]}"; do
    local reg_out=""
    # Try DisplayIcon (typically points to the main executable in NSIS)
    reg_out=$(wine reg query "${key}" /v DisplayIcon 2>/dev/null | grep -i 'REG_SZ' || true)
    
    if [[ -n "${reg_out}" ]]; then
      # Isolate the actual path, strip out potential icon indexes (,0) and protect against spaces/quotes
      app_exe_wine=$(echo "${reg_out}" | sed -E 's/.*REG_SZ[[:space:]]+//' | tr -d '\r')
      app_exe_wine="${app_exe_wine%%,*}"
      app_exe_wine="${app_exe_wine%\"*}"
      app_exe_wine="${app_exe_wine#*\"}"
      
      if [[ -n "${app_exe_wine}" ]]; then
        info_msg "Found Registry Entry: ${app_exe_wine}"
        break
      fi
    fi
  done

  if [[ -n "${app_exe_wine}" ]]; then
    # Use native winepath to mathematically translate the Windows path to a precise Linux path
    app_exe_linux=$(wine winepath -u "${app_exe_wine}" 2>/dev/null | tr -d '\r' || true)
  fi

  # Fallback to broad disk search if registry parsing somehow fails or returns an invalid path
  if [[ -z "${app_exe_linux}" || ! -f "${app_exe_linux}" ]]; then
    warn_msg "Registry query returned empty or invalid path. Falling back to disk search..."
    local match=""
    while IFS= read -r -d '' match; do
      # Avoid accidentally selecting the uninstaller executable
      if [[ ! "${match}" =~ [Uu]ninstall ]]; then
        app_exe_linux="${match}"
        break
      fi
    done < <(find "${WINEPREFIX}/drive_c" -type f -iname "*cluckers*.exe" -print0 2>/dev/null)
  fi

  if [[ -n "${app_exe_linux}" && -f "${app_exe_linux}" ]]; then
    ok_msg "Found executable at: ${app_exe_linux}"
  else
    error_exit "Could not locate the executable after installation. It may have failed to install. Please check logs in ${WINEPREFIX}"
  fi

  # ── 7. EXTRACT ICON ──
  step_msg "Setting up desktop icon..."
  mkdir -p "${ICON_DIR}"
  local final_icon_path="wine" 

  if command_exists wrestool && command_exists icotool; then
    if wrestool -x --type=14 "${app_exe_linux}" -o /tmp/cluckers.ico 2>/dev/null; then
      icotool -x -o "${ICON_DIR}" /tmp/cluckers.ico 2>/dev/null || true
      local best_icon=""
      local best_size=0
      local fsize
      local file_iter=""
      while IFS= read -r -d '' file_iter; do
        fsize=$(stat -c '%s' "${file_iter}" 2>/dev/null || printf '0')
        if (( fsize > best_size )); then
          best_size="${fsize}"
          best_icon="${file_iter}"
        fi
      done < <(find "${ICON_DIR}" -maxdepth 1 -name 'cluckers*.png' -print0 2>/dev/null)

      if [[ -n "${best_icon}" ]]; then
        cp "${best_icon}" "${ICON_PATH}"
        final_icon_path="${ICON_PATH}"
        ok_msg "Beautiful icon extracted."
      fi
    fi
  else
    warn_msg "icoutils not installed. Skipping custom icon extraction (will use default Wine icon)."
  fi

  # ── 8. CREATE WINELOADER WRAPPER ──
  # EXPLANATION FOR NEW USERS:
  # When Wine spawns a child Windows process (e.g. the game exe launched by the launcher),
  # it exec()s the binary pointed to by $WINELOADER, passing the exe path and all its
  # arguments as already-split argv[] elements. Special characters like & = | in private
  # server auth tokens are just bytes in argv — no shell ever touches them.
  #
  # This wrapper checks if Wine is being asked to run the game exe. If yes, it prepends
  # gamescope and exec()s with all original args passed through verbatim via "$@".
  # For any other Wine process (the launcher itself, etc.) it just runs real wine directly.
  #
  # This completely eliminates IFEO, VBScript, background watchers, temp files, and all
  # arg re-parsing — the root cause of every previous token corruption issue.
  step_msg "Configuring Gamescope via WINELOADER wrapper..."

  local real_wine_path=""
  real_wine_path=$(command -v wine) \
    || error_exit "Cannot locate wine binary to create WINELOADER wrapper."

  local wrapper_path="${WINEPREFIX}/wine-game-wrapper.sh"

  if [[ "${no_gamescope}" == "true" ]]; then
    info_msg "Gamescope disabled (-g flag). Creating pass-through wrapper."
  else
    ok_msg "Real wine binary: ${real_wine_path}"
  fi

  # ── 9. CREATE WRAPPER & SHORTCUT ──
  step_msg "Creating launcher scripts..."
  mkdir -p "$(dirname "${LAUNCHER_SCRIPT}")"

  # Part 1: Write variables into the launcher (these expand at setup time)
  cat <<EOF > "${LAUNCHER_SCRIPT}"
#!/usr/bin/env bash
export WINEPREFIX="${WINEPREFIX}"
export WINEDEBUG=-all
export GS_COMMAND_STR="${final_gamescope_opts}"
APP_EXE_LINUX="${app_exe_linux}"
WRAPPER_PATH="${wrapper_path}"
REAL_WINE="${real_wine_path}"
NO_GAMESCOPE="${no_gamescope}"
EOF

  # Part 2: Write the WINELOADER wrapper generator and launcher (static, no variable expansion)
  cat << 'LAUNCHEREOF' >> "${LAUNCHER_SCRIPT}"

# ── Generate the WINELOADER wrapper on every launch ──
# This allows GS_COMMAND_STR to be updated without re-running setup.
# The wrapper is tiny and only does complex work when the game exe is matched.
cat > "${WRAPPER_PATH}" << WRAPEOF
#!/usr/bin/env bash
# WINELOADER wrapper for Cluckers Central / Realm Royale
# Called by Wine for every Windows process it spawns.
#   \$1 = Windows exe path  (e.g. C:\path\ShippingPC-RealmGameNoEditor.exe)
#   \$2+ = exe arguments    (already correctly-split argv[] — & = tokens are safe)
WRAPEOF

# Bake real wine path and no-gamescope flag into wrapper (expand from launcher env)
cat >> "${WRAPPER_PATH}" << WRAPEOF2
_REAL_WINE="${REAL_WINE}"
_NO_GAMESCOPE="${NO_GAMESCOPE}"
_GS_OPTS="${GS_COMMAND_STR}"
WRAPEOF2

# Bake static wrapper logic (no variable expansion — quotes are literal)
cat >> "${WRAPPER_PATH}" << 'WRAPEOF3'

if [[ "$1" == *"ShippingPC-RealmGameNoEditor"* ]] && [[ "${_NO_GAMESCOPE}" != "true" ]]; then
  # ── GAME EXE: wrap in gamescope ──
  # Unset WINELOADER so gamescope's wine child doesn't recurse into this wrapper
  unset WINELOADER
  exec python3 -c '
import sys, os, shlex
real_wine = sys.argv[1]
game_args = sys.argv[2:]           # already correct argv[] elements — zero re-parsing
gs_str    = os.environ.get("_GS_OPTS", "")
if not gs_str:
    os.execvp(real_wine, [real_wine] + game_args)
gs_parts = shlex.split(gs_str)
if "%command%" in gs_parts:
    idx = gs_parts.index("%command%")
    cmd = gs_parts[:idx] + ["--", real_wine] + game_args + gs_parts[idx+1:]
else:
    cmd = gs_parts + ["--", real_wine] + game_args
# Write launch log for debugging: ~/.wine-cluckers/drive_c/launch_diff.log
wp = os.environ.get("WINEPREFIX", "")
if wp:
    try:
        with open(os.path.join(wp, "drive_c", "launch_diff.log"), "w") as lf:
            lf.write("ARGV FROM WINE (verbatim, no re-parsing):\n")
            for i, a in enumerate(game_args):
                lf.write(f"  [{i}] {repr(a)}\n")
            lf.write(f"\nFINAL CMD:\n{cmd}\n")
    except Exception:
        pass
os.execvp(cmd[0], cmd)
' "${_REAL_WINE}" "$@"
else
  # ── ALL OTHER PROCESSES: pass straight through ──
  exec "${_REAL_WINE}" "$@"
fi
WRAPEOF3

chmod +x "${WRAPPER_PATH}"

# Point Wine at our wrapper for all child process spawning
export WINELOADER="${WRAPPER_PATH}"

# Launch Cluckers Central — the launcher itself runs bare wine (no gamescope).
# When it launches the game, Wine will call our WINELOADER wrapper which intercepts
# only the game exe and wraps it in gamescope with all args passed through perfectly.
wine "${APP_EXE_LINUX}" "$@"

LAUNCHEREOF
  chmod +x "${LAUNCHER_SCRIPT}"

  mkdir -p "$(dirname "${DESKTOP_FILE}")"
  cat <<EOF > "${DESKTOP_FILE}"
[Desktop Entry]
Name=Cluckers Central
Comment=Launch Cluckers Central
Exec=${LAUNCHER_SCRIPT}
Icon=${final_icon_path}
Type=Application
Categories=Game;
EOF
  chmod +x "${DESKTOP_FILE}"
  command_exists update-desktop-database && update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  ok_msg "Smart Shortcuts created."
  
  # ── 10. DOWNLOAD CUSTOM ARTWORK ──
  step_msg "Downloading Steam artwork (Banners)..."
  mkdir -p "/tmp/cluckers_assets"
  info_msg "Downloading Grid cover..."
  curl -sS -L -o "/tmp/cluckers_assets/grid.jpg" "https://steamcdn-a.akamaihd.net/steam/apps/813820/library_600x900_2x.jpg" || true
  info_msg "Downloading Hero banner..."
  curl -sS -L -o "/tmp/cluckers_assets/hero.jpg" "https://steamcdn-a.akamaihd.net/steam/apps/813820/library_hero.jpg" || true
  info_msg "Downloading Logo..."
  curl -sS -L -o "/tmp/cluckers_assets/logo.png" "https://steamcdn-a.akamaihd.net/steam/apps/813820/logo.png" || true
  ok_msg "Artwork assets fetched."

  # ── 11. STEAM INTEGRATION ──
  step_msg "Configuring Steam..."
  local skip_steam="false"
  local steam_root=""
  local candidate=""
  for candidate in "${HOME}/.steam/steam" "${HOME}/.local/share/Steam" "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -d "${candidate}" ]]; then steam_root="${candidate}"; break; fi
  done

  if [[ -z "${steam_root}" ]]; then
    warn_msg "Steam not found. Skipping Steam integration."
    skip_steam="true"
  else
    if pgrep -x "steam" > /dev/null 2>&1; then
      printf "\n  ${RED}⚠ STEAM IS RUNNING!${NC}\n"
      printf "  Steam overwrites config files when it closes. Please close Steam now.\n"
      read -rp "  Close Steam, then press Enter to continue... "
      sleep 2
    fi

    local userdata_dir="${steam_root}/userdata"
    local steam_user=""
    local _ts=""
    local name=""
    if [[ -d "${userdata_dir}" ]]; then
      while IFS=' ' read -r _ts name; do
        steam_user="${name}"
        break
      done < <(find "${userdata_dir}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn)
    fi

    if [[ -z "${steam_user}" ]]; then
      warn_msg "No logged-in Steam user found. Skipping Steam integration."
      skip_steam="true"
    else
      local user_config_dir="${userdata_dir}/${steam_user}/config"
      STEAM_ROOT="${steam_root}" \
      USER_CONFIG_DIR="${user_config_dir}" \
      LAUNCHER_ENV="${LAUNCHER_SCRIPT}" \
      ICON_PATH_ENV="${final_icon_path}" \
      REALM_APPID="${REALM_ROYALE_APPID}" \
      APP_NAME_ENV="${APP_NAME}" \
      GAMESCOPE_OPTS_ENV="${final_gamescope_opts}" \
      VERBOSE_ENV="${verbose}" \
      python3 - << 'PYEOF'
import os
import shutil
import binascii
import vdf

STEAM_ROOT = os.environ["STEAM_ROOT"]
USER_CONFIG_DIR = os.environ["USER_CONFIG_DIR"]
LAUNCHER = os.environ["LAUNCHER_ENV"]
ICON_PATH_PY = os.environ["ICON_PATH_ENV"]
REALM_APPID = os.environ["REALM_APPID"]
APP_NAME = os.environ["APP_NAME_ENV"]
GAMESCOPE_OPTS = os.environ["GAMESCOPE_OPTS_ENV"]
VERBOSE = os.environ.get("VERBOSE_ENV", "false") == "true"

def compute_shortcut_id(exe, name):
    crc = binascii.crc32((exe + name).encode("utf-8")) & 0xFFFFFFFF
    unsigned_id = (crc | 0x80000000) & 0xFFFFFFFF
    return unsigned_id

unsigned_id = compute_shortcut_id(LAUNCHER, APP_NAME)
# Python VDF library needs the signed 32-bit int for shortcuts.vdf
shortcut_appid = unsigned_id - 4294967296 if unsigned_id > 2147483647 else unsigned_id

# Steam needs the completely raw unsigned ID for identifying images in the "grid" directory
grid_appid = str(unsigned_id)

# 1. Add to shortcuts.vdf (We intentionally LEAVE LaunchOptions EMPTY for the launcher!)
shortcuts_path = os.path.join(USER_CONFIG_DIR, "shortcuts.vdf")
shortcuts = vdf.VDFDict({"shortcuts": vdf.VDFDict()})
if os.path.exists(shortcuts_path):
    try:
        with open(shortcuts_path, "rb") as f:
            shortcuts = vdf.binary_load(f)
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not read shortcuts.vdf (might be empty). Creating new one.")

sc = shortcuts.get("shortcuts", vdf.VDFDict())
exists = False
for k, v in sc.items():
    if isinstance(v, dict) and LAUNCHER in v.get("Exe", v.get("exe", "")):
        v["icon"] = ICON_PATH_PY if os.path.exists(ICON_PATH_PY) else ""
        v["LaunchOptions"] = "" 
        exists = True
        break

if not exists:
    next_idx = str(max([int(k) for k in sc if k.isdigit()], default=-1) + 1)
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
with open(shortcuts_path, "wb") as f:
    vdf.binary_dump(shortcuts, f)
print("  [\033[0;32m OK \033[0m] Injected shortcut into Steam (Launcher runs natively!).")

# 2. Add Gamescope Launch Options to the OFFICIAL Realm Royale AppID
localconfig_path = os.path.join(USER_CONFIG_DIR, "localconfig.vdf")
if os.path.exists(localconfig_path):
    try:
        with open(localconfig_path, "r", encoding="utf-8", errors="replace") as f:
            lc = vdf.load(f)
        apps = lc.setdefault("UserLocalConfigStore", {}).setdefault("Software", {}).setdefault("Valve", {}).setdefault("Steam", {}).setdefault("apps", {})
        apps.setdefault(REALM_APPID, {})["LaunchOptions"] = GAMESCOPE_OPTS
        with open(localconfig_path, "w", encoding="utf-8") as f:
            vdf.dump(lc, f, pretty=True)
        print("  [\033[0;32m OK \033[0m] Pre-configured Gamescope launch options for Realm Royale.")
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not update localconfig: {e}")

# 3. Add Proton Compatibility mapping in config.vdf for BOTH the shortcut and Official AppID
config_path = os.path.join(STEAM_ROOT, "config", "config.vdf")
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8", errors="replace") as f:
            cfg = vdf.load(f)
        
        mapping = cfg.setdefault("InstallConfigStore", {}).setdefault("Software", {}).setdefault("Valve", {}).setdefault("Steam", {}).setdefault("CompatToolMapping", {})
        
        proton_counts = {}
        for app, data in mapping.items():
            if isinstance(data, dict):
                p_name = data.get("name", "")
                if "proton" in p_name.lower():
                    proton_counts[p_name] = proton_counts.get(p_name, 0) + 1
        
        best_proton = "proton_experimental"
        if proton_counts:
            best_proton = max(proton_counts, key=proton_counts.get)
            if VERBOSE:
                print("  [\033[0;36mINFO\033[0m] Proton detection details:")
                for pn, count in sorted(proton_counts.items(), key=lambda item: item[1], reverse=True):
                    print(f"         - {pn}: used by {count} app(s)")
                print(f"         -> Selected '{best_proton}' as the most common.")
        else:
            if VERBOSE:
                print("  [\033[0;36mINFO\033[0m] No existing Proton mappings found. Defaulting to 'proton_experimental'.")
        
        mapping[str(shortcut_appid)] = {"name": best_proton, "config": "", "Priority": "250"}
        mapping[REALM_APPID] = {"name": best_proton, "config": "", "Priority": "250"}
        
        with open(config_path, "w", encoding="utf-8") as f:
            vdf.dump(cfg, f, pretty=True)
        print(f"  [\033[0;32m OK \033[0m] Forced '{best_proton}' for the Launcher and Official Game.")
    except Exception as e:
        print(f"  [\033[1;33mWARN\033[0m] Could not update config.vdf for Proton: {e}")

# 4. Install Grid Artwork
grid_dir = os.path.join(USER_CONFIG_DIR, "grid")
os.makedirs(grid_dir, exist_ok=True)

assets = {
    "grid.jpg": [f"{grid_appid}p.jpg"],
    "hero.jpg": [f"{grid_appid}_hero.jpg"],
    "logo.png": [f"{grid_appid}_logo.png"]
}

for src_name, dest_names in assets.items():
    src_path = os.path.join("/tmp/cluckers_assets", src_name)
    if os.path.exists(src_path) and os.path.getsize(src_path) > 0:
        for dest_name in dest_names:
            dest_path = os.path.join(grid_dir, dest_name)
            shutil.copy2(src_path, dest_path)
print("  [\033[0;32m OK \033[0m] Applied custom artwork to the shortcut.")

PYEOF
    fi
  fi

  # ── SUMMARY ──
  printf "\n${GREEN}╔══════════════════════════════════════════════════════╗${NC}\n"
  printf "${GREEN}║                ✓  Setup Complete!                    ║${NC}\n"
  printf "${GREEN}╚══════════════════════════════════════════════════════╝${NC}\n\n"
  printf "\n  ${YELLOW}How Gamescope works:${NC}\n"
  printf "  A WINELOADER wrapper intercepts Wine's child process spawning at the Linux level.\n"
  printf "  The launcher (Cluckers Central) runs in bare Wine as normal.\n\n"
  printf "  ${CYAN}1.${NC} When you click 'Play', Wine tries to exec the game binary.\n"
  printf "  ${CYAN}2.${NC} Our WINELOADER wrapper catches this — game exe args arrive as\n"
  printf "     correct argv[] elements (no shell mangling of & = tokens).\n"
  printf "  ${CYAN}3.${NC} The wrapper execs gamescope wrapping *only* the game process.\n"
  if [[ "${no_gamescope}" == "true" ]]; then
  printf "\n  ${YELLOW}⚠ Gamescope is DISABLED (-g flag). Game runs in bare Wine.${NC}\n"
  printf "  Re-run setup without -g to re-enable it.\n"
  fi
  printf "\n  ${CYAN}Disable Gamescope:${NC}  ./cluckers-setup.sh -g  (bypasses wrapper entirely)\n"
  printf "  ${CYAN}Run Uninstall:${NC}       ./cluckers-setup.sh --uninstall\n\n"
  
  if [[ "${skip_steam}" == "false" ]]; then
    printf "  ${GREEN}▶ You can now open Steam and click Play on Cluckers Central!${NC}\n"
  else
    printf "  Launch the game from your App Menu.\n"
  fi
  printf "\n"
}

main "$@"
