#!/bin/bash

#The migration-tool helps to migrate to another product mainly from 
#openSUSE.

#Copyright (C) 2024 Marcela Maslanova
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU Affero General Public License as
#published by the Free Software Foundation, either version 3 of the
#License, or (at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU Affero General Public License for more details.
#
#You should have received a copy of the GNU Affero General Public License
#along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

# Ensure the script is run with Bash 4.0+ for associative array support
if ! [ "${BASH_VERSION:0:1}" -ge 4 ]; then
    echo "This script requires Bash 4.0 or higher." >&2
    exit 1
fi

# Define current system type (e.g., Leap, Slowroll, etc.)
CURRENT_SYSTEM="Leap"  # Change this as needed to reflect the current system

# Define migration targets using an associative array
declare -A MIGRATION_OPTIONS

if [ "$CURRENT_SYSTEM" == "Leap" ]; then
    MIGRATION_OPTIONS=(
        ["1"]="SLES"
        ["2"]="Tumbleweed"
        ["3"]="Slowroll"
        ["4"]="Leap 16.0"
    )
elif [ "$CURRENT_SYSTEM" == "Slowroll" ]; then
    MIGRATION_OPTIONS=(
        ["2"]="Tumbleweed"
    )
else
    echo "Unsupported system type: $CURRENT_SYSTEM" >&2
    exit 1
fi

# Generate the dialog input string from the associative array
DIALOG_ITEMS=()
for key in "${!MIGRATION_OPTIONS[@]}"; do
    DIALOG_ITEMS+=("$key" "${MIGRATION_OPTIONS[$key]}")
done

# Get terminal dimensions
read -r term_width term_height < <(stty size)

# Calculate dialog box dimensions with padding
border=2
dialog_width=$((term_width - 2 * border))
dialog_height=$((term_height - 2 * border))

# Ensure minimum dimensions for dialog box
dialog_width=$((dialog_width < 20 ? 20 : dialog_width))
dialog_height=$((dialog_height < 10 ? 10 : dialog_height))

# Display a dialog with calculated size
dialog --title "Dynamic Sizing Example" \
       --msgbox "This dialog adjusts to your terminal size." \
       "$dialog_height" "$dialog_width"

# Display the dialog menu
CHOICE=$(dialog --clear \
    --title "System Migration" \
    --menu "Select the migration target:" \
    $dialog_width $dialog_height 100 \
    "${DIALOG_ITEMS[@]}" \
    2>&1 >/dev/tty)

mkdir /etc/zypp/repos.d/old
mv /etc/zypp/repos.d/*.repo /etc/zypp/repos.d/old

# Clear the screen and handle the user choice
clear
if [ "$CHOICE" == "1" ]; then
	cat > /etc/os-release  << EOL
NAME="SLES" 
VERSION="15-SP6" 
VERSION_ID="15.6"
PRETTY_NAME="SUSE Linux Enterprise Server 15 SP6"
ID="sles"
ID_LIKE="suse"
ANSI_COLOR="0;32" 
CPE_NAME="cpe:/o:suse:sles:15:sp6"
EOL
	zypper in suseconnect-ng
	suseconnect -e  email -r number 
	suseconnect -p sle-module-basesystem/15.6/x86_64
	zypper in sles-release
	zypper dup
	SUSEConnect -p PackageHub/15.SP6/x86_64
# to tumbleweed
elif [ "$CHOICE" == "2" ]; then
        zypper ar -f -c http://download.opensuse.org/tumbleweed/repo/oss
        zypper in openSUSE-repos-Tumbleweed
	zypper dup --allow-vendor-change --force-resolution -y
# to slowroll
elif [ "$CHOICE" = "3" ]; then
        zypper addrepo https://download.opensuse.org/slowroll/repo/oss/ leap-to-slowroll
	shopt -s globstar && TMPSR=$(mktemp -d) && zypper --pkg-cache-dir=${TMPSR} download openSUSE-repos-Slowroll && zypper modifyrepo --all --disable && zypper install ${TMPSR}/**/openSUSE-repos-Slowroll*.rpm && zypper dist-upgrade
	zypper dup --allow-vendor-change --force-resolution -y
# to 16.0
elif [ "$CHOICE" == "4" ]; then
        zypper ar -f -c http://download.opensuse.org/16.0/repo/oss
	zypper in Leap-release
fi

if [ -n "$CHOICE" ]; then
    echo "You selected: ${MIGRATION_OPTIONS[$CHOICE]}"
    echo "Now is recommended to reboot. "
else
    echo "No option selected. Exiting."
    exit 1
fi
