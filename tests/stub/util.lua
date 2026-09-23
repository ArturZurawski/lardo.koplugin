local util = {}

-- KOReader's stringLower is utf8proc, i.e. the whole of Unicode. This is the
-- letters with marks that recipes and their tags actually carry -- enough that
-- typing ŚNIADANIE still finds "śniadanie", which a plain ASCII :lower() would
-- not, and the filter would look broken here while working on the device.
local FOLD = {
    ["Ą"] = "ą", ["Ć"] = "ć", ["Ę"] = "ę", ["Ł"] = "ł", ["Ń"] = "ń",
    ["Ó"] = "ó", ["Ś"] = "ś", ["Ź"] = "ź", ["Ż"] = "ż",
    ["Ä"] = "ä", ["Ö"] = "ö", ["Ü"] = "ü", ["ß"] = "ß",
    ["É"] = "é", ["È"] = "è", ["À"] = "à", ["Ç"] = "ç", ["Ñ"] = "ñ",
}

function util.stringLower(s)
    s = tostring(s):lower() -- the ASCII half; the bytes above 127 are left alone
    return (s:gsub("[\194-\244][\128-\191]*", function(char) return FOLD[char] or char end))
end

return util
