# Cluckers Source Code Summary

## Overview
Cluckers is a launcher for Realm Royale that handles Steam integration, game configuration patching (especially for Steam Deck), and process launching via Proton on Linux.

---

## 1. process.go - Game Launch Configuration

**File**: `internal/launch/process.go`

### LaunchConfig Struct
Holds all parameters needed to launch the game:

```go
type LaunchConfig struct {
	ProtonScript      string // Path to the proton Python script (Linux only)
	ProtonDir         string // Root of the Proton-GE installation (Linux only)
	CompatDataPath    string // Path to Proton compatdata directory (Linux only)
	SteamInstallPath  string // Detected Steam root directory (Linux only). Empty if not found
	SteamGameId       string // Non-Steam shortcut app ID for Gamescope tracking (Linux only). "0" if not found
	GameDir           string
	Username          string
	AccessToken       string
	OIDCTokenPath     string
	ContentBootstrap  []byte
	HostX             string
	Verbose           bool
}
```

### Key Points on Game Launching:
- **Proton Integration**: Stores paths to Proton script and installation directory for running Windows game via Wine/Proton
- **Steam Integration**: Tracks `SteamGameId` (non-Steam shortcut app ID) for Gamescope to properly track the game window
- **Game Configuration**: Passes game directory, username, and authentication tokens (AccessToken, OIDCTokenPath)
- **Bootstrap Data**: Carries `ContentBootstrap` binary data (likely for game initialization)
- **Display**: `HostX` likely relates to X11 display configuration
- **Verbosity**: Flag for debug output

This struct is the core data structure that ties together all launch parameters before actually spawning the game process.

---

## 2. steam_linux.go - Steam Integration on Linux

**File**: `internal/cli/steam_linux.go`

### Purpose
Creates a `.desktop` file for Steam integration and provides instructions for adding the game as a Non-Steam Game shortcut.

### Key Functions

#### `runSteamAdd()`
1. **Resolves cluckers binary path** using `os.Executable()` and `filepath.EvalSymlinks()`
2. **Determines .desktop file location**: `~/.local/share/applications/cluckers.desktop`
3. **Detects Steam Deck** via `wine.IsSteamDeck()` to enable platform-specific behavior

### Steam Deck Shortcut Behavior
On Steam Deck, the shortcut points to `shm_launcher.exe` instead of the cluckers binary:
- **Why**: Allows Steam to **auto-enable Proton** for .exe files
- **Location**: `shm_launcher.exe` is extracted to `config.BinDir()/shm_launcher.exe`
- **Extraction**: Uses `launch.ExtractSHMLauncherTo()` to embed the launcher

### Desktop File Content
```
[Desktop Entry]
Name=Realm Royale (Cluckers)
Comment=Launch Realm Royale via Cluckers Central
Exec=[path to executable]
Type=Application
Categories=Game;
Terminal=false
```

