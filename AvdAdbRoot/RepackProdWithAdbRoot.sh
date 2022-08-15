#!/bin/bash

#trap 'echo "# $BASH_COMMAND";read' DEBUG
source ./framework.sh

MAPPER_CONFIG="mapper.conf"
export LPTOOLS_BIN_DIR="/tmp/lpunpack_and_lpmake/bin"
export FEC_BINARY="/tmp/otatools/bin/fec"
export IMAGE_SYSDIR=""
export WORKDIR=""
export TEMPDIR=""
export RTDIR=""
export SYSIMG_IS_SYSTEM=""

TEMPDIR="$(mktemp --tmpdir -d "RepackProdWithAdbRoot.XXXX")"
RTDIR="/mnt/mounted_avd"

if [ ! -f "mapper.conf" ]; then
  USAGESTRING="Usage: ${0} <images-dir> [WORKDIR] [LPTOOLS_BIN_DIR] [FEC_BINARY]";
  if [ $# -lt 1  ]; then
    echo "$USAGESTRING";
    exit 1;
  fi

  IMAGE_SYSDIR=${1}
  WORKDIR=${2}

  if [[ -n "$3" ]]; then
    LPTOOLS_BIN_DIR="$3"
  fi
  
  if [[ -n "$4" ]]; then
    FEC_BINARY="$4"
  fi
else
  read_config "$MAPPER_CONFIG"
fi

# How much space to add to the system.img so that there is enough space to install OpenGApps
# You may need to inscrease this if you install "super" variant
export REQUIRED_SPACE_FOR_OPENGAPPS_IN_MB=3000

# for lpunpack, lpdump & lpmake


if [[ -z $WORKDIR ]]; then
  WORKDIR="./"
fi

# path to fec binary
if [ -f "$FEC_BINARY" ]; then
  export FEC_PATH="$(dirname "$FEC_BINARY")"
else
  export FEC_PATH="$FEC_BINARY"
fi

export OS="$(uname)"

if [ $UID -ne 0 ]; then
  echo "Root rights needed"
  exit 9;
fi

### FUNCTIONS' START ###

# Mount the filesystems locally & set debuggable flag with copying of debug sepolicy data
set_debuggable_and_update_policies() {
  if [ -d "$RTDIR/tmp" ]; then
    export ROOT_TMP_EXISTED="true"
  fi

  #local ANDROID_API_LEVEL=$(grep "$RTDIR/system/build.prop" -e "ro.build.version.sdk" | sed 's/[^0-9]*//g')
  #local CPU_ABI=$(grep "$RTDIR/system/build.prop" -e "ro.product.cpu.abilist" | sed 's/[^0-9]*//g')


  if [ ! -f "$RTDIR/system/etc/prop.default" ]; then
    sed -i 's/ro.debuggable=0/ro.debuggable=1/g' "$RTDIR/system/build.prop"  
    sed -i 's/persist.sys.usb.config=none/persist.sys.usb.config=adb/g' "$RTDIR/system/build.prop"
  else
    #sed -i 's/ro.debuggable=0/ro.debuggable=1/g' "$RTDIR/default.prop"
    # sed -i 's/ro.adb.secure=1/ro.adb.secure=0/g' "$RTDIR/default.prop"
    sed -i 's/ro.debuggable=0/ro.debuggable=1/g' "$RTDIR/system/etc/prop.default"
    # sed -i 's/ro.adb.secure=1/ro.adb.secure=0/g' "$RTDIR/system/etc/prop.default"
    #sed -i 's/persist.sys.usb.config=none/persist.sys.usb.config=adb/g' "$RTDIR/default.prop"
    sed -i 's/persist.sys.usb.config=none/persist.sys.usb.config=adb/g' "$RTDIR/system/etc/prop.default"
    #sed -i 's/ro.adb.secure=1/ro.adb.secure=0/g' "$RTDIR/default.prop"
    #sed -i 's/ro.adb.secure=1/ro.adb.secure=0/g' "$RTDIR/system/etc/prop.default"
    #echo tombstoned.max_tombstone_count=50 > "$RTDIR/default.prop"
    #echo tombstoned.max_tombstone_count=50 > "$RTDIR/system/etc/prop.default"
    #sed -i 's/ro.system.build.type=user/ro.system.build.type=userdebug/g' "$RTDIR/system/build.prop"
    #sed -i 's/ro.build.type=user/ro.build.type=userdebug/g' "$RTDIR/system/build.prop"
    #sed -i 's/ro.build.flavor=sdk_gphone_x86-user/ro.build.flavor=sdk_phone_x86-userdebug/g' "$RTDIR/system/build.prop"
  fi

  echo "Creating xbin dir"
  mkdir "$RTDIR/system/xbin"
  echo "Copying su to xbin dir"
  cp -r "$WORKDIR/xbin/su" "$RTDIR/system/xbin/"

  echo "Changing SEPolicies"

  cp "$WORKDIR/policies/plat_sepolicy.cil" "$RTDIR/system/etc/selinux/plat_sepolicy.cil"
  cp "$WORKDIR/policies/plat_sepolicy_and_mapping.sha256" "$RTDIR/system/etc/selinux/plat_sepolicy_and_mapping.sha256"
  cp -r "$WORKDIR/policies/mapping" "$RTDIR/system/etc/selinux/mapping" 
}

### FUNCTIONS' START ###

# Cleanup current avd instance
cleanup_avd

# Copy clean system.img to selected AVD and related stuff
unpack_images

# Resize system.img
set_new_size
echo -e "\nResizing system.img to $NEW_SIZE"
resize_img "${WORKDIR}/tmp/system.img" "$NEW_SIZE"

map_images
set_debuggable_and_update_policies
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
