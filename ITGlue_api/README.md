# ITGlue Password Folder Extractor

This project extracts password entries and their associated folder structure from an ITGlue tenant. It was developed due to a limitation in the native ITGlue API, which does **not expose password folder names or hierarchy** via its endpoints. To work around this, folder names are scraped from the ITGlue web UI using Selenium.

---

## Features

- Retrieves all organizations via the ITGlue REST API
- Queries all password entries for each organization
- Resolves password folder names and parent folders using Selenium
- Caches resolved folder names and processed orgs to avoid reprocessing
- Gracefully handles API rate limits and saves progress between runs
- Outputs structured data to both JSON and CSV formats
- Supports debug mode to target a single organization

---

## Requirements

- Python 3.10+
- Google Chrome
- ChromeDriver (matching your Chrome version)

---

## Project Structure
```
.
├── ITGlueFolders.py         # Main script: extracts passwords and folder info
├── folder_resolver.py       # Uses Selenium to scrape folder names from UI
├── .env_example             # Template environment file
├── org_cache.json           # Tracks processed orgs (auto-generated)
├── folder_cache.json        # Caches folder names (auto-generated)
├── itglue_passwords.csv     # CSV export of password data
├── itglue_passwords.json    # JSON export of same
```
---

## Environment Configuration

1. Copy `.env.example` to `.env`:
```
   cp .env.example .env
```
2. Fill in your credentials:
```
   ITGLUE_API_BASE=https://api.itglue.com  
   ITGLUE_UI_BASE=https://yourcompany.itglue.com  
   ITGLUE_API_KEY=your-api-key  
   ITGLUE_USERNAME=your@email.com  
   ITGLUE_PASSWORD=your-password  
   ITGLUE_TOTP_SECRET=your-otp-secret  # Base32 TOTP (e.g., from Authy or 1Password)
```

---

## Usage

### Install dependencies
```
   pip install -r requirements.txt
```

### Run the full audit
```
   python ITGlueFolders.py
```

- Fetches all organizations
- Continues from last saved state (cached orgs and folders)
- Outputs to `itglue_passwords.csv` and `itglue_passwords.json`

---

### Debugging Options

- **Single Organization Debug**

   Set `DEBUG_ORG_ID = <OrgID>` in `ITGlueFolders.py` to process a specific organization.

- **Multiple Organizations Debug**

   Set `DEBUG_ORG_COUNT = <number>` in `ITGlueFolders.py` to process the first X unprocessed organizations.


Then run:
```
   python ITGlueFolders.py
```

---

## Rate Limit Handling

- API rate limits (HTTP 429) are automatically detected
- The script will wait and retry based on the `Retry-After` header
- Cache files are saved after each org, so reruns are safe

---

## Resetting the State

To start from scratch:
```
   rm org_cache.json folder_cache.json itglue_passwords.*
```

---

## Output Format

Each row in `itglue_passwords.csv` includes:

- Organization ID and Name
- Password ID, Name, and Username
- Folder ID, Folder Name, and Parent Folder
- Direct ITGlue URL to the folder

---

## License

MIT – free to use, modify, or distribute.

---

## Author

Raymond Slater  
https://github.com/razer86
