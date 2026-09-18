JUKEBOX OFFLINE BUILDER
========================

Base server:
    server_10.5.06.py

Files:
    install.sh                  Online installer
    download_offline_packages.sh  Downloads Python wheels
    install_offline.sh          Fully offline installer
    offline_packages/           Put downloaded .whl files here

IMPORTANT:
The server itself is already designed to keep LOCAL playback independent
from the Internet. Its Internet/YouTube functions are separate from local
song scanning/playback.

BUILD STEPS
1. On a Termux device WITH Internet:
       bash download_offline_packages.sh

2. Copy the complete JUKEBOX_OFFLINE folder to the offline device.

3. On the offline device:
       bash install_offline.sh

4. Put local karaoke files in:
       ~/storage/shared/KARAOKE

5. Start:
       jukebox

The offline installer uses only local wheel files for qrcode/Pillow.
