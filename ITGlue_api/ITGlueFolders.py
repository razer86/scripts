import os
import requests
import json
import csv
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from folder_resolver import FolderResolver

# === Debugging variables ===
debug_org_id = 6526607

# === Load environment variables ===
load_dotenv()
API_KEY = os.getenv("ITGLUE_API_KEY")
API_BASE = os.getenv("ITGLUE_API_BASE")
UI_BASE = os.getenv("ITGLUE_UI_BASE")

HEADERS = {
    "x-api-key": API_KEY,
    "Accept": "application/vnd.api+json"
}

def main():
    password_data = []
    folder_cache = {}
    resolver = FolderResolver()

    # Step 1: Get first orgs
    if debug_org_id:
        org_id = debug_org_id
        print(f"[~] DEBUG_ORG_ID detected: {org_id}")
        org_resp = requests.get(f"{API_BASE}/organizations/{org_id}", headers=HEADERS)
        
        if org_resp.ok:
            org_data = org_resp.json().get("data", {})
            org_name = org_data.get("attributes", {}).get("name", "Unknown")
            print(f"[+] Using test organization: {org_name} (ID: {org_id})")
            orgs = [{"id": org_id, "attributes": {"name": org_name}}]
        else:
            print(f"[!] Failed to retrieve organization {org_id} — status {org_resp.status_code}")
            return
    else:
        print("[*] Querying API for organizations...")
        orgs_resp = requests.get(f"{API_BASE}/organizations?page[size]=1", headers=HEADERS)
        orgs = orgs_resp.json().get("data", [])

    for org in orgs:
        org_id = org["id"]
        org_name = org["attributes"]["name"]
        print(f"[+] Processing organization: {org_name} (ID: {org_id})")

        # Step 2: Get all password IDs for this org
        pw_ids_resp = requests.get(f"{API_BASE}/organizations/{org_id}/relationships/passwords", headers=HEADERS)
        pw_ids = pw_ids_resp.json().get("data", [])
        print(f"    - Found {len(pw_ids)} passwords")

        for pw in pw_ids:
            pw_id = pw["id"]
            print(f"[+] Processing Password ID: {pw_id}")
            pw_detail_resp = requests.get(f"{API_BASE}/passwords/{pw_id}", headers=HEADERS)
            pw_detail = pw_detail_resp.json().get("data", {})
            attrs = pw_detail.get("attributes", {})
            rels = pw_detail.get("relationships", {})
            #print(f"    [DEBUG] Attributes: {json.dumps(attrs, indent=2)}")

            folder_id = None
            folder_name = None
            folder_url = None

            # Try the relationships block first
            folder_rel = rels.get("password-folder", {}).get("data")
            if folder_rel:
                folder_id = folder_rel.get("id")
                print(f"    - password-folder-id (rel): {folder_id}")
            else:
                # Fallback to attributes
                folder_id = attrs.get("password-folder-id")
                if folder_id:
                    print(f"    - password-folder-id (attr): {folder_id}")
                else:
                    print("    - Password not in a folder")

            # Step 3: If folder assigned, try to scrape its name
            if folder_id:
                print(f"    - Resolving folder name via Selenium for folder ID {folder_id}")
                if folder_id in folder_cache:
                    folder_name = folder_cache[folder_id]
                else:
                    folder_name = resolver.resolve(org_id, folder_id)
                    folder_cache[folder_id] = folder_name

                print(f"      → Folder name: {folder_name}")
                folder_url = f"{UI_BASE}/{org_id}/passwords/folder/{folder_id}"


            if folder_id and folder_name:
                password_data.append({
                    "OrgID": org_id,
                    "OrgName": org_name,
                    "PasswordID": pw_id,
                    "PasswordName": attrs.get("name"),
                    "Username": attrs.get("username"),
                    "FolderID": folder_id,
                    "FolderName": folder_name,
                    "FolderURL": folder_url
                })
            else:
                print("    - Skipping password (not in folder or folder name unresolved)")


    # Step 4: Output to JSON and CSV
    with open("itglue_passwords.json", "w") as jf:
        json.dump(password_data, jf, indent=2)

    with open("itglue_passwords.csv", "w", newline='', encoding="utf-8") as cf:
        writer = csv.DictWriter(cf, fieldnames=password_data[0].keys())
        writer.writeheader()
        for row in password_data:
            writer.writerow(row)

    print("Export complete: itglue_passwords.csv and .json")

if __name__ == "__main__":
    main()
