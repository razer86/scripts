import os
import requests
import json
import csv
import time
from datetime import datetime
from dotenv import load_dotenv
from folder_resolver import FolderResolver

# === Configuration ===
DEBUG_ORG_ID = 6526607  # Set to None to process all organizations
ORG_CACHE_FILE = "org_cache.json"

# === Load environment variables from .env file ===
load_dotenv()
API_KEY = os.getenv("ITGLUE_API_KEY")
API_BASE = os.getenv("ITGLUE_API_BASE")
UI_BASE = os.getenv("ITGLUE_UI_BASE")

# === HTTP headers for all API requests ===
HEADERS = {
    "x-api-key": API_KEY,
    "Accept": "application/vnd.api+json"
}

# === Global counter for API rate limit hits ===
rate_limit_hits = 0

# === Safely performs a GET request, respecting rate limits and retries ===
def safe_get(url, headers, retry_limit=3):
    global rate_limit_hits

    for attempt in range(retry_limit):
        response = requests.get(url, headers=headers)

        # Handle ITGlue 429 rate-limiting
        if response.status_code == 429:
            retry_after = int(response.headers.get("Retry-After", "60"))
            rate_limit_hits += 1
            print(f"[!] Rate limit hit. Waiting {retry_after} seconds...")
            time.sleep(retry_after)
            continue

        # Success — return the response
        if response.ok:
            return response

        # Retry for non-429 failures (e.g. 500, 404, etc.)
        print(f"[!] Request failed: {response.status_code} {response.reason} → {url}")
        time.sleep(2)

    raise Exception(f"[!] Failed after {retry_limit} attempts: {url}")

# === Load cached orgs from disk (if present) ===
def load_org_cache():
    if os.path.exists(ORG_CACHE_FILE):
        with open(ORG_CACHE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}

# === Save org cache to disk ===
def save_org_cache(cache):
    with open(ORG_CACHE_FILE, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2)

# === Paginate and retrieve all organizations, updating the local cache ===
def get_all_organizations():
    org_cache = load_org_cache()
    page = 1
    print("[*] Querying all organizations with pagination...")

    while True:
        print(f"  → Fetching page {page}")
        response = safe_get(
            f"{API_BASE}/organizations?page[number]={page}&page[size]=100",
            headers=HEADERS
        )

        # Add any new orgs to the cache
        for org in response.json().get("data", []):
            org_id = org["id"]
            org_name = org["attributes"]["name"]
            if org_id not in org_cache:
                org_cache[org_id] = {
                    "OrgName": org_name,
                    "Processed": False
                }

        # Check for a next page link
        links = response.json().get("links", {})
        if not links.get("next"):
            break
        page += 1

    save_org_cache(org_cache)
    return org_cache

# === Process all passwords for a given org and resolve folder names ===
def process_org_passwords(org_id, org_name, resolver):
    password_data = []

    # Get all password relationships for the org
    pw_ids_resp = safe_get(f"{API_BASE}/organizations/{org_id}/relationships/passwords", headers=HEADERS)
    pw_ids = pw_ids_resp.json().get("data", [])
    print(f"    - Found {len(pw_ids)} passwords")

    for pw in pw_ids:
        pw_id = pw["id"]
        print(f"[+] Processing Password ID: {pw_id}")

        pw_detail_resp = safe_get(f"{API_BASE}/passwords/{pw_id}", headers=HEADERS)
        pw_detail = pw_detail_resp.json().get("data", {})
        attrs = pw_detail.get("attributes", {})
        rels = pw_detail.get("relationships", {})

        # Determine folder ID from relationships or fallback to attributes
        folder_id = rels.get("password-folder", {}).get("data", {}).get("id") or attrs.get("password-folder-id")

        if not folder_id:
            print("    - Password not in a folder")
            continue

        resolved = resolver.resolve(org_id, folder_id)
        folder_name = resolved.get("FolderName")
        parent_name = resolved.get("ParentFolderName")
        folder_url = f"{UI_BASE}/{org_id}/passwords/folder/{folder_id}"

        if folder_name:
            password_data.append({
                "OrgID": org_id,
                "OrgName": org_name,
                "PasswordID": pw_id,
                "PasswordName": attrs.get("name"),
                "Username": attrs.get("username"),
                "FolderID": folder_id,
                "FolderName": folder_name,
                "ParentFolderName": parent_name,
                "FolderURL": folder_url
            })

    return password_data

# === Export results to JSON and CSV ===
def export_password_data(password_data):
    if not password_data:
        print("[!] No passwords with folders found. Skipping export.")
        return

    with open("itglue_passwords.json", "w") as jf:
        json.dump(password_data, jf, indent=2)

    with open("itglue_passwords.csv", "w", newline='', encoding="utf-8") as cf:
        writer = csv.DictWriter(cf, fieldnames=password_data[0].keys())
        writer.writeheader()
        for row in password_data:
            writer.writerow(row)

    print("[✓] Export complete: itglue_passwords.csv and .json")

# === Main execution flow ===
def main():
    start_time = time.time()
    orgs_processed = 0
    password_data = []
    resolver = FolderResolver()

    # === DEBUG MODE: process only a single org ===
    if DEBUG_ORG_ID:
        org_id = DEBUG_ORG_ID
        print(f"[~] DEBUG_ORG_ID detected: {org_id}")
        org_resp = safe_get(f"{API_BASE}/organizations/{org_id}", headers=HEADERS)

        org_data = org_resp.json().get("data", {})
        org_name = org_data.get("attributes", {}).get("name", "Unknown")
        print(f"[+] Using test organization: {org_name} (ID: {org_id})")

        password_data = process_org_passwords(org_id, org_name, resolver)
        export_password_data(password_data)
        return

    # === FULL RUN: process all unprocessed orgs ===
    org_cache = get_all_organizations()
    total = len(org_cache)
    completed = sum(1 for o in org_cache.values() if o.get("Processed"))
    print(f"[*] Starting audit for {total} organizations ({completed} already completed)")

    for idx, (org_id, org_info) in enumerate(org_cache.items(), start=1):
        if org_info.get("Processed"):
            continue

        org_name = org_info["OrgName"]
        print(f"\n[{idx}/{total}] Processing: {org_name} (ID: {org_id})")

        try:
            org_passwords = process_org_passwords(org_id, org_name, resolver)
            password_data.extend(org_passwords)

            org_cache[org_id]["Processed"] = True
            save_org_cache(org_cache)
            orgs_processed += 1

        except Exception as e:
            print(f"[!] Fatal error processing {org_name} (ID: {org_id}): {e}")
            print("[*] Saving progress before exit...")
            save_org_cache(org_cache)
            resolver.close()
            exit(1)

    export_password_data(password_data)

    # === Final audit summary ===
    end_time = time.time()
    elapsed = end_time - start_time
    unprocessed = sum(1 for o in org_cache.values() if not o.get("Processed"))

    print("\n=== Audit Summary ===")
    print(f"Total organizations:        {len(org_cache)}")
    print(f"Organizations processed:    {orgs_processed}")
    print(f"Remaining unprocessed:      {unprocessed}")
    print(f"Rate limits encountered:    {rate_limit_hits}")
    print(f"Total execution time:       {elapsed:.1f} seconds")

if __name__ == "__main__":
    main()
