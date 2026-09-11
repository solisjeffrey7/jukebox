#!/usr/bin/env python3

import os
import json
import time
import mimetypes
import threading
import urllib.parse
import socket
import subprocess
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

HOST = "0.0.0.0"
PORT = 8080
KARAOKE_DIR = os.path.expanduser("~/storage/shared/KARAOKE")
PREVIEW_IMAGE = os.path.expanduser("~/storage/shared/KARAOKE/preview.png")

VIDEO_EXTENSIONS = {".mp4", ".m4v", ".webm", ".mkv", ".mov", ".avi"}
SCAN_INTERVAL = 30
MAX_QUEUE = 100

state_lock = threading.Lock()
songs = []
song_map = {}
queue = []
play_history = []
current_song_id = None
current_started_at = 0
player_playing = True
last_scan = 0

# Only one browser/device may own the Player page at a time.
player_lock = threading.Lock()
player_owner_token = None
player_owner_last_seen = 0
PLAYER_LOCK_TIMEOUT = 8


def make_song_id(relative_path):
    return relative_path.replace("\\", "/")


def parse_filename(filename):
    name = os.path.splitext(filename)[0].strip()

    # A dash is ALWAYS the separator.
    # Spaces around the dash do not matter.
    # Examples:
    # 0001-214-Rivermaya
    # 0001 -214 -Rivermaya
    # 0001- 214 - Rivermaya
    # 0001   -   214   -   Rivermaya
    parts = [part.strip() for part in name.split("-")]

    if len(parts) >= 3:
        code = parts[0]
        title = parts[1]
        artist = "-".join(parts[2:]).strip()
    elif len(parts) == 2:
        code = parts[0]
        title = parts[1]
        artist = ""
    else:
        code = ""
        title = name
        artist = ""

    digits = "".join(c for c in code if c.isdigit())
    if digits:
        code = digits.zfill(4)

    return code, title, artist


def scan_songs():
    global songs, song_map, last_scan

    found = []

    os.makedirs(KARAOKE_DIR, exist_ok=True)

    for root, dirs, files in os.walk(KARAOKE_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".")]

        for filename in files:
            ext = os.path.splitext(filename)[1].lower()
            if ext not in VIDEO_EXTENSIONS:
                continue

            full_path = os.path.join(root, filename)

            try:
                rel_path = os.path.relpath(full_path, KARAOKE_DIR).replace("\\", "/")
            except Exception:
                continue

            code, title, artist = parse_filename(filename)

            try:
                size = os.path.getsize(full_path)
            except Exception:
                size = 0

            found.append({
                "id": make_song_id(rel_path),
                "code": code,
                "title": title,
                "artist": artist,
                "filename": filename,
                "path": rel_path,
                "size": size,
            })

    found.sort(key=lambda x: (
        int(x["code"]) if x["code"].isdigit() else 999999999,
        x["title"].lower()
    ))

    with state_lock:
        songs = found
        song_map = {song["id"]: song for song in found}
        last_scan = time.time()


def scanner_loop():
    while True:
        try:
            scan_songs()
        except Exception as e:
            print("SCAN ERROR:", e)
        time.sleep(SCAN_INTERVAL)


def public_song(song):
    if not song:
        return None

    return {
        "id": song["id"],
        "code": song["code"],
        "title": song["title"],
        "artist": song["artist"],
        "filename": song["filename"],
        "path": song["path"],
    }


def get_queue():
    with state_lock:
        return [
            public_song(song_map[sid])
            for sid in queue
            if sid in song_map
        ]


def add_to_queue(song_id):
    with state_lock:
        if song_id not in song_map:
            return False, "Song not found"

        if len(queue) >= MAX_QUEUE:
            return False, "Queue is full"

        queue.append(song_id)
        return True, "Added to queue"


def remove_from_queue(position):
    with state_lock:
        if position < 0 or position >= len(queue):
            return False, "Invalid queue position"

        queue.pop(position)
        return True, "Removed"


def clear_queue():
    with state_lock:
        queue.clear()
        play_history.clear()


def get_current_song():
    with state_lock:
        if current_song_id:
            return public_song(song_map.get(current_song_id))
    return None


def set_current_song(song_id):
    global current_song_id, current_started_at

    with state_lock:
        if song_id not in song_map:
            return False

        current_song_id = song_id
        current_started_at = time.time()
        return True


def start_next_song():
    global current_song_id, current_started_at

    with state_lock:
        while queue:
            next_id = queue.pop(0)

            if next_id not in song_map:
                continue

            # Remember the song we are leaving so PREVIOUS can restore it.
            if current_song_id and current_song_id in song_map:
                play_history.append(current_song_id)

            current_song_id = next_id
            current_started_at = time.time()
            return public_song(song_map[next_id])

        # No next song: return to the videoke idle state.
        current_song_id = None
        current_started_at = 0
        return None


def start_previous_song():
    global current_song_id, current_started_at

    with state_lock:
        if not play_history:
            return None

        previous_id = play_history.pop()

        # Put the current song back into the queue so the queue is restored.
        if current_song_id and current_song_id in song_map:
            queue.insert(0, current_song_id)

        if previous_id not in song_map:
            return None

        current_song_id = previous_id
        current_started_at = time.time()
        return public_song(song_map[previous_id])


def get_player_token(handler):
    return handler.headers.get("X-Jukebox-Player-Token")


def create_player_token():
    return os.urandom(24).hex()


def acquire_player(token):
    global player_owner_token, player_owner_last_seen

    now = time.time()

    with player_lock:
        if player_owner_token and now - player_owner_last_seen <= PLAYER_LOCK_TIMEOUT:
            if token and token == player_owner_token:
                player_owner_last_seen = now
                return True
            return False

        if not token:
            return False

        player_owner_token = token
        player_owner_last_seen = now
        return True


