# AVD adb root

Scripts are written under and for the Linux systems. In future I'll port them onto MacOs. Everything was tested unde the Debian 11.x BullsEye.
Also, scripts are meant to be run with root privileges.

This projects is based on the script, that was taken from https://gist.github.com/tenzap/253c8918ee488c3874f20a563f458510
Original script is aimed on instyalling open GApps onto the AVD. I wanted to use it for having GApps on the debug avd build.
For some reasons, after applying it, I could not boot any of tested device to usable state. tenzap mentioned that there
might be problems on debug systems. So, to have clean adb root with GApps aside I've decided to slightly rework the script.

So here we have:
- framework.sh - where the necessary API is located (functions);
- MapImage.sh - maps the avd's system.img onto /mnt/mounted_avd;
- UnMapImage.sh - does only unmaping mapped system.img
- RepackMappedImage.sh - repacks already mapped avd's system.img. Needed cause one may want to experiment with repacking;
- RepackProdWithAdbRoot.sh - repacks avd's system.img with nerw config data, su taken from debug version of the image, 
    SELinux policies taken from debug version of the image;

## Usage

### Prepare configuration
To use any of these scripts you need to edit the mapper.conf file. There you need to write actual data into fielads:
- WORKDIR - working directory for scripts, where intermediate files and results are stored;
- ANDROID_SDK_ROOT - Android SDK root directory. Commonly it is /home/<username>/Android/Sdk/ on Linux systems;
- IMAGE_SYSDIR - directory where the system.img, vendor.img and encryptionkey.img are stored. Commonly it is /home/<username>/Android/Sdk/system-images/android-<API-level>/<image_type>/<arch>/ on Linux systems;
- LPTOOLS_BIN_DIR - directory where the lpdump, lpunpack etc. are stored. You need to build or get ones on the internet. To build these tools, you can get source from here: https://github.com/LonelyFool/lpunpack_and_lpmake. Also you can get already build tools from here: https://forum.xda-developers.com/t/guide-ota-tools-lpunpack.4041843/;
- FEC_BINARY - directory that contains the fec tool necessary for working of the avbtool.py. You can obtain it as part of the otatools from above.

### Prepare WorkDir
Inside of the directory, that is your WORKDIR, you need to create and fill two directories like this:  
WORKDIR  
&nbsp; &nbsp; |  
&nbsp; &nbsp; |--xbin  
&nbsp; &nbsp; &nbsp; &nbsp; |  
&nbsp; &nbsp; &nbsp; &nbsp; |--su - binary taken from /system/xbin/ the debug version of system.img  
&nbsp; &nbsp; |  
&nbsp; &nbsp; |--policies  
&nbsp; &nbsp; &nbsp; &nbsp; |  
&nbsp; &nbsp; &nbsp; &nbsp; |--plat_sepolicy.cil - SELinux policies file taken from /system/etc/selinux/ the debug version of system.img  
&nbsp; &nbsp; &nbsp; &nbsp; |  
&nbsp; &nbsp; |--plat_sepolicy_and_mapping.sha256 - file taken from /system/etc/selinux/ the debug version of system.img; it contains sha256 hash of the policy and mapping (if my understanding is right)  
&nbsp; &nbsp; &nbsp; &nbsp; |  
&nbsp; &nbsp; &nbsp; &nbsp; |--mapping - copy of directory taken from /system/etc/selinux/mapping/ the debug version of system.img  

### Start the script

Then, you can:  
#> ./MapImage.sh - to map you system.img;  
#> ./UnMapImage.sh - to undo system.img mapping;  
#> ./RepackMappedImage.sh - to save editions made to the inners of the mapped system.img;  
#> ./RepackProdWithAdbRoot.sh - to automatically repack production system.img with configuration, su binary and SEPolicies from debug version.  
