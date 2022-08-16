#!/bin/bash
read_config() {
    # $1 - config path
    if [ -f "$1" ]; then
        export ANDROID_SDK_ROOT=$( grep "$1" -e "ANDROID_SDK_ROOT=" | cut -d '=' -f 2 )
        export WORKDIR=$( grep "$1" -e "WORKDIR=" | cut -d '=' -f 2 )
        export IMAGE_SYSDIR=$( grep "$1" -e "IMAGE_SYSDIR=" | cut -d '=' -f 2 )
        export LPTOOLS_BIN_DIR=$( grep "$1" -e "LPTOOLS_BIN_DIR=" | cut -d '=' -f 2 )
        export FEC_BINARY=$( grep "$1" -e "FEC_BINARY=" | cut -d '=' -f 2 )
        
        if [ ! -d "$IMAGE_SYSDIR" ]; then
            echo "images-dir is not valid"
            exit 4;
        fi

        if [ ! -d "$WORKDIR" ]; then
            echo "WORKDIR is not valid"
            exit 4
        fi

        if [ ! -d "$LPTOOLS_BIN_DIR" ]; then
            echo "LPTOOLS_BIN_DIR is not valid"
            exit 4
        fi

        if [ ! -f "$FEC_BINARY" ] && [ ! -d "$FEC_BINARY" ]; then
            echo "FEC_BINARY is not valid"
            exit 4
        fi

        if [ ! -d "$ANDROID_SDK_ROOT" ]; then
            echo "ANDROID_SDK_ROOT is not valid"
            exit 4
        fi

    else
        echo "Could not open $1 config file"
        exit 1
    fi
}

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

map_images() {
    echo -e "\nMouting the images..."
    # Mount the images
    mkdir -p "$RTDIR"

    mount_img "$WORKDIR/tmp/system.img" "$RTDIR"
    if [ ! -d "$RTDIR/system" ]; then        
        SYSIMG_IS_SYSTEM="true"
        # On API27, system.img has the content of /system
        umount_img "$WORKDIR/tmp/system.img" "$RTDIR"
        mkdir -p "$RTDIR/"{system,cache,vendor,proc,dev}
        mount_img "$WORKDIR/tmp/system.img" "$RTDIR/system"
    fi
    mount_img "$WORKDIR/tmp/vendor.img" "$RTDIR/vendor"
    if [ -e "$WORKDIR/tmp/lpdump.json" ]; then
        if [ $(jq ".partitions | length" "$WORKDIR/tmp/lpdump.json") -eq 4 ]; then
        mount_img "$WORKDIR/tmp/system_ext.img" "$RTDIR/system_ext"
        mount_img "$WORKDIR/tmp/product.img" "$RTDIR/product"
        fi
    fi

    mount_img "$WORKDIR/cache.img" "$RTDIR/cache"
}