def release_player(token):
    global player_owner_token, player_owner_last_seen

    with player_lock:
        if token and token == player_owner_token:
            player_owner_token = None
            player_owner_last_seen = 0


PLAYER_CLAIM_HTML = r"""
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Karaoke Player</title>
<style>
html,body{margin:0;width:100%;height:100%;background:#090909;color:#fff;font-family:Arial,Helvetica,sans-serif}
body{display:flex;align-items:center;justify-content:center}
#msg{text-align:center;color:#aaa;font-size:14px}

/* =========================================================
   SONG ACTION PROMPT
========================================================= */
.song-action-overlay{
    position:fixed;
    inset:0;
    z-index:9999;
    display:flex;
    align-items:center;
    justify-content:center;
    padding:14px;
    background:rgba(0,0,0,.72);
    backdrop-filter:blur(5px);
}
.song-action-card{
    width:min(520px,100%);
    background:#151515;
    border:1px solid #333;
    border-radius:18px;
    padding:20px;
    box-shadow:0 18px 60px rgba(0,0,0,.55);
}
.song-action-card h2{
    margin:0 0 8px;
    font-size:20px;
}
.song-action-song{
    margin:0 0 18px;
    padding:12px;
    border-radius:12px;
    background:#202020;
}
.song-action-title{
    font-weight:700;
    font-size:17px;
}
.song-action-artist{
    margin-top:3px;
    color:#aaa;
    font-size:13px;
}
.song-action-buttons{
    display:grid;
    grid-template-columns:1fr 1fr;
    gap:10px;
}
.song-action-buttons button{
    border:0;
    border-radius:12px;
    padding:13px 10px;
    font-weight:700;
    font-size:14px;
    cursor:pointer;
}
.song-action-play{
    background:#fff;
    color:#111;
}
.song-action-queue{
    background:#303030;
    color:#fff;
    border:1px solid #444 !important;
}
.song-action-cancel{
    width:100%;
    margin-top:10px;
    background:transparent;
    color:#aaa;
    border:1px solid #333 !important;
}
@media(max-width:600px){
    .song-action-overlay{
        padding:12px 10px;
        align-items:center;
    }
    .song-action-card{
        border-radius:15px;
        padding:15px;
    }
    .song-action-buttons{
        grid-template-columns:1fr;
    }
}

</style>
</head>
<body>
<div id="msg">Connecting to Karaoke Player...</div>
<script>
(async()=>{
    const KEY="jukebox_player_tab_token";
    // Always create a fresh token when /player is opened.
    // This guarantees that every newly opened tab gets its own Player claim.
    let token;
    if(window.crypto && crypto.randomUUID){
        token=crypto.randomUUID().replace(/-/g,"");
    }else{
        token=Date.now().toString(36)+Math.random().toString(36).slice(2);
    }
    sessionStorage.setItem(KEY,token);

    try{
        const response=await fetch("/api/player/claim",{
            method:"POST",
            cache:"no-store",
            headers:{"X-Jukebox-Player-Token":token}
        });

        const data=await response.json();

        if(data.ok){
            location.replace("/player-ui?token="+encodeURIComponent(token));
        }else{
            location.replace("/remote");
        }
    }catch(e){
        document.getElementById("msg").textContent="Unable to connect to Player";
    }
})();
</script>
</body>
</html>
"""

