local gettext = setmetatable({}, {
    __call = function(_, msgstr) return msgstr end,
})
gettext.ngettext = function(singular, plural, n)
    if n == 1 then return singular end
    return plural
end
return gettext
