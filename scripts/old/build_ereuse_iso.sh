#!/bin/sh
# Generate eReuseOS ISO.
#
# Based on instructions from
# <https://help.ubuntu.com/community/LiveCDCustomization>.

set -e

# Configurable regional settings.
KB_LAYOUT=${KB_LAYOUT:-us}  # see available in ``/usr/share/X11/xkb/symbols``
LOCALE=${LOCALE:-en_US.UTF-8}
TIMEZONE=${TIMEZONE:-Etc/UTC}

# Configurable settings.
WORK_DIR=${WORK_DIR:-dist/iso}

# Version-specific settings.
VERSION=$(cd erwb && python -Bc 'from __init__ import get_version; print get_version()')

# Seems that this iso has been dissapeared
# BASE_ISO_URL="http://ubuntu-mini-remix.mirror.garr.it/mirrors/ubuntu-mini-remix/15.10/ubuntu-mini-remix-15.10-i386.iso"
# This is a mirror with the same sha even
BASE_ISO_URL="https://fabrizioballiano.net/ubuntu-mini-remix/15.10/ubuntu-mini-remix-15.10-i386.iso"
BASE_ISO_SHA256="e9985f0bcb05678d87d62c3d70191aab7a80540dc17523d93c313aa8515e173e"

# Other derived values.
# This line is obsolete in favor of git clone
# SDIST=$(find "dist/ereuse-workbench-$VERSION.tar.gz")  # fail if missing
BASE_ISO_PATH="$WORK_DIR/$(basename "$BASE_ISO_URL")"
BASE_ISO_SHA256SUM="$BASE_ISO_SHA256  $BASE_ISO_PATH"
ISO_PATH="$WORK_DIR/eReuseOS-$VERSION.iso"


if [ "$(whoami)" != "root" ]; then
    echo "Please run this script as root." >&2
    exit 1
fi

cat << 'EOF'

