# AVD adb root

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
