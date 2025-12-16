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

## Author

Raymond Slater
https://github.com/razer86/scripts
