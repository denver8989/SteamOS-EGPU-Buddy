"""EGPU Buddy — standalone Decky backend (runs as root via the "root" flag).

Talks only to the NV-EGPU-Buddy system helpers; no Go Hub, no LACT daemon.
"""
import asyncio
import json
import os
import re
import subprocess
import time

import decky  # type: ignore

UID = 1000
RUNENV = {"XDG_RUNTIME_DIR": f"/run/user/{UID}", "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{UID}/bus"}
ST = "/run/nvegpu"
GM_STATUS = f"{ST}/gm-status.json"
GM_PENDING = f"{ST}/gm-attach-pending"
DESKTOP_STATUS = f"/run/user/{UID}/nv-egpu-buddy/safe-detach-status.json"
PRIV = "/usr/local/sbin/nv-egpu-buddy-privileged"
SWITCH = "/usr/local/sbin/egpu-gamemode-switch"
DETACH = "/usr/local/sbin/egpu-gamemode-detach"
REATTACH = "/usr/local/sbin/egpu-reattach"
GPU_ID = "10de:2d04"


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
        if GPU_ID in line:
            return line.split()[0]
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


def _displays(bdf):
    outs = []
    base = f"/sys/bus/pci/devices/{bdf}/drm"
    try:
        for card in os.listdir(base):
            if not re.match(r"card\d+$", card):
                continue
            for c in os.listdir(f"/sys/class/drm"):
                if c.startswith(card + "-") and _read(f"/sys/class/drm/{c}/status") == "connected":
                    outs.append({"name": c.split("-", 1)[1], "enabled": _read(f"/sys/class/drm/{c}/enabled") == "enabled"})
    except OSError:
        pass
    return outs


def _audio_sink():
    rc, out, _ = _sh(["runuser", "-u", "deck", "--", "env", *[f"{k}={v}" for k, v in RUNENV.items()], "pactl", "get-default-sink"], 5)
    return out if rc == 0 else ""


class Plugin:
    async def get_status(self):
        bdf = _gpu_bdf()
        game_mode = _gamescope_running()
        driver = os.path.exists("/sys/module/nvidia_drm")
        output = _gamescope_env("OUTPUT_CONNECTOR").split(",")[0] if game_mode else ""
        status = {
            "present": bool(bdf), "bdf": bdf, "driver_loaded": driver,
            "game_mode": game_mode, "game_running": _game_running() if game_mode else False,
            "attach_pending": os.path.exists(GM_PENDING),
            "on_egpu": bool(bdf) and game_mode and output not in ("", "*", "eDP-1"),
            "output": output,
            "gm_status": _json(GM_STATUS), "desktop_status": _json(DESKTOP_STATUS),
            "link": {"speed": _read(f"/sys/bus/pci/devices/{bdf}/current_link_speed") if bdf else "",
                     "width": _read(f"/sys/bus/pci/devices/{bdf}/current_link_width") if bdf else ""},
            "displays": _displays(bdf) if bdf else [],
            "audio_sink": _audio_sink(),
            "telemetry": _nvidia_query(bdf) if (bdf and driver) else {},
            "ts": time.time(),
        }
        return status

    async def attach(self, force: bool = False):
        if not _gamescope_running():
            return {"ok": False, "message": "Not in Game Mode. Use the Attach eGPU desktop icon."}
        if _game_running() and not force:
            return {"ok": False, "message": "Close the running game first, then Attach."}
        if _gpu_bdf():
            out = _gamescope_env("OUTPUT_CONNECTOR").split(",")[0]
            if out not in ("", "*", "eDP-1"):
                return {"ok": True, "message": f"Already attached: Game Mode is on {out}."}
            cmd = [SWITCH] + (["--force"] if force else [])
        else:
            cmd = [REATTACH]  # GPU off the bus (after a safe detach): rescan + fresh driver + gamescope switch
        rc, out, err = _sh(cmd, 240)
        msgs = {0: "Game Mode is moving to the eGPU display.", 2: "Game Mode is not running.",
                3: "Close the running game first, then Attach.", 4: "Game Mode did not restart."}
        return {"ok": rc == 0, "rc": rc, "message": msgs.get(rc, (out or err)[-200:] or f"rc={rc}")}

    async def safe_detach(self):
        if not _gpu_bdf():
            return {"ok": True, "message": "No eGPU attached."}
        if not _gamescope_running():
            return {"ok": False, "message": "Not in Game Mode. Use the Safely Eject desktop icon."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first, then Safe Detach."}
        subprocess.Popen([DETACH], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return {"ok": True, "message": "Detaching: Game Mode restarts on the handheld screen. Do not unplug until told."}

    async def set_power_limit(self, watts: int):
        rc, out, err = _sh([PRIV, "set-gpu-power-limit", str(int(watts))], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    async def set_core_offset(self, mhz: int):
        rc, out, err = _sh([PRIV, "set-gpu-core-offset", str(int(mhz))], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    async def reset_clocks(self):
        rc, out, err = _sh([PRIV, "reset-gpu-clocks"], 20)
        return {"ok": rc == 0, "message": (err or out)[-200:]}

    async def _main(self):
        decky.logger.info("EGPU Buddy backend loaded")
        while True:  # keep the plugin alive; nothing to do in the background (system udev rules do the work)
            await asyncio.sleep(3600)

    async def _unload(self):
        decky.logger.info("EGPU Buddy backend unloaded")
