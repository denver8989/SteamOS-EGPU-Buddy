"""EGPU Buddy — standalone Decky backend (runs as root via the "root" flag).

Talks only to the NV-EGPU-Buddy system helpers; no Go Hub, no LACT daemon.
"""
import asyncio
import hashlib
import json
import glob
import os
import pwd
import re
import shutil
import subprocess
import tarfile
import threading
import time
import ssl
import urllib.request

import decky  # type: ignore

USER = getattr(decky, "DECKY_USER", "") or "deck"
USER_HOME = getattr(decky, "DECKY_USER_HOME", "") or f"/home/{USER}"
UID = pwd.getpwnam(USER).pw_uid
PLUGIN_DIR = getattr(decky, "DECKY_PLUGIN_DIR", "") or os.path.dirname(os.path.abspath(__file__))
RUNENV = {"XDG_RUNTIME_DIR": f"/run/user/{UID}", "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{UID}/bus"}
# ---- system integration setup (the whole SteamOS-EGPU-Buddy install, driven from Game Mode) ----
PAYLOAD_VERSION = "0.7.81"   # pinned by build-release.sh; the matching release tarball is fetched and verified
REPO = "denver8989/SteamOS-EGPU-Buddy"
SYSDIR = f"{USER_HOME}/.local/share/steamos-egpu-buddy"
SETUP_LOG = "/tmp/egpu-buddy-setup.log"
VERSION_FILE = "/etc/nv-egpu-buddy/version"
SETUP_COMPONENTS = os.environ.get("EGPU_SETUP_COMPONENTS", "core,session,gamescope,bootpolicy,desktopapp")   # no decky (already here); driver added where pacman exists
_setup = {"busy": False, "step": "", "rc": None, "progress": 0, "started": 0.0}
# ---- automatic updates: keep an existing install on the latest GitHub release (system integration + this plugin)
SETTINGS = f"{USER_HOME}/.config/egpu-buddy/plugin.json"
PLUGIN_LIVE = f"{USER_HOME}/homebrew/plugins/EGPU-Buddy"
_update = {"available": "", "state": "", "checked": 0.0, "last_error": ""}
_started = time.time()
# ---- Decky UI watchdog: Steam beta clients break stable Decky's UI injection while its backend (this) keeps running.
# The plugin UI calls pop_notice every 5 s as soon as Decky loads it, panel open or not. Game Mode up for 10 minutes and
# not one call = Decky's UI is not loading. On a SteamOS non-stable channel (or with the setting on), install Decky's
# pre-release through its official installer (egpu-decky-prerelease: backup + automatic rollback). At most once a day, and
# only when a newer pre-release than the installed loader exists. Setting "decky_prerelease_repair": true/false overrides.
_decky_ui = {"seen": 0.0, "gs_since": 0.0}
DECKY_REPAIR = "/usr/local/sbin/egpu-decky-prerelease"
def _steamos_branch():
    rc, out, _ = _sh(["steamos-select-branch", "-c"], 5) if shutil.which("steamos-select-branch") else (1, "", "")
    return out.strip().split()[0].lower() if rc == 0 and out.strip() else ""
def _decky_watchdog_tick():
    if not os.path.exists(DECKY_REPAIR): return
    if _decky_ui["seen"]: return                                   # the UI is loading: nothing to do
    if not (_gamescope_running() and _proc_running("steam")): _decky_ui["gs_since"] = 0.0; return
    now = time.time(); _decky_ui["gs_since"] = _decky_ui["gs_since"] or now
    if now - _decky_ui["gs_since"] < 600 or now - _started < 600: return
    d = _settings(); want = d.get("decky_prerelease_repair")
    if want is None: want = _steamos_branch() not in ("", "rel", "stable")
    if not want or now - d.get("decky_repair_last", 0) < 86400: return
    installed = _read(f"{USER_HOME}/homebrew/services/.loader.version")
    try:
        rels = json.loads(_get("https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases", 20).decode())
        tag = next((r.get("tag_name", "") for r in rels if r.get("prerelease")), "")
    except Exception as ex:  # noqa: BLE001
        decky.logger.info(f"decky watchdog: release check failed: {ex}"); return
    d["decky_repair_last"] = now; _save_settings(d)
    if not tag or tag == installed:
        decky.logger.info(f"decky watchdog: UI not loading, but no newer pre-release than {installed or '?'}"); return
    decky.logger.info(f"decky watchdog: Decky UI has not loaded for 10 min; installing pre-release {tag} (was {installed or '?'})")
    _spawn_root_job("decky-prerelease", [DECKY_REPAIR])
def _settings():
    try: return json.load(open(SETTINGS))
    except Exception: return {}
def _save_settings(d):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True); json.dump(d, open(SETTINGS, "w")); subprocess.run(["chown", "-R", USER, os.path.dirname(SETTINGS)], env=_clean_env())
def _vt(v): return tuple(int(x) for x in re.findall(r"\d+", v or "0")[:3]) or (0,)
def _latest_release():
    data = json.loads(_get(f"https://api.github.com/repos/{REPO}/releases/latest", 20).decode())
    return data.get("tag_name", "").lstrip("v")
# (line prefix in the installer output, percent when that stage STARTS, short label for the line under the bar).
# The percentages follow measured time, not the order of the text: on SteamOS the downloads and the compile dominate.
STAGES = (("== preflight", 3, "Checking the system"), ("== installing user files", 6, "Installing the user files"),
          ("== installing system files", 10, "Installing the system files"),
          ("== building GBM-scanout gamescope", 14, "Building gamescope"), ("== no build toolchain", 14, "Installing the prebuilt gamescope"),
          ("== installing the prebuilt GBM-scanout gamescope", 14, "Installing the gamescope build for this system"),
          ("== no shipped gamescope build runs", 14, "gamescope will be built after the driver"),
          ("== building the GBM-scanout gamescope on this device", 96, "Building gamescope on this device (10-15 minutes)"),
          ("== installing the EGPU Buddy desktop app", 18, "Installing the desktop app"),
          ("== patched driver package", 90, "NVIDIA driver already installed"),
          ("== building the patched nvidia-open", 22, "Preparing the NVIDIA driver build"),
          ("== SteamOS: building the patched NVIDIA driver", 20, "Preparing the NVIDIA driver"),
          ("== creating the build environment", 22, "Downloading the build tools (1.3 GB, a few minutes)"),
          ("== kernel headers:", 36, "Kernel headers downloaded"),
          ("== building the patched NVIDIA", 38, "Downloading the NVIDIA driver files (about 500 MB)"),
          ("==> Retrieving sources", 46, "Downloading the driver source"), ("==> Extracting sources", 48, "Unpacking the driver source"),
          ("==> Starting prepare()", 49, "Applying the eGPU patches"), ("==> Starting build()", 50, "Compiling the driver"),
          ("==> Entering fakeroot", 80, "Packaging the driver"), ("==> Finished making", 82, "Installing the driver package"),
          ("==> dkms install", 84, "Building the modules for this kernel (1-2 minutes)"), ("installed: nvidia-open-egpu-dkms", 90, "Driver installed"),
          ("== assembling the system extension", 90, "Collecting the driver files"), ("== packing the extension image", 93, "Packing the driver image"),
          ("== driver ", 96, "Driver active"), ("== patched driver not installed", 90, "Driver step skipped"),
          ("== keeping a copy", 97, "Saving the self-heal copy"), ("== writing the kernel parameters", 98, "Writing the kernel parameters"),
          ("== NOT finished", 99, "The NVIDIA driver was not built"), ("== done", 100, "Finished"),
          ("restored ", 50, "Restoring the original files"), ("removed  ", 50, "Removing files"), ("done. The stock", 100, "Finished"))
