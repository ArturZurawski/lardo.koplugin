--[[--
Wording for the recipe view, in the language Mealie is set to.

Mealie has no API field that says "use this language": it localizes every
response from the request's Accept-Language header
(mealie/middleware/locale_context.py). So the language is one setting on our
side, sent to the server *and* used for the chapter titles below.

Adding a language is a matter of copying the `en` block and translating the
values; the keys must stay as they are. Unknown languages fall back to
KOReader's own translation of the English wording.

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
    de = {
        description = "Beschreibung", ingredients = "Zutaten", instructions = "Zubereitung", notes = "Notizen",
        servings = "Portionen", recipe_yield = "Ergibt", total = "Gesamt", prep = "Vorbereitung",
        cook = "Kochen", categories = "Kategorien", tags = "Schlagwörter", source = "Quelle",
        empty = "Dieses Rezept hat keinen Inhalt.",
    },
    fr = {
        description = "Description", ingredients = "Ingrédients", instructions = "Préparation", notes = "Notes",
        servings = "Portions", recipe_yield = "Rendement", total = "Total", prep = "Préparation",
        cook = "Cuisson", categories = "Catégories", tags = "Étiquettes", source = "Source",
        empty = "Cette recette n'a pas de contenu.",
    },
    es = {
        description = "Descripción", ingredients = "Ingredientes", instructions = "Preparación", notes = "Notas",
        servings = "Raciones", recipe_yield = "Rendimiento", total = "Total", prep = "Preparación",
        cook = "Cocción", categories = "Categorías", tags = "Etiquetas", source = "Fuente",
        empty = "Esta receta no tiene contenido.",
    },
    it = {
        description = "Descrizione", ingredients = "Ingredienti", instructions = "Preparazione", notes = "Note",
        servings = "Porzioni", recipe_yield = "Resa", total = "Totale", prep = "Preparazione",
        cook = "Cottura", categories = "Categorie", tags = "Tag", source = "Fonte",
        empty = "Questa ricetta non ha contenuto.",
    },
    nl = {
        description = "Beschrijving", ingredients = "Ingrediënten", instructions = "Bereiding", notes = "Notities",
        servings = "Porties", recipe_yield = "Opbrengst", total = "Totaal", prep = "Voorbereiding",
        cook = "Koken", categories = "Categorieën", tags = "Labels", source = "Bron",
        empty = "Dit recept heeft geen inhoud.",
    },
    cs = {
        description = "Popis", ingredients = "Suroviny", instructions = "Postup", notes = "Poznámky",
        servings = "Porce", recipe_yield = "Výtěžnost", total = "Celkem", prep = "Příprava",
        cook = "Vaření", categories = "Kategorie", tags = "Štítky", source = "Zdroj",
        empty = "Tento recept nemá žádný obsah.",
    },
    pt = {
        description = "Descrição", ingredients = "Ingredientes", instructions = "Modo de preparo", notes = "Notas",
        servings = "Porções", recipe_yield = "Rendimento", total = "Total", prep = "Preparo",
        cook = "Cozimento", categories = "Categorias", tags = "Etiquetas", source = "Fonte",
        empty = "Esta receita não tem conteúdo.",
    },
    sv = {
        description = "Beskrivning", ingredients = "Ingredienser", instructions = "Gör så här", notes = "Anteckningar",
        servings = "Portioner", recipe_yield = "Ger", total = "Totalt", prep = "Förberedelse",
        cook = "Tillagning", categories = "Kategorier", tags = "Etiketter", source = "Källa",
        empty = "Det här receptet har inget innehåll.",
    },
}

--- Endonyms for the settings menu, and the full tag we send to Mealie
-- (its translation files are named pl-PL.json, pt-BR.json and so on).
local LANGUAGES = {
    { "cs", "cs-CZ", "Čeština" },
    { "de", "de-DE", "Deutsch" },
    { "en", "en-US", "English" },
    { "es", "es-ES", "Español" },
    { "fr", "fr-FR", "Français" },
    { "it", "it-IT", "Italiano" },
    { "nl", "nl-NL", "Nederlands" },
    { "pl", "pl-PL", "Polski" },
    { "pt", "pt-BR", "Português" },
    { "sv", "sv-SE", "Svenska" },
}

--- What the settings menu offers. The other languages above are still used
-- when KOReader itself runs in one of them ("Follow KOReader"), but the plugin
-- is only *translated* into these two, so these are the only ones worth picking.
local CHOICES = { "en", "pl" }

LardoLang.ENGLISH = ENGLISH
LardoLang.STRINGS = STRINGS
LardoLang.LANGUAGES = LANGUAGES

--- The entries of LANGUAGES that the menu offers, in its order.
function LardoLang.choices()
    local out = {}
    for i = 1, #CHOICES do
        for j = 1, #LANGUAGES do
            if LANGUAGES[j][1] == CHOICES[i] then
                table.insert(out, LANGUAGES[j])
            end
        end
    end
    return out
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
