# Development notes

Everything that cannot be read off the code itself: why things are the way they
are, what was verified against the KOReader and Mealie sources, and what has
**not** been verified.

## What this is and where it lives

```
lardo/
├── lardo.koplugin/      <- this is what goes on the device
│   ├── _meta.lua        <- name and description, read by PluginLoader
│   ├── main.lua         <- the plugin: menus, settings, start-up, network
│   ├── lardoapi.lua     <- Mealie HTTP client
│   ├── lardobrowser.lua <- the recipe list (a Menu subclass)
│   ├── lardoconfig.lua  <- reading and writing lardo.conf
│   ├── lardoi18n.lua    <- our own translations of the interface
│   ├── lardolang.lua    <- chapter wording per language
│   ├── lardorecipe.lua  <- Mealie JSON -> flat Lua tables, chapters
│   └── lardoview.lua    <- the full screen reader
├── tests/               <- offline tests (stubs of KOReader's modules)
│   ├── run.sh           <- runs both suites
│   ├── bench.sh         <- timings for the list, a recipe, the start-up parse
│   ├── bench.lua
│   ├── stub/            <- just enough of KOReader to exercise the plugin
│   ├── test_units.lua   <- config, recipe normalisation, API client
│   └── test_plugin.lua  <- the plugin itself, the list and the view
├── README.md            <- user documentation
└── DEVELOPMENT.md       <- this file
```

On a Kindle: `/mnt/us/koreader/plugins/lardo.koplugin/`.

## The container

Nothing in the repository depends on a particular machine, but two things have
to be there to work on it:

- **A Lua 5.1 or LuaJIT interpreter** for the tests. The devcontainer installs
  `luajit` (see `.devcontainer/Dockerfile`); on a container without it, build it
  from source as described under "Running the tests".
- **Network access to github.com** if you want the reference sources below. The
  devcontainer's firewall (`.devcontainer/init-firewall.sh`) allows GitHub, which
  is enough: both `git clone` and the raw file URLs work, lua.org does not.

Reference material (**not part of the project**, safe to delete) lives outside
the repository in `../.refs/`. To recreate it:

```sh
mkdir -p ../.refs && cd ../.refs
git clone --depth 1 https://github.com/koreader/koreader.git
git clone --depth 1 https://github.com/mealie-recipes/mealie.git
```

Reading those two trees is how most of the findings below were established;
keep them around if you intend to change anything non-trivial. For a single
file, fetching it straight from GitHub is quicker than a clone:

```sh
curl -sL -o /tmp/menu.lua \
  https://raw.githubusercontent.com/koreader/koreader/master/frontend/ui/widget/menu.lua
```

## Status

Confirmed working on a Kindle Keyboard: the recipe list, opening a recipe, the
settings, and configuration from file. Everything else is covered by tests but
has not been exercised on hardware — **including the whole touch model**, which
was written against KOReader's sources and the stubs, never against a finger.

Where it stands, in one paragraph: the plugin lists recipes from a Mealie server
and reads them full screen. **One** network operation (*Refresh*) fetches the
index and every recipe that is new or changed, in one Wi-Fi session, and hands
the radio back to KOReader afterwards. The list has a single line of chrome that
doubles as the filter box (type on a keyboard device, *Menu → Filter* anywhere),
can be sorted four ways, and marks Mealie's favourites with a star. The reading
font is one setting for the recipes and the list. The interface is translated
into Polish by the plugin itself. Back never leaves the list; *Close Lardo*
does. Nothing is ever written to the server.

## Running the tests

The tests need neither KOReader nor a device — `tests/stub/` impersonates its
modules. Any Lua 5.1 / LuaJIT interpreter will do:

```sh
tests/run.sh                      # finds luajit / lua5.1 / lua on PATH
LUA=/path/to/luajit tests/run.sh
```

The devcontainer ships `luajit`, so `tests/run.sh` works out of the box. If the
machine has no Lua and no access to lua.org (only GitHub), build LuaJIT:

