#!/usr/bin/env python3
"""Generates egpu-buddy.png from aorus-box-source.jpg: the eGPU box cut out of its white background on a dark
rounded tile, with a lightning bolt (hot-plug) overlaid top-right."""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops
H=os.path.dirname(os.path.abspath(__file__)); S=512
src=Image.open(os.path.join(H,"aorus-box-source.jpg")).convert("RGB")
# white background -> transparent (flood from the corners so the dark stand/box interior stays)
mask=Image.new("L",src.size,255); m=mask.load(); p=src.load(); W,Hh=src.size
from collections import deque
seen=bytearray(W*Hh); q=deque([(0,0),(W-1,0),(0,Hh-1),(W-1,Hh-1)])
while q:
    x,y=q.popleft(); i=y*W+x
    if seen[i]: continue
    seen[i]=1; r,g,b=p[x,y]
    if min(r,g,b)<225: continue
    m[x,y]=0
    for nx,ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
        if 0<=nx<W and 0<=ny<Hh and not seen[ny*W+nx]: q.append((nx,ny))
mask=mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1))
box=src.copy()
# stylise the product shot: posterise + boost contrast + blue duotone tint + slight edge glow, so it reads as an
# illustration rather than the manufacturer's photo
from PIL import ImageOps, ImageEnhance
g=ImageOps.autocontrast(box.convert("L"),cutoff=2)
g=ImageEnhance.Contrast(g).enhance(1.35)
g=ImageOps.posterize(g,4)
box=ImageOps.colorize(g,black=(8,14,24),mid=(52,96,140),white=(180,225,255)).convert("RGB")
edges=box.convert("L").filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(1)).point(lambda v:min(255,v*3))
box=Image.composite(Image.new("RGB",box.size,(87,183,255)),box,edges.point(lambda v:v//2))
box.putalpha(mask); box=box.crop(mask.getbbox())
# tile
im=Image.new("RGBA",(S,S),(0,0,0,0)); d=ImageDraw.Draw(im)
d.rounded_rectangle((12,12,S-12,S-12),radius=104,fill=(15,20,28,255),outline=(40,49,62,255),width=6)
# soft accent glow behind the box
glow=Image.new("RGBA",(S,S),(0,0,0,0)); ImageDraw.Draw(glow).ellipse((110,120,400,470),fill=(87,183,255,90)); glow=glow.filter(ImageFilter.GaussianBlur(40)); im.alpha_composite(glow)
# box scaled to ~78% of the tile height, centred slightly left/low
bw,bh=box.size; sc=(S*0.78)/bh; box=box.resize((int(bw*sc),int(bh*sc)),Image.LANCZOS)
shadow=Image.new("RGBA",(S,S),(0,0,0,0)); sh=Image.new("RGBA",box.size,(0,0,0,170)); sh.putalpha(box.split()[3]); shadow.paste(sh,(S//2-box.width//2-14+10,S-56-box.height+14)); shadow=shadow.filter(ImageFilter.GaussianBlur(10)); im.alpha_composite(shadow)
im.alpha_composite(box,(S//2-box.width//2-14,S-56-box.height))
# lightning bolt top-right, white with accent outline + glow
bolt=[(392,52),(316,196),(372,196),(330,300),(444,160),(388,160),(440,52)]
bg=Image.new("RGBA",(S,S),(0,0,0,0)); ImageDraw.Draw(bg).polygon(bolt,fill=(87,183,255,255)); bg=bg.filter(ImageFilter.GaussianBlur(14)); im.alpha_composite(bg)
d=ImageDraw.Draw(im); d.polygon(bolt,fill=(255,255,255,255),outline=(87,183,255,255),width=6)
im.save(os.path.join(H,"egpu-buddy.png")); im.resize((256,256),Image.LANCZOS).save(os.path.join(H,"egpu-buddy-256.png"))
print("icon written", im.size)
