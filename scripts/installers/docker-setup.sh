#!/usr/bin/env bash
set -eo pipefail

RED='\033[1;31m'
NC='\033[0m' # No Color
FORK=automaticrippingmachine
TAG=latest
ARM_USER=""
ARM_GROUP=""
# dir of this script, used to deploy the local (hardened) start command
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_START="$SCRIPT_DIR/../docker/start_arm_container.sh"

function usage() {
    echo -e "\nUsage: docker_setup.sh [OPTIONS]"
    echo -e " -f <fork>\tSpecify the fork to pull from on DockerHub. \n\t\tDefault is \"$FORK\""
    echo -e " -t <tag>\tSpecify the tag to pull from on DockerHub. \n\t\tDefault is \"$TAG\""
    echo -e " -u <user>\tUser that owns/runs ARM. Created if missing. \n\t\tPrompted if omitted."
    echo -e " -g <group>\tGroup for that user. Created if missing. \n\t\tPrompted if omitted."
}

while getopts 'f:t:u:g:' OPTION
do
    case $OPTION in
    f)    FORK=$OPTARG
          ;;
    t)    TAG=$OPTARG
          ;;
    u)    ARM_USER=$OPTARG
          ;;
    g)    ARM_GROUP=$OPTARG
          ;;
    ?)    usage
          exit 2
          ;;
    esac
done
IMAGE="$FORK/automatic-ripping-machine:$TAG"

# prompt for user/group when not passed as flags. default to the invoking
# (sudo) user so we reuse an existing account instead of a second one.
if [ -z "$ARM_USER" ]; then
    read -rp "User to own/run ARM [${SUDO_USER:-arm}]: " ARM_USER
    ARM_USER=${ARM_USER:-${SUDO_USER:-arm}}
fi
if [ -z "$ARM_GROUP" ]; then
    read -rp "Group for '$ARM_USER' [$ARM_USER]: " ARM_GROUP
    ARM_GROUP=${ARM_GROUP:-$ARM_USER}
fi

function install_reqs() {
    # scoped install only. run full system upgrades separately, on your own schedule
    apt install -y curl lsscsi wget
}

function add_arm_user() {
    echo -e "${RED}Ensuring group '$ARM_GROUP' and user '$ARM_USER'${NC}"
    # create group if it doesn't already exist
    if ! [[ "$(getent group "$ARM_GROUP")" ]]; then
        groupadd "$ARM_GROUP"
    else
        echo -e "${RED}group '$ARM_GROUP' already exists, skipping...${NC}"
    fi

    # create user if it doesn't already exist (reuse existing account otherwise)
    if ! id "$ARM_USER" >/dev/null 2>&1; then
        useradd -m "$ARM_USER" -g "$ARM_GROUP"
        passwd "$ARM_USER"
    else
        echo -e "${RED}user '$ARM_USER' already exists, skipping create...${NC}"
    fi
    usermod -aG cdrom,video "$ARM_USER"
}

function launch_setup() {
    # install docker
    if [ -e /usr/bin/docker ]; then
        echo -e "${RED}Docker installation detected, skipping...${NC}"
        echo -e "${RED}Adding user '$ARM_USER' to docker group (note: docker group = root-equivalent)${NC}"
        usermod -aG docker "$ARM_USER"
    else
        echo -e "${RED}Installing Docker${NC}"
        # the convenience script auto-detects OS and handles install accordingly
        curl -sSL https://get.docker.com | bash
        echo -e "${RED}Adding user '$ARM_USER' to docker group (note: docker group = root-equivalent)${NC}"
        usermod -aG docker "$ARM_USER"
    fi
}

function pull_image() {
    echo -e "${RED}Pulling image from $IMAGE${NC}"
    sudo -u "$ARM_USER" docker pull "$IMAGE"
}

function setup_mountpoints() {
    echo -e "${RED}Creating mount points${NC}"
    for dev in /dev/sr?; do
        mkdir -p "/mnt$dev"
    done
    chown "$ARM_USER:$ARM_GROUP" /mnt/dev/sr*
}

# Prompt for a path, offering a default; echoes the chosen value.
function prompt_path() {
    local label="$1" default="$2" ans
    read -rp "$label [$default]: " ans
    echo "${ans:-$default}"
}

function save_start_command() {
    # deploy the LOCAL (hardened) start command, not a blind upstream fetch,
    # so the no-privileged / device-scoped edits actually ship.
    arm_home=$(getent passwd "$ARM_USER" | cut -d: -f6)
    uid=$(id -u "$ARM_USER")
    gid=$(id -g "$ARM_USER")

    # Prompt for timezone and the host folders to mount, so the generated run
    # command is ready to use with no hand-editing. Defaults derive from a
    # single base dir under the user's home.
    local tz base music logs media config
    tz=$(prompt_path "Timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)")
    base=$(prompt_path "ARM data folder (mounted as /home/arm)" "$arm_home/arm")
    music=$(prompt_path "Music folder" "$base/music")
    logs=$(prompt_path "Logs folder" "$base/logs")
    media=$(prompt_path "Media folder" "$base/media")
    config=$(prompt_path "Config folder" "$base/config")

    # Pre-create the mount dirs owned by the ARM user. If they don't exist,
    # the docker daemon creates them as root:root on first run, which breaks
    # the container's write access.
    echo -e "${RED}Creating mount folders owned by '$ARM_USER'${NC}"
    mkdir -p "$base" "$music" "$logs" "$media" "$config"
    chown -R "$ARM_USER:$ARM_GROUP" "$base" "$music" "$logs" "$media" "$config"

    cd "$arm_home"
    if [ -e start_arm_container.sh ]
    then
        echo -e "'start_arm_container.sh' already exists. Backing up..."
        sudo mv ./start_arm_container.sh ./start_arm_container.sh.bak
    fi
    sudo -u "$ARM_USER" cp "$SRC_START" start_arm_container.sh
    chmod +x start_arm_container.sh
    # Fill every placeholder so the script is runnable as-is. '|' delimiter
    # avoids clashing with the '/' in paths.
    sed -i "s|IMAGE_NAME|${IMAGE}|" start_arm_container.sh
    sed -i "s|ARM_UID_PLACEHOLDER|${uid}|" start_arm_container.sh
    sed -i "s|ARM_GID_PLACEHOLDER|${gid}|" start_arm_container.sh
    sed -i "s|<timedatectl show -p Timezone --value>|${tz}|" start_arm_container.sh
    sed -i "s|<path_to_arm_user_home_folder>|${base}|" start_arm_container.sh
    sed -i "s|<path_to_music_folder>|${music}|" start_arm_container.sh
    sed -i "s|<path_to_logs_folder>|${logs}|" start_arm_container.sh
    sed -i "s|<path_to_media_folder>|${media}|" start_arm_container.sh
    sed -i "s|<path_to_config_folder>|${config}|" start_arm_container.sh
}


# start here
install_reqs
add_arm_user
launch_setup
pull_image
setup_mountpoints
save_start_command

echo -e "${RED}Installation complete. A template command to run the ARM container is located in: $(echo ~arm) ${NC}"
