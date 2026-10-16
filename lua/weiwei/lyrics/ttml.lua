-- Apple Music / AMLL TTML lyrics reader.
--
-- Implements the subset Apple Music ships and that the AMLL ecosystem
-- documents (amll.dev/en/guides/lyric/ttml.html plus the amll-ttml-db format
-- specification and its "implementation behavior" notes):
--   * `itunes:timing` = `None | Line | Word`, declared on `<tt>` or in `<head>`;
--   * `<div itunes:songPart>` / `<div itunes:song-part>` grouping, and `<p>`
--     written directly under `<body>`;
--   * `<p begin end dur itunes:key="L1" ttm:agent="v1">` paragraphs;
--   * word `<span begin end>` elements, `ttm:role="x-bg"` backing vocals
--     (optional timings, with or without parentheses);
--   * `tts:ruby` annotations: the base text is the lyric, the ruby text is the
--     reading and never leaks into the line;
--   * `amll:obscene` and `amll:empty-beat` are parsed and preserved;
--   * `<ttm:agent xml:id="v1"><ttm:name type="full">` speaker names;
--   * `<iTunesMetadata><translations>/<transliterations>` sidecars linked by
--     `for="L1"`, merged with the inline `x-translation` / `x-roman` spans and
--     de-duplicated per language;
--   * `<amll:meta key="musicName" value="…">` and `<ttm:title>` metadata;
--   * whitespace is structural: an inline space between spans is a separator,
--     while a whitespace run containing a newline is file formatting and is
--     dropped;
--   * a line without word timings still gets placeholder words spread over its
--     duration, so the karaoke wipe never has to fall back to guesswork.
-- Everything outside that subset is ignored rather than guessed at, and a
-- document with no timed paragraph is reported as unusable.
local xml = require('weiwei.xml')
local util = require('weiwei.util')

local M = {}

local AUX_ROLES = {
  ['x-translation'] = 'translation',
  ['x-transliteration'] = 'romanization',
  ['x-roman'] = 'romanization',
  ['x-romanization'] = 'romanization',
}

local BG_ROLES = { ['x-bg'] = true, ['background'] = true }

--- TTML time expressions: `12.5`, `01:02.500`, `1:02:03.250`, `12.5s`, `500ms`.
function M.parse_time(value)
  if type(value) ~= 'string' or value == '' then return nil end
  local text = value:gsub('^%s+', ''):gsub('%s+$', '')
  local milliseconds = text:match('^(%d+)ms$')
  if milliseconds then return tonumber(milliseconds) end
  local seconds = text:match('^(%d+%.?%d*)s$')
  if seconds then return math.floor(tonumber(seconds) * 1000 + 0.5) end
  local hours, minutes, rest = text:match('^(%d+):(%d+):(%d+%.?%d*)$')
  if not hours then
    minutes, rest = text:match('^(%d+):(%d+%.?%d*)$')
    hours = '0'
  end
  if not minutes then
    if text:match('^%d+%.?%d*$') then return math.floor(tonumber(text) * 1000 + 0.5) end
    return nil
  end
  local total = tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(rest)
  return math.floor(total * 1000 + 0.5)
end

--- First attribute that is present, so namespaced and bare spellings both work.
local function attribute(node, ...)
  if type(node) ~= 'table' then return nil end
  for _, name in ipairs({ ... }) do
    local value = (node.attributes or {})[name]
    if value ~= nil then return value end
  end
  return nil
end

local function normalize_space(text)
  return (tostring(text or ''):gsub('%s+', ' '))
end

local function collapse(text)
  return (normalize_space(text):gsub('^ ', ''):gsub(' $', ''))
end

--- Whitespace handling for character data inside a timed element.
---
--- `nil` means "this is file formatting, drop it"; `' '` is a separator the
--- author wrote on one line; anything else is real text with runs collapsed.
local function spacing(raw)
  if type(raw) ~= 'string' or raw == '' then return nil end
  if raw:match('%S') then return normalize_space(raw) end
  if raw:find('\n', 1, true) or raw:find('\r', 1, true) then return nil end
  return ' '
