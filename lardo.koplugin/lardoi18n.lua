--[[--
The plugin's own translations.

KOReader's gettext only knows the strings that ship with KOReader, so the
plugin's menus and messages stayed English whatever language was picked. The
tables here are the plugin's own interface, translated; anything not in them
falls back to KOReader's gettext, and from there to the English text itself.

The language is the plugin's language setting (see lardolang.lua): choosing
Polski for the recipes turns the menus Polish as well. Adding a language is a
matter of adding a table keyed by the English text, plus its plural forms;
nothing has to be complete, every missing string simply stays English.

@module koplugin.lardo.i18n
--]]

local gettext = require("gettext")

local LardoI18N = {}

local PL = {
    -- menus
    ["Lardo"] = "Lardo",
    ["Lardo: recipes"] = "Lardo: przepisy",
    ["Lardo: jump to the ingredients"] = "Lardo: przejdź do składników",
    ["Start with: %1"] = "Zacznij od: %1",
    ["Browse recipes"] = "Przeglądaj przepisy",
    ["Refresh recipes from the server"] = "Odśwież przepisy z serwera",
    ["Fetches the list, and with it every recipe that is new or has changed, so everything is readable without WiFi afterwards."] =
        "Pobiera listę, a wraz z nią każdy nowy lub zmieniony przepis, żeby potem wszystko dało się czytać bez WiFi.",
    ["Connection: %1"] = "Połączenie: %1",
    ["not set"] = "nie ustawiono",
    ["View"] = "Widok",
    ["Language: %1"] = "Język: %1",
    ["Follow KOReader (%1)"] = "Za KOReaderem (%1)",
    ["Open Lardo instead of the file browser at start-up"] =
        "Otwieraj Lardo zamiast menedżera plików przy starcie",

    -- view settings
    ["Font size: %1"] = "Rozmiar czcionki: %1",
    ["Font size"] = "Rozmiar czcionki",
    ["Used for the recipes and for the recipe list."] =
        "Używany w przepisach i na liście przepisów.",
    ["Typeface: %1"] = "Krój pisma: %1",
    ["Typeface"] = "Krój pisma",
    ["KOReader default"] = "domyślny KOReadera",
    ["Use KOReader's default typeface"] = "Użyj domyślnego kroju KOReadera",
    ["Press a font to use it"] = "Naciśnij czcionkę, aby jej użyć",
    ["Reading position bar: %1"] = "Pasek postępu: %1",
    ["Reading position bar"] = "Pasek postępu",
    ["Under the chapters"] = "Pod rozdziałami",
    ["Bottom edge"] = "Przy dolnej krawędzi",
    ["Right edge, whole recipe"] = "Przy prawej krawędzi, cały przepis",
    ["Hidden"] = "Ukryty",
    ["Button row at the bottom: %1"] = "Rząd przycisków na dole: %1",
    ["On a touch screen it starts out shown; the same things are on the header and on a long press."] =
        "Na ekranie dotykowym jest domyślnie widoczny; to samo jest w nagłówku i pod długim przytrzymaniem.",
    ["shown"] = "widoczny",
    ["hidden"] = "ukryty",
    ["View and font"] = "Widok i czcionka",
    ["This KOReader version has no number picker. Use the A- / A+ buttons in the recipe menu instead."] =
        "Ta wersja KOReadera nie ma pola liczbowego. Użyj przycisków A- / A+ w menu przepisu.",
    ["This KOReader version does not expose its font list."] =
        "Ta wersja KOReadera nie udostępnia listy czcionek.",

    -- connection
    ["Configuration file: %1"] = "Plik konfiguracyjny: %1",
    ["Configuration file: none yet"] = "Plik konfiguracyjny: jeszcze go nie ma",
    ["Configuration file"] = "Plik konfiguracyjny",
    ["Reload configuration file"] = "Wczytaj ponownie plik konfiguracyjny",
    ["Server address"] = "Adres serwera",
    ["Mealie server address"] = "Adres serwera Mealie",
    ["Address of your Mealie instance, including the port."] =
        "Adres Twojej instancji Mealie, razem z portem.",
    ["Log in with username and password"] = "Zaloguj się nazwą użytkownika i hasłem",
    ["Enter API token manually"] = "Wpisz token API ręcznie",
    ["Test connection"] = "Sprawdź połączenie",
    ["Mealie API token"] = "Token API Mealie",
    ["Tokens are long. It is usually easier to put it in lardo.conf over USB, or to log in with your username and password."] =
        "Tokeny są długie. Zwykle łatwiej wpisać go do lardo.conf przez USB albo zalogować się nazwą użytkownika i hasłem.",
    ["Log in to Mealie"] = "Zaloguj się do Mealie",
    ["Username or email"] = "Nazwa użytkownika lub e-mail",
    ["Password"] = "Hasło",
    ["Log in"] = "Zaloguj",
    ["Please enter the Mealie server address."] = "Podaj adres serwera Mealie.",
    ["Logging in to Mealie…"] = "Logowanie do Mealie…",
    ["Logged in. The API token has been saved to:\n%1"] =
        "Zalogowano. Token API zapisano w:\n%1",
    ["Logged in. The API token has been saved on the device."] =
        "Zalogowano. Token API zapisano na urządzeniu.",
    ["Contacting the Mealie server…"] = "Łączenie z serwerem Mealie…",

    -- offline
    ["Recipe list updated: %1"] = "Lista przepisów zaktualizowana: %1",
    ["Recipe list was never downloaded"] = "Lista przepisów nie była jeszcze pobrana",
    ["Refresh at start-up"] = "Odświeżaj przy starcie",
    ["Refreshes once, when KOReader starts. WiFi is brought up the way KOReader's own settings say, and handed back afterwards."] =
        "Odświeża raz, przy starcie KOReadera. WiFi włącza się zgodnie z ustawieniami KOReadera i wraca pod jego kontrolę po zakończeniu.",
    ["Delete downloaded recipes"] = "Usuń pobrane przepisy",
    ["Delete all recipes stored on this device?\nThey will be downloaded again when needed."] =
        "Usunąć wszystkie przepisy zapisane na urządzeniu?\nW razie potrzeby zostaną pobrane ponownie.",
    ["Delete"] = "Usuń",
    ["Downloaded recipes deleted."] = "Usunięto pobrane przepisy.",
    ["Everything was already up to date."] = "Wszystko było już aktualne.",

    -- the recipe list and its filter box
    ["Filter: %1_   %2/%3"] = "Filtr: %1_   %2/%3",
    ["Filter recipes"] = "Filtruj przepisy",
    ["Filter"] = "Filtruj",
    ["On a device with a keyboard you can simply start typing on the list itself."] =
        "Na urządzeniu z klawiaturą wystarczy zacząć pisać na samej liście.",
    ["Filters the downloaded recipe list by name and description."] =
        "Filtruje pobraną listę przepisów po nazwie i opisie.",
    ["Clear the filter"] = "Wyczyść filtr",
    ["Nothing matches. Press Back to clear the filter."] =
        "Brak wyników. Naciśnij Wstecz, aby wyczyścić filtr.",
    ["No recipes yet. Press Menu, then Refresh."] =
        "Nie ma jeszcze przepisów. Naciśnij Menu, a potem Odśwież.",
    ["Refresh from the server"] = "Odśwież z serwera",
    ["Lardo settings"] = "Ustawienia Lardo",
    ["Close Lardo"] = "Zamknij Lardo",
    ["Sort by: %1"] = "Sortowanie: %1",
    ["Sort recipes by"] = "Sortuj przepisy wg",
    ["Name"] = "Nazwy",
    ["Newest first"] = "Najnowszych",
    ["Recently changed"] = "Ostatnio zmienionych",
    ["Favourites first"] = "Ulubionych",
    ["Show all"] = "Pokaż wszystkie",
    ["Loading the recipe list from Mealie…"] = "Pobieranie listy przepisów z Mealie…",
    ["Loading %1…"] = "Wczytywanie %1…",

    -- set-up and configuration file
    ["Lardo reads its server address and API token from:\n\n%1\n\nEdit it over USB, then choose \"Reload configuration file\"."] =
        "Lardo czyta adres serwera i token API z:\n\n%1\n\nEdytuj ten plik przez USB, a potem wybierz „Wczytaj ponownie plik konfiguracyjny”.",
    ["No configuration file found.\n\nLardo looks for lardo.conf in:\n%1\n\nCreate a template at the first of those? You can then fill in the server address and the API token over USB, without typing them on the device."] =
        "Nie znaleziono pliku konfiguracyjnego.\n\nLardo szuka lardo.conf w:\n%1\n\nUtworzyć szablon w pierwszej z tych lokalizacji? Adres serwera i token API uzupełnisz przez USB, bez wpisywania ich na urządzeniu.",
    ["Create"] = "Utwórz",
    ["Create file"] = "Utwórz plik",
    ["Created:\n%1\n\nFill it in over USB, then choose \"Reload configuration file\"."] =
        "Utworzono:\n%1\n\nUzupełnij go przez USB, a potem wybierz „Wczytaj ponownie plik konfiguracyjny”.",
    ["Created:\n%1\n\nConnect the device over USB, fill in \"url\" and \"token\", then choose \"Reload configuration file\"."] =
        "Utworzono:\n%1\n\nPodłącz urządzenie przez USB, uzupełnij „url” i „token”, a potem wybierz „Wczytaj ponownie plik konfiguracyjny”.",
    ["Could not write the configuration file:\n%1"] =
        "Nie udało się zapisać pliku konfiguracyjnego:\n%1",
    ["Loaded settings from:\n%1"] = "Wczytano ustawienia z:\n%1",
    ["Read %1, but it contains no server address or token."] =
        "Odczytano %1, ale nie ma w nim adresu serwera ani tokenu.",
    ["Saved to:\n%1"] = "Zapisano w:\n%1",
    ["Lardo is not set up yet.\n\nPut your server address and API token into:\n%1"] =
        "Lardo nie jest jeszcze skonfigurowane.\n\nWpisz adres serwera i token API do:\n%1",
    ["Lardo is not set up yet.\n\nPut your server address and API token into lardo.conf, in any of:\n%1\n\nCreate that file now?"] =
        "Lardo nie jest jeszcze skonfigurowane.\n\nWpisz adres serwera i token API do lardo.conf, w jednej z lokalizacji:\n%1\n\nUtworzyć ten plik teraz?",
    ["Enter manually"] = "Wpisz ręcznie",
    ["Cancel"] = "Anuluj",
    ["Save"] = "Zapisz",
    ["Back"] = "Wstecz",
    ["Close"] = "Zamknij",

    -- errors
    ["Something went wrong."] = "Coś poszło nie tak.",
    ["Something went wrong:\n%1"] = "Coś poszło nie tak:\n%1",
    ["This recipe could not be read."] = "Nie udało się odczytać tego przepisu.",
    ["Could not open the recipe view.\n\n%1"] = "Nie udało się otworzyć widoku przepisu.\n\n%1",
    ["Mealie server address is not set."] = "Adres serwera Mealie nie jest ustawiony.",
    ["Could not reach the Mealie server.\n%1"] = "Nie można połączyć się z serwerem Mealie.\n%1",
    ["Mealie rejected the credentials. Check the token, or log in again."] =
        "Mealie odrzuciło dane logowania. Sprawdź token albo zaloguj się ponownie.",
    ["Not found on the Mealie server. Check the server address."] =
        "Nie znaleziono na serwerze Mealie. Sprawdź adres serwera.",
    ["Mealie server returned an error: %1"] = "Serwer Mealie zwrócił błąd: %1",
    ["Mealie server returned an empty response."] = "Serwer Mealie zwrócił pustą odpowiedź.",
    ["Mealie server returned a response that is not valid JSON.\nIs the server address correct?"] =
        "Serwer Mealie zwrócił odpowiedź, która nie jest poprawnym JSON-em.\nCzy adres serwera jest poprawny?",
    ["Mealie did not return an access token."] = "Mealie nie zwróciło tokenu dostępu.",
    ["Unexpected answer from the Mealie server.\nIs this really a Mealie instance?"] =
        "Nieoczekiwana odpowiedź serwera Mealie.\nCzy to na pewno instancja Mealie?",
    ["This recipe has no identifier."] = "Ten przepis nie ma identyfikatora.",
}

