#!/usr/bin/env python3
"""Generate an A2 'Nordic' skin (Nord palette, gnome-look Nordic inspired)."""
import os, shutil, tarfile
from PIL import Image, ImageDraw

OUT = "/tmp/claude-1000/-data-Projects-A2-a2oberon/977677fd-c425-4bd5-9fe0-a4649ad866ef/scratchpad/nordic"
IMG = os.path.join(OUT, "images")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(IMG)

# Nord palette (R,G,B)
n0=(46,52,64); n1=(59,66,82); n2=(67,76,94); n3=(76,86,106)
n6=(236,239,244)
frost=(136,192,208)      # nord8
red=(191,97,106)         # nord11
orange=(208,135,112)     # nord12
A=255

def solid(w,h,rgb,a=A):
    return Image.new("RGBA",(w,h),rgb+(a,))

def titletile(fill):
    # H=24: body fill, bottom 2px frost accent
    im=solid(8,24,fill); px=im.load()
    for y in (22,23):
        for x in range(8): px[x,y]=frost+(A,)
    return im

def titlecap(fill):
    im=solid(2,24,fill); px=im.load()
    for y in (22,23):
        for x in range(2): px[x,y]=frost+(A,)
    return im

def closebtn(circle, cross):
    im=Image.new("RGBA",(18,18),(0,0,0,0)); d=ImageDraw.Draw(im)
    d.ellipse([2,2,15,15],fill=circle+(A,))
    if cross:
        d.line([6,6,11,11],fill=n6+(A,),width=2)
        d.line([11,6,6,11],fill=n6+(A,),width=2)
    return im

# window chrome
titletile(n1).save(f"{IMG}/atm.png")          # active title fill + frost accent
titlecap(n1).save(f"{IMG}/atl.png")            # active top-left cap
titlecap(n1).save(f"{IMG}/atr.png")            # active top-right cap
inact=solid(8,24,n0); pxi=inact.load()
for y in (22,23):
    for x in range(8): pxi[x,y]=n3+(A,)
inact.save(f"{IMG}/itm.png")                   # inactive title fill (dim)
solid(2,8,n1).save(f"{IMG}/alm.png")           # left border
solid(2,8,n1).save(f"{IMG}/arm.png")           # right border
solid(8,2,n1).save(f"{IMG}/abm.png")           # bottom border
solid(2,2,n1).save(f"{IMG}/abl.png")
solid(2,2,n1).save(f"{IMG}/abr.png")
closebtn(red,True).save(f"{IMG}/aclose.png")   # active close (red x)
closebtn(orange,True).save(f"{IMG}/hclose.png")# hover close (orange x)
closebtn(n3,False).save(f"{IMG}/iclose.png")   # inactive close (grey dot)

# cursors: reuse from an existing skin (kept generic)
for c in ("arrow.png","move.png"):
    src=f"/tmp/skinprobe/images/{c}"
    if os.path.exists(src): shutil.copy(src,f"{IMG}/{c}")

# skin.bsl
bsl = '''skin{
	meta{
		name : "Nordic";
		description : "Nord-palette dark theme (gnome-look Nordic inspired)";
		author : "minia2";
		date : "2026-07-17";
	}
	window{
		useBitmaps : true;
		title{
			activeLeftMargin : 8;
			activeTopMargin : 16;
			activeColor : 0ECEFF4FF;
			activeCloseBitmap : "images/aclose.png";
			hoverCloseBitmap : "images/hclose.png";
			inactiveLeftMargin : 8;
			inactiveTopMargin : 16;
			inactiveColor : 0D8DEE9FF;
			inactiveCloseBitmap : "images/iclose.png";
		}
		top{
			activeLeft : "images/atl.png";
			activeMiddle : "images/atm.png";
			activeRight : "images/atr.png";
			inactiveMiddle : "images/itm.png";
		}
		bottom{
			activeLeft : "images/abl.png";
			activeMiddle : "images/abm.png";
			activeRight : "images/abr.png";
		}
		left{ activeMiddle : "images/alm.png"; }
		right{ activeMiddle : "images/arm.png"; }
		desktop{
			color : 088C0D0FF;
			bgColor : 02E3440FF;
			fgColor : 0ECEFF4FF;
			selectColor : 05E81ACFF;
		}
	}
	cursor{
		default{ bitmap : "images/arrow.png"; hotX : 0; hotY : 0; }
		move{ bitmap : "images/move.png"; hotX : 10; hotY : 10; }
	}
	component{
		button{
			bounds{ height : 22; width : 64; }
			clDefault : 0434C5EFF;
			clHover : 04C566AFF;
			clPressed : 05E81ACFF;
			clTextDefault : 0ECEFF4FF;
			clTextHover : 0ECEFF4FF;
			clTextPressed : 0ECEFF4FF;
			fontHeight : 12;
			effect3d : 0;
			useBgBitmaps : FALSE;
		}
		scrollbar{
			width : 14;
			minTrackerSize : 40;
			useTrackerBitmaps : FALSE;
			useArrowBitmaps : FALSE;
			useBackgroundBitmaps : FALSE;
			clDefault : 03B4252FF;
			clHover : 0434C5EFF;
			clPressed : 05E81ACFF;
			clBtnDefault : 04C566AFF;
			clBtnHover : 088C0D0FF;
			clBtnPressed : 05E81ACFF;
			effect3d : 0;
		}
	}
}
'''
open(f"{OUT}/skin.bsl","w").write(bsl)

# package as tar (paths: images/*.png, skin.bsl) — like traditional.skin
skinpath="/tmp/claude-1000/-data-Projects-A2-a2oberon/977677fd-c425-4bd5-9fe0-a4649ad866ef/scratchpad/nordic.skin"
with tarfile.open(skinpath,"w") as t:
    for f in sorted(os.listdir(IMG)):
        t.add(f"{IMG}/{f}", arcname=f"images/{f}")
    t.add(f"{OUT}/skin.bsl", arcname="skin.bsl")

print("built", skinpath, os.path.getsize(skinpath), "bytes")
print("images:", sorted(os.listdir(IMG)))