# the one long stage with countable output: the compile prints ~15,500 lines (measured, same with any -j) until the next marker
SPAN = {"==> Starting build()": (15500, 80)}
RC_NO_DRIVER = 20   # install.sh on SteamOS: everything installed except the NVIDIA driver extension
# install.sh cannot write /usr/local while the driver extension is merged and the eGPU is in use.
# That is NOT a failed update: the new payload has already been unpacked into the self-heal source,
# and the boot path installs it when the versions differ — before the eGPU is brought up, with no
# session to disturb. So the update is STAGED and finishes on the next reboot. Nobody should have
# to unplug an eGPU to update the software that manages it.
RC_STAGED = 21
ANSI = re.compile(r"\x1b\[[0-9;]*m")

ST = "/run/nvegpu"
GM_STATUS = f"{ST}/gm-status.json"
GM_PENDING = f"{ST}/gm-attach-pending"
DESKTOP_STATUS = f"/run/user/{UID}/nv-egpu-buddy/safe-detach-status.json"
PRIV = "/usr/local/sbin/nv-egpu-buddy-privileged"
SWITCH = "/usr/local/sbin/egpu-gamemode-switch"
DETACH = "/usr/local/sbin/egpu-gamemode-detach"
REATTACH = "/usr/local/sbin/egpu-reattach"
PLUGIN_BACKUP = f"{USER_HOME}/homebrew/egpu-buddy-plugin-backup"
FLOOD_LOCKOUT = "/var/lib/nvegpu/flood-lockout"; FLOOD_HISTORY = "/var/lib/nvegpu/flood-history"
GPU_RE = re.compile(r"^(\S+) 0300: 10de:")   # any NVIDIA VGA-class device


def _sh(cmd, timeout=15, env=None):
    e = dict(os.environ)
    for k in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
        e.pop(k, None)
    if env:
        e.update(env)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=e)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as ex:  # noqa: BLE001
        return 124, "", str(ex)


def _read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def _json(path):
    try:
        return json.loads(_read(path, "{}") or "{}")
    except ValueError:
        return {}


def _gpu_bdf():
    _, out, _ = _sh(["lspci", "-Dn"], 5)
    for line in out.splitlines():
        m = GPU_RE.match(line)
        if m:
            return m.group(1)
    return ""


def _proc_running(name):
    return _sh(["pgrep", "-x", name], 3)[0] == 0


def _gamescope_running():
    return _sh(["pgrep", "-x", "gamescope(-wl)?"], 3)[0] == 0


def _game_running():
    # exact names only: a -f pattern also matches shells whose command line quotes these words
    return _proc_running("reaper")   # reaper wraps every launched game; pv-adverb/srt-bwrap also host steamwebhelper


def _gamescope_env(key):
    _, pid, _ = _sh(["pgrep", "-n", "-x", "gamescope(-wl)?"], 3)
    if not pid:
        return ""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            for item in f.read().split(b"\0"):
                if item.startswith(key.encode() + b"="):
                    return item.split(b"=", 1)[1].decode(errors="replace")
    except OSError:
        pass
    return ""


def _nvidia_query(bdf):
    fields = ("name,driver_version,temperature.gpu,power.draw,power.limit,power.max_limit,power.min_limit,"
              "clocks.gr,clocks.mem,memory.used,memory.total,utilization.gpu,pcie.link.gen.current,"
              "pcie.link.width.current,fan.speed")
    rc, out, _ = _sh(["timeout", "6", "nvidia-smi", "-i", bdf, f"--query-gpu={fields}", "--format=csv,noheader,nounits"], 8)
    if rc != 0 or not out:
        return {}
    vals = [v.strip() for v in out.split(",")]
    keys = fields.split(",")
    return dict(zip(keys, vals))


GAME_SCREEN = "/var/lib/nvegpu/game-screen"   # connector Game Mode goes to first (nv-egpu-gamescope-session)
SCREEN_NET = "/var/lib/nvegpu/screen-net.json"   # TV control tricks: paired network TVs (egpu-screen)
_seen_screens = None


def _edid_name(path):
    try:
        e = open(path, "rb").read()[:128]
    except OSError:
        return ""
    i = e.find(b"\0\0\0\xfc\0")
    return e[i + 5:i + 18].split(b"\n")[0].decode(errors="ignore").strip() if i >= 0 else ""


# CTA-861 video codes (progressive modes from 720p up; most TVs list their best modes only this way)
_VIC = {4: (1280, 720, 60), 19: (1280, 720, 50), 47: (1280, 720, 120), 16: (1920, 1080, 60), 31: (1920, 1080, 50),
        32: (1920, 1080, 24), 33: (1920, 1080, 25), 34: (1920, 1080, 30), 63: (1920, 1080, 120), 64: (1920, 1080, 100),
        93: (3840, 2160, 24), 94: (3840, 2160, 25), 95: (3840, 2160, 30), 96: (3840, 2160, 50), 97: (3840, 2160, 60),
        114: (3840, 2160, 48), 117: (3840, 2160, 100), 118: (3840, 2160, 120), 98: (4096, 2160, 24), 99: (4096, 2160, 25),
        100: (4096, 2160, 30), 101: (4096, 2160, 50), 102: (4096, 2160, 60), 115: (4096, 2160, 48), 218: (4096, 2160, 100),
        219: (4096, 2160, 120), 194: (7680, 4320, 24), 195: (7680, 4320, 25), 196: (7680, 4320, 30), 197: (7680, 4320, 48),
        198: (7680, 4320, 50), 199: (7680, 4320, 60), 200: (7680, 4320, 100), 201: (7680, 4320, 120)}


