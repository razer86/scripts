#!/usr/bin/env python

import configparser
import re
import os

config = configparser.ConfigParser()
config.optionxform = str
# this option is mandatory as list in popup will be blank
# if we let configparser default to lowercase option key.
inifile = os.getenv('APPDATA')+'\Mozilla\Firefox\profiles.ini'
config.read(inifile)

nconfig = configparser.ConfigParser()
nconfig.optionxform = str
nconfig['General'] = config['General']

profiles = [section for section in config.sections() if re.match('^Profile', section)]
sorted_profiles = sorted(profiles, key=lambda profile: config[profile]['Name'])

for idx, profile in enumerate(sorted_profiles):
    # 2020-08-25 - fixed this line which was generating syntax error
    nconfig["Profile" + str(idx)] = config[profile]
    # dict are sorted in python 3.6
    # it seems profiles don't need to be renamed,
    # but let's fake we created them in order anyway.

if os.path.exists(inifile+'_old'):
    os.remove(inifile+'_old')

os.rename(inifile, inifile+'_old')

with open(inifile, 'w') as f:
    nconfig.write(f, space_around_delimiters=False)