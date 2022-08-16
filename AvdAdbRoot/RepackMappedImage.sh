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

if [ -f "$FEC_BINARY" ]; then
  export FEC_PATH="$(dirname "$FEC_BINARY")"
else
  export FEC_PATH="$FEC_BINARY"
fi

unmap_images

# Downsize images if extfs format
for file in system.img product.img vendor.img system_ext.img; do
  if [ -e "${WORKDIR}/tmp/$file" ]; then
    downsize_img "${WORKDIR}/tmp/$file"
  fi
done

# Repack images
repack_images

# Disable verfied boot (for version before Android-Q)
disable_verified_boot_pre_q

# Resize data partition
#sed -i -e "s/disk.dataPartition.size.*/disk.dataPartition.size=1536M/" "${WORKDIR}/config.ini"

# Install the built images into the avd
if [ $(kpartx "${IMAGE_SYSDIR}/system.img" | wc -l) -le 1 ]; then
  mv "${WORKDIR}/tmp/system.img" "${WORKDIR}"
  mv "${WORKDIR}/tmp/vendor.img" "${WORKDIR}"
else
  # Move combined.img to system.img for use by the emulator
  mv "${WORKDIR}/tmp/combined.img" "${WORKDIR}/system.img"
fi

unmap_disk_img "${IMAGE_SYSDIR}/system.img"

rm -r "$TEMPDIR"
rmdir "${WORKDIR}/tmp"

rm "$CONFIGNAME"