PLAYER_HTML = r"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Karaoke Player</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:#090909;color:#fff;font-family:Arial,Helvetica,sans-serif}
body{min-height:100vh}
.header{height:58px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#111;border-bottom:1px solid #292929}
.logo{font-size:20px;font-weight:800;letter-spacing:1px}
.header-right{display:flex;align-items:center;gap:12px}
.remote-box{display:flex;align-items:center;gap:9px}
.remote-qr{width:62px;height:62px;background:#fff;padding:3px;display:block}
.remote-note{font-size:10px;line-height:1.35;color:#aaa}
.remote-note strong{display:block;color:#fff;font-size:11px}
.remote-link{color:#fff;text-decoration:none;background:#222;border:1px solid #3a3a3a;padding:8px 13px;border-radius:7px;font-size:12px}
.player-layout{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:14px;padding:14px;min-height:calc(100vh - 58px)}
.video-side{min-width:0}
.video-wrapper{position:relative;width:100%;background:#000;aspect-ratio:16/9;overflow:hidden}
video{display:none;width:100%;height:100%;background:#000;object-fit:contain}
.preview-image{display:block;width:100%;height:100%;background:#000;object-fit:contain}
.video-wrapper.has-video video{display:block}
.video-wrapper.has-video .preview-image{display:none}
/* QR ABOVE PLAYER - NORMAL VIEW */
.normal-remote-qr{
    width:100%;
    min-height:58px;
    margin-bottom:8px;
    padding:6px 10px;
    display:flex;
    align-items:center;
    gap:10px;
    background:#111;
    border:1px solid #292929;
    border-radius:8px;
}
.normal-remote-qr img{
    display:block;
    width:46px;
    height:46px;
    background:#fff;
    border-radius:3px;
    flex:0 0 46px;
}
.video-qr-label{
    color:#fff;
    font-size:10px;
    line-height:1.3;
    text-align:left;
    font-weight:700;
}
.video-qr-label span{
    color:#aaa;
    font-weight:500;
}
.video-wrapper.is-fullscreen{
    width:100vw;
    height:100vh;
    aspect-ratio:auto;
}
.video-wrapper.is-fullscreen video{
    width:100%;
    height:100%;
}

/* SMALL QR - FULLSCREEN TOP RIGHT */
.fullscreen-remote-qr{
    display:none;
}
.video-wrapper.is-fullscreen .fullscreen-remote-qr{
    display:block;
    position:absolute;
    top:10px;
    right:10px;
    z-index:30;
    width:58px;
    height:58px;
    padding:3px;
    background:rgba(0,0,0,.55);
    border-radius:5px;
}
.fullscreen-remote-qr img{
    display:block;
    width:52px;
    height:52px;
    background:#fff;
}
.fullscreen-button{position:absolute;right:14px;bottom:12px;z-index:30;background:rgba(0,0,0,.72);color:#fff;border:1px solid rgba(255,255,255,.25);border-radius:5px;width:42px;height:34px;padding:0;font-size:17px}
.video-wrapper.is-fullscreen .fullscreen-button{bottom:18px}
.now-playing{padding:12px 0;border-bottom:1px solid #292929}
.now-label{color:#999;font-size:11px;text-transform:uppercase;letter-spacing:1px}
.now-title{font-size:22px;font-weight:800;margin-top:4px}
.now-artist{color:#aaa;margin-top:3px}
.controls{display:flex;gap:8px;padding:12px 0}
.controls button{flex:1;border:0;background:#242424;color:#fff;padding:10px 15px;border-radius:6px;cursor:pointer;font-weight:700}
.controls button:hover{background:#333}
.controls .next-button{background:#fff;color:#000}
.queue-side{min-width:0;display:flex;flex-direction:column;border-left:1px solid #292929;padding-left:14px}
.queue-header{display:flex;align-items:center;justify-content:space-between;padding-bottom:10px;border-bottom:1px solid #292929}
.queue-title{font-size:18px;font-weight:800}
.queue-count{color:#888;font-size:12px}
.queue-list{flex:1;min-height:0;max-height:calc(100vh - 115px);overflow-y:auto}
.queue-item{display:grid;grid-template-columns:40px minmax(0,1fr) 65px;align-items:center;gap:8px;padding:11px 3px;border-bottom:1px solid #202020}
.queue-number{color:#888;font-size:13px}
.queue-song{min-width:0}
.queue-song-title{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:700}
.queue-song-artist{color:#888;font-size:12px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.remove-button{font-size:10px;padding:6px 5px;border:0;border-radius:6px;background:#242424;color:#fff;cursor:pointer}
.empty{color:#777;padding:30px 5px;text-align:center}
@media(max-width:850px){
.player-layout{display:flex;flex-direction:column;gap:0;padding:10px}
.video-side{width:100%}
.queue-side{width:100%;border-left:0;border-top:1px solid #292929;padding-left:0;padding-top:14px;margin-top:5px}
.queue-list{flex:none;height:220px;max-height:220px}
.now-title{font-size:18px}
.remote-box{display:none}
}
@media(max-width:600px){
.header{padding:0 10px}
.logo{font-size:16px}
.remote-link{padding:7px 10px;font-size:11px}
}
</style>
</head>
<body>

<header class="header">
<div class="logo">KARAOKE PLAYER</div>

<div class="header-right">
<a class="remote-link" href="/remote" target="_blank">REMOTE</a>
</div>
</header>

<main class="player-layout">

<section class="video-side">

<div class="normal-remote-qr">
<img id="videoQr" alt="Remote QR">
<div class="video-qr-label">SCAN FOR REMOTE<br><span>Must be connected to same network</span></div>
</div>

<div id="videoWrapper" class="video-wrapper">

<img id="previewImage" class="preview-image" src="/preview" alt="Karaoke Preview">
<video id="video" controls playsinline preload="metadata"></video>

<div class="fullscreen-remote-qr">
<img id="fullscreenQr" alt="Remote QR">
</div>

<button id="fullscreenButton" class="fullscreen-button" onclick="toggleFullscreen()" title="Fullscreen">⛶</button>

</div>

<section class="now-playing">
<div class="now-label">NOW PLAYING</div>
<div id="nowTitle" class="now-title">Please select a song</div>
<div id="nowArtist" class="now-artist">—</div>
</section>

<div class="controls">
<button onclick="previousSong()">⏮ PREVIOUS</button>
<button onclick="togglePlay()">▶ PLAY / ⏸ PAUSE</button>
<button class="next-button" onclick="nextSong()">⏭ NEXT</button>
</div>

</section>

<aside class="queue-side">
<div class="queue-header">
<div class="queue-title">QUEUE</div>
<div id="queueCount" class="queue-count">0 songs</div>
</div>
<div id="queueList" class="queue-list"></div>
</aside>

</main>

<script>
let currentSongId=null;
let loadingVideo=false;
let remoteCommand=false;

const video=document.getElementById("video");
const videoWrapper=document.getElementById("videoWrapper");

function setRemoteQr(){
    const url=window.location.origin+"/remote";
    const qr="https://api.qrserver.com/v1/create-qr-code/?size=180x180&margin=0&data="+encodeURIComponent(url);
    document.getElementById("videoQr").src=qr;
    document.getElementById("fullscreenQr").src=qr;
}

const playerToken=sessionStorage.getItem("jukebox_player_tab_token");

async function api(url,options={}){
    options={...options,headers:{
        ...(options.headers||{}),
        "X-Jukebox-Player-Token":playerToken
    }};
    const response=await fetch(url,{cache:"no-store",...options});
    if(!response.ok)throw new Error(await response.text());
    return response.json();
}

async function updatePlayer(){
    try{
        const data=await api("/api/player");
        const current=data.current;

        if(current){
            document.getElementById("nowTitle").textContent=
                current.code+" - "+current.title;

            document.getElementById("nowArtist").textContent=
                current.artist||"Unknown artist";

            if(currentSongId!==current.id){
                currentSongId=current.id;
                loadVideo(current);
            }

            if(!remoteCommand){
                if(data.playing && video.paused && video.readyState>=2){
                    video.play().catch(()=>{});
                }

                if(!data.playing && !video.paused){
                    video.pause();
                }
            }
        }else{
            document.getElementById("nowTitle").textContent="Please select a song";
            document.getElementById("nowArtist").textContent="—";

            if(currentSongId!==null){
                currentSongId=null;
                video.removeAttribute("src");
                video.load();
            }

            videoWrapper.classList.remove("has-video");
        }

        renderQueue(data.queue||[]);
    }catch(e){
        console.error("Player update:",e);
    }
}

function loadVideo(song){
    if(loadingVideo)return;

    loadingVideo=true;

    const url="/video/"+song.path.split("/")
        .map(part=>encodeURIComponent(part))
        .join("/");

    video.src=url;
    video.load();
    videoWrapper.classList.add("has-video");

    video.play().catch(()=>{});

    setTimeout(()=>{loadingVideo=false;},500);
}

video.addEventListener("ended",nextSong);

video.addEventListener("play",async()=>{
    if(remoteCommand)return;
    try{
        await api("/api/player/set-playing",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({playing:true})
        });
    }catch(e){}
});

video.addEventListener("pause",async()=>{
    if(remoteCommand)return;
    if(video.ended)return;

    try{
        await api("/api/player/set-playing",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({playing:false})
        });
    }catch(e){}
});

async function togglePlay(){
    try{
        remoteCommand=true;

        const data=await api("/api/player/toggle",{
            method:"POST"
        });

        if(data.ok){
            if(data.playing){
                await video.play().catch(()=>{});
            }else{
                video.pause();
            }
        }
    }catch(e){
        console.error(e);
    }finally{
        setTimeout(()=>{remoteCommand=false;},300);
    }
}

async function nextSong(){
    try{
        const data=await api("/api/player/next",{method:"POST"});
        if(!data.ok)return;

        currentSongId=null;
        await updatePlayer();
    }catch(e){
        console.error(e);
    }
}

async function previousSong(){
    try{
        const data=await api("/api/player/previous",{method:"POST"});
        if(!data.ok)return;

        currentSongId=null;
        await updatePlayer();
    }catch(e){
        console.error(e);
    }
}

function renderQueue(queue){
    const container=document.getElementById("queueList");

    document.getElementById("queueCount").textContent=
        queue.length+(queue.length===1?" song":" songs");

    container.innerHTML="";

    if(!queue.length){
        container.innerHTML='<div class="empty">Queue is empty</div>';
        return;
    }

    queue.forEach((song,index)=>{
        const item=document.createElement("div");
        item.className="queue-item";

        item.innerHTML=`
            <div class="queue-number">${index+1}</div>
            <div class="queue-song">
                <div class="queue-song-title">
                    ${escapeHtml(song.code+" - "+song.title)}
                </div>
                <div class="queue-song-artist">
                    ${escapeHtml(song.artist)}
                </div>
            </div>
            <button class="remove-button" onclick="removeQueue(${index})">
                REMOVE
            </button>
        `;

        container.appendChild(item);
    });
}

async function removeQueue(position){
    try{
        await api("/api/queue/remove",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({position:position})
        });

        await updatePlayer();
    }catch(e){
        console.error(e);
    }
}

async function toggleFullscreen(){
    try{
        if(document.fullscreenElement){
            await document.exitFullscreen();
        }else{
            await videoWrapper.requestFullscreen();
        }
    }catch(e){
        if(!videoWrapper.classList.contains("is-fullscreen")){
            videoWrapper.classList.add("is-fullscreen");
        }else{
            videoWrapper.classList.remove("is-fullscreen");
        }
    }
}

document.addEventListener("fullscreenchange",()=>{
    if(document.fullscreenElement===videoWrapper){
        videoWrapper.classList.add("is-fullscreen");
    }else{
        videoWrapper.classList.remove("is-fullscreen");
    }
});

function escapeHtml(value){
    return String(value||"")
        .replace(/&/g,"&amp;")
        .replace(/</g,"&lt;")
        .replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;")
        .replace(/'/g,"&#039;");
}

window.addEventListener("beforeunload",()=>{
    fetch("/api/player/release",{
        method:"POST",
        keepalive:true,
        headers:{"X-Jukebox-Player-Token":playerToken}
    }).catch(()=>{});
});

setRemoteQr();
updatePlayer();
setInterval(updatePlayer,1000);
</script>

</body>
</html>
"""



REMOTE_HTML = r"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Karaoke Remote</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;padding:0;background:#090909;color:#fff;font-family:Arial,Helvetica,sans-serif}
body{min-height:100vh}
.header{position:sticky;top:0;z-index:10;height:58px;display:flex;align-items:center;justify-content:space-between;padding:0 15px;background:#111;border-bottom:1px solid #292929}
.logo{font-weight:800;font-size:18px;letter-spacing:1px}
.header-right{display:flex;align-items:center;gap:8px}
.control{height:36px;min-width:40px;padding:0 8px;border:1px solid #3a3a3a;border-radius:6px;background:#222;color:#fff;font-size:15px;font-weight:700;cursor:pointer}
.control.play{background:#fff;color:#000}
.player-link{color:#fff;text-decoration:none;background:#222;border:1px solid #3a3a3a;padding:8px 12px;border-radius:7px;font-size:12px}
.remote-layout{display:grid;grid-template-columns:260px minmax(0,1fr);min-height:calc(100vh - 58px)}
.folder-panel{border-right:1px solid #292929;background:#0d0d0d;min-width:0}
.folder-header{padding:14px;border-bottom:1px solid #292929;font-weight:800}
.folder-list{overflow-y:auto;max-height:calc(100vh - 58px)}
.folder{width:100%;display:flex;align-items:center;gap:9px;padding:12px 14px;border:0;border-radius:0;background:transparent;color:#fff;text-align:left;font-weight:600;cursor:pointer}
.folder:hover{background:#1b1b1b}
.folder.active{background:#252525}
.folder-icon{font-size:18px;width:22px;text-align:center}
.folder-name{min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.song-panel{min-width:0;display:flex;flex-direction:column}
.song-header{padding:14px;border-bottom:1px solid #292929}
.song-header-row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.song-header h2{margin:0;font-size:18px;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.song-count{color:#888;font-size:12px;white-space:nowrap}
.search{width:100%;padding:12px;background:#171717;color:#fff;border:1px solid #333;border-radius:7px;outline:none;font-size:15px}
.song-list{overflow-y:auto;flex:1}
.song{display:grid;grid-template-columns:60px minmax(0,1fr) 48px;gap:10px;align-items:center;padding:12px 14px;border-bottom:1px solid #222;cursor:pointer}
.song:hover{background:#151515}
.code{color:#777;font-family:monospace;font-size:13px}
.info{min-width:0}
.title{font-size:15px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.artist{color:#888;font-size:12px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.add{width:42px;height:42px;border:0;border-radius:50%;background:#fff;color:#000;font-size:24px;font-weight:700;cursor:pointer;position:relative;z-index:2}
.add:active{transform:scale(.92)}
.added{background:#444;color:#fff}
.status{padding:8px 14px;color:#777;font-size:11px;border-top:1px solid #222}
.empty{text-align:center;padding:40px 10px;color:#777}
@media(max-width:700px){
.remote-layout{grid-template-columns:145px minmax(0,1fr);min-height:calc(100vh - 58px)}
.folder-list{max-height:calc(100vh - 58px)}
.folder{padding:11px 9px;gap:6px;font-size:12px}
.folder-icon{font-size:16px;width:18px}
.song-header{padding:10px}
.song-header h2{font-size:15px}
.song{grid-template-columns:48px minmax(0,1fr) 42px;gap:6px;padding:10px 8px}
.title{font-size:13px}
.artist{font-size:11px}
.code{font-size:11px}
.add{width:38px;height:38px;font-size:21px}
.control{min-width:34px;height:32px;padding:0 5px;font-size:13px}
.player-link{padding:7px 8px;font-size:10px}
}
@media(max-width:420px){
.remote-layout{grid-template-columns:125px minmax(0,1fr)}
.folder{padding-left:7px;padding-right:5px}
.song{grid-template-columns:44px minmax(0,1fr) 40px}
.header-right{gap:3px}
.control{min-width:30px;padding:0 3px}
.player-link{display:none}
}

/* =========================================================
   SONG ACTION PROMPT - REMOTE
========================================================= */
.song-action-overlay{
    position:fixed;
    inset:0;
    z-index:99999;
    display:flex;
    justify-content:center;
    align-items:center;
    padding:14px;
    background:rgba(0,0,0,.72);
    backdrop-filter:blur(4px);
}
.song-action-card{
    width:min(520px,100%);
    padding:18px;
    background:#151515;
    color:#fff;
    border:1px solid #333;
    border-radius:16px;
    box-shadow:0 12px 40px rgba(0,0,0,.65);
}
.song-action-card h2{
    margin:0 0 12px;
    font-size:21px;
    line-height:1.2;
}
.song-action-song{
    margin:0 0 14px;
    padding:11px 12px;
    background:#202020;
    border:1px solid #2d2d2d;
    border-radius:11px;
}
.song-action-title{
    font-size:16px;
    font-weight:700;
    line-height:1.3;
    word-break:break-word;
}
.song-action-artist{
    margin-top:3px;
    color:#aaa;
    font-size:13px;
    line-height:1.3;
    word-break:break-word;
}
.song-action-buttons{
    display:grid;
    grid-template-columns:1fr 1fr;
    gap:9px;
}
.song-action-buttons button,
.song-action-cancel{
    min-height:44px;
    border-radius:10px;
    padding:10px 12px;
    font-size:14px;
    font-weight:700;
    cursor:pointer;
}
.song-action-play{
    border:1px solid #fff;
    background:#fff;
    color:#111;
}
.song-action-queue{
    border:1px solid #444 !important;
    background:#303030;
    color:#fff;
}
.song-action-cancel{
    width:100%;
    margin-top:9px;
    border:1px solid #3a3a3a !important;
    background:#191919;
    color:#aaa;
}
.song-action-buttons button:active,
.song-action-cancel:active{
    transform:scale(.98);
}
@media(max-width:600px){
    .song-action-card{
        padding:15px;
        border-radius:14px;
    }
    .song-action-card h2{
        font-size:19px;
    }
}
@media(max-width:380px){
    .song-action-buttons{
        grid-template-columns:1fr;
    }
}

</style>
</head>
<body>

<header class="header">
<div class="logo">KARAOKE REMOTE</div>

<div class="header-right">
<button class="control" onclick="previousSong()" title="Previous">⏮</button>
<button id="playButton" class="control play" onclick="togglePlay()" title="Play/Pause">▶</button>
<button class="control" onclick="nextSong()" title="Next">⏭</button>
<a href="/player" class="player-link" target="_blank">PLAYER</a>
</div>
</header>

<div class="remote-layout">

<aside class="folder-panel">
<div class="folder-header">FOLDERS</div>
<div id="folderList" class="folder-list"></div>
</aside>

<main class="song-panel">

<div class="song-header">
<div class="song-header-row">
<h2 id="folderTitle">ALL SONGS</h2>
<div id="songCount" class="song-count">0</div>
</div>

<input
    id="search"
    class="search"
    type="search"
    placeholder="Search song number, title or artist..."
    autocomplete="off"
>
</div>

<div id="songList" class="song-list"></div>

<div id="status" class="status">Loading songs...</div>

</main>
</div>

<script>
let songs=[];
let selectedFolder="";
let serverPlaying=false;

async function api(url,options={}){
    const response=await fetch(url,{cache:"no-store",...options});
    if(!response.ok)throw new Error(await response.text());
    return response.json();
}

async function loadSongs(){
    try{
        const data=await api("/api/songs");
        songs=data.songs||[];
        renderFolders();
        renderSongs();
    }catch(e){
        console.error(e);
        document.getElementById("status").textContent="Failed to load songs";
    }
}

function getFolders(){
    const folderSet=new Set();

    for(const song of songs){
        const parts=song.path.split("/");

        if(parts.length>1){
            parts.pop();
            folderSet.add(parts.join("/"));
        }
    }

    return Array.from(folderSet).sort((a,b)=>
        a.localeCompare(b,undefined,{
            numeric:true,
            sensitivity:"base"
        })
    );
}

function folderName(folder){
    if(!folder)return"ALL SONGS";

    const parts=folder.split("/");
    return parts[parts.length-1];
}

function getSongFolder(song){
    const parts=song.path.split("/");

    if(parts.length<=1)return"";

    parts.pop();
    return parts.join("/");
}

function renderFolders(){
    const container=document.getElementById("folderList");
    container.innerHTML="";

    const all=document.createElement("button");
    all.className="folder"+(selectedFolder===""?" active":"");

    all.innerHTML=`
        <span class="folder-icon">🏠</span>
        <span class="folder-name">ALL SONGS</span>
    `;

    all.onclick=()=>{
        selectedFolder="";
        renderFolders();
        renderSongs();
    };

    container.appendChild(all);

    for(const folder of getFolders()){

        const button=document.createElement("button");

        button.className=
            "folder"+
            (selectedFolder===folder?" active":"");

        const count=songs.filter(
            song=>getSongFolder(song)===folder
        ).length;

        button.innerHTML=`
            <span class="folder-icon">📁</span>
            <span class="folder-name">
                ${escapeHtml(folderName(folder))}
                (${count})
            </span>
        `;

        button.onclick=()=>{
            selectedFolder=folder;
            document.getElementById("search").value="";
            renderFolders();
            renderSongs();
        };

        container.appendChild(button);
    }
}

document.getElementById("search").addEventListener(
    "input",
    renderSongs
);

function renderSongs(){

    const container=document.getElementById("songList");

    const search=document
        .getElementById("search")
        .value
        .trim()
        .toLowerCase();

    let filtered=songs;

    if(selectedFolder){
        filtered=filtered.filter(
            song=>getSongFolder(song)===selectedFolder
        );
    }

    if(search){
        filtered=filtered.filter(song=>{
            const text=(
                song.code+" "+
                song.title+" "+
                song.artist+" "+
                song.filename
            ).toLowerCase();

            return text.includes(search);
        });
    }

    document.getElementById("folderTitle").textContent=
        selectedFolder
            ? folderName(selectedFolder)
            : "ALL SONGS";

    document.getElementById("songCount").textContent=
        filtered.length+" songs";

    document.getElementById("status").textContent=
        filtered.length+" songs available";

    container.innerHTML="";

    if(!filtered.length){
        container.innerHTML=
            '<div class="empty">No songs found</div>';
        return;
    }

    for(const song of filtered){

        const row=document.createElement("div");
        row.className="song";

        /*
          BODY = SHOW ACTION PROMPT
          PLUS = ADD TO QUEUE ONLY
        */

        row.onclick=()=>{
            showSongActionPrompt(song);
        };

        row.innerHTML=`
            <div class="code">
                ${escapeHtml(song.code)}
            </div>

            <div class="info">
                <div class="title">
                    ${escapeHtml(song.title)}
                </div>

                <div class="artist">
                    ${escapeHtml(song.artist)}
                </div>
            </div>

            <button
                class="add"
                id="add-${encodeId(song.id)}"
                title="Add to queue"
            >+</button>
        `;

        const addButton=row.querySelector(".add");

        addButton.onclick=(event)=>{
            event.stopPropagation();
            addSong(song.id);
        };

        container.appendChild(row);
    }
}


function closeSongActionPrompt(){
    const overlay=document.getElementById("songActionOverlay");
    if(overlay) overlay.remove();
}

function showSongActionPrompt(song){
    closeSongActionPrompt();

    const overlay=document.createElement("div");
    overlay.id="songActionOverlay";
    overlay.className="song-action-overlay";

    overlay.innerHTML=`
        <div class="song-action-card" role="dialog" aria-modal="true">
            <h2>What do you want to do?</h2>

            <div class="song-action-song">
                <div class="song-action-title">
                    ${escapeHtml(song.code)} - ${escapeHtml(song.title)}
                </div>
                <div class="song-action-artist">
                    ${escapeHtml(song.artist)}
                </div>
            </div>

            <div class="song-action-buttons">
                <button class="song-action-play" id="songActionPlay">
                    ▶ PLAY IT NOW
                </button>

                <button class="song-action-queue" id="songActionQueue">
                    ＋ ADD TO QUEUE
                </button>
            </div>

            <button class="song-action-cancel" id="songActionCancel">
                CANCEL
            </button>
        </div>
    `;

    document.body.appendChild(overlay);

    document.getElementById("songActionPlay").onclick=async()=>{
        closeSongActionPrompt();
        await playSong(song.id);
    };

    document.getElementById("songActionQueue").onclick=async()=>{
        closeSongActionPrompt();
        await addSong(song.id);
    };

    document.getElementById("songActionCancel").onclick=()=>{
        closeSongActionPrompt();
    };

    overlay.onclick=(event)=>{
        if(event.target===overlay){
            closeSongActionPrompt();
        }
    };
}

async function playSong(id){
    try{
        const data=await api("/api/player/play",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({id:id})
        });

        if(!data.ok){
            alert(data.message||"Unable to play song");
            return;
        }

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
        alert("Failed to play song");
    }
}

async function addSong(id){

    const button=document.getElementById(
        "add-"+encodeId(id)
    );

    try{
        const data=await api("/api/queue/add",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({id:id})
        });

        if(!data.ok){
            alert(data.message||"Unable to add song");
            return;
        }

        if(button){
            button.classList.add("added");
            button.textContent="✓";

            setTimeout(()=>{
                button.classList.remove("added");
                button.textContent="+";
            },800);
        }

    }catch(e){
        console.error(e);
        alert("Failed to add song");
    }
}

async function nextSong(){
    try{
        const data=await api(
            "/api/player/next",
            {method:"POST"}
        );

        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function previousSong(){
    try{
        const data=await api(
            "/api/player/previous",
            {method:"POST"}
        );

        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function togglePlay(){
    try{
        const data=await api(
            "/api/player/toggle",
            {method:"POST"}
        );

        if(!data.ok)return;

        serverPlaying=!!data.playing;
        updatePlayButton();

    }catch(e){
        console.error(e);
    }
}

function updatePlayButton(){
    document.getElementById("playButton").textContent=
        serverPlaying?"⏸":"▶";
}

async function syncPlayerState(){
    try{
        const data=await api("/api/player");

        if(typeof data.playing==="boolean"){
            serverPlaying=data.playing;
            updatePlayButton();
        }
    }catch(e){}
}

function encodeId(value){
    return btoa(
        unescape(
            encodeURIComponent(value)
        )
    ).replace(
        /[^a-zA-Z0-9]/g,
        ""
    );
}

function escapeHtml(value){
    return String(value||"")
        .replace(/&/g,"&amp;")
        .replace(/</g,"&lt;")
        .replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;")
        .replace(/'/g,"&#039;");
}

loadSongs();
syncPlayerState();

setInterval(loadSongs,30000);
setInterval(syncPlayerState,1000);
</script>

</body>
</html>
"""



class JukeboxHandler(BaseHTTPRequestHandler):

    server_version = "KaraokeJukebox/1.0"

    def log_message(self, fmt, *args):
        print("[HTTP]", self.address_string(), "-", fmt % args)

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def do_GET(self):
        global player_owner_last_seen

        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)

        if path == "/":
            self.redirect("/player")
            return

        if path == "/player":
            self.send_html(PLAYER_CLAIM_HTML)
            return

        if path == "/player-ui":
            token = get_player_token(self)
            if not token:
                token = urllib.parse.parse_qs(parsed.query).get("token", [None])[0]

            with player_lock:
                allowed = (
                    token
                    and token == player_owner_token
                    and time.time() - player_owner_last_seen <= PLAYER_LOCK_TIMEOUT
                )

            if not allowed:
                self.redirect("/remote")
                return

            self.send_html(PLAYER_HTML)
            return

        if path == "/remote":
            self.send_html(REMOTE_HTML)
            return

        if path == "/api/songs":
            with state_lock:
                result = [public_song(song) for song in songs]

            self.send_json({
                "ok": True,
                "count": len(result),
                "songs": result
            })
            return

        if path == "/api/queue":
            self.send_json({
                "ok": True,
                "queue": get_queue()
            })
            return

        if path == "/api/player":
            token = get_player_token(self)

            with player_lock:
                if token and token == player_owner_token:
                    player_owner_last_seen = time.time()

            self.send_json({
                "ok": True,
                "current": get_current_song(),
                "queue": get_queue(),
                "playing": player_playing
            })
            return

        if path == "/preview":
            self.serve_preview()
            return

        if path.startswith("/video/"):
            relative = path[len("/video/"):]
            self.serve_video(relative)
            return

        self.send_json({
            "ok": False,
            "error": "Not found"
        }, 404)

    def do_POST(self):
        global player_playing

        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except Exception:
            length = 0

        body = self.rfile.read(length) if length else b""

        try:
            data = json.loads(body.decode("utf-8")) if body else {}
        except Exception:
            data = {}

        if path == "/api/player/claim":
            token = get_player_token(self)

            if not token:
                self.send_json({
                    "ok": False,
                    "message": "Missing Player tab token"
                }, 400)
                return

            if acquire_player(token):
                self.send_json({"ok": True})
            else:
                self.send_json({
                    "ok": False,
                    "message": "Player is already in use",
                    "redirect": "/remote"
                })
            return

        if path == "/api/player/release":
            token = get_player_token(self)
            release_player(token)

            self.send_json({
                "ok": True
            })
            return

        if path == "/api/queue/add":
            song_id = data.get("id")

            if not isinstance(song_id, str):
                self.send_json({
                    "ok": False,
                    "message": "Invalid song ID"
                }, 400)
                return

            ok, message = add_to_queue(song_id)

            self.send_json({
                "ok": ok,
                "message": message,
                "queue": get_queue()
            })
            return

        if path == "/api/queue/remove":
            try:
                position = int(data.get("position"))
            except Exception:
                position = -1

            ok, message = remove_from_queue(position)

            self.send_json({
                "ok": ok,
                "message": message,
                "queue": get_queue()
            })
            return

        if path == "/api/queue/clear":
            clear_queue()
            self.send_json({
                "ok": True,
                "message": "Queue cleared"
            })
            return

        if path == "/api/player/next":
            next_song = start_next_song()

            if next_song is None:
                player_playing = False
                self.send_json({
                    "ok": False,
                    "message": "Queue is empty",
                    "current": None,
                    "queue": get_queue()
                })
                return

            player_playing = True

            self.send_json({
                "ok": True,
                "current": next_song,
                "queue": get_queue()
            })
            return

        if path == "/api/player/previous":
            previous_song = start_previous_song()

            if previous_song is None:
                self.send_json({
                    "ok": False,
                    "message": "Queue is empty"
                })
                return

            player_playing = True

            self.send_json({
                "ok": True,
                "current": previous_song,
                "queue": get_queue()
            })
            return

        if path == "/api/player/toggle":
            player_playing = not player_playing

            self.send_json({
                "ok": True,
                "playing": player_playing
            })
            return

        if path == "/api/player/set-playing":
            value = data.get("playing")

            if not isinstance(value, bool):
                self.send_json({
                    "ok": False,
                    "message": "Invalid playing value"
                }, 400)
                return

            player_playing = value

            self.send_json({
                "ok": True,
                "playing": player_playing
            })
            return

        if path == "/api/player/play":
            song_id = data.get("id")

            if not isinstance(song_id, str):
                self.send_json({
                    "ok": False,
                    "message": "Invalid song ID"
                }, 400)
                return

            if not set_current_song(song_id):
                self.send_json({
                    "ok": False,
                    "message": "Song not found"
                }, 404)
                return

            player_playing = True

            self.send_json({
                "ok": True,
                "current": get_current_song()
            })
            return

        self.send_json({
            "ok": False,
            "message": "Unknown endpoint"
        }, 404)

    def serve_preview(self):
        if not os.path.isfile(PREVIEW_IMAGE):
            self.send_error(404, "preview.jpg not found")
            return

        try:
            file_size = os.path.getsize(PREVIEW_IMAGE)
            content_type = mimetypes.guess_type(PREVIEW_IMAGE)[0] or "image/jpeg"

            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()

            self.copy_file(PREVIEW_IMAGE, 0, file_size)
        except OSError:
            self.send_error(404, "Preview unavailable")

    def serve_video(self, relative_path):
        relative_path = relative_path.replace("\\", "/")

        requested = os.path.normpath(
            os.path.join(KARAOKE_DIR, relative_path)
        )

        base = os.path.abspath(KARAOKE_DIR)
        requested_abs = os.path.abspath(requested)

        if not (
            requested_abs == base
            or requested_abs.startswith(base + os.sep)
        ):
            self.send_error(403, "Forbidden")
            return

        if not os.path.isfile(requested_abs):
            self.send_error(404, "Video not found")
            return

        try:
            file_size = os.path.getsize(requested_abs)
        except OSError:
            self.send_error(404, "File unavailable")
            return

        content_type = mimetypes.guess_type(requested_abs)[0] or "video/mp4"
        range_header = self.headers.get("Range")

        if not range_header:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.copy_file(requested_abs, 0, file_size)
            return

        try:
            range_value = range_header.split("=", 1)[1]
            start_text, end_text = range_value.split("-", 1)

            if start_text:
                start = int(start_text)
            else:
                suffix = int(end_text)
                start = max(file_size - suffix, 0)

            if end_text:
                end = int(end_text)
            else:
                end = file_size - 1

            if start < 0 or start >= file_size or end < start:
                raise ValueError

            end = min(end, file_size - 1)

        except Exception:
            self.send_response(416)
            self.send_header("Content-Range", "bytes */" + str(file_size))
            self.end_headers()
            return

        length = end - start + 1

        self.send_response(206)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header(
            "Content-Range",
            "bytes " + str(start) + "-" + str(end) + "/" + str(file_size)
        )
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        self.copy_file(requested_abs, start, length)

    def copy_file(self, path, start, length):
        try:
            with open(path, "rb") as file:
                file.seek(start)
                remaining = length

                while remaining > 0:
                    chunk = file.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break

                    self.wfile.write(chunk)
                    remaining -= len(chunk)

        except (BrokenPipeError, ConnectionResetError):
            pass



def get_local_ip():
    """Return the phone's actual LAN/Wi-Fi IP address."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No traffic needs to be sent; this selects the local interface.
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return "127.0.0.1"
    finally:
        sock.close()


def open_browser(url):
    """Open the Player URL using Android's default browser via Termux."""
    try:
        subprocess.Popen(
            ["termux-open-url", url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return True
    except Exception as e:
        print("BROWSER OPEN ERROR:", e)
        return False


def main():
    print()
    print("==========================================")
    print("       KARAOKE JUKEBOX SERVER")
    print("==========================================")
    print()
    print("KARAOKE FOLDER:")
    print(KARAOKE_DIR)
    print()

    os.makedirs(KARAOKE_DIR, exist_ok=True)

    print("Scanning karaoke files...")
    scan_songs()
    print("Songs found:", len(songs))
    print()

    scanner = threading.Thread(target=scanner_loop, daemon=True)
    scanner.start()

    server = ThreadingHTTPServer((HOST, PORT), JukeboxHandler)

    local_ip = get_local_ip()
    player_url = "http://" + local_ip + ":" + str(PORT) + "/player"
    remote_url = "http://" + local_ip + ":" + str(PORT) + "/remote"

    print("Server running...")
    print()
    print("PLAYER:")
    print(player_url)
    print()
    print("REMOTE:")
    print(remote_url)
    print()
    print("Opening Player in browser...")
    open_browser(player_url)
    print()
    print("Press CTRL+C to stop.")
    print("==========================================")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
        print("Stopping server...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
