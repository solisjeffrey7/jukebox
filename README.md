# 🎤 Jukebox Server

A lightweight local-network Karaoke Jukebox Server designed to run on **Android + Termux**.

The Android phone acts as the central jukebox server. Karaoke videos remain in Android shared storage, while phones/tablets connected to the same Wi-Fi can use the Remote interface to control playback and the shared queue.

## Features

- 🎬 Local karaoke video library
- 🔎 Search by code, title, or artist
- 📁 Recursive folder scanning
- 📋 Shared server-side queue
- ▶️ Automatic queue playback
- ⏮ Previous / ▶️ Play-Pause / ⏭ Next
- 📱 Multi-device Remote control
- 📺 Single active Player page
- 🔐 Player ownership timeout
- 🖼️ Custom idle `preview.png`
- 📷 QR code for Remote access
- ⏩ HTTP Range support for video seeking
- 🔄 Automatic library scan every 30 seconds
- No external Python packages required

## Requirements

- Android
- Termux
- Python 3
- Termux storage permission
- Karaoke video files

## Installation

### 1. Install Python

```bash
pkg update
pkg install python
```

### 2. Allow Termux to access Android storage

```bash
termux-setup-storage
```

Accept the Android permission prompt.

### 3. Clone the repository

```bash
git clone https://github.com/solisjeffrey7/jukebox.git
cd jukebox
```

Or copy `jukebox-server.py` manually into your Termux folder.

### 4. Prepare the karaoke folder

The server expects:

```text
/storage/emulated/0/KARAOKE
```

which is available in Termux as:

```text
~/storage/shared/KARAOKE
```

Example:

```text
KARAOKE/
├── preview.png
├── 0001-214-Rivermaya.mp4
├── 0002-Bituin-Kapuso.mp4
└── ...
```

`preview.png` is optional, but recommended.

### 5. Start the server

```bash
python jukebox-server.py
```

The server will display the local IP address and automatically open the Player page in the Android browser.

Default port:

```text
8080
```

## Filename format

Use:

```text
CODE-TITLE-ARTIST.ext
```

The dash (`-`) is the separator. Spaces around the dash do not matter.

All of these are valid:

```text
0001-214-Rivermaya.mp4
0001 -214 -Rivermaya.mp4
0001- 214 - Rivermaya.mp4
0001   -   214   -   Rivermaya.mp4
```

They are parsed as:

```text
Code:   0001
Title:  214
Artist: Rivermaya
```

## Access

After starting the server, use the displayed address.

Player:

```text
http://PHONE-IP:8080/player
```

Remote:

```text
http://PHONE-IP:8080/remote
```

All devices must be connected to the same local network.

## Player locking

Only one browser tab/device can own `/player`.

If another device opens `/player` while the Player is already active, it is redirected to `/remote`.

If the Player disconnects, its ownership expires after the configured timeout.

## Python dependencies

There are **no third-party Python dependencies**.

The server uses only Python standard-library modules:

```text
os
json
time
mimetypes
threading
urllib.parse
socket
subprocess
http.server
```

Therefore, this project does not require:

```bash
pip install ...
```

and does not need a `requirements.txt`.

## Android / Termux notes

The server uses:

```text
~/storage/shared/KARAOKE
```

Do not move the karaoke videos into the Git repository.

Keep large media files in Android shared storage.

## GitHub safety

Do not commit copyrighted karaoke videos or other large media files to the repository unless you have the necessary rights.

The repository should contain the server source code and documentation, not the karaoke library.

## License

Add the license that matches how you intend to distribute your own code.