end

local function role_of(node) return attribute(node, 'ttm:role', 'role') end
local function language_of(node) return attribute(node, 'xml:lang', 'lang') end
local function ruby_of(node) return attribute(node, 'tts:ruby', 'ruby') end

--- Boolean-ish extension attributes: present and not an explicit negative.
local function flag(value)
  if value == nil then return nil end
  local text = tostring(value):lower()
  if text == 'false' or text == '0' or text == 'no' or text == 'off' then return nil end
  return true
end

--- `amll:empty-beat` carries a beat count; invalid or non-finite values are
--- ignored instead of poisoning the timing maths.
local function beat(value)
  local parsed = tonumber(value)
  if parsed == nil or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then return nil end
  return parsed
end

--- Background vocals are stored without their parentheses, so the model has one
--- canonical form and the view decides how to render them.
local function strip_parentheses(text)
  return collapse((text:gsub('^[%(%（]+', ''):gsub('[%)%）]+$', '')))
end

local function empty_aux()
  return {
    line = { translation = {}, romanization = {} },
    background = { translation = {}, romanization = {} },
  }
end

local function record_aux(aux, background, kind, language, text)
  local scope = background and aux.background or aux.line
  local bucket = scope[kind]
  bucket[#bucket + 1] = { language = language or 'und', text = collapse(text) }
end

--- Collects the visible tokens of a node's children.
---
--- Tokens are `text` (untimed character data) or `word` (a timed element, a
--- ruby container, or a background block that carries its own timings).
--- Auxiliary spans never produce tokens: they are recorded in `aux` so the line
--- text, the word list and the karaoke wipe stay clean.
local function collect(node, background, aux, out)
  out = out or {}
  for _, child in ipairs(node.children or {}) do
    if child.name == '#text' then
      local text = spacing(child.text)
      if text then
        if not (text == ' ' and #out == 0) then
          out[#out + 1] = { kind = 'text', text = text, background = background }
        end
      end
    else
      local role = role_of(child)
      local auxiliary = AUX_ROLES[role]
      if auxiliary then
        record_aux(aux, background, auxiliary, language_of(child), xml.deep_text(child))
      elseif BG_ROLES[role] then
        local inner = collect(child, true, aux, {})
        for _, token in ipairs(inner) do out[#out + 1] = token end
        -- The wrapper's own `begin`/`end` are optional; when they are the only
        -- timing a background line has, they still describe a word.
        local begin_time = M.parse_time(attribute(child, 'begin'))
        local timed = false
        for _, token in ipairs(inner) do
          if token.kind == 'word' then timed = true; break end
        end
        if begin_time and not timed then
          local parts = {}
          for _, token in ipairs(inner) do parts[#parts + 1] = token.text or '' end
          local text = collapse(table.concat(parts))
          if text ~= '' then
            out[#out + 1] = {
              kind = 'word', text = text, time = begin_time,
              end_time = M.parse_time(attribute(child, 'end')),
              background = true,
              obscene = flag(attribute(child, 'amll:obscene', 'obscene')),
              empty_beat = beat(attribute(child, 'amll:empty-beat', 'empty-beat', 'emptyBeat')),
            }
          end
        end
      elseif ruby_of(child) == 'container' then
        local base, reading, first_time, last_end = {}, {}, nil, nil
        local function walk(current)
          for _, grandchild in ipairs(current.children or {}) do
            if grandchild.name == '#text' then
              local text = spacing(grandchild.text)
              -- Formatting whitespace inside a ruby container is not base text.
              if text and text ~= ' ' then base[#base + 1] = text end
            else
              local ruby = ruby_of(grandchild)
              if ruby == 'text' then
                reading[#reading + 1] = xml.deep_text(grandchild)
                local begin_time = M.parse_time(attribute(grandchild, 'begin'))
                local end_time = M.parse_time(attribute(grandchild, 'end'))
                if begin_time and (not first_time or begin_time < first_time) then first_time = begin_time end
                if end_time and (not last_end or end_time > last_end) then last_end = end_time end
              elseif ruby == 'textContainer' then
                walk(grandchild)
              else
                -- `tts:ruby="base"` must not carry timings; anything else inside
                -- the container counts as base text too.
                base[#base + 1] = xml.deep_text(grandchild)
              end
            end
          end
        end
        walk(child)
        local text = collapse(table.concat(base))
        if text ~= '' then
          out[#out + 1] = {
            kind = 'word',
            text = text,
            ruby = collapse(table.concat(reading)),
            time = first_time or M.parse_time(attribute(child, 'begin')),
            end_time = last_end or M.parse_time(attribute(child, 'end')),
            background = background,
            obscene = flag(attribute(child, 'amll:obscene', 'obscene')),
            empty_beat = beat(attribute(child, 'amll:empty-beat', 'empty-beat', 'emptyBeat')),
          }
        end
      else
        local begin_time = M.parse_time(attribute(child, 'begin'))
        if begin_time then
          local inner = collect(child, background, aux, {})
          local parts = {}
          for _, token in ipairs(inner) do
            -- Nested background vocals inside a word are a different voice.
            if token.background == background then parts[#parts + 1] = token.text or '' end
          end
          for _, token in ipairs(inner) do
            if token.background ~= background then out[#out + 1] = token end
          end
          local text = normalize_space(table.concat(parts))
          if text:match('%S') then
            out[#out + 1] = {
              kind = 'word', text = text, time = begin_time,
              end_time = M.parse_time(attribute(child, 'end')),
              background = background,
              obscene = flag(attribute(child, 'amll:obscene', 'obscene')),
              empty_beat = beat(attribute(child, 'amll:empty-beat', 'empty-beat', 'emptyBeat')),
            }
          end
        else
          -- An untimed span is a wrapper: its children keep the current scope.
          collect(child, background, aux, out)
        end
      end
    end
  end
  return out
end

--- Line text: foreground tokens only, source whitespace preserved so that
--- `<span>You </span><span>telling</span>` stays "You telling".
local function line_text(tokens)
  local parts = {}
  for _, token in ipairs(tokens) do
    if not token.background then parts[#parts + 1] = token.text or '' end
  end
  return collapse(table.concat(parts))
end

--- Background (backing vocal) text plus its words, kept separate from the line.
local function background_of(tokens)
  local parts, words = {}, {}
  for _, token in ipairs(tokens) do
    if token.background and token.text then
      parts[#parts + 1] = token.text
      if token.kind == 'word' then
        local text = strip_parentheses(token.text)
        if text ~= '' then
          words[#words + 1] = { text = text, time = token.time, end_time = token.end_time, background = true }
        end
      end
    end
  end
  local text = strip_parentheses(table.concat(parts))
  if text == '' then return nil end
  return { text = text, words = #words > 0 and words or nil }
end

--- Spreads placeholder words over a gap, proportionally to their length, so the
--- karaoke wipe advances smoothly instead of jumping from word to word.
local function distribute(words, first_index, last_index, from_time, to_time, fallback_per_character)
  local total = 0
  for index = first_index, last_index do total = total + #(words[index].text or '') end
  if total <= 0 then return end
  if not to_time or to_time <= from_time then to_time = from_time + total * fallback_per_character end
  local cursor = from_time
  for index = first_index, last_index do
    local weight = #(words[index].text or '')
    words[index].time = math.floor(cursor)
    words[index].placeholder = true
    cursor = cursor + (to_time - from_time) * (weight / total)
  end
end

--- Word list for a line.
---
--- Timed elements are words; the character data between them is split into
--- chunks and marked as placeholders, and the whole line is spread over its own
--- duration when it has no word timing at all. That mirrors AMLL, which keeps
--- placeholder words rather than dropping the line's timing.
--- @return table words, boolean word_timed
local function words_of(tokens, line_begin, line_end)
  local words = {}
  for _, token in ipairs(tokens) do
    if not token.background and token.text then
      if token.kind == 'word' then
        local text = collapse(token.text)
        if text ~= '' then
          words[#words + 1] = {
            text = text, time = token.time, end_time = token.end_time,
            ruby = token.ruby, obscene = token.obscene, empty_beat = token.empty_beat,
          }
        end
      else
        for chunk in token.text:gmatch('%S+') do
          words[#words + 1] = { text = chunk, placeholder = true }
        end
      end
    end
  end
  if #words == 0 then return nil, false end

  local word_timed = false
  for _, word in ipairs(words) do
    if word.time then word_timed = true end
  end

  local previous_anchor, previous_time = 0, line_begin
  for index, word in ipairs(words) do
    if word.time then
      if index > previous_anchor + 1 then
        distribute(words, previous_anchor + 1, index - 1, previous_time, word.time, 60)
      end
      previous_anchor, previous_time = index, word.end_time or word.time
    end
  end
  if previous_anchor < #words then
    distribute(words, previous_anchor + 1, #words, previous_time, line_end, 60)
  end
  return words, word_timed
end

--- Merge helper: inline spans win over the head sidecar, identical texts are
--- deduplicated, and a second different text for the same language is kept
--- aside instead of being silently dropped.
local function merge_language(map, types, alternates, language, text, entry_type)
  if type(text) ~= 'string' or text == '' then return end
  local current = map[language]
  if current == nil then
    map[language] = text
    if types and entry_type then types[language] = entry_type end
  elseif current ~= text then
    alternates[#alternates + 1] = { language = language, text = text, type = entry_type }
  end
end

local function first_value(map)
  if not map then return nil end
  for _, key in util.ordered_pairs(map) do
    local value = map[key]
    if type(value) == 'string' and value ~= '' then return value end
  end
  return nil
end

--- Reads one `<translation>` / `<transliteration>` block into
--- `out[key][language] = { text, background, type }`.
local function read_sidecar(container, out)
  for _, block in ipairs(container.children or {}) do
    if block.name ~= '#text' and (block.name == 'translation' or block.name == 'transliteration') then
      local language = language_of(block) or 'und'
      local entry_type = attribute(block, 'type') or 'subtitle'
      for _, text_node in ipairs(xml.find_all(block, 'text')) do
        local key = attribute(text_node, 'for')
        if key then
          local visible = xml.text(text_node)
          local background = ''
          for _, child in ipairs(xml.elements(text_node)) do
            local role = role_of(child)
            if BG_ROLES[role] then
              background = background .. (xml.deep_text(child) or '')
            elseif not AUX_ROLES[role] then
              visible = visible .. (xml.deep_text(child) or '')
            end
          end
          local bucket = out[key]
          if not bucket then bucket = {}; out[key] = bucket end
          local value = {
            text = collapse(visible),
            background = strip_parentheses(background),
            type = entry_type,
          }
          if value.background == '' then value.background = nil end
          local existing = bucket[language]
          if not existing then
            bucket[language] = value
          else
            existing.extra = existing.extra or {}
            existing.extra[#existing.extra + 1] = value
          end
        end
      end
    end
  end
end

local function sidecar_of(root)
  local out = { translations = {}, transliterations = {} }
  local metadata = xml.find(root, 'iTunesMetadata')
  if not metadata then return out end
  local translations = xml.find(metadata, 'translations')
  if translations then read_sidecar(translations, out.translations) end
  local transliterations = xml.find(metadata, 'transliterations')
  if transliterations then read_sidecar(transliterations, out.transliterations) end
  return out
end

local function agents_of(root)
  local agents = {}
  for _, agent in ipairs(xml.find_all(root, 'ttm:agent')) do
    local id = attribute(agent, 'xml:id', 'id')
    if id then
      local name = nil
      -- Only `ttm:name type="full"` is defined; anything else is a hint.
      for _, candidate in ipairs(xml.find_all(agent, 'ttm:name')) do
        local declared = attribute(candidate, 'type')
        if declared == 'full' or declared == nil then
          name = collapse(xml.deep_text(candidate))
          if declared == 'full' then break end
        end
      end
      agents[id] = {
        id = id,
        type = attribute(agent, 'type') or 'person',
        name = name ~= '' and name or nil,
      }
    end
  end
  return agents
end

--- `<amll:meta key value>` pairs plus `<ttm:title>` and the `<songwriters>`
--- sidecar, flattened for the matcher.
local function metadata_of(root)
  local values, all = {}, {}
  for _, meta in ipairs(xml.find_all(root, 'amll:meta')) do
    local key = attribute(meta, 'key')
    local value = attribute(meta, 'value')
    if key and value then
      if values[key] == nil then values[key] = value end
      all[key] = all[key] or {}
      all[key][#all[key] + 1] = value
    end
  end
  local title_node = xml.find(root, 'ttm:title')
  local title = title_node and collapse(xml.deep_text(title_node)) or nil
  if title == '' then title = nil end
  local songwriters = {}
  local block = xml.find(root, 'songwriters')
  if block then
    for _, writer in ipairs(xml.elements(block)) do
      if writer.name == 'songwriter' then
        local name = collapse(xml.deep_text(writer))
        if name ~= '' then songwriters[#songwriters + 1] = name end
      end
    end
  end
  return values, all, title, songwriters
end

--- Parses a TTML document into the unified model.
--- @param source string
--- @param options table|nil { title, artist, album, duration_ms, offset_ms, source }
--- @return table|nil model, string|nil error
function M.parse(source, options)
  options = options or {}
  local root, error_message = xml.parse(source)
  if not root then return nil, error_message end
  local tt = root.name == 'tt' and root or xml.find(root, 'tt')
  if not tt then return nil, 'not a TTML document (no <tt> element)' end
  local body = xml.find(tt, 'body')
  if not body then return nil, 'TTML document has no <body>' end
  local head = xml.find(tt, 'head')

  -- `itunes:timing` is optional and does not change how the body is read; it is
  -- kept for diagnostics. Both the root attribute and the head element appear
  -- in the wild.
  local declared = collapse(attribute(tt, 'itunes:timing', 'timing') or '')
  if declared == '' then
    local timing_node = head and xml.find(head, 'itunes:timing')
    declared = timing_node and collapse(xml.deep_text(timing_node)) or ''
  end
  if declared == '' then declared = nil end

  local amll, amll_all, ttml_title, songwriters = metadata_of(tt)
  local aux = sidecar_of(tt)
  local agents = agents_of(tt)
  local body_duration = M.parse_time(attribute(body, 'dur'))

  local lines = {}
  local word_timed = false
  local function read_paragraph(paragraph, part)
    local begin_time = M.parse_time(attribute(paragraph, 'begin'))
    if not begin_time then return end
    local end_time = M.parse_time(attribute(paragraph, 'end'))
    local duration = M.parse_time(attribute(paragraph, 'dur'))
    if not end_time and duration then end_time = begin_time + duration end

    local local_aux = empty_aux()
    local tokens = collect(paragraph, false, local_aux, {})
    local text = line_text(tokens)
    local background = background_of(tokens)
    local words, timed = words_of(tokens, begin_time, end_time)
    if timed then word_timed = true end

    -- Inline auxiliary spans first: the head sidecar is appended to them, which
    -- is what AMLL does, so the deduplication below has to tolerate both.
    local translations, translation_types, translation_alternates = {}, {}, {}
    local romanizations, romanization_alternates = {}, {}
    local inline_translation, inline_romanization
    for _, item in ipairs(local_aux.line.translation) do
      if inline_translation == nil and item.text ~= '' then inline_translation = item.text end
      merge_language(translations, translation_types, translation_alternates, item.language, item.text)
    end
    for _, item in ipairs(local_aux.line.romanization) do
      if inline_romanization == nil and item.text ~= '' then inline_romanization = item.text end
      merge_language(romanizations, nil, romanization_alternates, item.language, item.text)
    end

    local key = attribute(paragraph, 'itunes:key', 'key')
    local background_translations, background_romanizations = {}, {}
    if key then
      for language, entry in util.ordered_pairs(aux.translations[key] or {}) do
        merge_language(translations, translation_types, translation_alternates, language, entry.text, entry.type)
        if entry.background then
          merge_language(background_translations, nil, translation_alternates, language, entry.background, entry.type)
        end
      end
      for language, entry in util.ordered_pairs(aux.transliterations[key] or {}) do
        merge_language(romanizations, nil, romanization_alternates, language, entry.text, entry.type)
        if entry.background then
          merge_language(background_romanizations, nil, romanization_alternates, language, entry.background)
        end
      end
    end

    -- Background auxiliary lyrics written inline.
    for _, item in ipairs(local_aux.background.translation) do
      merge_language(background_translations, nil, translation_alternates, item.language, item.text)
    end
    for _, item in ipairs(local_aux.background.romanization) do
      merge_language(background_romanizations, nil, romanization_alternates, item.language, item.text)
    end
    if background then
      background.translations = next(background_translations) and background_translations or nil
      background.romanizations = next(background_romanizations) and background_romanizations or nil
    end

    local agent = attribute(paragraph, 'ttm:agent', 'agent')
    local obscene = flag(attribute(paragraph, 'amll:obscene', 'obscene'))
    if not obscene then
      for _, word in ipairs(words or {}) do
        if word.obscene then obscene = true; break end
      end
    end
    if obscene then
      -- `amll:obscene` on the paragraph covers every word in it.
      for _, word in ipairs(words or {}) do word.obscene = true end
    end

    local entry = {
      time = begin_time,
      end_time = end_time,
      text = text,
      part = part,
      key = key,
      agent = agent,
      agent_name = agent and agents[agent] and agents[agent].name or nil,
      words = words,
      background = background,
      translations = next(translations) and translations or nil,
      translation = inline_translation or first_value(translations),
      translation_types = next(translation_types) and translation_types or nil,
      translation_alternates = #translation_alternates > 0 and translation_alternates or nil,
      romanizations = next(romanizations) and romanizations or nil,
      romanization = inline_romanization or first_value(romanizations),
      romanization_alternates = #romanization_alternates > 0 and romanization_alternates or nil,
      obscene = obscene or nil,
      empty_beat = beat(attribute(paragraph, 'amll:empty-beat', 'empty-beat', 'emptyBeat')),
    }
    if entry.text ~= '' or entry.background or entry.empty_beat then lines[#lines + 1] = entry end
  end

  for _, div in ipairs(xml.find_all(body, 'div')) do
    local part = attribute(div, 'itunes:songPart', 'itunes:song-part', 'songPart', 'song-part')
    for _, child in ipairs(div.children or {}) do
      -- Nested divs are not part of the format; paragraphs directly under a div
      -- and paragraphs directly under the body both are.
      if child.name == 'p' then read_paragraph(child, part) end
    end
  end
  for _, child in ipairs(body.children or {}) do
    if child.name == 'p' then read_paragraph(child, nil) end
  end

  if #lines == 0 then return nil, 'TTML document contains no timed lyric lines' end
  table.sort(lines, function(left, right)
    if left.time == right.time then return (left.key or '') < (right.key or '') end
    return left.time < right.time
  end)

  local has_amll = next(amll) ~= nil
  return {
    lines = lines,
    meta = {
      title = options.title or ttml_title or amll.musicName or amll.title,
      artist = options.artist or amll.artists or amll.artist,
      album = options.album or amll.album,
      isrc = options.isrc or amll.isrc,
      duration_ms = options.duration_ms or body_duration,
      offset_ms = tonumber(options.offset_ms) or 0,
      format = 'ttml',
      timing = word_timed and 'word' or 'line',
      declared_timing = declared,
      language = attribute(tt, 'xml:lang', 'lang'),
      agents = agents,
      amll = has_amll and amll or nil,
      amll_all = has_amll and amll_all or nil,
      songwriters = #songwriters > 0 and songwriters or nil,
      body_duration_ms = body_duration,
      source = options.source,
    },
  }
end

return M
