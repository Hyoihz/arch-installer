#!/bin/bash

#  Make pacman colorful and set number of concurrent downloads
sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf

# Display available block devices
echo "Available block devices:"
lsblk

# Prompt user for the block device to partition
echo "Enter the disk for partitioning (e.g. sda/vda): "
read disk
disk_address="/dev/$disk"

# Partition the disk with cfdisk
cfdisk $disk_address

# Prompt user for the root partition number
echo "Enter the root partition number: "
read num
root_partition="${disk_address}${num}"

# Format the root partition
mkfs.ext4 $root_partition

# Check if an EFI partition was created
read -p "Did you create an EFI partition? (y/n)" answer
if [[ $answer = y ]] ; then
    # Prompt user for the EFI partition number
    echo "Enter the EFI partition number: "
    read num
    efi_partition="${disk_address}${num}"
    # Format the EFI partition
    mkfs.vfat -F 32 $efi_partition
fi

# Check if a swap partition was created
read -p "Did you also create a swap partition? (y/n)" answer
if [[ $answer = y ]] ; then
    # Prompt user for the swap partition number
    echo "Enter the swap partition number: "
    read num
    swap_partition="${disk_address}${num}"
    # Format the swap partition
    mkswap $swap_partition
fi

# Mount the root partition to /mnt
mount $root_partition /mnt

# Detect CPU manufacturer and set appropriate microcode package
CPU=$(grep vendor_id /proc/cpuinfo)
microcode="$([[ $CPU == *"AuthenticAMD"* ]] && echo "amd-ucode" || echo "intel-ucode")"

# Install "essential" packages
pacstrap /mnt base base-devel linux linux-headers linux-firmware $"microcode" grub efibootmgr os-prober archlinux-keyring zsh opendoas

# Will include later to above pacstrap install
# firefox neovim feh ttf-jetbrains-mono-nerd noto-fonts-emoji noto-fonts-cjk mpv obs-studio htop
# neofetch unzip xlcip man-db unclutter networkmanager dhcpcd fd ripgrep flameshot xorg-server xorg-xinit 

# Generate an fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Change root into the new system
arch-chroot /mnt

# Set timezone
ln -sf /usr/share/zoneinfo/$(curl -s http://ip-api.com/line?fields=timezone) /etc/localtime

# Set the hardware clock from the system clock
hwclock --systohc

# Set locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Set hostname
echo "Enter hostname: "
read hostname
echo $hostname > /etc/hostname

# Configure /etc/hosts
echo "127.0.0.1       localhost" >> /etc/hosts
echo "::1             localhost" >> /etc/hosts
echo "127.0.1.1		$hostname.localdomain	$hostname >> /etc/hosts"

# Set root password
passwd

# Set username and password
echo "Enter username: "
read username
useradd -m -s /bin/zsh $username
passwd $username

# Create and set doas config file
touch /etc/doas.conf
echo "permit persist keepenv $username" >> /etc/doas.conf
echo "permit nopass $username cmd su" >> /etc/doas.conf

# Configure GRUB
mkdir /boot/efi
mount $efi_partition /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Exit chroot and unmount partitions
exit
umount -R /mnt

clear
echo "Installation Complete! Please reboot now!"
