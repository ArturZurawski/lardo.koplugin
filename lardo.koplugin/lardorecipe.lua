--[[--
Turns Mealie's JSON into small plain-Lua tables (safe to serialize into the
cache) and renders them as plain text for the reading view.

@module koplugin.lardo.recipe
--]]

local L = require("lardolang")

local Recipe = {}

--- JSON nulls come back as nil or as a light userdata depending on the decoder,
-- so anything that is not a string/number is treated as absent.
local function str(value)
    if type(value) == "string" then return value end
    if type(value) == "number" then
        if value == math.floor(value) then
            return string.format("%d", value)
        end
        return (string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", ""))
    end
    return ""
end

local function trim(s)
    return (str(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", ndash = "-", mdash = "-", hellip = "...",
    deg = "\u{00B0}", frac12 = "1/2", frac14 = "1/4", frac34 = "3/4",
}

--- Mealie stores markdown, but recipes scraped from the web often carry HTML
-- leftovers too. Neither renders in a plain TextViewer, so flatten both.
local function cleanText(value)
    local s = str(value)
    if s == "" then return "" end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    s = s:gsub("<[bB][rR]%s*/?>", "\n")
    s = s:gsub("</[pPlL][iI]?>", "\n")
    s = s:gsub("<[^<>]->", "")
    s = s:gsub("&#(%d+);", function(n)
        local c = tonumber(n)
        return c and c < 128 and string.char(c) or ""
    end)
    s = s:gsub("&(%a+);", function(name)
        return ENTITIES[name:lower()] or ""
    end)
    -- markdown: links, emphasis, headings, horizontal rules, list bullets
    s = s:gsub("!?%[([^%]]*)%]%b()", "%1")
    s = s:gsub("%*%*([^*]+)%*%*", "%1")
    s = s:gsub("__([^_]+)__", "%1")
    s = s:gsub("%*([^*\n]+)%*", "%1")
    s = s:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    s = s:gsub("\n%s*[%-%*_][%s%-%*_]*\n", "\n")
    s = s:gsub("[ \t]+\n", "\n")
    s = s:gsub("\n\n\n+", "\n\n")
    return trim(s)
end
Recipe.cleanText = cleanText

local function nameList(list)
    local names = {}
    if type(list) == "table" then
        for i = 1, #list do
            local entry = list[i]
            local name = type(entry) == "table" and trim(entry.name) or trim(entry)
            if name ~= "" then
                table.insert(names, name)
            end
        end
    end
    return names
end

--- Best effort "1 1/2 cups flour" line for one ingredient.
local function ingredientText(raw)
    if type(raw) ~= "table" then
        return cleanText(raw)
    end
    local display = trim(raw.display)
    if display ~= "" then return cleanText(display) end

    local parts = {}
    local quantity = tonumber(raw.quantity)
    if quantity and quantity > 0 then
        table.insert(parts, str(quantity))
    end
    local unit = raw.unit
    if type(unit) == "table" then
        local abbreviate = unit.useAbbreviation or unit.use_abbreviation
        local unit_name = abbreviate and trim(unit.abbreviation) or ""
        if unit_name == "" then unit_name = trim(unit.name) end
        if unit_name ~= "" then table.insert(parts, unit_name) end
    end
    local food = raw.food
    if type(food) == "table" then
        local food_name = trim(food.name)
        if food_name ~= "" then table.insert(parts, food_name) end
    end

    local note = trim(raw.note)
    if #parts == 0 then
        -- amount-less recipes keep everything in the note / original text
        return cleanText(note ~= "" and note or raw.originalText)
    end
    local line = table.concat(parts, " ")
    if note ~= "" then
        line = line .. " (" .. note .. ")"
    end
    return cleanText(line)
end

--- Shrinks a recipe summary to what the list view needs.
function Recipe.normalizeSummary(raw)
    if type(raw) ~= "table" then return nil end
    local slug = trim(raw.slug)
    if slug == "" then slug = trim(raw.id) end
    local name = trim(raw.name)
    if name == "" then name = slug end
    if slug == "" then return nil end
    -- Mealie stamps every recipe; this is what lets us sync only what moved.
    local updated_at = trim(raw.updatedAt)
    if updated_at == "" then updated_at = trim(raw.dateUpdated) end
    -- dateAdded is a plain date, createdAt a timestamp; both sort as strings
    local date_added = trim(raw.dateAdded)
    if date_added == "" then date_added = trim(raw.createdAt) end
    return {
        slug = slug,
        -- Mealie's own id, which is how it names recipes in the favourites list
        id = trim(raw.id),
        name = name,
        updated_at = updated_at,
        date_added = date_added,
        description = cleanText(raw.description),
        total_time = trim(raw.totalTime),
        prep_time = trim(raw.prepTime),
        perform_time = trim(raw.performTime),
        cook_time = trim(raw.cookTime),
        recipe_yield = trim(raw.recipeYield),
        categories = nameList(raw.recipeCategory),
        tags = nameList(raw.tags),
        rating = tonumber(raw.rating),
    }
end

--- Full recipe, including the parts only returned by /api/recipes/{slug}.
function Recipe.normalizeFull(raw)
    local recipe = Recipe.normalizeSummary(raw)
    if not recipe then return nil end

    recipe.org_url = trim(raw.orgURL)
    recipe.servings = trim(raw.recipeServings)

    recipe.ingredients = {}
    if type(raw.recipeIngredient) == "table" then
        for i = 1, #raw.recipeIngredient do
            local entry = raw.recipeIngredient[i]
            local text = ingredientText(entry)
            local title = type(entry) == "table" and trim(entry.title) or ""
            if text ~= "" or title ~= "" then
                table.insert(recipe.ingredients, { title = title, text = text })
            end
        end
    end

    recipe.steps = {}
    if type(raw.recipeInstructions) == "table" then
        for i = 1, #raw.recipeInstructions do
            local entry = raw.recipeInstructions[i]
            local text = type(entry) == "table" and cleanText(entry.text) or cleanText(entry)
            local title = type(entry) == "table" and trim(entry.title) or ""
            if text ~= "" or title ~= "" then
                table.insert(recipe.steps, { title = title, text = text })
            end
        end
    end

    recipe.notes = {}
    if type(raw.notes) == "table" then
        for i = 1, #raw.notes do
            local entry = raw.notes[i]
            if type(entry) == "table" then
                local text = cleanText(entry.text)
                local title = trim(entry.title)
                if text ~= "" or title ~= "" then
                    table.insert(recipe.notes, { title = title, text = text })
                end
            end
        end
    end

    return recipe
end

--- Right-aligned column in the recipe list: the most useful number we have.
function Recipe.listMandatory(recipe)
    if recipe.total_time ~= "" then return recipe.total_time end
    if recipe.perform_time ~= "" then return recipe.perform_time end
    if recipe.cook_time ~= "" then return recipe.cook_time end
    if recipe.prep_time ~= "" then return recipe.prep_time end
    return ""
end

--- Compact summary for the view header: the one number worth seeing while
-- you are reading the instructions.
function Recipe.headerMeta(recipe)
    return Recipe.listMandatory(recipe)
end

--- Splits a recipe into the chapters the view pages through.
-- Description, ingredients, instructions and notes are separate chapters, so
-- you can jump straight to the one you need instead of scrolling past the
-- other three while cooking.
-- @return array of { id = , title = , text = }
function Recipe.toChapters(recipe)
    local chapters = {}
    local function chapter(id, title, lines)
        if #lines > 0 then
            table.insert(chapters, { id = id, title = title, text = table.concat(lines, "\n") })
        end
    end

    -- Description: the summary of the recipe, plus whatever prose it has.
    local lines = {}
    local meta = {}
    if recipe.servings ~= "" and recipe.servings ~= "0" then
        table.insert(meta, L.t("servings") .. ": " .. recipe.servings)
    elseif recipe.recipe_yield ~= "" then
        table.insert(meta, L.t("recipe_yield") .. ": " .. recipe.recipe_yield)
    end
    if recipe.total_time ~= "" then
        table.insert(meta, L.t("total") .. ": " .. recipe.total_time)
    end
    if recipe.prep_time ~= "" then
        table.insert(meta, L.t("prep") .. ": " .. recipe.prep_time)
    end
    if recipe.perform_time ~= "" then
        table.insert(meta, L.t("cook") .. ": " .. recipe.perform_time)
    elseif recipe.cook_time ~= "" then
        table.insert(meta, L.t("cook") .. ": " .. recipe.cook_time)
    end
    if #meta > 0 then
        table.insert(lines, table.concat(meta, "  |  "))
    end
    if #recipe.categories > 0 then
        table.insert(lines, L.t("categories") .. ": " .. table.concat(recipe.categories, ", "))
    end
    if #recipe.tags > 0 then
        table.insert(lines, L.t("tags") .. ": " .. table.concat(recipe.tags, ", "))
    end
    if recipe.description ~= "" then
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, recipe.description)
    end
    if recipe.org_url ~= "" then
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, L.t("source") .. ": " .. recipe.org_url)
    end
    chapter("description", L.t("description"), lines)

    lines = {}
    for i = 1, #recipe.ingredients do
        local item = recipe.ingredients[i]
        if item.title ~= "" then
            if #lines > 0 then table.insert(lines, "") end
            table.insert(lines, item.title .. ":")
        end
        if item.text ~= "" then
            table.insert(lines, "- " .. item.text)
        end
    end
    chapter("ingredients", L.t("ingredients"), lines)

    lines = {}
    local number = 0
    for i = 1, #recipe.steps do
        local step = recipe.steps[i]
        if step.title ~= "" then
            if #lines > 0 then table.insert(lines, "") end
            table.insert(lines, step.title .. ":")
        end
        if step.text ~= "" then
            number = number + 1
            table.insert(lines, number .. ". " .. step.text)
            table.insert(lines, "")
        end
    end
    chapter("instructions", L.t("instructions"), lines)

    lines = {}
    for i = 1, #recipe.notes do
        local note = recipe.notes[i]
        if note.title ~= "" then
            table.insert(lines, note.title .. ":")
        end
        if note.text ~= "" then
            table.insert(lines, note.text)
        end
        table.insert(lines, "")
    end
    chapter("notes", L.t("notes"), lines)

    if #chapters == 0 then
        table.insert(chapters, { id = "empty", title = L.t("description"), text = L.t("empty") })
    end
    return chapters
end

return Recipe
