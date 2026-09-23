local Font = { missing = {}, fontmap = { smallinfofont = 20, cfont = 24 } }
--- Mimics KOReader: nil for a font file it cannot load.
--
-- And, just as importantly, an error when asked for a face without a size. The
-- real getFace() falls back to `fontmap[name]` -- which a *font file path* is
-- never a key of -- and then scales it, so a missing size is arithmetic on a
-- nil, deep inside the framebuffer. That is how the recipe list took the whole
-- device down at start-up while this stub happily answered.
function Font:getFace(name, size)
    if self.missing[name] then return nil end
    size = size or self.fontmap[name]
    if not size then
        error("Font:getFace: no size given and no fontmap entry for " .. tostring(name))
    end
    return { name = name, size = size }
end
return Font
