"""Point LibreOffice's built-in LanguageTool checker at the local server.

Run by Home Manager on every rebuild (see home.nix). LibreOffice keeps user
settings in registrymodifications.xcu, one <item> per line. This replaces only
the LanguageTool lines and leaves the rest of the file byte for byte as it is.
If LibreOffice is open during a rebuild, it overwrites the file when it quits,
so rebuild again after closing it.
"""

import os
import re
import sys
from xml.sax.saxutils import escape

SERVER = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8081/v2"
PATH = "/org.openoffice.Office.Linguistic/GrammarChecking/LanguageTool"
SETTINGS = {"BaseURL": SERVER, "IsEnabled": "true"}

HEADER = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<oor:items xmlns:oor="http://openoffice.org/2001/registry"'
    ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
    ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
)
FOOTER = "</oor:items>\n"

config_home = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
xcu = os.path.join(config_home, "libreoffice/4/user/registrymodifications.xcu")

try:
    with open(xcu, encoding="utf-8") as f:
        content = f.read()
except FileNotFoundError:
    os.makedirs(os.path.dirname(xcu), exist_ok=True)
    content = HEADER + FOOTER

wanted = "".join(
    f'<item oor:path="{PATH}"><prop oor:name="{name}" oor:op="fuse">'
    f"<value>{escape(value)}</value></prop></item>\n"
    for name, value in SETTINGS.items()
)

# Drop the lines this script manages, then add them back before the end tag.
names = "|".join(SETTINGS)
pattern = re.compile(
    rf'^<item oor:path="{re.escape(PATH)}"><prop oor:name="(?:{names})"[^\n]*\n',
    re.MULTILINE,
)
current = "".join(pattern.findall(content))
if current == wanted:
    sys.exit(0)

content = pattern.sub("", content)
end = content.rfind("</oor:items>")
if end == -1:
    sys.exit(f"{xcu}: no </oor:items>, not touching it")
content = content[:end] + wanted + content[end:]

with open(xcu + ".tmp", "w", encoding="utf-8") as f:
    f.write(content)
os.replace(xcu + ".tmp", xcu)
print(f"LibreOffice: LanguageTool set to {SERVER}")
