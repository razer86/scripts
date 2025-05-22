import os
import json
import pyotp
from dotenv import load_dotenv
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

# === Load credentials and environment variables ===
load_dotenv()
EMAIL = os.getenv("ITGLUE_USERNAME")
PASSWORD = os.getenv("ITGLUE_PASSWORD")
TOTP_SECRET = os.getenv("ITGLUE_TOTP_SECRET")
UI_BASE = os.getenv("ITGLUE_UI_BASE")

CACHE_FILE = "folder_cache.json"

class FolderResolver:
    def __init__(self):
        # Load cache and launch browser session
        self.cache = self._load_cache()
        self.driver = self._start_browser()
        self._login()
    
    # === Load cached folder data from disk (if available) ===
    def _load_cache(self):
        if os.path.exists(CACHE_FILE):
            try:
                with open(CACHE_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"[!] Failed to load cache file: {e}")
        return {}

    # === Save cache to disk on exit ===
    def _save_cache(self):
        try:
            with open(CACHE_FILE, "w", encoding="utf-8") as f:
                json.dump(self.cache, f, indent=2)
        except Exception as e:
            print(f"[!] Failed to write cache file: {e}")

    # === Start a headless Chrome session for Selenium ===
    def _start_browser(self):
        options = Options()
        options.headless = True
        options.add_argument("--window-size=1920,1080")
        return webdriver.Chrome(options=options)

    # === Log in to the ITGlue UI using username/password/OTP ===
    def _login(self):
        totp = pyotp.TOTP(TOTP_SECRET)
        otp_code = totp.now()

        self.driver.get(f"{UI_BASE}/login")

        # Step 1: enter username and password
        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.NAME, "username")))
        self.driver.find_element(By.NAME, "username").send_keys(EMAIL)
        self.driver.find_element(By.NAME, "password").send_keys(PASSWORD)
        self.driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

        # Step 2: enter OTP
        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.NAME, "mfa")))
        self.driver.find_element(By.NAME, "mfa").send_keys(otp_code)
        self.driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

        # Step 3: wait for dashboard element to confirm login
        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.ID, "react-main")))

    # === Resolve folder name and parent name from folder ID (with caching) ===
    def resolve(self, org_id, folder_id):
        # Return cached value if available
        if folder_id in self.cache:
            return self.cache[folder_id]

        try:
            url = f"{UI_BASE}/{org_id}/passwords/folder/{folder_id}"
            self.driver.get(url)

            # Wait for breadcrumb navigation to fully load
            WebDriverWait(self.driver, 10).until(
                lambda d: "/folder/" in d.find_element(
                    By.XPATH, "//ul[contains(@class,'breadcrumb')]/li[last()]/a"
                ).get_attribute("href")
            )

            # Parse breadcrumb elements
            breadcrumbs = self.driver.find_elements(By.XPATH, "//ul[contains(@class,'breadcrumb')]/li")
            folder_name = breadcrumbs[-1].text.strip() if len(breadcrumbs) >= 1 else None
            parent_name = breadcrumbs[-2].text.strip() if len(breadcrumbs) >= 2 else "root"

            # Normalize "Passwords" as root folder
            if parent_name.lower() == "passwords":
                parent_name = "root"

            # Store in memory cache and return
            self.cache[folder_id] = {
                "FolderName": folder_name,
                "ParentFolderName": parent_name
            }
            return self.cache[folder_id]

        except Exception as e:
            print(f"[!] Failed to resolve folder ID {folder_id}: {e}")
            return {"FolderName": None, "ParentFolderName": None}

    # === Save cache and close browser cleanly ===
    def close(self):
        self._save_cache()
        self.driver.quit()
