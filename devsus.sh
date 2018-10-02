#!/bin/sh -xe

#  this file is part of Devsus.
#
#  Copyright 2017, 2018 Dima Krasner
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.

KVER=4.9

outmnt=$(mktemp -d -p `pwd`)
inmnt=$(mktemp -d -p `pwd`)

outdev=/dev/loop6
indev=/dev/loop7

cleanup() {
	set +e

	umount -l $inmnt > /dev/null 2>&1
	rmdir $inmnt > /dev/null 2>&1
	losetup -d $indev > /dev/null 2>&1

	umount -l $outmnt > /dev/null 2>&1
	rmdir $outmnt > /dev/null 2>&1
	losetup -d $outdev > /dev/null 2>&1
}

[ "$CI" != true ] && trap cleanup INT TERM EXIT

minor=`wget -q -O- http://linux-libre.fsfla.org/pub/linux-libre/releases/LATEST-$KVER.N/ | grep -F patch-$KVER-gnu | head -n 1 | cut -f 9 -d . | cut -f 1 -d -`
[ ! -f linux-libre-$KVER-gnu.tar.xz ] && wget http://linux-libre.fsfla.org/pub/linux-libre/releases/LATEST-4.9.0/linux-libre-$KVER-gnu.tar.xz
[ ! -f patch-$KVER-gnu-$KVER.$minor-gnu ] && wget -O- https://www.linux-libre.fsfla.org/pub/linux-libre/releases/LATEST-$KVER.N/patch-$KVER-gnu-$KVER.$minor-gnu.xz | xz -d > patch-$KVER-gnu-$KVER.$minor-gnu
[ ! -f ath9k_htc_do_not_use_bulk_on_ep3_and_ep4.patch ] && wget -O ath9k_htc_do_not_use_bulk_on_ep3_and_ep4.patch https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/patch/?id=2b721118b7821107757eb1d37af4b60e877b27e7
[ ! -d open-ath9k-htc-firmware ] && git clone --depth 1 https://github.com/qca/open-ath9k-htc-firmware.git
[ ! -f hosts ] && wget -O- https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews/hosts | grep ^0\.0\.0\.0 | awk '{print $1" "$2}' | grep -F -v "0.0.0.0 0.0.0.0" > hosts

# build Linux-libre
[ ! -d linux-$KVER ] && tar -xJf linux-libre-$KVER-gnu.tar.xz
cd linux-$KVER
patch -p 1 < ../patch-$KVER-gnu-$KVER.$minor-gnu
make clean
make mrproper
# work around instability of ath9k_htc, see https://github.com/SolidHal/PrawnOS/issues/38
patch -R -p 1 < ../ath9k_htc_do_not_use_bulk_on_ep3_and_ep4.patch
# reset the minor version number, so out-of-tree drivers continue to work after
# a kernel upgrade
sed s/'SUBLEVEL = .*'/'SUBLEVEL = 0'/ -i Makefile
cp -f ../config .config

kmake="make -j `grep ^processor /proc/cpuinfo  | wc -l` CROSS_COMPILE=arm-none-eabi- ARCH=arm"

$kmake olddefconfig
$kmake modules_prepare
$kmake SUBDIRS=drivers/usb/dwc2 modules
$kmake SUBDIRS=drivers/net/wireless/ath/ath9k modules
$kmake SUBDIRS=drivers/bluetooth modules
$kmake dtbs

# CI flow ends here
[ "$CI" = true ] && exit 0

$kmake zImage modules

[ ! -h kernel.its ] && ln -s ../kernel.its .
mkimage -D "-I dts -O dtb -p 2048" -f kernel.its vmlinux.uimg
dd if=/dev/zero of=bootloader.bin bs=512 count=1
vbutil_kernel --pack vmlinux.kpart \
              --version 1 \
              --vmlinuz vmlinux.uimg \
              --arch arm \
              --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
              --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
              --config ../cmdline \
              --bootloader bootloader.bin
cd ..

# build AR9271 firmware
cd open-ath9k-htc-firmware
make toolchain
make -C target_firmware
cd ..

create_image() {
	# it's a sparse file - that's how we fit a 16GB image inside a 2GB one
	dd if=/dev/zero of=$1 bs=$3 count=$4 conv=sparse
	parted --script $1 mklabel gpt
	cgpt create $1
	cgpt add -i 1 -t kernel -b 8192 -s 65536 -l Kernel -S 1 -T 5 -P 10 $1
	start=$((8192 + 65536))
	end=`cgpt show $1 | grep 'Sec GPT table' | awk '{print $1}'`
	size=$(($end - $start))
	cgpt add -i 2 -t data -b $start -s $size -l Root $1
	# $size is in 512 byte blocks while ext4 uses a block size of 1024 bytes
	losetup -P $2 $1
	mkfs.ext4 -F -b 1024 -m 0 -O ^has_journal ${2}p2 $(($size / 2))

	# mount the / partition
	mount -o noatime ${2}p2 $5
}

# create a 2GB image with the Chrome OS partition layout
create_image devuan-ascii-c201-libre-2GB.img $outdev 50M 40 $outmnt

