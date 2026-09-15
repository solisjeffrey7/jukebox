#!/usr/bin/env python3

import os
import json
import time
import mimetypes
import threading
import urllib.parse
import socket
import subprocess
import zipfile
import argparse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

HOST = "0.0.0.0"
PORT = 8080
KARAOKE_DIR = os.path.expanduser("~/storage/shared/KARAOKE")
PREVIEW_IMAGE = os.path.expanduser("~/storage/shared/KARAOKE/preview.png")

VIDEO_EXTENSIONS = {".mp4", ".m4v", ".webm", ".mkv", ".mov", ".avi"}
ZIP_EXTENSIONS = {".zip"}
# ZIP archives are treated as virtual folders in the Remote UI.
SCAN_INTERVAL = 30
MAX_QUEUE = 100

state_lock = threading.RLock()
songs = []
song_map = {}
search_index = {}
queue = []
play_history = []
current_song_id = None
current_started_at = 0
player_playing = False
last_scan = 0

# Incremental filesystem index: unchanged folders are not re-parsed every scan.
scan_cache = {}
scan_cache_lock = threading.RLock()

# Version counters prevent the browser from rebuilding unchanged UI.
songs_version = 0
queue_version = 0
player_version = 0

# Fast persistent command channel for Remote PLAY IT NOW.
player_command_version = 0
player_command = None

player_lock = threading.Lock()
player_owner_token = None
player_owner_last_seen = 0
PLAYER_LOCK_TIMEOUT = 10


def make_song_id(relative_path):
    return relative_path.replace("\\", "/")


def parse_filename(filename):
    name = os.path.splitext(filename)[0].strip()
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


def scan_zip_songs(zip_path, relative_zip_path):
    """Index video files inside a ZIP without extracting them to disk."""
    result=[]
    try:
        with zipfile.ZipFile(zip_path,"r") as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue

                entry_name=info.filename.replace("\\","/").lstrip("/")
                if not entry_name or entry_name.startswith("../") or "/../" in entry_name:
                    continue

                ext=os.path.splitext(entry_name)[1].lower()
                if ext not in VIDEO_EXTENSIONS:
                    continue

                # Accept both STORED and normal compressed ZIP entries.
                # MP4 files are usually already compressed, but users may
                # create ZIPs with the normal ZIP command, so do not hide
                # those songs from the library. Playback is still streamed
                # directly from the ZIP without extracting the whole file.

                filename=os.path.basename(entry_name)
                code,title,artist=parse_filename(filename)
                virtual_path="@ZIP@/"+relative_zip_path+"::"+entry_name

                result.append({
                    "id":make_song_id(virtual_path),
                    "code":code,
                    "title":title,
                    "artist":artist,
                    "filename":filename,
                    "path":virtual_path,
                    "size":info.file_size,
                    "_search":(
                        code+" "+title+" "+artist+" "+filename
                    ).lower()
                })
    except (OSError,zipfile.BadZipFile,RuntimeError):
        return []

    result.sort(key=lambda x:x["id"].lower())
    return result


def song_folder_path(song):
    """Return the folder shown/used by the Remote UI. ZIP files appear as folders."""
    path=str(song.get("path","")).replace("\\","/")
    if path.startswith("@ZIP@/") and "::" in path:
        zip_rel=path[6:].split("::",1)[0]
        return "@ZIP@/"+zip_rel
    return os.path.dirname(path).replace("\\","/")


def scan_songs():
    global songs, song_map, last_scan, songs_version, scan_cache

    os.makedirs(KARAOKE_DIR, exist_ok=True)

    new_cache={}
    found=[]

    def scan_dir(directory, relative_dir=""):
        try:
            dir_stat=os.stat(directory)
            dir_mtime_ns=getattr(dir_stat,"st_mtime_ns",int(dir_stat.st_mtime*1e9))
        except OSError:
            return

        # Directory mtime changes when files are added/removed/renamed.
        # If unchanged, reuse the previously parsed entries for this directory.
        with scan_cache_lock:
            cached=scan_cache.get(relative_dir)

        if cached and cached.get("mtime_ns")==dir_mtime_ns:
            new_cache[relative_dir]=cached
            found.extend(cached["songs"])
            for subdir in cached.get("subdirs",[]):
                sub_path=os.path.join(directory,subdir)
                sub_rel=os.path.join(relative_dir,subdir).replace("\\","/")
                scan_dir(sub_path,sub_rel)
            return

        directory_songs=[]
        subdirs=[]

        try:
            entries=list(os.scandir(directory))
        except OSError:
            return

        for entry in entries:
            name=entry.name

            if name.startswith("."):
                continue

            try:
                if entry.is_dir(follow_symlinks=False):
                    subdirs.append(name)
                    continue

                if not entry.is_file(follow_symlinks=False):
                    continue
            except OSError:
                continue

            ext=os.path.splitext(name)[1].lower()

            if ext in ZIP_EXTENSIONS:
                try:
                    zip_stat=entry.stat(follow_symlinks=False)
                    zip_songs=scan_zip_songs(
                        entry.path,
                        os.path.join(relative_dir,name).replace("\\","/")
                    )
                    directory_songs.extend(zip_songs)
                except OSError:
                    pass
                continue

            if ext not in VIDEO_EXTENSIONS:
                continue

            full_path=entry.path

            try:
                rel_path=os.path.relpath(
                    full_path,KARAOKE_DIR
                ).replace("\\","/")
                size=entry.stat(follow_symlinks=False).st_size
            except OSError:
                continue

            code,title,artist=parse_filename(name)

            song={
                "id":make_song_id(rel_path),
                "code":code,
                "title":title,
                "artist":artist,
                "filename":name,
                "path":rel_path,
                "size":size,
                "_search":(
                    code+" "+title+" "+artist+" "+name
                ).lower()
            }
            directory_songs.append(song)

        directory_songs.sort(key=lambda x:x["id"].lower())

        record={
            "mtime_ns":dir_mtime_ns,
            "songs":directory_songs,
            "subdirs":sorted(subdirs,key=str.lower)
        }

        with scan_cache_lock:
            new_cache[relative_dir]=record

        found.extend(directory_songs)

        for subdir in record["subdirs"]:
            sub_path=os.path.join(directory,subdir)
            sub_rel=os.path.join(relative_dir,subdir).replace("\\","/")
            scan_dir(sub_path,sub_rel)

    scan_dir(KARAOKE_DIR)

    found.sort(key=lambda x:(
        int(x["code"]) if x["code"].isdigit() else 999999999,
        x["title"].lower()
    ))

    # Don't expose the internal search field to the client.
    for song in found:
        song.pop("_search",None)

    with scan_cache_lock:
        scan_cache=new_cache

    with state_lock:
        old_signature=[(x["id"],x["size"]) for x in songs]
        new_signature=[(x["id"],x["size"]) for x in found]

        songs=found
        song_map={song["id"]:song for song in found}

        if old_signature!=new_signature:
            songs_version+=1

        last_scan=time.time()

def scanner_loop():
    while True:
        try:
            scan_songs()
        except Exception as e:
            print("SCAN ERROR:", e)
        time.sleep(SCAN_INTERVAL)


def search_blob(song):
    return (
        str(song.get("code",""))+" "+
        str(song.get("title",""))+" "+
        str(song.get("artist",""))+" "+
        str(song.get("filename",""))
    ).lower()

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
    global queue_version, player_version

    with state_lock:
        if song_id not in song_map:
            return False, "Song not found"

        if len(queue) >= MAX_QUEUE:
            return False, "Queue is full"

        queue.append(song_id)
        queue_version += 1
        player_version += 1
        return True, "Added to queue"


