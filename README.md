# ccfin

A small Jellyfin music client for CC:Tweaked, built for an Advanced Computer and
one or two speakers. It browses music libraries, albums, and tracks, supports
search, and uses [AUKit](https://github.com/MCJack123/AUKit) directly.

## Install in ComputerCraft

Until this repository has a stable raw URL, copy `ccfin.lua` onto the computer
and install AUKit:

```text
wget https://raw.githubusercontent.com/MCJack123/AUKit/master/aukit.lua
ccfin
```

Alternatively, copy `ccfin-install.lua` next to `ccfin.lua`, then run:

```text
ccfin-install
```

To replace a cached AUKit file with the current upstream version, run:

```text
ccfin-install --force
```

Forced downloads include a unique cache-busting query. AUStream is not needed.

CC:Tweaked must allow HTTP access to both GitHub and the Jellyfin server. Local
Jellyfin addresses are blocked by default; the server owner must allow the host
or private-network access in the ComputerCraft server configuration.
Server addresses entered without a scheme default to HTTPS.

## Playback profiles

- **PCM** asks Jellyfin to decode to headerless 48 kHz, signed 16-bit,
  little-endian stereo PCM. Jellyfin labels this response `audio/wav`, but does
  not include a WAV header. ccfin describes the raw samples explicitly to AUKit.
  This avoids doing FLAC decompression on the ComputerCraft computer, but its
  large response often exceeds CC:Tweaked's HTTP download limit.
- **FLAC** asks Jellyfin for a compressed FLAC response and is the recommended
  profile.
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

Run `ccfin --version` to confirm the installed version. For credential-safe HTTP
diagnostics, run `ccfin --verbose`. It prints request and response metadata and
a redacted login payload, and saves the same output to `.ccfin-debug`;
passwords and access tokens are never printed. Playback diagnostics include
speaker discovery, selected profile, stream response metadata, decoder
selection, and AUKit's return status.

Run `ccfin --probe` to send harmless marker headers to httpbin.org and report
whether CC:Tweaked transmitted both Jellyfin authorization header names.

ccfin follows same-origin HTTP redirects manually so Jellyfin authorization
headers are preserved. It refuses to forward credentials to another origin.
Jellyfin requests use its native `X-Emby-Authorization` header; the reserved
standard `Authorization` header is intentionally avoided for Java HTTP-client
compatibility.
Client identity fields use punctuation-free values for compatibility with
strict structured-authorization parsers.
