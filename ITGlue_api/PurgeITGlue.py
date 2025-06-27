import requests
import json
import os
from dotenv import load_dotenv

# Load API key from .env file
load_dotenv()
API_KEY = os.getenv("ITGLUE_API_KEY")

if not API_KEY:
    print("❌ API key not found in .env file. Please define ITGLUE_API_KEY.")
    exit(1)

headers = {
    "x-api-key": API_KEY,
    "Accept": "application/vnd.api+json",
    "Content-Type": "application/vnd.api+json"
}


# Get all organizations
all_orgs = []
page = 1

while True:
    print(f"📥 Fetching page {page}...")
    url = f"https://api.itglue.com/organizations?page[size]=1000&page[number]={page}"
    response = requests.get(url, headers=headers)

    if response.status_code != 200:
        print(f"❌ Failed to fetch page {page}: {response.status_code}")
        print(response.text)
        break

    data = response.json().get("data", [])
    if not data:
        break

    all_orgs.extend(data)
    page += 1


if response.status_code != 200:
    print(f"❌ Failed to fetch organizations: {response.status_code}")
    print(response.text)
    exit(1)

orgs = response.json().get("data", [])

# Loop and delete each org
for org in all_orgs:
    org_id = org["id"]
    org_name = org["attributes"].get("name", "(Unnamed Org)")

    print(f"\n🔻 Deleting organization: {org_name} (ID: {org_id})")

    delete_url = f"https://api.itglue.com/organizations?filter[id]={org_id}"

    delete_response = requests.delete(delete_url, headers=headers)

    if delete_response.status_code in (200, 204):
        print(f"🗑️ Successfully deleted: {org_name}")
    else:
        print(f"❌ Failed to delete {org_name} (ID: {org_id})")
        print(f"   {delete_response.status_code}: {delete_response.text}")
