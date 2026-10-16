local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = assert(source:match('^(.*)[/\\]lua[/\\]hikari[/\\]paths%.lua$'), 'cannot locate hikari plugin root')
return { root = root }
