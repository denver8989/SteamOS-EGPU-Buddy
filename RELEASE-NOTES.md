0.7.39 — the second USB4 port works on any machine, not just the one it was written on.

Clearing PCIe Downstream Port Containment is what lets a USB4 port build a PCIe tunnel after the link has been
contained — on the development handheld, the **second** USB4 port would not form a tunnel at all without it. That fix
was gated to a single device ID (`1022:150a`, Strix Halo), so on every other machine it silently did nothing. A Legion
Go 1 is AMD Phoenix: the gate matched nothing there, and the clear never ran on either of its two USB4 ports.

It is now found by what the port *is*: a host root port that is a USB4/Thunderbolt tunnel bridge, with a DPC capability
discovered by walking its capability list. No device IDs.

Restricted to **host** root ports on purpose. Matching any tunnel bridge also caught the eGPU enclosure's own
Thunderbolt switch, which is not ours to write to. Verified on a real machine: it now finds exactly the two USB4 root
ports and nothing else.

0.7.38 — booting with the eGPU attached now gets the full 16 GiB BAR1, not 256 MiB.

Hot-plugging an eGPU has always produced a 16 GiB BAR1. Booting with it attached produced 256 MiB, and the resize was
refused with `write error: No space left on device`. The difference is not the card and not the driver: it is *when* the
device appears. A device that arrives after boot is placed in bridge windows sized with the reserve from
`pci=hpmemprefsize`; a device that is already there at boot keeps the windows firmware assigned for the BARs it had —
and a 16 GiB window, which must also be 16 GiB-aligned, does not fit in them.

So boot now makes itself look like a hot-plug: when the resize is refused, the eGPU's Thunderbolt subtree is taken down
and enumerated again, the kernel sizes the bridge windows afresh, and the resize is retried. Nothing is displaying at
that point in boot, so there is no session to disturb. Removing only the GPU is not enough — its parent bridge keeps its
window — so the bridge below the root port is what goes and comes back.

**It will not do this to hardware that is not yours.** The re-enumeration is refused unless every PCI function behind
that bridge is either part of the tunnel or the eGPU itself. A dock, a drive or a display controller sharing the path
stops it, by design: taking a bridge down takes everything under it with it. Checked against a real machine's topology,
where the tree also contains bus directories and PCIe port services that are not devices at all.

If the resize still cannot be done, the eGPU is used anyway at the smaller BAR — that has not changed since 0.7.34, and
the log now says what actually happened at each step instead of failing silently.

0.7.37 — quiet boot restored, and the handheld panel goes dark when the session starts on the eGPU.

**Every boot had become a wall of console text.** This project appends its kernel parameters after the distribution's,
and SteamOS's `steamenv_boot` rewrites the tail of that line — with anything appended behind them, it dropped
`loglevel=3 quiet splash plymouth.ignore-serial-consoles` entirely. The stock configuration keeps those four last, so
ours now go **before** them instead of after. Verified by comparing against the untouched configuration on the other
SteamOS slot, which is where the correct layout came from.

**The handheld panel stayed lit when the machine booted straight onto the eGPU.** Turning it off only ever happened on
the hot-plug switch path, never when the session started on the eGPU in the first place — so a boot with the eGPU
attached left the panel glowing behind a picture on the monitor. The session now applies the same rule: if the picture
is on an eGPU output, the panel goes dark. It cannot strand you, because the panel is only ever darkened when an eGPU is
actually mounted.

Also: the boot-time BAR1 message no longer claims Game Mode will fall back to the built-in screen. It says what is
actually true — the eGPU is used anyway, at lower bandwidth over Thunderbolt.

0.7.36 — the flood lockout is gone.

When the platform reset itself while the eGPU was connected (an AMD "data fabric sync flood"), this software set a
persistent lockout and refused every later attach until the user ran `egpu-rearm`. The intent was to break a reboot
loop. In practice it cost far more than it prevented:

- plugging the eGPU in did nothing, with no obvious reason why
- boot stalled for two and a half minutes waiting for a GPU it had already decided not to bring up
- and the way out was a command, on a device that may have no keyboard

The loop it guarded against is escaped by unplugging the eGPU — one action, obvious to anyone holding the device. So
the lockout is removed: an attach is never refused because of a past reset, and boot never waits on one.

**The reset is still recorded.** `flood-history` is what tells the interface that this machine resets when the eGPU link
drops, which is why it keeps a standing "always Safe Detach before unplugging" note. That record costs nothing and is
worth keeping; the refusal was not. Leftover lockout state from an older version is cleared automatically.

0.7.35 — this software could leave a handheld sitting at a boot menu. Update.

**A SteamOS machine could be left needing a keyboard to boot.** Applying the kernel parameters regenerates the GRUB
configuration with `grub-mkconfig` — and on SteamOS the result comes out with **no timeout directive at all**, so GRUB
waits at a menu forever. SteamOS's own configuration is not produced by `grub-mkconfig`, so it never had this problem
until this project regenerated it. On a handheld with no keyboard that is indistinguishable from a dead device; it
happened to a user, who had to find a keyboard to get the machine to boot, twice.

Fixed in two ways, because this one must not come back:

- The drop-in this project writes now also pins `GRUB_TIMEOUT=0` and `GRUB_TIMEOUT_STYLE=hidden`, so any regeneration —
  by us, or by anything else — produces a configuration that boots straight through.
- After regenerating, the generated file is **checked**: if it has no timeout directive, one is written into it. A
  config that stops and waits is never left behind.

**Boot no longer stalls for two and a half minutes after a hardware reset.** When the flood lockout is set — the guard
that pauses eGPU attach after the platform resets itself — the boot-time mount still waited 90 seconds for a GPU that
the lockout had already refused to bring up, while holding the login manager back. A user saw "A start job is running
for Session-independent eGPU compute mount (2min 39s)" and read it, reasonably, as a failed boot. It now skips
immediately and says so, and the unit's timeout no longer exceeds what the helper can use.

The hotplug memory window stays at the value that has always been shipped. Raising it was an untested guess at a
performance setting, and nothing depends on the BAR size any more.

0.7.34 — a small BAR1 no longer costs you the eGPU.

Booting with the eGPU attached still landed on the built-in screen after 0.7.32, and the reason was a requirement that
should never have been one.

