🎤 Karaoke Jukebox

«A self-hosted, browser-based Karaoke Jukebox for local networks — built for Android/Termux, with multi-player control, remote queue management, local video playback, ZIP karaoke libraries, QR access, and optional YouTube integration.»

---

✨ Overview

Karaoke Jukebox is a lightweight self-hosted karaoke system designed to run on a local device and provide a modern web interface accessible from phones, tablets, computers, smart displays, or other devices connected to the same network.

The server runs directly from Python and exposes separate Player, Remote, and Single Player interfaces through a web browser.

It is designed around a simple concept:

📱 Phone / Tablet
       │
       │  Wi-Fi / Local Network
       ▼
┌──────────────────────┐
│   KARAOKE JUKEBOX    │
│   Python HTTP Server │
└──────────┬───────────┘
           │
     ┌─────┴─────┐
     ▼           ▼
  PLAYER       REMOTE
     │           │
     ▼           ▼
 Video        Queue Control
 Playback     Player Control

---

🚀 Features

🎵 Local Karaoke Library

Automatically scans the configured "KARAOKE" directory for karaoke videos.

Supported video formats:

- ".mp4"
- ".m4v"
- ".webm"
- ".mkv"
- ".mov"
- ".avi"

The server periodically rescans the library and uses a directory cache to avoid unnecessary work.

---

📦 ZIP Karaoke Library

Karaoke videos can also be stored inside ZIP archives.

The server can:

- Detect ".zip" karaoke libraries
- Read supported video files directly from ZIP archives
- Display ZIP-contained songs in the song library
- Play ZIP-contained karaoke videos
- Protect against unsafe ZIP paths such as directory traversal

ZIP songs are represented internally using a virtual path system such as:

@ZIP@/MY KARAOKE.zip::folder/song.mp4

---

🎶 Automatic Song Information

Song filenames can be interpreted using the following format:

CODE - TITLE - ARTIST.mp4

Example:

0001 - My Song - My Artist.mp4

The server extracts:

Code   : 0001
Title  : My Song
Artist : My Artist

If only a title is provided, the remaining fields are optional.

Numeric song codes are normalized to four digits when possible.

---

🎛️ Player

The Player interface is designed for the main karaoke display.

Features include:

- Video playback
- Play / Pause
- Next
- Previous
- Current song information
- Queue display
- Drag-and-drop queue ordering
- Mobile touch queue reordering
- Fullscreen playback
- QR Remote access
- YouTube playback
- Idle preview behavior
- Independent Player sessions

The server maintains an independent state for each Player token.

---

📱 Remote Control

The Remote interface allows another device to control an active Player.

Remote controls include:

- Select Player
- View current song
- Add songs to queue
- Remove songs
- Reorder queue
- Play / Pause
- Next
- Previous
- Clear queue
- Select and play songs

Player activity is tracked using heartbeat information, allowing the Remote interface to determine whether a Player is currently active.

The active Player window is configured to 6 seconds, while inactive Player sessions are cleaned up after 10 minutes.

---

👥 Multi-Player Support

Multiple Player sessions can run simultaneously.

Each Player receives its own Player token and maintains its own:

- Queue
- Current song
- Playback state
- History
- Commands
- Version state

This allows a single Jukebox server to manage multiple independent Player screens.

---

🔄 Queue Management

The queue system supports:

- Add song
- Remove song
- Reorder songs
- Clear queue
- Next song
- Previous song
- Playback history
- Current song tracking

Maximum queue size:

100 songs

---

▶️ Playback Controls

The Player state supports:

PLAY
PAUSE
NEXT
PREVIOUS

The server keeps track of:

- Current song
- Playback status
- Start time
- Queue
- History
- Player commands

---

▶️ YouTube Integration

When an Internet connection is available, the Jukebox can search YouTube using the YouTube Data API.

Features include:

- YouTube song search
- Up to 50 search results
- Philippine region targeting
- Search caching
- Saved playable links
- YouTube thumbnails
- YouTube playback
- Offline detection

The YouTube API key can be provided through:

Environment variable