def _edid_modes(e):
    """(w, h, Hz) from every detailed timing: base block, CTA-861 and DisplayID (type I / VII) extensions."""
    def dtd(d):
        clk = (d[0] | d[1] << 8) * 10000
        h, hb = d[2] | (d[4] >> 4) << 8, d[3] | (d[4] & 15) << 8
        v, vb = d[5] | (d[7] >> 4) << 8, d[6] | (d[7] & 15) << 8
        return (h, v, round(clk / ((h + hb) * (v + vb)))) if clk and h and v else None

    def did(t, k):  # DisplayID detailed timing: 20 bytes, little-endian fields stored minus one
        u = lambda o: (t[o] | t[o + 1] << 8) + 1
        clk = ((t[0] | t[1] << 8 | t[2] << 16) + 1) * (k * 1000)
        h, hb, v, vb = u(4), u(6), u(12), u(14)  # byte 3 = flags
        return (h, v, round(clk / ((h + hb) * (v + vb))))
    out = [dtd(e[i:i + 18]) for i in range(54, 126, 18) if e[i] or e[i + 1]]
    vics = []
    for x in range(128, len(e) - 127, 128):
        blk = e[x:x + 128]
        if blk[0] == 0x02 and blk[2] >= 4:  # CTA: DTDs from offset blk[2] to the padding
            out += [dtd(blk[i:i + 18]) for i in range(blk[2], 110, 18) if blk[i] or blk[i + 1]]
            i = 4
            while i < blk[2]:  # data blocks: video codes (tag 2) and 4:2:0-only video codes (extended tag 14)
                tag, n = blk[i] >> 5, blk[i] & 31
                codes = blk[i + 1:i + 1 + n] if tag == 2 else blk[i + 2:i + 1 + n] if tag == 7 and blk[i + 1] == 14 else b""
                vics += [_VIC.get(c - 128 if 129 <= c <= 192 else c) for c in codes]  # 129-192: "native" flag on VIC 1-64
                i += 1 + n
        elif blk[0] == 0x70:  # DisplayID: data blocks after the 5-byte section header
            i, end = 5, 5 + blk[2]
            while i + 3 <= end:
                tag, n = blk[i], blk[i + 2]
                if tag in (0x03, 0x22):  # type I (10 kHz units) / type VII (1 kHz units)
                    out += [did(blk[j:j + 20], 10 if tag == 0x03 else 1) for j in range(i + 3, i + 3 + n - 19, 20)]
                i += 3 + n
    return [m for m in out if m], [m for m in vics if m]


def _native_mode(e):
    """Native resolution at its top refresh. Detailed timings describe the real panel (an ultrawide that also
    accepts a 4K signal stays 5120x1440); video codes add refresh rates at that resolution, and only set the
    resolution when the detailed timings stop at 1080p (TVs that list 4K as codes only). 3840 beats DCI 4096."""
    dtds, vics = _edid_modes(e)
    pool = dtds if dtds and max(w * h for w, h, _ in dtds) > 1920 * 1080 else dtds + vics
    if not pool:
        return None
    w, h, _ = max(pool, key=lambda m: (m[0] * m[1] - (m[0] == 4096) * 10 ** 7, m[2]))
    return w, h, max(z for x, y, z in dtds + vics if (x, y) == (w, h))


def _screen_info(conn):
    """('LG TV SSCR2', 'HDMI · 3840x2160 @ 120 Hz · 72"') from the EDID: native mode at its top refresh + size."""
    path = f"/sys/class/drm/{conn}"
    try:
        e = open(path + "/edid", "rb").read()
    except OSError:
        e = b""
    parts = []
    mode = _native_mode(e) if len(e) >= 128 else None
    if mode:
        parts.append("{}x{} @ {} Hz".format(*mode))
    if len(e) >= 128 and e[21] and e[22]:
        parts.append(f'{round((e[21] ** 2 + e[22] ** 2) ** 0.5 / 2.54)}"')
    port = conn.split("-", 1)[1] if "-" in conn else conn
    port = "HDMI" if port.startswith("HDMI") else "DisplayPort" if port.startswith("DP") else port
    return _edid_name(path + "/edid"), " · ".join([port] + parts)


def _displays(bdf):
    outs = []
    base = f"/sys/bus/pci/devices/{bdf}/drm"
    try:
        for card in os.listdir(base):
            if not re.match(r"card\d+$", card):
                continue
            for c in os.listdir(f"/sys/class/drm"):
                if c.startswith(card + "-") and _read(f"/sys/class/drm/{c}/status") == "connected":
                    outs.append({"name": c.split("-", 1)[1], "enabled": _read(f"/sys/class/drm/{c}/enabled") == "enabled",
                                 **dict(zip(("model", "detail"), _screen_info(c)))})
    except OSError:
        pass
    return outs


def _dock_present():
    """A Thunderbolt/USB4 device is enumerated (the enclosure is still plugged in)."""
    import glob as _g
    # host routers are "<domain>-0"; a plugged enclosure/dock has a non-zero route such as "0-2" or "0-2.1"
    return any(re.match(r"^\d+-[1-9]", os.path.basename(d)) and os.path.exists(d + "/device_name") for d in _g.glob("/sys/bus/thunderbolt/devices/*-*"))


def _heal_audio():
    """A detach stops WirePlumber to release the eGPU audio card; if it never came back (interrupted detach), restart it."""
    if os.path.exists(GM_PENDING) or _json(GM_STATUS).get("state") == "DETACHING":
        return
    base = ["runuser", "-u", USER, "--", "env", *[f"{k}={v}" for k, v in RUNENV.items()], "systemctl", "--user"]
    rc, out, _ = _sh(base + ["is-active", "wireplumber.service"], 5)
    if out.strip() == "inactive":
        _sh(base + ["start", "wireplumber.service"], 10); decky.logger.info("wireplumber was down; started it")


def _settle_detach_status():
    """After a safe detach the status says 'safe to unplug' until the cable is actually pulled; once the
    enclosure is gone, retire that message."""
    st = _json(GM_STATUS)
    if st.get("state") in ("SAFE_COMPLETE", "DETACHED") and not _dock_present() and not _gpu_bdf():
        try:
            with open(GM_STATUS, "w") as f:
                json.dump({"state": "IDLE", "message": "eGPU disconnected."}, f)
        except OSError:
            pass


def _audio_sink():
    rc, out, _ = _sh(["runuser", "-u", USER, "--", "env", *[f"{k}={v}" for k, v in RUNENV.items()], "pactl", "get-default-sink"], 5)
    if rc != 0: return ""
    if out.startswith("@"):   # PipeWire may answer with the placeholder; resolve it from the server info
        _, info, _ = _sh(["runuser", "-u", USER, "--", "env", *[f"{k}={v}" for k, v in RUNENV.items()], "pactl", "info"], 5)
        out = next((l.split(":", 1)[1].strip() for l in info.splitlines() if l.startswith("Default Sink:")), "")
    return "" if out.startswith("@") else out


def _ssl_ctx():
    """Decky's bundled Python has no CA store; use the distro's bundle."""
    for ca in ("/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"):
        if os.path.exists(ca): return ssl.create_default_context(cafile=ca)
    try:
        import certifi; return ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001
        return ssl.create_default_context()

def _get(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout, context=_ssl_ctx()) as r: return r.read()

def _download(url, dst):
    with urllib.request.urlopen(url, timeout=120, context=_ssl_ctx()) as r, open(dst, "wb") as f: shutil.copyfileobj(r, f)