**Game Mode refused the eGPU unless BAR1 had been resized to 16 GiB.** That is a performance limit, not a health check.
BAR1 can only be resized while the GPU has no driver bound, and on some boots it cannot be resized at all — the kernel
answered `write error: No space left on device`, because a 16 GiB BAR must be 16 GiB-aligned and shares the hotplug
window with the GPU's other BARs. So a perfectly healthy eGPU with the monitor connected sat unused while the session
ran on the handheld screen. The development machine this project was built on runs with ReBAR off entirely and is fine.

The readiness gate now asks what actually proves the GPU is alive — NVML responding, which a wedged initialisation
cannot do — and treats BAR1 as advisory, logging "BAR1 is 256MiB, not resized (lower performance over Thunderbolt, but
the eGPU is used anyway)".

Two supporting fixes:

- **The boot-time resize was failing silently.** It ran immediately after the FLR, while the GPU still reads as a zombie,
  and the helper refused it — but the loop threw the error away, so the log said nothing. It now waits for the device to
  come back and **logs the refusal reason** if it still will not resize.
- **The hotplug memory window is requested as 32 GiB instead of 16 GiB**, which gives a 16 GiB BAR room to be placed at
  boot, and the older copy of these parameters is removed from the base bootloader config so a stale value cannot sit
  next to the new one. This only affects performance; nothing depends on it any more.

0.7.33 — a stale DRM card no longer black-screens Game Mode.

Found live on a Legion Go 1 that booted to a black screen with the eGPU attached. Game Mode was not merely failing to
use the eGPU — the session was **crash-looping**, restarting every four seconds, which is why nothing was ever drawn.

A GPU can expose more than one DRM card. A driver reload, or a remove-and-rescan cycle, leaves a stale card behind that
has **no connectors on it at all**. On the failing machine `card1` and `card2` both belonged to `0000:65:00.0`, and only
`card2` carried the monitor. Everything in this project picked the *first* card under the GPU, so gamescope was aimed at
the dead one, exited immediately, took the whole session down with it, and systemd started the cycle again.

The rule is now: **take the card that has connectors**, in all five places that resolve one (the Game Mode session, the
display profile helper, the desktop autostart, the attach hook and the mount helper). A card with no outputs is never
chosen while one with outputs exists.

The visible symptom of this bug was every session service failing with "Failed to load environment files" — the stock
session writes that file only once gamescope reports its displays, and gamescope never got that far.

0.7.32 — booting with the eGPU attached now actually routes Game Mode to it.

Found on a real Legion Go 1 with an RTX 5060 Ti: the machine booted with the eGPU plugged in and the monitor switched
on, the eGPU mounted correctly, its display was connected — and Game Mode still came up on the built-in screen. The
session wrapper waited 25 seconds and gave up.

The reason was **BAR1 = 256 MiB**. Game Mode's readiness gate requires the resized BAR, and BAR1 can only be resized
while the GPU has no driver bound. The boot path deliberately skipped the resize and loaded the driver immediately, so
by the time anything else ran, the window had closed — and no amount of waiting could change it. A hot-plugged eGPU was
fine, because there the GPU is driverless when the resize happens. Only the boot-with-eGPU case was broken, which is
exactly the case nobody had tested.

The boot path now resizes BAR1 while the GPU is still driverless, before loading the driver.

The old rule that produced this ("no ReBAR at boot") came from one platform where a large BAR stops the driver
initialising. That is now handled by **detection instead of denial**: if the driver does not create a DRM card with the
resized BAR, the BAR is backed down to its original size and the driver is loaded again, so such a machine ends up
exactly where it was before rather than with no eGPU at all.

0.7.31 — drive the signal, because on many monitors the signal is what ends standby.

Two corrections, both from a live failure: a machine booted with the eGPU attached and the monitor in standby, and
nothing ever came up on either screen.

**The eGPU was not pushing a signal out at all.** A monitor in standby does not answer detection, so its connector read
"disconnected", so no compositor would put a mode on it, so no signal was driven — and the monitor had nothing to wake
up for. Asking politely in a loop could never break that circle. Now, when the probe gets no answer, the connector is
**forced on**: the kernel reports it connected, the compositor drives a mode, and that signal is what brings the monitor
back. The monitor's own reply (its EDID appearing) is taken as proof it really woke; if nothing replies after 20 seconds
of driven signal the force is released and the session stays on the built-in screen.

**The built-in panel now follows whether the eGPU mounted, not whether a monitor was detected.** Detection is the wrong
thing to hang it on, for the reason above. If the eGPU mounted, the panel goes dark and the picture is on the eGPU. The
panel only comes back if the eGPU failed to mount. The one thing still refused is darkening the panel when no eGPU is
mounted at all, which is what leaves a machine with no screen and no way back in.

0.7.30 — a monitor in standby counts as connected, and gets driven.

Correction to 0.7.29. That release would only turn the built-in panel off if an eGPU display was already **lit**, which
is the wrong test: a monitor in standby, or with its panel switched off, is still connected — it answers on DisplayPort
AUX / DDC and it wakes the moment a signal is driven at it. Requiring it to be lit first would refuse the very handover
that wakes it, and would keep the session on the built-in screen for a display that was perfectly available.

The test is now **connected, after asking**: every eGPU connector is probed first ("detect" makes the driver query the
monitor), and any connected output on a card that is not the built-in GPU counts. So a sleeping or panel-off monitor is
found, the session moves to it, and the signal wakes it.

The protection is unchanged for the case that caused the trouble: with no eGPU display connected at all, the built-in
panel is not turned off, and the machine is never left with no screen.

Checked on a machine whose only external display hangs off the built-in GPU: still refused, because that display is not
the eGPU's and darkening the panel for it would be wrong.

0.7.29 — the built-in screen is never turned off unless an eGPU display is actually lit.

**Update before booting with the eGPU attached.** A user booted with the eGPU plugged in and the monitor in standby and
ended up with **both screens dark**, on a machine that was otherwise working.

What happened: with the monitor asleep, no eGPU connector reported "connected". After waiting 90 seconds the switch-over
went ahead anyway, on the theory that the monitor was merely asleep and would light up later. The compositor relogged
onto the eGPU, the built-in panel was handed over and darkened — and the monitor never woke. No screen, no way back in.

Three fixes, smallest first:

- **`egpu-panel off` now refuses** unless a display on a card other than the built-in GPU is actually lit. That is the
  rule in one place, so every caller gets it; the deliberate teardown paths that darken the panel while they still own
  the picture pass `EGPU_PANEL_FORCE=1`. Verified on a machine with no eGPU: "refusing to turn the built-in panel off:
  no eGPU display is lit to replace it".
