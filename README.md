# Call Center Chaos

Co-op call center game for Roblox. Players boot into **ChaOS**, a fake computer desktop, form a crew in a lobby,
and start their shift. Synced into Studio with [Rojo](https://rojo.space) 7.7.1; networking uses
[ByteNet-Max](https://github.com/Elitriare/ByteNet-Max).

## Two places, two project files

| Place | Project file | Rojo port | What it is |
| --- | --- | --- | --- |
| Lobby (start place of *Call Center Chaos*) | `default.project.json` | 34872 | ChaOS desktop: Play, Join with Code, Settings |
| **Call Center Place** (`120521915270020`) | `callcenter.project.json` | 34873 | where a crew works its shift |

When the host starts the shift, the whole crew is teleported **together** into a **new reserved (private) server**
of the Call Center Place. Every crew gets its own server, nobody else can join it, and Roblox shuts it down once
the crew has left.

## Run it

Open the lobby place in Studio and run:

```bash
rojo serve
```

Open the **Call Center Place** in a second Studio window and, in another terminal, run:

```bash
rojo serve callcenter.project.json
```

In that window's Rojo plugin, change the port to **34873** before connecting. **Whenever a `.project.json` file
changes, stop and restart that `rojo serve`**, or new folders won't show up.

### Testing

- **Lobby in Studio:** **Test → Clients and Servers → 2+ players → Start**. Player 1 clicks **Play**, player 2 opens
  **Join with Code** and types player 1's code. Ready up and start. Studio can't teleport, so after the countdown
  everyone gets a "Teleports only work in the live game" notice and the lobby reopens.
- **Call Center Place in Studio:** press Play. You get a test shift (`STUDIO`, Associate) so the arrival screen and
  shift HUD can be tested without teleporting.
- **The real teleport:** publish **both** places, then play the game from the Roblox app or website with friends
  (or 2 accounts). Start a shift from the lobby. You should all land in the same new call center server, and the
  taskbar shows your lobby code. A second crew lands in a different server.

## What's in the game so far

- **Boot screen** (ReplicatedFirst): replaces Roblox's loading screen and shows real boot steps. The same screen is
  the "clocking in" screen, stays up during the teleport, and is picked up again by the Call Center Place.
- **ChaOS desktop** (lobby): wallpaper, desktop icons, taskbar (apps, lobby status, clock), Start menu and
  notifications. Windows open, close, minimize to the taskbar, maximize, and drag by the title bar.
- **Play**: creates a crew lobby, or reopens yours. 4 desks show each player's avatar head, display name and
  @username. Click a free desk to switch seats. The host picks difficulty and starts the shift once everyone is ready.
  **Leave lobby** only appears while you're in one.
- **Join with Code**: join a friend's 6-character code. In the live game this also works across servers
  (MemoryStore lookup + teleport).
- **Settings**: wallpaper (Dusk / Overcast / Night), interface size, 24-hour clock, reduce motion. Saved per player
  with a DataStore in the live game.
- **Call Center Place**: works out which crew it belongs to, shows the shift on a ChaOS taskbar (code, difficulty,
  quota, crew clocked in, clock) and has **Leave shift**, which sends you back to the lobby.

## Layout

```text
default.project.json          lobby place
callcenter.project.json       Call Center Place (reuses shared/, Packages, Ui/ and LoadingController)
src/
  ReplicatedFirst/            -> ReplicatedFirst (lobby)
    Boot.client.luau            shows the boot screen before anything else loads
    LoadingScreen.model.json    boot screen GUI (used by both places)
  StarterGui/                 -> StarterGui (lobby)
    Desktop.model.json          the ChaOS desktop GUI (all windows, taskbar, start menu)
  shared/                     -> ReplicatedStorage.Shared (both places)
    Config/                     LobbyConfig, SettingsConfig, Places (place ids, teleport settings)
    Network/                    ByteNet-Max namespaces: Lobby, Settings, Shift (+ Namespace helper)
    Util/Signal.luau
  server/                     -> ServerScriptService.Server (lobby)
    Services/LobbyService       crew lobbies: create/join/leave, desks, ready, host, start shift
    Services/ShiftLauncher      teleports a crew into its own reserved Call Center Place server
    Services/LobbyDirectory     cross-server codes (MemoryStore + teleport, live game only)
    Services/SettingsService    loads/saves settings (DataStore)
  client/                     -> StarterPlayerScripts.Client (lobby)
    init.client.luau            boot steps shown on the boot screen
    Controllers/                LoadingController (boot screen), DesktopController (desktop + taskbar)
    Apps/                       LobbyApp, JoinApp, SettingsApp (one module per window)
    Stores/                     LobbyStore, SettingsStore (client state + requests to the server)
    Ui/                         Theme, UiScale, Motion, ButtonFx, WindowManager, Notify, Avatar
  callcenter/                 Call Center Place only
    ReplicatedFirst/Arrival     picks the boot screen back up after the teleport
    StarterGui/ShiftHud         shift taskbar + "Leave shift" dialog
    server/Services/ShiftService  which crew/shift this server is for; sends strays back
    client/                     boot steps + Shift/ShiftHud
Packages/                     -> ReplicatedStorage.Packages (Wally layout; ByteNet-Max 0.2.7)
```

## How the teleport works

1. Host presses **Start shift**. `LobbyService` runs the countdown, then calls `ShiftLauncher.Launch`.
2. `ShiftLauncher` calls `TeleportService:TeleportAsync(Places.CallCenter, crew, options)` with
   `options.ShouldReserveServer = true`, which creates a brand-new private server and moves the whole crew into it.
   The shift (lobby code, difficulty, host, crew, return place) goes along as TeleportData and is also written to
   MemoryStore under the new server's `PrivateServerId`.
3. Each client hands its boot screen to `TeleportService:SetTeleportGui`, so the "clocking in" screen stays up.
4. In the Call Center Place, `ShiftService` reads the shift from MemoryStore (trusted), falling back to TeleportData,
   and publishes it as `ReplicatedStorage` attributes (`ShiftCode`, `ShiftDifficulty`, `ShiftQuota`, ...).
   Players who aren't in the crew list are kicked.
5. If one player's teleport fails, they're retried into the **same** server (3 tries). If it still fails they go back
   to their desktop with a message.
6. Anyone who reaches the Call Center Place without a crew (a public server) is sent back. Set `Places.Lobby` in
   `src/shared/Config/Places.luau` to the start place id to teleport them there; at `0` they're kicked with a message.

## How the pieces talk

- The **server owns every lobby**. Clients send requests through `LobbyStore` (ByteNet packets/queries),
  the server validates them and pushes the full lobby state to its members, and the apps re-render from it.
- Screens are designed at **1280x720**. `UiScale` fits them to any screen; the Settings "Interface size"
  option scales on top of that.

## Adding things

- **A network namespace:** create `src/shared/Network/<Name>.luau` with `Namespace.define`, then list it in
  `src/shared/Network/init.luau`.
- **A desktop app:** add a window to the GUI, write `src/client/Apps/<Name>App.luau` with a `Start(window)`, then
  register it in `DesktopController` with `WindowManager.register` (plus an icon or taskbar button).
- **Shift gameplay:** add services next to `src/callcenter/server/Services/ShiftService.luau` and read the shift
  with `ShiftService.Get()`.

## Editing GUIs

The GUI files are Rojo model files. Rojo syncs files into Studio, not the other way around, so edits made in
Studio's Explorer get overwritten on the next sync. Change the `.model.json` files, or ask for the change.
To preview the boot screen in the editor, copy `ReplicatedFirst.LoadingScreen` into StarterGui (GUIs don't
render inside ReplicatedFirst).

## Packages

ByteNet-Max is committed under `Packages/` so the project works without extra setup. To update it, bump the
version in `wally.toml` and run `wally install` (Wally is listed in `aftman.toml`).
