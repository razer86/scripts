#!/usr/bin/env python3
# =============================================================================
# Script  : update_radarr_from_plex.py
# Author  : Raymond Slater
# Repository: https://github.com/razer86/scripts
# =============================================================================
# Description:
#   Tautulli notification script triggered by a library scan. When Tautulli
#   detects a movie in the Plex library, this script checks Radarr for the
#   matching entry. Since the download process bypasses Radarr's file handling,
#   Radarr still tracks the movie but with no associated file. This script
#   cleans up those stale entries and optionally sends a Discord notification.
#
#   Configuration is loaded from a .env file in the same directory.
#
# Usage:
#   python update_radarr_from_plex.py imdbid=tt12345678
#
# Dependencies:
#   pip install requests python-dotenv
# =============================================================================

import sys
import os
import requests
from datetime import datetime
from dotenv import load_dotenv

# === Load Configuration ===
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

RADARR_URL = os.getenv("RADARR_URL")
RADARR_API_KEY = os.getenv("RADARR_API_KEY")
LOG_FILE = os.getenv("LOG_FILE", "/config/logs/plex2radarr.log")
DISCORD_WEBHOOK = os.getenv("DISCORD_WEBHOOK", "")

if not RADARR_URL or not RADARR_API_KEY:
    print("ERROR: RADARR_URL and RADARR_API_KEY must be set in .env file.")
    sys.exit(1)

# === Timestamp ===
timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# === Parse Args ===
args = {}
for arg in sys.argv[1:]:
    if "=" in arg:
        key, value = arg.split("=", 1)
        args[key.strip()] = value.strip()

# === IMDb ID Validation ===
imdb_id = args.get("imdbid")
if not imdb_id:
    print("Missing imdbid argument. Usage: imdbid=tt12345678")
    sys.exit(1)

def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"[{timestamp}] {message}\n")
        print(message)
    except Exception as e:
        print(f"Logging error: {e}")

def send_discord_notification(title, imdb_id):
    if not DISCORD_WEBHOOK:
        return
    message = {
        "content": f"🗑️ Removed **{title}** (`{imdb_id}`) from Radarr"
    }
    try:
        response = requests.post(DISCORD_WEBHOOK, json=message)
        if response.status_code == 204:
            log(f"📣 Sent Discord notification for '{title}'.")
        else:
            log(f"⚠️ Failed to send Discord notification: {response.status_code} - {response.text}")
    except Exception as e:
        log(f"❌ Error sending Discord message: {e}")


# === Search Radarr for IMDb ID ===
try:
    response = requests.get(
        f"{RADARR_URL}/api/v3/movie",
        headers={"X-Api-Key": RADARR_API_KEY}
    )
    response.raise_for_status()
    movies = response.json()

    match = next((m for m in movies if m.get("imdbId") == imdb_id), None)

    if match:
        log(f"Found in Radarr: {match['title']} (ID: {match['id']}, hasFile: {match['hasFile']})")
    else:
        log(f"No movie with IMDb ID {imdb_id} found in Radarr.")

    if not match.get("hasFile"):
        # Proceed to delete the movie from Radarr
        delete_url = f"{RADARR_URL}/api/v3/movie/{match['id']}"
        delete_params = {
            "deleteFiles": "false",
            "addImportListExclusion": "false"
        }

        delete_response = requests.delete(
            delete_url,
            headers={"X-Api-Key": RADARR_API_KEY},
            params=delete_params
        )

        if delete_response.status_code == 200:
            log(f"✅ Deleted '{match['title']}' (ID: {match['id']}) from Radarr.")
            send_discord_notification(match['title'], match['imdbId'])
        else:
            log(f"❌ Failed to delete '{match['title']}' — HTTP {delete_response.status_code}: {delete_response.text}")
    else:
        log(f"⚠️ Movie '{match['title']}' hasFile=True — skipping deletion.")


except Exception as e:
    log(f"Error querying Radarr: {str(e)}")
    sys.exit(1)