--- Keyed by the English singular, one entry per Polish plural form:
-- {1, 22, 34...}, {2-4, 22-24...}, {0, 5-21, 25-31...}.
local PL_PLURAL = {
    ["Offline: %1 recipe stored"] = {
        "Offline: %1 przepis na urządzeniu",
        "Offline: %1 przepisy na urządzeniu",
        "Offline: %1 przepisów na urządzeniu",
    },
    ["Connected. %1 recipe on the server."] = {
        "Połączono. %1 przepis na serwerze.",
        "Połączono. %1 przepisy na serwerze.",
        "Połączono. %1 przepisów na serwerze.",
    },
    ["%1 recipe in Mealie"] = {
        "%1 przepis w Mealie",
        "%1 przepisy w Mealie",
        "%1 przepisów w Mealie",
    },
    ["%1 recipe available."] = {
        "%1 przepis dostępny.",
        "%1 przepisy dostępne.",
        "%1 przepisów dostępnych.",
    },
    ["%1 deleted recipe removed from the device."] = {
        "Usunięto z urządzenia %1 skasowany przepis.",
        "Usunięto z urządzenia %1 skasowane przepisy.",
        "Usunięto z urządzenia %1 skasowanych przepisów.",
    },
    ["%1 recipe added."] = { "Dodano %1 przepis.", "Dodano %1 przepisy.", "Dodano %1 przepisów." },
    ["%1 recipe updated."] = {
        "Zaktualizowano %1 przepis.",
        "Zaktualizowano %1 przepisy.",
        "Zaktualizowano %1 przepisów.",
    },
    ["%1 recipe removed."] = {
        "Usunięto %1 przepis.",
        "Usunięto %1 przepisy.",
        "Usunięto %1 przepisów.",
    },
    ["Downloading %1 recipe…\n%2 of %1"] = {
        "Pobieranie %1 przepisu…\n%2 z %1",
        "Pobieranie %1 przepisów…\n%2 z %1",
        "Pobieranie %1 przepisów…\n%2 z %1",
    },
    ["%1 recipe failed."] = {
        "Nie udało się pobrać %1 przepisu.",
        "Nie udało się pobrać %1 przepisów.",
        "Nie udało się pobrać %1 przepisów.",
    },
}

