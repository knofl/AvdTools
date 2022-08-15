#!/bin/bash
CONFIGNAME="ImagePackerConfig.conf"
export RTDIR="/mnt/mounted_avd"

if file "$CONFIGNAME" | grep "No such file" > /dev/null; then
    echo "Could not find $CONFIGNAME; Yopu should run MapImage.sh first"
    exit 10
fi

OS=$( grep "$CONFIGNAME" -e "OS=" | cut -d '=' -f 2 )

if [ $UID -ne 0 ]; then
  echo "Root rights needed"
  exit 9;
fi

ANDROID_SDK_ROOT=$( grep "$CONFIGNAME" -e "ANDROID_SDK_ROOT=" | cut -d '=' -f 2 )

if [ ! -d "$ANDROID_SDK_ROOT" ]; then
  echo "ANDROID_SDK_ROOT is not valid"
  exit 4;
fi

AVD_DIR=$( grep "$CONFIGNAME" -e "AVD_DIR=" | cut -d '=' -f 2 )
IMAGE_SYSDIR=$( grep "$CONFIGNAME" -e "IMAGE_SYSDIR=" | cut -d '=' -f 2 )

########## Functions BEGIN #############

unmap_disk_img() {
  if [[ "$OS" == "Linux" ]]; then
    if losetup | grep "$(realpath "$1")" > /dev/null; then
        kpartx -d -v "$1" > /dev/null 2>&1
    fi
  elif [[ "$OS" == "Darwin" ]]; then
    # TODO
    echo "Not implemented. Please do" 
    exit 34;
  fi
}

is_mounted() {
  echo "IsMounted $1"
    if [[ "$OS" == "Linux" ]]; then
      if mountpoint -q "$1"; then
        return 0
      else
        return 1
      fi
    elif [[ "$OS" == "Darwin" ]]; then
      if mount | grep -q "$1" > /dev/null; then
        return 0
      else
        return 1
      fi
    fi
}

umount_img() {
  # $1 image path
  # $2 mount path
  echo "UnMounting $1 on $2"
  if is_mounted "$2"; then
    umount "$2"
  fi
  unmap_disk_img "$1"
}

########## Functions END #############

umount_img "${AVD_DIR}/tmp/vendor.img" "$RTDIR/vendor"
umount_img "${AVD_DIR}/tmp/product.img" "$RTDIR/product"
umount_img "${AVD_DIR}/tmp/system_ext.img" "$RTDIR/system_ext"
umount_img "${AVD_DIR}/tmp/cache.img" "$RTDIR/cache"

if grep "$CONFIGNAME" -e "SYSIMG_IS_SYSTEM=" > /dev/null; then
  umount_img "${AVD_DIR}/tmp/system.img" "$RTDIR/system"
else
  umount_img "${AVD_DIR}/tmp/system.img" "$RTDIR"
fi

unmap_disk_img "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img"

rm "$CONFIGNAME"