unmap_images() {
    # Unmount the images & cleanup
  echo -e "\nUnmouting the images..."
  if [ ! "a$ROOT_TMP_EXISTED" = "atrue" ]; then rmdir "$RTDIR/tmp" ; fi
  umount_img "$IMAGE_SYSDIR/cache.img" "$RTDIR/cache"
  umount_img "$WORKDIR/tmp/vendor.img" "$RTDIR/vendor"
  if [ -e "$WORKDIR/tmp/lpdump.json" ]; then
    if [ $(jq ".partitions | length" "$WORKDIR/tmp/lpdump.json") -eq 4 ]; then
      umount_img "$WORKDIR/tmp/system_ext.img" "$RTDIR/system_ext"
      umount_img "$WORKDIR/tmp/product.img" "$RTDIR/product"
    fi
  fi

  umount "$RTDIR/proc"
  umount "$RTDIR/dev"
  if [[ "a$SYSIMG_IS_SYSTEM" == "atrue" ]]; then    
    umount_img "$WORKDIR/tmp/system.img" "$RTDIR/system"
    rmdir "$RTDIR/"{system,cache,vendor,proc,dev,tmp}
  else
    umount_img "$WORKDIR/tmp/system.img" "$RTDIR"
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
    downsize_extfs "${WORKDIR}/tmp/$file"
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
  echo -e "\nUnpack original partition images from $IMAGE_SYSDIR"
  mkdir -p "$WORKDIR/tmp"
  if [ $(kpartx "${IMAGE_SYSDIR}/system.img" | wc -l) -gt 1 ]; then
    lptools_required
    # API 29 image (android Q) holding a super.img
    map_disk_img "${IMAGE_SYSDIR}/system.img" 2

    echo $DEVICE
    "$LPTOOLS_BIN_DIR/lpdump" -j "$DEVICE" > "$WORKDIR/tmp/lpdump.json"
    echo $("cat $WORKDIR/tmp/lpdump.json")
    "$LPTOOLS_BIN_DIR/lpdump" "$DEVICE" > "$WORKDIR/tmp/lpdump.txt"

    download_and_extract_aosp_scripts

    dd if="${DEVICE::-1}1" of="${WORKDIR}/tmp/vbmeta.orig.img"
    "$TEMPDIR/avbtool.py" info_image   --image "${WORKDIR}/tmp/vbmeta.orig.img" > "${WORKDIR}/tmp/vbmeta.orig.img.info_image.txt"

    for partition in $(jq -r ".partitions[].name" "$WORKDIR/tmp/lpdump.json"); do
        echo -e "\nUnpacking & converting to read/write: $partition.img"

        local PART_SIZE
        PART_SIZE=$(jq -r '.partitions[] | select(.name=="'$partition'").size ' "$WORKDIR/tmp/lpdump.json")
        check_free_space "${WORKDIR}/tmp" $(( PART_SIZE * 11 / 10 ))

        "$LPTOOLS_BIN_DIR/lpunpack" --slot=0 -p $partition "$DEVICE" "$WORKDIR/tmp"
        "$TEMPDIR/avbtool.py" info_image   --image "$WORKDIR/tmp/$partition.img" > "$WORKDIR/tmp/$partition.img.info_image.txt"
        # Filesystems have the feature: EXT4_FEATURE_RO_COMPAT_SHARED_BLOCKS
        # We need to remove it to mount rw,
        # and at least resize the partition a bit if there is not enough space
        FS_SIZE=$(wc -c "$WORKDIR/tmp/$partition.img" | cut -f 1 -d ' ')
        e2fsck -f -y "$WORKDIR/tmp/$partition.img"
        # Increase size by 10% to be able to unshare_blocks
        resize2fs "$WORKDIR/tmp/$partition.img" $(( FS_SIZE * 11 / 10 / 1024 ))K
        e2fsck -y -E unshare_blocks "$WORKDIR/tmp/$partition.img" > /dev/null 2>&1
        e2fsck -f -y "$WORKDIR/tmp/$partition.img"
    done
  else
    check_free_space "${WORKDIR}/tmp" $(wc -c "${IMAGE_SYSDIR}/vendor.img" | cut -f 1 -d ' ')
    cp "${IMAGE_SYSDIR}/vendor.img" "${WORKDIR}/tmp/vendor.img"
    check_free_space "${WORKDIR}/tmp" $(wc -c "${IMAGE_SYSDIR}/system.img" | cut -f 1 -d ' ')
    cp "${IMAGE_SYSDIR}/system.img" "${WORKDIR}/tmp/system.img"
  fi
  if [ -f "${IMAGE_SYSDIR}/encryptionkey.img" ]; then
    if [ ! -f "${WORKDIR}/encryptionkey.img" ]; then
      echo "copying encryptionkey.img ..."
      cp "${IMAGE_SYSDIR}/encryptionkey.img" "${WORKDIR}/encryptionkey.img"
    fi
  fi
}

