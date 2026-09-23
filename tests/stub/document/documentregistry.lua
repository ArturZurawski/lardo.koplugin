-- KOReader's registry, in the part that decides two things: who opens a file,
-- and -- the one that cost us a shortcut nobody could see -- whether the file
-- browser lists it at all.
--
-- The browser's filter is `file_filter = function(filename)
-- return DocumentRegistry:hasProvider(filename) end`: a **bare name**, so the
-- rules below are answered with nothing but the file type. Kept rule for rule
-- as in KOReader v2026.07.1, because a kinder version of this file is what let
-- a shortcut that could never appear pass its tests.
local DocSettings = require("docsettings")

local DocumentRegistry = {
    known_providers = {},   -- key -> provider table
    filetype_provider = {}, -- extension -> true, set by addProvider only
    providers = {},         -- every registered file type, in order
    associations = {},      -- per file, as written into a sidecar
    filetype_associations = {}, -- per file type, as kept in the settings
}

local function suffix(file)
    return (file:match(".+%.([^.]+)") or ""):lower()
end

function DocumentRegistry:addProvider(extension, mimetype, provider, weight)
    extension = extension:lower()
    table.insert(self.providers, {
        extension = extension,
        mimetype = mimetype,
        provider = provider,
        weight = weight or 100,
    })
    self.filetype_provider[extension] = true
    if self.known_providers[provider.provider] == nil then
        self.known_providers[provider.provider] = provider
    end
end

--- Says who a provider is. Notably, it does *not* say what it owns.
function DocumentRegistry:addAuxProvider(provider)
    self.known_providers[provider.provider] = provider
end

function DocumentRegistry:getProviderFromKey(key) return self.known_providers[key] end

function DocumentRegistry:hasProvider(file, _mimetype, include_aux)
    if not file then return false end
    -- a registered file type
    if self.filetype_provider[suffix(file)] then return true end
    -- a provider associated with the file type -- but an auxiliary provider is
    -- exactly one with an `order`, and those do not count here
    local key = self.filetype_associations[suffix(file)]
    local provider = key and self.known_providers[key]
    if provider and (not provider.order or include_aux) then return true end
    -- a provider associated with this one file, which lives in its sidecar --
    -- and a bare filename is not a path to one
    if DocSettings:hasSidecarFile(file) then
        return DocSettings:open(file):has("provider")
    end
    return false
end

function DocumentRegistry:getProviders(file)
    local found = {}
    for _, provider in ipairs(self.providers) do
        if suffix(file) == provider.extension then table.insert(found, provider) end
    end
    return #found > 0 and found or nil
end

function DocumentRegistry:getProvider(file, include_aux)
    local providers = self:getProviders(file)
    if providers or include_aux then
        local association = self.associations[file]
        local provider = association and self.known_providers[association.provider]
        if provider and (not provider.order or include_aux) then return provider, true end
        return providers and providers[1].provider
    end
    return nil
end

function DocumentRegistry:setProvider(file, provider, all)
    if all then
        self.filetype_associations[suffix(file)] = provider.provider
    else
        self.associations[file] = { provider = provider.provider }
    end
end

return DocumentRegistry
