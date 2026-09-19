#!/usr/bin/env bash
# SteamOS EGPU Buddy — patched NVIDIA driver on SteamOS WITHOUT touching the 5 GB system partition.
#
# Why this exists (all measured on Valve's 3.8.14 image, 2026-09-19): the system partition has ~870 MB free and the
# driver needs ~1.5-2.1 GB; /var is a 256 MB partition; there is no compiler; and an OS update replaces /usr wholesale.
# So nothing is installed into the system at all:
#   1. a small SteamOS build root is created on /home with Valve's own pacman repositories and keyring,
#   2. inside it the SAME tested driver is installed and built the SAME way as everywhere else
#      (install-patched-nvidia.sh: 610.57.04 userspace from checksummed files + the patched modules, built with DKMS
#       against the headers of the EXACT running kernel),
#   3. the NVIDIA files and the built modules are collected into a systemd system extension (sysext) on /home, which
#      systemd merges into /usr (SteamOS enables systemd-sysext by default). The extension is ONE squashfs IMAGE file:
#      SteamOS formats /home as ext4 with case-folding, and overlayfs (which sysext uses) refuses directories on such a
#      filesystem ("case-insensitive capable filesystem ... not supported", seen on a real device 2026-09-19); an image
#      is loop-mounted as its own filesystem, so where the file lives does not matter,
#   4. module dependency data is generated into the extension, the extension is activated, the library cache refreshed.
# Self-healing: everything lives on /home or in /etc paths that SteamOS keeps across updates (see install.sh). After an
# OS update with a NEW KERNEL this script is simply run again by the self-heal service: steps 1-2 are incremental and
# only the modules for the new kernel are built.
#   install-steamos-sysext.sh            build (or rebuild for the running kernel) and activate
#   install-steamos-sysext.sh --boot     re-activate at boot; rebuild for a new kernel (used by the self-heal service)
#   install-steamos-sysext.sh --status   what is in place for the running kernel (exit 0 = driver usable)
#   install-steamos-sysext.sh --remove   deactivate and delete everything this created
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
BASE=${EGPU_SYSEXT_BASE:-/home/.egpu-buddy}; BR=$BASE/buildroot; NAME=egpu-nvidia; SX=$BASE/sysext/$NAME; IMG=$SX.raw; MANIFEST=$SX.manifest; CACHE=$BASE/pkgcache
K=${EGPU_KERNEL:-$(uname -r)}; PV=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD")
say(){ printf '== %s\n' "$*"; }
P(){ pacman --root "$BR" --dbpath "$BR/var/lib/pacman" --cachedir "$CACHE" --gpgdir /etc/pacman.d/gnupg --config "$BASE/pacman.conf" --noconfirm "$@"; }
# the manifest lists what the image holds: "userspace <version>" and one "kernel <release>" line per built kernel
have_modules(){ [ -s "$IMG" ] && grep -qxF "kernel $K" "$MANIFEST" 2>/dev/null; }
link_ext(){ mkdir -p /etc/extensions; rm -f /etc/extensions/$NAME; ln -sfn "$IMG" /etc/extensions/$NAME.raw; }   # (the first name is the pre-image directory link)
# merging attaches the image to a loop device; a device that is still being released makes that fail once in a while
merge(){ local i; for i in 1 2 3; do systemd-sysext refresh >/dev/null 2>&1 && break; sleep 2; done; ldconfig 2>/dev/null || true; }
active(){ [ "$(readlink -f /etc/extensions/$NAME.raw 2>/dev/null)" = "$IMG" ] && ls "/usr/lib/modules/$K"/kernel/drivers/video/nvidia.ko* >/dev/null 2>&1 && [ -e /usr/lib/libnvidia-ml.so.1 ]; }

