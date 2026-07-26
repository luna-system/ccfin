# ccfin

A small Jellyfin music client for CC:Tweaked, built for an Advanced Computer and
one or two speakers. It browses music libraries, albums, and tracks, supports
search, and hands playback to [AUKit](https://github.com/MCJack123/AUKit).

## Install in ComputerCraft

Until this repository has a stable raw URL, copy `ccfin.lua` onto the computer
and install AUKit:

```text
wget https://raw.githubusercontent.com/MCJack123/AUKit/master/aukit.lua
wget https://raw.githubusercontent.com/MCJack123/AUKit/master/austream.lua
ccfin
```

Alternatively, copy `ccfin-install.lua` next to `ccfin.lua`, then run:

```text
ccfin-install
```

CC:Tweaked must allow HTTP access to both GitHub and the Jellyfin server. Local
Jellyfin addresses are blocked by default; the server owner must allow the host
or private-network access in the ComputerCraft server configuration.

## Playback profiles

- **PCM** asks Jellyfin to decode to headerless 48 kHz, signed 16-bit,
  little-endian stereo PCM. Jellyfin labels this response `audio/wav`, but does
  not include a WAV header. ccfin describes the raw samples explicitly to AUKit.
  This avoids doing FLAC decompression on the ComputerCraft computer and is the
  recommended profile.
- **FLAC** asks Jellyfin to produce a 48 kHz FLAC stream.
- **Original FLAC** downloads the original item through Jellyfin.

All CC:Tweaked speaker audio ultimately becomes signed 8-bit PCM at 48 kHz.
That hard limit explains much of the quality difference from the source FLAC.
Using two speakers lets AUKit keep the left and right channels; one speaker is
mixed to mono.

Credentials are exchanged for a Jellyfin access token. The token and server URL
are stored in `.ccfin` on the in-game computer; the password is not stored.

## Controls

Menus show their controls at the bottom. Enter a number to select, `n`/`p` to
change pages, `b` to go back, and `/` from an album list to search.

During playback, hold Ctrl+T to terminate AUKit and return to ccfin.
