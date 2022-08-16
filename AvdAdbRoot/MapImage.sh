#!/bin/bash
source ./framework.sh

MAPPER_CONFIG="mapper.conf"
export LPTOOLS_BIN_DIR="/tmp/lpunpack_and_lpmake/bin"
export FEC_BINARY="/tmp/otatools/bin/fec"
export IMAGE_SYSDIR=""
export WORKDIR=""
export TEMPDIR=""
export RTDIR=""
export SYSIMG_IS_SYSTEM=""

TEMPDIR="$(mktemp --tmpdir -d "ImageMapper.XXXX")"
RTDIR="/mnt/mounted_avd"
CONFIGNAME="ImagePackerConfig.conf"

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

export DEVICE=""

if [ -f "$CONFIGNAME" ]; then
    #rm "$CONFIGNAME"
    echo "Run UnMapImage.sh before mapping new one"
    exit 10
fi


# How much space to add to the system.img so that there is enough space to install OpenGApps
# You may need to inscrease this if you install "super" variant
export REQUIRED_SPACE=1400

if [ $UID -ne 0 ]; then
  echo "Root rights needed"
  exit 9;
fi

if [ -f "$FEC_BINARY" ]; then
  export FEC_PATH="$(dirname "$FEC_BINARY")"
else
  export FEC_PATH="$FEC_BINARY"
fi

export OS="$(uname)"

touch "$CONFIGNAME"

{
  echo "OS=$OS" >> "$CONFIGNAME"
  echo "TEMPDIR=$TEMPDIR"
} >> "$CONFIGNAME"

if [ ! -f "MAPPER_CONFIG" ]; then
  { 
    echo "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
    echo "WORKDIR=$WORKDIR"
    echo "IMAGE_SYSDIR=$IMAGE_SYSDIR"
    echo "LPTOOLS_BIN_DIR=$LPTOOLS_BIN_DIR"
    echo "FEC_BINARY=$FEC_BINARY"    
  } >> "$CONFIGNAME"
fi

# Copy clean system.img to selected AVD and related stuff
unpack_images

# Resize system.img
set_new_size
echo -e "\nResizing system.img to $NEW_SIZE"
resize_img "${WORKDIR}/tmp/system.img" "$NEW_SIZE"

#unmap_disk_img "${IMAGE_SYSDIR}/system.img" 

map_images

if [[ "a$SYSIMG_IS_SYSTEM" == "atrue" ]]; then
  echo "SYSIMG_IS_SYSTEM=$SYSIMG_IS_SYSTEM" >> "$CONFIGNAME"
fi
