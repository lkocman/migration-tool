#!/bin/bash
# Migration-tool: Helps migrate to another product, mainly from openSUSE.
#
# Copyright 2024 Marcela Maslanova, SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#set -x
#set -euo pipefail
# Trap to clean up on exit or interruption
#trap 'clear; tput cnorm' EXIT INT TERM
# Ensure required tools are installed
REQUIRED_TOOLS=("bc" "jq" "curl" "dialog")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "$tool is required but not installed. Please run: sudo zypper in $tool"
        exit 1
    fi
done
# Ensure Bash version is 4.0+
if ((BASH_VERSINFO[0] < 4)); then
    echo "This script requires Bash 4.0 or higher." >&2
    exit 1
fi
# Ensure /etc/os-release exists
if [[ ! -f /etc/os-release ]]; then
    echo "File /etc/os-release not found." >&2
    exit 2
fi
# Source OS release info
source /etc/os-release
# Fetch distribution data from API
API_URL="https://get.opensuse.org/api/v0/distributions.json"
API_DATA=$(curl -s "$API_URL")
if [ $? != 0 ]; then
    echo "Network error: Unable to fetch release data from https://get.opensuse.org/api/v0/distributions.json"
    echo "Ensure that you have working network connectivity and get.opensuse.org is accessible."
    exit 3
fi
DRYRUN=""
PRERELEASE=""
TMP_REPO_NAME="tmp-migration-tool-repo" # tmp repo to get sles-release or openSUSE-repos-*
# Initialize MIGRATION_OPTIONS as an empty associative array
declare -A MIGRATION_OPTIONS=()
CURRENT_INDEX=1
# Parse command-line arguments
function print_help() {
    echo "Usage: migration-tool [--pre-release] [--dry-run] [--help]"
    echo "  --pre-release  Include pre-release versions in the migration options."
    echo "  --dry-run      Show commands without executing them."
    echo "  --help         Show this help message and exit."
    exit 0
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --pre-release) PRERELEASE="YES"; shift ;;
        --dry-run) DRYRUN="echo"; shift ;;
        --help) print_help ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
# Populate migration options
function fetch_versions() {
    local filter="$1"
    local key="$2"
    jq -r ".${key}[] | select(${filter}) | .version" <<<"$API_DATA"
}
function populate_options() {
    local key="$1"
    local current_version="$2"
    local filter="$3"
    local versions
    versions=$(fetch_versions "$filter" "$key")
    while IFS= read -r version; do
        if (( $(bc <<<"$current_version < $version") )); then
            MIGRATION_OPTIONS["$CURRENT_INDEX"]="openSUSE $key $version"
            ((CURRENT_INDEX++))
        fi
    done <<<"$versions"
}
# System-specific options
if [[ "$NAME" == "openSUSE Leap Micro" ]]; then
    MIGRATION_OPTIONS["$CURRENT_INDEX"]="MicroOS"
    ((CURRENT_INDEX++))
    if [[ $PRERELEASE ]]; then
        populate_options "LeapMicro" "$VERSION" '.state!="EOL"'
    else
        populate_options "LeapMicro" "$VERSION" '.state=="Stable"'
    fi
elif [[ "$NAME" == "openSUSE Leap" ]] | [[ "$NAME" == "SLE" ]] ; then
    MIGRATION_OPTIONS["$CURRENT_INDEX"]="SUSE Linux Enterprise $(sed 's/\./ SP/' <<<"$VERSION")"
    ((CURRENT_INDEX++))
    MIGRATION_OPTIONS["$CURRENT_INDEX"]="openSUSE Tumbleweed"
    ((CURRENT_INDEX++))
    MIGRATION_OPTIONS["$CURRENT_INDEX"]="openSUSE Tumbleweed-Slowroll"
    ((CURRENT_INDEX++))
    if [[ $PRERELEASE ]]; then
        populate_options "Leap" "$VERSION" '.state!="EOL"'
    else
        populate_options "Leap" "$VERSION" '.state=="Stable"'
    fi
elif [[ "$NAME" == "openSUSE Tumbleweed-Slowroll" ]]; then
    MIGRATION_OPTIONS["$CURRENT_INDEX"]="openSUSE Tumbleweed"
    ((CURRENT_INDEX++))
else
    echo "Unsupported system type: $NAME" >&2
    exit 1
