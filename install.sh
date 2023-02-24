#!/bin/bash

#  Make pacman colorful and set number of concurrent downloads
sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf

# Display available block devices
echo "Available block devices:"
lsblk -o NAME,SIZE,MODEL

# Prompt user for the block device to partition
read -p "Enter the disk for partitioning (e.g. sda/vda): " disk
disk_address="/dev/$disk"

# Partition the disk with cfdisk
cfdisk "$disk_address"

# Prompt user for the root partition number
clear
lsblk -o NAME,SIZE,TYPE "$disk_address"
read -p "Enter the root partition number: " num
root_partition="${disk_address}${num}"

# Format the root partition
mkfs.ext4 "$root_partition"

# Mount the root partition to /mnt
mount "$root_partition" /mnt

# Check if an EFI partition was created
read -p "Did you create an EFI partition? (y/n): " answer
if [[ $answer = y ]] ; then
    # Prompt user for the EFI partition number
    clear
    lsblk -o NAME,SIZE,TYPE "$disk_address"
    read -p "Enter the EFI partition number (e.g. 1): " num
    efi_partition="${disk_address}${num}"

    # Format the EFI partition
    mkfs.vfat -F 32 "$efi_partition"

    # Create a mount point for the EFI partition
    mkdir -p /mnt/boot/efi

    # Mount the EFI partition to /mnt/boot/efi
    mount "$efi_partition" /mnt/boot/efi
fi

# Check if a swap partition was created
read -p "Did you also create a swap partition? (y/n): " answer
if [[ $answer = y ]] ; then
    # Prompt user for the swap partition number
    clear
    lsblk -o NAME,SIZE,TYPE "$disk_address"
    read -p "Enter the swap partition number (e.g. 1): " num
    swap_partition="${disk_address}${num}"

    # Format the swap partition
    mkswap "$swap_partition"

    # Enable the swap partition
    swapon "$swap_partition"
fi

# Detect CPU manufacturer and set appropriate microcode package
CPU=$(grep vendor_id /proc/cpuinfo)
microcode="$([[ $CPU == *"AuthenticAMD"* ]] && echo "amd-ucode" || echo "intel-ucode")"

# Install "essential" packages
pacstrap /mnt base base-devel linux linux-headers linux-firmware "$microcode" grub efibootmgr os-prober archlinux-keyring zsh opendoas

# Will include later to above pacstrap install
# firefox neovim feh ttf-jetbrains-mono-nerd noto-fonts-emoji noto-fonts-cjk mpv obs-studio htop
# neofetch unzip xlcip man-db unclutter networkmanager dhcpcd fd ripgrep flameshot xorg-server xorg-xinit 

# Generate an fstab file
genfstab -U /mnt >> /mnt/etc/fstab

# Prompt user for hostname and username
read -p "Enter hostname: " hostname
read -p "Enter username: " username

# Define functions

setup_timezone() {
    ln -sf /usr/share/zoneinfo/"$(curl -s http://ip-api.com/line?fields=timezone)" /etc/localtime
    hwclock --systohc
}

setup_locale() {
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
}

setup_hostname() {
    echo "$hostname" > /etc/hostname

    {
      echo "127.0.0.1       localhost"
      echo "::1             localhost"
      echo "127.0.1.1       $hostname.localdomain       $hostname"
    } >> /etc/hosts
}

setup_root_password() {
    passwd
}

setup_user() {
    useradd -m -s /bin/zsh "$username"
    passwd "$username"

    # Create and set doas config file
    touch /etc/doas.conf
    echo "permit persist keepenv $username" >> /etc/doas.conf
    echo "permit nopass $username cmd su" >> /etc/doas.conf
}

setup_grub() {
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
}

# Execute functions in chroot environment

arch-chroot /mnt bash <<-EOF
    $(declare -f setup_timezone); setup_timezone
    $(declare -f setup_locale); setup_locale
    $(declare -f setup_hostname); setup_hostname
    $(declare -f setup_root_password); setup_root_password
    $(declare -f setup_user); setup_user
    $(declare -f setup_grub); setup_grub
EOF

# End
clear
echo "Installation complete! Please reboot now!"