### Steam Deck Launch Options
Users must set this in Steam properties:
```
<cluckers_path> prep && WINEDLLOVERRIDES=dxgi=n %command%
```
- `prep` command: Pre-launch preparation
- `WINEDLLOVERRIDES=dxgi=n`: Forces Wine to use native dxgi DLL (not Proton's)

### Desktop vs Steam Deck Flows
- **Desktop Linux**: Point Exec to `cluckers launch` command
- **Steam Deck**: Point Exec to `shm_launcher.exe` and provide launch options with prep + dxgi override

### Shortcut ID Resolution
The code searches `shortcuts.vdf` (binary VDF file in Steam userdata) to find the Cluckers shortcut app ID for later controller layout deployment.

---

## 3. deckconfig.go - Steam Deck Configuration Patching

**File**: `internal/launch/deckconfig.go`

### Overview
Patches game configuration files for optimal Steam Deck experience (display, input, controller layout).

### Main Function: `PatchDeckConfig(gameDir)`
1. Only runs if `wine.IsSteamDeck()` returns true
2. Calls three sub-functions:
   - `patchDeckDisplay()` - Fix display resolution
   - `PatchDeckInputConfig()` - Fix input mode detection
   - `deployDeckControllerLayout()` - Deploy controller mapping

---

### Display Patching: `patchDeckDisplay(gameDir)`

**File Path**: `gameDir/Realm-Royale/RealmGame/Config/RealmSystemSettings.ini`

**Patches Applied** (idempotent - skips if already applied):
```
Fullscreen=false          → Fullscreen=True
FullscreenWindowed=false  → FullscreenWindowed=True
ResX=1920                 → ResX=1280
ResY=1080                 → ResY=800
```

**Why**: Steam Deck screen is 1280x800. Fullscreen mode ensures proper rendering.

**Idempotency**: Checks if all new values already exist before writing.

**File Permissions**: Ensures writable (0644) before writing since game zip extracts files as read-only (0444).

---

### Input Patching: `PatchDeckInputConfig(gameDir)`

**Root Cause Problem**:
- UE3 game has "Count bXAxis" and "Count bYAxis" mouse activity counters in input bindings
- These counters trigger input mode auto-detection (gamepad → KB/M switch)
- On Steam Deck under Wine: phantom mouse events from touch screen and Wine cursor warping constantly trigger these counters
- Result: **Controller becomes disabled in-match** even though it was detected at startup

**Solution**: Remove Count commands from mouse bindings

**Input Patches**:
```go
{
    `Bindings=(Name="MouseX",Command="Count bXAxis | Axis aMouseX")`,
    `Bindings=(Name="MouseX",Command="Axis aMouseX")`,
},
{
    `Bindings=(Name="MouseY",Command="Count bYAxis | Axis aMouseY")`,
    `Bindings=(Name="MouseY",Command="Axis aMouseY")`,
},
```

**Target Sections in INI Files**:
- `[TgGame.TgPlayerInput]` - Game-specific input (in-match gameplay)
- `[Engine.PlayerInput]` - Base engine input (always active)
- Note: `[TgGame.TgSpectatorInput]` intentionally excluded (needs mouse for spectator camera)

**Files Patched** (in order):
1. **BaseInput.ini** (`gameDir/Realm-Royale/Engine/Config/BaseInput.ini`)
   - This is UE3's engine template that game uses to regenerate RealmInput.ini
   - MUST patch first, otherwise Count commands get re-added during INI coalescing
   
2. **DefaultInput.ini** (`gameDir/Realm-Royale/RealmGame/Config/DefaultInput.ini`)
   - Global replacement of all Count patterns
   - Also handles UE3 append syntax: `+Bindings=` → `+Bindings=`
   - **Adds UE3 removal directives** (`-Bindings=...`) to prevent coalescing from re-adding Count entries from BaseInput.ini
   
3. **RealmInput.ini** (`gameDir/Realm-Royale/RealmGame/Config/RealmInput.ini`)
   - Same global replacement and removal directives as DefaultInput.ini

**Gamepad Mode Forcing**:
Adds/replaces these lines in both PlayerInput sections:
```
bUsingGamepad=False  → bUsingGamepad=True
bUsingGamepad=false  → bUsingGamepad=True
```
Why: UE3 reads config properties when creating new PlayerInput (e.g., after ServerTravel). On Wine, one-time HID enumeration at startup doesn't re-fire, so new PlayerInput might default to KB/M mode without this.

**File Permissions**: Makes all .ini files writable (0644) so game can persist user controller preferences.

**Idempotency**: Skips files already patched or missing.

---

### Controller Layout Deployment: `deployDeckControllerLayout()`

**Purpose**: Deploy embedded Steam Deck controller configuration to Steam's controller config directory.

**Discovery Process**:
1. Searches for `shortcuts.vdf` files: `~/.local/share/Steam/userdata/*/config/shortcuts.vdf`
2. Parses binary VDF to find Cluckers shortcut using `findCluckersAppID()`
3. Extracts the app ID (uint32 little-endian at specific VDF offset)

**Deployment Path**:
```
~/.local/share/Steam/userdata/<steamid>/config/controller_configs/apps/<appid>/controller_neptune_config.vdf
```

**When Applied**: Only if no existing config (preserves user customizations).

**Source**: Embedded `assets.ControllerLayout` (pre-built VDF configuration).

**Error Handling**: Best-effort, silent failures (non-blocking).

---

### Binary VDF Parsing: `findCluckersAppID(data []byte) uint32`

**Binary VDF Field Types**:
- `\x01` = string field (format: `key\x00value\x00`)
- `\x02` = int32 field (format: `key\x00[4 bytes LE]`)

**Algorithm**:
1. Search for `exe` field marker (`\x01exe\x00`)
2. Read null-terminated exe path string
3. Check if path contains "cluckers"
4. If found, search **backward** for `appid` field (`\x02appid\x00`)
5. Extract 4-byte little-endian uint32 at appid value offset
6. Return app ID or 0 if not found

**Why backward search**: VDF structure typically has appid defined before exe field in the shortcut entry.

---

## 4. shm.go - SHM Launcher Extraction

**File**: `internal/launch/shm.go`

### Purpose
Manages extraction of embedded `shm_launcher.exe` binary and bootstrap data files to temp locations.

### Function 1: `ExtractSHMLauncher() (path string, cleanup func(), err error)`

**What it does**:
1. Creates temp file with pattern `shm_launcher_*.exe`
2. Writes embedded `assets.SHMLauncherExe` binary to temp file
3. Sets executable permissions (0755)
4. Returns path to temp file + cleanup function

**Cleanup Function**: Removes the temp file when called

**Error Handling**: If any step fails, cleans up created file and returns error

**Why it exists**: SHM launcher is embedded in the binary; this function extracts it to filesystem for Steam to reference.

### Function 2: `WriteBootstrapFile(data []byte) (path string, cleanup func(), err error)`

**What it does**:
1. Creates temp file with pattern `realm_bootstrap_*.bin`
2. Writes provided bootstrap data to temp file
3. Sets restricted permissions (0600) for security
4. Returns path + cleanup function

**Input**: Bootstrap binary data (passed as parameter)

**Cleanup Function**: Removes the temp file when called

**Error Handling**: Same as ExtractSHMLauncher - cleans up on failure

**Why it exists**: Bootstrap data contains game initialization info; needs to be written to filesystem before launching game process.

**Permission Difference**: Uses 0600 (user read/write only) vs 0755 (executable) because bootstrap is data, not executable.

---

## Integration Flow

1. **User runs `cluckers steam-add`**
   - `steam_linux.go`: Creates `.desktop` file pointing to shm_launcher.exe on Deck
   - Extracts shm_launcher using `shm.go:ExtractSHMLauncher()`
   - Prints instructions for manual Steam shortcut creation

2. **User adds game to Steam and sets launch options**
   - Steam creates shortcut in `shortcuts.vdf`
   - Launch options include: `prep && WINEDLLOVERRIDES=dxgi=n %command%`

3. **User launches game from Steam**
   - Calls cluckers with `prep` argument
   - `deckconfig.go:PatchDeckConfig()` runs:
     - Patches display settings (1280x800 fullscreen)
     - Patches input config (removes Count commands, forces gamepad mode)
     - Deploys controller layout (reads shortcuts.vdf to find app ID)
   - `process.go`: LaunchConfig is populated with game parameters
   - Game launches via Proton with dxgi override

4. **Bootstrap on Launch**
   - `shm.go:WriteBootstrapFile()` writes bootstrap data to temp file
   - Game process receives bootstrap path as argument
   - Game initializes with authentication and content bootstrap

---

## Key Design Patterns

### Idempotency
All patches check if already applied before writing, allowing safe re-running.

### Error Handling
- Critical errors (missing files) return errors
- Best-effort operations (controller layout) silently fail
- File permission issues are fixed (ensureWritable) before writing

### Steam Deck Detection
Uses `wine.IsSteamDeck()` to conditionally apply Deck-specific patches.

### Embedded Assets
Binary files (shm_launcher.exe, controller layout) embedded in Go binary, extracted to temp on demand.

### UE3 INI Coalescing Awareness
Patches account for UE3's INI file merging behavior (BaseInput.ini template reapplied), using removal directives to prevent re-adding unwanted entries.
