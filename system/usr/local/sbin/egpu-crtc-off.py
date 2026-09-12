#!/usr/bin/env python3
# Disable a DRM CRTC with the legacy SETCRTC ioctl (fb_id=0, no connectors) as DRM master.
# Usage: egpu-crtc-off.py /dev/dri/card1 <crtc_id>
import ctypes, fcntl, os, sys, struct
dev, crtc = sys.argv[1], int(sys.argv[2])
class drm_mode_modeinfo(ctypes.Structure):
    _fields_=[("clock",ctypes.c_uint32),("hdisplay",ctypes.c_uint16),("hsync_start",ctypes.c_uint16),("hsync_end",ctypes.c_uint16),("htotal",ctypes.c_uint16),("hskew",ctypes.c_uint16),
              ("vdisplay",ctypes.c_uint16),("vsync_start",ctypes.c_uint16),("vsync_end",ctypes.c_uint16),("vtotal",ctypes.c_uint16),("vscan",ctypes.c_uint16),
              ("vrefresh",ctypes.c_uint32),("flags",ctypes.c_uint32),("type",ctypes.c_uint32),("name",ctypes.c_char*32)]
class drm_mode_crtc(ctypes.Structure):
    _fields_=[("set_connectors_ptr",ctypes.c_uint64),("count_connectors",ctypes.c_uint32),("crtc_id",ctypes.c_uint32),("fb_id",ctypes.c_uint32),
              ("x",ctypes.c_uint32),("y",ctypes.c_uint32),("gamma_size",ctypes.c_uint32),("mode_valid",ctypes.c_uint32),("mode",drm_mode_modeinfo)]
def IOWR(t,nr,size): return (3<<30)|(size<<16)|(ord(t)<<8)|nr
DRM_IOCTL_SET_MASTER=0x641e; DRM_IOCTL_DROP_MASTER=0x641f
DRM_IOCTL_MODE_SETCRTC=IOWR('d',0xA2,ctypes.sizeof(drm_mode_crtc))
fd=os.open(dev, os.O_RDWR|os.O_CLOEXEC)
try:
    fcntl.ioctl(fd, DRM_IOCTL_SET_MASTER)
    c=drm_mode_crtc(); c.crtc_id=crtc; c.fb_id=0; c.count_connectors=0; c.mode_valid=0
    fcntl.ioctl(fd, DRM_IOCTL_MODE_SETCRTC, c)
    print("crtc", crtc, "disabled")
finally:
    try: fcntl.ioctl(fd, DRM_IOCTL_DROP_MASTER)
    except Exception: pass
    os.close(fd)
