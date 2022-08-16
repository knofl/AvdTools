#!/bin/bash
source ./framework.sh

MAPPER_CONFIG="mapper.conf"
CONFIGNAME="ImagePackerConfig.conf"
export RTDIR="/mnt/mounted_avd"

if [ ! -f "$CONFIGNAME" ]; then
    echo "Could not find $CONFIGNAME; You should run MapImage.sh first"
    exit 10
fi

export OS=$( grep "$CONFIGNAME" -e "OS=" | cut -d '=' -f 2 )
export TEMPDIR=$( grep "$CONFIGNAME" -e "TEMPDIR=" | cut -d '=' -f 2 )
export SYSIMG_IS_SYSTEM=$( grep "$CONFIGNAME" -e "SYSIMG_IS_SYSTEM=" | cut -d '=' -f 2 )

if [ $UID -ne 0 ]; then
  echo "Root rights needed"
  exit 9;
fi

if [ ! -f "$MAPPER_CONFIG" ]; then
    read_config "$CONFIGNAME"
else 
    read_config "$MAPPER_CONFIG"
fi

unmap_images

if grep "$CONFIGNAME" -e "SYSIMG_IS_SYSTEM=" > /dev/null; then
  umount_img "${WORKDIR}/tmp/system.img" "$RTDIR/system"
else
  umount_img "${WORKDIR}/tmp/system.img" "$RTDIR"
fi

unmap_disk_img "${IMAGE_SYSDIR}/system.img"

rm "$CONFIGNAME"