- **The 90-second wait no longer stages a session with nothing to show it on.** If no eGPU output answers, the session
  stays on the built-in screen and says so. That is safe *and* self-correcting: switching the monitor on fires a DRM
  hotplug that moves the session across by itself.
- **If the monitor disappears mid-switch**, the handover now puts the built-in panel back and re-enables it, instead of
  turning it off and leaving nothing.

**Booting with the eGPU attached and the monitor asleep also works now.** The driver always came up at boot, but a
monitor in standby does not assert hot-plug, so its connector read "disconnected" and the session went to the built-in
screen. Boot now forces a connector probe (the driver asks the monitor over DisplayPort AUX / DDC): a sleeping but
powered monitor answers and the eGPU gets the session. A monitor that is genuinely switched off still answers nothing,
the machine boots on the built-in screen as it should, and switching the monitor on moves the session over.

0.7.28 — the "not an eGPU" rule is vendor-neutral, and uninstall really does remove everything.

**The safety rule no longer hard-codes NVIDIA.** 0.7.27 refused to act on anything that was not an NVIDIA GPU, which
would have blocked AMD and Intel eGPUs from ever working. That was a sledgehammer. The rule is now the same one
`egpu-detect` has always used, and it is about being an eGPU, not about being NVIDIA: **a display-class PCI device that
does not drive the built-in panel.** Vendor-specific checks stay where they belong — in the driver actions that really
are NVIDIA-only.

What it refuses, checked on a live machine: the built-in GPU ("is the built-in GPU, not an eGPU") and a non-GPU device
such as the NVMe controller ("is not a GPU (PCI class 0x010802)"). Neither refusal mentions a vendor. An empty address
is still fine — that is an eGPU that has not enumerated yet. The same vendor-neutral test now decides which displays
belong to the eGPU, so a USB-C monitor or XR glasses on the built-in GPU can never be claimed by the eGPU path.

**Uninstall was leaving things behind.** It removed the installed files but not what this project writes at runtime, so
a reinstall was never really a fresh install. Now also removed: `/etc/nv-egpu-buddy`, `/var/lib/nvegpu` (lockout and
learned-device state), the installed GBM gamescope in `~/.local/gamescope-gbm`, `~/.local/lib/nv-egpu-buddy`, the
gamescope output routing file in `~/.config/environment.d`, and the project's logs.

**New: `uninstall.sh --verify`** lists anything still on the system and exits non-zero if there is any, so a clean
uninstall can be proven before reinstalling from scratch. When the uninstall came from the Decky plugin it reports the
plugin and its installed copy as deliberately kept — the plugin cannot delete itself mid-run, and it is what you
reinstall from.

0.7.27 — one rule, enforced at the root: hardware that is not an eGPU is never touched.

Every privileged action now refuses outright if the device it was pointed at is present and is not an NVIDIA GPU. That
is checked once, at the root-owned boundary that every attach, detach, reset, power and bus operation goes through, so
it holds for all of them at once instead of relying on each caller getting it right. An address with nothing at it is
still fine — that is an eGPU that has not enumerated yet, and waiting or rescanning for it touches nobody else's device.

Verified against the built-in GPU: `remove-gpu`, `reset-gpu`, `dpc-off`, `load-nvidia` and `status` all refuse with
"is not an NVIDIA GPU (vendor 0x1002); refusing to touch it".

The recovery tool no longer resets a hard-coded bridge either. It finds the GPU by vendor and class, takes that card's
own parent bridge, and refuses the Secondary Bus Reset if anything that is not part of the eGPU sits behind it — a bus
reset hits every device under the bridge, so a dock or a drive there must never be caught by it.

0.7.26 — an external display is never mistaken for an eGPU, and a dock is never mistaken for an enclosure.

Follow-up to 0.7.25, from auditing every place that decides "there is an eGPU here" rather than waiting for the next
report. Two more classes of mistake were found, both able to affect people who own no eGPU at all.

**A display was attributed to an eGPU by address alone.** Every "is this monitor the eGPU's?" test compares the card
driving the connector against one PCI address. If that address was wrong — and until 0.7.25 it could fall back to the
development handheld's slot — an ordinary external display was handed to the eGPU path. Demonstrated on a machine with
no eGPU: forcing the wrong address made the Game Mode session claim the DisplayPort output of the built-in GPU. The
ownership test now also requires that the card really is an NVIDIA GPU, checked where ownership is decided and not only
where the address is resolved, so a wrong address can no longer produce a wrong answer. The same check was added to the
attach helper.

**A Thunderbolt dock was treated as an eGPU enclosure.** Any USB4/Thunderbolt device arriving fires the same event as
an eGPU box. With no GPU behind it, this software would clear the port's error containment, **de-authorize and
re-authorize the device** — which drops a dock and any display attached to it — and rescan the bus, on every plug. At
boot it would poke the bus and wait 30 seconds for a GPU that was never coming. Now:

- A device that has been through the full bring-up three times without ever producing a GPU is left completely alone
  from then on. Three, not one, because a real enclosure's PCIe tunnel is slow and racy and can genuinely miss a plug.
- Any successful attach clears that judgement, and **pressing Attach always tries anyway** regardless of it.
- The boot path does not poke the bus or wait at all on a machine where no eGPU has ever attached. A dock-only machine
  boots straight through.

Nothing here changes behaviour on a machine with a working eGPU.

0.7.25 — with no eGPU connected, this software now does nothing at all.

**Update if you use any other external display: a USB-C monitor, a dock, or XR display glasses.**

Several components fell back to the development handheld's PCI address (`0000:62:00.0`) when no NVIDIA GPU was
detected, instead of concluding that there is no eGPU. On another machine that slot can hold something else entirely,
and one component collapsed an empty address into a path that always exists — so an ordinary external display could be
treated as an attached eGPU. The visible result was the software rearranging a display layout it has no business
touching: the built-in panel forced back on as the primary screen while you were using glasses or a USB-C monitor, and
Game Mode waiting on an eGPU that was never there.

Fixed in the four components that run by themselves:

- **The display failover watcher** now stays completely idle unless an NVIDIA GPU is on the bus or it was the one that
  darkened the built-in panel. It was the component that pushed the panel back to primary, at 5-second intervals,
  against whatever you had set up.
- **The desktop display autostart** no-ops when there is no eGPU, rather than acting on a path that always exists.
- **Game Mode** checks the vendor of the device it finds before believing it is an eGPU, so an unrelated device in that
  slot no longer costs a 25-second wait at session start.
- **The display profile helper** takes the fallback address only when that slot really holds an NVIDIA GPU.

