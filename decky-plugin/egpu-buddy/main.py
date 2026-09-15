"""EGPU Buddy — standalone Decky backend (runs as root via the "root" flag).

Talks only to the NV-EGPU-Buddy system helpers; no Go Hub, no LACT daemon.
"""
import asyncio
import hashlib
import json
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
PAYLOAD_VERSION = "0.7.5"   # pinned by build-release.sh; the matching release tarball is fetched and verified
REPO = "denver8989/SteamOS-EGPU-Buddy"
SYSDIR = f"{USER_HOME}/.local/share/steamos-egpu-buddy"
SETUP_LOG = "/tmp/egpu-buddy-setup.log"
VERSION_FILE = "/etc/nv-egpu-buddy/version"
SETUP_COMPONENTS = os.environ.get("EGPU_SETUP_COMPONENTS", "core,session,gamescope,bootpolicy,desktopapp")   # no decky (already here); driver added where pacman exists
_setup = {"busy": False, "step": "", "rc": None, "progress": 0}
# ---- automatic updates: keep an existing install on the latest GitHub release (system integration + this plugin)
SETTINGS = f"{USER_HOME}/.config/egpu-buddy/plugin.json"
PLUGIN_LIVE = f"{USER_HOME}/homebrew/plugins/EGPU-Buddy"
_update = {"available": "", "state": "", "checked": 0.0, "last_error": ""}
def _settings():
    try: return json.load(open(SETTINGS))
    except Exception: return {}
def _save_settings(d):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True); json.dump(d, open(SETTINGS, "w")); subprocess.run(["chown", "-R", USER, os.path.dirname(SETTINGS)], env=_clean_env())
def _vt(v): return tuple(int(x) for x in re.findall(r"\d+", v or "0")[:3]) or (0,)
def _latest_release():
    data = json.loads(_get(f"https://api.github.com/repos/{REPO}/releases/latest", 20).decode())
    return data.get("tag_name", "").lstrip("v")
STAGES = (("== preflight", 8), ("== installing user files", 20), ("== installing system files", 40),
          ("== building GBM-scanout gamescope", 55), ("== no build toolchain", 60), ("== installing the EGPU Buddy desktop app", 75),
          ("== building the patched nvidia-open", 78), ("pinning NVIDIA userspace", 80), ("==> Making package", 82), ("==> Starting build()", 84),
          ("==> Entering fakeroot", 88), ("==> Finished making", 90), ("installed: nvidia-open-egpu-dkms", 94), ("== patched driver not installed", 94), ("== writing the kernel parameters", 97), ("== done", 100),
          ("restored ", 50), ("removed  ", 50), ("done. The stock", 100))
ANSI = re.compile(r"\x1b\[[0-9;]*m")

ST = "/run/nvegpu"
GM_STATUS = f"{ST}/gm-status.json"
GM_PENDING = f"{ST}/gm-attach-pending"
DESKTOP_STATUS = f"/run/user/{UID}/nv-egpu-buddy/safe-detach-status.json"
PRIV = "/usr/local/sbin/nv-egpu-buddy-privileged"
SWITCH = "/usr/local/sbin/egpu-gamemode-switch"
DETACH = "/usr/local/sbin/egpu-gamemode-detach"
REATTACH = "/usr/local/sbin/egpu-reattach"
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
    rc, out, _ = _sh(["runuser", "-u", USER, "--", "env", *[f"{k}={v}" for k, v in RUNENV.items()], "pactl", "get-default-sink"], 5)
    return out if rc == 0 else ""


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


def _slog(msg, progress=None):
    _setup["step"] = msg
    if progress is not None:
        _setup["progress"] = progress
    try:
        with open(SETUP_LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except OSError:
        pass


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
    with open(SETUP_LOG, "a") as log:
        pr = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, cwd=cwd, text=True)
        for line in pr.stdout:
            clean = ANSI.sub("", line.rstrip())
            log.write(clean + "\n"); log.flush()
            for marker, pct in STAGES:
                if clean.startswith(marker):
                    _setup["step"] = clean.lstrip("= ").strip()[:90]; _setup["progress"] = max(_setup["progress"], pct)
        return pr.wait()


def _clean_env(**extra):
    """Decky's bundled Python sets LD_LIBRARY_PATH to its own libraries; system binaries (bash!) must not see it."""
    e = dict(os.environ)
    for k in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "PYTHONPATH", "PYTHONHOME"):
        e.pop(k, None)
    e.update(extra); return e