def _spawn_root_job(name, cmd):
    """Run a privileged, long-running helper as a transient system service: outside Decky's cgroup, so a Decky
    restart cannot kill it half-way, and with Decky's library path stripped."""
    unit = f"egpu-buddy-{name}-{int(time.time())}"
    subprocess.Popen(["systemd-run", "--collect", "--quiet", "--unit", unit, "-p", "StandardOutput=append:/tmp/egpu-buddy-" + name + ".log",
                      "-p", "StandardError=inherit", *cmd], env=_clean_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return unit


TRIAL = "/usr/local/sbin/egpu-driver-trial"; TRIAL_STATE = "/var/lib/nvegpu/driver-trial"; TRIAL_LOG = "/var/log/egpu-driver-trial.log"


def _trial():
    """The beta driver trial as the system records it (survives Decky restarts and reboots)."""
    d = {}
    for line in _read(TRIAL_STATE).splitlines():
        if "=" in line: k, v = line.split("=", 1); d[k] = v
    d["running"] = d.get("state", "") in ("building", "attempting", "reverting")
    return d


# beta driver trial progress, read from its log the same way the install progress is: (line prefix, percent, label).
# Percentages follow the measured 615 run on a Legion Go 2 (detach 40 s, compile 85 s / ~13,700 lines, DKMS 100 s, attach 15 s).
TRIAL_STAGES = (("Safe Detach (", 3, "Safely detaching the eGPU"),
    ("building the NVIDIA userspace nvidia-utils", 8, "Downloading NVIDIA's driver (about 530 MB) and packaging its libraries"),
    ("building the NVIDIA userspace lib32", 22, "Packaging the 32-bit libraries"),
    ("== creating the build environment", 10, "Downloading the build tools (SteamOS, 1.3 GB)"), ("== kernel headers:", 20, "Kernel headers downloaded"),
    ("==> Making package: nvidia-open-egpu", 32, "Preparing the patched driver"), ("==> Starting prepare()", 34, "Applying the eGPU patches"),
    ("==> Starting build()", 36, "Compiling the patched driver"), ("==> Finished making: nvidia-open-egpu", 60, "Installing the driver"),
    ("==> dkms install", 64, "Building the modules for this kernel (1-2 minutes)"), ("installed: nvidia-open-egpu-dkms", 86, "Driver installed"),
    ("== assembling the system extension", 80, "Collecting the driver files"), ("== packing the extension image", 84, "Packing the driver image"),
    ("[attempting]", 88, "Attaching the eGPU with the beta driver"))
TRIAL_REVERT = (("[reverting]", 10, "Putting the tested driver back"), ("Safe Detach (", 15, "Safely detaching the eGPU"),
    ("==> dkms install", 40, "Rebuilding the tested driver's modules (1-2 minutes)"), ("the tested driver", 80, "Tested driver back; attaching the eGPU"))
TRIAL_SPAN = {"==> Starting build()": (13700, 60)}


def _trial_progress():
    """(percent, label) of the trial in progress, from its log since the trial started."""
    try:
        lines = open(TRIAL_LOG, errors="replace").read().splitlines()
    except OSError:
        return 0, ""
    start = max((i for i, l in enumerate(lines) if "==== beta driver trial" in l), default=0)
    table, pct, label, span, base, n, driver = TRIAL_STAGES, 0, "Starting", None, 0, 0, False
    for l in lines[start:]:
        body = l[20:] if l[:4].isdigit() else l   # strip the "YYYY-MM-DD HH:MM:SS " prefix the trial adds
        if body.startswith("[reverting]"): table, pct, span = TRIAL_REVERT, 0, None
        if body.startswith("==> Making package: nvidia-open-egpu"): driver = True
        for marker, p, lab in table:
            # makepkg's generic markers also appear while the NVIDIA libraries are packaged: count them for the driver only
            if body.startswith(marker) and (driver or marker not in ("==> Starting prepare()", "==> Starting build()")):
                pct, label, span, base, n = max(pct, p), lab, TRIAL_SPAN.get(marker), p, 0; break
        else:
            if span: n += 1; pct = max(pct, base + (span[1] - base) * min(n / span[0], 1.0))
    return round(pct), label


def _operation_in_progress():
    st = _json(GM_STATUS).get("state", "")
    return os.path.exists(GM_PENDING) or st in ("DETACHING", "SWITCHING") or _setup["busy"] or _game_running() or _trial()["running"]


def _slog(msg, progress=None):
    _setup["step"] = msg
    if progress is not None:
        _setup["progress"] = progress
    try:
        with open(SETUP_LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


def _notify(text):
    d = _settings(); d["notice"] = text; _save_settings(d)


def _installed_vendor():
    """Which install was chosen: 'amd' skips the NVIDIA driver. Nothing was connected at install
    time for most people, so this is a CHOICE, not a detection, and it can turn out to be wrong."""
    try:
        return open("/etc/nv-egpu-buddy/gpu-vendor").read().strip() or "nvidia"
    except OSError:
        return "nvidia"


def _egpu_on_bus():
    """A display-class PCI device that is not the one driving the built-in panel."""
    try:
        internal = ""
        for c in glob.glob("/sys/class/drm/card*-eDP-*"):
            internal = os.path.basename(os.path.realpath(os.path.join(c.rsplit("-eDP-", 1)[0], "device")))
            break
        for d in sorted(glob.glob("/sys/bus/pci/devices/*")):
            if os.path.basename(d) == internal:
                continue
            try:
                cls = open(os.path.join(d, "class")).read().strip()
                ven = open(os.path.join(d, "vendor")).read().strip()
            except OSError:
                continue
            if cls.startswith(("0x0300", "0x0302", "0x0380")):
                return {"0x10de": "nvidia", "0x1002": "amd", "0x8086": "intel"}.get(ven, ven)
    except Exception:
        pass
    return ""


def _driver_ready():
    """The NVIDIA kernel module is resolvable for the running kernel (what the attach gate checks as well)."""
    return not shutil.which("pacman") or _sh(["modinfo", "-n", "nvidia"], 5)[0] == 0


def _expect():
    """Honest duration for the confirm dialog and the progress view."""
    if not shutil.which("steamos-readonly"):
        return "several minutes"
    if _driver_ready():
        return "about a minute (the driver is already built)"
    if os.path.exists("/home/.egpu-buddy/buildroot/usr/bin/makepkg"):
        return "about 5-10 minutes (the build tools are already downloaded)"
    return "10-20 minutes the first time, mostly downloads (about 2 GB)"


def _fetch_payload(version=None):
    """Return the path of the verified release tarball: bundled payload/ if present, else downloaded."""
    version = version or PAYLOAD_VERSION
    name = f"SteamOS-EGPU-Buddy-{version}.tar.gz"
    local = os.path.join(PLUGIN_DIR, "payload", name)
    if os.path.exists(local):
        _slog(f"using bundled payload {name}", 3)
        return local
    base = f"https://github.com/{REPO}/releases/download/v{version}/"
    dst = f"/tmp/{name}"
    _slog(f"downloading {name} (no bundled payload)", 2)
    _download(base + name, dst)
    sums = _get(base + "SHA256SUMS").decode()
    want = next((l.split()[0] for l in sums.splitlines() if l.strip().endswith(name)), "")
    got = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    if not want or want != got:
        raise RuntimeError("checksum mismatch on the downloaded payload")
    _slog("checksum ok")
    return dst


def _run_logged(cmd, env, cwd):
    """Run the installer, stream its output into the log, and turn its stage lines into progress."""
    # Run the installer in its OWN transient systemd unit: on SteamOS the driver build takes 10-20 minutes, and as a child
    # of Decky it would die with any Decky/Steam restart. --pipe keeps the output streaming back for the progress bar.
    if shutil.which("systemd-run"):
        keep = [f"--setenv={k}={v}" for k, v in env.items() if k.startswith("EGPU_") or k in ("HOME", "PATH", "STOCK_GAMESCOPE_SESSION")]
        cmd = ["systemd-run", "--quiet", "--wait", "--pipe", "--collect", f"--unit=egpu-buddy-setup-{int(time.time())}",
               f"--working-directory={cwd}", "--property=TimeoutStartSec=7200", *keep, *cmd]
    with open(SETUP_LOG, "a") as log:
        pr = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, cwd=cwd, text=True)
        span = None; base = 0; n = 0
        for line in pr.stdout:
            clean = ANSI.sub("", line.rstrip())
            log.write(clean + "\n"); log.flush()
            for marker, pct, label in STAGES:
                if clean.startswith(marker):
                    log.write(f"{time.strftime('%H:%M:%S')} [{pct}%] {label}\n")
                    _setup["step"] = label; _setup["progress"] = max(_setup["progress"], pct); span = SPAN.get(marker); base = pct; n = 0
                    break
            else:
                if span:   # real progress inside the compile: lines seen / lines expected
                    n += 1; _setup["progress"] = max(_setup["progress"], base + (span[1] - base) * min(n / span[0], 1.0))
        return pr.wait()


def _clean_env(**extra):
    """Decky's bundled Python sets LD_LIBRARY_PATH to its own libraries; system binaries (bash!) must not see it."""
    e = dict(os.environ)
    for k in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "PYTHONPATH", "PYTHONHOME"):
        e.pop(k, None)
    e.update(extra); return e


