#!/bin/bash

# Basic variables (replace YOUR_NAME and YOUR_UCODE_PACKAGE with your specifics)
USERNAME="YOUR_NAME"
KEYMAP="us"
TIMEZONE="America/Puerto_Rico"
LOCALE="en_US.UTF-8"
EFI_PARTITION="/dev/nvme0n1p1"
ROOT_PARTITION="/dev/nvme0n1p2"
LVM_NAME="vg"
UCODE_PACKAGE="intel-ucode"  # Replace with amd-ucode if you're using AMD

# Step 1: Connect to Wi-Fi if necessary
echo "Connecting to Wi-Fi..."
iwctl station wlan0 connect "SSID"  # Replace with your Wi-Fi SSID

# Step 2: Partition the Disk
# Partitioning using parted
echo "Partitioning the disk with parted..."
parted /dev/nvme0n1 --script mklabel gpt
parted /dev/nvme0n1 --script mkpart ESP fat32 1MiB 513MiB
parted /dev/nvme0n1 --script set 1 boot on
parted /dev/nvme0n1 --script mkpart primary ext4 513MiB 100%

# Step 3: Format the EFI partition
echo "Formatting EFI partition..."
mkfs.fat -F32 $EFI_PARTITION

# Step 4: Encrypt the LUKS partition
echo "Encrypting LUKS partition..."
cryptsetup luksFormat --type luks2 $ROOT_PARTITION
cryptsetup open $ROOT_PARTITION cryptlvm

# Step 5: Set up LVM inside the encrypted partition
echo "Configuring LVM..."
pvcreate /dev/mapper/cryptlvm
vgcreate $LVM_NAME /dev/mapper/cryptlvm
lvcreate -l 100%FREE $LVM_NAME -n root
mkfs.ext4 /dev/$LVM_NAME/root

# Step 6: Mount the root and EFI partitions
echo "Mounting partitions..."
mount /dev/$LVM_NAME/root /mnt
mkdir -p /mnt/boot/efi
mount $EFI_PARTITION /mnt/boot/efi

# Step 7: Install the base system
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware $UCODE_PACKAGE sudo vim lvm2 dracut sbsigntools iwd git efibootmgr binutils dhcpcd

# Step 8: Generate the fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Step 9: Chroot into the system
echo "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<EOF

# Set the root password
echo "Setting root password..."
passwd

# Set timezone and synchronize hardware clock
echo "Setting timezone and clock..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
echo "Setting locale..."
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Configure the console keyboard layout
echo "Setting keyboard layout..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
echo "Setting hostname..."
echo "archlinux" > /etc/hostname

# Create new user with sudo privileges
echo "Creating user $USERNAME..."
useradd -m $USERNAME
passwd $USERNAME
usermod -aG wheel $USERNAME
sed -i 's/^# %wheel ALL=(ALL) ALL$/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Enable basic services
echo "Enabling system services..."
systemctl enable dhcpcd
systemctl enable iwd

# Dracut setup for Secure Boot
echo "Configuring Dracut for Unified Kernel Image..."
mkdir -p /usr/local/bin
cat <<'SCRIPT' > /usr/local/bin/dracut-install.sh
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
  if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
    kver="${line#'usr/lib/modules/'}"
    kver="${kver%'/pkgbase'}"
    dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/arch-linux.efi
  fi
done
SCRIPT
chmod +x /usr/local/bin/dracut-install.sh

# Pacman hooks for Dracut
mkdir -p /etc/pacman.d/hooks
cat <<'HOOK' > /etc/pacman.d/hooks/90-dracut-install.hook
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating Linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
HOOK

# UUID for encrypted volume
UUID=$(blkid -s UUID -o value $ROOT_PARTITION)
echo "kernel_cmdline=\"rd.luks.uuid=luks-$UUID rd.lvm.lv=$LVM_NAME/root root=/dev/mapper/$LVM_NAME-root rootfstype=ext4 rootflags=rw,relatime\"" > /etc/dracut.conf.d/cmdline.conf
echo "compress=\"zstd\"" > /etc/dracut.conf.d/flags.conf

# Generate Unified Kernel Image
echo "Generating Unified Kernel Image..."
pacman -S linux --noconfirm

# UEFI boot entry
efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "Arch Linux" --loader 'EFI\Linux\arch-linux.efi' --unicode

EOF

# Exit chroot
echo "Installation complete. You can reboot now."
