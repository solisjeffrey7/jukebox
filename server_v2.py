#!/usr/bin/env python3

import os
import sys
import re
import hashlib
import hmac
import secrets
import zipfile
import json
import time
import mimetypes
import threading
import urllib.parse
import urllib.request
import urllib.error
import socket
import subprocess
import zipfile
import argparse
import qrcode
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

JUKEBOX_VERSION = "10.5.04"


# ============================================================
# JUKEBOX LICENSE / KEY SYSTEM
# ============================================================
JUKEBOX_KEY_FILENAME = "Jukebox.key"
JUKEBOX_KEY_MASTER = "2dc1d5c9fe88831ad4e6fbd23e847d517905e09741168c543c043d141b5c2f37"
JUKEBOX_KEY_MAX_BYTES = 4096
VALID_JUKEBOX_KEY_PATH = None

def _valid_jukebox_key_bytes(data):
    """Validate legacy SHA256 keys and JKB2 signed keys."""
    try:
        if not data or len(data) > JUKEBOX_KEY_MAX_BYTES:
            return False
        value = data.decode("utf-8-sig").strip()
    except Exception:
        return False

    # JKB2-<32 hex>-<64 hex>
    m = re.fullmatch(r"JKB2-([0-9A-Fa-f]{32})-([0-9A-Fa-f]{64})", value)
    if m:
        key_id, signature = m.groups()
        expected = hmac.new(
            JUKEBOX_KEY_MASTER.encode("utf-8"),
            key_id.upper().encode("utf-8"),
            hashlib.sha256
        ).hexdigest().upper()
        return hmac.compare_digest(signature.upper(), expected)

    # Legacy key support.
    legacy_hash = "5d3a8b745e1b1663953cdac6f9131a72c03627db258e983e63922749081844ba"
    return hmac.compare_digest(
        hashlib.sha256(value.encode("utf-8")).hexdigest(),
        legacy_hash
    )

def _find_jukebox_key():
    """Search KARAOKE recursively, including keys stored inside ZIP files."""
    root = os.path.expanduser("~/storage/shared/KARAOKE")
    if not os.path.isdir(root):
        return None

    # Direct key files anywhere below KARAOKE.
    for dirpath, dirnames, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower() == JUKEBOX_KEY_FILENAME.lower():
                path = os.path.join(dirpath, filename)
                try:
                    with open(path, "rb") as f:
                        if _valid_jukebox_key_bytes(f.read(JUKEBOX_KEY_MAX_BYTES + 1)):
                            return path
                except Exception:
                    pass

        # Also inspect ZIP archives for Jukebox.key.
        for filename in filenames:
            if not filename.lower().endswith(".zip"):
                continue
            path = os.path.join(dirpath, filename)
            try:
                with zipfile.ZipFile(path, "r") as zf:
                    for member in zf.infolist():
                        if member.is_dir():
                            continue
                        if os.path.basename(member.filename).lower() != JUKEBOX_KEY_FILENAME.lower():
                            continue
                        if member.file_size > JUKEBOX_KEY_MAX_BYTES:
                            continue
                        data = zf.read(member)
                        if _valid_jukebox_key_bytes(data):
                            return f"{path}::{member.filename}"
            except Exception:
                pass

    return None

def require_jukebox_key():
    """Return True only when a valid Jukebox.key is found."""
    global VALID_JUKEBOX_KEY_PATH
    VALID_JUKEBOX_KEY_PATH = _find_jukebox_key()
    if VALID_JUKEBOX_KEY_PATH:
        return True

    print("Jukebox.key: NOT FOUND / INVALID")
    print("Place a valid Jukebox.key inside KARAOKE, any subfolder, or a ZIP archive.")
    print("Jukebox stopped: valid Jukebox.key is required.")
    return False

def generate_jukebox_key():
    """Generate and save a new signed Jukebox.key directly into KARAOKE."""
    root = os.path.expanduser("~/storage/shared/KARAOKE")
    os.makedirs(root, exist_ok=True)

    key_id = secrets.token_hex(16).upper()
    signature = hmac.new(
        JUKEBOX_KEY_MASTER.encode("utf-8"),
        key_id.encode("utf-8"),
        hashlib.sha256
    ).hexdigest().upper()
    key = f"JKB2-{key_id}-{signature}"

    path = os.path.join(root, JUKEBOX_KEY_FILENAME)
    with open(path, "w", encoding="utf-8") as f:
        f.write(key + "\n")

    print(f"Jukebox.key generated: {path}")
    print(key)
    return path
# ============================================================

HOST = "0.0.0.0"
PORT = 8080
KARAOKE_DIR = os.path.expanduser("~/storage/shared/KARAOKE")
PREVIEW_IMAGE = os.path.expanduser("~/storage/shared/KARAOKE/preview.png")

VIDEO_EXTENSIONS = {".mp4", ".m4v", ".webm", ".mkv", ".mov", ".avi"}
ZIP_EXTENSIONS = {".zip"}
# ZIP archives are treated as virtual folders in the Remote UI.
SCAN_INTERVAL = 30
MAX_QUEUE = 100

# YouTube integration. Keep the API key server-side; never expose it to the browser.
YOUTUBE_API_KEY_FILE = os.path.expanduser("~/jukebox/youtube_api_key.txt")
# YouTube search cache. Keep successful searches for 24 hours and persist them
# across Jukebox restarts so repeated searches do not consume Search quota.
YOUTUBE_SEARCH_CACHE_TTL = 86400
YOUTUBE_MAX_RESULTS = 50
YOUTUBE_SEARCH_CACHE_FILE = os.path.expanduser("~/jukebox/youtube_search_cache.json")
# Permanent folder name shown in the Remote library for saved playable YouTube links.
SAVED_LINKS_FOLDER = "@SAVED_LINKS@"
YOUTUBE_PLAYABLE_LINKS_FILE = os.path.expanduser("~/jukebox/yt-playable-link.json")
youtube_playable_links = {}
youtube_songs = {}
youtube_search_cache = {}
youtube_cache_lock = threading.RLock()

state_lock = threading.RLock()
songs = []
song_map = {}
search_index = {}
# Per-device/player state. The library remains shared to keep RAM usage low.
players = {}
players_lock = threading.RLock()
last_scan = 0

PLAYER_IDLE_TIMEOUT = 600  # Player stays alive while heartbeat is received; closed tabs expire after timeout

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
        cleanup_players()
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

    result={
        "id": song["id"],
        "code": song["code"],
        "title": song["title"],
        "artist": song["artist"],
        "filename": song["filename"],
        "path": song["path"],
    }
    if song.get("youtube"):
        result["youtube"]=True
        result["youtube_id"]=song.get("youtube_id","")
        result["thumbnail"]=song.get("thumbnail","")
        if song.get("saved_link"):
            result["saved_link"]=True
    return result


def get_song_by_id(song_id):
    if not song_id:
        return None
    song = song_map.get(song_id)
    if song is not None:
        return song
    with youtube_cache_lock:
        return youtube_songs.get(song_id)


def public_song_by_id(song_id):
    return public_song(get_song_by_id(song_id))


