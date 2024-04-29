#!/bin/bash
# Custom arch install script to fully install a new configured system
# WARNING: this script will destroy data on the selected disk!
# This script can be run by executing the following:
#   curl -sL arch.sevbesau.xyz/tools/install-system.sh | bash

# Harden script agains errors
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

REPO_URL="http://arch.sevbesau.xyz/repo"
MIRRORLIST_URL="https://archlinux.org/mirrorlist/?country=BE&country=FR&country=DE&country=LU&country=NL&protocol=http&protocol=https&use_mirror_status=on"

# Figure out wether this is an amd or intel based system and what ucode package to install
cpu=$(cat /proc/cpuinfo | grep vendor_id | head -n 1 | cut -d : -f 2 | tr -d ' ')
case $cpu in
    AuthenticAMD) ucode_package="amd-ucode" ;;
    GenuineIntel) ucode_package="amd-ucode" ;;
    *) echo "Unsupported cpu vendor detected" && exit 1 ;;
esac

# Install deps for this script
pacman -Sy --noconfirm pacman-contrib dialog

echo "Updating mirror list"
curl -s "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    rankmirrors -n 5 - > /etc/pacman.d/mirrorlist

#################################
### Get information from user ###
#################################

hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords do not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installation disk" 0 0 0 $devicelist) || exit 1
clear


######################
### Set up logging ###
######################

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

timedatectl set-ntp true

#####################################
### Setup the disk and partitions ###
#####################################
echo "Setting up disk partitions"

# Boot sector of about 1GB in Mib
# (Using Mib to allow gparted to nicely line up the sectors)
boot_size=953 
boot_end="$boot_size"Mib
swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
swap_end=$(( $swap_size + 1907 + $boot_size + 1))Mib

parted --script "$device" -- mklabel gpt \
    mkpart ESP fat32 1Mib $boot_end \
    set 1 boot on \
    mkpart primary linux-swap $boot_end $swap_end \
    mkpart primary ext4 $swap_end 100%

# Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
# but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

wipefs "$part_boot"
wipefs "$part_swap"
wipefs "$part_root"

mkfs.vfat -F32 "$part_boot"
mkswap "$part_swap"
mkfs.f2fs -f "$part_root"

swapon "$part_swap"
mount "$part_root" /mnt
mount --mkdir "$part_boot" /mnt/boot


##############################################
### Install and configure the basic system ###
##############################################

echo "Installing packages"

cat >>/etc/pacman.conf <<EOF
[sevbesau]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF

pacstrap /mnt sevbesau-desktop $ucode_package

cat >>/mnt/etc/pacman.conf <<EOF
[sevbesau]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF

# Installing the bootloader
echo "Installing systemd bootloader"
arch-chroot /mnt bootctl install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /$ucode_package.img
initrd  /initramfs-linux.img
options root=UUID=$(blkid -s UUID -o value "$part_root") rw quiet splash
EOF

cat <<EOF > /mnt/boot/loader/entries/arch-fallback.conf
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /$ucode_package.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$(blkid -s UUID -o value "$part_root") rw
EOF

echo "Configuring the system"

# Generate the fstab
genfstab -t UUID /mnt >> /mnt/etc/fstab

# Set the hostname
echo "$hostname" > /mnt/etc/hostname

# Set the timezone
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Brussels /etc/localtime

# Sync system time and hardware clock
arch-chroot /mnt hwclock --systohc

# Create the user
arch-chroot /mnt useradd -mU -s /usr/bin/bash -G wheel "$user"

# Set the password for root and the user
echo "root:$password" | chpasswd --root /mnt
echo "$user:$password" | chpasswd --root /mnt