**WARNING:** Please run this script UNDER YOUR OWN RESPONSIBILITY.  Beware
that you may be exposed to security attacks if the base ISO image is
compromised (although the image's SHA256 hash is checked before using it).

EOF
read -p "Press Enter to continue, Ctrl+C to abort." dummy

# Since we use git clone this has now meaning
# if git submodule status | grep -q '^-'; then
#     echo "Please check out Git submodules." >&2
#     exit 1
# fi

genisoimage --version > /dev/null  # fail if missing
mksquashfs -version > /dev/null  # fail if missing

mkdir -p "$WORK_DIR"

# Download the base ISO.
while ! echo "$BASE_ISO_SHA256SUM" | sha256sum -c --quiet --status; do
    wget -c -O $BASE_ISO_PATH "$BASE_ISO_URL"
done

# Mount a writable version of the ISO and the FS in it.
ISO_RO=$(mktemp -d -p"$WORK_DIR")
ISO_RW_DATA=$(mktemp -d -p"$WORK_DIR")
ISO_RW_WORK=$(mktemp -d -p"$WORK_DIR")
ISO_ROOT=$(mktemp -d -p"$WORK_DIR")

mount -t iso9660 -o loop,ro $BASE_ISO_PATH $ISO_RO
mount -t overlay -o lowerdir=$ISO_RO,upperdir=$ISO_RW_DATA,workdir=$ISO_RW_WORK base-iso $ISO_ROOT

FS_RO=$(mktemp -d -p"$WORK_DIR")
FS_RW_DATA=$(mktemp -d -p"$WORK_DIR")
FS_RW_WORK=$(mktemp -d -p"$WORK_DIR")
FS_ROOT=$(mktemp -d -p"$WORK_DIR")

mount -t squashfs -o loop,ro $ISO_RO/casper/filesystem.squashfs $FS_RO
mount -t overlay -o lowerdir=$FS_RO,upperdir=$FS_RW_DATA,workdir=$FS_RW_WORK ereuse $FS_ROOT

# To customize filesystem.
alias ch="chroot $FS_ROOT env HOME=/root LC_ALL=C"
alias chi="ch apt-get install -y --no-install-recommends"

# Customization prerequisites.
ch dbus-uuidgen > $FS_ROOT/var/lib/dbus/machine-id
ch dpkg-divert --local --rename --add /sbin/initctl
ch ln -s /bin/true /sbin/initctl

# Disable swapping to disk in a systemd-friendly way.
# See <https://tails.boum.org/contribute/design/#index34h3>.
ch dpkg-divert --local --rename --add /sbin/swapon
ch ln -s /bin/true /sbin/swapon

# TODO manually update resolv.conf
ch rm /etc/resolv.conf  # in case it's a link
echo "nameserver  208.67.222.222" > $FS_ROOT/etc/resolv.conf

# Enable universe repository (/etc/apt/sources.list)
chi software-properties-common
ch add-apt-repository "deb http://archive.ubuntu.com/ubuntu $(ch lsb_release -sc) universe"

# installation tools requirements (could be removed)
ch apt-get update
chi python-pip  # vim
# Install git (Garito)
chi git
ch git clone https://github.com/Garito/Workbench.git /home/ubuntu/workbench
ch git clone https://github.com/Garito/WorkbenchSneaky.git /home/ubuntu/WorkbenchSneaky

cat > $FS_ROOT/etc/systemd/system/workbenchsneaky.service << EOF
[Unit]
Description=Workbench USB Sneaky
After=multi-user.target

[Service]
# Ubuntu/Debian convention:
Type=simple
#ExecStart=/usr/bin/python /home/ubuntu/WorkbenchSneaky/sneak.py http://192.168.2.2:5000
ExecStart=/usr/bin/python /home/ubuntu/WorkbenchSneaky/sneak.py redis://192.168.2.2:6379/0
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
EOF

chmod 644 $FS_ROOT/etc/systemd/system/workbenchsneaky.service

# ereuse-workbench requirements
# TODO read from requirements.txt
chi $(sed -rn 's/.*\bdeb:(.+)$/\1/p' requirements.txt)

ch pip install -e /home/ubuntu/workbench

# Install Reciclanet's image installation script
install -m 0755 reciclanet-scripts/instalar $FS_ROOT/usr/local/bin/erwb-install-image

# Obsolete
# cp $SDIST $FS_ROOT/tmp
# ch pip install --upgrade /tmp/$(basename $SDIST)
install -m 0755 scripts/erwb-keyboard-layout scripts/erwb-disk-dump $FS_ROOT/usr/local/sbin

# Configure regional settings
ch ckbcomp "$KB_LAYOUT" | gzip -c > $FS_ROOT/etc/console-setup/cached.kmap.gz

echo "$TIMEZONE" > $FS_ROOT/etc/timezone
ch debconf-set-selections << EOF
locales locales/locales_to_be_generated multiselect $LOCALE ${LOCALE##*.}
locales locales/default_environment_locale select $LOCALE
EOF

ch dpkg-reconfigure -f noninteractive tzdata locales
ch locale-gen "$LOCALE"
ch update-locale "LANG=$LOCALE" "LANGUAGE=$LOCALE" "LC_ALL=$LOCALE"

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   UPC REUTILITZA - GRAPHICAL ENVIRONMENT     #
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#ch apt-get install xorg icewm

#~~~~~~~~~~~~~~~~ end UPC ~~~~~~~~~~~~~~~~~~~~~~

## CLEAN UP ##
## PURGE temporal packages XXX?
#ch apt-get purge git python-pip
ch apt-get clean

# Add ubuntu user:
printf 'ubuntu\nubuntu\n' | ch adduser -q --gecos 'Ubuntu' ubuntu

# Autologin
ch sed -i -r --follow-symlinks \
   's#(ExecStart=.*getty\b.*)(%I \$TERM)#\1--autologin ubuntu \2#' \
   '/etc/systemd/system/getty.target.wants/getty@tty1.service'

# Autostart
cat > $FS_ROOT/home/ubuntu/.erwb-help << 'EOF'

eReuse Workbench process finished.

  - To reboot the computer, press Ctrl+Alt+Del or run "sudo reboot".

  - To turn the computer off, press the power button or run "sudo poweroff".

  - To run the process again, "exit" this session.

  - To dump an existing installation from disk into an FSArchiver image, run:

       sudo erwb-disk-dump NAME_OF_IMAGE [OPTIONAL_DESTINATION]

EOF


ch chown -R ubuntu:ubuntu /home/ubuntu
cat > $FS_ROOT/home/ubuntu/.bash_history << 'EOF'
sudo erwb-disk-dump xubuntu-i386-ca
exit
sudo poweroff
sudo reboot
EOF

ch chown ubuntu:ubuntu /home/ubuntu/.bash_history

cat >> $FS_ROOT/home/ubuntu/.profile << 'EOF'
sudo systemctl daemon-reload
sudo systemctl enable workbenchsneaky.service
sudo systemctl start workbenchsneaky.service
clear
if [ -d /media/ereuse-data ]; then
    sudo erwb-keyboard-layout /media/ereuse-data/config.ini
    clear
    sudo erwb --settings /media/ereuse-data/config.ini --inventory /media/ereuse-data/inventory
else
    sudo erwb-keyboard-layout
    clear
    sudo erwb
fi
cat ~/.erwb-help
EOF

# Mount remote data directory.
sed -i '/^exit 0/d' $FS_ROOT/etc/rc.local
cat >> $FS_ROOT/etc/rc.local << 'EOF'
# Mount remote data directory.
nfsserver=$(sed -rn 's/.*\bnfsroot=([^:]+):.*/\1/p' /proc/cmdline)
if [ "$nfsserver" ]; then
    mkdir -p /media/ereuse-data
    mount -t cifs -o guest,uid=ubuntu,forceuid,gid=ubuntu,forcegid "//$nfsserver/ereuse-data" /media/ereuse-data
fi
exit 0
EOF

# If you installed software, be sure to run
ch rm -f /var/lib/dbus/machine-id
ch rm -f /sbin/initctl
ch dpkg-divert --rename --remove /sbin/initctl

# delete temporary files
rm -rf $FS_ROOT/tmp/* $FS_ROOT/root/.bash_history

### PACK the ISO ###

# Regenerate manifest
ch dpkg-query -W --showformat='${Package} ${Version}\n' > $ISO_ROOT/casper/filesystem.manifest
cp $ISO_ROOT/casper/filesystem.manifest $ISO_ROOT/casper/filesystem.manifest-desktop
sed -i '/ubiquity/d' $ISO_ROOT/casper/filesystem.manifest-desktop
sed -i '/casper/d' $ISO_ROOT/casper/filesystem.manifest-desktop

# Create new squashfs using default compression, skip boot dir to save some space.
# LZMA is currently not supported even if the initramfs uses it for compression.
mksquashfs $FS_ROOT $ISO_ROOT/casper/filesystem-new.squashfs -e $FS_ROOT/boot

# replace squashfs
umount $FS_ROOT
umount $FS_RO
mv $ISO_ROOT/casper/filesystem-new.squashfs $ISO_ROOT/casper/filesystem.squashfs

# Update the filesystem.size file, which is needed by the installer:
mount -t squashfs -o loop,ro $ISO_ROOT/casper/filesystem.squashfs $FS_RO
printf $(sudo du -sx --block-size=1 $FS_RO | cut -f1) > $ISO_ROOT/casper/filesystem.size
umount $FS_RO

# Set an image name in extract-cd/README.diskdefines
##sudo vim extract-cd/README.diskdefines

# Calculate new SHA256 sums.
( cd $ISO_ROOT \
      && sed -i '/  \.\/casper\/filesystem\..*$/d' SHA256SUMS \
      && sha256sum ./casper/filesystem.* >> SHA256SUMS )

# Remove old md5sum.txt and calculate new md5 sums
( cd $ISO_ROOT \
     && rm -f md5sum.txt \
     && find -type f -print0 | xargs -0 md5sum | grep -v isolinux/boot.cat > md5sum.txt )

# Create the ISO image
# A) Ubuntu
#sudo mkisofs -D -r -V "$IMAGE_NAME" -cache-inodes -J -l -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o $ISO_PATH $ISO_ROOT

# B) Debian
genisoimage -D -r -V "eReuseOS" -cache-inodes -J -l -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o $ISO_PATH $ISO_ROOT

umount $ISO_ROOT
umount $ISO_RO

rm -rf $ISO_ROOT $ISO_RW_WORK $ISO_RW_DATA $ISO_RO $FS_ROOT $FS_RW_WORK $FS_RW_DATA $FS_RO

echo "Done, image created:" $ISO_PATH
