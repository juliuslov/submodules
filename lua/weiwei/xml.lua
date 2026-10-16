-- Minimal, bounded XML reader for lyric documents (TTML).
--
-- This is deliberately not a general XML library: no DTD/entity expansion, no
-- external or parameter entities, no XInclude, bounded depth and node count. It
-- keeps namespace prefixes as written (`ttm:agent`, `itunes:timing`) so the TTML
-- reader can match Apple's dialect literally, and it reports malformed input
-- rather than guessing. Anything more involved (full XML, CSS, etc.) is out of
-- scope for a lyrics parser.
local M = {}

local DEFAULTS = { max_bytes = 1024 * 1024, max_depth = 64, max_nodes = 20000 }

--- Encodes a Unicode code point as UTF-8 (lyrics are not Latin-1 only).
local function utf8(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
  end
  return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
    0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

local function decode_entities(text)
  return (text
    :gsub('&#(%d+);', function(code) return utf8(tonumber(code)) end)
    :gsub('&#[xX](%x+);', function(code) return utf8(tonumber(code, 16)) end)
    :gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"')
    :gsub('&apos;', "'"):gsub('&nbsp;', ' ')
    :gsub('&amp;', '&'))
end

--- Attribute scanner: quoted values are decoded, and a bare name (no `=`) is
--- kept as an empty string, which is how TTML writes boolean extensions such as
--- `amll:obscene` or `xml:space`.
local function parse_attributes(source)
  local attributes = {}
  local position = 1
  while position <= #source do
    -- Note: `string.find` returns start, end, then the captures.
    local _, name_end, name = source:find('([%w:_%-%.]+)', position)
    if not name then break end
    local cursor = name_end + 1
    while source:sub(cursor, cursor) == ' ' do cursor = cursor + 1 end
    local separator = source:sub(cursor, cursor)
    if separator == '=' then
      cursor = cursor + 1
      while source:sub(cursor, cursor) == ' ' do cursor = cursor + 1 end
      local quote = source:sub(cursor, cursor)
      if quote == '"' or quote == "'" then
        local closing = source:find(quote, cursor + 1, true)
        if not closing then break end
        attributes[name] = decode_entities(source:sub(cursor + 1, closing - 1))
        position = closing + 1
      else
        local value = source:match('^([^%s]+)', cursor) or ''
        attributes[name] = decode_entities(value)
        position = cursor + #value
      end
    else
      attributes[name] = ''
      position = name_end + 1
    end
  end
  return attributes
end

--- Parses an XML document into `{ name, attributes, children, text }` nodes.
--- @return table|nil root, string|nil error
function M.parse(source, options)
  local settings = {}
  for key, value in pairs(DEFAULTS) do settings[key] = value end
  for key, value in pairs(options or {}) do settings[key] = value end
  if type(source) ~= 'string' then return nil, 'XML input must be a string' end
  if #source > settings.max_bytes then return nil, 'XML input exceeds the size limit' end
  if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
  if source:find('<!DOCTYPE', 1, true) or source:find('<!ENTITY', 1, true) then
    return nil, 'XML must not declare a DTD or entities'
  end

  local root = { name = '#document', attributes = {}, children = {} }
  local stack = { root }
  local position = 1
  local nodes = 0
  while position <= #source do
    local opener = source:find('<', position, true)
    if not opener then break end
    if opener > position then
      local text = decode_entities(source:sub(position, opener - 1))
      local node = stack[#stack]
      -- Text is stored as an ordered child so `<p>a<span>b</span>c</p>` keeps
      -- its document order instead of being flattened into one string.
      if node and text ~= '' then node.children[#node.children + 1] = { name = '#text', text = text } end
    end
    if source:sub(opener, opener + 3) == '<!--' then
      local closing = source:find('-->', opener + 4, true)
      if not closing then return nil, 'unterminated XML comment' end
      position = closing + 3
    elseif source:sub(opener, opener + 8) == '<![CDATA[' then
      local closing = source:find(']]>', opener + 9, true)
      if not closing then return nil, 'unterminated CDATA section' end
      local node = stack[#stack]
      local text = source:sub(opener + 9, closing - 1)
      if node and text ~= '' then node.children[#node.children + 1] = { name = '#text', text = text } end
      position = closing + 3
    elseif source:sub(opener, opener + 1) == '<?' then
      local closing = source:find('?>', opener + 2, true)
      if not closing then return nil, 'unterminated XML declaration' end
      position = closing + 2
    elseif source:sub(opener, opener + 1) == '</' then
      local closing = source:find('>', opener + 2, true)
      if not closing then return nil, 'unterminated closing tag' end
      local name = source:sub(opener + 2, closing - 1):gsub('%s+$', '')
      local node = stack[#stack]
      if #stack < 2 or not node or node.name ~= name then
        return nil, 'mismatched closing tag </' .. name .. '>'
      end
      stack[#stack] = nil
      position = closing + 1
    else
      local closing = source:find('>', opener + 1, true)
      if not closing then return nil, 'unterminated tag' end
      local body = source:sub(opener + 1, closing - 1)
      local self_closing = body:sub(-1) == '/'
      if self_closing then body = body:sub(1, -2) end
      local name, rest = body:match('^([%w:_%-%.]+)%s*(.*)$')
      if not name then return nil, 'malformed tag' end
      nodes = nodes + 1
      if nodes > settings.max_nodes then return nil, 'XML exceeds the node limit' end
      if #stack >= settings.max_depth then return nil, 'XML exceeds the nesting limit' end
      local node = { name = name, attributes = parse_attributes(rest or ''), children = {} }
      local parent = stack[#stack]
      parent.children[#parent.children + 1] = node
      if not self_closing then stack[#stack + 1] = node end
      position = closing + 1
    end
  end
  if #stack ~= 1 then return nil, 'unclosed tag <' .. tostring(stack[#stack].name) .. '>' end
  return root
end

--- Depth-first search for the first element with `name` (namespace prefix
--- included as written).
function M.find(node, name)
  for _, child in ipairs(node.children or {}) do
    if child.name == name then return child end
    local found = M.find(child, name)
    if found then return found end
  end
  return nil
end

--- Direct element children (text nodes excluded).
function M.elements(node)
  local out = {}
  for _, child in ipairs((node and node.children) or {}) do
    if child.name ~= '#text' then out[#out + 1] = child end
  end
  return out
end

--- All elements with `name`, in document order.
function M.find_all(node, name, out)
  out = out or {}
  for _, child in ipairs(node.children or {}) do
    if child.name == name then out[#out + 1] = child end
    M.find_all(child, name, out)
  end
  return out
end

--- Direct character data of a node, excluding nested elements.
function M.text(node)
  local parts = {}
  for _, child in ipairs((node and node.children) or {}) do
    if child.name == '#text' then parts[#parts + 1] = child.text end
  end
  return table.concat(parts)
end

--- All character data below a node in document order.
---
--- No artificial separators are inserted: in TTML the whitespace between word
--- spans is structural, so `<p>Hello <span>world</span></p>` must yield
--- "Hello world" from the source text node itself, while two directly adjacent
--- spans stay glued together ("don't" + "'t").
function M.deep_text(node)
  local parts = {}
  local function walk(current)
    for _, child in ipairs(current.children or {}) do
      if child.name == '#text' then parts[#parts + 1] = child.text else walk(child) end
    end
  end
  walk(node)
  return table.concat(parts)
end

return M
