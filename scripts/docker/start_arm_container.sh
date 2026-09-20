#!/bin/bash
# Template run command for the ARM container. docker-setup.sh prompts for the
# user/group, timezone and folder paths and fills every placeholder below, so
# the generated ~arm/start_arm_container.sh is runnable as-is. To run it by
# hand instead, replace the placeholder tokens yourself. Add a --device pair
# per extra optical drive.
#
# This runs WITHOUT --privileged. The minimal grants it needs instead:
#   --network host       container's udevd receives disc-insert uevents so the
#                         shipped in-container rule auto-starts a rip (a bridged
#                         container never sees these - separate net namespace).
#   --cap-add SYS_ADMIN   the mount() syscall, used to identify data/video discs.
#   --device sr0/sg0      the optical drive plus its SCSI generic node (makemkv
#                         rips via SCSI passthrough on sgN, not srN).
# Add a --device pair per extra drive (e.g. sr1/sg1). Check yours with:
#   lsscsi -g
docker run -d \
    --network host \
    -e ARM_UID="ARM_UID_PLACEHOLDER" \
    -e ARM_GID="ARM_GID_PLACEHOLDER" \
    -e TZ="<timedatectl show -p Timezone --value>" \
    -v "<path_to_arm_user_home_folder>:/home/arm" \
    -v "<path_to_music_folder>:/home/arm/music" \
    -v "<path_to_logs_folder>:/home/arm/logs" \
    -v "<path_to_media_folder>:/home/arm/media" \
    -v "<path_to_config_folder>:/etc/arm/config" \
    --device="/dev/sr0:/dev/sr0" \
    --device="/dev/sg0:/dev/sg0" \
    --cap-add SYS_ADMIN \
    --restart "always" \
    --name "arm-rippers" \
    --cpuset-cpus='2,3,4,5,6,7,8...' \
    IMAGE_NAME
