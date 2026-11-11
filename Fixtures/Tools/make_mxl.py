#!/usr/bin/env python3
"""Package Fixtures/MusicXML/twinkle.musicxml as a compressed MusicXML (.mxl).

Standard library only. Run from anywhere:

    python3 Fixtures/Tools/make_mxl.py
"""

import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
XML_DIR = os.path.normpath(os.path.join(HERE, os.pardir, "MusicXML"))
SRC = os.path.join(XML_DIR, "twinkle.musicxml")
DST = os.path.join(XML_DIR, "twinkle.mxl")

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container>
  <rootfiles>
    <rootfile full-path="twinkle.musicxml" media-type="application/vnd.recordare.musicxml+xml"/>
  </rootfiles>
</container>
"""


def main():
    with zipfile.ZipFile(DST, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("META-INF/container.xml", CONTAINER)
        z.write(SRC, arcname="twinkle.musicxml")
    print("wrote", DST, os.path.getsize(DST), "bytes")


if __name__ == "__main__":
    main()
