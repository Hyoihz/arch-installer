#!/bin/bash

#  Make pacman colorful and set number of concurrent downloads
#sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
#sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf

# Ansi codes
BOLD='\e[1m'
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
RESET='\e[0m'

display_info() {
    echo -e "${BOLD}${BLUE}[ ${MAGENTA}•${BLUE} ] $1${RESET}"
}

display_error() {
    echo -e "${BOLD}${RED}[ ${MAGENTA}•${RED} ] $1${RESET}"
}

prompt_input() {
    echo -ne "${YELLOW}[ ${BOLD}${MAGENTA}•${YELLOW}${RESET}${YELLOW} ] $1${RESET}"
}

is_uefi_boot() {
    # If the directory exists, system is using UEFI
    [[ -d /sys/firmware/efi/ ]] && return 0 || return 1
}

output_firmware_system() {
    if is_uefi_boot; then
        echo && display_info "Your system is using UEFI boot."
    else
        echo && display_info "Your system is using BIOS legacy boot."
    fi
}

pause_script() {
    prompt_input "Press any key to continue..."
    read _ && clear
}

get_partition_block() {
    # Flag to stop the outer loop in the inner loop
    valid_input=false

    # Loop until a valid partition block is entered
    while ! $valid_input; do
        # Show available block devices
        display_info "Select the block you wish to partition."
        display_info "Available block devices:"
        lsblk -o NAME,SIZE,MODEL

        # Prompt user for partition block
        prompt_input "Enter the partition block (e.g. sda, vda): "
        read -r partition_block
        partition_block_path="/dev/$partition_block"

        # Check if the entered partition block exists
        if [ -b "$partition_block_path" ]; then
            # Prompt user for confirmation
            while true; do
                prompt_input "You've chosen ${BOLD}$partition_block${RESET}${YELLOW} for partitioning. Proceed? (Y/n): "
                read -r confirm

                case $confirm in
                    [Yy]* | '')
                        valid_input=true && break
                        ;;
                    [Nn]*)
                        clear && break
                        ;;
                    *)
                        clear && display_error "Invalid input. Please enter y or n."
                        ;;
                esac
            done
        else
            # Partition block does not exist
            clear && display_error "Partition block $partition_block does not exist." && echo
        fi
    done
}

set_partition_vars() {
    if $(is_uefi_boot); then
        # GPT
        EFI_MTPT="/mnt/boot/efi"
        if [[ $IN_DEVICE =~ nvme ]]; then
            EFI_PARTITION="${partition_block_path}p1"
            ROOT_PARTITION="${partition_block_path}p2"
            SWAP_PARTITION="${partition_block_path}p3"
        else
            EFI_PARTITION="${partition_block_path}1"
        fi
    else
        # MBR
        BOOT_MTPT="/mnt/boot"
        BOOT_PARTITION="${partition_block_path}1"
    fi
    # Both
    ROOT_PARTITION="${partition_block_path}2"
    SWAP_PARTITION="${partition_block_path}3"
}

read_partition_size() {
    clear
    while true; do
        # Get the available space for the partition
        display_info "Available space: $(numfmt --to=iec --format='%.1f' "$2")"
        # Prompt the user to enter the partition size
        prompt_input "$1"
        read -r size

        # Validate the partition size format and available space
        if [[ "$size" =~ ^[0-9]+[KMGT]$ ]]; then
            size_bytes=$(numfmt --from=iec "$size")
            if [[ "$size_bytes" -le 0 ]]; then
                # Display an error if the partition size is invalid
                clear && display_error "Invalid size. Please specify a valid size." && echo
            elif [[ "$size_bytes" -gt "$2" ]]; then
                # Display an error if the partition size is larger than the available space
                clear && display_error "Not enough available space. Please specify a size smaller than $(numfmt --to=iec --format='%.1f' "$2")." && echo
            else
                # Assign the partition size to the appropriate variable and update the available space
                if [[ $3 == "boot_size" ]]; then
                    boot_size=$size
                else
                    swap_size=$size
                fi

                available_space=$(($2 - size_bytes)) && break
            fi
        else
            # Display an error if the partition size is larger than the available space
            clear && display_error "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)." && echo
        fi
    done
}

