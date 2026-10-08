# python3 test_screen_info.py - native-mode rule on synthetic EDIDs (no hardware, no decky needed)
import re
src = open(__file__.replace("test_screen_info.py", "main.py")).read()
ns = {"re": re}
exec(src[src.index("def _edid_name"):src.index("def _displays(bdf)")], ns)


def dtd(w, h, hz, hb=160, vb=40):
    clk = round((w + hb) * (h + vb) * hz / 10000)
    return bytes([clk & 255, clk >> 8, w & 255, hb & 255, (w >> 8) << 4 | hb >> 8, h & 255, vb & 255, (h >> 8) << 4 | vb >> 8]) + bytes(10)


def edid(dtds, vics):
    base = bytearray(128); base[54:72] = dtds[0]; base[126] = 1
    cta = bytearray(128); cta[0] = 2
    vdb = bytes([0x40 | len(vics)]) + bytes(vics); cta[4:4 + len(vdb)] = vdb; cta[2] = off = 4 + len(vdb)
    for d in dtds[1:]:
        cta[off:off + 18] = d; off += 18
    return bytes(base + cta)


nm = ns["_native_mode"]
assert nm(edid([dtd(1920, 1080, 60)], [16, 97, 118, 102, 219])) == (3840, 2160, 120)       # TV: 4K only as codes, DCI loses
assert nm(edid([dtd(1920, 1080, 60), dtd(3440, 1440, 100)], [16, 97])) == (3440, 1440, 100)  # ultrawide that accepts 4K
assert nm(edid([dtd(3840, 2160, 60)], [97, 118])) == (3840, 2160, 120)                     # 4K60 timing + 4K120 code
assert nm(edid([dtd(2560, 1440, 165, 80, 20)], [])) == (2560, 1440, 165)                            # plain monitor
print("ok")