export YOUTUBE_API_KEY="YOUR_API_KEY"

or through:

~/jukebox/youtube_api_key.txt

---

💾 YouTube Search Cache

YouTube search results are cached locally.

Default cache lifetime:

24 hours

Cache file:

~/jukebox/youtube_search_cache.json

This reduces unnecessary API requests and allows previously cached searches to remain available even when the YouTube API is temporarily unavailable.

---

⭐ Saved YouTube Links

Playable YouTube songs can be saved locally.

Saved links are stored in:

~/jukebox/yt-playable-link.json

Saved songs appear as part of the Jukebox library and can be played again without performing another search.

---

🌐 Online / Offline Detection

The server automatically checks Internet connectivity.

When offline:

OFFLINE — YouTube unavailable

Local karaoke playback remains independent from YouTube connectivity.

The Internet status is cached for a short period to prevent excessive connectivity checks.

---

🔐 Jukebox Key Protection

Karaoke Jukebox includes a built-in license/key validation mechanism.

The required file is:

Jukebox.key

A valid key can be located:

KARAOKE/
KARAOKE/<subfolder>/
KARAOKE/<archive>.zip

The server validates the key using HMAC-SHA256 verification.

If a valid key cannot be found, the server does not start.

---

🔑 Generate a Jukebox Key

The server includes a built-in key generation mode:

python3 server_v10.5.108.py --generate

The generated key is placed inside:

~/storage/shared/KARAOKE/Jukebox.key

«Security note: Do not publish your private/master key material or valid production keys in a public GitHub repository.»

---

📦 Karaoke ZIP Migration

The server also includes a ZIP migration utility.

Run:

python3 server_v10.5.108.py --zip

This creates:

MY KARAOKE.zip

inside the "KARAOKE" directory.

The ZIP operation uses ZIP STORED mode and verifies each written file before deleting the original loose video.

«⚠️ Important: "--zip" is a destructive operation because successfully archived original video files are deleted. Always maintain a backup before using it.»

The implementation also avoids overwriting an existing "MY KARAOKE.zip".

---

📱 Termux Installation

This project is designed to work well with Termux on Android.

Install Python:

pkg update
pkg install python

Install the QR-code dependency:

pip install qrcode

Grant storage access:

termux-setup-storage

Create the karaoke directory:

mkdir -p ~/storage/shared/KARAOKE

Copy the server:

cp server_v10.5.108.py ~/jukebox/

---

▶️ Start the Server

Run:

cd ~/jukebox
python3 server_v10.5.108.py

The server listens on:

0.0.0.0:8080

Once started, the terminal displays the Player and Remote information, including QR codes for quick access.

---

🌐 Web Interfaces

Player

http://DEVICE-IP:8080/player

Single Player

http://DEVICE-IP:8080/singleplayer

Remote

http://DEVICE-IP:8080/remote

Player UI

http://DEVICE-IP:8080/player-ui

The root URL automatically redirects to the Player:

/
→ /player

---

📁 Directory Structure

Recommended layout:

~/jukebox/
├── server_v10.5.108.py
├── youtube_api_key.txt
├── youtube_search_cache.json
└── yt-playable-link.json

~/storage/shared/KARAOKE/
├── Jukebox.key
├── preview.png
├── 0001 - Song Title - Artist.mp4
├── 0002 - Another Song - Artist.mp4
├── Folder/
│   └── 0003 - Song - Artist.mp4
└── MY KARAOKE.zip

---

🎞️ Supported Video Formats

Extension| Supported
".mp4"| ✅
".m4v"| ✅
".webm"| ✅
".mkv"| ✅
".mov"| ✅
".avi"| ✅

---

🧩 Architecture

Karaoke Jukebox uses a lightweight Python HTTP architecture.

Backend

Python 3
ThreadingHTTPServer
BaseHTTPRequestHandler

Frontend

HTML
CSS
JavaScript
HTML5 Video
YouTube Player

Storage

Local filesystem
ZIP archives
JSON cache files

Communication

HTTP
JSON API
Player tokens
QR-generated URLs

The server uses "ThreadingHTTPServer", allowing concurrent browser clients to communicate with the Jukebox.

