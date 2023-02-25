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

PARTITION_BLOCK=""

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
    [[ -d /sys/firmware/efi/ ]] && return 0
    return 1
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

create_partition_table() {
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
	PARTITION_BLOCK="/dev/$partition_block"

        # Check if the entered partition block exists
        if [ -b "$PARTITION_BLOCK" ]; then
            # Prompt user for confirmation
            while true; do
                prompt_input "Partition table will be created on $PARTITION_BLOCK. Proceed? (Y/n): "
                read -r confirm

                case $confirm in
                    [Yy]* | '' )
                        # Create partition table on the selected block
			#if (is_uefi_boot); then
                        #    parted -s "$PARTITION_BLOCK" mklabel gpt
                        #else
                        #    parted -s "$PARTITION_BLOCK" mklabel msdos
                        #fi

                        ## Prompt user that partition table has been created
                        #display_info "Partition table $(is_uefi_boot && echo 'gpt' || echo 'msdos') created on $PARTITION_BLOCK."
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
            display_error "Partition block $PARTITION_BLOCK does not exist." && echo
        fi
    done
}

set_disk_vars() {
if $(is_uefi_boot); then
    DISK_LABEL='GPT'
    EFI_MTPT='/mnt/boot/efi'
    if [[ $IN_DEVICE =~ nvme ]]; then
        EFI_PARTITION="${PARTITION_BLOCK}p1" 
	ROOT_PARTITION="${PARTITION_BLOCK}p2"
        SWAP_PARTITION="${PARTITION_BLOCK}p3"
    else
        EFI_PARTITION="${PARTITION_BLOCK}1" 
    fi
else
    DISK_LABEL='MBR'
    BOOT_MTPT='/mnt/boot'
    BOOT_PARTITION="${PARTITION_BLOCK}1"
fi

ROOT_PARTITION="${PARTITION_BLOCK}2"
SWAP_PARTITION="${PARTITION_BLOCK}3"
}

set_partition_sizes() {
    available_space=$(lsblk -nb -o SIZE -d "$PARTITION_BLOCK" | tail -1)

    if $(is_uefi_boot); then
        prompt="Enter EFI partition size (e.g. 512M): "
    else
        prompt="Enter BOOT partition size (e.g. 512M): "
    fi

    while true; do
    echo "Available space: $(numfmt --to=iec --format='%.1f' "$available_space")"
    read -rp "$prompt" size
        if [[ "$size" =~ ^[0-9]+[KMGT]$ ]]; then
            size_bytes=$(numfmt --from=iec "$size")
            if [[ "$size_bytes" -le 0 ]]; then
                echo "Invalid size. Please specify a positive size."
            elif [[ "$size_bytes" -gt "$available_space" ]]; then
                echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec --format='%.1f' "$available_space")."
            else
                available_space=$((available_space - size_bytes))
                break
            fi
        else
            echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)."
        fi
    done

    prompt="Enter swap partition size (e.g. 4G): "
    while true; do
    echo "Available space: $(numfmt --to=iec --format='%.1f' "$available_space")"
    read -rp "$prompt" swap_size
        if [[ "$swap_size" =~ ^[0-9]+[KMGT]$ ]]; then
            swap_size_bytes=$(numfmt --from=iec "$swap_size")
            if [[ "$swap_size_bytes" -le 0 ]]; then
                echo "Invalid size. Please specify a positive size."
            elif [[ "$swap_size_bytes" -gt "$available_space" ]]; then
                echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec --format='%.1f' "$available_space")."
            else
                available_space=$((available_space - swap_size_bytes))
                break
            fi
        else
            echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 4G)."
        fi
    done

    if $(is_uefi_boot); then
        echo "EFI partition size: $size"
    else
        echo "BOOT partition size: $size"
    fi

    echo "SWAP partition size: $swap_size"
    echo "ROOT partition size: $(numfmt --to=iec "$available_space")"

    read -rp "Are you satisfied with these partition sizes? (Y/n) " choice
    while [[ "$choice" != "y" && "$choice" != "n"  && "$choice" != "" ]]; do
        read -rp "Invalid input. Please enter 'y' or 'n': " choice
    done

    if [[ "$choice" == "n" ]]; then
        set_partition_sizes
    fi
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
        sgdisk -Z "$PARTITION_BLOCK"
        sgdisk -n 1::+"$size" -t 1:ef00 -c 1:EFI "$PARTITION_BLOCK"
        sgdisk -n 2::+"$swap_size" -t 2:8200 -c 2:SWAP "$PARTITION_BLOCK"
        sgdisk -n 3 -t 3:8300 -c 3:ROOT "$PARTITION_BLOCK"

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
$BOOT_PARTITION : start= 2048, size=+$size, type=83, bootable
$SWAP_PARTITION : size=+$swap_size, type=82
$ROOT_PARTITION : type=83
EOF

        # Using sfdisk because we're talking MBR disktable now...
        sfdisk "$PARTITION_BLOCK" < /tmp/sfdisk.cmd

        # Format and mount slices for non-EFI
        format_partition "$ROOT_PARTITION" "ext4"
        mount_partition "$ROOT_PARTITION" /mnt
        format_partition "$BOOT_PARTITION" "ext4"
        mkdir /mnt/boot
        mount_partition "$BOOT_PARTITION" "$BOOT_MTPT"
        mkswap "$SWAP_PARTITION" && swapon "$SWAP_PARTITION"
    fi

    lsblk "$PARTITION_BLOCK"
    echo "Type any key to continue..."; read empty
}


display_info "Checking firmware system..."
sleep 1

output_firmware_system
pause_script

create_partition_table
pause_script

set_disk_vars
set_partition_sizes
create_partitions
