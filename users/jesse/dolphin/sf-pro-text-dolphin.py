import glob
import os
import sys
from fontTools.ttLib import TTFont

src, dst, family = sys.argv[1:]

for f in glob.glob(src + "/SF-Pro-Text-*.otf"):
    t = TTFont(f)
    cmap, hmtx = t.getBestCmap(), t["hmtx"]
    adv = [hmtx[cmap[c]][0] for c in range(32, 127) if c in cmap]
    t["OS/2"].xAvgCharWidth = round(sum(adv) / len(adv))
    for n in t["name"].names:
        s = n.toUnicode()
        if n.nameID == 6:
            n.string = s.replace("SFProText", "SFProTextDolphin")
        elif "SF Pro Text" in s:
            n.string = s.replace("SF Pro Text", family)
    t.save(os.path.join(dst, os.path.basename(f).replace("SF-Pro-Text", "SF-Pro-Text-Dolphin")))
