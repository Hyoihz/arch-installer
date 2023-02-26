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

display_info () {
    echo -e "${BOLD}${BLUE}[ ${MAGENTA}•${BLUE} ] $1${RESET}"
}

display_error () {
    echo -e "${BOLD}${RED}[ ${MAGENTA}•${RED} ] $1${RESET}"
}

prompt_input () {
    echo -ne "${YELLOW}[ ${BOLD}${MAGENTA}•${YELLOW}${RESET}${YELLOW} ] $1${RESET}"
}

is_uefi_boot() {
    [[ -d /sys/firmware/efi/ ]] && return 0 || return 1
}

output_firmware_system() {
    if is_uefi_boot; then
        echo && display_info "The system is using UEFI boot."
    else
        echo && display_info "The system is using BIOS legacy boot."
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
        display_info "Select the block to create partition table on."
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
                prompt_input "Partition table will be created on $partition_block_path. Proceed? (Y/n): "
                read -r confirm

                case $confirm in
                    [Yy]* | '' )
                        valid_input=true
                        break
                        ;;
                    [Nn]* )
                        clear
                        break
                        ;;
                    * )
                        clear
                        display_error "Invalid input. Please enter y or n."
                        ;;
                esac
            done
        else
            # Partition block does not exist
            clear
            display_error "Partition block $partition_block_path does not exist." && echo
        fi
    done
}

set_partition_vars() {
if $(is_uefi_boot); then
    # GPT
    EFI_MTPT='/mnt/boot/efi'
    if [[ $IN_DEVICE =~ nvme ]]; then
        EFI_PARTITION="${partition_block_path}p1" 
	ROOT_PARTITION="${partition_block_path}p2"
        SWAP_PARTITION="${partition_block_path}p3"
    else
        EFI_PARTITION="${partition_block_path}1" 
    fi
else
    # MBR
    BOOT_MTPT='/mnt/boot'
    BOOT_PARTITION="${partition_block_path}1"
fi

ROOT_PARTITION="${partition_block_path}2"
SWAP_PARTITION="${partition_block_path}3"
}

read_partition_size() {
    while true; do
        echo "Available space: $(numfmt --to=iec --format='%.1f' "$2")"
        read -rp "$1" size
        if [[ "$size" =~ ^[0-9]+[KMGT]$ ]]; then
            size_bytes=$(numfmt --from=iec "$size")
            if [[ "$size_bytes" -le 0 ]]; then
                echo "Invalid size. Please specify a positive size."
            elif [[ "$size_bytes" -gt "$2" ]]; then
                echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec --format='%.1f' "$2")."
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
            echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)."
        fi
    done
}

confirm_partition_sizes() {
    if $(is_uefi_boot); then
        echo "EFI partition size: $boot_size"
    else
        echo "BOOT partition size: $boot_size"
    fi

    echo "SWAP partition size: $swap_size"
    echo "ROOT partition size: $(numfmt --to=iec --format='%.1f' "$available_space")"

    read -rp "Are you satisfied with these partition sizes? (Y/n) " choice
    while [[ "$choice" != "y" && "$choice" != "n"  && "$choice" != "" ]]; do
        read -rp "Invalid input. Please enter 'y' or 'n': " choice
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

    prompt="Enter swap partition size (e.g. 4G): "
    read_partition_size "$prompt" "$available_space" "swap_size"

    confirm_partition_sizes 
    [[ $? -ne 0 ]] && set_partition_sizes
}

format_partition(){
    device=$1; fstype=$2
    mkfs."$fstype" "$device" || error "format_partition(): Can't format device $device with $fstype"
}

mount_partition(){
    device=$1; mt_pt=$2
    mount "$device" "$mt_pt" || error "mount_partition(): Can't mount $device to $mt_pt"
}

create_partitions(){
    # We're just doing partitions, no LVM here
    clear
    if $(is_uefi_boot); then
        sgdisk -Z "$partition_block_path"
        sgdisk -n 1::+"$boot_size" -t 1:ef00 -c 1:EFI "$partition_block_path"
        sgdisk -n 2::+"$swap_size" -t 2:8200 -c 2:SWAP "$partition_block_path"
        sgdisk -n 3 -t 3:8300 -c 3:ROOT "$partition_block_path"

        # Format and mount slices for EFI
        format_partition "$ROOT_PARTITION" "vfat"
        mount_partition "$ROOT_PARTITION" /mnt
        mkfs.fat -F32 "$EFI_PARTITION"
        mkdir -p /mnt/boot/efi
        mount_partition "$EFI_PARTITION" "$EFI_MTPT"
        mkswap "$SWAP_PARTITION" && swapon "$SWAP_PARTITION"
    else
        # For non-EFI. Eg. for MBR systems
cat > /tmp/sfdisk.cmd << EOF
$BOOT_PARTITION : start= 2048, size=+$boot_size, type=83, bootable
$SWAP_PARTITION : size=+$swap_size, type=82
$ROOT_PARTITION : type=83
EOF

        # Using sfdisk because we're talking MBR disktable now...
        sfdisk "$partition_block_path" < /tmp/sfdisk.cmd

        # Format and mount slices for non-EFI
        format_partition "$ROOT_PARTITION" "ext4"
        mount_partition "$ROOT_PARTITION" /mnt
        format_partition "$BOOT_PARTITION" "ext4"
        mkdir /mnt/boot
        mount_partition "$BOOT_PARTITION" "$BOOT_MTPT"
        mkswap "$SWAP_PARTITION" && swapon "$SWAP_PARTITION"
    fi

    lsblk "$partition_block_path"
    echo "Type any key to continue..."; read empty
}


display_info "Checking firmware system..."
sleep 1

output_firmware_system
pause_script

get_partition_block
pause_script

set_partition_vars
set_partition_sizes
create_partitions
