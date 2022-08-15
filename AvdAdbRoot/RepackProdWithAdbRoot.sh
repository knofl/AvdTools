#!/bin/bash

#trap 'echo "# $BASH_COMMAND";read' DEBUG

# Original script was taken from https://gist.github.com/tenzap/253c8918ee488c3874f20a563f458510
# Huge Thanks to tenzap

# Tested only on 30 API level with x86 arch

USERNAME=${1}
WORKDIR=${2}
USAGESTRING="Usage: ${0} <user> [WORKDIR] [LPTOOLS_BIN_DIR] [FEC_BINARY]";
TEMPDIR="$(mktemp --tmpdir -d "RepackProdWithAdbRoot.XXXX")"
export RTDIR="/mnt/mounted_avd"

# How much space to add to the system.img so that there is enough space to install OpenGApps
# You may need to inscrease this if you install "super" variant
REQUIRED_SPACE_FOR_OPENGAPPS_IN_MB=3000

# for lpunpack, lpdump & lpmake
LPTOOLS_BIN_DIR="/tmp/lpunpack_and_lpmake/bin"
if [[ -n "$3" ]]; then
  LPTOOLS_BIN_DIR="$3"
fi

echo "lptoolsdir: $LPTOOLS_BIN_DIR"

if [[ -z $WORKDIR ]]; then
  WORKDIR="./"
fi

# path to fec binary
FEC_BINARY="/tmp/otatools/bin/fec"
if [[ -n $4 ]]; then
  FEC_BINARY="$4"
fi

echo "fecBinary: $FEC_BINARY"

if [ -f "$FEC_BINARY" ]; then
  FEC_PATH="$(dirname "$FEC_BINARY")"
else
  FEC_PATH="$FEC_BINARY"
fi

OS="$(uname)"

if [ $UID -ne 0 ]; then
  echo "Root rights needed"
  exit 9;
fi