def remove_from_queue(position):
    global queue_version, player_version

    with state_lock:
        if position < 0 or position >= len(queue):
            return False, "Invalid queue position"

        queue.pop(position)
        queue_version += 1
        player_version += 1
        return True, "Removed"


def clear_queue():
    global queue_version, player_version

    with state_lock:
        queue.clear()
        play_history.clear()
        queue_version += 1
        player_version += 1


def get_current_song():
    with state_lock:
        if current_song_id:
            return public_song(song_map.get(current_song_id))
    return None


def set_current_song(song_id):
    global current_song_id, current_started_at
    global player_playing, player_version, queue_version
    global player_command_version, player_command

    with state_lock:
        if song_id not in song_map:
            return False

        # PLAY IT NOW removes the selected song from the queue
        # if it is already there, preventing an immediate duplicate.
        try:
            queue.remove(song_id)
            queue_version += 1
        except ValueError:
            pass

        current_song_id = song_id
        current_started_at = time.time()
        player_playing = True
        player_version += 1

        # Publish a new command every time PLAY IT NOW is requested.
        player_command_version += 1
        player_command = {
            "type": "play",
            "version": player_command_version,
            "song": public_song(song_map[song_id])
        }

        return True


def start_next_song():
    global current_song_id, current_started_at
    global player_playing, queue_version, player_version

    with state_lock:
        while queue:
            next_id = queue.pop(0)
            queue_version += 1

            if next_id not in song_map:
                continue

            if current_song_id and current_song_id in song_map:
                if current_song_id != next_id:
                    play_history.append(current_song_id)

            current_song_id = next_id
            current_started_at = time.time()
            player_playing = True
            player_version += 1
            return public_song(song_map[next_id])

        current_song_id = None
        current_started_at = 0
        player_playing = False
        player_version += 1
        return None


def start_previous_song():
    global current_song_id, current_started_at
    global player_playing, queue_version, player_version

    with state_lock:
        if not play_history:
            return None

        previous_id = play_history.pop()

        if current_song_id and current_song_id in song_map:
            queue.insert(0, current_song_id)
            queue_version += 1

        if previous_id not in song_map:
            return None

        current_song_id = previous_id
        current_started_at = time.time()
        player_playing = True
        player_version += 1
        return public_song(song_map[previous_id])


def toggle_playing():
    global player_playing, player_version

    with state_lock:
        player_playing = not player_playing
        player_version += 1
        return player_playing


def set_playing(value):
    global player_playing, player_version

    with state_lock:
        if player_playing != value:
            player_playing = value
            player_version += 1
        return player_playing


def get_player_token(handler):
    return handler.headers.get("X-Jukebox-Player-Token")


def acquire_player(token):
    global player_owner_token, player_owner_last_seen

    if not token:
        return False

    now = time.time()

    with player_lock:
        if (
            player_owner_token
            and now - player_owner_last_seen <= PLAYER_LOCK_TIMEOUT
        ):
            if token == player_owner_token:
                player_owner_last_seen = now
                return True
            return False

        player_owner_token = token
        player_owner_last_seen = now
        return True


def touch_player(token):
    global player_owner_last_seen

    if not token:
        return False

    with player_lock:
        if token == player_owner_token:
            player_owner_last_seen = time.time()
            return True

    return False


def release_player(token):
    global player_owner_token, player_owner_last_seen

    with player_lock:
        if token and token == player_owner_token:
            player_owner_token = None
            player_owner_last_seen = 0


def player_is_owner(token):
    if not token:
        return False

    with player_lock:
        return (
            token == player_owner_token
            and time.time() - player_owner_last_seen <= PLAYER_LOCK_TIMEOUT
        )


