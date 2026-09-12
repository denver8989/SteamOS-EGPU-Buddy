#!/bin/bash
# Install the author-rebased PR#985+#984 610.57.04 modules (AUR nvidia-open-egpu patches 160+170) over the DKMS-built
# stock ones (backup kept), swap the DKMS source for the patched tree so kernel updates rebuild it, and force is_external_gpu.
set -e
W=/tmp/claude-1000/-home-deck/3eb55c40-0a54-4c36-b960-c4246162247f/scratchpad; S=$W/nvsrc2
K=$(uname -r); D=/usr/lib/modules/$K/updates/dkms; B=/var/lib/nvegpu/stock-modules-610.57.04-$K
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do [ -f $S/kernel-open/$m.ko ] || { echo "missing $m.ko"; exit 2; }; done
mkdir -p $B; [ -n "$(ls $B 2>/dev/null)" ] || cp -a $D/nvidia*.ko.zst $B/
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do zstd -q -f -19 $S/kernel-open/$m.ko -o $D/$m.ko.zst; done
depmod -a $K
[ -d /usr/src/nvidia-610.57.04.stock ] || mv /usr/src/nvidia-610.57.04 /usr/src/nvidia-610.57.04.stock
rm -rf /usr/src/nvidia-610.57.04; cp -a $S /usr/src/nvidia-610.57.04; rm -rf /usr/src/nvidia-610.57.04/kernel-open/*.ko /usr/src/nvidia-610.57.04/kernel-open/*.o /usr/src/nvidia-610.57.04/kernel-open/.*.cmd /usr/src/nvidia-610.57.04/src/nvidia/_out /usr/src/nvidia-610.57.04/src/nvidia-modeset/_out 2>/dev/null
cp /usr/src/nvidia-610.57.04.stock/dkms.conf /usr/src/nvidia-610.57.04/dkms.conf; chown -R root:root /usr/src/nvidia-610.57.04
printf '%s\n' '# NV-EGPU-Buddy: PR #984 registry key (patched module) — treat the TB5 eGPU as external on this AMD USB4 host' 'options nvidia NVreg_RegistryDwords="RmForceExternalGpu=1"' > /etc/modprobe.d/zz-nvidia-egpu-external.conf
echo "installed srcversion: $(modinfo -F srcversion $D/nvidia.ko.zst) (stock $(modinfo -F srcversion $B/nvidia.ko.zst))"
echo "depmod ok: $(modinfo -n nvidia_modeset) ; patched src marker: $(grep -c gpuLost /usr/src/nvidia-610.57.04/src/nvidia-modeset/include/nvkms-types.h)"
echo "modprobe option: $(cat /etc/modprobe.d/zz-nvidia-egpu-external.conf | tail -1)"