set_new_size() {
  local USED_IN_KB NEW_SIZE_IN_B CUR_SIZE_IN_B

  mount_img "$WORKDIR/tmp/system.img" "$RTDIR"
  USED_IN_KB=$(df --output=used "$RTDIR" | tail -1)
  umount_img "$WORKDIR/tmp/system.img" "$RTDIR"

  NEW_SIZE_IN_B="$(( ( USED_IN_KB + REQUIRED_SPACE_FOR_OPENGAPPS_IN_MB * 1024 ) * 1024 ))"
  CUR_SIZE_IN_B=$(wc -c "${WORKDIR}/tmp/system.img" | cut -f 1 -d ' ')

  if [ $CUR_SIZE_IN_B -ge $NEW_SIZE_IN_B ]; then
    NEW_SIZE="$((CUR_SIZE_IN_B / 1024 / 1024 + 1))M"
  else
    NEW_SIZE="$((NEW_SIZE_IN_B / 1024 / 1024 + 1))M"
  fi
}

cleanup_avd() {
  rm -f "${WORKDIR}/vendor.img"
  rm -f "${WORKDIR}/system.img"
  rm -f "${WORKDIR}/cache.img"
  rm -f "${WORKDIR}/cache.img.qcow2"
  rm -f "${WORKDIR}/userdata-qemu.img"
  rm -f "${WORKDIR}/userdata-qemu.img.qcow2"
  rm -fr "${WORKDIR}/snapshots/default_boot/"
}

