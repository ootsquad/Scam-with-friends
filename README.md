# Call Center Chaos

Co-op call center game for Roblox. Players boot into **ChaOS**, a fake computer desktop, form a party, and start
their shift. Synced into Studio with [Rojo](https://rojo.space) 7.7.1; networking uses
[ByteNet-Max](https://github.com/Elitriare/ByteNet-Max).

## Two places, two project files

| Place | Project file | Rojo port | What it is |
| --- | --- | --- | --- |
| Lobby (start place of *Call Center Chaos*) | `default.project.json` | 34872 | ChaOS desktop: Play, Join with Code, Settings |
| **Call Center Place** (`120521915270020`) | `callcenter.project.json` | 34873 | where a crew works its shift |

Parties work across lobby servers (MemoryStore + MessagingService). When the leader starts the shift, the whole
party is teleported into the same **new reserved (private) server** of the Call Center Place. Every crew gets its
own server, nobody else can join it, and Roblox shuts it down once the crew has left.

## Packages

ByteNet-Max is committed under `Packages/` so the project works without extra setup. To update it, bump the
version in `wally.toml` and run `wally install` (Wally is listed in `aftman.toml`).
