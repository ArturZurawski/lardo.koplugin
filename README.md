100% vibe coded

# Lardo

*Mealie recipes for KOReader.*

A KOReader plugin that reads recipes from a self-hosted [Mealie](https://mealie.io/)
server on an e-reader. Everything is reachable **both ways**: with a 5-way controller
and a keyboard (it was built on a Kindle Keyboard, where there is no touch screen at
all) and with a finger on a touch screen. It can **replace the file browser as
KOReader's start-up screen**.

- Recipe list fetched from `/api/recipes`.
- A recipe is split into **chapters** — description, ingredients, instructions, notes —
  with the ingredients one key press away, so you never scroll past the other three
  while cooking.
- **Full screen reading view**: no dialog frame, no oversized title bar. Font size and
  typeface are picked from whatever KOReader has installed — and the recipe list is
  drawn in the same font, because it is read in the same kitchen light.
- Recipes are stored on the device, so once downloaded everything works **without Wi-Fi**.
- The server address and API token go into a **plain text file over USB** — no typing a
  200-character JWT on a Kindle keyboard.
- **Type to filter** by name and description, with the whole screen still on recipes:
  the list has one line of chrome, and it is the recipe count or what you have typed.

## Installation

Copy the `lardo.koplugin` directory into KOReader's plugin folder. On a Kindle:

```
/mnt/us/koreader/plugins/lardo.koplugin/
```

which over USB is simply `koreader/plugins/lardo.koplugin/`. Restart KOReader.
Plugins in that folder are enabled by default; if the menu entry does not show up,
check *Tools → More tools → Plugin management*.

## Configuration (the token, over USB)

Mealie API tokens are long JWTs, and there is no sensible way to type one on a Kindle.
The plugin reads `lardo.conf` from the first of these that exists:

1. `/mnt/us/koreader/settings/lardo.conf` — **the default** (this is where the
   template is created),
2. `/mnt/us/koreader/lardo.conf`,
3. `/mnt/us/lardo.conf`,
4. `/mnt/us/koreader/plugins/lardo.koplugin/lardo.conf`.

All four are checked on every start; the first one found wins. The plugin shows the
full list of paths, already resolved for your device, under
*Connection → Configuration file*.

```ini
# Mealie server address, including the port
url = http://192.168.1.10:9000

# API token from Mealie: Profile → API Tokens → Generate
token = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9....

# Instead of a token you can put your login here and use
# "Log in with username and password" once; the plugin stores the token itself.
#username = me@example.com
#password = secret

# Language Mealie should answer in, and the wording of the recipe chapters.
# Leave empty to follow KOReader's own language.
#language = en-GB
```

The plugin can create this template for you: *Tools → Lardo → Connection →
Configuration file*.

**The file is re-read on its own whenever it changes** — at start-up, and every time you
open the recipe list or refresh it from the server. So: edit `lardo.conf` over USB,
unplug, open the recipe list, and the new settings are live. *Connection → Reload
configuration file* is only a shortcut for the impatient.

It also works **the other way round**: changing the server address or the token from
inside KOReader (including a successful *Log in*) is written back into `lardo.conf`,
so the file you see over USB never disagrees with what the plugin is actually using.
Only the values are rewritten — comments, line order, `username`/`password` and any
keys the plugin does not know are left untouched. If the file does not exist yet, it is
created in the default location.

The file only overrides settings edited in the UI when its contents changed outside the
plugin, so nothing loops back and forth.

## Using it as the start-up screen

Two equivalent places:

- *Settings → File browser → Start with → **Lardo*** — the plugin adds itself
  to KOReader's standard list, or
- *Tools → Lardo → Open Lardo instead of the file browser at start-up*.

KOReader then opens the recipe list straight away. *Menu → Close Lardo* closes the list
and reveals the normal file browser underneath — the device is still an e-reader.

## Key and touch reference

### Recipe list

| Key | Action |
| --- | --- |
| 5-way up / down | move the cursor; at the edge of a page it moves to the next / previous one |
| — | the selected recipe is shown **inverted** (white on black), not merely underlined |
| 5-way centre | open the recipe |
| **any letter** | **filter the list** — it narrows as you type, the typed text is in the title |
| Del | delete the last character of the filter |
| Next Page / Prev Page | next / previous page of the list |
| Shift + Next/Prev Page | last / first page |
| Shift + down | go to a page number |
| **Menu** | actions: filter, sort, refresh, settings, close Lardo |
| Back | clear the filter — and nothing else: Lardo is left through its menu |

The letters used to be KOReader's item shortcuts (press `Q` to open the first row).
Filtering is worth more than that on a list of recipes — and opening a recipe by
accidentally brushing a letter key was never a feature. *Menu → Filter recipes* opens
the same box (on a device with no keyboard it opens an input dialog, the only way to
type there).

**Back never leaves Lardo.** It clears the filter, and with no filter it does nothing;
the way out is *Menu → Close Lardo*. A key that is one thumb-slip away from the page
keys should not drop you out of the recipe you are cooking from.

On a **touch screen**: tap a recipe to open it, tap ☰ for the same menu, and the ✕ in
the title bar closes Lardo (that one is a deliberate tap, so it does what it says).

### Reading a recipe

| Key | Touch | Action |
| --- | --- | --- |
| Next Page / Prev Page | tap the right / left of the page, or swipe up / down | scroll; at the end of a chapter it moves on to the next one, like a book |
| 5-way up / down | — | scroll one line |
| 5-way left / right | swipe left / right | previous / next chapter |
| **S** | — | jump to the ingredients; **press S again to return exactly where you were** |
| **1 … 9** | — | jump to the chapter with that number |
| **Shift + Next/Prev Page** | — | previous / next **recipe** from the list |
| Menu | long press anywhere, or tap the right end of the header | view options: font size and typeface, position bar, button row |
| Back | tap the header (left of the time) | back to the list |

The header is the only chrome the reading view has, so it is also the only thing a tap
can hit that is not text: its right hand end (where the total time is) opens the menu,
the rest of it goes back to the list. On a touch screen the **button row is shown by
default** — it does the same things with labels on them — and can be turned off in
*View* for a full page of recipe.

The plain page keys **never** jump to a different recipe — they scroll within the
current one, moving between its chapters. Switching recipes is on Shift.

Jumping to the ingredients is also a Dispatcher action (*Lardo: jump to the
ingredients*), so it can be bound to any key with the **Hotkeys** plugin.

### Screen layout

The recipe list is one line of chrome and then recipes:

```
☰   12 recipes in Mealie                                 <- idle: what there is
☰   Filter: pan_   2/12                                  <- typing: what is left
    ★ Pancakes                                   20 min  <- a favourite in Mealie
    Pancake sauce                                 5 min
```

No second line repeating the plugin name, no hint about the Menu key — the ☰ is
already there, and a line of the list is a recipe.

**Sorting** is in the same menu (*Menu → Sort by*): by name, newest first (Mealie's
`dateAdded`), recently changed (`updatedAt`), or favourites first. Favourites belong to
the user rather than to the recipe, so they come from `/api/users/self` plus
`/api/users/{id}/favorites` on every refresh; a Mealie too old to have that endpoint
simply shows no stars.

The reading view is deliberately not a `TextViewer`: on a 600×800 screen the frame,
margins, large title bar and button row cost roughly a quarter of the page. Instead:

```
Spaghetti Carbonara                              45 min     <- name + time
Description   Ingredients   Instructions   Notes            <- every chapter, always
▁▁▁▁▁▁▁▁▁▁▁   ▇▇▇▇▇▃▁▁▁▁▁   ▁▁▁▁▁▁▁▁▁▁▁▁   ▁▁▁▁▁            <- progress, per chapter
─────────────────────────────────────────────────────────
- 400 g spaghetti
- 4 egg yolks (at room temperature)
...
```

- **Every chapter is always listed** in the header. The one being read is bold and
  black, the others grey.
- **The progress bar is split per chapter**, each segment sitting exactly under its
  chapter's name. The segment of the chapter you are reading follows the scroll,
  chapters already read stay filled, untouched ones stay empty. By default it sits
  under the chapter names; it can be moved to the bottom edge, to the right edge
  (vertical, flush against the screen, showing the whole recipe) or hidden.
- **The button row at the bottom follows the device** (*View → Button row at the bottom*):
  shown on a touch screen, where it is the only visible way around, hidden on a keyboard
  device, where every button has a key of its own. It costs height either way.
- **Font size** 12–40 (in the recipe menu: `A −` `20` `A +`, the middle one opens a
  picker) and **typeface** from every font KOReader knows about. Both settings are
  **global** — chosen once they apply to every recipe, to the **recipe list** as well,
  and survive a restart. A larger font gives the list fewer, taller rows, because a
  `Menu` row caps its text to the row height. The header stays in the interface font so
  that its height is predictable and it cannot break on a typeface missing some glyphs.
- The same settings appear in two places, and they are one set: *Tools → Lardo →
  View*, and the **Menu** key while reading a recipe (or *Lardo settings → View and
  font* from the list). Each entry shows its current value, so nothing has to be opened
  to see how things stand.
- The font list is a plain KOReader menu, not `FontChooser`: 5-way down walks through
  the pages, with no buttons to hunt for below the list. **Every entry is drawn in the
  font it offers**, so you can see what you are choosing, and selecting one applies it
  immediately.

### When the view cannot be built

The custom view uses a fair amount of KOReader's widget API, which varies between
versions. If it cannot be built for any reason, the plugin **does not leave a blank
screen**: it shows the error, with the reason, and stays on the list.

There used to be a fallback here to KOReader's built-in `TextViewer`. It has been
removed: on a keyboard device its Close button cannot be reached with the 5-way, so a
recipe opened in it could not be left — a worse failure than the one it was covering.

## Language

Mealie has **no "language" field in its API** — it translates every response based on
the request's `Accept-Language` header
([`locale_context.py`](https://github.com/mealie-recipes/mealie/blob/mealie-next/mealie/middleware/locale_context.py)).
So a single setting on our side does both jobs: it is sent to the server *and* it picks
the wording of the chapter names.

Set it in *Tools → Lardo → Language*, or in `lardo.conf`:

```ini
language = pl-PL
```

Empty means "follow KOReader's own language" — and the menu entry says which language
that currently is, whatever the plugin itself is set to.

The setting drives three things:

| | |
| --- | --- |
| `Accept-Language` sent to Mealie | so the server answers in that language |
| the chapter names | wording for cs, de, en, es, fr, it, nl, pl, pt, sv |
| **the plugin's own menus and messages** | English and **Polish** |

KOReader's own gettext only knows the strings that ship with KOReader, so the plugin
carries its interface translations itself, in
[`lardoi18n.lua`](lardo.koplugin/lardoi18n.lua) — a table keyed by the English text,
with Polish plural forms (1 / 2–4 / 5+). Anything missing from it falls back to
KOReader's translations and then to English, so a partial translation is fine.

**The menu offers only English and Polish**, because those are the two the interface is
translated into; the chapter wording for the other languages is still used when
KOReader itself runs in one of them. Adding a language means a block in
[`lardolang.lua`](lardo.koplugin/lardolang.lua) (chapter names), optionally one in
`lardoi18n.lua` (the interface), and its code in `CHOICES`.

## Offline use and incremental sync

There is **one** operation, *Refresh*: one (paginated) `GET /api/recipes` for the index,
and then one request per recipe that the index says is new or has changed. Afterwards
everything is readable with the Wi-Fi off.

(It used to be two entries, *Refresh list* and *Sync all recipes for offline use*. The
distinction was not worth a menu line: the index is what tells you what to fetch, and a
recipe is a few kilobytes of text.)

Mealie returns an `updatedAt` field for every recipe in the index, so that one cheap
request is enough to work out the difference locally, without asking the server about
each recipe:

| Situation | What the plugin does |
| --- | --- |
| on the server, not on the device | download |
| `updatedAt` changed | download again |
| `updatedAt` unchanged | **skip, zero requests** |
| no longer on the server | delete from the device |

So the first refresh downloads everything and every later one costs only what actually
changed — usually a single request for the index and nothing else. Downloading can be
interrupted with any key and resumed later; progress is not lost.

While it runs there is **one message with a counter on it**, and no recipe names: the
message used to be redrawn for every recipe, and that was the slow part of a sync. Each
redraw is an e-ink refresh plus the 100 ms KOReader waits to see whether the message was
tapped away — more time than the few kilobytes of JSON it was announcing. The counter now
moves at most once a second (which is also how often a cancel is noticed), and what the
refresh actually did is said once, at the end.

Independently of that, **opening a recipe** checks `updatedAt`: if the stored copy is
out of date and the device happens to be online, the server version is fetched on the
spot. When Wi-Fi is off the plugin **does not ask you to turn it on** — it shows the
stored copy, because a slightly stale recipe beats a Wi-Fi dialog while you are cooking.

If the server sends no `updatedAt` (a very old Mealie), the plugin does not guess: once
downloaded, a recipe is not fetched again until you clear the cache.

*Delete downloaded recipes* clears the cache.

### Where the recipes live

**One file per recipe**, in `koreader/settings/lardo_recipes/`, next to a small index
in `lardo_cache.lua`: the recipe list as the server sent it, and one line per stored
recipe saying which version of it is on the device.

They all used to be one key in that index file, which meant KOReader parsed every recipe
you had ever downloaded at start-up and kept the lot in memory for as long as it ran — in
order to draw a list of names. For 300 recipes that is ~1.7 MB of Lua against ~190 kB for
the index, and a Kindle Keyboard has 256 MB for everything it does. Now the list is drawn
from the index, "is my copy still current?" is answered by the stamp, and **the recipe
itself is read when you open it** and let go of when you close it. An existing cache is
moved into the new shape once, the first time the plugin starts after the update; nothing
is re-downloaded.

### Doing it without being asked

*Tools → Lardo → Offline → **Refresh at start-up*** does exactly that once when
KOReader starts, instead of waiting for you to open the list.

### Wi-Fi

KOReader has two settings of its own for this (*Network → Action when Wi-Fi is needed* /
**when done**). Bringing the connection up was always KOReader's business; hanging it up
is not automatic — `NetworkMgr:runWhenOnline()` only connects, and the "when done"
setting is acted on by `afterWifiAction()`, which the plugin has to call. It now does,
at the end of every download **including a failed one**, so "turn Wi-Fi off when done"
finally does what it says.

*Test connection* takes the other of KOReader's two doors: `runWhenConnected()` rather
than `runWhenOnline()`. The second one decides with a DNS lookup of its own and, when the
radio is up but that lookup fails, drops the callback without saying anything — which for
a button whose whole job is to report whether the server answers is the one outcome that
helps nobody. `runWhenConnected()` needs the link, brings it up the same way, and
guarantees the answer: either the recipe count, or the reason there is none.

### Falling asleep

KOReader asks every widget to save its settings on the way into suspend
(`Device:_beforeSuspend()` → `FlushSettings`), and `LuaSettings:flush()` rewrites the
whole file every time it is called — renames the old one aside, serialises the table,
fsyncs the result. For us that file is **every recipe on the device**, so the screensaver
meant writing the entire collection to a Kindle's flash, with input already inhibited,
every single time the device dozed off. Both of the plugin's files now remember whether
anything was actually saved since the last flush and skip the write when nothing was:
recipes change on a refresh, not on a nap.

Two smaller things in the same corner:

- The recipe list declares `covers_fullscreen`, which `Menu` does not do for its
  subclasses. The file browser is always open underneath Lardo, and without that flag
  `UIManager` painted it first on every full repaint — including the one after the
  screensaver goes away.
- A download that loses the network mid-sync (the usual reason for which is the device
  falling asleep) **stops after three failures in a row** instead of working through what
  is left. Each of those requests blocks for LuaSocket's timeouts — 10 s per read, 30 s
  in total — with all of KOReader waiting on it, so forty recipes were forty chances to
  freeze the device for half a minute. Whatever arrived is kept, and the next refresh
  fetches the rest.

## Tests

The plugin's logic — config parsing, recipe normalisation, the API client, the reading
view, menus, the start-up takeover — has tests that run without a device and without
KOReader, against stubs of its modules:

```sh
tests/run.sh                        # finds luajit / lua5.1 / lua on PATH
LUA=/path/to/luajit tests/run.sh
```

`tests/bench.sh` asserts nothing; it prints how long the things you wait for
actually take — drawing the list, one more letter in the filter, opening a recipe,
and what KOReader has to parse at start-up — on 300 synthetic recipes.

See [DEVELOPMENT.md](DEVELOPMENT.md) for how to get a Lua interpreter, what has been
verified against the KOReader and Mealie sources, and what has not been checked on real
hardware.

## Layout

| File | Responsibility |
| --- | --- |
| `main.lua` | the plugin: menus, settings, start-up screen, network operations |
| `lardoapi.lua` | Mealie HTTP API client (login, list, single recipe) |
| `lardorecipe.lua` | Mealie JSON → small Lua tables and recipe chapters |
| `lardoview.lua` | full screen recipe reader (chapters, progress bar, buttons) |
| `lardolang.lua` | chapter wording in the language Mealie is set to |
| `lardoi18n.lua` | the plugin's own menus and messages, translated |
| `lardobrowser.lua` | full screen recipe list (a `Menu` subclass) |
| `lardoconfig.lua` | reading and writing `lardo.conf` |

## Notes

- **Plain HTTP on a local network is simplest.** HTTPS works too, but an old Kindle has
  a slow processor and a TLS handshake on every request noticeably slows the list down.
- **The clock matters.** JWTs carry an expiry date; if the Kindle's clock is badly off,
  the server will reject the token (the plugin then reports rejected credentials).
- Recipe images are not downloaded — on a 16-grey 600×800 screen they would add little
  and cost a lot of loading time.
- The plugin never writes anything to the Mealie server; it only reads.