def _cmdline_reboot_needed():
    """True only when the RUNNING kernel lacks parameters this software needs."""
    if not os.path.exists("/usr/local/sbin/egpu-kernel-cmdline"):
        return False
    return _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--check"], 5)[0] != 0


def _setup_worker(action, with_driver=False, version=None, vendor="nvidia"):
    env = _clean_env(EGPU_TARGET_USER=USER, HOME=USER_HOME, EGPU_AUTO_YES="1", EGPU_ACCEPT_UNTESTED="1" if _accepted() else "0")
    ro = shutil.which("steamos-readonly")
    try:
        if action == "install":
            tgz = _fetch_payload(version)
            _slog(f"extracting to {SYSDIR}", 5)
            shutil.rmtree(SYSDIR, ignore_errors=True); os.makedirs(os.path.dirname(SYSDIR), exist_ok=True)
            with tarfile.open(tgz) as t:
                top = t.getnames()[0].split("/")[0]; t.extractall(os.path.dirname(SYSDIR))
            os.rename(os.path.join(os.path.dirname(SYSDIR), top), SYSDIR)
            subprocess.run(["chown", "-R", USER, SYSDIR], env=_clean_env())
            comps = SETUP_COMPONENTS + (",driver" if shutil.which("pacman") and "driver" not in SETUP_COMPONENTS and os.environ.get("EGPU_SETUP_NO_DRIVER") != "1" else "")
            env.update(EGPU_COMPONENTS=comps, EGPU_PREBUILT_GAMESCOPE=f"{SYSDIR}/prebuilt/gamescope-gbm")
            if ro: subprocess.run([ro, "disable"], env=_clean_env())
            _slog("running install.sh", 6)
            # An AMD (or Intel) eGPU skips the two NVIDIA-only components: the patched nvidia-open
            # build, which is the long part of an install, and the GBM-scanout gamescope, which only
            # exists to fix the NVIDIA scan-out corruption. Everything else is vendor-neutral.
            _argv = ["bash", f"{SYSDIR}/install.sh"] + (["--amd"] if vendor == "amd" else [])
            rc = _run_logged(_argv, env, SYSDIR)
            if ro: subprocess.run([ro, "enable"], env=_clean_env())
        else:
            if not os.path.exists(f"{SYSDIR}/uninstall.sh"):
                raise RuntimeError("no installed copy to uninstall from")
            env.update(EGPU_KEEP_PLUGIN="1")
            if ro: subprocess.run([ro, "disable"], env=_clean_env())
            _slog("running uninstall.sh", 10)
            rc = _run_logged(["bash", f"{SYSDIR}/uninstall.sh"], env, SYSDIR)
            if ro: subprocess.run([ro, "enable"], env=_clean_env())
        _setup["rc"] = rc
        _slog(f"{action} finished rc={rc}" + ("" if rc == 0 else " (see log)"), 100)
        if action == "install":
            _notify(("Installed. Plug the eGPU in when you like." if not _cmdline_reboot_needed()
                     else "Installed. One reboot activates the kernel parameters — the eGPU can stay plugged in.") if rc == 0 else
                    "The NVIDIA driver was not built. Keep the eGPU unplugged and open EGPU Buddy." if rc == RC_NO_DRIVER else
                    "Update staged: it finishes by itself on the next reboot. Nothing to unplug." if rc == RC_STAGED else
                    f"Install failed (rc {rc}). Open EGPU Buddy for details.")
    except Exception as ex:  # noqa: BLE001
        _setup["rc"] = 1
        _slog(f"{action} failed: {ex}")
    finally:
        _setup["busy"] = False


DETECT = "/usr/local/sbin/egpu-detect"


def _untested():
    """Lines describing how this machine differs from the one tested configuration ('' when it matches)."""
    det = os.path.join(PLUGIN_DIR, "egpu-detect")   # copy shipped in the plugin zip for the first install, before /usr/local has it
    for cand in (DETECT, det):
        if os.path.exists(cand):
            rc, out, _ = _sh(["bash", cand, "--untested"], 10)
            return out.strip() if rc == 0 else ""
    return ""


def _accepted():
    """The untested-hardware notice was accepted explicitly in the dialog (an old or partial install does not count)."""
    return bool(_settings().get("accepted_untested"))


def _unsupported():
    try:
        osr = dict(l.split("=", 1) for l in open("/etc/os-release").read().splitlines() if "=" in l)
    except OSError:
        return ""
    if osr.get("ID", "").strip('"') == "steamos":
        return ""
    return ""


def _start_setup(action, with_driver=False, version=None, vendor="nvidia"):
    if action == "install" and _unsupported():
        return {"ok": False, "message": _unsupported()}
    if action == "install" and _untested() and not _accepted():
        return {"ok": False, "message": "This hardware is untested. Read the notice and accept it first."}
    if _setup["busy"]:
        return {"ok": False, "message": "Setup is already running."}
    _setup.update(busy=True, rc=None, step="starting", progress=0, started=time.time())
    try:
        os.replace(SETUP_LOG, SETUP_LOG + ".prev")   # the previous run stays readable: a retry must not erase the first failure
    except OSError:
        pass
    threading.Thread(target=_setup_worker, args=(action, with_driver, version, vendor), daemon=True).start()
    return {"ok": True, "message": f"{action} started"}


def _drop_stray_plugin_copies():
    """Remove copies of this plugin that older versions left inside homebrew/plugins (Decky would load them as plugins)."""
    import glob
    n = 0
    for d in glob.glob(PLUGIN_LIVE + ".bak*"):
        shutil.rmtree(d, ignore_errors=True); n += 1
    return n