disable_verified_boot_pre_q() {
  # On Android Pie, we disable it since we modify the system.img file. Otherwise the emulator will not boot.
  if [ -f "${IMAGE_SYSDIR}/VerifiedBootParams.textproto" ] \
    && grep "^dm_param" "${IMAGE_SYSDIR}/VerifiedBootParams.textproto" > /dev/null ; then
    # If the file exists, maybe the emulator has Verity/Verified boot enabled.
    if [ ! -f "${WORKDIR}/VerifiedBootParams.textproto" ]; then
      echo "copying VerifiedBootParams.textproto..."
      cp "${IMAGE_SYSDIR}/VerifiedBootParams.textproto" "${WORKDIR}/VerifiedBootParams.textproto"
    fi
    echo "Disabling verity/verified-boot..."
    sed -i -e "s/^dm_param/#dm_param/" "${WORKDIR}/VerifiedBootParams.textproto"
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
  if [ $(kpartx "${IMAGE_SYSDIR}/system.img" | wc -l) -le 1 ]; then return 0; fi

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

  for partition in $(jq -r ".partitions[].name" "$WORKDIR/tmp/lpdump.json"); do
    unset PROP_ARGS
    declare -a PROP_ARGS=()
    for line in $(grep "Prop:" "${WORKDIR}/tmp/$partition.img.info_image.txt" | sed -e 's/.*Prop: \(.*\) -> \(.*\)/\1:\2/' -e "s/'//g"); do
      PROP_ARGS+=(--prop "$line")
    done

    if [ ! $partition = "system" ]; then
        #$TEMPDIR/avbtool.py erase_footer --image "${WORKDIR}/tmp/$partition.img"
        PATH=$PATH:$FEC_PATH "$TEMPDIR/avbtool.py" add_hashtree_footer \
            --partition_name $partition \
            --partition_size 0 \
            --image "${WORKDIR}/tmp/$partition.img" \
            "${PROP_ARGS[@]}"

        "$TEMPDIR/avbtool.py" info_image   --image "${WORKDIR}/tmp/$partition.img"
        "$TEMPDIR/avbtool.py" verify_image --image "${WORKDIR}/tmp/$partition.img"
    fi
  done


  unset PROP_ARGS
  declare -a PROP_ARGS=()
  for line in $(grep "Prop:" "${WORKDIR}/tmp/$partition.img.info_image.txt" | sed -e 's/.*Prop: \(.*\) -> \(.*\)/\1:\2/' -e "s/'//g"); do
    PROP_ARGS+=(--prop "$line")
  done
  #"$TEMPDIR/avbtool.py" erase_footer --image "${WORKDIR}/tmp/system.img"
  # We skip the rollback index value (--rollback-index)
  PATH=$PATH:$FEC_PATH "$TEMPDIR/avbtool.py" add_hashtree_footer \
    --partition_name system \
    --partition_size 0 \
    --image "${WORKDIR}/tmp/system.img" \
    --algorithm SHA256_RSA2048 \
    --key "$TEMPDIR/testkey_rsa2048.pem" \
    "${PROP_ARGS[@]}"

  "$TEMPDIR/avbtool.py" info_image   --image "${WORKDIR}/tmp/system.img"
  "$TEMPDIR/avbtool.py" verify_image --image "${WORKDIR}/tmp/system.img" --key "$TEMPDIR/testkey_rsa2048.pem"

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
#     --output ${WORKDIR}/tmp/vbmeta_disabled.img \
#     --chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey

  declare -a AVBTOOL_ADDITIONAL_ARGS=()
  for partition in $(jq -r ".partitions[].name" "$WORKDIR/tmp/lpdump.json"); do
    if [ ! "$partition" = "system" ]; then
      AVBTOOL_ADDITIONAL_ARGS+=(--include_descriptors_from_image "${WORKDIR}/tmp/$partition.img")
    fi
  done

  REPLICATE_LPDUMP=0

  # Remove old vbmeta.img, then create vbmeta image
  rm -f "${WORKDIR}/tmp/vbmeta.img"
  "$TEMPDIR/avbtool.py" make_vbmeta_image \
    --algorithm SHA256_RSA4096 \
    --key "$TEMPDIR/testkey_rsa4096.pem" \
    --padding_size 4096 \
    --output "${WORKDIR}/tmp/vbmeta.img" \
    --chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey \
    "${AVBTOOL_ADDITIONAL_ARGS[@]}"
    #--include_descriptors_from_image "${WORKDIR}/tmp/vendor.img"

  "$TEMPDIR/avbtool.py" info_image   --image "${WORKDIR}/tmp/vbmeta.img"
  "$TEMPDIR/avbtool.py" verify_image --image "${WORKDIR}/tmp/vbmeta.img" \
    --expected_chain_partition system:1:$TEMPDIR/system_rsa2048.avbpubkey \
    --key "$TEMPDIR/testkey_rsa4096.pem"

  if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
    cp "${WORKDIR}/tmp/vbmeta.orig.img" "${WORKDIR}/tmp/vbmeta.img"
  fi

  "$TEMPDIR/avbtool.py" info_image   --image "${WORKDIR}/tmp/vbmeta.img" | tee "${WORKDIR}/tmp/vbmeta.img.info_image.txt"

  # Create VerifiedBootParams.textproto
  AVBTOOL="$(realpath "$TEMPDIR/avbtool.py")" "$TEMPDIR/mk_vbmeta_boot_params.sh" \
    "${WORKDIR}/tmp/vbmeta.img" \
    "${WORKDIR}/tmp/system.img" \
    "${WORKDIR}/tmp/VerifiedBootParams.textproto"
  mv "${WORKDIR}/tmp/VerifiedBootParams.textproto" "${WORKDIR}/VerifiedBootParams.textproto"

  # Prepare variables to repack super.img with lpmake
  LPMAKE_SUPER_NAME=$(jq -r '.block_devices[0].name' "$WORKDIR/tmp/lpdump.json")
  LPMAKE_ALIGNMENT=$(jq -r '.block_devices[0].alignment' "$WORKDIR/tmp/lpdump.json")
  LPMAKE_BLOCK_SIZE=$(jq -r '.block_devices[0].block_size' "$WORKDIR/tmp/lpdump.json")
  LPMAKE_GROUP_NAME=$(jq -r '.partitions[0].group_name' "$WORKDIR/tmp/lpdump.json")
  LPMAKE_METADATA_SIZE=$(cat "$WORKDIR/tmp/lpdump.txt" | grep "Metadata max size:" | cut -d ' ' -f 4)
  LPMAKE_METADATA_SLOTS=$(cat "$WORKDIR/tmp/lpdump.txt" | grep "Metadata slot count:" | cut -d ' ' -f 4)

  declare -a LPMAKE_PARTITION_ARGS=()
  for partition in $(jq -r ".partitions[].name" "$WORKDIR/tmp/lpdump.json"); do
    if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
      PART_SIZE=$(jq -r '.partitions[] | select(.name=="'$partition'").size ' "$WORKDIR/tmp/lpdump.json")
    else
      PART_SIZE=$(wc -c "${WORKDIR}/tmp/$partition.img" | cut -f 1 -d ' ')
    fi
    PART_SIZE_SUM=$(( PART_SIZE_SUM + PART_SIZE ))
    LPMAKE_PARTITION_ARGS+=(-p $partition:readonly:$PART_SIZE:$LPMAKE_GROUP_NAME)
    LPMAKE_PARTITION_ARGS+=(-i $partition="${WORKDIR}/tmp/$partition.img")
  done

  if [[ $REPLICATE_LPDUMP -eq 1 ]]; then
    LPMAKE_GROUP_MAX_SIZE=$(jq -r '.groups[] | select(.name=="'$LPMAKE_GROUP_NAME'").maximum_size' "$WORKDIR/tmp/lpdump.json")
    LPMAKE_DEVICE_SIZE=$(jq -r '.block_devices[0].size' "$WORKDIR/tmp/lpdump.json")
  else
    # LPMAKE_GROUP_MAX_SIZE: round size to multiple of 1024*1024 (size of all partitions + 4MiB)
    LPMAKE_GROUP_MAX_SIZE=$(( ( ( PART_SIZE_SUM / 1024 / 1024 ) + 4 ) * 1024 * 1024))
    # LPMAKE_DEVICE_SIZE = LPMAKE_GROUP_MAX_SIZE + 8MiB
    LPMAKE_DEVICE_SIZE=$(( LPMAKE_GROUP_MAX_SIZE + ( 8 * 1024 * 1024 ) ))
    #LPMAKE_DEVICE_SIZE=$(( $(jq -r '.block_devices[0].size' "$WORKDIR/tmp/lpdump.json") + (100 * 1024 * 1024) ))
  fi

  # Repack the super.img
  check_free_space "${WORKDIR}/tmp" $LPMAKE_DEVICE_SIZE
  "$LPTOOLS_BIN_DIR/lpmake" \
    --device-size=$LPMAKE_DEVICE_SIZE \
    --metadata-size=$LPMAKE_METADATA_SIZE \
    --metadata-slots=$LPMAKE_METADATA_SLOTS \
    --output="${WORKDIR}/tmp/super.img" \
    "${LPMAKE_PARTITION_ARGS[@]}" \
    --block-size=$LPMAKE_BLOCK_SIZE \
    --alignment=$LPMAKE_ALIGNMENT \
    --super-name="$LPMAKE_SUPER_NAME" \
    --group=$LPMAKE_GROUP_NAME:$LPMAKE_GROUP_MAX_SIZE

  # Delete partition images (we now have super.img)
  for partition in $(jq -r ".partitions[].name" "$WORKDIR/tmp/lpdump.json"); do
    rm "${WORKDIR}/tmp/$partition.img"*
  done

  # Prepare image_config file to build the combined img that will be used as system.img for the emulator
  echo "${WORKDIR}/tmp/vbmeta.img vbmeta 1" > "${WORKDIR}/tmp/image_config"
  echo "${WORKDIR}/tmp/super.img super 2" >> "${WORKDIR}/tmp/image_config"

  # Fix incorrect arguments when calling sgdisk (replace --type= by --typecode= )
  sed -i -e "s/--type=/--typecode=/" "$TEMPDIR/mk_combined_img.py"

  # Remove previous image (because the mk_combined_img.py behaves differently if the file already exists)
  # Then, create the combined image
  rm -f "${WORKDIR}/tmp/combined.img"
  check_free_space "${WORKDIR}/tmp" $(( $(wc -c "${WORKDIR}/tmp/super.img" | cut -f 1 -d ' ') + 5 * 1024 * 1024 ))
  "$TEMPDIR/mk_combined_img.py" -i "${WORKDIR}/tmp/image_config" -o "${WORKDIR}/tmp/combined.img"

  # Cleanup
  rm "${WORKDIR}/tmp/image_config"
  rm "${WORKDIR}/tmp/vbmeta.img"*
  rm "${WORKDIR}/tmp/vbmeta.orig.img"*
  rm "${WORKDIR}/tmp/super.img"
  rm "${WORKDIR}/tmp/lpdump.json"
  rm "${WORKDIR}/tmp/lpdump.txt"


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
