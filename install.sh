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
                        if is_uefi_boot; then
                            parted -s "$PARTITION_BLOCK" mklabel gpt
                        else
                            parted -s "$PARTITION_BLOCK" mklabel msdos
                        fi

                        # Prompt user that partition table has been created
                        display_info "Partition table $(is_uefi_boot && echo 'gpt' || echo 'msdos') created on $PARTITION_BLOCK."
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
    while true; do
        available_space=$(lsblk -nb -o SIZE -d "$PARTITION_BLOCK" | tail -1)
	echo "Available space: $(numfmt --to=iec --format='%.1f' "$available_space")"
        if $is_uefi_boot; then
            read -p "Enter EFI partition size (e.g. 512M): " efi_size
            if [[ $efi_size =~ ^[0-9]+[KMGT]$ ]]; then
	        efi_size_bytes=$(numfmt --from=iec "$efi_size")
                if [[ "$efi_size_bytes" -le 0 ]]; then
                    echo "Invalid size. Please specify a positive size."
                elif [[ "$efi_size_bytes" -gt "$available_space" ]]; then
                    echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec "$available_space")."
                else
                    available_space=$((available_space - efi_size_bytes))
                    break
                fi
            else
                echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)."
            fi
        else
            read -rp "Enter BOOT partition size (e.g. 512M): " boot_size
            if [[ "$boot_size" =~ ^[0-9]+[KMGT]$ ]]; then
	        boot_size_bytes=$(numfmt --from=iec "$boot_size")
                if [[ "$boot_size_bytes" -le 0 ]]; then
                    echo "Invalid size. Please specify a positive size."
                elif [[ "$boot_size_bytes" -gt "$available_space" ]]; then
                    echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec "$available_space")."
                else
                    available_space=$((available_space - boot_size_bytes))
                    break
                fi
            else
                echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 512M)."
            fi
        fi
    done

    while true; do
	echo "Available space: $(numfmt --to=iec --format='%.1f' "$available_space")"
        read -rp "Enter swap partition size (e.g. 4G): " swap_size
        if [[ "$swap_size" =~ ^[0-9]+[KMGT]$ ]]; then
	    swap_size_bytes=$(numfmt --from=iec "$swap_size")
            if [[ "$swap_size_bytes" -le 0 ]]; then
                echo "Invalid size. Please specify a positive size."
            elif [[ "$swap_size_bytes" -gt "$available_space" ]]; then
                echo "Not enough available space. Please specify a size smaller than $(numfmt --to=iec "$available_space")."
            else
                available_space=$((available_space - swap_size_bytes))
                break
            fi
        else
            echo "Invalid size. Please specify a size in the format [0-9]+[KMG] (e.g. 4G)."
        fi
    done

    echo "EFI partition size: $efi_size"
    echo "Swap partition size: $swap_size"
    echo "Root partition size: $(numfmt --to=iec "$available_space")"

}

display_info "Checking firmware system..."
sleep 1

output_firmware_system
pause_script

create_partition_table
pause_script

set_disk_vars
set_partition_sizes
