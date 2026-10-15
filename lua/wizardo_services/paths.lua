local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = assert(source:match('^(.*)[/\\]lua[/\\]wizardo_services[/\\]paths%.lua$'), 'cannot locate services root')
return { root = root }