case "${1:-}" in
  --status)
    echo "kernel: $K"; echo "extension image: $([ -s "$IMG" ] && echo present || echo absent)  userspace: $(sed -n 's/^userspace //p' "$MANIFEST" 2>/dev/null | grep . || echo none)"
    echo "modules for this kernel: $(have_modules && echo yes || echo NO)   merged into /usr: $(active && echo yes || echo NO)"
    active && have_modules; exit $? ;;
  --activate)   # fast, offline, never builds: merge what exists (first thing at boot)
    have_modules || { echo "no modules for kernel $K in the extension"; exit 4; }
    link_ext; merge
    active && { echo "driver extension active for $K"; exit 0; }; echo "extension present but not merged"; exit 9 ;;
  --boot)   # every boot (self-heal): re-activate what exists; rebuild only when the kernel changed
    if have_modules; then link_ext; merge
      active && { echo "driver extension active for $K"; exit 0; }; echo "extension present but not merged"; exit 9; fi
    [ -d "$BR" ] || { echo "no driver extension installed"; exit 0; }
    echo "no modules for kernel $K (OS update?): rebuilding" ;;
  --remove)
    rm -f /etc/extensions/$NAME /etc/extensions/$NAME.raw; systemd-sysext refresh >/dev/null 2>&1 || true; ldconfig 2>/dev/null || true
    rm -rf "$BASE"; echo "removed"; exit 0 ;;
esac

mkdir -p "$BASE" "$CACHE" "$BASE/sysext"; chmod 755 "$BASE"
need=4000; free=$(df -Pm "$BASE" | awk 'NR==2{print $4}')
[ "$free" -ge "$need" ] || have_modules || { echo "NOT ENOUGH SPACE on $(df -P "$BASE" | awk 'NR==2{print $6}'): ${free} MB free, about ${need} MB needed for the build environment and the driver. Nothing was changed."; exit 3; }

# ---- 0. keyring + the exact kernel package of the RUNNING kernel ---------------------------------------------------
pacman-key --list-keys >/dev/null 2>&1 || { say "initialising the pacman keyring"; pacman-key --init >/dev/null 2>&1 && pacman-key --populate >/dev/null 2>&1; }
kpkg=$(pacman -Qqo "/usr/lib/modules/$K/vmlinuz" 2>/dev/null || true); [ -n "$kpkg" ] || kpkg=$(pacman -Qqo "/usr/lib/modules/$K" 2>/dev/null | head -1 || true)
[ -n "$kpkg" ] || { echo "cannot tell which package owns kernel $K"; exit 5; }
kver=$(pacman -Q "$kpkg" | awk '{print $2}'); say "running kernel $K = package $kpkg $kver"
# the host's repositories, minus its DBPath (it points into the read-only system)
grep -vE '^\s*DBPath' /etc/pacman.conf > "$BASE/pacman.conf"

# ---- 1. build root on /home ----------------------------------------------------------------------------------------
if [ ! -x "$BR/usr/bin/makepkg" ] || [ ! -x "$BR/usr/bin/dkms" ]; then
  say "creating the build environment on $BASE (about 1.3 GB, one time)"
  mkdir -p "$BR/var/lib/pacman" "$BR/etc"
  P -Sy filesystem glibc bash coreutils pacman sudo base-devel dkms kmod zstd xz curl gawk grep sed findutils diffutils which archlinux-keyring holo-keyring >/dev/null
  cp "$BASE/pacman.conf" "$BR/etc/pacman.conf"; [ -d /etc/pacman.d ] && { mkdir -p "$BR/etc/pacman.d"; cp /etc/pacman.d/mirrorlist "$BR/etc/pacman.d/mirrorlist"; }
  rm -rf "$BR/etc/pacman.d/gnupg"; cp -a /etc/pacman.d/gnupg "$BR/etc/pacman.d/gnupg"
else P -Sy >/dev/null 2>&1 || true; fi

# headers of EXACTLY the running kernel: the repository database may have moved on to a newer build, but the mirror
# keeps the older files, and modules only load when the headers match the running kernel to the letter
if [ ! -f "$BR/usr/lib/modules/$K/build/Makefile" ]; then
  hf="${kpkg}-headers-${kver}-x86_64.pkg.tar.zst"; got=""
  if [ ! -s "$CACHE/$hf" ]; then
    for repo in $(sed -n 's/^\[\(.*\)\]$/\1/p' "$BASE/pacman.conf" | grep -v '^options$'); do
      for srv in $(sed -n 's/^\s*Server\s*=\s*//p' /etc/pacman.d/mirrorlist "$BASE/pacman.conf" 2>/dev/null); do
        url=$(printf '%s' "$srv" | sed "s/\$repo/$repo/; s/\$arch/x86_64/")/$hf
        curl -fsL --retry 2 -o "$CACHE/$hf.part" "$url" 2>/dev/null && { mv "$CACHE/$hf.part" "$CACHE/$hf"; got=$url; break 2; }
      done
    done
    rm -f "$CACHE/$hf.part"; [ -s "$CACHE/$hf" ] || { echo "kernel headers $hf are not on the package mirror; cannot build for $K"; exit 6; }
    say "kernel headers: $got"
  fi
  P -U --ask 4 "$CACHE/$hf" >/dev/null
  [ -f "$BR/usr/lib/modules/$K/build/Makefile" ] || { echo "headers installed but /usr/lib/modules/$K/build is missing"; exit 6; }