```sh
cd /tmp && git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git
cd LuaJIT && make -j4          # result: /tmp/LuaJIT/src/luajit
```

Currently: **586 checks, 0 failures** (288 + 298).

`tests/bench.sh` is not part of the suite and asserts nothing; it prints how
long the things somebody waits for actually take, on 300 synthetic recipes
(`BENCH_RECIPES=1000 tests/bench.sh` for more). The numbers are only useful
relative to each other — a Kindle Keyboard is roughly two orders of magnitude
slower, and its `util.stringLower()` is a real UTF-8 pass rather than the stub's
`string.lower()`, so the filtering difference is larger there, not smaller.

Two extra checks worth repeating after any change:

```sh
# 1. every file parses
for f in lardo.koplugin/*.lua; do
  LUA_PATH="/tmp/LuaJIT/src/?.lua;;" /tmp/LuaJIT/src/luajit \
    -e "local f,e=loadfile('$f') print('$f', f and 'ok' or e)"
done

# 2. accidental globals (a typo in a local name)
for f in lardo.koplugin/*.lua; do
  LUA_PATH="/tmp/LuaJIT/src/?.lua;;" /tmp/LuaJIT/src/luajit -bl "$f" 2>&1 |
    grep -oE 'G(GET|SET) .*"[^"]+"' | grep -oE '"[^"]+"'
done | sort -u
```

