--[[--
Wording for the recipe view, in the language Mealie is set to.

Mealie has no API field that says "use this language": it localizes every
response from the request's Accept-Language header
(mealie/middleware/locale_context.py). So the language is one setting on our
side, sent to the server *and* used for the chapter titles below.

English and Polish only. Adding a language is a matter of copying the `en`
block and translating the values, plus a line in LANGUAGES; the keys must stay
as they are. Unknown languages fall back to KOReader's own translation of the
English wording.

@module koplugin.lardo.lang
--]]

local _ = require("lardoi18n").gettext

local LardoLang = {}

--- English is both the fallback and the msgid we hand to KOReader's gettext.
local ENGLISH = {
    description  = "Description",
    ingredients  = "Ingredients",
    instructions = "Instructions",
    notes        = "Notes",
    servings     = "Servings",
    recipe_yield = "Yield",
    total        = "Total",
    prep         = "Prep",
    cook         = "Cook",
    categories   = "Categories",
    tags         = "Tags",
    source       = "Source",
    empty        = "This recipe has no content.",
}

local STRINGS = {
    en = ENGLISH,
    pl = {
        description = "Opis", ingredients = "Składniki", instructions = "Wykonanie", notes = "Notatki",
        servings = "Porcje", recipe_yield = "Wydajność", total = "Czas", prep = "Przygotowanie",
        cook = "Gotowanie", categories = "Kategorie", tags = "Tagi", source = "Źródło",
        empty = "Ten przepis nie ma treści.",
    },
}

--- The languages there is wording for: endonyms for the settings menu, and
-- the full tag we send to Mealie (its translation files are named pl-PL.json
-- and so on). Any other language KOReader runs in is still sent to Mealie
-- ("Follow KOReader"); our own chapter titles then fall back to KOReader's
-- translation of the English ones.
local LANGUAGES = {
    { "en", "en-US", "English" },
    { "pl", "pl-PL", "Polski" },
}

LardoLang.ENGLISH = ENGLISH
LardoLang.STRINGS = STRINGS
LardoLang.LANGUAGES = LANGUAGES

--- What the settings menu offers.
function LardoLang.choices()
    return LANGUAGES
end

local current = nil -- nil = fall back to KOReader's own translations

--- "pl-PL" -> "pl". Mealie uses full tags, our table is keyed by the base one.
function LardoLang.baseCode(code)
    if type(code) ~= "string" then return nil end
    local base = code:match("^%s*(%a%a%a?)") -- ISO 639-1/2
    return base and base:lower() or nil
end

--- @param code language tag as sent to Mealie, e.g. "pl-PL"; nil to reset
function LardoLang.set(code)
    current = STRINGS[LardoLang.baseCode(code) or ""] or nil
end

function LardoLang.isSupported(code)
    return STRINGS[LardoLang.baseCode(code) or ""] ~= nil
end

--- Name to show for a language tag, e.g. "pl-PL" -> "Polski".
function LardoLang.nameFor(code)
    local base = LardoLang.baseCode(code)
    for i = 1, #LANGUAGES do
        if LANGUAGES[i][1] == base then
            return LANGUAGES[i][3]
        end
    end
    return code
end

--- Translated wording for a key, falling back to KOReader's own translations.
function LardoLang.t(key)
    if current and current[key] then
        return current[key]
    end
    return _(ENGLISH[key] or key)
end

return LardoLang