confirm_partition_sizes() {
    clear && display_info "Consuming remaining size for root..." && sleep 1
    display_info "Assigned partition sizes: " && echo

    # Display the sizes of the EFI/BOOT, SWAP, and ROOT partitions
    if $(is_uefi_boot); then
        display_info "EFI partition size: $boot_size"
    else
        display_info "BOOT partition size: $boot_size"
    fi

    display_info "SWAP partition size: $swap_size"
    display_info "ROOT partition size: $(numfmt --to=iec --format='%.1f' "$available_space")"

    # Prompt the user to confirm the partition sizes
    prompt_input "Are you satisfied with these partition sizes? (Y/n) "
    read -r choice

    while [[ "$choice" != "y" && "$choice" != "n" && "$choice" != "" ]]; do
        prompt_input "Invalid input. Please enter 'y' or 'n': "
        read -r choice
    done

    # Return 1 if the user does not confirm the partition sizes, 0 otherwise
    [[ "$choice" == "n" ]] && return 1 || return 0
}

set_partition_sizes() {
    # Determine available space on the device
    available_space=$(lsblk -nb -o SIZE -d "$partition_block_path" | tail -1)

    # Prompt the user to enter the size of the boot partition (UEFI or BIOS)
    if $(is_uefi_boot); then
        prompt="Enter EFI partition size (e.g. 512M): "
    else
        prompt="Enter BOOT partition size (e.g. 512M): "
    fi

    read_partition_size "$prompt" "$available_space" "boot_size"

    # Prompt the user to enter the size of the swap partition
    prompt="Enter SWAP partition size (e.g. 4G): "
    read_partition_size "$prompt" "$available_space" "swap_size"

    # Confirm the partition sizes with the user and give the option to modify them if needed
    confirm_partition_sizes
    [[ $? -ne 0 ]] && set_partition_sizes
}

format_partition() {
    mkfs."$2" "$1" || display_error "format_partition(): Can't format device $1 with $2"
}

mount_partition() {
    mount "$1" "$2" || display_error "mount_partition(): Can't mount $1 to $2"
}

create_partitions() {
    # Creates partitions on the block device, formats them, and mounts them
    if $(is_uefi_boot); then
        # Create GPT partition table and partitions for UEFI boot
        sgdisk -Z "$partition_block_path"
        sgdisk -n 1::+"$boot_size" -t 1:ef00 -c 1:EFI "$partition_block_path"
        sgdisk -n 2::+"$swap_size" -t 2:8200 -c 2:SWAP "$partition_block_path"
        sgdisk -n 3 -t 3:8300 -c 3:ROOT "$partition_block_path"

        # Format partitions
        mkfs.fat -F32 "$EFI_PARTITION"
        format_partition "$ROOT_PARTITION" "ext4"
        mkswap "$SWAP_PARTITION"

        # Mount partitions
        mkdir -p "$EFI_MTPT"
        mount_partition "$EFI_PARTITION" "$EFI_MTPT"
        mount_partition "$ROOT_PARTITION" /mnt
        swapon "$SWAP_PARTITION"
    else
        # Create partitions for BIOS boot
        cat > /tmp/sfdisk.cmd << EOF
$BOOT_PARTITION : start= 2048, size=+$boot_size, type=83, bootable
$SWAP_PARTITION : size=+$swap_size, type=82
$ROOT_PARTITION : type=83
EOF
        sfdisk "$partition_block_path" < /tmp/sfdisk.cmd

        # Format partitions
        format_partition "$BOOT_PARTITION" "ext4"
        format_partition "$ROOT_PARTITION" "ext4"
        mkswap "$SWAP_PARTITION"

        # Mount partitions
        mkdir -p "$BOOT_MTPT"
        mount_partition "$BOOT_PARTITION" "$BOOT_MTPT"
        mount_partition "$ROOT_PARTITION" /mnt
        swapon "$SWAP_PARTITION"
    fi

    echo && lsblk "$partition_block_path"
}

set_password() {
    while true; do
        prompt_input "Enter a password for $1: "
        read -r -s password

        # Check if the password is empty
        if [[ -z "$password" ]]; then
            clear && display_error "You need to enter a password, try again."
        else
            # Prompt the user to confirm the password
            echo && prompt_input "Enter the password again: "
            read -r -s password2 && echo

            # Check if the two passwords match
            if [[ "$password" != "$password2" ]]; then
                clear && display_error "Passwords don't match, try again."
            else
                # Store the password as root password or user password
                if [[ $1 == "root" ]]; then
                    root_pass=$password
                else
                    user_pass=$password
                fi
		break
            fi
        fi
    done
}

