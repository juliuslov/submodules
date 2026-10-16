-- Audio metadata extraction: ID3v2 (MP3/AAC), Vorbis comments (FLAC/OGG) and
-- MP4/M4A atoms.
--
-- Only the fields a music library needs are read (title, artist, album, track
-- number, duration, ISRC, embedded artwork) and every read is bounded: a header
-- region is fetched rather than a whole file, so a 40 MB FLAC does not cost 40 MB
-- of memory to index. Malformed tags degrade to "no metadata" instead of failing
-- the scan, because one broken file must not break a library.
local util = require('weiwei.util')

local M = {}

M.MAX_TAG_BYTES = 8 * 1024 * 1024

--- Reads the header region of a file (enough for tags and stream info).
function M.header(path, max_bytes)
  return util.read_file(path, max_bytes or M.MAX_TAG_BYTES)
end

--- ID3 sizes are stored as four 7-bit bytes (most significant bit unused).
local function synchsafe(values)
  local value = 0
  for index = 1, #values do value = value * 128 + values[index] end
  return value
end

--- Decodes an ID3 text frame. Handles ISO-8859-1, UTF-16 with and without BOM,
--- and UTF-8; terminator and null padding are removed.
function M.decode_id3_text(bytes)
  if type(bytes) ~= 'string' or bytes == '' then return nil end
  local encoding = bytes:byte(1)
  local body = bytes:sub(2)
  if encoding == 0 then
    return (body:gsub('%z+$', ''):gsub('\r', ' '):gsub('\n', ' '))
  elseif encoding == 1 or encoding == 2 then
    local big_endian = encoding == 2
    if body:sub(1, 2) == '\255\254' then big_endian = false; body = body:sub(3)
    elseif body:sub(1, 2) == '\254\255' then big_endian = true; body = body:sub(3) end
    local out = {}
    local index = 1
    while index <= #body - 1 do
      local first, second = body:byte(index), body:byte(index + 1)
      local code = big_endian and (first * 256 + second) or (second * 256 + first)
      if code == 0 then break end
      index = index + 2
      if code < 0x80 then
        out[#out + 1] = string.char(code)
      elseif code < 0x800 then
        out[#out + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
      else
        out[#out + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
      end
    end
    return table.concat(out)
  end
  return (body:gsub('%z+$', ''))
end

--- Parses an ID3v2.2/2.3/2.4 tag header plus frames.
--- @return table metadata (fields are nil when absent)
function M.parse_id3(data)
  local out = {}
  if type(data) ~= 'string' or #data < 10 or data:sub(1, 3) ~= 'ID3' then return out end
  local major = data:byte(4)
  local flags = data:byte(6)
  local size = synchsafe({ data:byte(7, 10) })
  if size <= 0 or size + 10 > #data then return out end
  local body = data:sub(11, 10 + size)
  if flags % 128 >= 64 then
    -- Extended header: `size` then `flags` in 2.3, a synchsafe size in 2.4.
    local skip
    if major >= 4 then
      skip = synchsafe({ body:byte(1, 4) })
    else
      local a, b, c, d = body:byte(1, 4)
      if a then
        local fields = a * 16777216 + b * 65536 + c * 256 + d
        skip = 4 + fields + 2
      end
    end
    if skip and skip > 0 and skip < #body then body = body:sub(skip + 1) end
  end
  local frame_names = {
    TIT2 = 'title', TPE1 = 'artist', TALB = 'album', TRCK = 'track', TDRC = 'year',
    TYER = 'year', TPUB = 'publisher', TCON = 'genre', TLEN = 'length', TSRC = 'isrc',
    TT2 = 'title', TP1 = 'artist', TAL = 'album', TRK = 'track', TYE = 'year',
  }
  local index = 1
  while index + 10 <= #body do
    local name = body:sub(index, index + 3)
    if name:match('^%z%z%z%z$') or name:match('^%z') then break end
    local frame_size
    if major >= 4 then
      frame_size = synchsafe({ body:byte(index + 4, index + 7) })
    else
      local a, b, c, d = body:byte(index + 4, index + 7)
      if not (a and d) then break end
      frame_size = a * 16777216 + b * 65536 + c * 256 + d
    end
    if not frame_size or frame_size <= 0 or index + 10 + frame_size - 1 > #body then break end
    -- The frame header is 10 bytes (id, size, flags), so the payload starts at
    -- `index + 10`; starting one byte later would eat the text encoding byte.
    local frame = body:sub(index + 10, index + 9 + frame_size)
    local key = frame_names[name]
    if key then
      local text = M.decode_id3_text(frame)
      if text and text ~= '' then out[key] = text end
    elseif name == 'APIC' then
      -- The picture itself is decoded on demand by the artwork renderer; the
      -- scan only records that one exists.
      out.has_artwork = true
    end
    index = index + 10 + frame_size
  end
  if out.length then
    -- TLEN is milliseconds in ID3v2.3/2.4, not seconds.
    local milliseconds = tonumber(out.length)
    if milliseconds and milliseconds > 0 then out.duration_ms = math.floor(milliseconds) end
  end
  out.tag = 'id3v2.' .. tostring(major)
  return out
end

--- Parses a FLAC metadata block chain (STREAMINFO, VORBIS_COMMENT, PICTURE).
function M.parse_flac(data)
  local out = {}
  if type(data) ~= 'string' or data:sub(1, 4) ~= 'fLaC' then return out end
  local index = 5
  while index + 4 <= #data do
    local header = data:byte(index)
    local last = header >= 128
    local kind = header % 128
    local length = 0
    local a, b, c = data:byte(index + 1, index + 3)
    if not c then break end
    length = a * 65536 + b * 256 + c
    local body = data:sub(index + 4, index + 3 + length)
    if kind == 0 and #body >= 18 then
      -- STREAMINFO tail: sample rate (20 bits), channels-1 (3 bits), bits-1
      -- (5 bits), then the 36-bit total sample count, whose top four bits share
      -- the fourth packed byte with the low bits of the sample size.
      local a, b, c, d, e, f, g, h = body:byte(11, 18)
      if h then
        local sample_rate = a * 4096 + b * 16 + math.floor(c / 16)
        local total = (d % 16) * 4294967296 + e * 16777216 + f * 65536 + g * 256 + h
        if sample_rate > 0 and total > 0 then out.duration_ms = math.floor(total / sample_rate * 1000) end
      end
    elseif kind == 4 then
      -- VORBIS_COMMENT: `uint32 vendor_length`, the vendor string, then
      -- `uint32 comment_count` and one `uint32 length` + `KEY=value` per entry,
      -- all little-endian. Reading the count from offset 1 silently parses the
      -- vendor length instead, so the vendor string has to be skipped first.
      local vendor_a, vendor_b, vendor_c, vendor_d = body:byte(1, 4)
      if vendor_d then
        local vendor_length = vendor_a + vendor_b * 256 + vendor_c * 65536 + vendor_d * 16777216
        local cursor = 5 + vendor_length
        local count_a, count_b, count_c, count_d = body:byte(cursor, cursor + 3)
        if count_d then
          local count = count_a + count_b * 256 + count_c * 65536 + count_d * 16777216
          if count > 10000 then count = 10000 end
          cursor = cursor + 4
          for _ = 1, count do
            local length_a, length_b, length_c, length_d = body:byte(cursor, cursor + 3)
            if not length_d then break end
            local length2 = length_a + length_b * 256 + length_c * 65536 + length_d * 16777216
            local pair = body:sub(cursor + 4, cursor + 3 + length2)
            local key, value = pair:match('^([^=]+)=(.*)$')
            if key then
              local lower = key:lower()
              if lower == 'title' then out.title = value
              elseif lower == 'artist' then out.artist = value
              elseif lower == 'album' then out.album = value
              elseif lower == 'tracknumber' then out.track = value:match('^%d+')
              elseif lower == 'isrc' then out.isrc = value
              elseif lower == 'date' then out.year = value:sub(1, 4) end
            end
            cursor = cursor + 4 + length2
          end
        end
      end
    elseif kind == 6 then
      out.has_artwork = true
    end
    index = index + 4 + length
    if last then break end
  end
  out.tag = 'flac'
  return out
end

--- Walks MP4 atoms to `moov.udta.meta.ilst` and reads the standard tags.
function M.parse_mp4(data)
  local out = {}
  if type(data) ~= 'string' or #data < 12 then return out end
  local function atoms(blob)
    local list, index = {}, 1
    while index + 8 <= #blob do
      local a, b, c, d = blob:byte(index, index + 3)
      if not d then break end
      local size = a * 16777216 + b * 65536 + c * 256 + d
      local name = blob:sub(index + 4, index + 7)
      if size < 8 then break end
      local body = blob:sub(index + 8, index + size - 1)
      if name == 'meta' then body = body:sub(5) end
      list[name] = body
      index = index + size
    end
    return list
  end
  local top = atoms(data)
  local ilst = top.moov and (function()
    local moov = atoms(top.moov)
    local udta = moov.udta and atoms(moov.udta)
    if not udta then return nil end
    local meta = udta.meta and atoms(udta.meta)
    return meta and meta.ilst
  end)()
  if ilst then
    local entries = atoms(ilst)
    local names = {
      ['\169nam'] = 'title', ['\169ART'] = 'artist', ['\169alb'] = 'album',
      ['\169day'] = 'year', ['\169gen'] = 'genre', aART = 'album_artist', covr = 'artwork',
    }
    for atom, body in pairs(entries) do
      local key = names[atom]
      if key == 'artwork' then
        out.has_artwork = true
      elseif key then
        -- One level of container (`data`), 8 bytes of flags then the payload.
        local inner = atoms(body)
        local payload = inner.data and inner.data:sub(9) or body:sub(9)
        local text = payload:gsub('%z+$', '')
        if text ~= '' then out[key] = text end
      end
    end
  end
  -- Duration comes from `mvhd` when the file is small enough to hold it.
  local moov = top.moov and atoms(top.moov)
  local mvhd = moov and moov.mvhd
  if mvhd and #mvhd >= 20 then
    local a, b, c, d = mvhd:byte(13, 16)
    local timescale = a * 16777216 + b * 65536 + c * 256 + d
    local e, f, g, h = mvhd:byte(17, 20)
    local duration = e * 16777216 + f * 65536 + g * 256 + h
    if timescale and timescale > 0 and duration then
      out.duration_ms = math.floor(duration / timescale * 1000)
    end
  end
  out.tag = 'mp4'
  return out
end

--- Extracts metadata from a path, choosing the parser by content.
function M.read(path)
  local data = M.header(path)
  if not data then return nil, 'cannot read ' .. tostring(path) end
  local head = data:sub(1, 4)
  local metadata
  if head:sub(1, 3) == 'ID3' then metadata = M.parse_id3(data)
  elseif head == 'fLaC' then metadata = M.parse_flac(data)
  elseif head:sub(2, 4) == 'ftyp' then metadata = M.parse_mp4(data)
  elseif head == 'OggS' then metadata = M.parse_vorbis(data)
  else metadata = {} end
  return metadata
end

--- Embedded artwork bytes, read on demand (bounded). Returns the image payload
--- and its declared media type, or nil.
function M.artwork(path, max_bytes)
  local limit = max_bytes or 4 * 1024 * 1024
  local data = M.header(path, math.min(M.MAX_TAG_BYTES, limit + 1024 * 1024))
  if not data then return nil end
  if data:sub(1, 4) == 'fLaC' then
    local picture = data:match('(\255\216.-\255\217)') or data:match('(\137PNG\r\n\026\n.-IEND.-)')
    if picture and #picture <= limit then
      return picture, picture:sub(1, 3) == '\255\216' and 'image/jpeg' or 'image/png'
    end
    return nil
  end
  if data:sub(1, 3) == 'ID3' then
    local start_at = data:find('APIC', 1, true)
    if not start_at then return nil end
    local mime_at = data:find('image/', start_at, true)
    if not mime_at then return nil end
    local mime = data:sub(mime_at, mime_at + 30):match('^(image/[%w+.%-]+)') or 'image/jpeg'
    local body = data:sub(mime_at + #mime + 2)
    local picture = body:match('(\255\216.-\255\217)') or body:match('(\137PNG\r\n\026\n.-IEND)')
    if picture and #picture <= limit then return picture, mime end
  end
  return nil
end

--- Ogg/Vorbis comment header. Layout after the magic: vendor length (4 bytes
--- little endian), vendor string, comment count, then `KEY=value` pairs, each
--- prefixed by its own length.
function M.parse_vorbis(data)
  local out = {}
  local start_at = data:find('vorbis', 1, true)
  local skip = 6
  if not start_at then start_at = data:find('OpusTags', 1, true); skip = 8 end
  if not start_at then return out end
  local cursor = start_at + skip
  local function little_endian(position)
    local a, b, c, d = data:byte(position, position + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
  end
  local vendor_length = little_endian(cursor)
  if not vendor_length then return out end
  local count = little_endian(cursor + 4 + vendor_length)
  if not count then return out end
  local body = data
  local position = cursor + 8 + vendor_length
  for _ = 1, count do
    local la, lb, lc, ld = body:byte(position, position + 3)
    if not ld then break end
    local size = la + lb * 256 + lc * 65536 + ld * 16777216
    local pair = body:sub(position + 4, position + 3 + size)
    local key, value = pair:match('^([^=]+)=(.*)$')
    if key then
      local lower = key:lower()
      if lower == 'title' then out.title = value
      elseif lower == 'artist' then out.artist = value
      elseif lower == 'album' then out.album = value
      elseif lower == 'tracknumber' then out.track = value:match('^%d+')
      elseif lower == 'isrc' then out.isrc = value end
    end
    position = position + 4 + size
  end
  out.tag = 'vorbis'
  return out
end

return M