No hardware value is assumed anywhere in these paths any more: the eGPU is found by vendor and class, or it is absent.

Found by a user running external display glasses on a Legion Go 2 with no eGPU attached.

0.7.24 — critical: a detach could leave the machine unable to start any Vulkan game.

**Update immediately if you have ever used Safe Detach or unplugged the eGPU.**

While the eGPU is attached, the session is pinned to the NVIDIA Vulkan driver (`VK_DRIVER_FILES`). Detaching hides that
driver file, as it must, because the card is gone — but nothing cleared the pin. The Vulkan loader then reports
`vkCreateInstance: Found no drivers!` and **every Vulkan game fails to start**, on the built-in GPU, with the eGPU not
even connected. Games hang on Steam's launch screen or crash immediately, and nothing points at this software as the
cause. A second variant set the same variables to an empty string, which the loader also reads as "no drivers at all".

Fixed in all three paths that move you back to the built-in GPU: Safe Detach, the desktop Safe Detach tool, and the
surprise-unplug recovery. They now clear the pin so the loader finds the built-in GPU's driver again.

**Already affected machines repair themselves.** Every session start now checks whether the Vulkan pin names a file
that exists, and clears it if not. That runs in both Game Mode and the desktop, so a reboot or a session restart is
enough; no manual repair and no reinstall. A valid pin is left alone.

Found on the development machine after a detach, by a user who reported that every game had started failing.

0.7.23 — everything SteamOS: a real device found what a container could not.

Tested end to end on a Legion Go (SteamOS 3.8, kernel 6.16 valve) with an RTX 5060 Ti in an AORUS TB5 box on a
5120x1440@144 ultrawide: install, driver, attach, a game in Game Mode, Safe Detach, replug, surprise unplug, and the
same again on the desktop. Every fix below came from that session. **Nothing changes on CachyOS / Legion Go 2 unless
it is named as a fix there.**

