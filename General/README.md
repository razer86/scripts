# General Utilities

Miscellaneous scripts and system utilities that don't fit into specific platform categories.

---

## Scripts

### FirefoxProfileSort.py

Sorts Firefox profile entries alphabetically in the profiles.ini configuration file.

**Language:** Python 3

**Synopsis:**
Reads the Firefox `profiles.ini` file, sorts profile sections alphabetically by their `Name` value, and rewrites the file with sorted entries. Useful for managing multiple Firefox profiles and keeping the profile list organized.

**What It Does:**
1. Locates Firefox profiles.ini in user's AppData folder
2. Parses the INI file structure
3. Preserves the `[General]` section as-is
4. Sorts all `[Profile*]` sections alphabetically by profile name
5. Renumbers profile sections sequentially (Profile0, Profile1, etc.)
6. Backs up original file as `profiles.ini_old`
7. Writes sorted configuration back to profiles.ini

**File Location:**
```
Windows: %APPDATA%\Mozilla\Firefox\profiles.ini
```

**Requirements:**
- Python 3.6+
- Firefox installed
- No external dependencies (uses standard library)

**Usage:**
```bash
# Run the script
python FirefoxProfileSort.py
```

**Before:**
```ini
[General]
StartWithLastProfile=1

[Profile2]
Name=Work
Path=Profiles/abc123.work

[Profile0]
Name=Personal
Path=Profiles/def456.personal

[Profile1]
Name=Development
Path=Profiles/ghi789.dev
```

**After:**
```ini
[General]
StartWithLastProfile=1

[Profile0]
Name=Development
Path=Profiles/ghi789.dev

[Profile1]
Name=Personal
Path=Profiles/def456.personal

[Profile2]
Name=Work
Path=Profiles/abc123.work
```

**Safety:**
- Original file backed up as `profiles.ini_old`
- Previous backup is removed before creating new one
- No Firefox restart required (changes take effect on next launch)

**Notes:**
- Close Firefox before running to avoid conflicts
- Profile paths remain unchanged, only order is modified
- Useful when managing many profiles and want alphabetical organization
- Does not modify profile content, only profiles.ini metadata


---

## Unraid Scripts

Bash scripts for Unraid server automation, designed for use with the **CA User Scripts** plugin.

### Unraid/config/plugins/user.scripts/scripts/PlexDBRepair/script

Weekly Plex Media Server database maintenance script.

**Synopsis:**
Checks for active Plex streams before running [PlexDBRepair](https://github.com/ChuckPa/PlexDBRepair) in automatic mode inside a Docker container. Skips maintenance if streams are active and sends Discord notifications for all outcomes.

**What It Does:**
1. Validates Docker is available and the Plex container is running
2. Resolves the container's IP via `docker inspect`
3. Queries the Plex API for active streams — skips if any are found
4. Downloads the latest `DBRepair.sh` from GitHub
5. Copies it into the container and runs `stop → auto → start → exit`
6. Reports duration and result via Discord embed notification

**Configuration:**
Values are baked into the top of `script` at deploy time by `deploy.ps1`, which reads a local `.secrets` file (gitignored) and writes the result to the Unraid flash share over SMB. The repo copy of `script` ships with empty values; runtime validation aborts (and notifies Discord, when possible) if any value is still empty.

To set up: copy `.secrets.example` to `.secrets` in the same directory and fill in real values:

| Variable | Description |
|----------|-------------|
| `PLEX_CONTAINER` | Docker container name (e.g. `plex`) |
| `PLEX_TOKEN` | Plex authentication token |
| `PLEX_PORT` | Plex port (default: `32400`) |
| `DBREPAIR_HOST_PATH` | Host path to download `DBRepair.sh` to (use `/mnt/cache/...`, not `/mnt/user/...`, to bypass the Unraid FUSE layer) |
| `DBREPAIR_CONTAINER_PATH` | Path inside the container to copy `DBRepair.sh` |
| `DBREPAIR_URL` | GitHub release URL for `DBRepair.sh` |
| `LOG_FILE` | Path for the host log file (also bypass FUSE) |
| `DISCORD_WEBHOOK` | Discord webhook URL for notifications (leave empty to disable) |

**Deploy:**
```powershell
# Preview only
./deploy.ps1 -DryRun

# Deploy to defaults (\\Tower\flash\config\plugins\user.scripts\scripts\PlexDBRepair\script)
./deploy.ps1

# Override target
./deploy.ps1 -Server 192.168.1.50 -Share flash
```

**Install Path (Unraid):**
```
/boot/config/plugins/user.scripts/scripts/PlexDBRepair/script
```
Only `script` is deployed — there is no separate config file on the server.

**Requirements:**
- Unraid with CA User Scripts plugin
- Docker with a running `linuxserver/plex` (or compatible) container
- `curl`, `wget`, `docker` available on the host
- Discord webhook for notifications

**Notifications:**
| Colour | Event |
|--------|-------|
| Green | Maintenance completed successfully |
| Yellow | Skipped — active streams detected |
| Red | Error (container not running, download failure, etc.) |

## Tautulli Scripts

Python scripts triggered by Tautulli notifications for media automation.

### Unraid/Tautulli/update_radarr_from_plex.py

Cleans up stale Radarr entries for movies that have been acquired and added to Plex.

**Language:** Python 3

**Synopsis:**
Triggered by a Tautulli library scan notification. When Tautulli detects a movie in the Plex library, this script looks up the matching entry in Radarr by IMDb ID. Since the download process bypasses Radarr's file handling, Radarr still tracks the movie but with no associated file. This script removes those stale entries and optionally sends a Discord notification.

**What It Does:**
1. Receives an IMDb ID from Tautulli via command-line argument (library scan trigger)
2. Queries the Radarr API for a matching movie
3. If found with `hasFile=False`, deletes the movie from Radarr
4. Sends a Discord notification on successful removal (if configured)
5. Logs all actions to a configurable log file

**Configuration:**
Settings are loaded from a `.env` file in the same directory (excluded from git via `.gitignore`). Copy `.env.example` to `.env` and fill in your values:

| Variable | Description |
|----------|-------------|
| `RADARR_URL` | Radarr base URL (e.g. `http://10.0.0.1:7878/radarr`) |
| `RADARR_API_KEY` | Radarr API key |
| `LOG_FILE` | Path for the log file (default: `/config/logs/plex2radarr.log`) |
| `DISCORD_WEBHOOK` | Discord webhook URL (optional — leave empty to disable) |

**Usage (Tautulli notification agent):**
```bash
python /path/to/update_radarr_from_plex.py imdbid={imdb_id}
```

**Requirements:**
- Python 3.6+
- `requests`, `python-dotenv` (`pip install requests python-dotenv`)
- Radarr instance with API access
- Tautulli configured to trigger the script on playback events

---

## Author

Raymond Slater
https://github.com/razer86/scripts