if [ $# -lt 1  ]; then
  echo "$USAGESTRING";
  exit 1;
fi

USER_HOME="$(sudo -u "$USERNAME" sh -c 'echo $HOME')"

if [ ! "$ANDROID_SDK_ROOT" ]; then
  if [ -d "$USER_HOME/Android/Sdk" ]; then
    echo "ANDROID_SDK_ROOT is not set, using default value: $USER_HOME/Android/Sdk"
    ANDROID_SDK_ROOT="$USER_HOME/Android/Sdk"
  else
    echo "ANDROID_SDK_ROOT is not set"
    exit 3;
  fi
fi

if [ ! -d "$ANDROID_SDK_ROOT" ]; then
  echo "ANDROID_SDK_ROOT is not valid"
  exit 4;
fi

a="/$0"; a=${a%/*}; a=${a#/}; a=${a:-.}; SCRIPT_DIR="$(cd "$a"; pwd -P)" || exit 1

########## Functions BEGIN #############

map_disk_img() {
    if [ ! -v 2 ]; then
      line=1 # We want the 1st line
    else
      line=$2
    fi
    if [[ "$OS" == "Linux" ]]; then
        if ! which kpartx > /dev/null; then
        echo "kpartx command missing, cannot continue";
        exit 11;
        fi
        DEVICE="/dev/mapper/$(kpartx -a -v "$1" | cut -f 3 -d ' ' | sed "$line"'!'"d" )"
    elif [[ "$OS" == "Darwin" ]]; then
        # TODO
        echo "Not implemented/tested. Please do."
        exit 35
        DEVICE=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | grep "Linux Filesystem"  | head -1 | cut -f 1 -d ' ')
    fi
    echo $DEVICE
}

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

mount_img() {
  # $1 image path
  # $2 mount path

  echo "Mounting $1 on $2"

  local DEVICE

  if file -b "$1" | grep "DOS/MBR boot sector" > /dev/null; then
    map_disk_img "$1"
    if is_mounted "$2"; then
        mount -o remount "$DEVICE" "$2"
    else
        mount "$DEVICE" "$2"
    fi
  elif file -b "$1" | grep "ext. filesystem data" > /dev/null; then
    if is_mounted "$2"; then
      mount -o remount "$1" "$2"
    else
      mount "$1" "$2"
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

# Mount the filesystems locally & set debuggable flag with copying of debug sepolicy data
set_debuggable_and_update_policies() {
  echo -e "\nMouting the images..."
  # Mount the images
  mkdir -p "$RTDIR"

  mount_img "$AVD_DIR/tmp/system.img" "$RTDIR"
  if [ ! -d "$RTDIR/system" ]; then
    SYSIMG_IS_SYSTEM="true"
    # On API27, system.img has the content of /system
    umount_img "$AVD_DIR/tmp/system.img" "$RTDIR"
    mkdir -p "$RTDIR/"{system,cache,vendor,proc,dev}
    mount_img "$AVD_DIR/tmp/system.img" "$RTDIR/system"
  fi
  mount_img "$AVD_DIR/tmp/vendor.img" "$RTDIR/vendor"
  if [ -e "$AVD_DIR/tmp/lpdump.json" ]; then
    if [ $(jq ".partitions | length" "$AVD_DIR/tmp/lpdump.json") -eq 4 ]; then
      mount_img "$AVD_DIR/tmp/system_ext.img" "$RTDIR/system_ext"
      mount_img "$AVD_DIR/tmp/product.img" "$RTDIR/product"
    fi
  fi

  mount_img "$AVD_DIR/cache.img" "$RTDIR/cache"
  
  if [ -d "$RTDIR/tmp" ]; then
    ROOT_TMP_EXISTED="true"
  fi

  local ANDROID_API_LEVEL=$(grep "$RTDIR/system/build.prop" -e "ro.build.version.sdk" | sed 's/[^0-9]*//g')
  local CPU_ABI=$(grep "$RTDIR/system/build.prop" -e "ro.product.cpu.abilist" | sed 's/[^0-9]*//g')


  if file "$RTDIR/system/etc/prop.default" | grep "No such file" > /dev/null; then
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

  # Unmount the images & cleanup
  echo -e "\nUnmouting the images..."
  if [ ! "a$ROOT_TMP_EXISTED" = "atrue" ]; then rmdir "$RTDIR/tmp" ; fi
  umount_img "$AVD_DIR/cache.img" "$RTDIR/cache"
  umount_img "$AVD_DIR/tmp/vendor.img" "$RTDIR/vendor"
  if [ -e "$AVD_DIR/tmp/lpdump.json" ]; then
    if [ $(jq ".partitions | length" "$AVD_DIR/tmp/lpdump.json") -eq 4 ]; then
      umount_img "$AVD_DIR/tmp/system_ext.img" "$RTDIR/system_ext"
      umount_img "$AVD_DIR/tmp/product.img" "$RTDIR/product"
    fi
  fi

  umount "$RTDIR/proc"
  umount "$RTDIR/dev"
  if [[ "a$SYSIMG_IS_SYSTEM" == "atrue" ]]; then    
    umount_img "$AVD_DIR/tmp/system.img" "$RTDIR/system"
    rmdir "$RTDIR/"{system,cache,vendor,proc,dev,tmp}
  else
    umount_img "$AVD_DIR/tmp/system.img" "$RTDIR"
  fi
}

upsize_extfs() {
  # $1 device path to the filesystem to upsize
  # $2 size

  "${ANDROID_SDK_ROOT}/emulator/bin64/e2fsck" -f "$1" 2> /dev/null
  if [ -z "$2" ]; then
    "${ANDROID_SDK_ROOT}/emulator/bin64/resize2fs" "$1" 2> /dev/null
  else
    "${ANDROID_SDK_ROOT}/emulator/bin64/resize2fs" "$1" "$2" 2> /dev/null
  fi
}

downsize_extfs() {
  # $1 device/file holding the filesystem
  "${ANDROID_SDK_ROOT}/emulator/bin64/e2fsck" -f "$1" 2> /dev/null
  "${ANDROID_SDK_ROOT}/emulator/bin64/resize2fs" -M "$1"
}

downsize_img() {
  local image="$1"
  echo -e "\n Downsizing image $1"

  if file -b "$image" | grep "DOS/MBR boot sector" > /dev/null; then
    # The system.img is not ext2/ext4 but a DOS/MBR boot sector (actually GPT) which contains an ext2/3/4 fs
    map_disk_img "$image"
    downsize_extfs "$DEVICE"
    BS=$(dumpe2fs -h "$DEVICE" 2> /dev/null | sed -n -e "s/Block size:\s*\(\d*\)/\1/p")
    BC=$(dumpe2fs -h "$DEVICE" 2> /dev/null | sed -n -e "s/Block count:\s*\(\d*\)/\1/p")
    unmap_disk_img "$image"

    SECTOR_SIZE=$(sgdisk -p "$image" | grep "Sector size (logical):" | cut -d " " -f 4)
    PART_NAME=$(sgdisk -i1 "$image" | sed -n -e "s/Partition name:\s*'\(.*\)'.*/\1/p")
    PART_OFFSET_SECTORS=$(sgdisk -i1 "$image" | grep "First sector" | cut -d " " -f 3)
    PART_SIZE_B=$(( BS * BC ))
    PART_END_B=$(( PART_OFFSET_SECTORS * SECTOR_SIZE + PART_SIZE_B ))
    GPT_FOOTER_SIZE_B=$((33 * SECTOR_SIZE))
    DISK_SIZE_B=$(( PART_END_B + GPT_FOOTER_SIZE_B ))

    truncate -s $DISK_SIZE_B "$image"
    sgdisk -Z "$image" > /dev/null 2>&1
    sgdisk -n 1:$PART_OFFSET_SECTORS:+$(( PART_SIZE_B / SECTOR_SIZE )) "$image" > /dev/null 2>&1
    sgdisk -c 1:"$PART_NAME" "$image" > /dev/null 2>&1
    sgdisk -t 1:8300 "$image" > /dev/null 2>&1
  elif file -b "$image" | grep "ext. filesystem data" > /dev/null; then
    downsize_extfs "${AVD_DIR}/tmp/$file"
  fi
}

resize_img() {
  local image="$1"
  local size="$2"
  if file -b "$image" | grep "DOS/MBR boot sector" > /dev/null; then
    # The system.img is not ext2/ext4 but a DOS/MBR boot sector (actually GPT) which contains an ext2/3/4 fs
    echo -e "\nResizing sysem partition to $size... (you can safely ignore the warning 'The kernel is still using the old partition table.')"
    fallocate -l "$size" "$image"
    PART_UUID=$(sgdisk -i 1 "$image" | grep "unique GUID" | cut -d ' ' -f4)
    sgdisk -d 1 "$image"
    sgdisk -n 1:0:0 "$image"
    sgdisk -c 1:system "$image"
    sgdisk -u 1:$PART_UUID "$image"
    map_disk_img "$image"
    SYS_EXT_PART_PATH="$DEVICE"
    upsize_extfs "$SYS_EXT_PART_PATH" ;
    unmap_disk_img "$image"
    echo "Resizing sysem partition to $size finished successfully!"
  elif file -b "$image" | grep "ext. filesystem data" > /dev/null; then
    upsize_extfs "$image" "$size"
  else
    echo "$image format not supported by this script"
    exit 10;
  fi
}

unpack_images() {
  echo -e "\nUnpack original partition images for ${AVD}"
  mkdir -p "$AVD_DIR/tmp"
  if [ $(kpartx "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" | wc -l) -gt 1 ]; then
    lptools_required
    # API 29 image (android Q) holding a super.img
    map_disk_img "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" 2

    echo $DEVICE
    "$LPTOOLS_BIN_DIR/lpdump" -j "$DEVICE" > "$AVD_DIR/tmp/lpdump.json"
    echo $("cat $AVD_DIR/tmp/lpdump.json")
    "$LPTOOLS_BIN_DIR/lpdump" "$DEVICE" > "$AVD_DIR/tmp/lpdump.txt"

    download_and_extract_aosp_scripts

    dd if="${DEVICE::-1}1" of="${AVD_DIR}/tmp/vbmeta.orig.img"
    "$TEMPDIR/avbtool.py" info_image   --image "${AVD_DIR}/tmp/vbmeta.orig.img" > "${AVD_DIR}/tmp/vbmeta.orig.img.info_image.txt"

    for partition in $(jq -r ".partitions[].name" "$AVD_DIR/tmp/lpdump.json"); do
        echo -e "\nUnpacking & converting to read/write: $partition.img"

        local PART_SIZE
        PART_SIZE=$(jq -r '.partitions[] | select(.name=="'$partition'").size ' "$AVD_DIR/tmp/lpdump.json")
        check_free_space "${AVD_DIR}/tmp" $(( PART_SIZE * 11 / 10 ))

        "$LPTOOLS_BIN_DIR/lpunpack" --slot=0 -p $partition "$DEVICE" "$AVD_DIR/tmp"
        "$TEMPDIR/avbtool.py" info_image   --image "$AVD_DIR/tmp/$partition.img" > "$AVD_DIR/tmp/$partition.img.info_image.txt"
        # Filesystems have the feature: EXT4_FEATURE_RO_COMPAT_SHARED_BLOCKS
        # We need to remove it to mount rw,
        # and at least resize the partition a bit if there is not enough space
        FS_SIZE=$(wc -c "$AVD_DIR/tmp/$partition.img" | cut -f 1 -d ' ')
        e2fsck -f -y "$AVD_DIR/tmp/$partition.img"
        # Increase size by 10% to be able to unshare_blocks
        resize2fs "$AVD_DIR/tmp/$partition.img" $(( FS_SIZE * 11 / 10 / 1024 ))K
        e2fsck -y -E unshare_blocks "$AVD_DIR/tmp/$partition.img" > /dev/null 2>&1
        e2fsck -f -y "$AVD_DIR/tmp/$partition.img"
    done
  else
    check_free_space "${AVD_DIR}/tmp" $(wc -c "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/vendor.img" | cut -f 1 -d ' ')
    cp "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/vendor.img" "${AVD_DIR}/tmp/vendor.img"
    check_free_space "${AVD_DIR}/tmp" $(wc -c "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" | cut -f 1 -d ' ')
    cp "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" "${AVD_DIR}/tmp/system.img"
  fi
  if [ -f "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/encryptionkey.img" ]; then
    if [ ! -f "${AVD_DIR}/encryptionkey.img" ]; then
      echo "copying encryptionkey.img ..."
      cp "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/encryptionkey.img" "${AVD_DIR}/encryptionkey.img"
    fi
  fi
}

set_new_size() {
  local USED_IN_KB NEW_SIZE_IN_B CUR_SIZE_IN_B

  mount_img "$AVD_DIR/tmp/system.img" "$RTDIR"
  USED_IN_KB=$(df --output=used "$RTDIR" | tail -1)
  umount_img "$AVD_DIR/tmp/system.img" "$RTDIR"

  NEW_SIZE_IN_B="$(( ( USED_IN_KB + REQUIRED_SPACE_FOR_OPENGAPPS_IN_MB * 1024 ) * 1024 ))"
  CUR_SIZE_IN_B=$(wc -c "${AVD_DIR}/tmp/system.img" | cut -f 1 -d ' ')

  if [ $CUR_SIZE_IN_B -ge $NEW_SIZE_IN_B ]; then
    NEW_SIZE="$((CUR_SIZE_IN_B / 1024 / 1024 + 1))M"
  else
    NEW_SIZE="$((NEW_SIZE_IN_B / 1024 / 1024 + 1))M"
  fi
}

cleanup_avd() {
  rm -f "${AVD_DIR}/vendor.img"
  rm -f "${AVD_DIR}/system.img"
  rm -f "${AVD_DIR}/cache.img"
  rm -f "${AVD_DIR}/cache.img.qcow2"
  rm -f "${AVD_DIR}/userdata-qemu.img"
  rm -f "${AVD_DIR}/userdata-qemu.img.qcow2"
  rm -fr "${AVD_DIR}/snapshots/default_boot/"
}

disable_verified_boot_pre_q() {
  # On Android Pie, we disable it since we modify the system.img file. Otherwise the emulator will not boot.
  if [ -f "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/VerifiedBootParams.textproto" ] \
    && grep "^dm_param" "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/VerifiedBootParams.textproto" > /dev/null ; then
    # If the file exists, maybe the emulator has Verity/Verified boot enabled.
    if [ ! -f "${AVD_DIR}/VerifiedBootParams.textproto" ]; then
      echo "copying VerifiedBootParams.textproto..."
      cp "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/VerifiedBootParams.textproto" "${AVD_DIR}/VerifiedBootParams.textproto"
    fi
    echo "Disabling verity/verified-boot..."
    sed -i -e "s/^dm_param/#dm_param/" "${AVD_DIR}/VerifiedBootParams.textproto"
  fi
}

lptools_required() {
  if [ ! -e $LPTOOLS_BIN_DIR/lpmake ] || [ ! -e $LPTOOLS_BIN_DIR/lpmake ] || [ ! -e $LPTOOLS_BIN_DIR/lpmake ]; then
    echo "lpmake, lpdump and lpunpack are missing. Get them and check LPTOOLS_BIN_DIR in the script "
    echo "Packaged sources (including the minimal android sources to build): https://github.com/LonelyFool/lpunpack_and_lpmake"
    echo "Upstream sources (needs all android sources): https://android.googlesource.com/platform/system/extras/+/refs/heads/master/partition_tools/"
    exit 8
  fi
}

download_and_extract_aosp_scripts() {
  wget -nc https://android.googlesource.com/platform/external/avb/+archive/master.tar.gz -O "$TEMPDIR/avbtool.tar.gz"
  tar -xvf "$TEMPDIR/avbtool.tar.gz" -C "$TEMPDIR" \
    avbtool.py \
    test/data/testkey_rsa2048.pem \
    test/data/testkey_rsa4096.pem
  chmod +x "$TEMPDIR/avbtool.py"
  mv "$TEMPDIR/test/data/testkey_rsa2048.pem" "$TEMPDIR/"
  mv "$TEMPDIR/test/data/testkey_rsa4096.pem" "$TEMPDIR/"
  rmdir "$TEMPDIR/test/data"
  rmdir "$TEMPDIR/test"

  # https://cs.android.com/android/platform/superproject/+/master:device/generic/goldfish/tools/mk_vbmeta_boot_params.sh
  # https://cs.android.com/android/platform/superproject/+/master:device/generic/goldfish/tools/mk_combined_img.py
  wget -nc https://android.googlesource.com/device/generic/goldfish/+archive/refs/heads/master/tools.tar.gz -O "$TEMPDIR/goldfish_tools.tar.gz"
  tar -xvf "$TEMPDIR/goldfish_tools.tar.gz" -C "$TEMPDIR" \
    mk_vbmeta_boot_params.sh \
    mk_combined_img.py
  chmod +x "$TEMPDIR/mk_vbmeta_boot_params.sh"
  chmod +x "$TEMPDIR/mk_combined_img.py"
}

repack_images() {

  # No need to repack if this is not a combined_img (appeard in android Q)
  if [ $(kpartx "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" | wc -l) -le 1 ]; then return 0; fi

  # Build the dynamic partiton system.img and the avb/verity/verified-boot related files/hases for android Q+ (10+)

  lptools_required

  if [ ! -e $FEC_BINARY ]; then
    echo "fec binary missing. Get them and check FEC_BINARY in the script "
    echo "prebuild binary can be found in the otatools here: https://forum.xda-developers.com/t/guide-ota-tools-lpunpack.4041843/"
    exit 8
  fi

  # Doc for verified boot:
  # https://android.googlesource.com/platform/external/avb/+/master/README.md

  # Download & extract some required scripts & files from anroid sources:
  download_and_extract_aosp_scripts

  # Add Hashtree footer to the images
  # We need the binary of "fec"
  # Sources: here http://www.ka9q.net/code/fec/ or there https://android.googlesource.com/platform/external/fec/+/master/)
  # Binary in otatools

  for partition in $(jq -r ".partitions[].name" "$AVD_DIR/tmp/lpdump.json"); do
    unset PROP_ARGS
    declare -a PROP_ARGS=()
    for line in $(grep "Prop:" "${AVD_DIR}/tmp/$partition.img.info_image.txt" | sed -e 's/.*Prop: \(.*\) -> \(.*\)/\1:\2/' -e "s/'//g"); do
      PROP_ARGS+=(--prop "$line")
    done

    if [ ! $partition = "system" ]; then
        #$TEMPDIR/avbtool.py erase_footer --image "${AVD_DIR}/tmp/$partition.img"
        PATH=$PATH:$FEC_PATH "$TEMPDIR/avbtool.py" add_hashtree_footer \
            --partition_name $partition \
            --partition_size 0 \
            --image "${AVD_DIR}/tmp/$partition.img" \
            "${PROP_ARGS[@]}"

        "$TEMPDIR/avbtool.py" info_image   --image "${AVD_DIR}/tmp/$partition.img"
        "$TEMPDIR/avbtool.py" verify_image --image "${AVD_DIR}/tmp/$partition.img"
    fi
  done


  unset PROP_ARGS
  declare -a PROP_ARGS=()
  for line in $(grep "Prop:" "${AVD_DIR}/tmp/$partition.img.info_image.txt" | sed -e 's/.*Prop: \(.*\) -> \(.*\)/\1:\2/' -e "s/'//g"); do
    PROP_ARGS+=(--prop "$line")
  done
  #"$TEMPDIR/avbtool.py" erase_footer --image "${AVD_DIR}/tmp/system.img"
  # We skip the rollback index value (--rollback-index)
  PATH=$PATH:$FEC_PATH "$TEMPDIR/avbtool.py" add_hashtree_footer \
    --partition_name system \
    --partition_size 0 \
    --image "${AVD_DIR}/tmp/system.img" \
    --algorithm SHA256_RSA2048 \
    --key "$TEMPDIR/testkey_rsa2048.pem" \
    "${PROP_ARGS[@]}"

  "$TEMPDIR/avbtool.py" info_image   --image "${AVD_DIR}/tmp/system.img"
  "$TEMPDIR/avbtool.py" verify_image --image "${AVD_DIR}/tmp/system.img" --key "$TEMPDIR/testkey_rsa2048.pem"

  "$TEMPDIR/avbtool.py" extract_public_key --key "$TEMPDIR/testkey_rsa2048.pem" --output "$TEMPDIR/system_rsa2048.avbpubkey"

  # TODO - get the vendor_boot.img and combine it into vbmeta.img
  # But it seems to work fine without this (at least until API31)
  #
  # The vendor_boot.img is added into ramdisk.img of the emulator image
  # by this scripts probably:
  # https://cs.android.com/android/platform/superproject/+/master:device/generic/goldfish/tools/mk_qemu_ramdisk.py
  #
  # I don't know how to extract it from ramdisk.img to use it in `avbtool make_vbmeta_image`

# Create vbmeta image with dm-verity disabled
# https://wiki.postmarketos.org/wiki/Android_Verified_Boot_(AVB)
#   "$TEMPDIR/avbtool.py" make_vbmeta_image \
#     --flags 2 \
#     --padding_size 4096 \
#     --output ${AVD_DIR}/tmp/vbmeta_disabled.img \
#     --chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey

  declare -a AVBTOOL_ADDITIONAL_ARGS=()
  for partition in $(jq -r ".partitions[].name" "$AVD_DIR/tmp/lpdump.json"); do
    if [ ! "$partition" = "system" ]; then
      AVBTOOL_ADDITIONAL_ARGS+=(--include_descriptors_from_image "${AVD_DIR}/tmp/$partition.img")
    fi
  done

  REPLICATE_LPDUMP=0

  # Remove old vbmeta.img, then create vbmeta image
  rm -f "${AVD_DIR}/tmp/vbmeta.img"
  "$TEMPDIR/avbtool.py" make_vbmeta_image \
    --algorithm SHA256_RSA4096 \
    --key "$TEMPDIR/testkey_rsa4096.pem" \
    --padding_size 4096 \
    --output "${AVD_DIR}/tmp/vbmeta.img" \
    --chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey \
    "${AVBTOOL_ADDITIONAL_ARGS[@]}"
    #--include_descriptors_from_image "${AVD_DIR}/tmp/vendor.img"

  "$TEMPDIR/avbtool.py" info_image   --image "${AVD_DIR}/tmp/vbmeta.img"
  "$TEMPDIR/avbtool.py" verify_image --image "${AVD_DIR}/tmp/vbmeta.img" \
    --expected_chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey \
    --key "$TEMPDIR/testkey_rsa4096.pem"

  if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
    cp "${AVD_DIR}/tmp/vbmeta.orig.img" "${AVD_DIR}/tmp/vbmeta.img"
  fi

  "$TEMPDIR/avbtool.py" info_image   --image "${AVD_DIR}/tmp/vbmeta.img" | tee "${AVD_DIR}/tmp/vbmeta.img.info_image.txt"

  # Create VerifiedBootParams.textproto
  AVBTOOL="$(realpath "$TEMPDIR/avbtool.py")" "$TEMPDIR/mk_vbmeta_boot_params.sh" \
    "${AVD_DIR}/tmp/vbmeta.img" \
    "${AVD_DIR}/tmp/system.img" \
    "${AVD_DIR}/tmp/VerifiedBootParams.textproto"
  mv "${AVD_DIR}/tmp/VerifiedBootParams.textproto" "${AVD_DIR}/VerifiedBootParams.textproto"

  # Prepare variables to repack super.img with lpmake
  LPMAKE_SUPER_NAME=$(jq -r '.block_devices[0].name' "$AVD_DIR/tmp/lpdump.json")
  LPMAKE_ALIGNMENT=$(jq -r '.block_devices[0].alignment' "$AVD_DIR/tmp/lpdump.json")
  LPMAKE_BLOCK_SIZE=$(jq -r '.block_devices[0].block_size' "$AVD_DIR/tmp/lpdump.json")
  LPMAKE_GROUP_NAME=$(jq -r '.partitions[0].group_name' "$AVD_DIR/tmp/lpdump.json")
  LPMAKE_METADATA_SIZE=$(cat "$AVD_DIR/tmp/lpdump.txt" | grep "Metadata max size:" | cut -d ' ' -f 4)
  LPMAKE_METADATA_SLOTS=$(cat "$AVD_DIR/tmp/lpdump.txt" | grep "Metadata slot count:" | cut -d ' ' -f 4)

  declare -a LPMAKE_PARTITION_ARGS=()
  for partition in $(jq -r ".partitions[].name" "$AVD_DIR/tmp/lpdump.json"); do
    if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
      PART_SIZE=$(jq -r '.partitions[] | select(.name=="'$partition'").size ' "$AVD_DIR/tmp/lpdump.json")
    else
      PART_SIZE=$(wc -c "${AVD_DIR}/tmp/$partition.img" | cut -f 1 -d ' ')
    fi
    PART_SIZE_SUM=$(( PART_SIZE_SUM + PART_SIZE ))
    LPMAKE_PARTITION_ARGS+=(-p $partition:readonly:$PART_SIZE:$LPMAKE_GROUP_NAME)
    LPMAKE_PARTITION_ARGS+=(-i $partition="${AVD_DIR}/tmp/$partition.img")
  done

  if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
    LPMAKE_GROUP_MAX_SIZE=$(jq -r '.groups[] | select(.name=="'$LPMAKE_GROUP_NAME'").maximum_size' "$AVD_DIR/tmp/lpdump.json")
    LPMAKE_DEVICE_SIZE=$(jq -r '.block_devices[0].size' "$AVD_DIR/tmp/lpdump.json")
  else
    # LPMAKE_GROUP_MAX_SIZE: round size to multiple of 1024*1024 (size of all partitions + 4MiB)
    LPMAKE_GROUP_MAX_SIZE=$(( ( ( PART_SIZE_SUM / 1024 / 1024 ) + 4 ) * 1024 * 1024))
    # LPMAKE_DEVICE_SIZE = LPMAKE_GROUP_MAX_SIZE + 8MiB
    LPMAKE_DEVICE_SIZE=$(( LPMAKE_GROUP_MAX_SIZE + ( 8 * 1024 * 1024 ) ))
    #LPMAKE_DEVICE_SIZE=$(( $(jq -r '.block_devices[0].size' "$AVD_DIR/tmp/lpdump.json") + (100 * 1024 * 1024) ))
  fi

  # Repack the super.img
  check_free_space "${AVD_DIR}/tmp" $LPMAKE_DEVICE_SIZE
  "$LPTOOLS_BIN_DIR/lpmake" \
    --device-size=$LPMAKE_DEVICE_SIZE \
    --metadata-size=$LPMAKE_METADATA_SIZE \
    --metadata-slots=$LPMAKE_METADATA_SLOTS \
    --output="${AVD_DIR}/tmp/super.img" \
    "${LPMAKE_PARTITION_ARGS[@]}" \
    --block-size=$LPMAKE_BLOCK_SIZE \
    --alignment=$LPMAKE_ALIGNMENT \
    --super-name="$LPMAKE_SUPER_NAME" \
    --group=$LPMAKE_GROUP_NAME:$LPMAKE_GROUP_MAX_SIZE

  # Delete partition images (we now have super.img)
  for partition in $(jq -r ".partitions[].name" "$AVD_DIR/tmp/lpdump.json"); do
    rm "${AVD_DIR}/tmp/$partition.img"*
  done

  # Prepare image_config file to build the combined img that will be used as system.img for the emulator
  echo "${AVD_DIR}/tmp/vbmeta.img vbmeta 1" > "${AVD_DIR}/tmp/image_config"
  echo "${AVD_DIR}/tmp/super.img super 2" >> "${AVD_DIR}/tmp/image_config"

  # Fix incorrect arguments when calling sgdisk (replace --type= by --typecode= )
  sed -i -e "s/--type=/--typecode=/" "$TEMPDIR/mk_combined_img.py"

  # Remove previous image (because the mk_combined_img.py behaves differently if the file already exists)
  # Then, create the combined image
  rm -f "${AVD_DIR}/tmp/combined.img"
  check_free_space "${AVD_DIR}/tmp" $(( $(wc -c "${AVD_DIR}/tmp/super.img" | cut -f 1 -d ' ') + 5 * 1024 * 1024 ))
  "$TEMPDIR/mk_combined_img.py" -i "${AVD_DIR}/tmp/image_config" -o "${AVD_DIR}/tmp/combined.img"

  # Cleanup
  rm "${AVD_DIR}/tmp/image_config"
  rm "${AVD_DIR}/tmp/vbmeta.img"*
  rm "${AVD_DIR}/tmp/vbmeta.orig.img"*
  rm "${AVD_DIR}/tmp/super.img"
  rm "${AVD_DIR}/tmp/lpdump.json"
  rm "${AVD_DIR}/tmp/lpdump.txt"


  # Some variables set in Android Makefile
  #BOARD_AVB_ENABLE := true
  #BOARD_AVB_ALGORITHM := SHA256_RSA4096
  #BOARD_AVB_KEY_PATH := external/avb/test/data/$TEMPDIR/testkey_rsa4096.pem
  # Enable chain partition for system. https://cs.android.com/android/platform/superproject/+/master:build/make/target/board/BoardConfigEmuCommon.mk;l=82?q=BOARD_AVB_SYSTEM_KEY_PATH&ss=android%2Fplatform%2Fsuperproject
  #BOARD_AVB_SYSTEM_KEY_PATH := external/avb/test/data/$TEMPDIR/testkey_rsa2048.pem
  #BOARD_AVB_SYSTEM_ALGORITHM := SHA256_RSA2048
  #BOARD_AVB_SYSTEM_ROLLBACK_INDEX := $(PLATFORM_SECURITY_PATCH_TIMESTAMP)
  #BOARD_AVB_SYSTEM_ROLLBACK_INDEX_LOCATION := 1
  #BOARD_SUPER_PARTITION_SIZE := 3229614080

}

check_free_space() {
  # $1: file or device
  # $2: required space (in bytes)

  local MOUNT_POINT
  MOUNT_POINT=$(stat -c %m -- "$1")
  AVAIL=$(( $(df --output=avail "$MOUNT_POINT" | tail -1) * 1024 ))
  if [ $AVAIL -le $(( $2 + 5 * 1024 * 1024 ))  ]; then
    echo "Not enough space on disk. Need: $2. Available: $AVAIL. Exiting"
    exit 15
  fi
}

########## Functions END #############

echo "Which AVD?"
sudo -u "$USERNAME" "${ANDROID_SDK_ROOT}/emulator/emulator" -list-avds
echo -en "\n>"
read -r AVD

AVD_DIR=$(grep "path=" "${USER_HOME}/.android/avd/${AVD}.ini" | cut -f2 -d"=")
AVD_DIR=${AVD_DIR// } # trim

echo -en "\ndetermining location of system.img file for ${AVD} ... "
IMAGE_SYSDIR=$(grep "image.sysdir.1" "${AVD_DIR}/config.ini" | cut -f2 -d"=")
IMAGE_SYSDIR=${IMAGE_SYSDIR// } # trim
echo "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}"

# Cleanup current avd instance
cleanup_avd

# Copy clean system.img to selected AVD and related stuff
unpack_images

# Resize system.img
set_new_size
echo -e "\nResizing system.img to $NEW_SIZE"
resize_img "${AVD_DIR}/tmp/system.img" "$NEW_SIZE"

# Install with the OpenGApps installer in a chroot environment
set_debuggable_and_update_policies

# Downsize images if extfs format
for file in system.img product.img vendor.img system_ext.img; do
  if [ -e "${AVD_DIR}/tmp/$file" ]; then
    downsize_img "${AVD_DIR}/tmp/$file"
  fi
done

# Repack images
repack_images

# Disable verfied boot (for version before Android-Q)
disable_verified_boot_pre_q

# Resize data partition
sed -i -e "s/disk.dataPartition.size.*/disk.dataPartition.size=1536M/" "${AVD_DIR}/config.ini"

# Install the built images into the avd
if [ $(kpartx "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img" | wc -l) -le 1 ]; then
  mv "${AVD_DIR}/tmp/system.img" "${AVD_DIR}"
  mv "${AVD_DIR}/tmp/vendor.img" "${AVD_DIR}"
else
  # Move combined.img to system.img for use by the emulator
  mv "${AVD_DIR}/tmp/combined.img" "${AVD_DIR}/system.img"
fi

unmap_disk_img "${ANDROID_SDK_ROOT}/${IMAGE_SYSDIR}/system.img"

rm -r "$TEMPDIR"
rmdir "${AVD_DIR}/tmp"
