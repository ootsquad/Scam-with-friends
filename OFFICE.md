# Building the office (Call Center Place)

The game finds everything in your office by **tags** (Studio: select a part or model, then Properties > Tags,
or the Tag Editor) and a few names. Nothing here has to be finished for the game to run.

## Desks

- Tag each desk's **Seat** with `Computer`, or tag the whole desk **Model** with `Computer`; a Seat inside is used.
- Optional: give the Seat a text attribute `DeskName` (for example `3`). It's shown on the prompt and the login screen.
- Every desk gets a **Sit down** prompt automatically.
- Name the monitor part `Monitor`, `Computer` or `Screen` to choose which part smokes when the computer breaks.
  Otherwise the tallest part on the desk is used.

## The six floors

The crew starts every shift on floor 1 and moves up one floor after each passed review.

| Floor | Name |
| --- | --- |
| 1 | Rock Bottom |
| 2 | Getting Started |
| 3 | Established |
| 4 | Corporate |
| 5 | Executive |
| 6 | Penthouse |

For each floor:

1. Put everything for that floor in one **Model** or **Folder**, and tag it `OfficeFloor`.
2. Give it a **number attribute** named `Floor`, set to 1–6.
3. Put that floor's desks (tagged `Computer`) inside it.
4. Add a **Part named `FloorSpawn`** inside it, where the crew arrives. Make it anchored, can't collide, and
   transparent.

**How moving up works**

- Floors can be stacked, or built far apart: the crew is moved, so you don't need a working elevator.
- When the crew moves up, everyone sees the elevator screen and is moved to the new floor's `FloorSpawn`.
- Desks on other floors can't be used.
- Players who join or respawn arrive on the crew's floor too.

**If floors are missing**

- If the floor the crew is heading to isn't built yet, they stay on the highest built floor below it. The
  perks still go up.
- With no floors built at all, the whole place is one office.

**Signs:** tag a Part (or a model with SurfaceGuis) `FloorSign`. Its TextLabels show `FLOOR 3 · ESTABLISHED`.

- A sign inside a floor shows that floor.
- A sign anywhere else, like a lobby or an elevator, shows the crew's current floor.

## The equipment store

The store is a room in the office with a vendor players walk up to. It isn't an app on the computer.

1. Build the store room wherever you like: on a floor, or outside the floors (a lobby or a ground-floor shop).
2. Tag the vendor `StoreVendor`. The vendor can be an NPC **Model** (with a Humanoid) or any **Part**, like the
   counter. A plain brick with the tag is enough for now.
3. The vendor gets a **Shop** prompt automatically. Using it opens the store on that player's screen.

- A vendor inside a floor only works while the crew is on that floor. A vendor outside the floors always works.
- Players can only buy within 16 studs of a working vendor. Walking away closes the store.
- Until you've tagged a vendor, a stand-in store counter shows up next to where the crew arrives, so the store
  still works while you build.

## Images

Every icon, store picture and wallpaper is listed by name in `src/shared/Config/ImageConfig.luau`. To change
one, upload the new picture to the group (S&C Production) and paste its id there. A decal id is fine: the
server turns it into the image id by itself.

- Icons are white pictures on a see-through background. They sit on the coloured app tiles and buttons.
- A new upload can take a while to pass Roblox's review. Until then, the game shows the old drawn icons, the
  store's text symbols, and a drawn wallpaper instead.
- In Studio, the Output says how many decal ids were turned into image ids.

## Chores (optional)

All three tags are optional; chores still show up without them.

| Tag | On | What it does |
| --- | --- | --- |
| `TrashSpot` | Parts on the floor | Trash bags appear here. Without them, trash appears next to desks. |
| `TrashBin` | Parts | With bins on a floor, players carry each bag to a bin. Without them, picking it up is enough. |
| `Equipment` | Parts (a router, a server rack, a printer) | These can break. A broken one makes calls worse on the whole floor. Without any, desk computers break instead. |

## Checklist

- [ ] Desks tagged `Computer`, a few per floor (crews are up to 4 players).
- [ ] Floors 1–6, each tagged `OfficeFloor`, with a `Floor` number attribute and a `FloorSpawn` part.
- [ ] A store room with a vendor tagged `StoreVendor`.
- [ ] Optional: `FloorSign`, `TrashSpot`, `TrashBin`, `Equipment`.
- [ ] Game Settings > Avatar > **R15**, so players look like their own avatars.