set_root_password() {
    clear && display_info "Set a root password." && echo

    set_password "root"

    # Set the root password
    echo "root:$root_pass" | arch-chroot /mnt chpasswd || {
        display_error "Failed to set root password."
    }

    display_info "Root password set successfully."
    pause_script
}

setup_sudo_access() {
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/00-wheel-can-sudo
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: \
    /usr/bin/shutdown,\
    /usr/bin/reboot,\
    /usr/bin/systemctl suspend,\
    /usr/bin/mount,\
    /usr/bin/umount,\
    /usr/bin/pacman -Syu,\
    /usr/bin/pacman -Syyu,\
    /usr/bin/pacman -Syyu --noconfirm,\
    /usr/bin/pacman -Syyuw --noconfirm,\
    /usr/bin/pacman -S -u -y --config /etc/pacman.conf --,\
    /usr/bin/pacman -S -y -u --config /etc/pacman.conf --" \
    > /mnt/etc/sudoers.d/01-no-pass-cmds

    display_info "Adding the user $1 to the system with root privilege."
    arch-chroot /mnt bash -c "usermod -aG wheel '$1'" > /dev/null
    display_info "Sudo access configured for '$1'." && echo
}

create_user_account() {
    display_info "Create a user credential." && echo

    while true; do
        prompt_input "Enter username (leave blank ito not create one): "
        read -r username

        # Check if the user already exists
        if id "$username" > /dev/null 2>&1; then
            clear && display_error "User $username already exists, try again." && continue
        fi

        # If the username is empty, exit the loop
        [[ -z "$username" ]] && break

        set_password "$username"

        display_info "Creating an account for user $username..."
        # Create the user account
        arch-chroot /mnt bash -c "useradd -m -G wheel '$username' >/dev/null 2>&1" || {
            display_error "Failed to create an account for '$username'." && continue
        }

        display_info "Setting the provided password of user $username."
        # Set the password for the user account
        echo "$username:$user_pass" | arch-chroot /mnt chpasswd || {
            display_error "Failed to set a password for '$username'." && continue
        }

        echo && display_info "User account '$username' created." && break
    done

    # Only set up sudo access if a username is provided
    [[ -n "$username" ]] && setup_sudo_access "$username"

    display_info "Finished setting up user account '$username'." && echo
}

set_hostname() {
    while true; do
        prompt_input "Please enter a hostname: "
        read -r hostname

        # If hostname is empty, print an error message and continue the loop until a valid input is provided
        [[ -z "$hostname" ]] && display_error "You need to enter a hostname in order to continue." && continue
    done
}

set_host() {
    echo "$hostname" > /etc/hostname

    {
        echo "127.0.0.1       localhost"
        echo "::1             localhost"
        echo "127.0.1.1       $hostname.localdomain       $hostname"
    } >> /etc/hosts
}

set_timezone() {
    ln -sf /usr/share/zoneinfo/"$(curl -s http://ip-api.com/line?fields=timezone)" /etc/localtime
    hwclock --systohc
}

set_locale() {
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
}

set_grub() {
    if is_uefi_boot; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    else
        grub-install --target=i386-pc $partition_block_path
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

get_microcode() {
    # Detect CPU manufacturer and set appropriate microcode package
    CPU=$(grep vendor_id /proc/cpuinfo)
    microcode="$([[ $CPU == *"AuthenticAMD"* ]] && echo "amd-ucode" || echo "intel-ucode")"
}

clear

## Display current boot mode prior to running the script
#display_info "Checking firmware system..." && sleep 1
#output_firmware_system
#pause_script
#
## Partitioning
#get_partition_block
#pause_script
#
#set_partition_vars
#set_partition_sizes
#create_partitions
#pause_script
#
## Installation of base system
#display_info "Installing the base system..."
#pacstrap -K /mnt base base-devel linux linux-firmware linux-headers
#
## Generate an fstab file
#display_info "Generating fstab..."
#genfstab -U /mnt >> /mnt/etc/fstab
#
# Credentials
set_root_password
create_user_account
