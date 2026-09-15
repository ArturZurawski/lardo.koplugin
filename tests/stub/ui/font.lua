local Font = { missing = {} }
--- Mimics KOReader: nil for a font file it cannot load.
function Font:getFace(name, size)
    if self.missing[name] then return nil end
    return { name = name, size = size or 20 }
end
return Font
