---
name: transmission-download
description: Send a quoted magnet link to Transmission and verify it is downloading
version: 0.1.0
author: Tuan Ha
license: MIT
metadata:
  hermes:
    tags: [torrents, magnets, transmission, downloads]
---

# Transmission Download

Use the `transmission` MCP server tools to start and monitor downloads.

## When to Use
- The user quotes or replies to a magnet discovery result (for example from `torrent-magnet-discovery`) and asks to download it.
- The user asks whether a magnet or torrent is downloading, or for the progress of current downloads.
- The user asks to pause or resume a torrent.

## Procedure
1. Extract the exact `magnet:?xt=urn:btih:...` URI from the quoted message. If the quote has several variants and the user did not pick one, ask which. Never alter the URI.
2. Call `add_magnet` with the URI. Leave `download_dir` unset unless the user names one.
   - `ok: false`: report the error text as is.
   - `duplicate: true`: tell the user it was already added, then check its status.
3. Wait about 10 seconds (metadata for a fresh magnet takes a few seconds), then call `get_torrent_status` with the returned `hash`.
4. Report by `verdict`:
   - `downloading`: name, percent, speed, ETA.
   - `fetching_metadata` or `checking`: say it is starting; check again once after about 15 seconds.
   - `stalled`: no data flowing; give peer count and suggest waiting or choosing another variant.
   - `queued`, `paused`, `complete`, `seeding`: state it plainly.
   - `error`: show the `error` text.
5. For "what is downloading?" use `list_torrents` (optionally `verdict="downloading"`).
6. Use `pause_torrent` / `resume_torrent` only when asked.

## Pitfalls
- Only report "downloading" when `verdict` is `downloading`; a successful `add_magnet` alone does not mean data is flowing.
- Send magnets only as plain text in replies on Telegram (see `torrent-magnet-discovery`).
- Removing torrents or deleting data is not supported; tell the user to do it in the Transmission UI.
