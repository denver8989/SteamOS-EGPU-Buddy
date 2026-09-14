#!/usr/bin/env python3
"""Generates egpu-buddy.png (256x256): dark rounded tile, GPU card glyph, Thunderbolt bolt in the accent colour."""
from PIL import Image, ImageDraw
S=256; im=Image.new("RGBA",(S,S),(0,0,0,0)); d=ImageDraw.Draw(im)
d.rounded_rectangle((8,8,S-8,S-8),radius=52,fill=(15,20,28,255),outline=(40,49,62,255),width=4)
# GPU card body + bracket + two fans
d.rounded_rectangle((40,96,200,176),radius=14,fill=(18,24,33,255),outline=(87,183,255,255),width=5)
d.rectangle((200,110,222,162),fill=(87,183,255,255))
for cx in (86,150):
    d.ellipse((cx-24,112,cx+24,160),outline=(87,183,255,255),width=5); d.ellipse((cx-7,129,cx+7,143),fill=(87,183,255,255))
# lightning bolt (Thunderbolt / hot-plug)
d.polygon([(150,30),(112,96),(140,96),(118,150),(172,78),(144,78),(166,30)],fill=(255,255,255,255))
d.polygon([(150,30),(112,96),(140,96),(118,150),(172,78),(144,78),(166,30)],outline=(87,183,255,255))
im.save(__import__("os").path.join(__import__("os").path.dirname(__file__),"egpu-buddy.png"))
