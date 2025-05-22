#!/usr/bin/env python

"""
This script reads the Firefox `profiles.ini` file, sorts the profile sections alphabetically
by their `Name` value, and rewrites the file with the sorted entries. The original file is
backed up as `profiles.ini_old`.
"""

import configparser
import re
import os

# Create configparser object and preserve the case of keys (optionxform disables lowercasing)
config = configparser.ConfigParser()
config.optionxform = str

# Path to Firefox profiles.ini in user's AppData
inifile = os.getenv('APPDATA') + r'\Mozilla\Firefox\profiles.ini'
config.read(inifile)

# New config object to hold sorted profiles
nconfig = configparser.ConfigParser()
nconfig.optionxform = str

# Copy the [General] section as-is
nconfig['General'] = config['General']

# Collect all sections that start with "Profile"
profiles = [section for section in config.sections() if re.match('^Profile', section)]

# Sort profiles alphabetically by their 'Name' entry
sorted_profiles = sorted(profiles, key=lambda profile: config[profile]['Name'])

# Rebuild the sorted profiles into the new config
for idx, profile in enumerate(sorted_profiles):
    nconfig["Profile" + str(idx)] = config[profile]
    # Python 3.6+ preserves insertion order in dictionaries
    # Renaming profiles is not strictly necessary, but done here for consistent indexing

# Remove any previous backup if it exists
if os.path.exists(inifile + '_old'):
    os.remove(inifile + '_old')

# Backup the original file
os.rename(inifile, inifile + '_old')

# Write the sorted config back to the original file location
with open(inifile, 'w') as f:
    nconfig.write(f, space_around_delimiters=False)