---

🔌 Main HTTP Routes

Route| Purpose
"/"| Redirects to Player
"/player"| Player claim/interface
"/player-ui"| Active Player UI
"/remote"| Remote controller
"/singleplayer"| Single-player interface
"/api/qr"| Generates QR SVG
"/api/internet-status"| Internet status
"/api/youtube-search"| YouTube search
"/api/player/next"| Next song
"/api/player/previous"| Previous song
"/api/player/toggle"| Play/Pause
"/api/player/set-playing"| Set playback state
"/api/player/play"| Play selected song

---

⚙️ Configuration

Important server configuration values are centralized near the beginning of the Python server:

HOST = '0.0.0.0'
PORT = 8080

KARAOKE_DIR = os.path.expanduser(
    '~/storage/shared/KARAOKE'
)

VIDEO_EXTENSIONS = {
    '.mp4',
    '.m4v',
    '.webm',
    '.mkv',
    '.mov',
    '.avi'
}

SCAN_INTERVAL = 30
MAX_QUEUE = 100

---

🛠️ Troubleshooting

Jukebox.key not found

If the server displays:

Jukebox.key: NOT FOUND / INVALID

make sure a valid key exists inside:

~/storage/shared/KARAOKE/

You can generate one with:

python3 server_v10.5.108.py --generate

---

No Songs Found

Check that karaoke videos are located inside:

~/storage/shared/KARAOKE/

Supported formats must use one of the supported extensions.

The server automatically creates the directory if it does not exist.

---

YouTube Search Not Working

Check:

1. Internet connection
2. YouTube API key
3. "youtube_api_key.txt"
4. YouTube API quota

API key location:

~/jukebox/youtube_api_key.txt

---

Remote Cannot Find Player

The Remote checks Player activity using the Player heartbeat system.

Make sure:

- Player is open
- Player is connected to the same Jukebox server
- Both devices are on the same network
- Player has not exceeded the inactive timeout

The configured active window is:

6 seconds

---

🔒 Security Recommendations

For production or public repositories:

- Never commit "Jukebox.key"
- Never publish private production keys
- Never publish your YouTube API key
- Do not expose port "8080" directly to the public Internet unless properly secured
- Use a trusted local network
- Keep backups of the karaoke library
- Be careful when using "--zip" because it deletes successfully archived source files

Recommended ".gitignore" entries:

Jukebox.key
youtube_api_key.txt
youtube_search_cache.json
yt-playable-link.json
MY KARAOKE.zip
*.key
*.part

---

📜 License

Add your preferred license here.

For example:

Copyright © 2026 Jeffrey Solis

All rights reserved.

Unauthorized redistribution, resale, modification, or commercial
deployment may require permission from the project owner.

«Replace this section with an official open-source license such as MIT, Apache-2.0, or GPL if you intend to distribute the project under one.»

---

🤝 Contributing

Contributions are welcome when they improve the project while preserving existing functionality.

Before submitting changes:

1. Test the server locally.
2. Verify Player functionality.
3. Verify Remote functionality.
4. Test queue operations.
5. Test local video playback.
6. Test ZIP library playback.
7. Test offline behavior.
8. Test YouTube functionality when Internet is available.
9. Avoid committing private keys or API credentials.

---

📌 Project Status

Current server file:

server_v10.5.108.py

Runtime version identifier currently embedded in the server:

10.5.102-V11

If the repository release is intended to be officially labeled "10.5.108", consider updating "JUKEBOX_VERSION" inside the Python file so the displayed runtime version and filename match.

---

🎤 Karaoke Jukebox

Local. Private. Fast. Flexible.

Built for real-world karaoke setups where the music library stays under your control while phones and displays become the interface.

🎤  KARAOKE JUKEBOX
──────────────────────────────
PLAYER       → Karaoke Display
REMOTE       → Song Selection
MULTI-PLAYER → Independent Players
ZIP LIBRARY  → Large Collections
YOUTUBE      → Online Expansion
QR ACCESS    → Fast Connection

Enjoy your karaoke. 🎶