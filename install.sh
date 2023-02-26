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
    read _
    clear
}

get_partition_block() {
    # Loop until a valid partition block is entered
    valid_input=false

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
                    valid_input=true
                    break
                    ;;
                [Nn]*)
                    clear
                    break
                    ;;
                *)
                    clear
                    display_error "Invalid input. Please enter y or n."
                    ;;
                esac
            done
        else
            # Partition block does not exist
            clear
            display_error "Partition block $partition_block does not exist." && echo
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

    ROOT_PARTITION="${partition_block_path}2"
    SWAP_PARTITION="${partition_block_path}3"
}

read_partition_size() {
    clear
    while true; do
        display_info "Available space: $(numfmt --to=iec --format='%.1f' "$2")"
        prompt_input "$1"
        read -r size
        if [[ "$size" =~ ^[0-9]+[KMGT]$ ]]; then
            size_bytes=$(numfmt --from=iec "$size")
            if [[ "$size_bytes" -le 0 ]]; then
                clear
                display_error "Invalid size. Please specify a valid size." && echo
            elif [[ "$size_bytes" -gt "$2" ]]; then
                clear
                display_error "Not enough available space. Please specify a size smaller than $(numfmt --to=iec --format='%.1f' "$2")." && echo
            else
                if [[ $3 == "boot_size" ]]; then
                    boot_size=$size
                else
                    swap_size=$size
                fi

                available_space=$(($2 - size_bytes))
                break
            fi
        else
            clear
            display_error "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)." && echo
        fi
    done
}

confirm_partition_sizes() {
    clear
    display_info "Consuming remaining size for root..." && sleep 1
    display_info "Assigned partition sizes: " && echo

    if $(is_uefi_boot); then
        display_info "EFI partition size: $boot_size"
    else
        display_info "BOOT partition size: $boot_size"
    fi

    display_info "SWAP partition size: $swap_size"
    display_info "ROOT partition size: $(numfmt --to=iec --format='%.1f' "$available_space")"

    prompt_input "Are you satisfied with these partition sizes? (Y/n) "
    read -r choice
    while [[ "$choice" != "y" && "$choice" != "n" && "$choice" != "" ]]; do
        prompt_input "Invalid input. Please enter 'y' or 'n': "
        read -r choice
    done

    [[ "$choice" == "n" ]] && return 1 || return 0
}

set_partition_sizes() {
    available_space=$(lsblk -nb -o SIZE -d "$partition_block_path" | tail -1)

    if $(is_uefi_boot); then
        prompt="Enter EFI partition size (e.g. 512M): "
    else
        prompt="Enter BOOT partition size (e.g. 512M): "
    fi

    read_partition_size "$prompt" "$available_space" "boot_size"

    prompt="Enter SWAP partition size (e.g. 4G): "
    read_partition_size "$prompt" "$available_space" "swap_size"

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
    if $(is_uefi_boot); then
        sgdisk -Z "$partition_block_path"
        sgdisk -n 1::+"$boot_size" -t 1:ef00 -c 1:EFI "$partition_block_path"
        sgdisk -n 2::+"$swap_size" -t 2:8200 -c 2:SWAP "$partition_block_path"
        sgdisk -n 3 -t 3:8300 -c 3:ROOT "$partition_block_path"

        # Format
        mkfs.fat -F32 "$EFI_PARTITION"
        format_partition "$ROOT_PARTITION" "ext4"
        mkswap "$SWAP_PARTITION"
        # Mount
        mkdir -p "$EFI_MTPT"
        mount_partition "$EFI_PARTITION" "$EFI_MTPT"
        mount_partition "$ROOT_PARTITION" /mnt
        swapon "$SWAP_PARTITION"
    else
        cat >/tmp/sfdisk.cmd <<EOF
$BOOT_PARTITION : start= 2048, size=+$boot_size, type=83, bootable
$SWAP_PARTITION : size=+$swap_size, type=82
$ROOT_PARTITION : type=83
EOF
        sfdisk "$partition_block_path" </tmp/sfdisk.cmd

        # Format
        format_partition "$BOOT_PARTITION" "ext4"
        format_partition "$ROOT_PARTITION" "ext4"
        mkswap "$SWAP_PARTITION"
        # Mount
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
        if [[ -z "$password" ]]; then
            clear && display_error "You need to enter a password, try again."
        else
            echo && prompt_input "Enter the password again: "
            read -r -s password2 && echo
            if [[ "$password" != "$password2" ]]; then
                clear && display_error "Passwords don't match, try again."
            else
                if [[ $1 == "root" ]]; then
                    root_pass=$password
                else
                    user_pass=$password
                fi
                return 0
            fi
        fi
    done
}

create_user_account() {
    display_info "Create user(s)." && echo
    while true; do
        prompt_input "Enter username (leave blank to stop): "
        read -r username

	if id "$username" > /dev/null 2>&1; then
	    clear
	    display_error "User $username already exists, try again."
	    continue
	fi

        [[ -z "$username" ]] && break
        set_password "$username"

        # Create the user account.
        useradd -m "$username" > /dev/null 2>&1 || {
            display_error "Failed to create an account for '$username'."
            continue
        }
        echo "$username:$user_pass" | chpasswd || {
            display_error "Failed to set a password for '$username'."
            continue
        }

        echo && display_info "User account '$username' created."
	pause_script
    done
}

set_root_password() {
    # Prompt for the root password.
    clear
    display_info "Set a root password." && echo

    set_password "root" || {
        display_error "Failed to set root password."
        return 1
    }
    echo "root:$root_pass" | chpasswd || {
        display_error "Failed to set root password."
        return 1
    }

    display_info "Root password set successfully."
    pause_script

    return 0
}

clear


display_info "Checking firmware system..." && sleep 1
output_firmware_system
pause_script

get_partition_block
pause_script

set_partition_vars
set_partition_sizes
create_partitions
pause_script

set_root_password
create_user_account