def _setup_worker(action, with_driver=False, version=None):
    env = _clean_env(EGPU_TARGET_USER=USER, HOME=USER_HOME, EGPU_AUTO_YES="1")
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
            rc = _run_logged(["bash", f"{SYSDIR}/install.sh"], env, SYSDIR)
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
    except Exception as ex:  # noqa: BLE001
        _setup["rc"] = 1
        _slog(f"{action} failed: {ex}")
    finally:
        _setup["busy"] = False


def _unsupported():
    try:
        osr = dict(l.split("=", 1) for l in open("/etc/os-release").read().splitlines() if "=" in l)
    except OSError:
        return ""
    if osr.get("ID", "").strip('"') == "steamos":
        return ""
    return ""


def _start_setup(action, with_driver=False, version=None):
    if action == "install" and _unsupported():
        return {"ok": False, "message": _unsupported()}
    if _setup["busy"]:
        return {"ok": False, "message": "Setup is already running."}
    _setup.update(busy=True, rc=None, step="starting", progress=0)
    try:
        os.remove(SETUP_LOG)
    except OSError:
        pass
    threading.Thread(target=_setup_worker, args=(action, with_driver, version), daemon=True).start()
    return {"ok": True, "message": f"{action} started"}


def _update_plugin_files(version):
    """Replace this plugin with the release's plugin zip (backup kept), then restart Decky detached from ourselves."""
    name = f"EGPU-Buddy-Decky-{version}.zip"; dst = f"/tmp/{name}"
    _download(f"https://github.com/{REPO}/releases/download/v{version}/{name}", dst)
    sums = _get(f"https://github.com/{REPO}/releases/download/v{version}/SHA256SUMS").decode()
    want = next((l.split()[0] for l in sums.splitlines() if l.strip().endswith(name)), "")
    if not want or want != hashlib.sha256(open(dst, "rb").read()).hexdigest(): raise RuntimeError("checksum mismatch on the plugin zip")
    import zipfile
    tmp = f"/tmp/egpu-buddy-plugin-{version}"; shutil.rmtree(tmp, ignore_errors=True); zipfile.ZipFile(dst).extractall(tmp)
    src = os.path.join(tmp, "EGPU-Buddy"); bak = PLUGIN_LIVE + ".bak-egpu-buddy"
    shutil.rmtree(bak, ignore_errors=True); shutil.copytree(PLUGIN_LIVE, bak)
    for entry in os.listdir(PLUGIN_LIVE):
        pth = os.path.join(PLUGIN_LIVE, entry); shutil.rmtree(pth, ignore_errors=True) if os.path.isdir(pth) else os.remove(pth)
    for entry in os.listdir(src):
        sp = os.path.join(src, entry); dp = os.path.join(PLUGIN_LIVE, entry)
        shutil.copytree(sp, dp) if os.path.isdir(sp) else shutil.copy2(sp, dp)
    subprocess.run(["chown", "-R", USER, PLUGIN_LIVE], env=_clean_env())
    if os.environ.get("EGPU_NO_DECKY_RESTART") != "1":   # test hook
        subprocess.Popen(["systemd-run", "--on-active=5", "--collect", "--quiet", "systemctl", "restart", "plugin_loader.service"], env=_clean_env())


def _update_worker(version):
    try:
        _update["state"] = f"installing {version}"
        _setup_worker("install", False, version)
        if _setup["rc"] != 0: raise RuntimeError(f"system integration install failed rc={_setup['rc']}")
        if _vt(version) > _vt(PAYLOAD_VERSION):
            _update["state"] = f"updating plugin to {version}"; _update_plugin_files(version)
        _update["state"] = f"updated to {version}"; _update["available"] = ""
        d = _settings(); d["last_update"] = version; _save_settings(d)
    except Exception as ex:  # noqa: BLE001
        _update["state"] = f"update failed: {ex}"; _update["last_error"] = str(ex); decky.logger.error(f"update failed: {ex}")