def load_youtube_api_key():
    key=os.environ.get("YOUTUBE_API_KEY","").strip()
    if key:
        return key
    try:
        with open(YOUTUBE_API_KEY_FILE,"r",encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


def load_youtube_search_cache():
    try:
        with open(YOUTUBE_SEARCH_CACHE_FILE,"r",encoding="utf-8") as f:
            data=json.load(f)
        if not isinstance(data,dict):
            return
        with youtube_cache_lock:
            for key,entry in data.items():
                if not isinstance(entry,dict):
                    continue
                results=entry.get("results")
                timestamp=entry.get("time")
                if not isinstance(results,list) or not isinstance(timestamp,(int,float)):
                    continue
                youtube_search_cache[str(key)]= {"time":float(timestamp),"results":results}
                for song in results:
                    if isinstance(song,dict) and song.get("id"):
                        youtube_songs[song["id"]]=song
    except (OSError,ValueError,TypeError):
        return


def save_youtube_search_cache():
    try:
        os.makedirs(os.path.dirname(YOUTUBE_SEARCH_CACHE_FILE),exist_ok=True)
        with youtube_cache_lock:
            payload=dict(youtube_search_cache)
        temp=YOUTUBE_SEARCH_CACHE_FILE+".tmp"
        with open(temp,"w",encoding="utf-8") as f:
            json.dump(payload,f,ensure_ascii=False,separators=(",",":"))
        os.replace(temp,YOUTUBE_SEARCH_CACHE_FILE)
    except OSError:
        pass


def cache_youtube_results(cache_key, results, timestamp=None):
    with youtube_cache_lock:
        youtube_search_cache[cache_key]={
            "time":float(timestamp if timestamp is not None else time.time()),
            "results":results
        }
        for song in results:
            if isinstance(song,dict) and song.get("id"):
                youtube_songs[song["id"]]=song
    save_youtube_search_cache()


def load_youtube_playable_links():
    global youtube_playable_links
    try:
        with open(YOUTUBE_PLAYABLE_LINKS_FILE,"r",encoding="utf-8") as f:
            data=json.load(f)
        if isinstance(data,list):
            items=data
        elif isinstance(data,dict):
            items=data.get("links",[])
        else:
            items=[]
        cleaned={}
        for item in items:
            if not isinstance(item,dict):
                continue
            video_id=str(item.get("youtube_id","")).strip()
            title=str(item.get("title","")).strip()
            link=str(item.get("link","")).strip()
            if not video_id and "v=" in link:
                video_id=urllib.parse.parse_qs(urllib.parse.urlparse(link).query).get("v",[""])[0]
            if not video_id or not link or not title:
                continue
            cleaned[video_id]={
                "youtube_id":video_id,
                "title":title,
                "link":link,
                "artist":str(item.get("artist","")).strip(),
                "thumbnail":str(item.get("thumbnail","")).strip(),
            }
        youtube_playable_links=cleaned
    except Exception:
        youtube_playable_links={}


def save_youtube_playable_links():
    os.makedirs(os.path.dirname(YOUTUBE_PLAYABLE_LINKS_FILE),exist_ok=True)
    with youtube_cache_lock:
        items=sorted(youtube_playable_links.values(),key=lambda x:x.get("title","").lower())
    temp=YOUTUBE_PLAYABLE_LINKS_FILE+".tmp"
    with open(temp,"w",encoding="utf-8") as f:
        json.dump(items,f,ensure_ascii=False,indent=2)
    os.replace(temp,YOUTUBE_PLAYABLE_LINKS_FILE)


def make_saved_youtube_song(item):
    video_id=str(item.get("youtube_id","")).strip()
    title=str(item.get("title","")).strip()
    artist=str(item.get("artist","")).strip()
    thumbnail=str(item.get("thumbnail","")).strip()
    return {
        "id":"yt:"+video_id,
        "code":"YT",
        "title":title,
        "artist":artist,
        "filename":title,
        "path":SAVED_LINKS_FOLDER+"/"+video_id,
        "youtube":True,
        "youtube_id":video_id,
        "thumbnail":thumbnail,
        "saved_link":True,
        "link":"https://www.youtube.com/watch?v="+video_id,
    }


def clean_youtube_filename(title):
    import re
    title=str(title or "").strip()
    # Remove parenthesized/bracketed text and common YouTube filename noise.
    title=re.sub(r"\([^)]*\)|\[[^]]*\]|\{[^}]*\}", " ", title)
    title=re.sub(r"[\\/:*?\"<>|]", " ", title)
    title=re.sub(r"[^\w\s.-]", " ", title, flags=re.UNICODE)
    title=re.sub(r"\s+", " ", title).strip(" .-")
    return title or "YouTube Song"


def save_playable_youtube_link(video_id,title,artist="",thumbnail=""):
    video_id=str(video_id or "").strip()
    title=clean_youtube_filename(title)
    if not video_id or not title:
        return False,"Invalid YouTube link"
    link="https://www.youtube.com/watch?v="+video_id
    with youtube_cache_lock:
        if video_id in youtube_playable_links or any(x.get("link")==link for x in youtube_playable_links.values()):
            return False,"Already saved"
        youtube_playable_links[video_id]={
            "youtube_id":video_id,
            "title":title,
            "link":link,
            "artist":str(artist or "").strip(),
            "thumbnail":str(thumbnail or "").strip(),
        }
        youtube_songs["yt:"+video_id]=make_saved_youtube_song(youtube_playable_links[video_id])
    save_youtube_playable_links()
    return True,"Saved"


def get_saved_youtube_songs():
    with youtube_cache_lock:
        return [make_saved_youtube_song(x) for x in sorted(youtube_playable_links.values(),key=lambda x:x.get("title","").lower())]


def youtube_search(query):
    query=" ".join(str(query or "").split()).strip()
    if not query:
        return []

    cache_key=query.lower()
    now=time.time()
    stale_cache=None
    with youtube_cache_lock:
        cached=youtube_search_cache.get(cache_key)
        if cached:
            stale_cache=cached
            # Do not reuse an old 15-result cache entry after upgrading to 50.
            # Refresh it once so the cache itself is upgraded to the new result count.
            if (now-cached["time"] < YOUTUBE_SEARCH_CACHE_TTL
                    and len(cached.get("results",[])) >= YOUTUBE_MAX_RESULTS):
                return cached["results"]

    key=load_youtube_api_key()
    if not key:
        if stale_cache:
            return stale_cache["results"]
        raise RuntimeError("YouTube API key is not configured")

    # IMPORTANT: Do not pre-filter by embeddable/syndicated status here.
    # The UI must display the YouTube search results first, then test them
    # one-by-one in the browser and remove only videos that return an actual
    # IFrame Player error.
    # YouTube search.list accepts at most 50 results per request.
    # Fetch up to 100 using two pages of 50.
    results=[]
    page_token=""
    target=max(1,min(int(YOUTUBE_MAX_RESULTS),100))
    try:
        while len(results) < target:
            page_size=min(50,target-len(results))
            params=urllib.parse.urlencode({
                "part":"snippet",
                "q":query,
                "type":"video",
                "maxResults":str(page_size),
                "regionCode":"PH",
                "relevanceLanguage":"en",
                "key":key,
                **({"pageToken":page_token} if page_token else {})
            })
            url="https://www.googleapis.com/youtube/v3/search?"+params
            request=urllib.request.Request(url,headers={"User-Agent":"KaraokeJukebox/{JUKEBOX_VERSION}"})
            with urllib.request.urlopen(request,timeout=10) as response:
                payload=json.loads(response.read().decode("utf-8"))

            for item in payload.get("items",[]):
                video_id=(item.get("id") or {}).get("videoId")
                if not video_id:
                    continue
                snippet=item.get("snippet") or {}
                title=snippet.get("title","")
                channel=snippet.get("channelTitle","")
                song={
                    "id":"yt:"+video_id,
                    "code":"YT",
                    "title":title,
                    "artist":channel,
                    "filename":title,
                    "path":"@YOUTUBE@/"+video_id,
                    "youtube":True,
                    "youtube_id":video_id,
                    "thumbnail":((snippet.get("thumbnails") or {}).get("medium") or {}).get("url","")
                }
                results.append(song)
                with youtube_cache_lock:
                    youtube_songs[song["id"]]=song
                if len(results) >= target:
                    break

            if len(results) >= target:
                break
            page_token=str(payload.get("nextPageToken") or "")
            if not page_token:
                break
    except urllib.error.HTTPError as e:
        if e.code == 429 and stale_cache:
            return stale_cache["results"]
        raise

    cache_youtube_results(cache_key,results,now)
    return results


# Restore cached YouTube searches at startup.
load_youtube_search_cache()
load_youtube_playable_links()
# Always create the permanent playable-links file, even when it is empty.
if not os.path.exists(YOUTUBE_PLAYABLE_LINKS_FILE):
    save_youtube_playable_links()
for _saved in get_saved_youtube_songs():
    youtube_songs[_saved["id"]]=_saved


def normalize_player_token(token):
    if not token:
        return None
    token=str(token).strip()
    return token if 8 <= len(token) <= 200 else None


def get_player_state(token, create=False):
    token=normalize_player_token(token)
    if not token:
        return None
    now=time.time()
    with players_lock:
        state=players.get(token)
        if state is None and create:
            state={
                "queue": [],
                "history": [],
                "current_song_id": None,
                "current_started_at": 0,
                "playing": False,
                "version": 0,
                "queue_version": 0,
                "command_version": 0,
                "command": None,
                "last_seen": now,
            }
            players[token]=state
        return state


def cleanup_players():
    cutoff=time.time()-PLAYER_IDLE_TIMEOUT
    with players_lock:
        for token in list(players):
            if players[token].get("last_seen",0)<cutoff:
                del players[token]


def get_queue(token):
    state=get_player_state(token)
    if state is None:
        return []
    with state_lock:
        return [
            public_song_by_id(sid)
            for sid in state["queue"]
            if get_song_by_id(sid) is not None
        ]


def add_to_queue(token, song_id):
    state=get_player_state(token)
    if state is None:
        return False, "Invalid player"
    with state_lock:
        if get_song_by_id(song_id) is None:
            return False, "Song not found"
        if len(state["queue"]) >= MAX_QUEUE:
            return False, "Queue is full"
        state["queue"].append(song_id)
        state["queue_version"]+=1
        state["version"]+=1
        return True, "Added to queue"


def remove_from_queue(token, position):
    state=get_player_state(token)
    if state is None:
        return False, "Invalid player"
    with state_lock:
        if position<0 or position>=len(state["queue"]):
            return False, "Invalid position"
        state["queue"].pop(position)
        state["queue_version"]+=1
        state["version"]+=1
        return True, "Removed"


def reorder_queue(token, from_position, to_position):
    state=get_player_state(token)
    if state is None:
        return False, "Invalid player"
    with state_lock:
        q=state["queue"]
        if from_position < 0 or from_position >= len(q):
            return False, "Invalid source position"
        if to_position < 0 or to_position >= len(q):
            return False, "Invalid destination position"
        if from_position == to_position:
            return True, "No change"
        song_id=q.pop(from_position)
        q.insert(to_position, song_id)
        state["queue_version"]+=1
        state["version"]+=1
        return True, "Queue reordered"


def clear_queue(token):
    state=get_player_state(token)
    if state is None:
        return
    with state_lock:
        state["queue"].clear()
        state["history"].clear()
        state["queue_version"]+=1
        state["version"]+=1


def get_current_song(token):
    state=get_player_state(token)
    if state is None:
        return None
    with state_lock:
        sid=state["current_song_id"]
        if sid:
            return public_song_by_id(sid)
    return None


def set_current_song(token, song_id):
    state=get_player_state(token)
    if state is None:
        return False
    with state_lock:
        if get_song_by_id(song_id) is None:
            return False
        try:
            state["queue"].remove(song_id)
            state["queue_version"]+=1
        except ValueError:
            pass
        # Keep the currently playing song in history so PREVIOUS also works
        # when a queued song is manually selected or drag-dropped to the player.
        current=state["current_song_id"]
        if current and current!=song_id and get_song_by_id(current) is not None:
            state["history"].append(current)
        state["current_song_id"]=song_id
        state["current_started_at"]=time.time()
        state["playing"]=True
        state["version"]+=1
        state["command_version"]+=1
        state["command"]={
            "type":"play",
            "version":state["command_version"],
            "song":public_song_by_id(song_id)
        }
        return True


def start_next_song(token):
    state=get_player_state(token)
    if state is None:
        return None
    with state_lock:
        while state["queue"]:
            next_id=state["queue"].pop(0)
            state["queue_version"]+=1
            next_song=get_song_by_id(next_id)
            if next_song is None:
                continue
            current=state["current_song_id"]
            if current and get_song_by_id(current) is not None and current!=next_id:
                state["history"].append(current)
            state["current_song_id"]=next_id
            state["current_started_at"]=time.time()
            state["playing"]=True
            state["version"]+=1
            return public_song(next_song)
        state["current_song_id"]=None
        state["current_started_at"]=0
        state["playing"]=False
        state["version"]+=1
        return None


def start_previous_song(token):
    state=get_player_state(token)
    if state is None:
        return None
    with state_lock:
        if not state["history"]:
            return None
        previous_id=state["history"].pop()
        current=state["current_song_id"]
        if current and get_song_by_id(current) is not None:
            state["queue"].insert(0,current)
            state["queue_version"]+=1
        previous_song=get_song_by_id(previous_id)
        if previous_song is None:
            return None
        state["current_song_id"]=previous_id
        state["current_started_at"]=time.time()
        state["playing"]=True
        state["version"]+=1
        return public_song(previous_song)


def toggle_playing(token):
    state=get_player_state(token)
    if state is None:
        return False
    with state_lock:
        state["playing"]=not state["playing"]
        state["version"]+=1
        return state["playing"]


def set_playing(token, value):
    state=get_player_state(token)
    if state is None:
        return False
    with state_lock:
        if state["playing"]!=value:
            state["playing"]=value
            state["version"]+=1
        return state["playing"]


def get_player_token(handler):
    return normalize_player_token(handler.headers.get("X-Jukebox-Player-Token"))


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
*{-webkit-user-select:none;-moz-user-select:none;user-select:none;-webkit-touch-callout:none}
html,body{-webkit-user-select:none;-moz-user-select:none;user-select:none}
input,textarea{user-select:text;-webkit-user-select:text}
html,body{margin:0;padding:0;background:#090909;color:#fff;font-family:Arial,Helvetica,sans-serif}
body{min-height:100vh;height:100vh;overflow:hidden}
.header{height:58px;display:flex;align-items:center;justify-content:space-between;padding:0 18px;background:#111;border-bottom:1px solid #292929}
.logo{font-size:20px;font-weight:900;letter-spacing:2px;color:#fff}
.header-right{display:flex;align-items:center;gap:12px}
.remote-link{color:#fff;text-decoration:none;background:#222;border:1px solid #3a3a3a;padding:8px 13px;border-radius:7px;font-size:12px}
.player-layout{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:14px;padding:14px;min-height:calc(100vh - 58px)}
.video-side{min-width:0}
.video-wrapper{position:relative;width:100%;background:#000;aspect-ratio:16/9;overflow:hidden}
video{display:none;width:100%;height:100%;background:#000;object-fit:contain}
.youtube-player{display:none;position:absolute;inset:0;background:#000}
.video-wrapper.youtube-active .youtube-player{display:block}
.video-wrapper.youtube-active video,.video-wrapper.youtube-active .preview-image{display:none}
.youtube-player iframe{width:100%;height:100%;border:0}
.preview-image{display:block;width:100%;height:100%;background:#000;object-fit:contain}
.video-wrapper.has-video video{display:block}
.video-wrapper.has-video .preview-image{display:none}
.player-badge{color:#fff;background:#222;border:1px solid #3a3a3a;padding:7px 10px;border-radius:7px;font-size:11px;font-weight:800;white-space:nowrap}
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
.play-pause-drop-target{position:relative}
#playPauseButton.drop-target{outline:3px dashed #fff;outline-offset:2px;transform:scale(1.02)}
#playPauseButton.drop-target::after{content:"DROP TO PLAY";position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.72);border-radius:6px;font-size:14px;font-weight:900;letter-spacing:.6px;pointer-events:none}
.queue-side{min-width:0;display:flex;flex-direction:column;border-left:1px solid #292929;padding-left:14px}
.queue-header{display:flex;align-items:center;justify-content:space-between;padding-bottom:10px;border-bottom:1px solid #292929}
.queue-title{font-size:18px;font-weight:800}
.queue-count{color:#888;font-size:12px}
.queue-list{flex:1;min-height:0;max-height:calc(100vh - 115px);overflow-y:auto}
.drag-handle{display:flex;align-items:center;justify-content:center;color:#fff;font-size:22px;font-weight:900;cursor:grab;user-select:none;-webkit-user-select:none;touch-action:none;width:28px;height:40px;border-radius:6px}.queue-item{display:grid;grid-template-columns:28px 40px minmax(0,1fr) 65px;align-items:center;gap:8px;padding:11px 3px;border-bottom:1px solid #202020}.queue-item{touch-action:pan-y;cursor:grab}.queue-item.touch-dragging{opacity:.35;outline:2px dashed #fff}.queue-item.touch-drag-over{outline:2px solid #fff;background:#1d1d1d}.touch-drag-clone{position:fixed;z-index:100000;pointer-events:none;opacity:.92;background:#171717;border:2px solid #fff;border-radius:8px;padding:8px;box-shadow:0 10px 30px rgba(0,0,0,.7);transform:scale(1.02);max-width:calc(100vw - 12px);overflow:hidden}.queue-item{cursor:grab;user-select:none;-webkit-user-select:none}
.queue-item:active{cursor:grabbing}
.queue-item.dragging{opacity:.45}
.queue-item.drag-over{border-top:2px solid #fff}
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

.qr-popup{
    position:fixed;inset:0;z-index:9999;display:none;
    align-items:center;justify-content:center;
    background:rgba(0,0,0,.82);padding:20px;
}
.qr-popup.show{display:flex}
.qr-popup-card{
    position:relative;background:#fff;border-radius:16px;
    padding:18px;text-align:center;max-width:92vw;
    box-shadow:0 20px 70px rgba(0,0,0,.65);
}
.qr-popup-card img{display:block;width:min(72vw,420px);height:min(72vw,420px);image-rendering:pixelated}
.qr-popup-close{
    position:absolute;right:-10px;top:-10px;width:34px;height:34px;
    border:0;border-radius:50%;background:#111;color:#fff;
    font-size:22px;font-weight:800;cursor:pointer;
}
.qr-popup-title{color:#111;font-weight:800;font-size:15px;margin-bottom:10px}
.qr-popup-hint{color:#666;font-size:11px;margin-top:10px}
.normal-remote-qr img,.fullscreen-remote-qr img{cursor:pointer}


/* Desktop: keep the QR ABOVE the video.
   Hide only the QR that is INSIDE the video. */
@media (min-width: 851px){
    .normal-remote-qr{
        display:flex !important;
    }
    .video-wrapper .fullscreen-remote-qr{
        display:none !important;
    }
}
</style>


<style id="fullscreen-picker-css">
#fullscreenPicker{
    position:fixed!important;
    inset:0!important;
    width:100vw!important;
    height:100vh!important;
    display:none;
    align-items:center!important;
    justify-content:center!important;
    padding:16px!important;
    box-sizing:border-box!important;
    background:rgba(0,0,0,.72)!important;
    z-index:2147483647!important;
}
#fullscreenPicker.show{display:flex!important}
#fullscreenPicker .fullscreen-picker-box{
    display:block!important;
    position:relative!important;
    width:min(420px,calc(100vw - 32px))!important;
    max-width:420px!important;
    box-sizing:border-box!important;
    padding:22px!important;
    border-radius:18px!important;
    background:#181818!important;
    color:#fff!important;
    box-shadow:0 12px 50px rgba(0,0,0,.55)!important;
}
#fullscreenPicker .fullscreen-choice{
    width:100%!important;
    min-height:64px!important;
    display:flex!important;
    align-items:center!important;
    gap:14px!important;
    text-align:left!important;
    padding:14px 16px!important;
    margin:9px 0!important;
    border:1px solid rgba(255,255,255,.18)!important;
    border-radius:14px!important;
    background:rgba(255,255,255,.07)!important;
    color:#fff!important;
    cursor:pointer!important;
    -webkit-tap-highlight-color:transparent;
}
#fullscreenPicker .fullscreen-choice:active{transform:scale(.99);background:rgba(255,255,255,.14)!important}
#fullscreenPicker .choice-icon{font-size:28px!important;line-height:1}
#fullscreenPicker .fullscreen-choice b{display:block!important;font-size:16px!important}
#fullscreenPicker .fullscreen-choice small{display:block!important;opacity:.68!important;margin-top:3px!important}
#fullscreenPicker .fullscreen-cancel{
    width:100%!important;
    margin-top:8px!important;
    padding:12px!important;
    border:0!important;
    border-radius:12px!important;
    background:transparent!important;
    color:#fff!important;
    opacity:.72!important;
    cursor:pointer!important;
}
</style>


<style id="fullscreen-icon-style">
#fullscreenButton .fullscreen-icon,
#fullscreenButton .fullscreen-state-icon{
    display:inline-flex;
    align-items:center;
    justify-content:center;
    line-height:1;
    font-size:1.1em;
    transition:transform .15s ease;
}
#fullscreenButton.is-fullscreen .fullscreen-icon,
#fullscreenButton.is-fullscreen .fullscreen-state-icon{
    transform:scale(.96);
}
</style>

</head>
<body>
<script>
// Prevent accidental text selection/copy while preserving queue drag-and-drop.
document.addEventListener("selectstart",e=>e.preventDefault());
document.addEventListener("contextmenu",e=>e.preventDefault());
document.addEventListener("copy",e=>e.preventDefault());
document.addEventListener("cut",e=>e.preventDefault());
document.addEventListener("dragover",e=>{if(!e.target.closest(".queue-item"))e.preventDefault();});
</script>
<header class="header">
<div class="logo">Jukebox <span style="font-size:11px;font-weight:500;opacity:.65;vertical-align:middle;">V__JUKEBOX_VERSION__</span></div>
<div class="header-right">
<div id="playerBadge" class="player-badge">PLAYER</div>
<a id="remoteLink" class="remote-link" href="#" target="_blank">REMOTE</a>
</div>
</header>

<main class="player-layout">
<section class="video-side">

<div class="normal-remote-qr">
<img id="videoQr" alt="Remote QR"><div style="font-size:12px;opacity:.7;margin-top:6px;">Tap QR to connect to this Player</div>
<div class="video-qr-label">SCAN FOR REMOTE<br><span>Must be connected to same network</span></div>
</div>

<div id="videoWrapper" class="video-wrapper">
<img id="previewImage" class="preview-image" src="/preview" alt="Karaoke Preview">
<video id="video" playsinline preload="metadata"></video>
<div id="youtubePlayer" class="youtube-player"></div>

<div class="fullscreen-remote-qr">
<img id="fullscreenQr" alt="Remote QR">
</div>

<button id="fullscreenButton" class="fullscreen-button" onclick="(document.fullscreenElement?exitAllFullscreen():openFullscreenPicker())">⛶</button>
</div>

<section class="now-playing">
<div class="now-label">NOW PLAYING</div>
<div id="nowTitle" class="now-title">Please select a song</div>
<div id="nowArtist" class="now-artist">—</div>
</section>

<div class="controls">
<button onclick="previousSong()">⏮ PREVIOUS</button>
<button id="playPauseButton" onclick="togglePlay()">▶ PLAY / ⏸ PAUSE</button>
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
let youtubePlayerEl=document.getElementById("youtubePlayer");
const videoWrapper=document.getElementById("videoWrapper");
let ytPlayer=null;
let ytApiReady=false;
let ytPlayerReady=false;
let ytPendingId=null;
let currentIsYouTube=false;

(function loadYouTubeAPI(){
    const tag=document.createElement("script");
    tag.src="https://www.youtube.com/iframe_api";
    document.head.appendChild(tag);
})();
window.onYouTubeIframeAPIReady=function(){
    ytApiReady=true;
    if(ytPendingId) loadYouTube(ytPendingId);
};

function destroyYouTube(){
    if(ytPlayer){
        try{ytPlayer.destroy();}catch(e){}
        ytPlayer=null;
        ytPlayerReady=false;
    }
    ytPendingId=null;
    youtubePlayerEl.innerHTML="";
    videoWrapper.classList.remove("youtube-active");
    currentIsYouTube=false;
}

function loadYouTube(videoId){
    currentIsYouTube=true;
    ytPendingId=videoId;
    videoWrapper.classList.add("has-video","youtube-active");
    video.pause();
    video.removeAttribute("src");
    video.load();
    if(!ytApiReady)return;
    if(ytPlayer && ytPlayerReady){
        try{
            ytPlayer.loadVideoById(videoId);
            ytPendingId=null;
            return;
        }catch(e){}
    }
    youtubePlayerEl.innerHTML="";
    ytPlayerReady=false;
    ytPlayer=new YT.Player(youtubePlayerEl,{
        width:"100%",height:"100%",videoId:videoId,
        playerVars:{autoplay:1,controls:0,playsinline:1,rel:0,fs:0,origin:window.location.origin},
        events:{
            onReady:function(event){
                ytPlayerReady=true;
                ytPendingId=null;
                event.target.playVideo();
                // Re-sync the newly-created YouTube player with the server state.
                api("/api/player").then(function(state){
                    if(state && state.ok && ytPlayer===event.target){
                        try{
                            if(state.playing) event.target.playVideo();
                            else event.target.pauseVideo();
                        }catch(e){}
                    }
                }).catch(()=>{});
            },
            onStateChange:function(event){
                if(event.data===0){
                    nextSong();
                }
            },
            onError:function(event){
                // Skip videos that YouTube refuses to play in the embedded
                // player instead of leaving the jukebox stuck on an error.
                if([2,5,100,101,150,153].includes(Number(event.data))){
                    setTimeout(()=>nextSong(),250);
                }
            }
        }
    });
}

const playerLayout=document.querySelector(".player-layout");
// Use the token assigned by /player-ui first.
// This keeps the Player token registered on the server, so the
// Remote button and QR always open THIS exact Player directly.
const playerQueryToken=new URLSearchParams(window.location.search).get("token");
let playerToken=playerQueryToken || sessionStorage.getItem("jukebox_player_tab_token");
if(!playerToken){
    playerToken=(window.crypto&&crypto.randomUUID)?crypto.randomUUID().replace(/-/g,""):Date.now().toString(36)+Math.random().toString(36).slice(2);
}
sessionStorage.setItem("jukebox_player_tab_token",playerToken);

function setRemoteQr(){
    const url=window.location.origin+"/remote?player="+encodeURIComponent(playerToken);
    const shortId=playerToken.slice(0,6).toUpperCase();
    const badge=document.getElementById("playerBadge");
    const link=document.getElementById("remoteLink");
    if(badge)badge.textContent="PLAYER "+shortId;
    if(link){link.href=url; link.textContent="REMOTE "+shortId;}
    const qr="/api/qr?data="+encodeURIComponent(url);
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


function applyDroppedCurrentSong(current){
    if(!current)return;

    currentSongId=null;
    try{ video.pause(); }catch(e){}
    try{ video.removeAttribute("src"); video.load(); }catch(e){}

    if(current.youtube && current.youtube_id){
        currentIsYouTube=true;
        // HARD REMOVE the old YouTube iframe/player, then replace its DOM node.
        if(ytPlayer){
            try{ytPlayer.stopVideo();}catch(e){}
            try{ytPlayer.destroy();}catch(e){}
        }
        ytPlayer=null;
        ytPlayerReady=false;
        ytPendingId=null;

        const oldEl=document.getElementById("youtubePlayer");
        const newEl=document.createElement("div");
        newEl.id="youtubePlayer";
        newEl.className="youtube-player";
        if(oldEl) oldEl.replaceWith(newEl);
        else videoWrapper.appendChild(newEl);
        youtubePlayerEl=newEl;

        videoWrapper.classList.remove("youtube-active");
        videoWrapper.classList.add("has-video");
        setTimeout(()=>{
            videoWrapper.classList.add("youtube-active");
            loadYouTube(current.youtube_id);
        },80);
    }else{
        destroyYouTube();
        loadVideo(current);
    }

    document.getElementById("nowTitle").textContent=
        (current.code||"")+" - "+(current.title||"");
    document.getElementById("nowArtist").textContent=
        current.artist||"Unknown artist";
    currentSongId=current.id;
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

                currentIsYouTube=!!(current.youtube && current.youtube_id);
                if(currentSongId!==current.id){
                    currentSongId=current.id;
                    if(current.youtube && current.youtube_id){
                        loadYouTube(current.youtube_id);
                    }else{
                        loadVideo(current);
                    }
                }

                if(!remoteCommand){
                    if(current.youtube && ytPlayer){
                        try{
                            if(data.playing) ytPlayer.playVideo();
                            else ytPlayer.pauseVideo();
                        }catch(e){}
                    }else{
                        if(data.playing && video.paused && video.readyState>=2){
                            video.play().catch(()=>{});
                        }
                        if(!data.playing && !video.paused){
                            video.pause();
                        }
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
                    destroyYouTube();
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
        if(song.youtube && song.youtube_id){
            loadingVideo=true;
            loadYouTube(song.youtube_id);
            loadingVideo=false;
        }else{
            loadVideo(song);
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

    destroyYouTube();
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

// DOUBLE TAP:
// Mobile: directly enter/exit normal video-container fullscreen.
// Desktop: popup when normal; exit native fullscreen when already fullscreen.
let lastTapTime=0;
let lastTapX=0;
let lastTapY=0;
let lastTapPointerId=null;

function handleDoubleTap(e){
    if(e.type==="pointerup"){
        if(e.pointerType==="mouse" && e.button!==0)return;
        if(lastTapPointerId!==null && e.pointerId!==lastTapPointerId)return;
        lastTapPointerId=e.pointerId;
    }

    const now=Date.now();
    const x=(typeof e.clientX==="number") ? e.clientX : 0;
    const y=(typeof e.clientY==="number") ? e.clientY : 0;
    const dx=Math.abs(x-lastTapX);
    const dy=Math.abs(y-lastTapY);

    if(lastTapTime>0 && (now-lastTapTime)<=500 && dx<=120 && dy<=120){
        if(e.cancelable)e.preventDefault();

        lastTapTime=0;
        lastTapX=0;
        lastTapY=0;

        if(document.fullscreenElement){
            exitAllFullscreen();
        }else if(isMobileView()){
            fullscreenVideoOnly();
        }else{
            openFullscreenPicker();
        }
        return true;
    }

    lastTapTime=now;
    lastTapX=x;
    lastTapY=y;
    return false;
}

videoWrapper.addEventListener("pointerup",handleDoubleTap,{capture:true,passive:false});

videoWrapper.addEventListener("dblclick",function(e){
    e.preventDefault();
    e.stopPropagation();

    if(document.fullscreenElement){
        exitAllFullscreen();
    }else if(isMobileView()){
        fullscreenVideoOnly();
    }else{
        openFullscreenPicker();
    }
});

video.addEventListener("ended",nextSong);

video.addEventListener("play",async()=>{
    if(remoteCommand || videoWrapper.classList.contains("youtube-active"))return;
    try{
        await api("/api/player/set-playing",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({playing:true})
        });
    }catch(e){}
});

video.addEventListener("pause",async()=>{
    if(remoteCommand || videoWrapper.classList.contains("youtube-active"))return;
    if(video.ended)return;

    try{
        await api("/api/player/set-playing",{
            method:"POST",
            headers:{"Content-Type":"application/json"},
            body:JSON.stringify({playing:false})
        });
    }catch(e){}
});

async function waitForYouTubeReady(timeout=3000){
    if(!currentIsYouTube && !videoWrapper.classList.contains("youtube-active"))return true;
    const started=Date.now();
    while(Date.now()-started<timeout){
        if(ytPlayer && ytPlayerReady)return true;
        await new Promise(r=>setTimeout(r,100));
    }
    return !!(ytPlayer && ytPlayerReady);
}

async function togglePlay(){
    try{
        remoteCommand=true;

        // After a YouTube DROP the old iframe is destroyed and a completely
        // new player is created. Wait for that new player to become ready
        // BEFORE toggling the server state, so the returned state can always
        // be applied to the correct YouTube player.
        const isYT=currentIsYouTube || videoWrapper.classList.contains("youtube-active");
        if(isYT){
            await waitForYouTubeReady(3000);
        }

        const data=await api("/api/player/toggle",{method:"POST"});

        if(data.ok){
            if(currentIsYouTube || videoWrapper.classList.contains("youtube-active")){
                const applyYT=()=>{
                    if(!ytPlayer || !ytPlayerReady)return false;
                    try{
                        const state=ytPlayer.getPlayerState();
                        if(data.playing){
                            ytPlayer.playVideo();
                        }else{
                            ytPlayer.pauseVideo();
                        }
                        return true;
                    }catch(e){return false;}
                };
                if(!applyYT()){
                    setTimeout(applyYT,100);
                    setTimeout(applyYT,300);
                    setTimeout(applyYT,600);
                    setTimeout(applyYT,1000);
                    setTimeout(applyYT,1500);
                    setTimeout(applyYT,2200);
                    setTimeout(applyYT,3000);
                }
            }else if(data.playing){
                await video.play().catch(()=>{});
            }else{
                video.pause();
            }
        }
    }catch(e){
        console.error(e);
    }finally{
        setTimeout(()=>{remoteCommand=false;},700);
    }
}

async function nextSong(){
    try{
        const data=await api("/api/player/next",{method:"POST"});
        if(!data.ok)return;

        // Use the same HARD REMOVE + CREATE NEW IFRAME flow as queue DROP.
        // This prevents the previous YouTube iframe/player from continuing
        // playback when NEXT switches to another YouTube song.
        currentSongId=null;
        lastPlayerVersion=-1;
        if(data.current){
            applyDroppedCurrentSong(data.current);
        }
        setTimeout(()=>updatePlayer(),120);
    }catch(e){
        console.error(e);
    }
}

async function previousSong(){
    try{
        const data=await api("/api/player/previous",{method:"POST"});
        if(!data.ok)return;

        // Same HARD REMOVE + CREATE NEW IFRAME flow for PREV.
        currentSongId=null;
        lastPlayerVersion=-1;
        if(data.current){
            applyDroppedCurrentSong(data.current);
        }
        setTimeout(()=>updatePlayer(),120);
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
        item.draggable=true;
        item.dataset.position=String(index);

        item.innerHTML=`
            <div class="drag-handle" title="Drag">☷</div>
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
                    onclick="event.stopPropagation();removeQueue(${index})">
                REMOVE
            </button>
        `;
        const dragHandle=item.querySelector(".drag-handle");
        if(dragHandle){
            dragHandle.setAttribute("aria-label","Drag song");
            dragHandle.draggable=false;
        }

        // Desktop: drag anywhere on the queue item. Mobile: custom long-press
        // drag anywhere on the song row (except the REMOVE button).
        item.addEventListener("dragstart",(e)=>{
            item.classList.add("dragging");
            e.dataTransfer.effectAllowed="move";
            e.dataTransfer.setData("text/plain",String(index));
            window.queueDragPosition=index;
        });

        item.addEventListener("dragend",()=>{
            item.classList.remove("dragging");
            document.querySelectorAll(".queue-item.drag-over").forEach(x=>x.classList.remove("drag-over"));
            window.queueDragPosition=null;
        });

        item.addEventListener("dragover",(e)=>{
            e.preventDefault();
            e.dataTransfer.dropEffect="move";
            document.querySelectorAll(".queue-item.drag-over").forEach(x=>{
                if(x!==item)x.classList.remove("drag-over");
            });
            item.classList.add("drag-over");
        });

        item.addEventListener("dragleave",()=>{
            item.classList.remove("drag-over");
        });

        item.addEventListener("drop",async(e)=>{
            e.preventDefault();
            e.stopPropagation();
            item.classList.remove("drag-over");

            const from=Number(e.dataTransfer.getData("text/plain"));
            const to=Number(item.dataset.position);

            if(!Number.isInteger(from)||!Number.isInteger(to)||from===to)return;

            try{
                const data=await api("/api/queue/reorder",{
                    method:"POST",
                    headers:{"Content-Type":"application/json"},
                    body:JSON.stringify({
                        from_position:from,
                        to_position:to
                    })
                });
                if(data.ok){
                    lastPlayerVersion=-1;
                    await updatePlayer();
                }
            }catch(err){
                console.error("Queue reorder:",err);
            }
        });

        // MOBILE / TOUCH: hold for 350ms, then drag.
        let touchTimer=null;
        let touchDragging=false;
        let touchStartX=0, touchStartY=0;
        let touchClone=null;
        let touchGrabOffsetX=0, touchGrabOffsetY=0;

        const cancelTouchDrag=()=>{
            if(touchTimer){clearTimeout(touchTimer);touchTimer=null;}
            if(touchClone){touchClone.remove();touchClone=null;}
            item.classList.remove("touch-dragging");
            document.querySelectorAll(".queue-item.touch-drag-over").forEach(x=>x.classList.remove("touch-drag-over"));
            touchDragging=false;
        };

        const positionTouchClone=(x,y)=>{
            if(!touchClone)return;
            const w=touchClone.getBoundingClientRect().width;
            const h=touchClone.getBoundingClientRect().height;
            let left=x-touchGrabOffsetX;
            let top=y-touchGrabOffsetY;
            left=Math.max(6,Math.min(left,window.innerWidth-w-6));
            top=Math.max(6,Math.min(top,window.innerHeight-h-6));
            touchClone.style.left=left+"px";
            touchClone.style.top=top+"px";
            touchClone.style.transform="scale(1.02)";
        };

        item.addEventListener("pointerdown",(e)=>{
            if(e.pointerType!=="touch")return;
            e.preventDefault();
            touchStartX=e.clientX;
            touchStartY=e.clientY;
            try{dragHandle.setPointerCapture(e.pointerId);}catch(_){}
            touchTimer=setTimeout(()=>{
                touchTimer=null;
                touchDragging=true;
                item.classList.add("touch-dragging");
                try{item.setPointerCapture(e.pointerId);}catch(_){}

                // Small floating copy makes it obvious that the song is being dragged.
                const rect=item.getBoundingClientRect();
                touchGrabOffsetX=e.clientX-rect.left;
                touchGrabOffsetY=e.clientY-rect.top;
                touchClone=item.cloneNode(true);
                touchClone.classList.add("touch-drag-clone");
                touchClone.style.width=Math.min(rect.width,window.innerWidth-12)+"px";
                document.body.appendChild(touchClone);
                positionTouchClone(e.clientX,e.clientY);
            },350);
        });

        item.addEventListener("pointermove",(e)=>{
            if(e.pointerType!=="touch")return;

            const dx=e.clientX-touchStartX;
            const dy=e.clientY-touchStartY;
            // Allow small finger movement while waiting for the long-press.
            // Do not cancel the timer just because the finger moved a little.
            if(!touchDragging && Math.hypot(dx,dy)>45){
                if(touchTimer){clearTimeout(touchTimer);touchTimer=null;}
                return;
            }

            if(!touchDragging)return;
            e.preventDefault();

            if(touchClone){
                positionTouchClone(e.clientX,e.clientY);
            }

            const target=document.elementFromPoint(e.clientX,e.clientY);
            const queueTarget=target && target.closest(".queue-item");
            document.querySelectorAll(".queue-item.touch-drag-over").forEach(x=>x.classList.remove("touch-drag-over"));
            if(queueTarget && queueTarget!==item){
                queueTarget.classList.add("touch-drag-over");
            }

            const playerTarget=target && target.closest("#playPauseButton");
            if(playerTarget){
                document.getElementById("playPauseButton")?.classList.add("drop-target");
            }else{
                document.getElementById("playPauseButton")?.classList.remove("drop-target");
            }
        });

        item.addEventListener("contextmenu",(e)=>e.preventDefault());

        item.addEventListener("pointerup",async(e)=>{
            if(e.pointerType!=="touch")return;
            if(touchTimer){clearTimeout(touchTimer);touchTimer=null;}

            if(!touchDragging)return;

            e.preventDefault();
            const target=document.elementFromPoint(e.clientX,e.clientY);
            const queueTarget=target && target.closest(".queue-item");
            const playerTarget=target && target.closest("#playPauseButton");
            const from=Number(item.dataset.position);

            cancelTouchDrag();
            document.getElementById("playPauseButton")?.classList.remove("drop-target");

            if(!Number.isInteger(from))return;

            // Drop on PLAY / PAUSE = move to front of queue, then NEXT.
            if(playerTarget){
                try{
                    const queueData=await api("/api/player");
                    const queue=queueData.queue||[];
                    const song=queue[from];
                    if(!song)return;

                    // DROP ON PLAY/PAUSE = NEXT.
                    // Move dropped song to queue position 0, then advance to it.
                    const reorder=await api("/api/queue/reorder",{
                        method:"POST",
                        headers:{"Content-Type":"application/json"},
                        body:JSON.stringify({
                            from_position:from,
                            to_position:0
                        })
                    });
                    if(reorder.ok){
                        lastPlayerVersion=-1;
                        await updatePlayer();

                        const data=await api("/api/player/next",{method:"POST"});
                        if(data.ok){
                            currentSongId=null;
                            lastPlayerVersion=-1;
                            if(data.current){
                                applyDroppedCurrentSong(data.current);
                            }
                            setTimeout(()=>updatePlayer(),120);
                        }
                    }
                }catch(err){
                    console.error("Touch queue drop-to-play:",err);
                }
                return;
            }

            // Drop on another queue item = reorder.
            if(queueTarget && queueTarget!==item){
                const to=Number(queueTarget.dataset.position);
                if(Number.isInteger(to) && from!==to){
                    try{
                        const data=await api("/api/queue/reorder",{
                            method:"POST",
                            headers:{"Content-Type":"application/json"},
                            body:JSON.stringify({
                                from_position:from,
                                to_position:to
                            })
                        });
                        if(data.ok){
                            lastPlayerVersion=-1;
                            await updatePlayer();
                        }
                    }catch(err){
                        console.error("Touch queue reorder:",err);
                    }
                }
            }
        });

        item.addEventListener("pointercancel",()=>{
            if(touchTimer){clearTimeout(touchTimer);touchTimer=null;}
            cancelTouchDrag();
            document.getElementById("playPauseButton")?.classList.remove("drop-target");
        });

        container.appendChild(item);
    });
}

// Drag any queued song onto PLAY / PAUSE = move it to front, then NEXT.
(function setupQueueDropToPlayer(){
    const dropTarget=document.getElementById("playPauseButton");
    if(!dropTarget)return;

    dropTarget.addEventListener("dragover",(e)=>{
        const types=e.dataTransfer && e.dataTransfer.types;
        if(!types || !Array.from(types).includes("text/plain"))return;
        e.preventDefault();
        e.dataTransfer.dropEffect="copy";
        dropTarget.classList.add("drop-target");
    });

    dropTarget.addEventListener("dragleave",()=>{
        dropTarget.classList.remove("drop-target");
    });

    dropTarget.addEventListener("drop",async(e)=>{
        e.preventDefault();
        e.stopPropagation();
        dropTarget.classList.remove("drop-target");

        const from=Number(e.dataTransfer.getData("text/plain"));
        if(!Number.isInteger(from))return;

        try{
            const queueData=await api("/api/player");
            const queue=queueData.queue||[];
            const song=queue[from];
            if(!song)return;

            // DROP ON PLAY/PAUSE = NEXT.
            // Move dropped song to queue position 0, then advance to it.
            const reorder=await api("/api/queue/reorder",{
                method:"POST",
                headers:{"Content-Type":"application/json"},
                body:JSON.stringify({
                    from_position:from,
                    to_position:0
                })
            });

            if(reorder.ok){
                lastPlayerVersion=-1;
                await updatePlayer();

                const data=await api("/api/player/next",{method:"POST"});
                if(data.ok){
                    currentSongId=null;
                    lastPlayerVersion=-1;
                    if(data.current){
                        applyDroppedCurrentSong(data.current);
                    }
                    setTimeout(()=>updatePlayer(),120);
                }
            }
        }catch(err){
            console.error("Queue drop-to-play:",err);
        }
    });
})();


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

async function playerHeartbeat(){
    try{
        const r=await fetch("/api/player-heartbeat",{
            cache:"no-store",
            headers:{"X-Jukebox-Player-Token":playerToken}
        });
        if(!r.ok) throw new Error("heartbeat failed");
    }catch(e){
        // Normal connection recovery is handled by the existing player polling.
    }
}
playerHeartbeat();
setInterval(playerHeartbeat,2000);
document.addEventListener("visibilitychange",()=>{ if(!document.hidden) playerHeartbeat(); });

// Player lifetime is controlled by heartbeat, not by pagehide/beforeunload.
// This keeps the Player alive for as long as the tab remains open, even when
// the browser fires a page lifecycle event (for example during bfcache).

setRemoteQr();
updatePlayer();
startPlayerCommandPoll();

// Keep normal state synchronization as fallback.
setInterval(updatePlayer,2000);
</script>

<div id="qrPopup" class="qr-popup" aria-hidden="true">
  <div class="qr-popup-card" onclick="event.stopPropagation()">
    <button class="qr-popup-close" id="qrPopupClose" aria-label="Close">×</button>
    <div class="qr-popup-title">SCAN FOR REMOTE</div>
    <img id="qrPopupImage" alt="Remote QR">
    <div class="qr-popup-hint">Tap outside or × to close</div>
  </div>
</div>


<script>
(function(){
  let qrPopupOriginalParent=null;

  function openQrPopup(){
    const src = document.getElementById("videoQr")?.src || document.getElementById("fullscreenQr")?.src;
    const popup = document.getElementById("qrPopup");
    const image = document.getElementById("qrPopupImage");
    if(!popup || !image || !src) return;

    // When the Player uses the browser Fullscreen API, only descendants of
    // the fullscreen element are visible above the video. Move the popup
    // into that element while it is open.
    const fs=document.fullscreenElement;
    if(fs && popup.parentElement!==fs){
      qrPopupOriginalParent=popup.parentElement;
      fs.appendChild(popup);
    }

    image.src = src;
    popup.classList.add("show");
    popup.setAttribute("aria-hidden","false");
  }
  function closeQrPopup(){
    const popup = document.getElementById("qrPopup");
    if(!popup) return;
    popup.classList.remove("show");
    popup.setAttribute("aria-hidden","true");
    if(qrPopupOriginalParent){
      qrPopupOriginalParent.appendChild(popup);
      qrPopupOriginalParent=null;
    }
  }

  // If fullscreen is exited while the QR popup is open, return it to the
  // normal document so it remains usable on the next fullscreen session.
  document.addEventListener("fullscreenchange",()=>{
    const popup=document.getElementById("qrPopup");
    if(!popup || !popup.classList.contains("show")) return;
    if(!document.fullscreenElement){
      popup.classList.remove("show");
      popup.setAttribute("aria-hidden","true");
      if(qrPopupOriginalParent){
        qrPopupOriginalParent.appendChild(popup);
        qrPopupOriginalParent=null;
      }
    }
  });
  window.openQrPopup = openQrPopup;
  document.addEventListener("DOMContentLoaded", function(){
    ["videoQr","fullscreenQr"].forEach(function(id){
      const el=document.getElementById(id);
      if(el) el.addEventListener("click", openQrPopup);
    });
    const close=document.getElementById("qrPopupClose");
    if(close) close.addEventListener("click", closeQrPopup);
    const popup=document.getElementById("qrPopup");
    if(popup) popup.addEventListener("click", function(e){
      if(e.target===popup) closeQrPopup();
    });
    document.addEventListener("keydown", function(e){
      if(e.key==="Escape") closeQrPopup();
    });
  });
})();
</script>


<!-- Fullscreen Mode Picker -->
<div id="fullscreenPicker" class="modal-overlay" style="display:none;z-index:99999;">
  <div class="modal-box fullscreen-picker-box">
    <div class="modal-title">Fullscreen</div>
    <div class="fullscreen-picker-subtitle">Choose fullscreen mode</div>
    <button class="fullscreen-choice" onclick="customFullscreenWithQueue()">
      <span class="choice-icon">⛶</span>
      <span><b>Custom Fullscreen</b><small>Fullscreen with Queue</small></span>
    </button>
    <button class="fullscreen-choice" onclick="fullscreenVideoOnly()">
      <span class="choice-icon">⛶</span>
      <span><b>Fullscreen</b><small>Video Container + Video / iframe</small></span>
    </button>
    <button class="fullscreen-cancel" onclick="closeFullscreenPicker()">Cancel</button>
  </div>
</div>


<script>
function isMobileView(){
    // IMPORTANT: Match the same breakpoint used by the fullscreen CSS:
    // @media(max-width:850px)
    //
    // This keeps the JS behavior exactly synchronized with the CSS.
    // <=850px = mobile layout/fullscreen, >850px = desktop popup.
    return window.innerWidth <= 850;
}

function openFullscreenPicker(){
    // Mobile: NEVER show the mode popup.
    // Keep the mobile fullscreen behavior direct.
    if(isMobileView()){
        if(typeof fullscreenVideoOnly==="function"){
            fullscreenVideoOnly();
        }
        return;
    }

    const p=document.getElementById("fullscreenPicker");
    if(!p)return;
    p.classList.add("show");
    p.style.display="flex";
    p.style.visibility="visible";
    p.style.opacity="1";
    p.style.pointerEvents="auto";
}
function closeFullscreenPicker(){
    const p=document.getElementById("fullscreenPicker");
    if(!p)return;
    p.classList.remove("show");
    p.style.display="none";
    p.style.pointerEvents="none";
}
function updateFullscreenButton(){
    const btn=document.getElementById("fullscreenButton");
    if(!btn)return;

    const active=!!document.fullscreenElement ||
        (typeof document.body!=="undefined" &&
         document.body.classList.contains("fullscreen"));

    btn.setAttribute("aria-label",active ? "Exit Fullscreen" : "Fullscreen");
    btn.title=active ? "Exit Fullscreen" : "Fullscreen";

    // ICON ONLY — no "Fullscreen" / "Exit Fullscreen" text.
    const icon=btn.querySelector(".fullscreen-icon");
    const text=btn.querySelector(".fullscreen-text");

    if(icon) icon.textContent=active ? "🗗" : "⛶";
    if(text) text.textContent="";

    if(!icon && !text){
        if(btn.children.length===0){
            btn.textContent=active ? "🗗" : "⛶";
        }else{
            let stateIcon=btn.querySelector(".fullscreen-state-icon");
            if(!stateIcon){
                stateIcon=document.createElement("span");
                stateIcon.className="fullscreen-state-icon";
                btn.insertBefore(stateIcon,btn.firstChild);
            }
            stateIcon.textContent=active ? "🗗" : "⛶";
        }
    }

    btn.classList.toggle("is-fullscreen",active);
}

async function exitAllFullscreen(){
    try{
        if(document.fullscreenElement){
            await document.exitFullscreen();
        }
    }catch(e){
        console.error("Exit native fullscreen failed:",e);
    }

    // Existing custom fullscreen toggle should be used to exit custom mode.
    if(document.body.classList.contains("fullscreen")
       && typeof toggleFullscreen==="function"){
        try{ await toggleFullscreen(); }catch(e){ console.error(e); }
    }

    updateFullscreenButton();
}

document.addEventListener("fullscreenchange",updateFullscreenButton);
document.addEventListener("webkitfullscreenchange",updateFullscreenButton);

async function fullscreenVideoOnly(){
    // NORMAL FULLSCREEN:
    // Fullscreen the VIDEO CONTAINER, which contains either the local
    // <video> element or the YouTube <iframe>.
    // The queue/header/page outside this container stays outside fullscreen.
    try{
        if(document.fullscreenElement){
            await document.exitFullscreen();
            updateFullscreenButton();
            return;
        }

        const target = (typeof videoWrapper!=="undefined") ? videoWrapper : null;

        if(!target){
            throw new Error("Video container not found");
        }

        if(target.requestFullscreen){
            await target.requestFullscreen();
        }else if(target.webkitRequestFullscreen){
            target.webkitRequestFullscreen();
        }else{
            throw new Error("Container fullscreen API unavailable");
        }
        updateFullscreenButton();
    }catch(e){
        console.error("Video container fullscreen failed:",e);
        alert("Fullscreen is not supported by this browser/device.");
    }
}

async function customFullscreenWithQueue(){
    // CUSTOM FULLSCREEN: use the existing Jukebox custom fullscreen.
    // This keeps the Jukebox queue and its custom player layout.
    try{
        if(typeof toggleFullscreen==="function"){
            await toggleFullscreen();
        }else{
            console.error("Existing custom fullscreen function not found.");
        }
    }catch(e){
        console.error("Custom fullscreen failed:",e);
    }
}

async function chooseFullscreenMode(mode){
    closeFullscreenPicker();

    if(mode==="fullscreen"){
        await fullscreenVideoOnly();
    }else if(mode==="custom"){
        await customFullscreenWithQueue();
    }
}

// Close when tapping the dark area, but not when tapping the dialog itself.
document.addEventListener("click",function(e){
    const p=document.getElementById("fullscreenPicker");
    if(p && e.target===p)closeFullscreenPicker();
});

updateFullscreenButton();
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
            document.getElementById("msg").textContent=data.message||"Unable to create player";
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

REMOTE_SELECT_HTML = r"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Karaoke Remote - Select Player</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;background:#090909;color:#fff;font-family:Arial,Helvetica,sans-serif}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{width:min(460px,100%);background:#111;border:1px solid #2b2b2b;border-radius:18px;padding:26px;box-shadow:0 20px 60px #000;text-align:center}
.icon{font-size:48px}.title{font-size:24px;font-weight:900;margin:8px 0}.text{color:#aaa;line-height:1.5;margin-bottom:18px}
.status{font-size:13px;color:#999;margin:10px 0 14px}
.players{display:flex;flex-direction:column;gap:10px;text-align:left}
.player{width:100%;border:1px solid #353535;background:#1a1a1a;color:#fff;border-radius:12px;padding:14px 16px;cursor:pointer;display:flex;align-items:center;justify-content:space-between}
.player:active{transform:scale(.99)}
.player:hover{background:#242424}
.player-main{display:flex;align-items:center;gap:12px}.dot{width:11px;height:11px;border-radius:50%;background:#4caf50;box-shadow:0 0 10px #4caf50}
.player-name{font-size:16px;font-weight:800}.player-sub{font-size:11px;color:#888;margin-top:3px}.arrow{font-size:22px;color:#aaa}
.empty{padding:16px;border:1px dashed #383838;border-radius:12px;color:#888}
.refresh{margin-top:15px;width:100%;height:44px;border:1px solid #3b3b3b;border-radius:10px;background:#222;color:#fff;font-weight:800;cursor:pointer}
</style>
</head>
<body>
<div class="card">
<div class="icon">🎤</div>
<div class="title">SELECT PLAYER</div>
<div class="text">Piliin kung aling Karaoke Player ang kokontrolin ng remote na ito.</div>
<div id="status" class="status">Hinahanap ang active players...</div>
<div id="players" class="players"></div>
<button class="refresh" onclick="loadPlayers()">↻ REFRESH PLAYERS</button>
</div>
<script>
async function loadPlayers(){
 const status=document.getElementById('status');
 const box=document.getElementById('players');
 status.textContent='Hinahanap ang active players...';
 box.innerHTML='';
 try{
   const r=await fetch('/api/players',{cache:'no-store'});
   const d=await r.json();
   if(!d.ok) throw new Error(d.message||'Unable to load players');
   if(!d.players.length){
     status.textContent='Walang active Player ngayon.';
     box.innerHTML='<div class="empty">Buksan muna ang <b>PLAYER</b> page sa bawat playback device.</div>';
     return;
   }
   status.textContent=d.players.length+' active Player'+(d.players.length===1?'':'s')+' found';
   d.players.forEach(p=>{
     const btn=document.createElement('button');
     btn.className='player';
     btn.onclick=()=>selectPlayer(p.token);
     btn.innerHTML='<div class="player-main"><span class="dot"></span><div><div class="player-name">PLAYER '+escapeHtml(p.id)+'</div><div class="player-sub">Active • Ready</div></div></div><span class="arrow">›</span>';
     box.appendChild(btn);
   });
 }catch(e){
   status.textContent='Hindi makuha ang Players.';
   box.innerHTML='<div class="empty">Check ang connection sa Karaoke server.</div>';
 }
}
function selectPlayer(token){
 const url='/remote?player='+encodeURIComponent(token);
 localStorage.setItem('jukebox_selected_player',token);
 location.replace(url);
}
function escapeHtml(v){
 return String(v).replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\'':'&#39;','"':'&quot;'}[c]));
}
loadPlayers();
setInterval(loadPlayers,5000);
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
.youtube-search-section{width:100%;padding-top:2px;margin-top:2px;display:none}.youtube-process{margin-top:7px;padding:8px 10px;color:#aaa;font-size:11px;font-weight:700;background:#111;border:1px solid #292929;border-radius:7px;display:none;line-height:1.35}.youtube-process.active{display:block}.youtube-process .yt-dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:#888;margin-right:6px;animation:ytpulse 1s infinite}.youtube-process.done{display:block;color:#aaa}.youtube-results{border-top:1px solid #292929;margin-top:4px;padding-top:10px}.youtube-load-wrap{padding:6px 7px;margin:5px 0 0;background:#090909;border-top:1px solid #292929;border-bottom:1px solid #292929;position:relative;z-index:2;box-shadow:none;flex:0 0 auto}.youtube-load-button{display:block;width:100%;padding:9px 12px;border:1px solid #3a3a3a;border-radius:8px;background:#171717;color:#fff;font-size:13px;font-weight:900;letter-spacing:.3px;cursor:pointer}.youtube-load-button:hover{background:#222}.youtube-load-button:active{transform:scale(.99)}.youtube-load-button:disabled{opacity:.45;cursor:not-allowed}@keyframes ytpulse{0%,100%{opacity:.3}50%{opacity:1}}
.youtube-heading{font-size:12px;font-weight:900;color:#f44;margin-bottom:6px;letter-spacing:.5px}
.youtube-song{display:grid;grid-template-columns:96px minmax(0,1fr) 42px;gap:8px;align-items:center;padding:8px;border:1px solid #252525;border-radius:7px;background:#111;margin-bottom:6px;cursor:pointer}.youtube-info{min-width:0}.youtube-test-state{font-size:9px;font-weight:800;margin-top:4px;letter-spacing:.2px}.youtube-test-state.testing{color:#777}.youtube-test-state.playable{color:#8bc34a}.youtube-test-state.timeout{color:#c5a85b}.youtube-song.youtube-removing{opacity:.15;transform:scale(.98);transition:opacity .18s ease,transform .18s ease}
.youtube-thumb{width:96px;height:54px;object-fit:cover;background:#222;border-radius:4px}
.youtube-title{font-size:12px;font-weight:700;line-height:1.25}
.youtube-channel{font-size:10px;color:#888;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.youtube-add{width:36px;height:36px;border:0;border-radius:6px;background:#242424;color:#fff;font-size:20px}
.song-list{
overflow-y:auto;
padding-bottom:0;
overflow-x:hidden;
flex:0 0 80vh;
min-height:0;
height:80vh;
max-height:80vh;
-webkit-overflow-scrolling:touch;
overscroll-behavior:contain
}
.song{display:grid;grid-template-columns:60px minmax(0,1fr) 48px;gap:10px;align-items:center;padding:10px 14px;border-bottom:1px solid #222;cursor:pointer}.song.has-thumbnail{grid-template-columns:72px minmax(0,1fr) 48px}.song-thumb-wrap{width:72px;height:42px;border-radius:5px;overflow:hidden;background:#222;display:flex;align-items:center;justify-content:center}.song-thumb{width:100%;height:100%;object-fit:cover;display:block}

.song:hover{background:#151515}
.code{color:#777;font-family:monospace;font-size:13px}
.info{min-width:0}
.title{font-size:15px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.artist{color:#888;font-size:12px;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.add{width:40px;height:40px;border:0;border-radius:50%;background:#fff;color:#000;font-size:24px;font-weight:700;cursor:pointer;position:relative;z-index:2}
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
.song{grid-template-columns:44px minmax(0,1fr) 40px;gap:6px;padding:7px 7px}.song.has-thumbnail{grid-template-columns:58px minmax(0,1fr) 40px}.song-thumb-wrap{width:58px;height:34px}

.title{font-size:13px}
.artist{font-size:11px}
.code{font-size:11px}
.add{width:36px;height:36px;font-size:20px}
.control{min-width:34px;height:32px;padding:0 5px;font-size:13px}
.player-link{padding:7px 8px;font-size:10px}
}
@media(max-width:700px){
.song-list{padding-bottom:0;scroll-padding-bottom:58px;height:80vh;max-height:80vh;flex:0 0 80vh}
.youtube-load-wrap{position:relative;z-index:2;margin-top:8px;padding:6px;background:#090909}
.youtube-load-button{min-height:40px;padding:8px 10px;font-size:12px}
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
<div id="connectionStatus" class="connection-status connected"><span class="connection-dot"></span> <span id="connectionText">CONNECTED</span></div>
<button class="control" onclick="remotePreviousSong()" title="Previous">⏮</button>
<button id="playButton" class="control play" onclick="remoteTogglePlay()" title="Play/Pause">▶</button>
<button class="control" onclick="remoteNextSong()" title="Next">⏭</button>
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
<div id="youtubeProcess" class="youtube-process" style="display:none"></div>
</div>

<div id="songList" class="song-list">
  <!-- YouTube loader is moved to the absolute end by renderSongs(). -->
  <div id="youtubeLoadItem" class="youtube-load-wrap">
    <button id="loadYouTubeButton" class="youtube-load-button" type="button" disabled>▶ LOAD FROM YOUTUBE</button>
  </div>
  <div id="youtubeSearchSection" class="youtube-search-section">
    <div id="youtubeResults" class="youtube-results" style="display:none"></div>
  </div>
</div>
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
let youtubeSearchTimer=null;
let youtubeSearchInFlight=false;
let youtubeLoadRequested=false;
let refreshInFlight=false;


let connectionFailCount=0;
let statusPollInFlight=false;
let reconnectInFlight=false;

(function loadYouTubeVerifierAPI(){
    if(window.YT && typeof YT.Player === "function")return;
    const tag=document.createElement("script");
    tag.src="https://www.youtube.com/iframe_api";
    document.head.appendChild(tag);
})();
window.onYouTubeIframeAPIReady=function(){ window.jukeboxYouTubeAPIReady=true; };

const remotePlayerToken=new URLSearchParams(location.search).get("player")||localStorage.getItem("jukebox_remote_player_token")||"";
if(remotePlayerToken)localStorage.setItem("jukebox_remote_player_token",remotePlayerToken);

async function api(url,options={},retries=2){
    let lastError;

    for(let attempt=0;attempt<=retries;attempt++){
        const controller=new AbortController();
        const timeout=setTimeout(()=>controller.abort(),8000);

        try{
            const response=await fetch(url,{
                cache:"no-store",
                ...options,
                headers:{
                    ...(options.headers||{}),
                    ...(remotePlayerToken?{"X-Jukebox-Player-Token":remotePlayerToken}: {})
                },
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

function getPlayerCode(){
    const t = new URLSearchParams(location.search).get("player") || "";
    return t ? "[" + t.slice(0,6).toUpperCase() + "]" : "";
}
function setConnectionStatus(online){
    const status=document.getElementById("status");
    const badge=document.getElementById("connectionStatus");
    const text=document.getElementById("connectionText");
    const code=getPlayerCode();
    if(!online){
        if(status){
            status.textContent="⚠ CONNECTION LOST — reconnecting...";
            status.classList.add("connection-lost");
        }
        if(badge)badge.className="connection-status offline";
        if(text)text.textContent="OFFLINE " + code;
        return;
    }
    if(status)status.classList.remove("connection-lost");
    if(badge)badge.className="connection-status connected";
    if(text)text.textContent="CONNECTED " + code;
}
function setReconnecting(){
    const badge=document.getElementById("connectionStatus");
    const text=document.getElementById("connectionText");
    if(badge)badge.className="connection-status reconnecting";
    if(text)text.textContent="RECONNECTING " + getPlayerCode();
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

function waitForYouTubeAPI(timeoutMs=8000){
    return new Promise((resolve)=>{
        if(window.YT && typeof YT.Player === "function"){
            resolve(true); return;
        }
        const started=Date.now();
        const timer=setInterval(()=>{
            if(window.YT && typeof YT.Player === "function"){
                clearInterval(timer); resolve(true); return;
            }
            if(Date.now()-started>=timeoutMs){
                clearInterval(timer); resolve(false);
            }
        },100);
    });
}

function verifyYouTubeEmbed(videoId, timeoutMs=4500){
    return new Promise((resolve)=>{
        let finished=false;
        let player=null;
        let timer=null;
        let result="timeout";
        const host=document.createElement("div");
        host.style.cssText="position:fixed;left:-20000px;top:-20000px;width:320px;height:180px;opacity:0;pointer-events:none;overflow:hidden;";
        document.body.appendChild(host);

        const finish=(status)=>{
            if(finished)return;
            finished=true;
            result=status;
            if(timer)clearTimeout(timer);
            try{if(player)player.destroy();}catch(e){}
            try{host.remove();}catch(e){}
            resolve(status);
        };

        // Timeout means the test could not decide. Keep the result visible.
        // Only an explicit YouTube player error means "not playable" and
        // causes the result to be removed.
        timer=setTimeout(()=>finish("timeout"),timeoutMs);

        if(!(window.YT && typeof YT.Player === "function")){
            finish("timeout");
            return;
        }

        try{
            player=new YT.Player(host,{
                width:"320",height:"180",videoId:String(videoId),
                playerVars:{
                    autoplay:0,controls:0,playsinline:1,rel:0,fs:0,
                    enablejsapi:1,origin:window.location.origin
                },
                events:{
                    onReady:function(event){
                        try{
                            event.target.mute();
                            event.target.playVideo();
                        }catch(e){
                            // Do not remove merely because autoplay was blocked.
                        }
                    },
                    onStateChange:function(event){
                        const state=Number(event.data);
                        if(state===1 || state===3){
                            finish("ok");
                        }
                    },
                    onError:function(event){
                        // Explicit YouTube error = not playable in this embed.
                        finish("error");
                    }
                }
            });
        }catch(e){
            // A local JS exception is not proof that the video is unplayable.
            finish("timeout");
        }
    });
}

async function verifyYouTubeResults(results,process,box){
    if(!results.length)return [];

    const apiReady=await waitForYouTubeAPI(10000);
    if(!apiReady){
        if(process){
            process.className="youtube-process done";
            process.innerHTML='✓ YouTube: playback test unavailable — results kept';
        }
        return results;
    }

    const kept=[...results];

    // All API-filtered results are displayed immediately. Each one is tested
    // afterwards; only an explicit player error removes its row.
    for(let i=0;i<results.length;i++){
        const song=results[i];
        const row=document.querySelector('[data-youtube-id="'+CSS.escape(String(song.youtube_id))+'"]');
        if(process){
            process.className="youtube-process active";
            process.innerHTML='<span class="yt-dot"></span> YouTube: testing video '+(i+1)+'/'+results.length+'...';
        }

        let verdict="timeout";
        try{
            verdict=await verifyYouTubeEmbed(song.youtube_id,4500);
        }catch(e){
            verdict="timeout";
        }

        if(verdict==="error"){
            const index=kept.findIndex(x=>String(x.youtube_id)===String(song.youtube_id));
            if(index>=0)kept.splice(index,1);
            if(row){
                row.classList.add("youtube-removing");
                setTimeout(()=>{try{row.remove();}catch(e){}},180);
            }
        }else if(row){
            const state=row.querySelector(".youtube-test-state");
            if(state){
                state.textContent=verdict==="ok" ? "✓ PLAYABLE" : "• TEST TIMEOUT — KEPT";
                state.className="youtube-test-state "+(verdict==="ok" ? "playable" : "timeout");
            }
        }

        // IMPORTANT: saving must NOT depend on the result row still existing in
        // the DOM. The row can be re-rendered while testing. A confirmed
        // playable result is saved directly from the test result.
        if(verdict==="ok"){
            try{
                const saveResponse=await fetch("/api/youtube-save-playable",{
                    method:"POST",
                    cache:"no-store",
                    headers:{"Content-Type":"application/json"},
                    body:JSON.stringify({
                        youtube_id:song.youtube_id,
                        title:song.title,
                        artist:song.artist||"",
                        thumbnail:song.thumbnail||""
                    })
                });
                if(!saveResponse.ok){
                    console.error("Save playable YouTube HTTP error:",saveResponse.status);
                }else{
                    const saveData=await saveResponse.json().catch(()=>null);
                    console.log("Saved playable YouTube:",saveData);
                }
            }catch(e){
                console.error("Save playable YouTube:",e);
            }
        }
    }
    return kept;
}

async function loadYouTubeResults(query){
    const section=document.getElementById("youtubeSearchSection");
    const box=document.getElementById("youtubeResults");
    const process=document.getElementById("youtubeProcess");
    if(!section || !box)return;
    if(!query){
        section.style.display="none";
        box.style.display="none";
        box.innerHTML="";
        return;
    }
    section.style.display="block";
    if(youtubeSearchInFlight)return;
    youtubeSearchInFlight=true;
    box.style.display="block";
    box.innerHTML=`<div class="youtube-heading">▶ YOUTUBE RESULTS</div>`;
    if(process){
        process.className="youtube-process active";
        process.innerHTML='<span class="yt-dot"></span> YouTube: searching videos...';
        process.style.display="block";
    }
    try{
        const data=await api("/api/youtube-search?q="+encodeURIComponent(query));
        if(!data.ok)throw new Error(data.message||"YouTube search failed");
        const results=data.results||[];

        if(!results.length){
            box.innerHTML+=`<div class="empty">No YouTube results found</div>`;
            if(process){process.className="youtube-process done";process.innerHTML='✓ YouTube: search complete — 0 results';}
            return;
        }

        // Display EVERYTHING returned by the API immediately. Verification
        // runs after rendering, and only explicit not-playable errors remove
        // a row from the list.
        for(const song of results){
            const row=document.createElement("div");
            row.className="youtube-song";
            row.dataset.youtubeId=String(song.youtube_id);
            row.innerHTML=`
                <img class="youtube-thumb" src="${escapeHtml(song.thumbnail||"")}" alt="">
                <div class="youtube-info">
                    <div class="youtube-title">${escapeHtml(song.title)}</div>
                    <div class="youtube-channel">${escapeHtml(song.artist)}</div>
                    <div class="youtube-test-state testing">● TESTING...</div>
                </div>
                <button class="youtube-add" title="Add to queue">+</button>`;
            row.onclick=()=>showSongActionPrompt(song);
            const addButton=row.querySelector(".youtube-add");
            addButton.onclick=(event)=>{
                event.stopPropagation();
                addSong(song.id,addButton);
            };
            box.appendChild(row);
        }

        if(process){
            process.className="youtube-process active";
            process.innerHTML='<span class="yt-dot"></span> YouTube: testing displayed results...';
        }

        const kept=await verifyYouTubeResults(results,process,box);
        const removed=results.length-kept.length;
        if(process){
            process.className="youtube-process done";
            process.innerHTML='✓ YouTube: '+kept.length+' playable result'+(kept.length===1?'':'s')+
                (removed ? ' • '+removed+' removed' : '');
        }

        const remainingRows=box.querySelectorAll(".youtube-song");
        if(!remainingRows.length){
            box.innerHTML=`<div class="youtube-heading">▶ YOUTUBE RESULTS</div><div class="empty">No playable YouTube results found</div>`;
        }
    }catch(e){
        console.error("YouTube search:",e);
        box.innerHTML=`<div class="youtube-heading">▶ YOUTUBE RESULTS</div><div class="empty">No YouTube results found</div>`;
        section.style.display="block";
        box.style.display="block";
        if(process){process.className="youtube-process done";process.innerHTML='✓ YouTube: search complete';}
    }finally{
        youtubeSearchInFlight=false;
    }
}

async function loadSongs(reset=true){
    const search=document.getElementById("search").value.trim();
    const offset=reset ? 0 : songsOffset;
    const key=selectedFolder+"|"+search+"|"+offset;

    if(!reset && offset===0 && key===lastSongsRequestKey)return;

    if(reset){
        songsOffset=0;
        hasMoreSongs=true;
        songs=[];
        // Keep the YouTube process/results section mounted. Clearing songList
        // directly would delete the loading indicator before the search runs.
        const songList=document.getElementById("songList");
        const youtubeSection=document.getElementById("youtubeSearchSection");
        const youtubeLoadItem=document.getElementById("youtubeLoadItem");
        if(songList){
            // Preserve BOTH YouTube UI nodes before clearing the song list.
            // Previously innerHTML removed youtubeLoadItem from the DOM, so
            // renderSongs() could no longer find it and the button disappeared.
            songList.innerHTML="";
            if(youtubeSection) songList.appendChild(youtubeSection);
            if(youtubeLoadItem) songList.appendChild(youtubeLoadItem);
        }
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

document.getElementById("loadYouTubeButton").addEventListener("click",()=>{
    const query=document.getElementById("search").value.trim();
    if(!query || youtubeSearchInFlight)return;

    youtubeLoadRequested=true;
    const section=document.getElementById("youtubeSearchSection");
    const process=document.getElementById("youtubeProcess");
    const box=document.getElementById("youtubeResults");
    if(section) section.style.display="block";
    if(process){
        process.className="youtube-process active";
        process.innerHTML='<span class="yt-dot"></span> YouTube: searching videos...';
        process.style.display="block";
    }
    if(box){box.style.display="block";box.innerHTML="";}
    clearTimeout(youtubeSearchTimer);
    youtubeSearchTimer=setTimeout(()=>loadYouTubeResults(query),0);
});

document.getElementById("search")
    .addEventListener("keydown",(e)=>{
        if(e.key !== "Enter") return;
        e.preventDefault();

        const query=document.getElementById("search").value.trim();
        const section=document.getElementById("youtubeSearchSection");
        const process=document.getElementById("youtubeProcess");
        const box=document.getElementById("youtubeResults");

        clearTimeout(searchTimer);
        clearTimeout(youtubeSearchTimer);

        if(!query){
            if(section) section.style.display="none";
            if(process){process.style.display="none";process.innerHTML="";}
            if(box){box.style.display="none";box.innerHTML="";}
            songs=[];
            songsOffset=0;
            totalSongs=0;
            hasMoreSongs=true;
            lastSongsRequestKey="";
            loadSongs(true);
            return;
        }

        // Enter searches the local karaoke library only.
        // YouTube is optional and is requested explicitly with the button below.
        if(section) section.style.display="none";
        if(process){process.style.display="none";process.innerHTML="";}
        if(box){box.style.display="none";box.innerHTML="";}
        youtubeLoadRequested=false;

        songs=[];
        songsOffset=0;
        totalSongs=0;
        hasMoreSongs=true;
        lastSongsRequestKey="";
        loadSongs(true);
    });

document.getElementById("search").addEventListener("input",()=>{
    const button=document.getElementById("loadYouTubeButton");
    if(button) button.disabled=!document.getElementById("search").value.trim();
});

// Also support form/programmatic submit if the search field is inside a form.
document.getElementById("search").addEventListener("search",()=>{
    const e=new KeyboardEvent("keydown",{key:"Enter",bubbles:true});
    document.getElementById("search").dispatchEvent(e);
});

function renderSongs(clear=true){
    const container=document.getElementById("songList");
    const youtubeSection=document.getElementById("youtubeSearchSection");
    const youtubeLoadItem=document.getElementById("youtubeLoadItem");
    // Keep both YouTube UI items while rebuilding the song list.
    if(youtubeSection && youtubeSection.parentNode===container) youtubeSection.remove();
    if(youtubeLoadItem && youtubeLoadItem.parentNode===container) youtubeLoadItem.remove();

    if(clear) container.innerHTML="";

    // YouTube loader belongs at the END of the song list.
    // Keep it out of the way during normal local browsing.

    document.getElementById("folderTitle").textContent=
        selectedFolder ? folderName(selectedFolder) : "ALL SONGS";

    document.getElementById("songCount").textContent=
        songs.length+" / "+totalSongs+" songs";

    if(!songs.length){
        container.innerHTML='<div class="empty">No songs found</div>';
        if(youtubeSection) container.appendChild(youtubeSection);
        if(youtubeLoadItem){
            youtubeLoadItem.style.display = "block";
            container.appendChild(youtubeLoadItem);
        }
        return;
    }

    const existingIds=new Set(
        Array.from(container.querySelectorAll(".song"))
            .map(row=>row.dataset.songId)
    );

    for(const song of songs){
        if(existingIds.has(song.id)) continue;

        const row=document.createElement("div");
        const hasThumb=!!(song.youtube && song.thumbnail);
        row.className="song"+(hasThumb?" has-thumbnail":"");
        row.dataset.songId=song.id;

        row.onclick=()=>showSongActionPrompt(song);

        row.innerHTML=`
            ${hasThumb ? `<div class="song-thumb-wrap"><img class="song-thumb" src="${escapeHtml(song.thumbnail)}" alt=""></div>` : `<div class="code">${escapeHtml(song.code)}</div>`}
            <div class="info">
                ${hasThumb ? `<div class="code">${escapeHtml(song.code)}</div>` : ``}
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
            "padding:10px;text-align:center;color:#777;font-size:10px;";
        container.appendChild(sentinel);
    }

    document.getElementById("status").textContent=
        hasMoreSongs
            ? songs.length+" of "+totalSongs+" songs loaded"
            : totalSongs+" songs loaded";

    document.getElementById("status").classList.remove("connection-lost");

    // FINAL ORDER: all local songs -> sentinel (if any) -> YouTube results -> LOAD FROM YOUTUBE.
    // The button is always appended LAST, never before the search results.
    if(youtubeSection){
        container.appendChild(youtubeSection);
    }
    if(youtubeLoadItem){
        youtubeLoadItem.style.display = "block";
        container.appendChild(youtubeLoadItem);
    }

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

    const isYoutube=!!song.youtube;
    overlay.innerHTML=`
        <div class="song-action-card" role="dialog" aria-modal="true">
            <h2>${isYoutube?"YouTube":"What do you want to do?"}</h2>

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

async function remoteNextSong(){
    try{
        const data=await api("/api/player/next",{method:"POST"});
        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function remotePreviousSong(){
    try{
        const data=await api("/api/player/previous",{method:"POST"});
        if(!data.ok)return;

        serverPlaying=true;
        updatePlayButton();
    }catch(e){
        console.error(e);
    }
}

async function remoteTogglePlay(){
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


// Watch the selected Player itself. The Remote must not keep a disconnected Player alive.
(function(){
    const selected=new URLSearchParams(location.search).get("player");
    if(!selected)return;
    let disconnectedShown=false;
    async function checkSelectedPlayer(){
        try{
            const r=await fetch("/api/connection-status",{
                cache:"no-store",
                headers:{"X-Jukebox-Player-Token":selected}
            });
            const d=await r.json();
            if(!d.player_active && !disconnectedShown){
                disconnectedShown=true;
                const overlay=document.createElement("div");
                overlay.id="playerDisconnectedOverlay";
                overlay.style.cssText="position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.82);display:flex;align-items:center;justify-content:center;padding:20px";
                overlay.innerHTML=`<div style="width:min(390px,100%);background:#171717;border:1px solid #333;border-radius:18px;padding:28px;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.6)">
                    <div style="font-size:48px;margin-bottom:8px">⚠️</div>
                    <div style="font-size:21px;font-weight:900;margin-bottom:8px">PLAYER DISCONNECTED</div>
                    <div style="color:#999;font-size:14px;margin-bottom:22px">The selected Karaoke Player is no longer connected.</div>
                    <button onclick="location.replace('/remote')" style="width:100%;height:46px;border:0;border-radius:10px;background:#fff;color:#000;font-weight:900;cursor:pointer">SELECT ANOTHER PLAYER</button>
                </div>`;
                document.body.appendChild(overlay);
            }
        }catch(e){
            // A temporary Wi-Fi/server error is not immediately treated as a Player disconnect.
        }
    }
    checkSelectedPlayer();
    setInterval(checkSelectedPlayer,2000);
})();
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



def _ansi_box(title, url, accent, icon, description, info_lines):
    """Render a compact left-side panel with the right side intentionally open."""
    import qrcode
    import shutil

    term_width=shutil.get_terminal_size(fallback=(100,40)).columns

    # Use roughly half the terminal width so the right side stays open.
    box_width=max(42, min(60, (term_width-4)//2))
    if box_width > term_width-4:
        box_width=max(30, term_width-4)

    qr=qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=1,
        border=4
    )
    qr.add_data(url)
    qr.make(fit=True)
    matrix=qr.get_matrix()
    if len(matrix)%2:
        matrix.append([False]*len(matrix[0]))

    qr_width=len(matrix[0])
    inner_width=box_width-2
    qr_left=max(0,(inner_width-qr_width)//2)

    RESET='\033[0m'
    WHITE_BG='\033[47m'
    BLACK='\033[30m'
    WHITE='\033[97m'

    def left_line(text='', color=''):
        text=str(text)
        if len(text)>inner_width:
            text=text[:max(0,inner_width-1)]+'…'
        return '│'+color+text.center(inner_width)+RESET

    print()
    print('╭'+'─'*box_width)
    print(left_line(title,accent))
    print('├'+'─'*box_width)

    # Full QR, centered within the left-side half panel.
    for y in range(0,len(matrix),2):
        chars=[]
        for x in range(qr_width):
            top=matrix[y][x]
            bottom=matrix[y+1][x]
            if top and bottom:
                chars.append('█')
            elif top:
                chars.append('▀')
            elif bottom:
                chars.append('▄')
            else:
                chars.append(' ')
        qr_line=' '*qr_left + WHITE_BG + BLACK + ''.join(chars) + RESET
        right=max(0,inner_width-qr_left-qr_width)
        qr_line += ' '*right
        print('│'+qr_line)

    print('├'+'─'*box_width)
    print(left_line(icon+'  '+title.split(' QR')[0],accent))
    print(left_line(description,WHITE))
    print()
    print('│'+accent+'INFO:'+RESET+' '*max(0,inner_width-5))
    for item in info_lines:
        txt='• '+item
        if len(txt)>inner_width:
            txt=txt[:inner_width-1]+'…'
        print('│'+WHITE+txt.ljust(inner_width)+RESET)
    print()
    print('│'+accent+'URL:'+RESET+' '*max(0,inner_width-4))
    url_text=url
    if len(url_text)>inner_width:
        url_text=url_text[:inner_width-1]+'…'
    print('│'+('\033[96m'+url_text+RESET).center(inner_width+len(RESET)+len('\033[96m')))
    print('╰'+'─'*box_width)

def print_terminal_qr(title, url):
    """Compatibility wrapper used by the startup screen."""
    if 'PLAYER' in title.upper():
        _ansi_box(
            title,
            url,
            '\033[96m',
            '🖥',
            'Open on the device connected to TV',
            [
                'Scan this QR code',
                'This device acts as a PLAYER',
                'Each Player has its own Player Code',
                'Each Player has an independent queue',
            ]
        )
    else:
        _ansi_box(
            title,
            url,
            '\033[95m',
            '📱',
            'Open on a phone, tablet or other device',
            [
                'Scan this QR code',
                'Select the Player you want to control',
                'Remote shows CONNECTED [PLAYER CODE]',
                'Search, play and add songs to queue',
            ]
        )


def print_startup_ui(player_url, remote_url):
    """Centered terminal startup screen matching the requested reference style."""
    import shutil
    term_width=shutil.get_terminal_size(fallback=(100,40)).columns
    RESET='\033[0m'
    CYAN='\033[96m'
    GREEN='\033[92m'
    YELLOW='\033[93m'
    MAGENTA='\033[95m'
    DIM='\033[90m'

    print('\033[2J\033[H',end='')
    print('╭'+'─'*max(20,term_width-2)+'╮')
    print('│'+CYAN+'🎤  KARAOKE JUKEBOX'.center(max(20,term_width-2))+RESET+'│')
    print('│'+GREEN+'START SERVER SUCCESSFUL'.center(max(20,term_width-2))+RESET+'│')
    print('╰'+'─'*max(20,term_width-2)+'╯')

    print_terminal_qr('PLAYER QR CODE',player_url)
    print_terminal_qr('REMOTE QR CODE',remote_url)

    inner=max(20,term_width-4)
    print('╭'+'─'*inner+'╮')
    print('│'+YELLOW+'QUICK GUIDE'.center(inner)+RESET+'│')
    print('├'+'─'*inner+'┤')
    guide=[
        ('PLAYER','Each Player has its own Player Code and independent queue.'),
        ('REMOTE','Scan Remote QR, then select the Player to control.'),
        ('MULTI-PLAYER','Multiple Players can run at the same time.'),
        ('--zip','ZIP STORED; originals are deleted after successful zip.'),
        ('SERVER','Normal HTTP logs are SILENT; important errors remain visible.'),
    ]
    for key,val in guide:
        text=f'{key:<13} │ {val}'
        if len(text)>inner:
            text=text[:inner-1]+'…'
        print('│'+text.ljust(inner)+'│')
    print('╰'+'─'*inner+'╯')
    print()
    status='●  SERVER RUNNING     │     ●  HTTP LOGS SILENT'
    print('╭'+'─'*inner+'╮')
    print('│'+GREEN+status.center(inner)+RESET+'│')
    print('╰'+'─'*inner+'╯')
    print()

class JukeboxHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    server_version = "KaraokeJukebox/2.0-ZIP-FIXED-QR"
    timeout = 15

    def setup(self):
        super().setup()
        try:
            self.connection.settimeout(30)
        except Exception:
            pass

    def log_message(self, fmt, *args):
        pass

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

    def send_svg(self, svg):
        body = svg.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "image/svg+xml")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
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
                token=normalize_player_token(urllib.parse.parse_qs(parsed.query).get("token",[None])[0])
            if not token:
                self.redirect("/player")
                return
            get_player_state(token, True)
            self.send_html(PLAYER_HTML.replace("__JUKEBOX_VERSION__", JUKEBOX_VERSION))
            return

        if path=="/remote":
            remote_token=normalize_player_token(urllib.parse.parse_qs(parsed.query).get("player",[None])[0])
            if not remote_token:
                self.send_html(REMOTE_SELECT_HTML)
            else:
                cleanup_players()
                with players_lock:
                    active = remote_token in players and (time.time()-players[remote_token].get("last_seen",0) <= PLAYER_IDLE_TIMEOUT)
                if active:
                    self.send_html(REMOTE_HTML)
                else:
                    self.send_html(REMOTE_SELECT_HTML)
            return

        if path=="/api/qr":
            data = urllib.parse.parse_qs(parsed.query).get("data", [""])[0]
            if not data:
                self.send_response(400)
                self.end_headers()
                return

            qr = qrcode.QRCode(
                version=None,
                error_correction=qrcode.constants.ERROR_CORRECT_M,
                box_size=1,
                border=4,
            )
            qr.add_data(data)
            qr.make(fit=True)
            matrix = qr.get_matrix()
            size = len(matrix)

            # Pure SVG generation: no image file, no external URL, fully local.
            rects = []
            for y, row in enumerate(matrix):
                for x, cell in enumerate(row):
                    if cell:
                        rects.append(f'<rect x="{x}" y="{y}" width="1" height="1"/>')

            svg = (
                f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
                f'shape-rendering="crispEdges"><rect width="100%" height="100%" fill="white"/>'
                f'<g fill="black">{"".join(rects)}</g></svg>'
            )
            self.send_svg(svg)
            return

        if path=="/api/youtube-search":
            query=urllib.parse.parse_qs(parsed.query).get("q",[""])[0].strip()
            if not query:
                self.send_json({"ok":True,"results":[]})
                return
            try:
                results=youtube_search(query)
                self.send_json({"ok":True,"results":results})
            except urllib.error.HTTPError as e:
                try:
                    detail=e.read().decode("utf-8",errors="replace")
                except Exception:
                    detail=""
                self.send_json({"ok":False,"message":"YouTube API error", "detail":detail[:500]},502)
            except Exception as e:
                self.send_json({"ok":False,"message":str(e)},500)
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

            if folder==SAVED_LINKS_FOLDER:
                source=get_saved_youtube_songs()
            elif folder:
                source=[
                    song for song in source
                    if song_folder_path(song)==folder
                ]

            # ALL SONGS includes permanently saved playable YouTube links.
            # They are also searchable from the same ALL SONGS list.
            if folder=="":
                existing_ids={song["id"] for song in source}
                for saved_song in get_saved_youtube_songs():
                    if saved_song["id"] not in existing_ids:
                        source.append(saved_song)
                        existing_ids.add(saved_song["id"])

            if search:
                # Search ALL SONGS against both the local karaoke library and
                # permanently saved playable YouTube links.  Saved YouTube
                # entries are not part of search_index, so explicitly use
                # search_blob() for them (and for all entries) here.
                source=[
                    song for song in source
                    if search in search_blob(song)
                ]

            total=len(source)
            page=source[offset:offset+limit]
            has_more=(offset+len(page))<total

            # Preserve existing folder-count behavior.
            with state_lock:
                all_source=songs[:]

            if search:
                if folder!=SAVED_LINKS_FOLDER:
                    existing_ids={song["id"] for song in all_source}
                    for saved_song in get_saved_youtube_songs():
                        if saved_song["id"] not in existing_ids:
                            all_source.append(saved_song)
                            existing_ids.add(saved_song["id"])
                all_source=[
                    song for song in all_source
                    if search in index.get(song["id"], search_blob(song))
                ]

            folder_counts={}
            for song in all_source:
                folder_path=song_folder_path(song)
                if folder_path:
                    folder_counts[folder_path]=folder_counts.get(folder_path,0)+1

            saved_count=len(get_saved_youtube_songs())
            # Always expose the Saved Links folder so it is visible in the Remote.
            folder_counts[SAVED_LINKS_FOLDER]=saved_count

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

        if path=="/api/players":
            cleanup_players()
            now=time.time()
            result=[]
            with players_lock:
                for token,state in players.items():
                    if now-state.get("last_seen",0) <= PLAYER_IDLE_TIMEOUT:
                        result.append({
                            "token":token,
                            "id":token[:6].upper(),
                            "last_seen":state.get("last_seen",0),
                        })
            result.sort(key=lambda x:x["id"])
            self.send_json({"ok":True,"players":result})
            return

        if path=="/api/player":
            token=get_player_token(self)
            state=get_player_state(token,False)
            if state is None:
                self.send_json({"ok":False,"message":"Missing player token"},400)
                return

            with state_lock:
                current=(
                    public_song_by_id(state["current_song_id"])
                    if state["current_song_id"] else None
                )
                result_queue=[
                    public_song_by_id(sid)
                    for sid in state["queue"]
                    if get_song_by_id(sid) is not None
                ]
                playing=state["playing"]
                version=state["version"]

            self.send_json({
                "ok":True,
                "version":version,
                "current":current,
                "queue":result_queue,
                "playing":playing
            })
            return

        if path=="/api/player-heartbeat":
            token=get_player_token(self)
            if not token:
                self.send_json({"ok":False,"message":"Missing player token"},400)
                return
            with players_lock:
                state=players.get(token)
                if state is None:
                    self.send_json({"ok":False,"player_active":False,"message":"Player not found"},404)
                    return
                state["last_seen"]=time.time()
            self.send_json({"ok":True,"player_active":True})
            return

        if path=="/api/player-command":
            token=get_player_token(self)
            state=get_player_state(token,False)
            if state is None:
                self.send_json({"ok":False,"message":"Missing player token"},400)
                return
            with state_lock:
                cmd=state["command"]
                if cmd is not None:
                    cmd=dict(cmd)
                    if isinstance(cmd.get("song"),dict): cmd["song"]=dict(cmd["song"])
            self.send_json({"ok":True,"command":cmd})
            return
        if path=="/api/connection-status":
            token=get_player_token(self)
            now=time.time()
            with players_lock:
                state=players.get(token) if token else None
                last_seen=state.get("last_seen") if state else None
            age=(now-last_seen) if last_seen else None
            active=bool(state and age is not None and age <= PLAYER_IDLE_TIMEOUT)

            self.send_json({
                "ok":True,
                "player_active":active,
                "last_seen":last_seen,
                "age":round(age,2) if age is not None else None,
                "timeout":PLAYER_IDLE_TIMEOUT
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

        if path=="/api/youtube-save-playable":
            try:
                video_id=str(data.get("youtube_id","")).strip()
                title=str(data.get("title","")).strip()
                artist=str(data.get("artist","")).strip()
                thumbnail=str(data.get("thumbnail","")).strip()
                saved,message=save_playable_youtube_link(video_id,title,artist,thumbnail)
                self.send_json({"ok":True,"saved":saved,"message":message})
            except Exception as e:
                self.send_json({"ok":False,"message":str(e)},500)
            return

        if path=="/api/player/claim":
            token=get_player_token(self)
            if not token:
                self.send_json({"ok":False,"message":"Missing Player tab token"},400)
                return
            get_player_state(token,True)
            self.send_json({"ok":True,"player_id":token})
            return

        if path=="/api/player/release":
            token=get_player_token(self)
            if token:
                with players_lock:
                    players.pop(token,None)
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

            ok,message=add_to_queue(get_player_token(self),song_id)

            self.send_json({
                "ok":ok,
                "message":message,
                "queue":get_queue(get_player_token(self))
            })
            return

        if path=="/api/queue/remove":

            try:
                position=int(data.get("position"))
            except Exception:
                position=-1

            ok,message=remove_from_queue(get_player_token(self),position)

            self.send_json({
                "ok":ok,
                "message":message,
                "queue":get_queue(get_player_token(self))
            })
            return

        if path=="/api/queue/reorder":
            try:
                from_position=int(data.get("from_position"))
                to_position=int(data.get("to_position"))
            except Exception:
                from_position=-1
                to_position=-1

            ok,message=reorder_queue(
                get_player_token(self),
                from_position,
                to_position
            )

            self.send_json({
                "ok":ok,
                "message":message,
                "queue":get_queue(get_player_token(self))
            })
            return

        if path=="/api/queue/clear":

            clear_queue(get_player_token(self))

            self.send_json({
                "ok":True,
                "message":"Queue cleared"
            })
            return

        if path=="/api/player/next":

            next_song=start_next_song(get_player_token(self))

            if next_song is None:
                self.send_json({
                    "ok":False,
                    "message":"Queue is empty",
                    "current":None,
                    "queue":get_queue(get_player_token(self))
                })
                return

            self.send_json({
                "ok":True,
                "current":next_song,
                "queue":get_queue(get_player_token(self))
            })
            return

        if path=="/api/player/previous":

            previous_song=start_previous_song(get_player_token(self))

            if previous_song is None:
                self.send_json({
                    "ok":False,
                    "message":"No previous song"
                })
                return

            self.send_json({
                "ok":True,
                "current":previous_song,
                "queue":get_queue(get_player_token(self))
            })
            return

        if path=="/api/player/toggle":

            playing=toggle_playing(get_player_token(self))

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

            playing=set_playing(get_player_token(self),value)

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

            if not set_current_song(get_player_token(self),song_id):
                self.send_json({
                    "ok":False,
                    "message":"Song not found"
                },404)
                return

            self.send_json({
                "ok":True,
                "current":get_current_song(get_player_token(self))
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

    if "--generate" in __import__("sys").argv[1:]:
        generate_jukebox_key()
        return

    if not require_jukebox_key():
        return

    print()
    print("==========================================")
    print(f"       KARAOKE JUKEBOX SERVER v{JUKEBOX_VERSION}")
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
    
    print_startup_ui(player_url, remote_url)

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