def _update_plugin_files(version):
    """Replace this plugin with the release's plugin zip (backup kept), then restart Decky detached from ourselves."""
    name = f"EGPU-Buddy-Decky-{version}.zip"; dst = f"/tmp/{name}"
    _download(f"https://github.com/{REPO}/releases/download/v{version}/{name}", dst)
    sums = _get(f"https://github.com/{REPO}/releases/download/v{version}/SHA256SUMS").decode()
    want = next((l.split()[0] for l in sums.splitlines() if l.strip().endswith(name)), "")
    if not want or want != hashlib.sha256(open(dst, "rb").read()).hexdigest(): raise RuntimeError("checksum mismatch on the plugin zip")
    import zipfile
    tmp = f"/tmp/egpu-buddy-plugin-{version}"; shutil.rmtree(tmp, ignore_errors=True); zipfile.ZipFile(dst).extractall(tmp)
    # The backup must NOT live inside homebrew/plugins: Decky loads every folder there as a plugin, found two "EGPU Buddy",
    # and kept running the BACKUP (the old version) after every update. Seen on a real device: "plugin stayed 0.7.20".
    src = os.path.join(tmp, "EGPU-Buddy"); bak = PLUGIN_BACKUP; _drop_stray_plugin_copies()
    shutil.rmtree(bak, ignore_errors=True); shutil.copytree(PLUGIN_LIVE, bak)
    for entry in os.listdir(PLUGIN_LIVE):
        pth = os.path.join(PLUGIN_LIVE, entry); shutil.rmtree(pth, ignore_errors=True) if os.path.isdir(pth) else os.remove(pth)
    for entry in os.listdir(src):
        sp = os.path.join(src, entry); dp = os.path.join(PLUGIN_LIVE, entry)
        shutil.copytree(sp, dp) if os.path.isdir(sp) else shutil.copy2(sp, dp)
    subprocess.run(["chown", "-R", USER, PLUGIN_LIVE], env=_clean_env())
    if os.environ.get("EGPU_NO_DECKY_RESTART") != "1":   # test hook
        subprocess.Popen(["systemd-run", "--on-active=5", "--collect", "--quiet", "systemctl", "try-restart", "plugin_loader.service"], env=_clean_env())


def _update_worker(version):
    """An update is two separate jobs, PLUGIN FIRST: (1) swap the plugin files (seconds) and let Decky restart; (2) the NEW
    plugin then installs its own bundled system files with its own code and progress view (_continue_update). Old plugin
    code never drives a newer installer."""
    try:
        if _vt(version) > _vt(PAYLOAD_VERSION):
            d = _settings(); d["continue_update"] = version; _save_settings(d)
            _update["state"] = f"updating the plugin to {version}"; _slog(f"updating the plugin to {version}; the system files follow after the restart", 50)
            _update_plugin_files(version)
            _update["state"] = f"plugin {version} installed; restarting"; return
        _update["state"] = f"installing the system files {version}"
        _setup_worker("install", False, version)
        if _setup["rc"] not in (0, RC_NO_DRIVER, RC_STAGED): raise RuntimeError(f"system files install failed rc={_setup['rc']}")
        _update["state"] = (f"updated to {version}; finishes on the next reboot" if _setup["rc"] == RC_STAGED
                            else f"updated to {version}" + ("; the NVIDIA driver was not built" if _setup["rc"] == RC_NO_DRIVER else "")); _update["available"] = ""
        d = _settings(); d["last_update"] = version; _save_settings(d)
    except Exception as ex:  # noqa: BLE001
        d = _settings(); d.pop("continue_update", None); _save_settings(d)
        _update["state"] = f"update failed: {ex}"; _update["last_error"] = str(ex); decky.logger.error(f"update failed: {ex}")
    finally:
        _setup["busy"] = False


def _continue_update():
    """Second half of an update, run by the freshly installed plugin after the Decky restart."""
    d = _settings()
    if d.pop("continue_update", None) != PAYLOAD_VERSION: return
    _save_settings(d)
    if _read(VERSION_FILE) == PAYLOAD_VERSION and os.path.exists(PRIV):
        _notify(f"EGPU Buddy updated to {PAYLOAD_VERSION}."); return
    if _setup["busy"] or _game_running():
        _notify(f"EGPU Buddy plugin {PAYLOAD_VERSION} installed. Open it and press Update system integration."); return
    _setup.update(busy=True, rc=None, step="update", progress=0, started=time.time())
    try: os.replace(SETUP_LOG, SETUP_LOG + ".prev")
    except OSError: pass
    _update_worker(PAYLOAD_VERSION)


def _check_update(install=False, manual=False):
    """Compare the installed integration with the latest release; optionally install it (never a first install)."""
    try:
        latest = _latest_release(); _update["checked"] = time.time(); _update["last_error"] = ""
    except Exception as ex:  # noqa: BLE001
        _update["last_error"] = f"check failed: {ex}"; return
    installed = _read(VERSION_FILE)
    # target = the newest of GitHub's latest release and the payload this plugin carries; the integration follows it
    target = latest if _vt(latest) > _vt(PAYLOAD_VERSION) else PAYLOAD_VERSION
    # an update exists when the system files OR this plugin are behind the target (a plugin left behind by an interrupted
    # update is brought level without reinstalling the system files); never before a first install
    newer = bool(installed) and (_vt(target) > _vt(installed) or _vt(target) > _vt(PAYLOAD_VERSION))
    _update["available"] = target if newer else ""
    if newer and install and _untested() and not _accepted():
        return   # untested hardware: only the button (with its dialog) installs, never the background check
    # the 5-minute settle time after a Decky start is for the BACKGROUND install only; a button press acts at once
    if newer and install and not _operation_in_progress() and (manual or time.time() - _started > 300):
        _setup.update(busy=True, rc=None, step="update", progress=0, started=time.time())
        try: os.replace(SETUP_LOG, SETUP_LOG + ".prev")
        except OSError: pass
        threading.Thread(target=_update_worker, args=(target,), daemon=True).start()