**The eGPU could never attach on a clean machine.** The display half of the driver was only loaded when
`/etc/nv-egpu-buddy/surprise-removal-safe` said `yes` — a file created by hand on the development machine and shipped
by nothing. Everywhere else the attach loaded the compute driver, said "display stack ready", and Game Mode fell back
to the handheld screen after a 25 second wait. The proof is now read from the installed modules themselves (strings
only this project's patches add), so it is true wherever the patched driver really is installed.

**The desktop ran on both GPUs instead of the eGPU alone.** `~/.config/plasma-workspace/env/00-egpu-free-nvidia-modeset.sh`
— the hook that pins the compositor to the eGPU and keeps the built-in GPU out of the session — also existed only on the
development machine. That hook *is* the anti-crosstalk mechanism; without it the desktop came back extended across both
GPUs after an attach. It is now part of the install.

**Game Mode composited on the built-in GPU.** Where the distribution's gamescope carries file capabilities (SteamOS),
the Vulkan loader ignores the environment this project uses for NVIDIA routing. The session now names the eGPU on the
command line instead, where capabilities cannot strip it.

**The picture was corrupted on SteamOS** because the GBM-scanout gamescope is built on CachyOS and cannot run there, so
the session silently fell back to the distribution's. A SteamOS build is now shipped, and the installer picks whichever
shipped build actually runs on the machine, by trying them, not by distribution name. If none runs it builds one on the
device. Both builds link the system EDID library so HDR metadata is read the same way everywhere.

**The Steam UI was 1080p on a 5120x1440 display.** SteamOS's session script hardcodes an inner resolution; it is now
dropped when this project stages a native canvas, so the UI follows the monitor's real mode.

**Login manager, sessions and Safe Detach.** All session pinning wrote CachyOS's login-manager file, which SteamOS
ignores, so a desktop Safe Detach came back in Game Mode and could not finish. One helper now detects the login manager
and the real session file names on both. The pin is released once the session it was for has returned, so "Return to
Gaming Mode" is not overridden. The password-less sudo rules were being outranked by SteamOS's own `wheel` rule because
of the file name; they now sort last and apply, which is what the desktop app's Safe Detach needs.

**Decky vanished after a detach.** Its backend holds `/dev/nvidia*`, so the driver unload killed it and nothing brought
it back: Game Mode returned with no plugins at all. Both the planned detach and the unplug recovery restart it now.

**A cable pull reset the machine.** On a USB4 root port without Downstream Port Containment the surprise removal raised
a fatal error and the platform answered with a data-fabric sync flood, i.e. an instant reboot. The attach now masks the
uncorrectable errors that port accepts and makes them non-fatal, by capability, so ports that have containment (Legion
Go 2) are untouched. With that in place the same yank recovered in eight seconds with the session back on the handheld.
If a reset does happen, the automatic attach pauses, says so, and the plugin offers Repair; every such reset is
remembered and the plugin keeps a standing "always Safe Detach" note for that machine.

**The handheld panel stayed lit and black in eGPU mode.** Turning it off gave up whenever anything held its graphics
card, which is always true in eGPU mode. The backlight is now powered down and zeroed regardless, and restored on the
way back.

**Desktop app and launchers.** The app is a native Qt/QML window with a system-tray icon instead of a browser tab
(SteamOS has no WebKitGTK), the tray runs as a user service so it survives the compositor restarts this project
performs, and "EGPU Buddy" and "Safely Eject eGPU" are installed to the menu and the desktop. Re-attach reports what
happened instead of failing silently.

**Also:** the plugin's update backup no longer lives inside Decky's plugin folder, where Decky loaded it as a second
copy of the plugin and kept running the old version after every update; the driver extension ships this project's own
driver package files (modprobe options, hotplug rule) without dragging a compiler along; the unplug recovery waits for
a working display before restarting Steam, so no "cannot open display" dialog; card numbers, the dock and the audio
route are looked up instead of assumed, so a machine that enumerates its GPUs the other way round works.

0.7.22 — SteamOS: installing again over a working install no longer fails; updates are plugin first, system files second.

- **SteamOS, found on a real Legion Go with 0.7.21:** the first install went through and the driver extension merged,
  but any later install (update, repair) failed with `cannot remove '/usr/local/sbin/...': Read-only file system`. On
  SteamOS `/usr/local` belongs to the system partition, and a merged system extension turns all of `/usr` into a
  read-only overlay. The installer and the uninstaller now unmerge the extension first and merge it again on every
  way out; they refuse (changing nothing) while the NVIDIA driver is loaded: Safe Detach and unplug first.
  The test container had mounted `/usr/local` separately, which SteamOS does not do; it now matches the device,
  reproduces the 0.7.21 failure and passes with 0.7.22.
- **An update is two separate jobs, plugin first:** the plugin replaces itself (seconds) and Decky restarts; the new
  plugin then installs the system files it carries, with its own code and its own progress view, and reports the
  result in a notification. Old plugin code no longer drives a newer installer. If the second half cannot start
  (a game is running), the first page offers **Update system integration**.
  Updating *from* 0.7.21 or older still runs in the old order once, because that plugin's code is what runs it.
- The log of the previous install run is kept (`/tmp/egpu-buddy-setup.log.prev`): a retry no longer erases the first
  failure.
- Nothing in the attach, detach or recovery paths changed; CachyOS / Legion Go 2 behaviour is untouched.

0.7.21 — SteamOS: fix for the install failure found on a real device; an honest progress bar; a visible finish line.

- **SteamOS, found on a real Legion Go:** the driver compiled, then the install stopped at `overlay: case-insensitive
  capable filesystem ... not supported`. SteamOS formats `/home` as ext4 with case-folding and its kernel's overlayfs
  refuses directories there, which also rules out a directory-based system extension. The extension is now one
  squashfs image (about 520 MB instead of a 1.5 GB directory) and the module dependency step works on tmpfs. If you
  hit this: press **Repair**; the compiled driver is reused, it takes about a minute. Verified in the test container
  (now with a case-folding `/home`); the merged extension is still unconfirmed on a real device, see `TESTED.md`.
- A failed driver step no longer ends in "done": the installer says the driver was not built and the plugin shows it,
  with a **Repair** button, until the driver really is there. The state is read from the system, so it is the same
  after closing the menu, a Decky restart or a reboot.
- The message when you plug the eGPU in without a driver now says what to do (wait for a running build, or Repair).
- **Much shorter driver build on SteamOS:** the compile ran on one CPU core (makepkg's default); it now uses all of them.
- **Progress bar:** percentages follow measured time per stage, the compile advances with its real output, the line
  under the bar is a short plain label that fits, a running clock shows it is alive, and the expected duration is
  stated before you start and while it runs.
- **Finish line:** a notification appears when the install ends, also when the menu was closed or Decky restarted
  meanwhile.
- **Updates:** the update button only appears when a newer release was detected and the setup is complete; a first
  install is never mixed with an update. A plugin left behind by an interrupted update is brought level on its own,
  without reinstalling the system files.
- Nothing in the attach, detach or recovery paths changed; CachyOS / Legion Go 2 behaviour is untouched.

0.7.20 — one click really is one click: no separate "Apply kernel parameters".

- The install always wrote the kernel parameters as its last step, yet the plugin showed a second "Apply kernel
  parameters" button: after every install until the reboot (it only looked at the running kernel), and after an install
  that had died before its last step. Now the first page says **Reboot to activate** when the parameters are written
  but not active yet, and an incomplete setup is handled by the one Install / Repair button. The Apply button is gone.
- The installer now checks that the parameters are **persisted in the bootloader configuration**, not merely present in
  the running kernel. On the development machine the boot entries had been edited by hand while the file they are
  regenerated from still held an older set; a kernel update would have brought the old parameters back unnoticed.
  `egpu-kernel-cmdline --written` / `--pending` report these states.

0.7.19 — plugin: a calm first page; the disclaimer is a dialog, not a banner.

- The first page shows the eGPU state and the controls. When something needs you there is one short neutral line and
  one button; the explanation is in the dialog that opens. No coloured paragraphs; colour is kept for a failure and for
  the live attach/detach status.
- The untested-hardware notice is a dialog that must be accepted once, before the first install **or update**, also
  on a machine where an earlier partial install had let it slip past. It no longer sits on the first page; the Setup
  page keeps the note, together with the kernel-parameter details.
- One button per job: the separate "Update now" pair only appears when a newer release exists (it used to show next to
  "Update system integration" for the same version).
- On SteamOS the dialog states the real duration (15-20 minutes the first time).
- With automatic updates switched on, untested hardware still never installs in the background before the notice was
  accepted.
- Each release page now carries only its own notes (all existing pages were rewritten accordingly).

0.7.18 — updates are opt-in, and the update controls are where you can find them.

- **Automatic updates are off by default.** A new release is announced on the first page with an Update button; it
  installs by itself only if you switch Automatic updates on in Setup. (Anyone who had switched it on keeps that.)
- **Check for updates** is now a button at the bottom of the plugin's first page. Before, it was only on the Setup page,
  which is reached by pressing the top button twice, and was reported as missing.

0.7.17 — SteamOS: the patched driver without touching the 5 GB system partition; self-healing across OS updates.

- Measured on Valve's SteamOS 3.8.14 image: 870 MB free on the system partition, the tested driver needs 1.5-2.1 GB,
  `/var` is 256 MB, no compiler, and Arch's 610.57.04 userspace needs `egl-wayland2`, which SteamOS 3.8 lacks. The old
  approach could not work there. Patching SteamOS's own 575 driver was ruled out: the hot-unplug patches do not apply.
- New on SteamOS: the same tested 610.57.04 driver is built in a SteamOS build environment on `/home` against the
  exact running kernel and delivered as a systemd system extension on `/home`; kernel parameters as a GRUB drop-in;
  the integration's `/etc` files registered with the OS updater; the self-heal service re-activates the extension at
  boot and rebuilds the modules after an update that brings a new kernel. See README, "Surviving OS updates".
- **On SteamOS only**, the attach script refuses to bring the eGPU up while the driver or the kernel parameters are
  missing (the window after an OS update) and says so in the plugin. No other system gets this gate.
- Nothing SteamOS-specific is applied elsewhere: on CachyOS and Arch the distro's own NVIDIA packages are kept, the
  driver step pins nothing when the installed userspace already matches, and attach/detach behave as in 0.7.16.
- The userspace packages are installed as checksum-verified local files instead of by URL (an older keyring does not
  know newer packagers).
- Safe Detach hides the NVIDIA userspace with bind mounts where `/usr` is read-only.
- The plugin runs the installer in its own systemd unit: a Steam or Decky restart no longer kills a long install.
  Install and uninstall from the plugin need no password.
- The plugin re-checks for updates when it is opened and the last check is older than ten minutes (the hourly timer
  only counts awake time, so after a night of sleep it showed a stale "up to date").
- Uninstall also removes the driver extension, the build environment, the keep-list and the GRUB drop-in.
- The installer no longer treats a failed udev/systemd/user-session reload as fatal (install at boot, chroot).
- Verified in a container built from Valve's image (TESTED.md). **Not yet run on a real SteamOS device.**

0.7.16 — first real SteamOS install attempt (Legion Go, SteamOS): install failed; fixed. Untested-hardware notice.

- **"Install failed (rc 1)" on SteamOS.** Near its end the installer records the installed NVIDIA package versions for
  the self-heal. On a system where `nvidia-utils` is not installed the version query fails, and under the installer's
  strict error mode that one failed query ended the whole install, just before the kernel parameters were written
  (everything before it had been installed). Fixed; the installer was audited for the same pattern.
- **SteamOS ships pacman without a keyring**, so every package step failed ("keyring is not writable", "required key
  missing"). The installer now initialises and populates the keyring once when it is missing, and the driver step
  installs the kernel's matching `-headers` package by itself.
- **Untested-hardware notice (requested earlier, missing from the stable line until now).** The plugin, the `.run` and the
  terminal install compare the machine with the one tested configuration (Legion Go 2, RTX 5060 Ti, CachyOS); when
  anything differs they say what, state that the project has not been tested there and that you install and test at
  your own risk, and install nothing until you accept. The plugin keeps a one-line reminder on its first page.
- Honest status for SteamOS: still **experimental and unverified**. SteamOS's repositories carry NVIDIA 575.64.05, the
  patched driver here is 610.57.04; the installer pins the 610 userspace from the Arch archive and builds the patched
  modules for Valve's kernel, and none of that has been confirmed on a SteamOS machine yet.

0.7.15 — games black after a re-attach, and the cable-yank recovery, both fixed and verified on real replugs.

- **Every game black (or crashing at launch) after re-attaching the eGPU, until a reboot.** The Steam UI was fine, games
  rendered on the eGPU but never reached the screen. Cause, A/B-tested four times on one boot: resizing the GPU's memory
  window (256 MB -> 16 GB) right before the driver loads leaves the card in a state only a fresh enumeration clears. A
  cable pull resets the window to 256 MB, so every replug ran into it. The attach now skips the resize when the window
  already is 16 GB (software re-attach), and after a real resize removes and re-scans the GPU once and resets it again
  before the driver loads (about two seconds, no session involved). Verified: Safe Detach -> unplug -> replug -> play.
- **Cable yank in Game Mode.** The recovery could not tell it was in Game Mode once gamescope had died with the card,
  took the Desktop route (three relaunches over four minutes, measured), and left Desktop display variables
  (WAYLAND_DISPLAY, DISPLAY, KWIN_RENDER_NODES) in the user environment until the next reboot, which by itself made
  game windows invisible. Now: the session records its type, the recovery detects it first, applies no Desktop routing
  in Game Mode and clears any stray variables, never touches the relaunched session, and the session script stops
  waiting as soon as the eGPU leaves the bus. One relaunch, no Steam restart. The Game Mode attach clears the same
  variables as a second line of defence. Verified: yank -> handheld back -> replug -> play.

0.7.14 — two attach fixes found while testing on the eGPU.

- **Panel stayed on next to the eGPU display after an automatic hot-plug (Desktop).** The attach script's panel-off
  step ran as a background job; the script is a transient systemd service, and when its main process exited systemd
  killed the job. It had only ever completed when the script was run by hand. The script now waits for it.
- **The boot_vga step in the attach never ran.** Its functions were defined after the script's `exit`, so the call
  failed silently every time since August. The NVIDIA-only session works on the compositor device pinning alone, so
  the dead step was removed rather than switched on; README and credits corrected (all-ways-egpu's technique is now
  used only by the experimental non-NVIDIA path in the 0.8.0 betas).

0.7.13 — hot-plug after a Desktop safe-detach left both screens on (KWin on both GPUs).

- The Desktop safe-detach hides the NVIDIA userspace (Vulkan/EGL ICD files, NVML) so nothing re-opens the card. A
  later hot-plug never un-hid them: the login-time routing script saw them missing, left KWin at its default, and the
  desktop came back on both GPUs with the handheld screen still on. The attach now restores them before restaging the
  session. (Seen 2026-09-18; the Reattach button already did this, the automatic hot-plug path did not.)

0.7.12 — one version, every build kept, credits completed.

- The plugin now carries the release version; the first page shows a single "EGPU Buddy 0.7.12" (with "system files
  x.y.z, update pending" only while an update is in flight).
- Releases are no longer removed when a newer one is published; older builds stay on the Releases page.
- Credits: the USB4 link-stability lineage (damianbienias32's method, the open-gpu-kernel-modules #979 thread, nikomiiller,
  Alex Forencich's setpci recipe, DamianKA1993's blackwell-egpu-manager), all-ways-egpu's boot_vga technique stated
  precisely, and a "related projects, no code shared" list (egpu-switcher, eGPUBridge, eGPU-Blackwell-Stability).
- README roadmap: separating the NVIDIA-specific layer from the generic eGPU path.

0.7.11 — no audio after an interrupted detach. The Game Mode detach stops WirePlumber to release the eGPU's audio card
and restarts it at the end; the detach that Decky's restart killed (0.7.7 story) never reached that line, leaving only a
dummy sink. The detach now restarts WirePlumber on any exit, and the plugin restarts it whenever it finds it down outside
a detach.

0.7.10 — plugin: the progress bar is now a plain, full-width bar drawn by the plugin (the UI kit's bar rendered inline
next to its label and ran off the panel on every display). Used for installs, updates and repairs alike.

0.7.9 — plugin: with no eGPU the details page says just that (one line plus the session) instead of a wall of empty
metrics; the tab switcher is labelled by what it opens ("Show setup & updates"), never like an action; Reinstall in
Setup asks first and says what it does; the raw PipeWire placeholder no longer shows as the audio sink.

0.7.8 — plugin: "Safe to unplug the cable" now goes away by itself once the enclosure is actually unplugged (no
Thunderbolt/USB4 device enumerated and no GPU on the bus).

0.7.7 — Safe Detach and the updater no longer fight each other.

- **Cause of the dead Decky after a detach:** the plugin's automatic update ran 90 s after Game Mode started and
  scheduled its Decky restart exactly while Safe Detach was running as a child of the plugin. The stop hung on that
  child, systemd killed the whole group after 15 s (Decky, the plugin and the half-finished detach), and the failed
  restart left Decky down.
- Attach, Safe Detach and the Game Mode restart now run as transient system services outside Decky's process group;
  a Decky restart cannot interrupt them. Their output goes to /tmp/egpu-buddy-{attach,detach,switch}.log.
- The updater never acts while an attach/detach is pending or a game runs, and not in the first five minutes of a
  session; the Decky restart after a self-update is a try-restart.
- Attach and Safe Detach ask for confirmation and explain what will happen (screen goes dark, reopen the menu, it
  says when it is safe to unplug). The first page shows the operation state in colour and "Safe to unplug the cable."
- After "Restart Game Mode now" the post-install message no longer reappears.
- The surprise-removal recovery also skips when a Game Mode detach is in progress.

0.7.6 — plugin: the install/update progress row overflowed the Quick Access panel (long single-line stage text); it is
now the panel's item-style bar with a wrapping, length-capped description.

0.7.5 — plugin: Safe Detach from Game Mode did nothing. The detach script was launched with Decky's library path, so
bash died on a readline symbol before doing anything, silently. Same class as the 0.7.2 installer fix; the last plain
spawn in the backend is now cleaned too, and the detach's output goes to /tmp/egpu-buddy-detach.log.

0.7.4 — two boot/reboot mistakes fixed.

- **Booting with the eGPU attached landed on the Desktop.** The hot-plug script, when it brought the card up during
  boot, pinned the autologin session to the desktop before any session existed, overriding the Game Mode boot policy.
  It now only does that when re-logging an already running desktop session.
- **After an update the plugin offered a full system reboot.** Script updates need none: the plugin now offers
  "Restart Game Mode now" and only asks for a reboot when the driver or kernel parameters actually changed.
- The boot-enumerate unit no longer carries a free-text Documentation line that systemd rejected.

0.7.3 — plugin updater follows the newest of GitHub's latest release and the payload the plugin carries, so an
integration older than the plugin is brought up without a download; plugin self-replacement only when the release is
newer than the plugin's own payload.

0.7.2 — plugin: installs and updates launched from Decky failed with `bash: undefined symbol: rl_trim_arg_from_keyseq`
because Decky's Python exports its own LD_LIBRARY_PATH; the plugin now strips it for everything it spawns. Found by the
first real unattended update attempt.

0.7.1 — plugin: the update check works inside Decky's bundled Python (it has no certificate store; the distro's CA bundle
is now used), the first page shows plugin version, integration version and update state, and Attach/Safe Detach presses
are logged.

0.7.0 — automatic updates from the Decky plugin. Hourly check of this repository's releases; with *Automatic updates* on
(default) a new release installs the system integration (verified tarball, same installer) and replaces the plugin's own
files, reloads Decky and asks for a reboot; never while a game is running, never as a first install. *Update now* and
*Check for updates now* buttons; the toggle lives in Setup. The driver package is no longer rebuilt when the installed one
already matches the release.

0.6.3 — picture back after resume from suspend. A new system unit runs after every resume: when an eGPU display is
connected it forces the modeset (VT round-trip) that the NVIDIA DisplayPort link needs to re-train, then re-darkens the
handheld panel. Root cause 11. The privileged helper gained `panel-off`/`panel-on`.

0.6.2 — Game Mode on the eGPU no longer capped at 60 Hz. The session wrapper kept a 60 Hz ceiling from the corruption
era (it chose the output mode and handed Steam a 40–60 limit, so the refresh slider snapped back to 60 each session).
The cap is gone: the display's best mode is used (5120×1440@144 on the tested monitor) and Steam's slider spans 40 to
that. `NV_EGPU_GAMESCOPE_MAX_REFRESH` in the session drop-in caps it again if a display misbehaves.

0.6.1 — no more "update available, restart Steam" loop on the eGPU.

- The eGPU desktop Steam launcher now stays on the same client branch as Game Mode (`steamdeck_stable`, `-steamdeck`),
  so switching between the eGPU desktop and Game Mode no longer makes Steam reinstall the other branch, nag for a
  restart, and break Decky on that restart. Games launched from the desktop get `SteamDeck=0` so they keep their
  normal resolution lists. Root cause 10 in docs/ROOT-CAUSES.md.

0.6.0 — the eGPU display no longer stays dark after the monitor sleeps.

- **Wake guard** (`egpu-wake-guard`, user service): NVIDIA leaves the DRM connector off after a monitor sleep while the
  compositor thinks it is on (open-gpu-kernel-modules #1055/#1028); moving the mouse then shows nothing until a
  suspend/resume. The guard sees the input, notices the connector is still off four seconds later, and performs the VT
  round-trip that a suspend would, automatically. Root cause 9 in docs/ROOT-CAUSES.md.

0.5.0 — survives OS updates that wipe /usr (SteamOS-style).

- **Self-heal.** The install keeps the whole release, a pacman package cache (nvidia-utils, lib32, bolt, dkms, the
  patched driver package) and the patched modules for the running kernel under `~/.local/share/steamos-egpu-buddy`,
  and enables `egpu-buddy-selfheal.service` (unit in /etc, script in /home). At boot it re-applies the root-side
  integration when missing or outdated, restores cached packages, rebuilds or restores the kernel modules, and
  re-applies the kernel parameters. The plugin offers **Repair system integration** for the same on demand.
- SteamOS is therefore installable again (experimental, untested on a real update); the 0.4.2 refusal is gone.
- The uninstaller disables the self-heal unit and removes the kept copy.

0.4.2 — surviving updates, and the truth about SteamOS.

- **pacman hook** `egpu-buddy-post-upgrade`: after every transaction it checks the private GBM gamescope against the
  updated libraries and rebuilds it (or logs the fallback), and reports when the patched DKMS modules are missing
  for the newest kernel.
- **IgnorePkg** is appended to, never replaced (0.4.1 and earlier overwrote an existing line).
- **SteamOS itself is declared unsupported** and the installer/plugin refuse there unless overridden: its updates wipe
  `/usr`, it has no NVIDIA driver and no kernel headers. Targets are Arch-based handheld distros (CachyOS tested);
  Bazzite untested and without the patched driver. README has a "Surviving OS updates" section.

0.4.1 — SteamOS accounts without a password: the `.run` and the one-line installer detect it and have you set one
first (terminal prompt); the Decky plugin route never needed one, since Decky runs the plugin's backend as root and the
installer in root mode does not call sudo. README says which route needs what.

0.4.0 — one press, no choices.

- **The plugin's Install button and the `.run` install everything**: hot-plug core, session integration, GBM
  gamescope, boot policy, desktop app, the patched hot-unplug driver (Arch-based), the NVIDIA userspace pinned to the
  exact version the patched modules are built for (from the Arch Linux Archive, kept by IgnorePkg), and the kernel
  parameters written to the bootloader. No driver toggle, no questions. `--advanced` on the `.run` keeps the
  component checklist for people who want it.
- **First-ever connection on a fresh machine**: the hot-plug script now authorizes the Thunderbolt dock itself
  when boltd has not (Game Mode has no consent prompt), for security levels user/none/dponly, and enrols it with an
  auto policy; higher security levels are reported and need a one-time enrol from the desktop.
- **USB4/Thunderbolt stack**: the installer loads the `thunderbolt` driver at boot (modules-load.d), installs bolt where
  missing, and warns when no USB4/Thunderbolt controller is visible (firmware setting).
- The patched driver package now requires `nvidia-utils` of exactly its version, so a mismatched userspace cannot
  be left behind.

0.3.3 — safe first plug-in on a fresh machine.

- **Kernel command line is now handled.** New `egpu-kernel-cmdline --check/--apply` (rpm-ostree, Limine, GRUB,
  systemd-boot; backups kept). The installer reports what is missing and offers to write it; the plugin's first
  page shows an Apply button when the running kernel lacks the parameters. Earlier releases only documented them.
- **NVIDIA packages.** The installer offers to install `nvidia-open-dkms` + `nvidia-utils` with pacman when
  nvidia-smi is missing (the plugin route does it automatically).
- **Graphical installer fixed.** The `.run` GUI path ran `sudo` without a terminal, so on any machine that asks
  for a password it would have failed; it now asks with a dialog once and reuses it.
- README: a "Before you start" block: install and reboot with the eGPU disconnected, why, and what is assumed.

0.3.2 — simpler ways in.

- **Decky plugin: one press.** When the system integration is missing or outdated, the plugin's first page shows a
  single Install button; a progress bar reports the stages inline, then a Reboot button. No tab hunting, no double
  confirm. The Setup tab keeps the driver toggle and Uninstall.
- **One-line installer** (`get-egpu-buddy.sh`): fetches the latest release, verifies the SHA-256, offers to install
  Decky Loader from its official installer if missing, then runs the installer.
- README: the three install methods are outlined step by step.

0.3.1 — one build, two ways in.

- **Decky plugin can install everything.** New Setup tab: "Install system integration" runs `install.sh` as root
  from the payload bundled inside the plugin (no internet needed), with a progress bar driven by the installer's
  stages (core, session, prebuilt GBM gamescope, boot policy, desktop app, optional patched-driver build on
  Arch-based systems). Uninstall from the same tab. The installer gained a root mode for this
  (`EGPU_TARGET_USER`), creating user files as the login user. `EGPU-Buddy-Decky-0.3.0.zip` is the plugin for
  Decky's "Install from URL". The plugin is part of this repository (`decky-plugin/egpu-buddy`).
- **Driver install fixed.** The `--with-driver` step (and the plugin's driver toggle) now builds the
  `nvidia-open-egpu-dkms` package from the shipped PKGBUILD with makepkg and installs it with pacman. The 0.1.x–0.3.0
  script only copied modules that existed on the maintainer's machine and would have failed anywhere else.
- Plugin: GPU detection generalised to any NVIDIA VGA device (was pinned to one device ID); the Desktop hint no
  longer names another project.
- Desktop app icon: the eGPU box as a blue duotone illustration with the hot-plug bolt.
- All earlier releases (0.1.0–0.2.0) were removed; this is the only build.

Tested on the tested machine: the plugin's install route end-to-end as root against the live system (no drift
afterwards). SteamOS and Bazzite untested.

0.2.0 — standalone.

- **No references to any other project.** The Go Hub tray-app hooks that were guarded in 0.1.x are gone from the
  attach/detach scripts. In their place: `/etc/nv-egpu-buddy/hooks.d/{pre-unload,post-attach,post-detach}/`, where
  anyone can drop their own executables. Nothing is shipped there.
- **EGPU Buddy desktop app** (`desktop-app/`, component `desktopapp`, on by default): telemetry, power limit, reset
  clocks, Safe Detach, Re-attach for the docked Desktop. GTK 4/WebKitGTK window with browser fallback. Backend on
  127.0.0.1:8772 uses only the shipped helpers. New icon, `EGPU Buddy` menu entry, removed by the uninstaller.
- **sudoers fix.** 0.1.x only whitelisted the privileged helper, so the Desktop Safe Detach tool (`sudo -n
  egpu-safe-detach`) would have asked for a password or failed on a fresh install. The rule now covers
  egpu-safe-detach, egpu-reattach, egpu-gamemode-switch/-detach and egpu-rearm.
- Holder kill list before driver unload no longer names foreign apps; use a `pre-unload` hook for yours.

Tested on the tested machine: desktop app backend (status + guards) and the installer component; the GTK window
was not opened by the maintainer's automation (launch it yourself). Scripts otherwise unchanged from 0.1.2.
SteamOS and Bazzite untested.

0.1.2 — installer warns about missing runtime tools (setpci, modetest, jq, xxd, perl, qdbus6, kscreen-doctor, xprop, boltctl, nvidia-smi); README states what is and is not required (no Go Hub, no LACT, no desktop tray app). No script changes.

0.1.1 — two hot-plug regressions found the day after 0.1.0, both on the tested machine.

- **Desktop Safe Detach re-logged into Game Mode with a dark handheld panel.** The KWin restart ends the login and
  the boot policy chose Game Mode; that gamescope started with an inactive seat and never lit the panel. Fixed:
  the detach pins the re-login to the desktop, and the session wrapper bounces the VT if the panel is still off
  12 s after gamescope starts (`nv-egpu-buddy-privileged vt-bounce`). Root cause 7 in docs/ROOT-CAUSES.md.
- **Hot plug on the Desktop left a frozen image on the handheld panel.** KWin runs NVIDIA-only and cannot disable
  `eDP-1`; the hot-plug script now turns the unowned CRTC off itself. Root cause 8.
- The boot policy now writes both `/etc/plasmalogin.conf` and the `conf.d` override that `os-session-select`
  creates (the override was winning).
- The attach-time environment file is no longer shipped as a static install (it pinned fresh installs to a card
  that is not there); it is written on attach and removed on detach.
- README: new *How it works* section (AMD crosstalk workaround, bandwidth/ReBAR/link pinning, operating modes and
  the panel-off state).

Re-tested on the tested machine: hot plug on the Desktop (panel now off). Not yet re-run since the change:
Desktop Safe Detach and the re-login watchdog. Installer flow unchanged from 0.1.0. SteamOS and Bazzite untested.
