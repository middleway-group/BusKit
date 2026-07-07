#!/usr/bin/env python3
"""Insert a new Sparkle appcast <item> entry and prune old ones.

Reads configuration from environment variables so it can be safely invoked
from both Scripts/release.sh and .github/workflows/release.yml without
embedding a Python heredoc inside a YAML `run: |` block (which breaks YAML
block-scalar indentation parsing).

Required environment variables:
  APPCAST_PATH  Path to releases/appcast.xml
  VERSION       Marketing version, e.g. "0.5.0"
  BUILD         CURRENT_PROJECT_VERSION build number
  PUBDATE       RFC-822 formatted publish date
  DOWNLOAD_URL  URL to the release DMG asset
  ED_SIG        Sparkle EdDSA signature of the DMG
  DMG_LEN       Size in bytes of the DMG
"""
import os
import re

appcast_path = os.environ["APPCAST_PATH"]
version = os.environ["VERSION"]
build = os.environ["BUILD"]
pubdate = os.environ["PUBDATE"]
download_url = os.environ["DOWNLOAD_URL"]
ed_sig = os.environ["ED_SIG"]
dmg_len = os.environ["DMG_LEN"]

new_item = f"""    <item>
            <title>{version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url="{download_url}" sparkle:edSignature="{ed_sig}" length="{dmg_len}" type="application/octet-stream"/>
        </item>"""

with open(appcast_path) as f:
    content = f.read()

content = content.replace(
    "        <title>BusKit</title>",
    "        <title>BusKit</title>\n" + new_item,
)

# Keep only the 3 most recent items — drop any older ones.
items = re.findall(r"    <item>.*?</item>", content, re.DOTALL)
for old in items[3:]:
    content = content.replace("\n" + old, "")

with open(appcast_path, "w") as f:
    f.write(content)

print("✅ appcast.xml updated")
