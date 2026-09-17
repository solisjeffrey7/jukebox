Karaoke Jukebox Termux Setup v10.5.17

- No termux-setup-storage.
- Does not rm -rf ~/jukebox.
- Uses server_10.5.06.py as the working base when server_v2.py is missing.
- Creates ~/bin/jukebox.
- Adds colorful AutoRun to ~/.zshrc.
- AutoRun runs server_v2.py in the background.
- `jukebox` while already running shows Player and Remote QR.
