import os
import pyotp
from dotenv import load_dotenv
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

load_dotenv()

EMAIL = os.getenv("ITGLUE_USERNAME")
PASSWORD = os.getenv("ITGLUE_PASSWORD")
TOTP_SECRET = os.getenv("ITGLUE_TOTP_SECRET")
UI_BASE = os.getenv("ITGLUE_UI_BASE")

class FolderResolver:
    def __init__(self):
        self.cache = {}
        self.driver = self._start_browser()
        self._login()

    def _start_browser(self):
        options = Options()
        options.headless = True
        options.add_argument("--window-size=1920,1080")
        return webdriver.Chrome(options=options)

    def _login(self):
        totp = pyotp.TOTP(TOTP_SECRET)
        otp_code = totp.now()
        self.driver.get(f"{UI_BASE}/login")

        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.NAME, "username")))
        self.driver.find_element(By.NAME, "username").send_keys(EMAIL)
        self.driver.find_element(By.NAME, "password").send_keys(PASSWORD)
        self.driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.NAME, "mfa")))
        self.driver.find_element(By.NAME, "mfa").send_keys(otp_code)
        self.driver.find_element(By.CSS_SELECTOR, "button[type='submit']").click()

        WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.ID, "react-main")))

    def resolve(self, org_id, folder_id):
        if folder_id in self.cache:
            return self.cache[folder_id]

        try:
            url = f"{UI_BASE}/{org_id}/passwords/folder/{folder_id}"
            self.driver.get(url)

            WebDriverWait(self.driver, 10).until(
                lambda d: "/folder/" in d.find_element(By.XPATH, "//ul[contains(@class,'breadcrumb')]/li[last()]/a").get_attribute("href")
            )
            elem = self.driver.find_element(By.XPATH, "//ul[contains(@class,'breadcrumb')]/li[last()]/a")
            folder_name = elem.text.strip()
            self.cache[folder_id] = folder_name
            return folder_name
        except Exception as e:
            print(f"[!] Failed to resolve folder ID {folder_id}: {e}")
            return None

    def close(self):
        self.driver.quit()