class Plugin:
    async def get_update_status(self):
        d = _settings()
        return {"auto_update": d.get("auto_update", False), "available": _update["available"], "state": _update["state"],
                "checked": _update["checked"], "last_error": _update["last_error"], "installed": _read(VERSION_FILE)}

    async def set_auto_update(self, enabled: bool):
        d = _settings(); d["auto_update"] = bool(enabled); _save_settings(d); return {"ok": True, "message": "saved"}

    async def check_update(self, install: bool = False):
        threading.Thread(target=_check_update, args=(bool(install), True), daemon=True).start(); return {"ok": True, "message": "checking"}

    async def get_setup_status(self):
        tail = ""
        try:
            with open(SETUP_LOG) as f:
                tail = "".join(f.readlines()[-6:])
        except OSError:
            pass
        rc, out, _ = _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--check"], 5) if os.path.exists("/usr/local/sbin/egpu-kernel-cmdline") else (0, "", "")
        # A reboot is needed for exactly one reason: the RUNNING kernel is missing parameters this
        # software needs. Everything else an install does takes effect immediately — the driver
        # extension merges live, the units start, the session picks its pieces up on the next Game
        # Mode start. The old test looked for phrases in the install log, and install.sh prints
        # "writing the kernel parameters" every single run, so it asked for a reboot after every
        # install whether or not anything had changed. `--check` already answers this properly.
        needs_reboot = rc != 0
        return {"installed_version": _read(VERSION_FILE), "payload_version": PAYLOAD_VERSION, "needs_reboot": needs_reboot,
                "unsupported": _unsupported(), "untested": _untested(), "accepted_untested": _accepted(),
                "cmdline_missing": out.replace("missing kernel parameters: ", "") if rc != 0 else "",
                "cmdline_pending": rc != 0 and _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--pending"], 5)[0] == 0,
                "helpers_present": os.path.exists(PRIV) and os.path.exists(DETACH),
                "busy": _setup["busy"], "step": _setup["step"], "rc": _setup["rc"], "progress": _setup["progress"],
                "started": _setup["started"], "expect": _expect(), "driver_ready": _driver_ready(),
                "installed_vendor": _installed_vendor(), "egpu_on_bus": _egpu_on_bus(),
                "can_build_driver": bool(shutil.which("pacman")), "slow_build": bool(shutil.which("steamos-readonly")), "log": tail}

    async def pop_notice(self):
        _decky_ui["seen"] = time.time()   # the plugin's UI polls this every 5 s from the moment Decky loads it
        d = _settings(); text = d.pop("notice", "")
        if text: _save_settings(d); return text
        # root services leave a one-line notice here (e.g. the driver being built ahead of a staged SteamOS update)
        try: text = open("/run/nvegpu/notice").read().strip(); os.remove("/run/nvegpu/notice")
        except OSError: text = ""
        return text

    async def apply_kernel_cmdline(self):
        rc, out, err = _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--apply"], 120)
        return {"ok": rc == 0, "message": (out or err)[-300:]}

    async def restart_gamemode(self):
        if not _gamescope_running():
            return {"ok": True, "message": "Not in Game Mode: the new session pieces apply at the next Game Mode start."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first."}
        _setup["rc"] = None; _update["state"] = ""
        _spawn_root_job("switch", [SWITCH])
        return {"ok": True, "message": "Game Mode is restarting."}

    async def reboot_system(self):
        subprocess.Popen(["systemctl", "reboot"], env=_clean_env()); return {"ok": True, "message": "Rebooting"}

    async def install_system(self, with_driver: bool = False, vendor: str = "nvidia"):
        return _start_setup("install", bool(with_driver), vendor=(vendor if vendor in ("nvidia", "amd") else "nvidia"))


    async def accept_untested(self):
        d = _settings(); d["accepted_untested"] = True; _save_settings(d); return {"ok": True, "message": "accepted"}

    async def uninstall_system(self):
        return _start_setup("uninstall")

    async def get_status(self):
        _settle_detach_status(); _heal_audio()
        bdf = _gpu_bdf()
        game_mode = _gamescope_running()
        driver = os.path.exists("/sys/module/nvidia_drm")
        output = _gamescope_env("OUTPUT_CONNECTOR").split(",")[0] if game_mode else ""
        status = {
            "present": bool(bdf), "bdf": bdf, "driver_loaded": driver,
            "game_mode": game_mode, "game_running": _game_running() if game_mode else False,
            "attach_pending": os.path.exists(GM_PENDING), "dock_present": _dock_present(),
            "on_egpu": bool(bdf) and game_mode and output not in ("", "*", "eDP-1"),
            "output": output,
            "gm_status": _json(GM_STATUS), "desktop_status": _json(DESKTOP_STATUS),
            # Strip NULs and control characters: a hardware reset can leave this file NUL-padded
            # (data written but never flushed), and the raw bytes rendered as a row of boxes in the
            # interface — "last: {}{}{}{}..." instead of a date.
            "resets": (lambda h: {"count": len(h), "last": h[-1] if h else ""})(
                [c for c in ("".join(ch for ch in _read(FLOOD_HISTORY) if ch == "\n" or " " <= ch <= "~")).splitlines() if c.strip()]),
            "link": {"speed": _read(f"/sys/bus/pci/devices/{bdf}/current_link_speed") if bdf else "",
                     "width": _read(f"/sys/bus/pci/devices/{bdf}/current_link_width") if bdf else ""},
            "displays": _displays(bdf) if bdf else [],
            "audio_sink": _audio_sink(),
            "telemetry": _nvidia_query(bdf) if (bdf and driver) else {},
            "ts": time.time(),
        }
        return status

    async def get_screens(self):
        rc, out, _ = _sh(["/usr/local/sbin/egpu-screen", "list"], 20)
        return [json.loads(l) for l in out.splitlines() if l.startswith("{")]

    async def wake_screens(self):
        rc, out, err = _sh(["/usr/local/sbin/egpu-screen", "wake", "--input"], 20)
        return {"ok": rc == 0, "message": out.replace("\n", "; ") or err or "No external screens connected."}

    # Extras > TV control tricks (off by default): a TV paired over the network is woken and switched to our HDMI
    # when Game Mode moves to it, and left out of the desktop while it shows something else (egpu-screen does both)
    async def get_tv_control(self):
        try:
            d = json.load(open(SCREEN_NET))
        except (OSError, ValueError):
            d = {}
        return {"enabled": bool(d.get("enabled")), "paired": [f'{t["ip"]} on {t["input"].replace("_", " ")}' for t in d.get("tvs", {}).values()]}

    async def set_tv_control(self, enabled: bool):
        try:
            d = json.load(open(SCREEN_NET))
        except (OSError, ValueError):
            d = {}
        d["enabled"] = bool(enabled)
        os.makedirs(os.path.dirname(SCREEN_NET), exist_ok=True)
        json.dump(d, open(SCREEN_NET, "w")); os.chmod(SCREEN_NET, 0o644)
        return {"ok": True, "message": "TV control on." if enabled else "TV control off: screens are handled as before."}

    async def pair_tv(self):
        def work():
            ips = _sh(["/usr/local/sbin/egpu-screen", "find"], 20)[1].split()
            hdmi = [d["name"] for d in _displays(_gpu_bdf() or "") if d["name"].startswith("HDMI")] if _gpu_bdf() else []
            if not ips:
                return "No LG TV found on the network. Turn the TV on, on the same network as this device."
            if len(hdmi) != 1:
                return "Connect the TV to the eGPU's HDMI port first." if not hdmi else "More than one HDMI screen: unplug the others while pairing."
            # ponytail: first TV found; a picker when someone has two LG TVs on the network
            return _sh(["/usr/local/sbin/egpu-screen", "pair", ips[0], hdmi[0]], 80)[1] or "No answer from the TV."
        msg = await asyncio.get_running_loop().run_in_executor(None, work)
        return {"ok": msg.startswith("paired"), "message": msg}

    async def get_screen_offer(self):
        """A screen newly connected to the eGPU while Game Mode is on another one -> offer to move."""
        global _seen_screens
        bdf = _gpu_bdf()
        if not bdf or not _gamescope_running():
            _seen_screens = None; return {}
        now = {d["name"]: d for d in _displays(bdf)}
        new = [c for c in now if _seen_screens is not None and c not in _seen_screens]
        _seen_screens = set(now)
        cur = _gamescope_env("OUTPUT_CONNECTOR").split(",")[0]
        for c in new:
            # a TV that is on another input is not being looked at: don't offer it
            if c != cur and _sh(["/usr/local/sbin/egpu-screen", "state", c], 15)[1] != "other-input":
                return {"connector": c, "name": now[c]["model"] or c, "detail": now[c]["detail"], "game": _game_running()}
        return {}

    async def set_game_screen(self, connector: str):
        if not re.fullmatch(r"[A-Za-z]+(-[A-Za-z0-9]+)+", connector or ""):
            return {"ok": False, "message": "Unknown screen."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first: switching screens restarts Game Mode."}
        os.makedirs(os.path.dirname(GAME_SCREEN), exist_ok=True)
        open(GAME_SCREEN, "w").write(connector + "\n")
        # once Game Mode is up there, ask the screen to turn on and select our input (HDMI-CEC / DDC/CI, where the
        # connection carries them; a screen that answers neither is simply left as it is)
        _spawn_root_job("switch", ["/bin/bash", "-c", f'{SWITCH}; /usr/local/sbin/egpu-screen wake --input {connector}'])
        return {"ok": True, "message": f"Moving Game Mode to {connector}: the screen goes dark for a few seconds."}

    async def attach(self, force: bool = False):
        decky.logger.info(f"attach pressed (force={force})")
        if not _gamescope_running():
            return {"ok": False, "message": "Not in Game Mode. Use the Attach eGPU desktop icon."}
        if _game_running() and not force:
            return {"ok": False, "message": "Close the running game first, then Attach."}
        if os.path.exists(FLOOD_LOCKOUT):   # left over from a version that paused attach after a hardware reset
            _sh(["/usr/local/sbin/egpu-rearm"], 10)
        if _gpu_bdf() and not os.path.exists("/sys/module/nvidia_drm"):
            # on the bus but never brought up (lockout, or an attach that stopped early): the full attach, not just a session switch
            _spawn_root_job("attach", ["/usr/local/sbin/egpu-hotplug-mount.sh", "--manual"])
            return {"ok": True, "message": "Attaching: driver load, then Game Mode restarts on the eGPU display (about 30 seconds). Reopen this menu afterwards."}
        if _gpu_bdf():
            out = _gamescope_env("OUTPUT_CONNECTOR").split(",")[0]
            if out not in ("", "*", "eDP-1"):
                return {"ok": True, "message": f"Already attached: Game Mode is on {out}."}
            cmd = [SWITCH] + (["--force"] if force else [])
        else:
            cmd = [REATTACH]  # GPU off the bus (after a safe detach): rescan + fresh driver + gamescope switch
        _spawn_root_job("attach", cmd)
        return {"ok": True, "message": "Attaching: the screen goes dark for a moment while Game Mode restarts on the eGPU display. Reopen this menu afterwards."}

    async def safe_detach(self):
        decky.logger.info("safe detach pressed")
        if not _gpu_bdf():
            return {"ok": True, "message": "No eGPU attached."}
        if not _gamescope_running():
            return {"ok": False, "message": "Not in Game Mode. Use the Safely Eject desktop icon."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first, then Safe Detach."}
        _spawn_root_job("detach", [DETACH])
        return {"ok": True, "message": "Detaching: the screen goes dark for a moment while Game Mode moves to the handheld screen. Reopen this menu afterwards; it says when it is safe to unplug."}

    async def get_driver_trial(self):
        t = _trial()
        beta = _read(f"{SYSDIR}/packaging/nvidia-open-egpu-615/PKGBUILD"); tested = _read(f"{SYSDIR}/packaging/nvidia-open-egpu/PKGBUILD")
        pv = lambda txt: next((l.split("=", 1)[1] for l in txt.splitlines() if l.startswith("pkgver=")), "")
        tail = ""
        try:
            with open(TRIAL_LOG) as f: tail = "".join(f.readlines()[-12:])
        except OSError: pass
        return {"available": bool(pv(beta)) and os.path.exists(TRIAL) and _installed_vendor() == "nvidia",
                "beta": pv(beta), "tested": pv(tested), "installed": _sh(["modinfo", "-F", "version", "nvidia"], 5)[1],
                "state": t.get("state", ""), "message": t.get("message", ""), "running": t["running"], "log": tail,
                "started": int(t.get("started", "0") or 0), "progress": _trial_progress()[0], "step": _trial_progress()[1],
                "acked": _settings().get("trial_ack", "") == t.get("started", "")}

    async def ack_driver_trial(self):
        """The result screen was closed with OK: never show this trial's result again (kept here, not in the browser —
        Steam's web storage does not survive a gamescope restart, so the screen came back on every one)."""
        d = _settings(); d["trial_ack"] = _trial().get("started", ""); _save_settings(d); return {"ok": True, "message": "ok"}

    async def start_driver_trial(self):
        if _trial()["running"]: return {"ok": False, "message": "A driver trial is already running."}
        if not _gamescope_running(): return {"ok": False, "message": "Start it from Game Mode."}
        if _game_running(): return {"ok": False, "message": "Close the running game first."}
        if not _gpu_bdf() and not os.path.exists("/sys/module/nvidia"):
            return {"ok": False, "message": "Connect the eGPU first: the trial attaches it to test the beta driver."}
        _spawn_root_job("driver-trial", [TRIAL, "start"])
        return {"ok": True, "message": "Beta driver trial started: Safe Detach, then the build (10-20 minutes), then the eGPU is attached with it. You can close this menu."}

    async def revert_driver_trial(self):
        if _trial()["running"]: return {"ok": False, "message": "A driver trial is running; it reverts by itself if the beta driver fails."}
        if not _gamescope_running(): return {"ok": False, "message": "Start it from Game Mode."}
        if _game_running(): return {"ok": False, "message": "Close the running game first."}
        _spawn_root_job("driver-trial", [TRIAL, "revert"])
        return {"ok": True, "message": "Returning to the tested driver: Safe Detach, the tested driver is put back, then the eGPU is attached again."}

    async def set_power_limit(self, watts: int):
        rc, out, err = _sh([PRIV, "set-gpu-power-limit", str(int(watts))], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    async def set_core_offset(self, mhz: int):
        rc, out, err = _sh([PRIV, "set-gpu-core-offset", str(int(mhz))], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    async def reset_clocks(self):
        rc, out, err = _sh([PRIV, "reset-gpu-clocks"], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    def _decky_watchdog(self):
        while True:
            try: _decky_watchdog_tick()
            except Exception as ex:  # noqa: BLE001
                decky.logger.error(f"decky watchdog: {ex}")
            time.sleep(60)

    async def _main(self):
        decky.logger.info("EGPU Buddy backend loaded")
        if os.path.realpath(PLUGIN_DIR) == os.path.realpath(PLUGIN_LIVE) and _drop_stray_plugin_copies():
            decky.logger.info("removed stray plugin copies from homebrew/plugins")
        await asyncio.sleep(8)
        threading.Thread(target=_continue_update, daemon=True).start()   # second half of a plugin-first update, if one is pending
        threading.Thread(target=self._decky_watchdog, daemon=True).start()
        await asyncio.sleep(300)
        while True:  # automatic updates: hourly check; install only if enabled, already installed, and no game running
            try:
                _check_update(install=_settings().get("auto_update", False))
            except Exception as ex:  # noqa: BLE001
                decky.logger.error(f"update check: {ex}")
            await asyncio.sleep(3600)

    async def _unload(self):
        decky.logger.info("EGPU Buddy backend unloaded")
