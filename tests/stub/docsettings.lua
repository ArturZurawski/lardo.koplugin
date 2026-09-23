-- The sidecar KOReader keeps beside a file; purging it is what makes the
-- library forget a shortcut we removed.
local DocSettings = { purged = {}, sidecars = {} }

--- Only ever true for a real path: a sidecar is a folder next to the file, so a
-- bare filename -- which is all the file browser's filter is given -- can never
-- have one. That is why the sidecar cannot be what makes a file visible.
function DocSettings:hasSidecarFile(file)
    return self.sidecars[file] ~= nil
end

function DocSettings:open(file)
    local settings = self.sidecars[file] or {}
    return {
        file = file,
        purge = function()
            table.insert(DocSettings.purged, file)
            DocSettings.sidecars[file] = nil
        end,
        has = function(_self, key) return settings[key] ~= nil end,
        readSetting = function(_self, key) return settings[key] end,
        saveSetting = function(_self, key, value)
            settings[key] = value
            DocSettings.sidecars[file] = settings
        end,
        flush = function() end,
    }
end

return DocSettings