fi

# ---- 2. the tested driver, installed and built inside the build root ------------------------------------------------
if ! ls "$BR/usr/lib/modules/$K"/kernel/drivers/video/nvidia.ko* >/dev/null 2>&1 || ! ls "$BR"/usr/lib/libnvidia-ml.so.$PV >/dev/null 2>&1; then
  say "building the patched NVIDIA $PV modules for $K (several minutes)"
  rm -rf "$BR/opt/pkg"; mkdir -p "$BR/opt/pkg" "$BR/usr/local/bin"; cp -a "$HERE"/. "$BR/opt/pkg/"
  # the build root has the kernel's HEADERS only; the DKMS package hook builds solely for kernels that also have a
  # modules tree ("Missing <kernel> kernel modules tree"), so give it one to install into
  mkdir -p "$BR/usr/lib/modules/$K/kernel"
  # the build root shares the host's kernel; `uname -r` must name it (nspawn would report it anyway, this pins it)
  printf '#!/bin/bash\nif [ "$1" = "-r" ]; then echo %s; else exec /usr/bin/uname "$@"; fi\n' "$K" > "$BR/usr/local/bin/uname"; chmod +x "$BR/usr/local/bin/uname"
  cat > "$BR/opt/build.sh" <<'EOS'
#!/bin/bash
set -e; export PATH=/usr/local/bin:$PATH
export MAKEFLAGS="-j$(nproc)"   # makepkg.conf ships with MAKEFLAGS commented out = the whole driver on ONE core
id builder >/dev/null 2>&1 || useradd -m -u 1000 builder
cd /opt/pkg && EGPU_TARGET_USER=builder EGPU_WANT_LIB32=1 bash ./install-patched-nvidia.sh
K=$(uname -r); ls /usr/lib/modules/$K/kernel/drivers/video/nvidia.ko* >/dev/null 2>&1 || dkms autoinstall -k "$K"
EOS
  chmod +x "$BR/opt/build.sh"
  # --register=no --keep-unit: no dependency on systemd-machined / a system bus (works from a root service as well)
  systemd-nspawn -q --register=no --keep-unit --resolv-conf=copy-host -D "$BR" /bin/bash /opt/build.sh
  ls "$BR/usr/lib/modules/$K"/kernel/drivers/video/nvidia.ko* >/dev/null 2>&1 || { echo "the module build did not produce nvidia.ko for $K"; exit 7; }
fi

