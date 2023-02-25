#!/bin/bash

#  Make pacman colorful and set number of concurrent downloads
#sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
#sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf

# Cosmetics (colors for text).
BOLD='\e[1m'
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
RESET='\e[0m'

# Pretty print (function).
info_print () {
    echo -e "${BOLD}${BLUE}[ ${MAGENTA}•${BLUE} ] $1${RESET}"
}

# Pretty print for input (function).
input_print () {
    echo -ne "${YELLOW}[ ${BOLD}${MAGENTA}•${YELLOW}${RESET}${YELLOW} ] $1${RESET}"
}

# Alert user of bad input (function).
error_print () {
    echo -e "${BOLD}${RED}[ ${MAGENTA}•${RED} ] $1${RESET}"
}

is_uefi_boot() {
    [[ -d /sys/firmware/efi/ ]] && return 0
    return 1
}

output_firmware_system() {
    if is_uefi_boot; then
        echo && info_print "The system is using UEFI boot."
    else
        info_print "The system is using BIOS legacy boot."
    fi
}

info_print "Checking firmware system..."
sleep 1

output_firmware_system

input_print "Press any key to continue..."
read _

clear

# Loop until a valid partition block is entered
while true; do
    # Show available block devices
    info_print "Select the block to create partition table on."
    info_print "Available block devices:"
    lsblk -o NAME,SIZE,MODEL

    # Prompt user for partition block
    input_print "Enter the partition block (e.g. sda, vda): "
    read -r partition_block

    # Check if the entered partition block exists
    if [ -b "/dev/$partition_block" ]; then
        # Prompt user for confirmation
        input_print "Partition table will be created on /dev/$partition_block. Proceed? (Y/n): "
        read -r confirm
        case $confirm in
            [Yy]* ) break;;
            [Nn]* ) clear;;
	    '' ) break;;
            * ) error_print "Please enter Y or N.";;
        esac
    else
        # Partition block does not exist
        clear
        error_print "Partition block /dev/$partition_block does not exist." && echo
    fi
done

# Create partition table on the selected block
if is_uefi_boot; then
    parted -s /dev/"$partition_block" mklabel gpt
else
    parted -s /dev/"$partition_block" mklabel msdos
fi

# Prompt user that partition table has been created
info_print "Partition table $(is_uefi_boot && echo 'gpt' || echo 'msdos') created on /dev/$partition_block."