# install Devuan on it
qemu-debootstrap --arch=armhf --foreign ascii --variant minbase $outmnt http://packages.devuan.org/merged
chroot $outmnt passwd -d root
echo -n devsus > $outmnt/etc/hostname

# install stable release updates as soon as they're available
install -m 644 sources.list $outmnt/etc/apt/sources.list

# disable installation of recommended, not strictly necessary packages
install -D -m 644 80disable-recommends $outmnt/etc/apt/apt.conf.d/80disable-recommends

cp -f /etc/resolv.conf $outmnt/etc/
chroot $outmnt apt update
DEBIAN_FRONTEND=noninteractive chroot $outmnt apt upgrade -y
DEBIAN_FRONTEND=noninteractive chroot $outmnt apt install -y eudev kmod net-tools inetutils-ping traceroute iproute2 isc-dhcp-client wpasupplicant iw alsa-utils cgpt elvis-tiny less psmisc netcat-traditional ca-certificates bzip2 xz-utils unscd dbus dbus-x11 bluez pulseaudio pulseaudio-module-bluetooth elogind libpam-elogind ntp xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-fbdev libgl1-mesa-dri xserver-xorg-input-synaptics xinit x11-xserver-utils ratpoison xbindkeys xvkbd rxvt-unicode htop firefox-esr mupdf locales man-db dmz-cursor-theme
chroot $outmnt apt-get autoremove --purge
chroot $outmnt apt-get clean

# set the default PulseAudio devices; otherwise, it uses dummy ones
echo "load-module module-alsa-sink device=sysdefault
load-module module-alsa-source device=sysdefault" >> $outmnt/etc/pulse/default.pa

# disable saving of dmesg output in /var/log
chroot $outmnt update-rc.d bootlogs disable

# reduce the number of virtual consoles
sed -i s/^[3-6]/\#\&/g $outmnt/etc/inittab

# enable DNS cache
sed -i s/'enable-cache            hosts   no'/'enable-cache            hosts   yes'/ -i $outmnt/etc/nscd.conf

# prevent DNS lookup of the default hostname, which dicloses the OS to a
# potential attacker
echo "127.0.0.1 devsus" >> $outmnt/etc/hosts

# block malware and advertising domains
cat hosts >> $outmnt/etc/hosts

rm -f $outmnt/etc/resolv.conf $outmnt/var/log/*log $outmnt/var/log/dmesg $outmnt/var/log/fsck/* $outmnt/var/log/apt/*

# allow unprivileged users to write to /sys/devices/platform/backlight/backlight/backlight/brightness
install -m 644 99-brightness.rules $outmnt/etc/udev/rules.d/99-brightness.rules

# give ath9k_htc devices a random MAC address
install -m 644 98-mac.rules $outmnt/etc/udev/rules.d/98-mac.rules

# make /tmp a tmpfs, to reduce disk I/O
install -m 644 fstab $outmnt/etc/fstab

install -m 644 skel/.xbindkeysrc $outmnt/etc/skel/.xbindkeysrc
install -D -m 644 skel/.config/htop/htoprc $outmnt/etc/skel/.config/htop/htoprc
install -m 744 skel/.xinitrc $outmnt/etc/skel/.xinitrc
install -m 644 skel/.Xresources $outmnt/etc/skel/.Xresources
install -m 644 skel/.ratpoisonrc $outmnt/etc/skel/.ratpoisonrc

# enable font hinting
install -D -m 644 skel/.config/fontconfig/conf.d/99-devsus.conf $outmnt/etc/skel/.config/fontconfig/conf.d/99-devsus.conf

# set the cursor theme
install -D -m 644 skel/.icons/default/index.theme $outmnt/etc/skel/.icons/default/index.theme

# change the default settings of firefox-esr
install -m 644 skel/devsus-settings.js $outmnt/usr/lib/firefox-esr/defaults/pref/devsus-settings.js
install -m 644 skel/devsus.cfg $outmnt/usr/lib/firefox-esr/devsus.cfg

# put the kernel in the kernel partition, modules in /lib/modules and AR9271
# firmware in /lib/firmware
dd if=linux-$KVER/vmlinux.kpart of=${outdev}p1 conv=notrunc
make -C linux-$KVER ARCH=arm INSTALL_MOD_PATH=$outmnt modules_install
rm -f $outmnt/lib/modules/$KVER.0-gnu/{build,source}
install -D -m 644 open-ath9k-htc-firmware/target_firmware/htc_9271.fw $outmnt/lib/firmware/htc_9271.fw

# create a 16GB image
create_image devuan-ascii-c201-libre-16GB.img $indev 512 30785536 $inmnt

# copy the kernel and / of the 2GB image to the 16GB one
dd if=${outdev}p1 of=${indev}p1 conv=notrunc
cp -a $outmnt/* $inmnt/

umount -l $inmnt
rmdir $inmnt
losetup -d $indev

# move the 16GB image inside the 2GB one
cp -f devuan-ascii-c201-libre-16GB.img $outmnt/
