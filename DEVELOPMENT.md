# Development notes

Everything that cannot be read off the code itself: why things are the way they
are, what was verified against the KOReader and Mealie sources, and what has
**not** been verified.

## What this is and where it lives

```
lardo/
├── .github/workflows/
│   └── release.yml      <- "Run workflow" -> tests, version, tag, zip
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

Used on two devices: a **Kindle Keyboard** (KOReader v2026.07.1, no touch
screen) and a **Kindle Oasis 2** (v2026.07.2, touch, alongside five other
plugins). Both models of interaction have been exercised by hand — the keyboard
one from the start, the touch one through the reports that fill the later half
of the history below. What has *not* been exercised on hardware is everything in
"What has NOT been verified" at the end of this file.

Where it stands, in one paragraph: the plugin lists recipes from a Mealie server
and reads them full screen. **One** network operation (*Refresh*) fetches the
index and every recipe that is new or changed, in one Wi-Fi session, and hands
the radio back to KOReader afterwards. The list has a single line of chrome that
is the filter box and the way to the menu, can be sorted four ways, and marks
Mealie's favourites with a star. The reading font is one setting for the recipes
and the list. The interface is translated into Polish by the plugin itself. Back
never leaves the list; *Close Lardo* does. Nothing is ever written to the
server.

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

Currently: **786 checks, 0 failures** (296 + 490).

`tests/bench.sh` is not part of the suite and asserts nothing; it prints how
long the things somebody waits for actually take, on 300 synthetic recipes
(`BENCH_RECIPES=1000 tests/bench.sh` for more). The numbers are only useful
relative to each other — a Kindle Keyboard is roughly two orders of magnitude
slower, and its `util.stringLower()` is the whole of utf8proc rather than the
stub's `string.lower()` plus a handful of accented letters, so the filtering
difference is larger there, not smaller.

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

### Tagging one

*Actions → Release → Run workflow* (`.github/workflows/release.yml`). It runs the
tests, writes the version into `_meta.lua`, commits, tags it and publishes
`lardo.koplugin.zip` as the release asset. **Dry run** does all of that except
the two pushes — worth using the first time.

**The version field is optional.** Left empty it is the newest `vX.Y.Z` tag with
one added to the patch number (`v1.2.3` → `v1.2.4`), which is what a release
usually is; with no version tag at all it starts at `v0.1.0`. Type a version only
when it is not a patch — a new minor, or a first release you want numbered
differently. Tags that are not versions are ignored, and the sort is git's
`-v:refname`, so `v1.10.0` counts as newer than `v1.9.0` rather than older.

Why each of those steps is there, from the AppStore's sources
(`omer-faruq/appstore.koplugin`):

- It finds repositories with two GitHub searches per kind — `topic:koreader-plugin`
  and `in:name ".koplugin"` — each run for non-forks and for forks separately.
  Ours matches both (the repository is *named* `lardo.koplugin`), but the topic
  is the part that does not depend on the name.
- **What the store lists is the repository's own metadata** — name, GitHub
  description, stars, topics, last push. `_meta.lua` is not read until install.
- Installing offers the release's assets by name, or a zipball. An asset called
  `<something>.koplugin.zip` is recognised as a plugin directory
  (`([%w_%-%.]+%.koplugin)%.zip$`), which is why the workflow names it that and
  zips the directory rather than its contents: the archive has to contain
  `lardo.koplugin/_meta.lua`.
- The version is read out of `_meta.lua` **by a text match**
  (`version%s*=%s*["']([^"']+)["']`), not by running the file, so it has to be a
  plain string literal — and it has to be in the commit the tag points at, which
  is why the workflow commits before tagging. Updates themselves work off commit
  SHAs; the version is what the user sees, and what the changelog compares.

The workflow pushes a commit and a tag with `GITHUB_TOKEN` (`permissions:
contents: write`), so a branch protection rule that requires pull requests on
the default branch will stop it.

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
| `buttons_position`, `list_buttons_position` | `bottom` / `top` / `off`, one per screen; nil = follow the device |
| `view_buttons`, `list_buttons` | per button, `false` when it has been turned off |
| `show_buttons` | what `buttons_position` grew out of; still read when the new key is unset |
| `sort_by` | `name` / `added` / `updated` / `favorites` |
| `auto_refresh` | refresh once at KOReader start-up |
| `keep_awake` | minutes between screensaver nudges while a recipe is open; 0 = off |
| `status_items` | what the recipe's header corner shows (battery / clock / wifi) |

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
  page, swipes for the chapters, the header for the menu, a long press as a
  second one, and *Back to the list* inside it. A recipe you cannot leave is the
  failure mode to avoid.
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
    definition of the view settings for both menus, each entry showing its
    value in the label rather than behind a dialog. (That definition is
    `getMenuItems` today -- see 41.)
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
37. **On a touch screen, tapping the recipe's title closed it** and tapping next
    to the title opened the menu — one strip, two halves that look the same, and
    the busier half throws away what you are cooking from. The header does
    nothing now; the menu and the way back are buttons. The recipe list lost its
    title bar icons for the same reason (and because its ✕ did not work at all),
    and gained a row of its own: filter, menu, page arrows, close.
38. **Both rows can be moved and taken apart** — *View → Buttons in a recipe* and
    *Buttons on the recipe list*: bottom, top or hidden, and one tick per button.
    The order is fixed. (Both rows were taken out again in #72.)

## Menus

**There is one menu, and it is KOReader's.** `Lardo:getMenuItems()` returns it,
`menuItemsToTouchMenu` converts it into the tables KOReader's menu is built from, and
`Lardo:showKOReaderMenu()` — the *Menu* button on either screen and the Menu key — opens
it with `FileManagerMenu:onShowMenu()` (public; we prefer `self.ui.menu` and fall back to
`FileManager.instance.menu`, because a recipe opened from the reader has a ReaderMenu that
knows nothing about a list of recipes).

There was a dialog of our own before, built from the same definition — a second menu to
keep in step with the one every KOReader user already knows. What it had that KOReader's
menu could not: the actions used while cooking. Those are the top of this menu now, one
press from the tap that opens it.

Two things about the entries:

- **Never force KOReader to build its menu again.** `FileManagerMenu:setUpdateItemTable()`
  merges into `self.menu_items` instead of replacing it, and `MenuSorter:sort` has already
  *consumed* that table — it moves each item into its parent and removes it from the flat
  one ("remove reference from item_table so it won't show up as orphaned"). Sorting the
  leftovers is nonsense and takes KOReader down, which is what pressing Menu on the recipe
  list did for exactly as long as `showKOReaderMenu` called `dropMenuCache` first. Nothing
  needs rebuilding: TouchMenu re-reads `text_func`, `enabled_func` and `checked_func` every
  time it draws. Where a rebuild really is needed (a language change), `dropMenuCache`
  clears **both** halves.
- **Entries are disabled, not omitted** (`enabled_func`, re-read on every draw): a menu
  whose entries move around is harder to learn than one whose entries grey out. It is also
  why nothing has to be rebuilt.

An entry is KOReader's menu item (`text`, `text_func`, `callback`, `enabled_func`,
`checked_func`, `help_text`) plus two of ours: `sub_items`, a function returning the level
below, and `title` for what that level is called. The levels are the tables that already
existed — `getScreenMenuTable`, `getApplicationMenuTable`, `getFontMenuTable`,
`getConnectionMenuTable`, `getOfflineMenuTable`, `getLanguageMenuTable`,
`getSortMenuTable`, `getProgressMenuTable`, `getButtonsMenuTable`, `getShortcutMenuTable`.

`Lardo:showMenuDialog` is still there, but not as a menu: it is the small choice dialog
the *Sort* button opens, and the fallback for a KOReader without `SortWidget`. A callback
is handed a `refresh` handle that answers both to `on_change()` and to
`touchmenu_instance:updateItems()` (`refreshHandle`), which is what lets one definition
serve KOReader's menu and that dialog without either side knowing.

## Arranging things

`SortWidget` (`ui/widget/sortwidget.lua`) is the widget for "an ordered list you can move
items in" — KOReader's status bar uses it for the same job. `Lardo:showArrangeDialog(spec)`
is the one wrapper. The corner of a recipe's header is what is left to arrange (the two
button rows went in #72); it hands in its definition and a `save(order)`.

**It carries no checkboxes, on purpose.** `SortItemWidget:onTap` toggles only when the tap
lands inside `checkmark_widget.dimen` — a fingernail-sized square at the left edge; a tap
anywhere else picks the line up to move it. The first thing anybody says about that is
"the clock will not switch on". So what is switched on is ticked in the menu, where the
tick is the whole line, and the window does one job. `item.callback` is called when the checkmark is tapped, `callback` on the widget is
called with `item_table` already reordered in place, so the whole of our side is building
the items and writing back the order and the ticks (`Lardo:saveButtonRow`). It is loaded
through `optionalWidget()`, with a dialog of ticks as the fallback.

The corner was a level of ticks before that, which closed and reopened the dialog on
every one of them — three changes in a row is three full redraws on e-ink.

**Two interactions, both KOReader's own.** A choice or a switch is a `checked_func` on
the button — the checkmark KOReader appends after the label, in its menus and in ours —
and it is redrawn *in place* (`getButtonById` → `setText(getDisplayText())`) so that
picking from a list does not close and reopen a dialog for a mark after a word. Where the
order is the reader's as well, it is the arranging window. `showTickDialog`, the fallback
for a KOReader without `SortWidget`, is the first of those two rather than a third thing.

**Do not hand the arranging window an `on_change` that reopens a dialog.** `SortWidget`
calls its `callback` from `onReturn`, and when an item is picked up for moving that does
*not* close the window — so the menu reopens on top of a window that is still there, which
is what "tapping the tick opens a menu" was. The refresh handle carries `in_place`: true
for KOReader's menu (still on screen behind us, wants its labels redrawn), false for a
dialog we replaced (leave it closed).

The order and the on/off are **one** setting in the widgets' eyes:
`Lardo:getButtonRow(which)` hands `LardoView` and `RecipeBrowser` an array of button ids,
in the order they are drawn, with the switched-off ones already gone. Both walk that array
and emit the widget spec for each id. A button added by a later version is appended to a
saved order rather than dropped, so it appears for everybody.

42. **The Kindle blanks the screen after ten minutes and has no setting for it**
    → *Keep the recipe on screen*, which nudges powerd's t1 timer while a recipe
    is open, and redraws the header's corner while it is at it. The corner shows
    the battery and whether the screen is being kept on, both by default, and
    can show the clock and Wi-Fi. That marker follows what is actually
    happening, not the setting: it is absent while charging, when nothing is
    nudged. See below.
43. **"Can a book in the library open Lardo?"** → it can: an auxiliary provider
    plus a file with the association recorded beside it. *Shortcut in the
    library* writes one. See below.
44. **The corner's settings opened a new screen per tick** → it is the same
    arranging window as the buttons now, and its items can be reordered too.
45. **The WiFi mark in the corner was stale** — it was only recomputed on the
    keep-awake tick, so a refresh that hung the radio up afterwards left it
    showing for up to ten minutes. `onNetworkConnected` / `onNetworkDisconnected`
    (KOReader broadcasts both; its own status bar listens to them) now redraw
    it, and so does the end of our own `runOnline`, which is where the radio
    gets hung up.
46. **The library shortcut crashed KOReader and then did not work** → two
    separate faults: the Tools menu handed entries its TouchMenu instance where
    our dialogs hand something callable (an entry that called it took KOReader
    with it), and the provider was looked up by `self.name`, which KOReader
    renames to `filemanagerlardo` the moment it registers the plugin — so the
    association that makes the file visible and ours to open was never written.
    Both have tests; the first one presses every entry in the Tools menu.
47. Three small ones from using it: the arranging window reopened the menu over
    itself when the tick was pressed with an item picked up (see above), the
    corner's "Screen kept on" is called *Awake* / *Czuwanie*, and the menus
    opened from the list and from a recipe carry no title — the recipe's name
    was already on the screen behind it.
48. **The library shortcut had nowhere to go but the folder on screen** → it has
    a folder of its own now (`PathChooser`), and moving it takes the file and
    its sidecar with it. The settings are also grouped into three categories,
    because a top level of eleven entries is a list, not a menu. The categories
    are their names and nothing else — a value belongs to a setting, and
    *Connection: http://…* only moved to *Server address: http://…* inside it.
49. **Back in a category closed the whole menu** instead of going up one → the
    level below now carries the way back to the one above it.
50. **Rows with nothing written on them in KOReader's menu** → the conversion
    copied `text_func` and not `text`, and an entry whose label never changes
    (the languages) gives the plain one. The test walks the converted menu and
    fails on any row without a label.
51. A tidy-up after all of the above: the two dialogs the menu rebuild left
    behind (`showSortDialog`, `showProgressPositionDialog` -- both a level of
    the menu now), the `Lardo.isStale` wrapper nothing called any more, and
    `buttonRowKeys` returning four values of which every caller threw three
    away. Dead code found by listing every function and grepping for its name;
    everything left over that is never named is an event handler KOReader calls
    by name (`onShow`, `onLardoScrollLine`, `onLeftButtonTap`, ...).
52. **"Can the places that switch things on and reorder them share one UI?"**
    → they now do: ticks are KOReader's `checked_func` (the same mark as its own
    menus and as the arranging window) redrawn in place, instead of a "✓ "
    pasted into the label with the dialog closing and reopening around it.

53. **"There is no point in a menu of our own; open KOReader's, with
    everything in it."** → the *Menu* button and the Menu key do that now.
    Lardo's own dialog is gone; the actions it held (filter, sort, refresh, the
    doors in and out) are entries in KOReader's menu, and the two that are worth
    a press while cooking can be put on the button row.

54. **Pressing Menu on the list crashed KOReader** → `showKOReaderMenu` asked it
    to rebuild its menu on every press, and KOReader's menu cannot be built
    twice from the same tables (see above). It does not ask any more, and the
    open is wrapped in a `pcall` that reports rather than dies.

55. **An optional tab of our own in KOReader's menu**, and Menu opening
    straight into it. Off by default; see "A tab in KOReader's menu".

56. **No way out of the button row on a Kindle Keyboard** → a `ButtonTable`
    binds the 5-way keys itself; both rows now leave them to the screen and join
    its focus grid instead. (The rows were taken out in #72.)

57. **KOReader would not start** (`crash.log`: `attempt to perform arithmetic on
    local 'px'`, in `framebuffer.scaleBySize` under `Font:getFace`). Joining the
    focus grid put the buttons into `self.layout`, and `updateItems` walked that
    grid setting each row's reading typeface — on a `Button`, which has no
    `font_size`. `Font:getFace(file, nil)` looks the name up in `fontmap`, where
    a *font file path* is never a key, and scales the nil it finds. It only bit
    with a typeface chosen **and** a row of buttons on, and at start-up the list
    is the first screen, so the device did not come up. The rows are marked
    `_lardo_button` where they are built, and a face is never asked for without
    a size. The same marking keeps the double inversion off them: a `Button`
    highlights itself, and inverting it again would cancel it out.

    The lesson for the stubs: `Font:getFace` had been returning a face for any
    size at all, including none, so 463 checks passed over a crash. A stub that
    is kinder than the real thing hides exactly the bug it is there to catch.

58. **"The tags should be visible on the list, and the filter should read them
    too."** → Mealie's summary carries `tags` and `Recipe.normalizeSummary` had
    been keeping them all along; nothing showed them. They are the right-hand
    column now, before the time (`Recipe.listColumn`), and part of the filter
    haystack. Two things worth keeping: the column is capped and gives way to
    the name (whole tags only — cutting one in half cuts a Polish letter in
    half), and the **filter reads the tags whether or not the column shows
    them**, because what fits on the row is a question about the screen and what
    you typed is a question about what you meant. A list cached before this
    change has no `tags` field, hence `recipe.tags or {}`.

59. **Still no way up out of the bottom button row** (#56 had only looked
    fixed). `key_events_enabled = false` stops the row binding the keys; it does
    not stop the row *answering the event a key turns into*, and children are
    asked before their parent. The row kept every Up and Down and moved nothing,
    so the cursor was never asked to leave — and, because a `ButtonTable`
    refocuses itself, a button was lit from the moment the list opened, which is
    what "I am stuck in the row" looked like. See "The button row and the
    5-way".

    The reason the tests agreed with the bug: they called
    `list:onFocusMove(...)` directly, which is a path no keypress ever takes.
    They press it the way a key arrives now — children first — and the stub
    `ButtonTable` answers like the real one instead of ignoring focus entirely.

60. **The tab of our own did nothing, and the menu answered "bad argument #1 to
    `ipairs` (table expected, got nil)"** — `menusorter.lua:139`. A tab needs a
    rebuild of KOReader's menu, and `dropMenuCache` was clearing `menu_items` to
    ask for one. On the device's KOReader nothing rebuilds the menu's *skeleton*
    after the sorter has eaten it, so the rebuild had no row of tabs to sort. We
    keep a copy of it now; see "Rebuilding KOReader's menu". #54 saw the same
    wall from the other side and only stopped walking into it.

    The tests said the tab worked because they called `addToMainMenu` with an
    empty table and read the result — the sorter, which is what the entries are
    *for*, never ran. There is a stand-in for KOReader's menu now, written off
    its sources: it builds the skeleton once, consumes what it sorts, and fails
    exactly where the real one failed.

61. **The shortcut was written and the file browser did not show it.** The file
    was there; `hasProvider` had no reason to say yes. `addAuxProvider` says who
    we are, not what we own, and the browser's filter is given a **bare
    filename** — so neither the sidecar association nor the file-type one could
    answer it (the latter is skipped for auxiliary providers by design). The
    extension is registered with `addProvider` now; see "The library shortcut".
    It is also called `Lardo.lardo` rather than the translated `Recipes.lardo`,
    and no sidecar is written any more — the type is enough.

    The stub for `DocumentRegistry` had no `hasProvider` at all, so the tests
    checked that the association was *recorded* and never that the file could be
    *seen*. It answers all three of KOReader's rules now.

62. **"I cannot open the menu by tapping the top of the screen."** The habit is
    KOReader's own — its `filemanager_tap` touch zone — and a widget that covers
    the screen covers the zone with it. Both screens answer that tap now: the
    recipe view's header (which had been made inert in #37; only its *closing*
    half was the dangerous one) and the recipe list's title bar, the strip above
    the recipes. On the list the zone stops at the title bar, because with the
    button row at the top it sits directly below and a button that opens the
    menu because it was missed is not a button.

    Reported together with "and Lardo is not in KOReader's menu once Lardo is
    open — on legacy it is". The log settled it, and it was **not the version**
    (v2026.07.1 against v2026.07.2) but another plugin: `menu_customizer`.

63. **A menu customiser makes our tab impossible, and takes Lardo with it.**
    `MenuSorter:mergeAndSort` reads `settings/<prefix>_menu_order.lua` — what a
    customiser writes — and copies it over the order module **after** every
    plugin's `addToMainMenu` has run. The row we add ourselves is therefore gone
    by the time the row is read. Worse than "no tab": the tab path publishes no
    entry under Tools, so what it did publish is swept up as orphans into the
    **first** tab behind a `NEW: ` prefix. Reachable, and nowhere anyone would
    look — which reads exactly like "Lardo is not in the menu".

    Nothing can tell before the menu is built, so `showKOReaderMenu` looks
    afterwards: tab asked for, menu built, tab not in it → give it up
    (`tab_refused`, once per session), drop the cache and build again, which is
    the build that puts Lardo under Tools. The *setting* is left alone — it is
    what the user asked for, and another KOReader will allow it.

    Also hardened on the way past: `FileManagerMenu` calls
    `pcall(widget.addToMainMenu, widget, menu_items)` and, on a throw, logs
    `failed to register widget` and carries on — so anything failing in ours
    would take Lardo out of the menu **silently**. `addToMainMenu` builds inside
    a `pcall` of its own now and leaves a one-entry door (*Browse recipes*) plus
    a log line naming the error. (The log showed no such line, so that was not
    this bug — but it is the same silence, and next time it will speak.)

64. **"Lardo is in neither Tools nor More tools, and ticking the tab changes
    nothing either."** Same plugin, other half of it:
    `JoeBumm/Koreader-Menu-customizer` ("Hide menus. Hide plugins.") writes the
    ids it hides into `["KOMenu:disabled"]` of that same order file, and
    `MenuSorter` **deletes** those from the flat table *before* orphan handling
    — so the entry never lands anywhere, and nothing is logged. Our entry and
    our tab share the id `lardo`, so one line in that file hides both.

    That is somebody's own configuration and not ours to override, so Lardo
    says so instead: after the build, if it is nowhere in `tab_item_table`, we
    log it and — **only when that file is really there**, else it would be a
    guess — show it once, naming the path. The customiser finds us by grepping
    `plugins/*/main.lua` for `menu_items%.([%w_]+)%s*=` and reading the
    `sorting_hint` out of the matched body, which is why `menu_items.lardo = {`
    needs to stay a plain literal.

65. **"Lardo is not in Tools at all — until I open it once. Storefront is
    always where it should be."** The right observation, and it named the real
    gap: every other plugin calls
    `require("ui/plugin/insert_menu").add("<id>")` **at load time**, which
    appends the id to `more_tools` in *both* order modules. An id that is in the
    **order** is *placed* by `MenuSorter`; an id that is not is left to the
    orphan pass, which only runs on what is left over and which a menu order
    file can pre-empt. Lardo relied on the orphan pass and `sorting_hint` alone.
    It makes the same call now, and lands under *Tools → More tools* like
    everything else — in the order from the moment the plugin is loaded, so a
    menu customiser that reads the orders sees it too.

    The other half of the same report — ticking the tab left Lardo nowhere —
    is now caught *before* the build: `tabWouldSurvive` reads the user's menu
    order file (the one thing available in advance) and, if that file fixes the
    row of tabs without us in it, we do not claim a tab at all. Claiming one and
    losing it used to cost the entry under Tools as well, which is why the entry
    appeared only after Lardo had been opened once and `tab_refused` had noticed
    (the device's log: `this KOReader's menu does not keep our tab`). Our id is
    in exactly one place at a time — `inMoreTools(order, false)` when we take
    the tab — because the sorter fills whichever it finds first and leaves an
    empty row in the other.

66. A tidy-up after all of the above, by the same method as #51 — list every
    definition and grep for its name. Gone: ten translations of strings the menu
    rebuild had left behind (including a whole plural form), and the stub
    methods nothing ever called (`Geom:copy`, `NetworkMgr:isConnected`,
    `UIManager:runTicks`, five `Button` methods, `SortWidget:toggle`). The two
    stubs that each had their own idea of what focusing a button does now share
    one. `showKOReaderMenu` lost a comment that had been true and stopped being
    so — "building it a second time must never happen" — now that a rebuild is
    something we ask for on purpose, and the duplicated build-if-needed became
    `ensureMenuBuilt`.

    What the sweep leaves behind, and why: `getProviders` in the registry stub
    (called by `getProvider`, one line above it) and five settings read but
    never written by name — `font_face`, `font_size` and `progress_position` go
    through `applyViewSetting`, whose key is a variable; `home_dir` is
    KOReader's; `recipes` is the key the one-file-per-recipe migration reads.

67. **The line of chrome, in two halves.** A tap on the recipe count starts the
    filter (that line *is* the filter box while you type, so tapping it does
    what it says), and a tap on the empty strip either side of it opens
    KOReader's menu. `Menu` builds its title bar with `align = "center"`, so the
    split is the width of the title widget, asked for at tap time: the text is a
    count one moment and what you have typed the next, in a font that is a
    setting.

68. **"Filter should take me to the field at the top and open the keyboard, not
    a window where the filtering is not live."** It was an `InputDialog`: a box
    in the middle of the screen that filtered once, on confirmation — the same
    word over a different thing. On a device with no keys the line of chrome is
    now a real `InputText` shown **over** the title bar (`showFilterField`),
    with `edit_callback` filtering on every keystroke and `enter_callback` as
    the way out that every keyboard layout has. Over, not in place of: `Menu`
    measures its own furniture to lay the list out, and swapping a widget into
    that furniture is how several of the uglier bugs here began. Opening a
    recipe or clearing the filter takes the field with it, and a KOReader that
    will not build one falls back to the old dialog.

69. **"Filter still shows the popup."** The field was being built and thrown
    away: `InputText` calls `edit_callback` **from its own constructor**
    ("called with false on init"), and ours reached for `self.filter_input`,
    which `new` had not returned yet. The error went into the `pcall` and we
    fell back to the dialog — the fallback working perfectly is what made it
    look like nothing had changed. The stub did not fire that callback on init;
    it does now, which is what makes the bug fail a test.

70. **"There is no keep-awake marker after switching it on, and I cannot tell
    whether it works."** The corner shows what *Status in the corner* lists, and
    `awake` is only in the default set — anyone who has touched that list has a
    saved one, where it may be off. Switching keep-awake on now brings its
    marker with it (once, from off: turning the marker off again while it runs
    is a decision, and changing the interval afterwards leaves it alone).
    The marker still means what it says: it is absent while charging, where the
    nudging is deliberately skipped (KOReader's own AutoSuspend skips it too).

71. **The ✕ was back on the recipe list, next to the count.** Not "still there"
    — *back*. `TitleBar:setTitle` re-runs the **whole of `TitleBar:init`** when
    the title may change height, which is what `title_shrink_font_to_fit` asks
    for and what this list sets; and `init` turns `close_callback` into the
    right hand icon. So removing the button worked exactly once, and the next
    count in that line put it back — which is every refresh and every letter
    typed into the filter. The fix removes the *cause*: `close_callback`,
    `right_icon` and their callbacks, and then the button. The stub's title bar
    rebuilds itself on `setTitle` now, the way the real one does, so the old fix
    fails three checks.

72. **"The bar at the bottom is not needed any more."** And it was not: the
    filter is the line at the top or the keyboard, the menu is a tap on that
    line or the Menu key, the way out is in the menu, the list pages with
    KOReader's own footer, and the ingredients have a key and a Dispatcher
    action. So both rows are gone, with everything that served them — the
    positions, the per-button ticks, the arranging window for them, the
    `ButtonTable` plumbing, the focus-grid merge, the footer we emptied to make
    room, and the settings all of that wrote (cleared once, on the way in:
    settings nothing reads are the settings-file version of dead code).

    What the rows were hiding, now that they are gone: `Menu`'s own footer is
    back, which pages the list for free, and every row of the focus grid is a
    recipe again.

73. **Three ways out, after the rows went.** With the keyboard up on a touch
    screen there is nothing else to do on that screen, so **a tap anywhere**
    puts the field away (an `InputContainer` the size of the screen under the
    strip; children are asked first, so a tap *on* the field still moves the
    cursor), as does **backspacing when there is nothing left to delete** —
    which is how the filter is left on a keyboard device, the same key a second
    time. The line then drops its trailing `_`: that cursor belongs to typing
    and to nothing else.

    The tap catcher needed a second thing to work at all, found only after it
    did not: **`is_always_active = true`**. While the keyboard is up it is the
    topmost widget, and `UIManager:sendEvent` offers an event the topmost widget
    declined **only** to widgets carrying that flag ("widgets that want to show
    a VirtualKeyboard"). Without it a tap outside the keyboard reached nothing
    at all. KOReader's own `InputDialog` carries the flag for the same reason —
    and, for the same reason, checks that the tap was not inside the keyboard's
    own rectangle before acting on it: a tap can land in the grey between two
    keys, which is a miss on the keyboard rather than a tap outside it.

    And a recipe got its way out back: a **✕ at the end of the header**, only
    where there is a finger to press it. Its zone is the width of the glyph plus
    a padding, and only on that first line — the chapter names under it are not
    a way out. Everything else in the header is still the menu, which is the
    half of the old header that was never the dangerous one.

74. **"Keep the recipe on screen may work on the Kindle Keyboard, but not
    against KOReader's own screensaver."** Both halves were wrong by the same
    number. The poking was on the *user's* interval — ten minutes by default,
    minus thirty seconds — against a timer whose **shortest setting is five**:
    KOReader's own AutoSuspend resets the same t1 timeout every four minutes,
    with the comment "lower than the minimum t1 timeout". On a Kindle Keyboard
    set to ten it just about won; on anything set to five it never did. And
    `resetT1Timeout` cannot help once the screensaver is already up — powerd
    refuses it — so being late is the same as being absent.

    So the two clocks are separate now: the device is told every **four
    minutes**, and the corner of the header is redrawn on the interval that was
    asked for (which is what that setting was always about — "rób jakieś
    odświeżenie co zdefiniowany czas"). An e-ink refresh every four minutes to
    move a clock by four minutes is more flicker than anybody wants.

    `PluginShare.pause_auto_suspend`, which holds off KOReader's *own* suspend,
    was already set and is still right — but on a Kindle it is not what the
    screensaver hangs on, and it cannot cover for a t1 reset that comes too
    late. Worth knowing: AutoSuspend's Kindle branch stops resetting t1 once its
    own suspend timeout has elapsed, `pause_auto_suspend` or not, so after that
    point ours is the only reset happening.

## A tab in KOReader's menu

The row of tabs is `order["KOMenu:menu_buttons"]` in
`ui/elements/filemanager_menu_order` — a module, so `require` hands every caller the same
table and a plugin can add to it. A tab is an entry in `menu_items` carrying an `icon`,
and its contents come from `order[<its id>]`: a list of ids of *other* `menu_items`
entries. So `installMenuTab` publishes our top-level items one id each
(`lardo_1`, `lardo_2`, …), lists them under `order.lardo`, and adds `"lardo"` to the row.
Sub-levels stay nested `sub_item_table`s — only a tab's own contents come from the order.

Five things worth knowing:

- **At the end of the row.** KOReader remembers which tab you had open by *index*
  (`filemanagermenu_tab_index`); inserting anywhere else moves its own tabs under it.
- **Switching it off has to undo it**, because that table lives as long as KOReader does.
- **A menu customiser wins.** `MenuSorter:mergeAndSort` copies
  `settings/<prefix>_menu_order.lua` over the order *after* every plugin has had its
  say, so on a device with one the tab cannot be added at all. That is only visible
  once the menu is built; see history #63 for what we do about it.
- **`MenuSorter` writes a tab's id into the table it builds for it**, which is how
  `menuTabIndex` finds ours to open the menu on it.
- **A tab only exists after a rebuild**, and a rebuild is not free — see below.

### Getting into the menu at all

**`require("ui/plugin/insert_menu").add("lardo")`, once, at load time.** It appends the
id to `more_tools` in `filemanager_menu_order` *and* `reader_menu_order`, and that is the
whole of how a contributed plugin appears under *Tools → More tools*. It matters more
than it looks:

- An id **in the order** is *placed* by `MenuSorter`. An id that is not is left to the
  orphan pass at the end of the sort, which runs on whatever is still in the flat table —
  and a menu order file can empty that first (`KOMenu:disabled`).
- A menu customiser reads the order files. An id that is never in one is invisible to it,
  so it cannot be switched back on either.

Lardo used to rely on the orphan pass and `sorting_hint = "tools"` alone, which is why it
was the one plugin missing from a menu where the others were fine. `sorting_hint` stays:
it is what the orphan pass uses if a customiser's file has replaced `more_tools`, and
what the customiser itself reads to decide where to file us.

**Two answers, because there are two cases.** The one cause that can be known in
advance is a menu order file that fixes the row of tabs without us: `tabWouldSurvive`
reads it, we do not claim a tab we would lose (which would cost the entry under *Tools*
as well), and the switch is **greyed out** — a switch that can be turned on and then
does nothing is worse than one that says so. Every other way of losing a tab can only be
seen afterwards, so if we *did* claim one and the built menu has not got it, that is
**reported once**, naming the order file if there is one and admitting we cannot name a
culprit if there is not.

The two must not be confused: the after-the-build check asks `self.tab_claimed`, not
"is the tab setting on". Asking the setting reported a missing tab on a device where we
had deliberately never asked for one — a warning, a wasted rebuild and a message about
something that was working as designed.

**One place at a time.** With the tab on, the id comes *out* of `more_tools`
(`inMoreTools(order, false)`): with it in both, the sorter puts the contents in whichever
it finds first and leaves an empty row behind in the other.

### Rebuilding KOReader's menu (and why it used to die)

The *skeleton* — `menu_items["KOMenu:menu_buttons"]` and one entry per tab carrying its
icon — is built **once**, in `FileManagerMenu:init()` (`ReaderMenu:init()` for the other
menu). `MenuSorter:sort` then **eats the flat table it sorts**: it moves each item into
its parent, removes it from the flat one ("remove reference from item_table so it won't
show up as orphaned"), and drops `KOMenu:menu_buttons` last of all. `setUpdateItemTable`
rebuilds its own entries and re-runs every plugin's `addToMainMenu`, but in **v2026.07.1
and earlier nothing rebuilds the skeleton** — so a second build has no row of tabs to
sort and dies on `ipairs(nil)` at `menusorter.lua:139`:

```
bad argument #1 to 'ipairs' (table expected, got nil)
```

Newer KOReaders fixed this by re-creating the skeleton at the top of
`setUpdateItemTable` (`getDefaultMenuButtons()`); we support both. Nobody but us asks
for a second build, so `rememberMenuItems` keeps a copy of `menu_items` from the first
`addToMainMenu` — before the sort, the only moment the skeleton still exists — and
`dropMenuCache` hands it back. **One level deep is exactly right**: that is the depth the
sort mutates (it appends a tab's children into the tab's own table), and everything else
in the copy is overwritten by the build that follows. With no snapshot we do not drop the
cache at all: a tab that waits for the next start-up beats a menu that cannot be opened.

## The 5-way and the list

**KOReader's `Menu` wraps the focus around inside the current page**, so holding Down on
a long list (every installed font, hundreds of recipes) never leaves the first one.
`RecipeBrowser:onFocusMove` steps onto the neighbouring page at the edges instead, and
paging back lands on the *last* row rather than the first.

## The library shortcut

`DocumentRegistry:addAuxProvider{ provider = "lardo", ... }` is how a plugin says it can
open a file. `FileManager:openFile()` then does `self[provider.provider]:openFile(file)`
— `self` being the file manager and `provider.provider` our plugin's `name`, which is the
whole of how a tap on a file in the library reaches `Lardo:openFile`. The "Open with…"
dialog asks `Lardo:isFileTypeSupported(file)` before offering us.

Three things are worth knowing before touching this:

- **`self.name` is not the provider key.** `FileManager:registerModule(name, module)` sets
  `self[name] = module` and then overwrites `module.name` with `"filemanager" .. name`
  (ReaderUI does the same with `"reader"`). Our `init()` runs *inside* the constructor, so
  registering the provider from `self.name` works — and every later use of it does not:
  by then the instance is called `filemanagerlardo` and the registry has never heard of
  it, so the association is quietly never written and the shortcut is a file nobody can
  see. Hence the `PROVIDER_KEY` constant.

- **The file type is the visibility, and nothing else is.** `FileChooser`'s filter is
  `file_filter = function(filename) return DocumentRegistry:hasProvider(filename) end` —
  a **bare name**, not a path, and without `include_aux`. Of the three things
  `hasProvider` accepts, only the first can answer that:

  1. `filetype_provider[suffix]`, which **only `addProvider(extension, …)` sets**;
  2. an association by file type, skipped for an auxiliary provider
     (`if provider and (not provider.order or include_aux)`, and `order` is precisely
     what makes a provider auxiliary);
  3. an association for that one file, which lives in its sidecar — and a bare filename
     cannot be resolved to one.

  `addAuxProvider` alone sets none of them: it says *who we are*, not *what we own*. So
  `registerProvider` calls both, and `addProvider("lardo", "application/x-lardo", …)` is
  what puts the shortcut on the screen. Registering an auxiliary provider as a file type
  is safe: `getFallbackProvider` only ever returns the `txt` one, so we cannot become the
  opener of last resort, and `openDocument` pcalls `provider.new`, so a cover browser
  asking our file for a thumbnail gets a log warning rather than a crash.
- **Register once.** The registry is a module and lives as long as KOReader does, while
  the plugin is instantiated again for every book opened and closed; without the guard,
  `DocumentRegistry.providers` grows all session and is walked for every file listed.
- The shortcut is named `Lardo.lardo`, untranslated: it sits among the books, and the
  thing it opens is called Lardo in every language.
- The folder on screen was listed before the file existed, hence the `ui:onRefresh()`.

## The Kindle screensaver

The ten minutes are **the firmware's**, not KOReader's: `com.lab126.powerd`'s "t1" timer.
KOReader grabs input from the event devices directly, so powerd never sees a reader
pressing keys and blanks the screen under it. Two levers exist, and they are not equal:

- `lipc-set-prop com.lab126.powerd preventScreenSaver 1` — what KOReader's own
  `keepalive.koplugin` uses. It is a **flag**: if KOReader goes away without clearing it,
  the device is left unable to blank its screen at all, which is why that plugin makes
  you confirm a warning first.
- `KindlePowerD:resetT1Timeout()` (`frontend/device/kindle/powerd.lua`) — sets
  `touchScreenSaverTimeout`, which makes powerd start counting again. A **nudge**: stop
  nudging and the firmware carries on as before. `autosuspend.koplugin` uses this one,
  every 4 minutes, so KOReader's own sleep timeout can outlive the firmware's.

Lardo uses the second, on its own timer, while a recipe is open — with two rules taken
from AutoSuspend's version: don't nudge while charging (it causes problems there), and
the nudge has to come in **before** the firmware's timer is up, not at the same moment,
so the interval is the one chosen minus thirty seconds.

`PluginShare.pause_auto_suspend` is set while nudging, which is how a plugin tells
`autosuspend.koplugin` not to suspend yet (`autoturn.koplugin` does the same). It is
cleared when the recipe closes.

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
- **How the tap zones feel.** They have all been used on an Oasis 2 now — the
  header, the words of the count, the ✕, the field and its catcher — so they
  work; whether the targets are the right *size* for a thumb in a kitchen is
  still a guess. The ✕ is the width of its glyph plus a padding, and the
  filter's words are exactly as wide as the words.
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