--- Polish: one, two-to-four (but not twelve-to-fourteen), and everything else.
local function polishPluralForm(n)
    if n == 1 then return 1 end
    local last, last_two = n % 10, n % 100
    if last >= 2 and last <= 4 and not (last_two >= 12 and last_two <= 14) then
        return 2
    end
    return 3
end

local TRANSLATIONS = { pl = PL }
local PLURALS = { pl = PL_PLURAL }
local PLURAL_FORMS = { pl = polishPluralForm }

local strings, plurals, plural_form

--- @param code language tag, e.g. "pl-PL"; anything unknown means English
function LardoI18N.setLanguage(code)
    local base = type(code) == "string" and code:match("^%s*(%a%a%a?)") or nil
    base = base and base:lower() or ""
    strings = TRANSLATIONS[base]
    plurals = PLURALS[base]
    plural_form = PLURAL_FORMS[base]
end

--- Drop-in for KOReader's `_()`.
function LardoI18N.gettext(msgid)
    if strings then
        local translated = strings[msgid]
        if translated then return translated end
    end
    return gettext(msgid)
end

--- Drop-in for KOReader's `_.ngettext()`.
function LardoI18N.ngettext(singular, plural, n)
    local forms = plurals and plurals[singular]
    if forms then
        local index = plural_form and plural_form(n) or (n == 1 and 1 or 2)
        return forms[index] or forms[#forms]
    end
    return gettext.ngettext(singular, plural, n)
end

LardoI18N.TRANSLATIONS = TRANSLATIONS

return LardoI18N