# =========================================================
# PLAYER HTML
# =========================================================

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
body{min-height:100vh;height:100vh;overflow:hidden}
.header{height:58px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#111;border-bottom:1px solid #292929}
.logo{font-size:20px;font-weight:800;letter-spacing:1px}
.header-right{display:flex;align-items:center;gap:12px}
.remote-link{color:#fff;text-decoration:none;background:#222;border:1px solid #3a3a3a;padding:8px 13px;border-radius:7px;font-size:12px}
.player-layout{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:14px;padding:14px;min-height:calc(100vh - 58px)}
.video-side{min-width:0}
.video-wrapper{position:relative;width:100%;background:#000;aspect-ratio:16/9;overflow:hidden}
video{display:none;width:100%;height:100%;background:#000;object-fit:contain}
.preview-image{display:block;width:100%;height:100%;background:#000;object-fit:contain}
.video-wrapper.has-video video{display:block}
.video-wrapper.has-video .preview-image{display:none}
.normal-remote-qr{width:100%;min-height:58px;margin-bottom:8px;padding:6px 10px;display:flex;align-items:center;gap:10px;background:#111;border:1px solid #292929;border-radius:8px}
.normal-remote-qr img{display:block;width:46px;height:46px;background:#fff;border-radius:3px;flex:0 0 46px}
.video-qr-label{color:#fff;font-size:10px;line-height:1.3;text-align:left;font-weight:700}
.video-qr-label span{color:#aaa;font-weight:500}
.fullscreen-remote-qr{display:none}
.fullscreen-remote-qr img{display:block;width:52px;height:52px;background:#fff}
.fullscreen-button{position:absolute;right:14px;bottom:12px;z-index:30;background:rgba(0,0,0,.72);color:#fff;border:1px solid rgba(255,255,255,.25);border-radius:5px;width:42px;height:34px;padding:0;font-size:17px}
.now-playing{padding:12px 0;border-bottom:1px solid #292929}
.now-label{color:#999;font-size:11px;text-transform:uppercase;letter-spacing:1px}
.now-title{font-size:22px;font-weight:800;margin-top:4px}
.now-artist{color:#aaa;margin-top:3px}
.controls{display:flex;gap:8px;padding:12px 0}
.controls button{flex:1;border:0;background:#242424;color:#fff;padding:10px 15px;border-radius:6px;cursor:pointer;font-weight:700}
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
.player-layout.is-fullscreen{position:fixed;inset:0;z-index:99999;width:100vw;height:100vh;margin:0;padding:14px;background:#090909;display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:14px;overflow:hidden}
.player-layout.is-fullscreen .video-side{min-width:0;min-height:0;display:flex;flex-direction:column}
.player-layout.is-fullscreen .video-wrapper{flex:1;width:100%;height:auto;aspect-ratio:auto;min-height:0}
.player-layout.is-fullscreen video,.player-layout.is-fullscreen .preview-image{width:100%;height:100%;object-fit:contain}
.player-layout.is-fullscreen .queue-side{height:100%;max-height:none;overflow:hidden}
.player-layout.is-fullscreen .queue-list{max-height:none;overflow-y:auto}
.player-layout.is-fullscreen .fullscreen-remote-qr{display:block;position:absolute;top:10px;right:10px;z-index:30;width:58px;height:58px;padding:3px;background:rgba(0,0,0,.55);border-radius:5px}
@media(max-width:850px){
.video-wrapper.is-fullscreen{position:fixed;inset:0;z-index:99999;width:100vw;height:100vh;aspect-ratio:auto;margin:0}
.video-wrapper.is-fullscreen video,.video-wrapper.is-fullscreen .preview-image{width:100%;height:100%;object-fit:contain}
.video-wrapper.is-fullscreen .fullscreen-remote-qr{display:block;position:absolute;top:10px;right:10px;z-index:30;width:58px;height:58px;padding:3px;background:rgba(0,0,0,.55);border-radius:5px}
.video-wrapper.is-fullscreen .fullscreen-button{bottom:18px}
.player-layout{display:flex;flex-direction:column;gap:0;padding:10px}
.queue-side{width:100%;border-left:0;border-top:1px solid #292929;padding-left:0;padding-top:14px;margin-top:5px}
.queue-list{flex:none;height:220px;max-height:220px}
.now-title{font-size:18px}
.remote-link{padding:7px 10px;font-size:11px}
}
@media(max-width:600px){.header{padding:0 10px}.logo{font-size:16px}}
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

<button id="fullscreenButton" class="fullscreen-button" onclick="toggleFullscreen()">⛶</button>
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
let lastPlayerVersion=-1;
let lastQueueKey="";
let lastCommandVersion=0;
let commandPollRunning=false;
let playerUpdateInFlight=false;

const video=document.getElementById("video");
const videoWrapper=document.getElementById("videoWrapper");
const playerLayout=document.querySelector(".player-layout");
const playerToken=sessionStorage.getItem("jukebox_player_tab_token");

function setRemoteQr(){
    const url=window.location.origin+"/remote";
    const qr="https://api.qrserver.com/v1/create-qr-code/?size=180x180&margin=0&data="+encodeURIComponent(url);
    document.getElementById("videoQr").src=qr;
    document.getElementById("fullscreenQr").src=qr;
}

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
    if(playerUpdateInFlight)return;
    playerUpdateInFlight=true;

    try{
        const data=await api("/api/player");

        // UI/state changes are processed only when the server version changes.
        if(data.version!==lastPlayerVersion){
            lastPlayerVersion=data.version;

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
                    video.pause();
                    video.removeAttribute("src");
                    video.load();
                    videoWrapper.classList.remove("has-video");
                }
            }
        }

        // Queue is rebuilt only if its IDs/order changed.
        const queue=data.queue||[];
        const queueKey=queue.map(song=>song.id).join("|");

        if(queueKey!==lastQueueKey){
            lastQueueKey=queueKey;
            renderQueue(queue);
        }
    }catch(e){
        console.error("Player update:",e);
    }finally{
        playerUpdateInFlight=false;
    }
}

async function checkPlayerCommand(){
    try{
        const data=await api("/api/player-command");
        const cmd=data && data.command;

        if(!cmd || cmd.type!=="play" || !cmd.song)return;

        const version=Number(cmd.version||0);
        if(version<=lastCommandVersion)return;

        lastCommandVersion=version;

        const song=cmd.song;
        remoteCommand=true;

        document.getElementById("nowTitle").textContent=
            (song.code||"")+" - "+(song.title||"");
        document.getElementById("nowArtist").textContent=
            song.artist||"Unknown artist";

        currentSongId=song.id;

        const url="/video/"+song.path.split("/")
            .map(part=>encodeURIComponent(part))
            .join("/");

        loadingVideo=true;
        video.pause();
        video.src=url;
        video.load();
        videoWrapper.classList.add("has-video");

        const start=()=>{
            video.play().catch(()=>{});
            loadingVideo=false;
        };

        if(video.readyState>=2){
            start();
        }else{
            video.addEventListener("loadeddata",start,{once:true});
            setTimeout(()=>{loadingVideo=false;},1000);
        }

        setTimeout(()=>{remoteCommand=false;},700);
    }catch(e){}
}

function startPlayerCommandPoll(){
    if(commandPollRunning)return;
    commandPollRunning=true;

    const tick=async()=>{
        if(!document.hidden){
            const started=performance.now();
            await checkPlayerCommand();
            const elapsed=performance.now()-started;
            // Fast after activity, lighter traffic while idle.
            const delay=elapsed>120 ? 40 : 120;
            setTimeout(tick,delay);
            return;
        }
        setTimeout(tick,1500);
    };

    tick();
}

function loadVideo(song){
    if(loadingVideo)return;

    loadingVideo=true;

    const url="/video/"+song.path.split("/")
        .map(part=>encodeURIComponent(part))
        .join("/");

    video.pause();
    video.src=url;
    video.load();
    videoWrapper.classList.add("has-video");
    video.play().catch(()=>{});

    setTimeout(()=>{loadingVideo=false;},300);
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

        const data=await api("/api/player/toggle",{method:"POST"});

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
        setTimeout(()=>{remoteCommand=false;},400);
    }
}

async function nextSong(){
    try{
        const data=await api("/api/player/next",{method:"POST"});
        if(!data.ok)return;

        currentSongId=null;
        lastPlayerVersion=-1;
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
        lastPlayerVersion=-1;
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
            <button class="remove-button"
                    onclick="removeQueue(${index})">
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

        lastPlayerVersion=-1;
        await updatePlayer();
    }catch(e){
        console.error(e);
    }
}

async function toggleFullscreen(){
    try{
        if(document.fullscreenElement){
            await document.exitFullscreen();
        }else if(window.innerWidth<=850){
            await videoWrapper.requestFullscreen();
        }else{
            await playerLayout.requestFullscreen();
        }
    }catch(e){
        if(window.innerWidth<=850){
            videoWrapper.classList.toggle("is-fullscreen");
        }else{
            playerLayout.classList.toggle("is-fullscreen");
        }
    }
}

document.addEventListener("fullscreenchange",()=>{
    if(document.fullscreenElement===playerLayout){
        playerLayout.classList.add("is-fullscreen");
        videoWrapper.classList.remove("is-fullscreen");
    }else if(document.fullscreenElement===videoWrapper){
        videoWrapper.classList.add("is-fullscreen");
        playerLayout.classList.remove("is-fullscreen");
    }else{
        playerLayout.classList.remove("is-fullscreen");
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
startPlayerCommandPoll();

// Keep normal state synchronization as fallback.
setInterval(updatePlayer,2000);
</script>
</body>
</html>
"""


# =========================================================
# PLAYER CLAIM
# =========================================================

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
</style>
</head>
<body>
<div id="msg">Connecting to Karaoke Player...</div>
<script>
(async()=>{
    const KEY="jukebox_player_tab_token";
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
        document.getElementById("msg").textContent=
            "Unable to connect to Player";
    }
})();
</script>
</body>
</html>
"""


# =========================================================
# REMOTE HTML
# =========================================================

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
.remote-layout{
display:grid;
grid-template-columns:260px minmax(0,1fr);
height:calc(100vh - 58px);
min-height:0;
overflow:hidden
}
.folder-panel{
border-right:1px solid #292929;
background:#0d0d0d;
min-width:0;
min-height:0;
height:100%;
display:flex;
flex-direction:column;
overflow:hidden
}
.folder-header{
flex:0 0 auto;
padding:14px;
border-bottom:1px solid #292929;
font-weight:800
}
.folder-list{
overflow-y:auto;
height:calc(100% - 48px);
max-height:none;
-webkit-overflow-scrolling:touch;
overscroll-behavior:contain
}
.folder{width:100%;display:flex;align-items:center;gap:9px;padding:12px 14px;border:0;border-radius:0;background:transparent;color:#fff;text-align:left;font-weight:600;cursor:pointer}
.folder:hover{background:#1b1b1b}
.folder.active{background:#252525}
.folder-icon{font-size:18px;width:22px;text-align:center}
.folder-name{min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.song-panel{
min-width:0;
min-height:0;
height:100%;
display:flex;
flex-direction:column;
overflow:hidden
}
.song-header{
flex:0 0 auto;
position:relative;
z-index:8;
padding:14px;
border-bottom:1px solid #292929;
background:#090909
}
.song-header-row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.song-header h2{margin:0;font-size:18px;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.song-count{color:#888;font-size:12px;white-space:nowrap}
.search{width:100%;padding:12px;background:#171717;color:#fff;border:1px solid #333;border-radius:7px;outline:none;font-size:15px}
.song-list{
overflow-y:auto;
overflow-x:hidden;
flex:1 1 auto;
min-height:0;
height:0;
-webkit-overflow-scrolling:touch;
overscroll-behavior:contain
}
.song{display:grid;grid-template-columns:60px minmax(0,1fr) 48px;gap:10px;align-items:center;padding:12px 14px;border-bottom:1px solid #222;cursor:pointer}
.song:hover{background:#151515}
.code{color:#777;font-family:monospace;font-size:13px}
.info{min-width:0}
.title{font-size:15px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.artist{color:#888;font-size:12px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.add{width:42px;height:42px;border:0;border-radius:50%;background:#fff;color:#000;font-size:24px;font-weight:700;cursor:pointer;position:relative;z-index:2}
.added{background:#444;color:#fff}
.status{padding:8px 14px;color:#777;font-size:11px;border-top:1px solid #222}
.load-sentinel{user-select:none;pointer-events:none}
.empty{text-align:center;padding:40px 10px;color:#777}
.load-more{display:block;width:calc(100% - 28px);margin:12px auto 20px;padding:13px 14px;border:1px solid #3a3a3a;border-radius:9px;background:#1b1b1b;color:#fff;font-size:12px;font-weight:800;letter-spacing:.5px;cursor:pointer}
.load-more:hover{background:#292929}
.load-more:active{transform:scale(.99)}
.connection-lost{color:#fff!important;background:#351717}
.connection-status{display:inline-flex;align-items:center;gap:6px;min-height:28px;padding:0 9px;border:1px solid #303030;border-radius:999px;background:#171717;color:#aaa;font-size:10px;font-weight:800;letter-spacing:.4px;white-space:nowrap}
.connection-dot{width:8px;height:8px;border-radius:50%;background:#777;flex:0 0 8px}
.connection-status.connected{color:#fff;background:#152015}
.connection-status.connected .connection-dot{background:#58d26b}
.connection-status.offline{color:#fff;background:#351717}
.connection-status.offline .connection-dot{background:#ff4d4d}
.connection-status.reconnecting{color:#fff;background:#302b16}
.connection-status.reconnecting .connection-dot{background:#e7c84b}

.song-action-overlay{position:fixed;inset:0;z-index:99999;display:flex;justify-content:center;align-items:center;padding:14px;background:rgba(0,0,0,.72);backdrop-filter:blur(4px)}
.song-action-card{width:min(520px,100%);padding:18px;background:#151515;color:#fff;border:1px solid #333;border-radius:16px;box-shadow:0 12px 40px rgba(0,0,0,.65)}
.song-action-card h2{margin:0 0 12px;font-size:21px;line-height:1.2}
.song-action-song{margin:0 0 14px;padding:11px 12px;background:#202020;border:1px solid #2d2d2d;border-radius:11px}
.song-action-title{font-size:16px;font-weight:700;line-height:1.3;word-break:break-word}
.song-action-artist{margin-top:3px;color:#aaa;font-size:13px;line-height:1.3;word-break:break-word}
.song-action-buttons{display:grid;grid-template-columns:1fr 1fr;gap:9px}
.song-action-buttons button,.song-action-cancel{min-height:44px;border-radius:10px;padding:10px 12px;font-size:14px;font-weight:700;cursor:pointer}
.song-action-play{border:1px solid #fff;background:#fff;color:#111}
.song-action-queue{border:1px solid #444!important;background:#303030;color:#fff}
.song-action-cancel{width:100%;margin-top:9px;border:1px solid #3a3a3a!important;background:#191919;color:#aaa}

@media(max-width:700px){
.remote-layout{
grid-template-columns:145px minmax(0,1fr);
height:calc(100vh - 58px);
min-height:0
}
.folder-panel{height:100%;min-height:0}
.song-panel{height:100%;min-height:0}
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
.remote-layout{grid-template-columns:125px minmax(0,1fr);height:calc(100vh - 58px)}
.folder{padding-left:7px;padding-right:5px}
.song{grid-template-columns:44px minmax(0,1fr) 40px}
.header-right{gap:3px}
.control{min-width:30px;padding:0 3px}
.player-link{display:none}
}
@media(max-width:380px){
.song-action-buttons{grid-template-columns:1fr}
}
</style>
</head>
<body>

<header class="header">
<div class="logo">KARAOKE REMOTE</div>
<div class="header-right">
<div id="connectionStatus" class="connection-status reconnecting"><span class="connection-dot"></span><span id="connectionText">RECONNECTING</span></div>
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
<input id="search" class="search" type="search"
       placeholder="Search song number, title or artist..."
       autocomplete="off">
</div>

<div id="songList" class="song-list"></div>
<div id="status" class="status">Loading songs...</div>
</main>
</div>

<script>
let songs=[];
let selectedFolder="";
let serverPlaying=false;
let songDisplayLimit=50;
let totalSongs=0;
let songsOffset=0;
let loadingMoreSongs=false;
let hasMoreSongs=true;
let lastSongsRequestKey="";
let searchTimer=null;
let refreshInFlight=false;

let connectionFailCount=0;
let statusPollInFlight=false;
let reconnectInFlight=false;

async function api(url,options={},retries=2){
    let lastError;

    for(let attempt=0;attempt<=retries;attempt++){
        const controller=new AbortController();
        const timeout=setTimeout(()=>controller.abort(),8000);

        try{
            const response=await fetch(url,{
                cache:"no-store",
                ...options,
                signal:controller.signal
            });

            clearTimeout(timeout);

            if(!response.ok){
                throw new Error(await response.text());
            }

            connectionFailCount=0;
            setConnectionStatus(true);
            return response.json();
        }catch(e){
            clearTimeout(timeout);
            lastError=e;

            if(attempt<retries){
                await new Promise(resolve=>setTimeout(resolve,
                    300*(attempt+1)
                ));
            }
        }
    }

    connectionFailCount++;
    setConnectionStatus(false);
    throw lastError||new Error("Connection failed");
}

function setConnectionStatus(online){
    const status=document.getElementById("status");
    const badge=document.getElementById("connectionStatus");
    const text=document.getElementById("connectionText");

    if(!online){
        if(status){
            status.textContent="⚠ CONNECTION LOST — reconnecting...";
            status.classList.add("connection-lost");
        }
        if(badge)badge.className="connection-status offline";
        if(text)text.textContent="OFFLINE";
        return;
    }

    if(status)status.classList.remove("connection-lost");
    if(badge)badge.className="connection-status connected";
    if(text)text.textContent="CONNECTED";
}

function setReconnecting(){
    const badge=document.getElementById("connectionStatus");
    const text=document.getElementById("connectionText");
    if(badge)badge.className="connection-status reconnecting";
    if(text)text.textContent="RECONNECTING";
}

async function checkConnection(){
    if(statusPollInFlight)return;
    statusPollInFlight=true;

    try{
        const data=await api("/api/connection-status",{},0);
        if(data && data.ok){
            setConnectionStatus(true);
        }else{
            setConnectionStatus(false);
        }
    }catch(e){
        setConnectionStatus(false);
    }finally{
        statusPollInFlight=false;
    }
}

async function recoverConnection(){
    if(reconnectInFlight)return;
    reconnectInFlight=true;
    setReconnecting();

    try{
        await api("/api/connection-status",{},0);
        setConnectionStatus(true);

        // Restore the current remote state after Wi-Fi/browser sleep.
        await Promise.allSettled([
            loadSongs(true),
            syncPlayerState()
        ]);
    }catch(e){
        setConnectionStatus(false);
    }finally{
        reconnectInFlight=false;
    }
}

window.addEventListener("online",recoverConnection);
window.addEventListener("offline",()=>setConnectionStatus(false));

document.addEventListener("visibilitychange",()=>{
    if(!document.hidden){
        recoverConnection();
    }
});

async function loadSongs(reset=true){
    const search=document.getElementById("search").value.trim();
    const offset=reset ? 0 : songsOffset;
    const key=selectedFolder+"|"+search+"|"+offset;

    if(!reset && offset===0 && key===lastSongsRequestKey)return;

    if(reset){
        songsOffset=0;
        hasMoreSongs=true;
        songs=[];
        document.getElementById("songList").innerHTML="";
    }

    try{
        const params=new URLSearchParams({
            offset:String(offset),
            limit:"50",
            folder:selectedFolder,
            search:search
        });

        const data=await api("/api/songs?"+params.toString());

        if(reset){
            songs=[];
        }

        const incoming=data.songs||[];
        const existing=new Set(songs.map(song=>song.id));

        for(const song of incoming){
            if(!existing.has(song.id)){
                songs.push(song);
            }
        }

        songsOffset=songs.length;
        totalSongs=Number(data.count||0);
        hasMoreSongs=!!data.has_more;
        lastSongsRequestKey=key;

        renderFolders(data.folders||[]);
        renderSongs(false);
        setConnectionStatus(true);

    }catch(e){
        console.error(e);
        setConnectionStatus(false);

        if(reset){
            document.getElementById("status").textContent=
                "Failed to load songs — retrying...";
        }
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
        a.localeCompare(b,undefined,{numeric:true,sensitivity:"base"})
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

function renderFolders(folderData=[]){
    const container=document.getElementById("folderList");
    container.innerHTML="";

    const all=document.createElement("button");
    all.className="folder"+(selectedFolder===""?" active":"");
    all.innerHTML=`
        <span class="folder-icon">🏠</span>
        <span class="folder-name">ALL SONGS (${totalSongs})</span>
    `;

    all.onclick=()=>{
        selectedFolder="";
        document.getElementById("search").value="";
        songs=[];
        songsOffset=0;
        totalSongs=0;
        hasMoreSongs=true;
        lastSongsRequestKey="";
        renderFolders([]);
        loadSongs(true);
    };

    container.appendChild(all);

    for(const item of folderData){
        const folder=item.path;
        const count=Number(item.count||0);

        const button=document.createElement("button");
        button.className="folder"+(selectedFolder===folder?" active":"");

        button.innerHTML=`
            <span class="folder-icon">📁</span>
            <span class="folder-name">
                ${escapeHtml(folderName(folder))} (${count})
            </span>
        `;

        button.onclick=()=>{
            selectedFolder=folder;
            document.getElementById("search").value="";
            songs=[];
            songsOffset=0;
            totalSongs=0;
            hasMoreSongs=true;
            lastSongsRequestKey="";
            renderFolders([]);
            loadSongs(true);
        };

        container.appendChild(button);
    }
}

document.getElementById("search")
    .addEventListener("input",()=>{
        clearTimeout(searchTimer);
        searchTimer=setTimeout(()=>{
            songs=[];
            songsOffset=0;
            totalSongs=0;
            hasMoreSongs=true;
            lastSongsRequestKey="";
            loadSongs(true);
        },250);
    });

function renderSongs(clear=true){
    const container=document.getElementById("songList");

    if(clear) container.innerHTML="";

    document.getElementById("folderTitle").textContent=
        selectedFolder ? folderName(selectedFolder) : "ALL SONGS";

    document.getElementById("songCount").textContent=
        songs.length+" / "+totalSongs+" songs";

    if(!songs.length){
        container.innerHTML='<div class="empty">No songs found</div>';
        return;
    }

    const existingIds=new Set(
        Array.from(container.querySelectorAll(".song"))
            .map(row=>row.dataset.songId)
    );

    for(const song of songs){
        if(existingIds.has(song.id)) continue;

        const row=document.createElement("div");
        row.className="song";
        row.dataset.songId=song.id;

        row.onclick=()=>showSongActionPrompt(song);

        row.innerHTML=`
            <div class="code">${escapeHtml(song.code)}</div>
            <div class="info">
                <div class="title">${escapeHtml(song.title)}</div>
                <div class="artist">${escapeHtml(song.artist)}</div>
            </div>
            <button class="add" title="Add to queue">+</button>
        `;

        const addButton=row.querySelector(".add");
        addButton.onclick=(event)=>{
            event.stopPropagation();
            addSong(song.id,addButton);
        };

        container.appendChild(row);
    }

    const oldSentinel=container.querySelector(".load-sentinel");
    if(oldSentinel) oldSentinel.remove();

    if(hasMoreSongs){
        const sentinel=document.createElement("div");
        sentinel.className="load-sentinel";
        sentinel.textContent="Scroll for more...";
        sentinel.style.cssText=
            "padding:14px;text-align:center;color:#777;font-size:11px;";
        container.appendChild(sentinel);
    }

    document.getElementById("status").textContent=
        hasMoreSongs
            ? songs.length+" of "+totalSongs+" songs loaded"
            : totalSongs+" songs loaded";

    document.getElementById("status").classList.remove("connection-lost");

    requestAnimationFrame(checkSongScroll);
}

async function loadMoreSongs(){
    if(loadingMoreSongs || !hasMoreSongs)return;

    loadingMoreSongs=true;

    const sentinel=document.querySelector(".load-sentinel");
    if(sentinel) sentinel.textContent="Loading more songs...";

    try{
        await loadSongs(false);
    }catch(e){
        console.error("Load more:",e);
    }finally{
        loadingMoreSongs=false;

        const currentSentinel=document.querySelector(".load-sentinel");
        if(currentSentinel && hasMoreSongs){
            currentSentinel.textContent="Scroll for more...";
        }
    }
}

let songScrollTick=false;

function checkSongScroll(){
    const container=document.getElementById("songList");
    if(!container || loadingMoreSongs || !hasMoreSongs)return;

    const remaining=
        container.scrollHeight -
        container.scrollTop -
        container.clientHeight;

    if(remaining<=500){
        loadMoreSongs();
    }
}

function closeSongActionPrompt(){
    const overlay=document.getElementById("songActionOverlay");
    if(overlay)overlay.remove();
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

async function addSong(id,button=null){
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
        const data=await api("/api/player/next",{method:"POST"});
        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function previousSong(){
    try{
        const data=await api("/api/player/previous",{method:"POST"});
        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function togglePlay(){
    try{
        const data=await api("/api/player/toggle",{method:"POST"});
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

function escapeHtml(value){
    return String(value||"")
        .replace(/&/g,"&amp;")
        .replace(/</g,"&lt;")
        .replace(/>/g,"&gt;")
        .replace(/"/g,"&quot;")
        .replace(/'/g,"&#039;");
}

const songList=document.getElementById("songList");

songList.addEventListener("scroll",()=>{
    if(songScrollTick)return;

    songScrollTick=true;

    requestAnimationFrame(()=>{
        songScrollTick=false;
        checkSongScroll();
    });
},{passive:true});

loadSongs(true);
syncPlayerState();

async function refreshFirstBatch(){
    if(refreshInFlight)return;
    refreshInFlight=true;

    try{
        const search=document.getElementById("search").value.trim();

        const params=new URLSearchParams({
            offset:"0",
            limit:"50",
            folder:selectedFolder,
            search:search
        });

        const data=await api("/api/songs?"+params.toString());
        const first=data.songs||[];

        // Keep already-loaded pages; update only the first 50 entries.
        const rest=songs.slice(50);
        const merged=[];
        const seen=new Set();

        for(const song of [...first,...rest]){
            if(!seen.has(song.id)){
                seen.add(song.id);
                merged.push(song);
            }
        }

        songs=merged;
        totalSongs=Number(data.count||0);
        hasMoreSongs=!!data.has_more || songs.length<totalSongs;

        renderFolders(data.folders||[]);
        renderSongs(true);
    }catch(e){
        console.error("Library refresh:",e);
    }finally{
        refreshInFlight=false;
    }
}

setInterval(refreshFirstBatch,30000);
setInterval(syncPlayerState,4000);
setInterval(checkConnection,5000);
checkConnection();
</script>
</body>
</html>
"""


# =========================================================
# HTTP SERVER
# =========================================================

class JukeboxHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


class JukeboxHandler(BaseHTTPRequestHandler):

    server_version = "KaraokeJukebox/2.0-ZIP-FIXED"
    timeout = 15

    def setup(self):
        super().setup()
        try:
            self.connection.settimeout(30)
        except Exception:
            pass

    def log_message(self, fmt, *args):
        print("[HTTP]", self.address_string(), "-", fmt % args)

    def send_json(self, data, status=200):
        body=json.dumps(
            data,
            ensure_ascii=False,
            separators=(",", ":")
        ).encode("utf-8")

        self.send_response(status)
        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8"
        )
        self.send_header(
            "Content-Length",
            str(len(body))
        )
        self.send_header("Cache-Control","no-store")
        self.send_header("Connection","close")
        self.end_headers()

        try:
            self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError,socket.timeout):
            pass

    def send_html(self, html):
        body=html.encode("utf-8")

        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/html; charset=utf-8"
        )
        self.send_header(
            "Content-Length",
            str(len(body))
        )
        self.send_header("Cache-Control","no-store")
        self.send_header("Connection","close")
        self.end_headers()

        try:
            self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError,socket.timeout):
            pass

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location",location)
        self.send_header("Cache-Control","no-store")
        self.send_header("Connection","close")
        self.end_headers()

    def do_GET(self):

        parsed=urllib.parse.urlparse(self.path)
        path=urllib.parse.unquote(parsed.path)

        if path=="/":
            self.redirect("/player")
            return

        if path=="/player":
            self.send_html(PLAYER_CLAIM_HTML)
            return

        if path=="/player-ui":
            token=get_player_token(self)

            if not token:
                token=urllib.parse.parse_qs(
                    parsed.query
                ).get("token",[None])[0]

            if not player_is_owner(token):
                self.redirect("/remote")
                return

            self.send_html(PLAYER_HTML)
            return

        if path=="/remote":
            self.send_html(REMOTE_HTML)
            return

        if path=="/api/songs":
            query=urllib.parse.parse_qs(parsed.query)

            try:
                offset=max(0,int(query.get("offset",["0"])[0]))
            except Exception:
                offset=0

            try:
                limit=int(query.get("limit",["50"])[0])
            except Exception:
                limit=50

            limit=max(1,min(limit,100))
            search=query.get("search",[""])[0].strip().lower()
            folder=query.get("folder",[""])[0].strip().replace("\\","/")

            with state_lock:
                source=songs[:]
                index=search_index.copy()

            if folder:
                source=[
                    song for song in source
                    if song_folder_path(song)==folder
                ]

            if search:
                source=[
                    song for song in source
                    if search in index.get(song["id"], search_blob(song))
                ]

            total=len(source)
            page=source[offset:offset+limit]
            has_more=(offset+len(page))<total

            # Preserve existing folder-count behavior.
            with state_lock:
                all_source=songs[:]

            if search:
                all_source=[
                    song for song in all_source
                    if search in index.get(song["id"], search_blob(song))
                ]

            folder_counts={}
            for song in all_source:
                folder_path=song_folder_path(song)
                if folder_path:
                    folder_counts[folder_path]=folder_counts.get(folder_path,0)+1

            folders=[
                {"path":path,"count":count}
                for path,count in sorted(
                    folder_counts.items(),
                    key=lambda item:item[0].lower()
                )
            ]

            self.send_json({
                "ok":True,
                "count":total,
                "offset":offset,
                "limit":limit,
                "has_more":has_more,
                "folders":folders,
                "songs":[public_song(song) for song in page]
            })
            return

        if path=="/api/queue":
            with state_lock:
                result=get_queue()
                version=queue_version

            self.send_json({
                "ok":True,
                "version":version,
                "queue":result
            })
            return

        if path=="/api/player":

            token=get_player_token(self)
            if token:
                touch_player(token)

            with state_lock:
                current=(
                    public_song(song_map.get(current_song_id))
                    if current_song_id else None
                )

                result_queue=[
                    public_song(song_map[sid])
                    for sid in queue
                    if sid in song_map
                ]

                playing=player_playing
                version=player_version

            self.send_json({
                "ok":True,
                "version":version,
                "current":current,
                "queue":result_queue,
                "playing":playing
            })
            return

        if path=="/api/player-command":
            with state_lock:
                cmd = player_command
                if cmd is not None:
                    cmd = dict(cmd)
                    if isinstance(cmd.get("song"), dict):
                        cmd["song"] = dict(cmd["song"])

            self.send_json({
                "ok": True,
                "command": cmd
            })
            return
        if path=="/api/connection-status":
            with player_lock:
                owner=player_owner_token is not None
                last_seen=player_owner_last_seen

            age=(time.time()-last_seen) if owner else None
            active=bool(owner and age is not None and age <= PLAYER_LOCK_TIMEOUT)

            self.send_json({
                "ok":True,
                "player_active":active,
                "last_seen":last_seen if active else None,
                "age":round(age,2) if age is not None else None
            })
            return

        if path=="/preview":
            self.serve_preview()
            return

        if path.startswith("/video/"):
            relative=path[len("/video/"):]
            self.serve_video(relative)
            return

        self.send_json({
            "ok":False,
            "error":"Not found"
        },404)

    def do_POST(self):

        parsed=urllib.parse.urlparse(self.path)
        path=urllib.parse.unquote(parsed.path)

        try:
            length=int(
                self.headers.get("Content-Length","0")
            )
        except Exception:
            length=0

        if length>1024*1024:
            self.send_json({
                "ok":False,
                "message":"Request too large"
            },413)
            return

        body=self.rfile.read(length) if length else b""

        try:
            data=json.loads(
                body.decode("utf-8")
            ) if body else {}
        except Exception:
            data={}

        if path=="/api/player/claim":

            token=get_player_token(self)

            if not token:
                self.send_json({
                    "ok":False,
                    "message":"Missing Player tab token"
                },400)
                return

            if acquire_player(token):
                self.send_json({"ok":True})
            else:
                self.send_json({
                    "ok":False,
                    "message":"Player is already in use",
                    "redirect":"/remote"
                })
            return

        if path=="/api/player/release":

            release_player(
                get_player_token(self)
            )

            self.send_json({"ok":True})
            return

        if path=="/api/queue/add":

            song_id=data.get("id")

            if not isinstance(song_id,str):
                self.send_json({
                    "ok":False,
                    "message":"Invalid song ID"
                },400)
                return

            ok,message=add_to_queue(song_id)

            self.send_json({
                "ok":ok,
                "message":message,
                "queue":get_queue()
            })
            return

        if path=="/api/queue/remove":

            try:
                position=int(data.get("position"))
            except Exception:
                position=-1

            ok,message=remove_from_queue(position)

            self.send_json({
                "ok":ok,
                "message":message,
                "queue":get_queue()
            })
            return

        if path=="/api/queue/clear":

            clear_queue()

            self.send_json({
                "ok":True,
                "message":"Queue cleared"
            })
            return

        if path=="/api/player/next":

            next_song=start_next_song()

            if next_song is None:
                self.send_json({
                    "ok":False,
                    "message":"Queue is empty",
                    "current":None,
                    "queue":get_queue()
                })
                return

            self.send_json({
                "ok":True,
                "current":next_song,
                "queue":get_queue()
            })
            return

        if path=="/api/player/previous":

            previous_song=start_previous_song()

            if previous_song is None:
                self.send_json({
                    "ok":False,
                    "message":"No previous song"
                })
                return

            self.send_json({
                "ok":True,
                "current":previous_song,
                "queue":get_queue()
            })
            return

        if path=="/api/player/toggle":

            playing=toggle_playing()

            self.send_json({
                "ok":True,
                "playing":playing
            })
            return

        if path=="/api/player/set-playing":

            value=data.get("playing")

            if not isinstance(value,bool):
                self.send_json({
                    "ok":False,
                    "message":"Invalid playing value"
                },400)
                return

            playing=set_playing(value)

            self.send_json({
                "ok":True,
                "playing":playing
            })
            return

        if path=="/api/player/play":

            song_id=data.get("id")

            if not isinstance(song_id,str):
                self.send_json({
                    "ok":False,
                    "message":"Invalid song ID"
                },400)
                return

            if not set_current_song(song_id):
                self.send_json({
                    "ok":False,
                    "message":"Song not found"
                },404)
                return

            self.send_json({
                "ok":True,
                "current":get_current_song()
            })
            return

        self.send_json({
            "ok":False,
            "message":"Unknown endpoint"
        },404)

    def serve_preview(self):

        if not os.path.isfile(PREVIEW_IMAGE):
            self.send_error(
                404,
                "Preview image not found"
            )
            return

        try:
            file_size=os.path.getsize(PREVIEW_IMAGE)
            content_type=(
                mimetypes.guess_type(PREVIEW_IMAGE)[0]
                or "image/png"
            )

            self.send_response(200)
            self.send_header("Content-Type",content_type)
            self.send_header("Content-Length",str(file_size))
            self.send_header("Cache-Control","public, max-age=60")
            self.send_header("Connection","close")
            self.end_headers()

            self.copy_file(
                PREVIEW_IMAGE,
                0,
                file_size
            )

        except OSError:
            self.send_error(
                404,
                "Preview unavailable"
            )

    def serve_video(self, relative_path):

        relative_path=relative_path.replace("\\","/")
        relative_path=relative_path.lstrip("/")

        base=os.path.abspath(KARAOKE_DIR)
        requested=os.path.abspath(
            os.path.join(
                KARAOKE_DIR,
                relative_path
            )
        )

        if not (
            requested==base
            or requested.startswith(base+os.sep)
        ):
            self.send_error(403,"Forbidden")
            return

        # Virtual ZIP entry: @ZIP@/archive.zip::folder/song.mp4
        if relative_path.startswith("@ZIP@/") and "::" in relative_path:
            zip_rel,entry_name=relative_path[6:].split("::",1)
            zip_path=os.path.abspath(os.path.join(KARAOKE_DIR,zip_rel))
            if not (zip_path==base or zip_path.startswith(base+os.sep)):
                self.send_error(403,"Forbidden")
                return
            self.serve_zip_video(zip_path,entry_name)
            return

        if not os.path.isfile(requested):
            self.send_error(404,"Video not found")
            return

        try:
            file_size=os.path.getsize(requested)
        except OSError:
            self.send_error(404,"File unavailable")
            return

        content_type=(
            mimetypes.guess_type(requested)[0]
            or "video/mp4"
        )

        range_header=self.headers.get("Range")

        if not range_header:

            self.send_response(200)
            self.send_header("Content-Type",content_type)
            self.send_header("Content-Length",str(file_size))
            self.send_header("Accept-Ranges","bytes")
            self.send_header("Cache-Control","no-cache")
            self.send_header("Connection","close")
            self.end_headers()

            self.copy_file(
                requested,
                0,
                file_size
            )
            return

        try:

            if not range_header.startswith("bytes="):
                raise ValueError

            range_value=range_header.split("=",1)[1]
            range_value=range_value.split(",",1)[0]

            start_text,end_text=range_value.split("-",1)

            if start_text:
                start=int(start_text)
            else:
                suffix=int(end_text)
                if suffix<=0:
                    raise ValueError
                start=max(
                    file_size-suffix,
                    0
                )

            if end_text:
                end=int(end_text)
            else:
                end=file_size-1

            if (
                start<0
                or start>=file_size
                or end<start
            ):
                raise ValueError

            end=min(
                end,
                file_size-1
            )

        except Exception:

            self.send_response(416)
            self.send_header(
                "Content-Range",
                "bytes */"+str(file_size)
            )
            self.send_header(
                "Connection",
                "close"
            )
            self.end_headers()
            return

        length=end-start+1

        self.send_response(206)
        self.send_header("Content-Type",content_type)
        self.send_header("Content-Length",str(length))
        self.send_header(
            "Content-Range",
            "bytes "+
            str(start)+"-"+
            str(end)+"/"+
            str(file_size)
        )
        self.send_header("Accept-Ranges","bytes")
        self.send_header("Cache-Control","no-cache")
        self.send_header("Connection","close")
        self.end_headers()

        self.copy_file(
            requested,
            start,
            length
        )

    def serve_zip_video(self,zip_path,entry_name):
        """Stream a video entry from ZIP. Range requests are supported."""
        try:
            with zipfile.ZipFile(zip_path,"r") as zf:
                try:
                    info=zf.getinfo(entry_name)
                except KeyError:
                    self.send_error(404,"Video not found in ZIP")
                    return

                if info.is_dir():
                    self.send_error(404,"Video not found")
                    return

                file_size=info.file_size
                content_type=(
                    mimetypes.guess_type(entry_name)[0]
                    or "video/mp4"
                )
                range_header=self.headers.get("Range")

                if not range_header:
                    self.send_response(200)
                    self.send_header("Content-Type",content_type)
                    self.send_header("Content-Length",str(file_size))
                    self.send_header("Accept-Ranges","bytes")
                    self.send_header("Cache-Control","no-cache")
                    self.send_header("Connection","close")
                    self.end_headers()
                    self.copy_zip_file(zf,info,0,file_size)
                    return

                try:
                    if not range_header.startswith("bytes="):
                        raise ValueError
                    range_value=range_header.split("=",1)[1].split(",",1)[0]
                    start_text,end_text=range_value.split("-",1)

                    if start_text:
                        start=int(start_text)
                    else:
                        suffix=int(end_text)
                        if suffix<=0:
                            raise ValueError
                        start=max(file_size-suffix,0)

                    if end_text:
                        end=int(end_text)
                    else:
                        end=file_size-1

                    if start<0 or start>=file_size or end<start:
                        raise ValueError
                    end=min(end,file_size-1)
                except Exception:
                    self.send_response(416)
                    self.send_header("Content-Range","bytes */"+str(file_size))
                    self.send_header("Connection","close")
                    self.end_headers()
                    return

                length=end-start+1
                self.send_response(206)
                self.send_header("Content-Type",content_type)
                self.send_header("Content-Length",str(length))
                self.send_header(
                    "Content-Range",
                    "bytes "+str(start)+"-"+str(end)+"/"+str(file_size)
                )
                self.send_header("Accept-Ranges","bytes")
                self.send_header("Cache-Control","no-cache")
                self.send_header("Connection","close")
                self.end_headers()
                self.copy_zip_file(zf,info,start,length)

        except (OSError,zipfile.BadZipFile,KeyError):
            try:
                self.send_error(404,"ZIP video unavailable")
            except Exception:
                pass

    def copy_zip_file(self,zf,info,start,length):
        try:
            with zf.open(info,"r") as file:
                remaining_skip=start
                while remaining_skip>0:
                    chunk=file.read(min(1024*1024,remaining_skip))
                    if not chunk:
                        return
                    remaining_skip-=len(chunk)

                remaining=length
                while remaining>0:
                    chunk=file.read(min(1024*1024,remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining-=len(chunk)
        except (BrokenPipeError,ConnectionResetError,socket.timeout,OSError,zipfile.BadZipFile):
            pass


    def copy_file(self,path,start,length):

        try:

            with open(path,"rb") as file:

                file.seek(start)
                remaining=length

                while remaining>0:

                    chunk=file.read(
                        min(
                            1024*1024,
                            remaining
                        )
                    )

                    if not chunk:
                        break

                    self.wfile.write(chunk)
                    remaining-=len(chunk)

        except (
            BrokenPipeError,
            ConnectionResetError,
            socket.timeout,
            OSError
        ):
            pass


def get_local_ip():

    sock=socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM
    )

    try:
        sock.connect(("8.8.8.8",80))
        return sock.getsockname()[0]

    except Exception:

        try:
            return socket.gethostbyname(
                socket.gethostname()
            )
        except Exception:
            return "127.0.0.1"

    finally:
        sock.close()


def open_browser(url):

    try:

        subprocess.Popen(
            ["termux-open-url",url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )

        return True

    except Exception as e:

        print("BROWSER OPEN ERROR:",e)
        return False


def create_karaoke_zip():
    """Move loose karaoke videos into MY KARAOKE.zip using ZIP STORED.

    Low-storage mode: each source video is deleted immediately after Python
    successfully writes that entry to the archive and verifies its stored size.
    """
    os.makedirs(KARAOKE_DIR, exist_ok=True)

    # Keep the archive INSIDE KARAOKE_DIR so the jukebox can scan/play it.
    output_path=os.path.join(KARAOKE_DIR,"MY KARAOKE.zip")
    temp_path=output_path+".part"

    print()
    print("==========================================")
    print("   KARAOKE JUKEBOX v8.5 -- ZIP MOVE")
    print("==========================================")
    print("Source:", KARAOKE_DIR)
    print("Output:", output_path)
    print("Mode: ZIP STORED (-0) + MOVE/DELETE")
    print()

    videos=[]
    for root, dirs, files in os.walk(KARAOKE_DIR):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files,key=str.lower):
            if name.startswith("."):
                continue
            if os.path.splitext(name)[1].lower() not in VIDEO_EXTENSIONS:
                continue
            full_path=os.path.join(root,name)
            rel_path=os.path.relpath(full_path,KARAOKE_DIR).replace("\\","/")
            videos.append((full_path,rel_path))

    if not videos:
        if os.path.isfile(output_path):
            print("No loose video files found.")
            print("Existing archive:",output_path)
            return 0
        print("No video files found in KARAOKE folder.")
        return 1

    # A previous archive would otherwise be replaced. This command is intended
    # to consolidate the current loose-video library into one fresh archive.
    if os.path.exists(temp_path):
        try:
            os.remove(temp_path)
        except OSError as e:
            print("ERROR: Cannot remove old temporary ZIP:",e)
            return 1

    if os.path.exists(output_path):
        print("ERROR: MY KARAOKE.zip already exists.")
        print("For safety, it was NOT overwritten.")
        print("Rename/remove the old ZIP first, then run --zip again.")
        return 1

    print("Videos found:",len(videos))
    print("IMPORTANT: Original video is deleted after each successful ZIP write.")
    print()

    moved=0
    try:
        with zipfile.ZipFile(
            temp_path,
            mode="w",
            compression=zipfile.ZIP_STORED,
            allowZip64=True
        ) as zf:
            for number,(full_path,rel_path) in enumerate(videos,1):
                source_size=os.path.getsize(full_path)
                print("[{}/{}] {}".format(number,len(videos),rel_path),flush=True)

                # zipfile writes from disk as a stream; it does not load the
                # complete video into RAM.
                zf.write(
                    full_path,
                    arcname=rel_path,
                    compress_type=zipfile.ZIP_STORED
                )

                # Verify the entry metadata before deleting the source.
                info=zf.getinfo(rel_path)
                if info.file_size != source_size or info.compress_type != zipfile.ZIP_STORED:
                    raise RuntimeError("ZIP verification failed for: "+rel_path)

                os.remove(full_path)
                moved += 1
                print("        moved -> ZIP, original deleted",flush=True)

        # Closing the ZipFile writes its central directory. Only then expose
        # the final .zip name to the jukebox scanner.
        os.replace(temp_path,output_path)

    except Exception as e:
        print()
        print("ZIP/MOVE ERROR:",e)
        print("Moved before error:",moved,"of",len(videos))
        if os.path.exists(temp_path):
            print("Partial archive kept for recovery:",temp_path)
        print("Files already moved were not duplicated back to save storage.")
        return 1

    # Remove empty subfolders left after moving videos. Never remove root.
    for root, dirs, files in os.walk(KARAOKE_DIR,topdown=False):
        if os.path.abspath(root)==os.path.abspath(KARAOKE_DIR):
            continue
        try:
            if not os.listdir(root):
                os.rmdir(root)
        except OSError:
            pass

    size=os.path.getsize(output_path)
    print()
    print("ZIP MOVE COMPLETED SUCCESSFULLY")
    print("File:",output_path)
    print("Size: {:.2f} GB ({:,} bytes)".format(size/(1024**3),size))
    print("Videos moved/deleted:",moved)
    print("Original loose videos remaining: 0")
    print()
    return 0


def main():

    print()
    print("==========================================")
    print("       KARAOKE JUKEBOX SERVER v2.0")
    print("==========================================")
    print()
    print("KARAOKE FOLDER:")
    print(KARAOKE_DIR)
    print()

    os.makedirs(
        KARAOKE_DIR,
        exist_ok=True
    )

    print("Scanning karaoke files...")
    scan_songs()

    print("Songs found:",len(songs))
    print()

    scanner=threading.Thread(
        target=scanner_loop,
        daemon=True,
        name="SongScanner"
    )
    scanner.start()

    server=JukeboxHTTPServer(
        (HOST,PORT),
        JukeboxHandler
    )

    local_ip=get_local_ip()

    player_url=(
        "http://"+
        local_ip+
        ":"+
        str(PORT)+
        "/player"
    )

    remote_url=(
        "http://"+
        local_ip+
        ":"+
        str(PORT)+
        "/remote"
    )

    print("Server running...")
    print()
    print("PLAYER:")
    print(player_url)
    print()
    print("REMOTE:")
    print(remote_url)
    print()
    print("Optimized:")
    print("- Player polling: 2 seconds")
    print("- Remote polling: 2 seconds\n- Remote songs: infinite scroll, 50 per batch")
    print("- Queue DOM only updates when changed")
    print("- Song library UI only updates when changed")
    print("- Versioned player state")
    print("- HTTP Range video streaming")
    print("- Dead client socket timeout")
    print("- Daemon HTTP threads")
    print("- PLAY IT NOW removes duplicate queue entry")
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


if __name__=="__main__":
    if "--zip" in __import__("sys").argv[1:]:
        raise SystemExit(create_karaoke_zip())
    main()
