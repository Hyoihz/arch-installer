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

partition_block=""

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

        # Check if the entered partition block exists
        if [ -b "/dev/$partition_block" ]; then
            # Prompt user for confirmation
            while true; do
                prompt_input "Partition table will be created on /dev/$partition_block. Proceed? (Y/n): "
                read -r confirm

                case $confirm in
                    [Yy]* | '' )
                        # Create partition table on the selected block
                        if is_uefi_boot; then
                            parted -s /dev/"$partition_block" mklabel gpt
                        else
                            parted -s /dev/"$partition_block" mklabel msdos
                        fi

                        # Prompt user that partition table has been created
                        display_info "Partition table $(is_uefi_boot && echo 'gpt' || echo 'msdos') created on /dev/$partition_block."
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
            display_error "Partition block /dev/$partition_block does not exist." && echo
        fi
    done
}

display_info "Checking firmware system..."
sleep 1

output_firmware_system
pause_script

create_partition_table
pause_script