The expected output of #2 is exactly: `G_reader_settings dofile io math os pairs
pcall require select setmetatable string table tonumber tostring type`.
Anything else is a typo. (`dofile` is how a stored recipe is read back, the same
way `LuaSettings` reads its own files.)

## Getting it listed

KOReader has no plugin store of its own, but there are three places users look:

1. **GitHub topics** — the community *AppStore* plugin searches GitHub for the
   `koreader-plugin` topic, validates the repository's `_meta.lua` and installs
   it straight onto the device. So: make the repository public and add that
   topic. Our layout already fits — `lardo.koplugin/` at the root, with
   `_meta.lua` in it, and a README.
2. **koreader/contrib** — a collection of non-official plugins, added as git
   submodules by pull request. It expects something that works, not a
   work in progress.
3. **awesome-koreader** — curated community lists; a pull request adding one
   line.

A GitHub release is not required (the AppStore downloads a zipball of the
default branch), but tagging versions makes it obvious what users are getting.

## What the plugin stores

Two `LuaSettings` files and a directory of recipes in `koreader/settings/`, plus
the text file the user edits. Nothing else is written anywhere.

| `lardo.lua` | what it is |
| --- | --- |
| `url`, `token` | the server; both also live in `lardo.conf` |
| `conf_signature` | checksum of `lardo.conf` at the last import, so the file only wins when it changed outside the plugin |
| `language` | Mealie tag, e.g. `pl-PL`; nil = follow KOReader |
| `font_size`, `font_face` | the reading font, used by the recipes and the list |
| `progress_position` | `top` / `bottom` / `side` / `off` |
| `show_buttons` | nil = follow the device (shown on touch), else explicit |
| `sort_by` | `name` / `added` / `updated` / `favorites` |
| `auto_refresh` | refresh once at KOReader start-up |

| `lardo_cache.lua` | what it is |
| --- | --- |
| `list` | the recipe index, normalised (`lardorecipe.normalizeSummary`) |
| `list_time` | when it was last downloaded |
| `stamps` | slug → the `updatedAt` of the copy on the device |

`lardo_recipes/<slug>.lua` is one recipe each, written as `return {…}` so that
`dofile()` reads it back — the same shape `LuaSettings` writes, without its
backup file and its fsync (a cache that fails to be read is downloaded again).

The recipes used to be a `recipes` key in `lardo_cache.lua`, which meant every
recipe ever downloaded was parsed at start-up and held in RAM for the whole run,
in order to draw a list of names. A cache of 300 recipes is ~1.7 MB of Lua
against ~190 kB for the index and the stamps; on a Kindle Keyboard, with 256 MB
for everything, that was the plugin's largest cost by a wide margin. What the
list needs is the index; what "is my copy current?" needs is a stamp; the recipe
itself is read when it is opened and dropped when the view closes. A cache in
the old shape is moved into the new one once, on the first start after the
update (`Lardo:migrateRecipeCache`). The trade is FAT slack — a few kB per file
— which is worth it and worth remembering.

`start_with = "lardo"` in KOReader's own `G_reader_settings` is what makes the
plugin the start-up screen.

## Working practices that paid off

- **A negative control after every fix.** Break the line you just fixed and
  confirm the test actually fails. This caught several tests that were asserting
  nothing.
- **Assert on every scripted edit.** A `str.replace` once silently did nothing
  (the comment above the function had changed) and `rebuild()` stayed on the old
  version — only a test caught it. Editing scripts carry `assert old in s`.
- **Beware stale `/tmp/*.bak` copies.** Restoring from an out-of-date backup once
  reverted an earlier fix. After any `cp` from a backup, `grep` for the fix.

## KOReader findings (verified in its sources)

The things that cost the most time and are not apparent from the documentation:

- **The Kindle Keyboard is supported by current master.** There is no separate
  "legacy branch": the `kindle-legacy` package is the same code built with an
  older toolchain (`frontend/device/kindle/device.lua` — `Kindle3`,
  `event_map_keyboard.lua`). So target the current API.
- **`DataStorage:getDataDir()` returns a bare `"."` on Kindle** — `koreader.sh`
  only `cd`s into the install directory and never sets `KO_HOME`. For any path
  shown to the user, always use `getFullDataDir()`. The same applies to
  `plugin.path` from PluginLoader (`./plugins//lardo.koplugin`).
- **An error in `addToMainMenu` is swallowed** — `filemanagermenu.lua` calls it
  inside `pcall` and only logs. The symptom is menu entries vanishing without a
  trace.
- **An error while loading `main.lua` drops the whole plugin** — PluginLoader
  does `pcall(dofile, ...)` and on failure only calls `logger.warn`. That is why
  every optional widget (`fontlist`, `fontchooser`, `spinwidget`)
  is required **on demand**, through `optionalWidget()`.
- **`Menu` wraps focus inside the current page** (`FocusManager:_wrapAroundY`),
  so 5-way down never reaches the next page. Overridden in `RecipeBrowser`.
- **`FocusManager:releaseFocusKeys()` is a recent addition.** There is a fallback
  (`LardoView:dropFocusKeys`) that clears `key_events` directly.
- **`Font:getFace()` accepts a font file path**, not just a `fontmap` name —
  that is what makes picking any KOReader font possible.
- **`MenuItem.font` accepts a path too**, and `MenuItem:init()` is idempotent
  (capping `font_size` and setting `single_line` do not compound on a second
  call). The font preview rests on this: set `font` to a path and call `init()`
  again. `Menu` has no per-item face field, and `MenuItem` is a local in
  `menu.lua`, so it cannot be subclassed.
- **`NetworkMgr:runWhenOnline()` only connects.** It calls `beforeWifiAction()`,
  which sets a flag; the "Action when done" setting (`wifi_disable_action`) is
  read by `afterWifiAction()`, and *nothing calls it for you* — KOReader's own
  comment says it is "used very sparingly (newsdownloader/send2ebook)". That is
  why Wi-Fi stayed on after a download however the setting was set. Every network
  operation now goes through `Lardo:runOnline()`, which calls it afterwards, in
  the coroutine's "finally" so a failed download hangs up too.
- **`Menu` re-reads `items_font_size` and `items_per_page` on every
  `updateItems()`** (`Menu:_recalculateDimen`), so the recipe list can change font
  while it is open. But **`MenuItem:init()` caps the font to the row height**
  (`TextBoxWidget:getFontSizeToFitHeight`), and the row height is the page divided
  by `perpage` — a larger font alone does nothing. `RecipeBrowser` therefore
  derives `items_per_page` from the font size, inverting KOReader's own
  `Menu.getItemFontSize(perpage)`.
- **`Menu`'s FileManager title-bar style always reserves a subtitle line**:
  `Menu:init` sets `self.subtitle = ""` when `title_bar_fm_style` is true and no
  subtitle was given, and `TitleBar` then builds a widget for the empty string.
  Leaving `title_bar_fm_style` **unset** gives the line back.
- **Never set `title_bar_fm_style = false`** — it crashed KOReader at start-up.
  `Menu` forwards it as `self.title_bar_fm_style and <number>` into
  `left_icon_size_ratio`, `button_padding` and `title_top_padding`; in Lua
  `false and 1` is *false*, not nil, so `TitleBar` multiplied a boolean
  (`DGENERIC_ICON_SIZE * self.left_icon_size_ratio`) and died — and the recipe
  list is built at start-up when Lardo is the start-up screen, outside any
  pcall. The same trap waits in any KOReader field documented as "set to true
  to...". The stub `Menu` now asserts on it (`tests/stub/ui/widget/menu.lua`).
- **`Menu` binds every letter key** to `SelectByShortCut` when
  `is_enable_shortcut` (true on a keyboard device), which opens the row with
  that shortcut. The recipe list turns it off and binds the letters itself, so
  typing filters instead of opening a random recipe.
- **The main menu is built once and cached** (`FileManagerMenu.tab_item_table`),
  so a label built with `text = _("…")` freezes in the language of the first
  build. Our menu entries use `text_func`, and a language change also drops that
  cache (`Lardo:dropMenuCache`).
- **KOReader's gettext only knows KOReader's own strings.** A plugin's menus are
  not in its `.po` files, so they stay English whatever is picked. Hence
  `lardoi18n.lua`: our own table, with KOReader's gettext as the fallback.
- **`FlushSettings` is broadcast before every suspend** —
  `Device:_beforeSuspend()` → `UIManager:flushSettings()` → *all* widgets — and
  **`LuaSettings:flush()` rewrites the whole file every time it is called**: it
  renames the old one to `.old`, serialises the entire table and writes it with
  an fsync. A plugin that flushes a large file from `onFlushSettings` therefore
  writes it out on every screensaver. Both of ours now track whether anything
  was actually saved since the last flush (`flushOnlyWhenChanged`) and skip the
  write when nothing was.
- **`Menu` does not set `covers_fullscreen`** — every full screen user of it
  sets the flag itself (`booklist.lua`, `filemanagercollection.lua`,
  `bookmapwidget.lua`…). Without it `UIManager:_repaint()` paints everything
  below the widget too, and below Lardo there is always the file manager.
- **`Trapper:info(text, fast_refresh, skip_dismiss_check)` costs about 100 ms**
  even before the repaint: it shows an `InfoMessage` and waits that long to see
  whether it was dismissed. One call per downloaded recipe was more time than
  the downloads.
- **`util.stringLower()` is not `string.lower()`** — it is
  `Utf8Proc.lowercase(util.fixUtf8(str, "?"))`, i.e. a validation pass over the
  string plus a case fold. Calling it from a sort comparator (twice per
  comparison, O(n log n) of them) and again for every filter keystroke was the
  recipe list's own cost; both are precomputed now (`Lardo:sortedList`).
- **`start_with` is hardcoded in `reader.lua`**, but it does not need patching:
  reader.lua always creates the file manager first and lets the chosen module
  open on top of it. We append to `menu_items.start_with` (our `addToMainMenu`
  runs **after** the core has built that entry).

## Mealie findings (verified in its sources)

- **There is no "language" field in the API.** Mealie translates every response
  from the request's `Accept-Language` header
  (`mealie/middleware/locale_context.py`). Hence a single setting on our side:
  it goes to the server **and** picks the chapter wording.
- **`updatedAt` is present in the recipe summary** (`RecipeSummary`, serialization
  alias `updatedAt`) — the incremental sync rests on this: one request for the
  index is enough to compute the difference locally.
- The JSON is **camelCase** (`humps.camelize` on `MealieModel`), but
  `PaginationBase` is a plain `BaseModel`, so there it is `total_pages`. We read
  both spellings.
- An ingredient's `display` is computed server-side; we have a fallback that
  assembles `quantity + unit + food + note` (note: `useAbbreviation`, not
  snake_case).
- Login: `POST /api/auth/token`, form-encoded `username`/`password`.

## Design decisions and why

- **A custom recipe view instead of `TextViewer`.** On 600×800 the frame,
  margins, large title bar and button row ate roughly a quarter of the page.
  `LardoView` paints edge to edge. There used to be a **fallback** to
  `TextViewer` when the view could not be built; it is gone — see below. A
  failure now shows the error and nothing else.
- **No fallback viewer, on purpose.** `TextViewer`'s Close button is not
  reachable with the 5-way on a keyboard device, so a recipe opened in it could
  not be left; the user was stuck, which is worse than the failure it covered.
  `displayRecipe` therefore has one path.
- **Both input models, not one.** Keys are the primary model (that is the device
  it was built on), but every one of them has a touch equivalent: taps for the
  page, swipes for the chapters, the header for the menu and the way back, a
  long press as a second menu, and the button row shown by default where there
  is a touch screen. A recipe you cannot leave is the failure mode to avoid.
- **Chapters instead of one block.** Description / ingredients / instructions /
  notes. Page keys scroll and roll over into the next chapter (like a book);
  switching *recipes* is Shift + page key only — scrolling must never dump you
  into a different recipe while you are cooking.
- **A segmented progress bar**, each segment aligned under its chapter's name.
  Segments are computed arithmetically from the real text widths, so it still
  works after the names are shrunk or truncated.
- **Font preview in the list** — a row is drawn in the font it offers. A font
  that cannot be loaded keeps the interface font rather than breaking the row
  (`Font:getFace` returns `nil` in that case).
- **Selection shown by inverting the row**, not by an underline — the patch is
  applied to the `MenuItem` instances in our menu, not to KOReader's class. The
  flag is set from `self.selected` after `updateItems`, because `Menu` focuses an
  item *while* building the page, before the patch can be installed.
- **One shared settings object** for the file-manager and reader instances —
  otherwise whichever flushes last wipes the other's changes (this is how a
  chosen font kept getting lost).
- **`lardo.conf` is bidirectional.** The file wins only when its contents
  changed outside the plugin (checksum in `conf_signature`); UI changes are
  written back into it, keeping comments and unknown keys.
- **Prefixed module names** (`lardoapi`, not `api`) — a plugin's `package.path`
  is shared, so `require("api")` would collide with other plugins.
- **JSON fields are normalised into our own flat tables** before being cached:
  that solves serialization (`LuaSettings` cannot store the userdata a JSON
  `null` decodes to), size and versioning in one go.

## History of reported issues (so they do not get undone)

In the order they came in — each has a test:

1. Token impossible to type on the keyboard → the `lardo.conf` file.
2. Only one config location appeared to be checked → in fact the others were
   relative paths (`./lardo.conf`), so the user could never find them →
   `getFullDataDir()` + 4 locations + the list shown in the dialog.
3. `koreader/settings/lardo.conf` should be the default → order changed.
4. Changing the server from the UI did not update the file → write-back.
5. "Does refresh store recipes?" → no; the sync was naive (it skipped anything
   cached) → incremental sync on `updatedAt` + deletion of removed recipes.
6. Ingredients as a separate window / key → chapters + `S`.
7. The frame and title bar waste space → the custom view.
8. Font size and typeface from KOReader's own resources.
9. Description/ingredients/instructions as separate chapters; language from Mealie.
10. Nothing opened when a recipe was tapped → the cause could not be determined
    remotely; added: `pcall` + showing the error, fallback to `TextViewer`, lazy
    `require` of optional widgets, `releaseFocusKeys` fallback. It worked after
    that.
11. No "Reload configuration file" → the config now reloads itself when the
    list is opened and when it is refreshed.
12. All chapters visible with a highlight; progress bar at the top and per chapter.
13. The side bar must touch the screen edge → a width arithmetic bug.
14. In the font picker, left/right did not reach "Close"/"Set font" →
    `FontChooser` replaced by a plain `Menu`.
15. Font size between `A −` and `A +`; the "Chapters" button is unnecessary.
16. 5-way down did not move to the next page of the list.
17. Make the selection highlight clearer → row inversion.
18. The font picker needs a preview (`FontChooser` had one) → every row of the
    font list is drawn in its own font, via `MenuItem.font` + a second `init()`.
19. The font chosen for a recipe should be the list's font too → one setting,
    pushed into the open list as well (`RecipeBrowser:setItemFont`, with
    `items_per_page` derived from the size so the size can actually grow).
20. Sections in the main menu: everything about reaching the server under
    *Connection*, everything about how things are drawn under *View*; and one
    definition of the view settings for both menus (`Lardo:getViewSettings`),
    each entry showing its value in the label rather than behind a dialog.
21. "Action when done" never turned Wi-Fi off → `afterWifiAction()`, see above.
22. Downloading by itself: *Download the recipe list at start-up* and *Keep every
    recipe on the device* (the second runs in the same Wi-Fi session as the
    refresh, so the radio is brought up and hung up once).
23. "Follow KOReader" named *our* language, not KOReader's → `getKOReaderLanguage`.
    The choice is now English and Polish only — the two the interface is
    translated into.
24. The menus were not translated after changing the language → `lardoi18n.lua`.
25. **"There is no way out of the simple viewer"** → the `TextViewer` fallback
    and its setting are removed entirely (see the design note above). This
    undoes part of 10: the `pcall` and the error message stay, the fallback goes.
26. **"Refresh list does the same as sync all; both unnecessary"** → one
    *Refresh*: the index, then every recipe the index says is new or changed,
    in one WiFi session, with one message at the end. The `auto_sync` setting
    went with it (it was the same thing, spelled as an option).
27. **A filter box instead of "Search recipes"** → typing on the list filters it
    live. `Menu` binds every letter to "open the row with that shortcut", so
    `is_enable_shortcut` is off for the recipe list and the letters are bound to
    our own handler (`RecipeBrowser:registerKeyEvents`). Back clears the filter
    before it closes the list. The input dialog stays for keyboardless devices.
28. **The plugin-name title and the "Menu: actions" hint waste a line** →
    the title *is* the state: "12 recipes in Mealie", or "Filter: pan_ 2/12".
    `title_bar_fm_style` had to go with them: it reserves a subtitle line even
    when the subtitle is empty (`Menu:init` sets `self.subtitle = ""`).
29. **KOReader would not start with the plugin installed** → 28 had switched
    that flag off with `false` instead of leaving it unset; `TitleBar` then did
    arithmetic on a boolean (see the finding above). Fixed, and the stub `Menu`
    asserts on it so the same shape cannot come back.
30. *Menu → Filter* opened an input dialog that did not filter as you type →
    it now just opens the same title-bar box the keyboard uses (`filtering`
    is its own state, so the box shows before the first letter). The input
    dialog is left for devices with no keyboard, where it is the only way in.
31. **Sorting**: by name, newest (`dateAdded`), recently changed (`updatedAt`),
    or favourites first. Favourites are per user in Mealie
    (`mealie/routes/users/ratings.py`): `/api/users/self` for the id, then
    `/api/users/{id}/favorites` → `{ratings = {{recipeId = …}}}`. Both calls are
    wrapped so an older server means "no stars", never a failed refresh, and the
    recipe summary now keeps Mealie's `id` (that is what favourites name).
32. **Back must not leave the recipe list** → on the recipe list it clears the filter and
    otherwise does nothing (`keep_open_on_back`); the way out is *Close Lardo*
    in the list's own menu. The typeface picker still closes with Back — it is a
    picker, not the place you live in.
33. **Not only for keyboard devices** → the reading view had no gestures at all,
    so on a touch-only device an opened recipe was a room with no doors. It now
    has taps (page, header), swipes (page and chapters) and a long press for the
    menu; the button row is shown by default there; the ✕ in the list's title bar
    really closes (it is rewired past `onClose`, which Back uses).
34. **The sync felt slow, naming every recipe** → it was: one `Trapper:info()`
    per recipe, each a repaint plus a 100 ms dismiss check. Now one message with
    a counter that moves at most once a second, and the summary at the end. The
    same entry no longer appears in the Tools menu as *Filter recipes* — that
    one only opened the list in order to cover it with a box.
35. **"Test connection" did not bring Wi-Fi up like a sync** →
    `NetworkMgr:runWhenOnline()` drops the callback when the link is up but its
    own DNS check is not (`manager.lua`); it now goes through
    `runWhenConnected()`, which guarantees the answer. It also re-reads
    `lardo.conf` first, exactly as a refresh does.
36. **The Kindle became unresponsive when the screensaver came on** →
    `onFlushSettings` was rewriting the entire recipe cache into the settings
    file on the way into every suspend, with input already inhibited. Three
    things came out of it: flush only when something changed, `covers_fullscreen`
    on the recipe list, and a sync that gives up after three failures in a row
    instead of blocking for 10–30 s per remaining recipe on a network that went
    away with the device falling asleep. Then the recipes moved out of the
    settings file altogether — one file each, read when opened.

## What has NOT been verified

- **How it looks on e-ink.** Header heights, bar thickness and proportions were
  computed against stubs; on 600×800 they may need adjusting.
- **HTTPS and TLS on a Kindle 3.** The code goes through `socket.http` exactly
  like OPDS and wallabag do, but there was no opportunity to test it on hardware.
  On a LAN, plain HTTP is simpler.
- **Chapter translations** beyond Polish and English (cs, de, es, fr, it, nl, pt,
  sv are present) — written without a native speaker.
- **The Wi-Fi hand-back on hardware.** `afterWifiAction()` is called (the tests
  assert that, against a stub); what the Kindle's radio then does, and whether
  "prompt" comes at an awkward moment, has not been seen on a device.
- **The list's rows-per-page at large font sizes** — the arithmetic is KOReader's
  own, inverted, but it has only been checked against stubs.
- **Behaviour with hundreds of recipes** — the first refresh downloads every
  recipe body and blocks the UI while it does (interruptible with any key);
  later ones cost one request unless something changed. `tests/bench.sh` says
  what the list and the store cost on a development machine, which is not a
  Kindle; nobody has watched 300 recipe files land on one.
- **The whole touch model.** Taps, swipes, the long press, the header zones and
  the title bar's ✕ were written against KOReader's sources and are covered by
  tests against stubs — no finger has touched them. The tap zones in particular
  (header vs body, the right hand third of the header for the menu) are guesses
  about what feels right.
- **Favourites on a real server.** `/api/users/self` + `/api/users/{id}/favorites`
  match Mealie's sources; the shape of the answer has only been replayed from a
  stub. A server that answers differently means no stars, not a failure.

## Possible next steps

- Check the header proportions and the 4 px bar thickness on the device, and the
  touch zones with a finger.
- Recipe images are deliberately skipped; if ever added, as thumbnails only.
- Publishing: the licence is MIT (`LICENSE`); what remains is making the
  repository public, adding the `koreader-plugin` topic, and — once it has been
  used for a while — the pull requests to koreader/contrib and awesome-koreader.
- Setting a favourite *from* the plugin would be one POST
  (`/api/users/{id}/favorites/{slug}`), but it would make this the first thing
  that writes to the server; the plugin is read-only on purpose.