def _check_update(install=False):
    """Compare the installed integration with the latest release; optionally install it (never a first install)."""
    try:
        latest = _latest_release(); _update["checked"] = time.time(); _update["last_error"] = ""
    except Exception as ex:  # noqa: BLE001
        _update["last_error"] = f"check failed: {ex}"; return
    installed = _read(VERSION_FILE)
    # target = the newest of GitHub's latest release and the payload this plugin carries; the integration follows it
    target = latest if _vt(latest) > _vt(PAYLOAD_VERSION) else PAYLOAD_VERSION
    newer = bool(installed) and _vt(target) > _vt(installed)
    _update["available"] = target if newer else ""
    if newer and install and not _setup["busy"] and not _game_running():
        _setup.update(busy=True, rc=None, step="update", progress=0)
        try: os.remove(SETUP_LOG)
        except OSError: pass
        threading.Thread(target=_update_worker, args=(target,), daemon=True).start()


class Plugin:
    async def get_update_status(self):
        d = _settings()
        return {"auto_update": d.get("auto_update", True), "available": _update["available"], "state": _update["state"],
                "checked": _update["checked"], "last_error": _update["last_error"], "installed": _read(VERSION_FILE)}

    async def set_auto_update(self, enabled: bool):
        d = _settings(); d["auto_update"] = bool(enabled); _save_settings(d); return {"ok": True, "message": "saved"}

    async def check_update(self, install: bool = False):
        threading.Thread(target=_check_update, args=(bool(install),), daemon=True).start(); return {"ok": True, "message": "checking"}

    async def get_setup_status(self):
        tail = ""
        try:
            with open(SETUP_LOG) as f:
                tail = "".join(f.readlines()[-6:])
        except OSError:
            pass
        rc, out, _ = _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--check"], 5) if os.path.exists("/usr/local/sbin/egpu-kernel-cmdline") else (0, "", "")
        needs_reboot = False
        try:
            body = open(SETUP_LOG).read()
            needs_reboot = any(k in body for k in ("building the patched nvidia-open", "pinning NVIDIA userspace", "installed: nvidia-open-egpu-dkms", "writing the kernel parameters"))
        except OSError:
            pass
        return {"installed_version": _read(VERSION_FILE), "payload_version": PAYLOAD_VERSION, "needs_reboot": needs_reboot,
                "unsupported": _unsupported(),
                "cmdline_missing": out.replace("missing kernel parameters: ", "") if rc != 0 else "",
                "helpers_present": os.path.exists(PRIV) and os.path.exists(DETACH),
                "busy": _setup["busy"], "step": _setup["step"], "rc": _setup["rc"], "progress": _setup["progress"],
                "can_build_driver": bool(shutil.which("pacman")), "log": tail}

    async def apply_kernel_cmdline(self):
        rc, out, err = _sh(["/usr/local/sbin/egpu-kernel-cmdline", "--apply"], 120)
        return {"ok": rc == 0, "message": (out or err)[-300:]}

    async def restart_gamemode(self):
        if not _gamescope_running():
            return {"ok": True, "message": "Not in Game Mode: the new session pieces apply at the next Game Mode start."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first."}
        rc, out, err = _sh([SWITCH], 240)
        return {"ok": rc == 0, "message": "Game Mode restarted." if rc == 0 else (out or err)[-200:]}

    async def reboot_system(self):
        subprocess.Popen(["systemctl", "reboot"], env=_clean_env()); return {"ok": True, "message": "Rebooting"}

    async def install_system(self, with_driver: bool = False):
        return _start_setup("install", bool(with_driver))

    async def uninstall_system(self):
        return _start_setup("uninstall")

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
        decky.logger.info(f"attach pressed (force={force})")
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
        decky.logger.info("safe detach pressed")
        if not _gpu_bdf():
            return {"ok": True, "message": "No eGPU attached."}
        if not _gamescope_running():
            return {"ok": False, "message": "Not in Game Mode. Use the Safely Eject desktop icon."}
        if _game_running():
            return {"ok": False, "message": "Close the running game first, then Safe Detach."}
        # detached, with Decky's library path stripped (bash dies on it) and its output kept for post-mortems
        out = open("/tmp/egpu-buddy-detach.log", "ab")
        subprocess.Popen([DETACH], stdout=out, stderr=subprocess.STDOUT, start_new_session=True, env=_clean_env())
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
        await asyncio.sleep(90)
        while True:  # automatic updates: hourly check; install only if enabled, already installed, and no game running
            try:
                _check_update(install=_settings().get("auto_update", True))
            except Exception as ex:  # noqa: BLE001
                decky.logger.error(f"update check: {ex}")
            await asyncio.sleep(3600)

    async def _unload(self):
        decky.logger.info("EGPU Buddy backend unloaded")