# ---- 3. collect the extension ---------------------------------------------------------------------------------------
say "assembling the system extension in $SX"
rm -rf "$SX" "$SX.new"; mkdir -p "$SX.new/usr/lib/extension-release.d"
# every package the driver's userspace pulled into the build root that the HOST does not have
# nvidia-open-egpu-dkms is OUR driver package: besides the modules it installs /usr/lib/modprobe.d/nvidia-open.conf
# (NVreg_OpenRmEnableUnsupportedGpus=1) and the eGPU hotplug udev rule. Those never reached the system before, so SteamOS
# ran the driver without the options every other distribution gets. Its /usr/src DKMS tree is excluded below (~1 GB).
# ... and only ITS OWN files: walking its dependencies would drag dkms, gcc, make and friends into the image.
declare -A seen=(); declare -A leaf=([nvidia-open-egpu-dkms]=1 [nvidia-open-egpu]=1)
queue=(nvidia-utils lib32-nvidia-utils nvidia-open-egpu-dkms); pkgs=()
while [ ${#queue[@]} -gt 0 ]; do p=${queue[0]}; queue=("${queue[@]:1}"); [ -z "${seen[$p]:-}" ] || continue; seen[$p]=1
  P -Qq "$p" >/dev/null 2>&1 || continue                       # not in the build root (e.g. lib32 left out)
  pacman -Qq "$p" >/dev/null 2>&1 && continue                  # the host already has it
  pkgs+=("$p")
  [ -n "${leaf[$p]:-}" ] && continue   # take this package's files, not its build-time dependency tree
  for d in $(P -Qi "$p" 2>/dev/null | sed -n 's/^Depends On *: *//p' | tr ' ' '\n' | sed 's/[<>=].*//' | grep -v '^None$' || true); do
    r=$(P -Qq "$d" 2>/dev/null || P -Qqo "/usr/lib/$d" 2>/dev/null || true); [ -n "$r" ] && queue+=($r) || true
  done
done
say "packages in the extension: ${pkgs[*]}"
[ ${#pkgs[@]} -gt 0 ] || { echo "nothing to put into the extension (is the driver installed in the build root?)"; exit 7; }
# (pacman prints file lists WITH the --root prefix; normalise, keep /usr files only, then address them in the build root)
for p in "${pkgs[@]}"; do P -Qlq "$p" | sed "s#^$BR##" | { grep -E '^/usr/' || true; } | { grep -vE '/$|^/usr/src/' || true; } | sed "s#^#$BR#"; done | while read -r f; do
  [ -e "$f" ] || [ -L "$f" ] || continue; d="$SX.new${f#$BR}"; mkdir -p "$(dirname "$d")"; cp -a --reflink=auto "$f" "$d"; done
ls "$SX.new"/usr/lib/libnvidia-ml.so.$PV >/dev/null 2>&1 || { echo "the NVIDIA userspace did not reach the extension"; exit 7; }
# modules for every kernel already built (an older kernel's modules stay usable for a rollback boot)
for kd in "$BR"/usr/lib/modules/*/; do kk=$(basename "$kd"); ls "$kd"kernel/drivers/video/nvidia*.ko* >/dev/null 2>&1 || continue
  mkdir -p "$SX.new/usr/lib/modules/$kk/kernel/drivers/video"; cp -a --reflink=auto "$kd"kernel/drivers/video/nvidia*.ko* "$SX.new/usr/lib/modules/$kk/kernel/drivers/video/"; done
printf 'ID=_any\n' > "$SX.new/usr/lib/extension-release.d/extension-release.$NAME"

# ---- 4. module dependency data INTO the extension: depmod over (system modules + ours) -------------------------------
# The overlay's writable layer is on tmpfs (/run), never on /home: overlayfs refuses a case-folding ext4 (see the header).
if [ -d "/usr/lib/modules/$K" ]; then
  m=$(mktemp -d /run/egpu-depmod.XXXXXX); mkdir -p "$m/root/usr/lib/modules/$K" "$m/upper" "$m/work"; ln -s usr/lib "$m/root/lib"
  cp -a "$SX.new/usr/lib/modules/$K/." "$m/upper/"
  mount -t overlay overlay -o "lowerdir=/usr/lib/modules/$K,upperdir=$m/upper,workdir=$m/work" "$m/root/usr/lib/modules/$K"
  depmod -b "$m/root" "$K" || { umount "$m/root/usr/lib/modules/$K"; rm -rf "$m"; echo "depmod failed"; exit 8; }
  umount "$m/root/usr/lib/modules/$K"; cp -a "$m/upper"/modules.* "$SX.new/usr/lib/modules/$K/"; rm -rf "$m"
fi

# ---- 5. one image file, then activate --------------------------------------------------------------------------------
say "packing the extension image"
{ echo "userspace $PV"; for kd in "$SX.new"/usr/lib/modules/*/; do echo "kernel $(basename "$kd")"; done; } > "$MANIFEST.new"
rm -f "$IMG.new"; mksquashfs "$SX.new" "$IMG.new" -noappend -comp zstd -quiet -no-progress >/dev/null
rm -rf "$SX.new"
# unmerge before swapping the file that is loop-mounted
rm -f /etc/extensions/$NAME /etc/extensions/$NAME.raw; systemd-sysext refresh >/dev/null 2>&1 || true
mv -f "$IMG.new" "$IMG"; mv -f "$MANIFEST.new" "$MANIFEST"
link_ext; merge
if active; then say "driver $PV active for $K (extension image on $(df -P "$BASE" | awk 'NR==2{print $6}'), system partition untouched)"
else systemd-sysext refresh || true; echo "the extension was written but is not merged into /usr (the message above says why)"; exit 9; fi