fi
# Display migration options
if [[ ${#MIGRATION_OPTIONS[@]} -eq 0 ]]; then
    echo "No migration options available."
    exit 1
fi
# Prepare dialog items
DIALOG_ITEMS=()
for key in "${!MIGRATION_OPTIONS[@]}"; do
    DIALOG_ITEMS+=("$key" "${MIGRATION_OPTIONS[$key]}")
done
# Display dialog and get choice
CHOICE=$(dialog --clear \
    --title "System Migration" \
    --menu "Select the migration target:" \
    20 60 10 \
    "${DIALOG_ITEMS[@]}" \
    2>&1 >/dev/tty) || exit
zypper in snapper grub2-snapper-plugin
rpmsave_repo() {
for repo_file in \
repo-backports-debug-update.repo repo-oss.repo repo-backports-update.repo \
repo-sle-debug-update.repo repo-debug-non-oss.repo repo-sle-update.repo \
repo-debug.repo repo-source.repo repo-debug-update.repo repo-update.repo \
repo-debug-update-non-oss.repo repo-update-non-oss.repo repo-non-oss.repo \
download.opensuse.org-oss.repo download.opensuse.org-non-oss.repo download.opensuse.org-tumbleweed.repo \
repo-openh264.repo openSUSE-*-0.repo repo-main.repo $TMP_REPO_NAME.repo; do
  if [ -f /etc/zypp/repos.d/$repo_file ]; then
    echo "Storing old copy as /etc/zypp/repos.d/$repo_file.rpmsave"
    mv /etc/zypp/repos.d/$repo_file /etc/zypp/repos.d/$repo_file.rpmsave
  fi
done
# regexpes
for file in /etc/zypp/repos.d/openSUSE-*.repo; do
    repo_file=$(basename $file)
    if [ -f /etc/zypp/repos.d/$repo_file ]; then
        echo "Storing old copy as /etc/zypp/repos.d/$repo_file.rpmsave"
        mv /etc/zypp/repos.d/$repo_file /etc/zypp/repos.d/$repo_file.rpmsave
    fi
done
# Ensure to drop any SCC generated service/repo files for Leap
# e.g. /etc/zypp/services.d/openSUSE_Leap_15.6_x86_64.service
for file in /etc/zypp/services.d/openSUSE_*.service; do
    service_file=$(basename $file)
    if [ -f /etc/zypp/services.d/$service_file ]; then
        echo "Storing old copy as /etc/zypp/repos.d/$service_file.rpmsave"
        mv /etc/zypp/services.d/$service_file /etc/zypp/services.d/$service_file.rpmsave
    fi
done
}
# Clear the screen and handle the user choice
clear
if [[ -n $CHOICE ]]; then
    echo "Selected option: ${MIGRATION_OPTIONS[$CHOICE]}"
    case "${MIGRATION_OPTIONS[$CHOICE]}" in
        *"SUSE Linux Enterprise"*|"SLE")
            $DRYRUN echo "Upgrading to ${MIGRATION_OPTIONS[$CHOICE]}"
            SP=$(sed 's/\./-SP/' <<<"$VERSION") # 15.6 -> 15-SP6
            ARCH=$(uname -i) # x86_64 XXX: check for other arches
            $DRYRUN zypper ar -f https://updates.suse.com/SUSE/Products/SLE-BCI/$SP/$ARCH/product/ $TMP_REPO_NAME
            $DRYRUN zypper in --force-resolution -y suseconnect-ng
            $DRYRUN zypper in --force-resolution -y unified-installer-release SLE_BCI-release # sles-release is not in BCI
            rpmsave_repo # invalidates all standard openSUSE repos
            #rpm -e --nodeps openSUSE-release
            # Dummy values for DRYRUN mode
            email="foo@bar"
            code="DUMMY-123456"
            if [ -z "$DRYRUN" ]; then
                read -p "Enter your email: " email
	            read -p "Enter your registration code: " code
            fi
	        $DRYRUN suseconnect -e  $email -r $code 
	        $DRYRUN SUSEConnect -p PackageHub/$VERSION/$ARCH
            $DRYRUN zypper dup --allow-vendor-change --force-resolution -y
            ;;
        "openSUSE Tumbleweed")
            $DRYRUN echo "Upgrading to ${MIGRATION_OPTIONS[$CHOICE]}"
            ;;
        "openSUSE Tumbleweed-Slowroll")
            $DRYRUN echo "Migrating to ${MIGRATION_OPTIONS[$CHOICE]}"
            ;;
        *"openSUSE Leap"*)
            $DRYRUN echo "Upgrading to ${MIGRATION_OPTIONS[$CHOICE]}"
            ;;
        *"openSUSE Leap Micro"*)
            $DRYRUN echo "Upgrading to ${MIGRATION_OPTIONS[$CHOICE]}"
            ;;
        *"MicroOS"*)
            $DRYRUN echo "Migrating to openSUSE MicroOS..."
            ;;
    esac
else
    echo "No option selected. Exiting."
    exit 1
fi
echo "Migration process completed. A reboot is recommended."
