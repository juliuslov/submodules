-- WeiWei suite: configuration, library/tag parsing, search, queue, player stub,
-- lyrics formats, provider fallbacks, the offline HTTP transport, streaming argv
-- construction and the interface builders.
--
-- Everything runs in plain Lua with a small `vim` model injected by
-- tests/run_lua.py: no Neovim, no audio device, no network and no yt-dlp.
local count = 0
local failures = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    print('not ok - ' .. name .. ': ' .. tostring(err))
  else
    count = count + 1
    print('ok ' .. count .. ' - ' .. name)
  end
end

local function fixture_directory()
  return python_mkdtemp('weiwei-test-')
end

local function write(path, content)
  local handle = assert(io.open(path, 'wb'))
  handle:write(content)
  handle:close()
  return path
end

local function read(path)
  local handle = io.open(path, 'rb')
  if not handle then return nil end
  local content = handle:read('*a')
  handle:close()
  return content
end

--- Minimal but real ID3v2.3 tag so the parser is exercised, not mocked.
local function id3v2(frames)
  local body = {}
  for name, value in pairs(frames) do
    local payload = '\0' .. value
    local size = #payload
    body[#body + 1] = name .. string.char(
      math.floor(size / 16777216) % 256, math.floor(size / 65536) % 256,
      math.floor(size / 256) % 256, size % 256) .. '\0\0' .. payload
  end
  local content = table.concat(body)
  local size = #content
  local header = 'ID3\3\0\0' .. string.char(
    math.floor(size / 2097152) % 128, math.floor(size / 16384) % 128,
    math.floor(size / 128) % 128, size % 128)
  return header .. content
end

--- FLAC with STREAMINFO + VORBIS_COMMENT, enough for the tag reader.
--- STREAMINFO is 34 bytes: block/frame sizes, then sample rate (20 bits),
--- channels (3), bits per sample (5), total samples (36) and an MD5.
--- Vorbis comments are little-endian: a 4-byte vendor length, the vendor, a
--- 4-byte comment count, then one 4-byte length + `KEY=value` per entry.
local function little_endian(value)
  return string.char(value % 256, math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function flac(tags, seconds)
  local comments = { 'TITLE=' .. tags.title, 'ARTIST=' .. tags.artist, 'ALBUM=' .. tags.album }
  local vendor = 'weiwei-test'
  local body = little_endian(#vendor) .. vendor .. little_endian(#comments)
  for _, comment in ipairs(comments) do
    body = body .. little_endian(#comment) .. comment
  end
  local block = string.char(0x80 + 4, math.floor(#body / 65536) % 256, math.floor(#body / 256) % 256, #body % 256) .. body
  local sample_rate, channels, bits = 44100, 2, 16
  local total = sample_rate * seconds
  local packed = string.char(
    math.floor(sample_rate / 4096) % 256,
    math.floor(sample_rate / 16) % 256,
    (sample_rate % 16) * 16 + (channels - 1) * 2 + math.floor((bits - 1) / 16) % 2,
    ((bits - 1) % 16) * 16 + math.floor(total / 2 ^ 32) % 16,
    math.floor(total / 16777216) % 256,
    math.floor(total / 65536) % 256,
    math.floor(total / 256) % 256,
    total % 256)
  local zero = string.char(0)
  local streaminfo = string.rep(zero, 10) .. packed .. string.rep(zero, 16)
  local header = string.char(0, math.floor(#streaminfo / 65536) % 256, math.floor(#streaminfo / 256) % 256, #streaminfo % 256)
  return 'fLaC' .. header .. streaminfo .. block
end

--- HTTP transport stubbed with scripted responses, so no network is touched.
local function scripted_http(routes)
  local http = require('weiwei.lyrics.http')
  local calls = {}
  http.set_runner(function(argv, options, callback)
    local url = argv[#argv]
    calls[#calls + 1] = url
    for index, route in ipairs(routes) do
      local matches = url:find(route.pattern, 1, true)
      if matches then
        routes[index].hits = (routes[index].hits or 0) + 1
        return callback({ code = route.code or 0, stdout = (route.body or '') .. '\n' .. tostring(route.status or 200), stderr = route.stderr or '' })
      end
    end
    callback({ code = 0, stdout = '\n404', stderr = '' })
  end)
  http.set_sleeper(function() end)
  return calls
end

local function fresh_weiwei(options)
  package.loaded['weiwei'] = nil
  for name in pairs(package.loaded) do
    if tostring(name):match('^weiwei%.') then package.loaded[name] = nil end
  end
  local weiwei = require('weiwei')
  local config = assert(weiwei.setup(options or {}))
  return weiwei, config
end

-- ------------------------------------------------------------------ config --

test('configuration rejects unknown keys and invalid values, and deep-merges', function()
  local config = require('weiwei.config')
  local resolved, err = config.resolve({ ui = { theme = 'nope' } })
  assert(err and err:find('ui.theme'), 'invalid theme accepted')
  local _, unknown = config.resolve({ nonsense = true })
  assert(unknown and unknown:find('unknown option nonsense'), 'unknown option accepted')
  local _, nested = config.resolve({ lyrics = { match = { nonsense = 1 } } })
  assert(nested and nested:find('lyrics.match.nonsense'), 'nested unknown option accepted')
  local merged = assert(config.resolve({ library = { directories = { '/music' } }, ui = { theme = 'light' } }))
  assert(merged.ui.theme == 'light')
  assert(merged.ui.border == 'rounded', 'defaults were dropped by the merge')
  assert(merged.library.directories[1] == '/music')
  assert(config.get(merged, 'ui.window.width') == 0.82)
  assert(config.set(merged, 'ui.window.width', 0.9) and config.get(merged, 'ui.window.width') == 0.9)
  -- Termux options: tri-state, validated, and nil still means "auto-detect".
  assert(merged.termux.wake_lock == 'auto' and merged.termux.notification == 'auto')
  assert(merged.termux.library_directories == nil, 'auto-detection must survive the merge')
  local _, bad_wake = config.resolve({ termux = { wake_lock = 'sometimes' } })
  assert(bad_wake and bad_wake:find('termux.wake_lock'), 'invalid wake lock mode accepted')
  local _, bad_notification = config.resolve({ termux = { notification = 'yes' } })
  assert(bad_notification and bad_notification:find('termux.notification'), 'invalid notification mode accepted')
  local _, bad_directories = config.resolve({ termux = { library_directories = { '/music', 3 } } })
  assert(bad_directories and bad_directories:find('termux.library_directories'), 'non-string directory accepted')
  local explicit = assert(config.resolve({ termux = { library_directories = {} } }))
  assert(type(explicit.termux.library_directories) == 'table' and #explicit.termux.library_directories == 0)
end)

test('theme builds Apple Music-inspired highlights for both modes', function()
  local theme = require('weiwei.theme')
  local config = assert(require('weiwei.config').resolve({}))
  local dark = theme.palette(config, 'dark')
  assert(dark.accent == '#fa2d48', 'system red accent expected: ' .. tostring(dark.accent))
  local light = theme.palette(config, 'light')
  assert(light.text ~= dark.text, 'light and dark must differ')
  local custom = theme.palette(assert(require('weiwei.config').resolve({ ui = { accent = '#00b0ff' } })), 'dark')
  assert(custom.accent == '#00b0ff', 'accent override ignored')
  local applied = theme.apply(config)
  assert(applied.groups.WeiweiLyricWord.bold == true)
  assert(#theme.group_names() > 15, 'expected a full group set')
end)

-- ----------------------------------------------------------------- library --

test('ID3v2 tags are read from a real header', function()
  local directory = fixture_directory()
  local path = directory .. '/song.mp3'
  write(path, id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Ca sĩ', TALB = 'Album Một', TRCK = '3', TLEN = '215000' }))
  local tags = require('weiwei.library.tags')
  local metadata = tags.read(path)
  assert(metadata.title == 'Đèn Biển', 'title: ' .. tostring(metadata.title))
  assert(metadata.artist == 'Ca sĩ')
  assert(metadata.album == 'Album Một')
  assert(metadata.track == '3')
  assert(metadata.duration_ms == 215000, 'duration: ' .. tostring(metadata.duration_ms))
  assert(metadata.tag == 'id3v2.3')
end)

test('FLAC stream info and Vorbis comments are read', function()
  local directory = fixture_directory()
  local path = directory .. '/track.flac'
  write(path, flac({ title = 'Lantern', artist = 'Mira', album = 'Harbour' }, 137))
  local metadata = require('weiwei.library.tags').read(path)
  assert(metadata.title == 'Lantern', 'title: ' .. tostring(metadata.title))
  assert(metadata.artist == 'Mira')
  assert(metadata.album == 'Harbour')
  assert(math.abs(metadata.duration_ms - 137000) <= 1000, 'duration: ' .. tostring(metadata.duration_ms))
  assert(metadata.tag == 'flac')
end)

test('file names supply metadata when tags are missing', function()
  local library = require('weiwei.library')
  local metadata = { title = 'Track 07' }
  local track = library.track_of('/music/01 - Ca sĩ - Đèn Biển.mp3', metadata)
  assert(track.title == 'Đèn Biển', 'title: ' .. tostring(track.title))
  assert(track.artist == 'Ca sĩ')
  assert(track.track == 1)
  local plain = library.track_of('/music/Lantern Keeper.mp3', {})
  assert(plain.title == 'Lantern Keeper')
end)

test('the library scans directories, skips other files and stays bounded', function()
  local directory = fixture_directory()
  write(directory .. '/one.mp3', id3v2({ TIT2 = 'One', TPE1 = 'Artist A' }))
  write(directory .. '/two.flac', flac({ title = 'Two', artist = 'Artist B', album = 'Albums' }, 60))
  write(directory .. '/notes.pdf', 'not audio')
  python_mkdir(directory .. '/nested')
  write(directory .. '/nested/three.mp3', id3v2({ TIT2 = 'Three', TPE1 = 'Artist C' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } } })
  local stats = weiwei.library.stats()
  -- Music libraries nest (Artist/Album/track), so the scan descends; the PDF is
  -- skipped because its extension is not an audio one.
  assert(stats.tracks == 3, 'expected 3 tracks, found ' .. tostring(stats.tracks))
  local tracks = weiwei.library.tracks()
  local titles = {}
  for _, track in ipairs(tracks) do titles[#titles + 1] = track.title end
  table.sort(titles)
  assert(table.concat(titles, ',') == 'One,Three,Two', table.concat(titles, ','))
  -- the bounded scan honours max_files
  local bounded = require('weiwei.library').scan(assert(require('weiwei.config').resolve({
    library = { directories = { directory }, max_files = 1 } })))
  assert(#bounded.tracks == 1, 'max_files ignored')
  assert(bounded.stats.truncated, 'truncation was not reported')
end)

test('library search answers title, artist, album and combined queries', function()
  local directory = fixture_directory()
  write(directory .. '/a.mp3', id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Hà Anh', TALB = 'Nha Trang' }))
  write(directory .. '/b.mp3', id3v2({ TIT2 = 'Harbour Lights', TPE1 = 'Mira', TALB = 'Nha Trang' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } } })
  local library = require('weiwei.library')
  local by_title = library.search('harbour lights')
  assert(#by_title >= 1 and by_title[1].track.title == 'Harbour Lights', 'title search failed')
  local by_artist = library.search('mira')
  assert(#by_artist >= 1 and by_artist[1].track.artist == 'Mira', 'artist search failed')
  local by_album = library.search('nha trang')
  assert(#by_album == 2, 'album search found ' .. #by_album)
  local combined = library.search({ title = 'Đèn Biển', artist = 'Hà Anh' })
  assert(#combined >= 1 and combined[1].reason == 'title+artist', 'combined search failed')
  assert(weiwei.library.facets().artists[1].name ~= nil)
end)

-- ------------------------------------------------------------------- queue --

test('queue order, repeat, shuffle and history behave', function()
  local queue = require('weiwei.queue')
  local value = queue.new()
  local tracks = {}
  for index = 1, 3 do
    tracks[index] = { id = 'id' .. index, title = 'Track ' .. index, duration_ms = 60000 }
  end
  assert(queue.append(value, tracks) == 3, 'append failed')
  assert(queue.append(value, { tracks[1] }) == 0, 'duplicates were appended')
  assert(queue.append(value, { tracks[1] }, true) == 1, 'allow_duplicates ignored')
  assert(#value.items == 4)
  value.index = 1
  assert(queue.advance(value).title == 'Track 2')
  assert(queue.advance(value).title == 'Track 3')
  assert(queue.advance(value, { forward = false }).title == 'Track 2', 'history navigation failed')
  value.repeat_mode = 'all'
  value.index = #value.items
  assert(queue.advance(value).title == 'Track 1', 'repeat all should wrap')
  value.repeat_mode = 'one'
  local current = value.items[value.index]
  assert(queue.advance(value) == current, 'repeat one should stay')
  value.repeat_mode = 'off'
  -- shuffle keeps every track exactly once
  queue.set_shuffle(value, true, function() return 0.5 end)
  local seen = {}
  for _, index in ipairs(value.shuffle_order) do seen[index] = (seen[index] or 0) + 1 end
  for index = 1, #value.items do assert(seen[index] == 1, 'shuffle lost a track') end
  queue.set_shuffle(value, false)
  assert(queue.move(value, 1, 3) and value.items[3].title == 'Track 1', 'reorder failed')
  assert(queue.remove(value, 1))
  local current_index = value.index
  local moved = queue.play_next(value, { id = 'next', title = 'Next' })
  assert(moved == current_index + 1, 'play-next must follow the current track, got ' .. tostring(moved))
  assert(value.items[moved].title == 'Next', 'play-next inserted the wrong item')
  assert(queue.duration(value) > 0)
end)

-- ------------------------------------------------------------------ player --

test('the stub player drives the whole playback state machine', function()
  local weiwei = fresh_weiwei({ player = { backend = 'stub' } })
  local directory = fixture_directory()
  write(directory .. '/one.mp3', id3v2({ TIT2 = 'One', TPE1 = 'Artist', TLEN = '3000' }))
  local track = require('weiwei.library').add(directory .. '/one.mp3')
  assert(weiwei.play_track(track))
  local player = weiwei.player
  assert(player.backend == 'stub')
  assert(player.status == 'playing', 'status: ' .. player.status)
  assert(player.duration_ms == 3000, 'duration: ' .. tostring(player.duration_ms))
  player.advance(1000)
  assert(player.position_ms == 1000, 'position: ' .. tostring(player.position_ms))
  assert(math.abs(player.percent() - 1 / 3) < 0.01)
  player.pause()
  assert(player.status == 'paused')
  local before = player.position_ms
  player.advance(500)
  assert(player.position_ms == before, 'a paused player must not advance')
  player.play()
  assert(player.seek(2500) == 2500)
  assert(player.seek_relative(1000) == 3000, 'seeking past the end must clamp')
  assert(player.set_volume(35) == 35)
  assert(require('weiwei.state').get().player.volume == 35)
  assert(player.adjust_volume(100) == 100, 'volume must clamp at 100')
  -- The player reports the end of the track; the plugin then decides what
  -- happens next (here: nothing left to play, so it stops).
  local events = {}
  local forward = player.on_event
  player.on_event = function(event, payload)
    events[#events + 1] = event
    if forward then forward(event, payload) end
  end
  player.advance(1000)
  local saw_ended = false
  for _, event in ipairs(events) do
    if event == 'ended' then saw_ended = true end
  end
  assert(saw_ended, 'end of track not emitted: ' .. table.concat(events, ','))
  assert(player.status == 'stopped', 'an empty queue should stop the player: ' .. player.status)
end)

-- ------------------------------------------------------------------ lyrics --

test('LRC parsing covers line and word timings, offsets and metadata tags', function()
  local format = require('weiwei.lyrics.format')
  local model = assert(format.parse('[ar:Ca sĩ]\n[offset:-500]\n[00:12.34]First line\n[00:15.00]<00:15.00>Hello <00:15.60>world\n'))
  assert(model.meta.artist == 'Ca sĩ')
  assert(model.meta.file_offset_ms == -500, 'offset tag not recorded')
  assert(model.meta.timing == 'word')
  assert(model.lines[1].time == 11840, 'file offset not applied: ' .. tostring(model.lines[1].time))
  local words = model.lines[2].words
  assert(#words == 2 and words[2].text == 'world', 'word timings wrong')
  assert(words[2].time == 15100, 'word offset wrong: ' .. tostring(words[2].time))
end)

test('Apple TTML is parsed: words, background vocals, agents, translations', function()
  local format = require('weiwei.lyrics.format')
  local document = [[<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
   xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions">
  <head><itunes:timing>Word</itunes:timing></head>
  <body><div itunes:song-part="Verse 1">
  <p begin="00:12.500" end="00:16.000" itunes:key="L1" ttm:agent="v1">Hello <span begin="00:12.500" end="00:13.400">world</span><span begin="00:13.400" end="00:14.000">,</span> again</p>
  <p begin="00:16.000" end="00:19.000" itunes:key="L2"><span ttm:role="x-bg"><span begin="00:16.000" end="00:17.000">oh</span></span>Lead line</p>
  </div>
  <div itunes:song-part="Chorus"><p begin="00:19.000" end="00:22.000" itunes:key="L3">Chorus line</p></div>
  </body>
  <iTunesMetadata><translations><translation xml:lang="vi"><text for="L1">Xin chào</text></translation></translations></iTunesMetadata>
  <ttm:agent xml:id="v1" type="person"><ttm:name type="full">Singer</ttm:name></ttm:agent>
  </tt>]]
  local model = assert(format.parse(document))
  assert(model.meta.format == 'ttml')
  assert(model.meta.declared_timing == 'Word', 'timing header: ' .. tostring(model.meta.declared_timing))
  assert(model.meta.timing == 'word')
  assert(#model.lines == 3, 'expected 3 lines, got ' .. #model.lines)
  local first = model.lines[1]
  assert(first.text == 'Hello world, again', 'line text: ' .. first.text)
  assert(first.part == 'Verse 1')
  assert(#first.words == 4, 'expected 4 words, got ' .. tostring(#first.words))
  assert(first.words[3].text == ',')
  assert(first.translations.vi == 'Xin chào', 'translation missing')
  local second = model.lines[2]
  assert(second.text == 'Lead line', 'background vocals leaked into the line: ' .. second.text)
  assert(second.background.text == 'oh')
end)


test('AMLL TTML extensions stay intact: ruby, obscene, empty beat, sidecar lyrics', function()
  local format = require('weiwei.lyrics.format')
  local document = [[<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
    xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
    xmlns:amll="http://www.example.com/ns/amll" xml:lang="ja" itunes:timing="Word">
  <head>
    <metadata>
      <ttm:title>Song Title</ttm:title>
      <ttm:agent type="person" xml:id="v1"><ttm:name type="full">Singer A</ttm:name></ttm:agent>
      <amll:meta key="musicName" value="Song Title" />
      <amll:meta key="artists" value="Singer A" />
      <amll:meta key="album" value="Album Name" />
      <amll:meta key="isrc" value="XX0000000000" />
      <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
        <translations>
          <translation type="subtitle" xml:lang="zh-Hans"><text for="L1">第一行</text></translation>
        </translations>
        <transliterations>
          <transliteration xml:lang="ja-Latn"><text for="L1">dai ichi gyou</text></transliteration>
        </transliterations>
        <songwriters><songwriter>Lin-Manuel Miranda</songwriter></songwriters>
      </iTunesMetadata>
    </metadata>
  </head>
  <body dur="00:30.000">
    <div itunes:songPart="Verse">
      <p begin="1.000" end="4.000" itunes:key="L1" ttm:agent="v1">
        <span begin="1.000" end="1.500">こん</span>
        <span begin="1.500" end="2.000">にちは</span>
        <span tts:ruby="container">
          <span tts:ruby="base">所詮</span>
          <span tts:ruby="textContainer">
            <span tts:ruby="text" begin="2.000" end="2.400">しょ</span>
            <span tts:ruby="text" begin="2.400" end="2.900">せん</span>
          </span>
        </span>
        <span begin="2.900" end="3.400">だ</span>
        <span ttm:role="x-bg"><span begin="3.000" end="3.600">(oh oh)</span></span>
        <span ttm:role="x-translation" xml:lang="en">Hello</span>
        <span ttm:role="x-roman">konnichiwa</span>
      </p>
      <p begin="4.000" end="6.000" itunes:key="L2" amll:obscene="true">
        <span begin="4.000" end="5.000">f***</span>
      </p>
      <p begin="6.000" end="8.000" itunes:key="L3" amll:empty-beat="2" />
      <p begin="8.000" end="10.000" itunes:key="L4">whole line only</p>
    </div>
  </body>
</tt>]]
  local model = assert(format.parse(document))
  -- Metadata: `amll:meta` and `ttm:title` feed the model, and the root declares
  -- the timing mode just as `<head>` does.
  assert(model.meta.declared_timing == 'Word', 'root itunes:timing ignored')
  assert(model.meta.title == 'Song Title', 'ttm:title ignored')
  assert(model.meta.artist == 'Singer A', 'amll:meta artists ignored')
  assert(model.meta.album == 'Album Name')
  assert(model.meta.isrc == 'XX0000000000')
  assert(model.meta.amll.musicName == 'Song Title')
  assert(model.meta.songwriters[1] == 'Lin-Manuel Miranda')
  assert(model.meta.body_duration_ms == 30000, 'body dur ignored')
  assert(model.meta.agents.v1.name == 'Singer A')

  local first = model.lines[1]
  -- Ruby: the base text is a lyric word, the reading never leaks into the line.
  assert(first.text == 'こんにちは所詮だ', 'ruby text leaked into the line: ' .. first.text)
  assert(#first.words == 4, 'expected 4 words, got ' .. tostring(#first.words))
  assert(first.words[3].text == '所詮' and first.words[3].time == 2000)
  assert(first.words[3].ruby == 'しょせん', 'ruby reading lost: ' .. tostring(first.words[3].ruby))
  assert(first.words[3].end_time == 2900)
  -- Background vocals stay separate and keep one canonical (unparenthesised) form.
  assert(first.background.text == 'oh oh', 'background text: ' .. tostring(first.background.text))
  assert(first.background.words[1].text == 'oh oh')
  -- Sidecar plus inline auxiliary lyrics, merged per language.
  assert(first.translations['zh-Hans'] == '第一行', 'sidecar translation lost')
  assert(first.translation_types['zh-Hans'] == 'subtitle')
  assert(first.translations.en == 'Hello', 'inline translation lost')
  assert(first.translation == 'Hello', 'the inline translation should be the primary one')
  assert(first.romanizations['ja-Latn'] == 'dai ichi gyou', 'sidecar transliteration lost')
  assert(first.romanization == 'konnichiwa', 'inline romanization lost')
  assert(first.part == 'Verse', 'itunes:songPart alias not accepted')
  assert(first.agent_name == 'Singer A')

  -- `amll:obscene` on the paragraph covers its words, and survives the model.
  local second = model.lines[2]
  assert(second.obscene == true, 'amll:obscene lost')
  assert(second.words[1].obscene == true, 'amll:obscene not propagated to words')

  -- `amll:empty-beat` keeps an instrumental bar as a real timed line.
  local third = model.lines[3]
  assert(third.empty_beat == 2, 'amll:empty-beat lost')
  assert(third.text == '' and third.time == 6000 and third.end_time == 8000)

  -- A line with only line timing still gets placeholder words spread over it, so
  -- the wipe has something to work with (AMLL behaviour).
  local fourth = model.lines[4]
  assert(fourth.text == 'whole line only')
  assert(#fourth.words == 3, 'placeholder words missing: ' .. tostring(#fourth.words))
  assert(fourth.words[1].placeholder == true)
  assert(fourth.words[1].time >= 8000 and fourth.words[3].time < 10000)
  assert(model.meta.timing == 'word', 'the document has real word timing')
end)

test('AMLL TTML whitespace, bare attributes, sidecar merge and de-duplication', function()
  local format = require('weiwei.lyrics.format')
  -- Formatting whitespace (a run containing a newline) is dropped; an inline
  -- space between two spans is a separator that must be kept.
  local formatted = assert(format.parse([[
  <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
    <body><div>
      <p begin="0" end="2" itunes:key="L1">
        <span begin="0" end="0.5">You </span>
        <span begin="0.5" end="1">telling </span>
        <span ttm:role="x-bg"><span begin="1" end="1.5">(oh)</span></span>
      </p>
      <p begin="2" end="3"><span begin="2" end="2.4">a</span> <span begin="2.4" end="3">b</span></p>
    </div></body>
  </tt>]]))
  assert(formatted.meta.declared_timing == nil, 'timing must stay optional')
  local line = formatted.lines[1]
  assert(line.text == 'You telling', 'formatted whitespace mishandled: ' .. line.text)
  assert(line.background.text == 'oh', 'single-pair parentheses not normalised')
  assert(formatted.lines[2].text == 'a b', 'inline separator lost: ' .. formatted.lines[2].text)
  assert(formatted.lines[2].time == 2000 and formatted.lines[2].end_time == 3000)
  assert(formatted.lines[2].words[1].time == 2000 and formatted.lines[2].words[2].time == 2400)

  -- A sidecar entry that repeats an inline translation collapses; a second text
  -- for the same language is kept as an alternate instead of being dropped, and
  -- bare (valueless) extension attributes read as booleans.
  local merged = assert(format.parse([[
  <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll">
    <head><metadata><iTunesMetadata>
      <translations>
        <translation xml:lang="vi"><text for="L1">Xin chao</text></translation>
        <translation xml:lang="en"><text for="L1">First line</text></translation>
      </translations>
    </iTunesMetadata></metadata></head>
    <body><div>
      <p begin="0" end="2" itunes:key="L1" amll:obscene>
        <span begin="0" end="1">words</span>
        <span ttm:role="x-translation" xml:lang="vi">Xin chao</span>
      </p>
      <p begin="2" end="4" itunes:key="L2">
        <span begin="2" end="3">&#31532;&#20108;&#34892;</span>
        <span ttm:role="x-translation" xml:lang="en">Second line</span>
      </p>
    </div></body>
  </tt>]]))
  local first = merged.lines[1]
  assert(first.obscene == true, 'bare amll:obscene attribute ignored')
  assert(first.translations.vi == 'Xin chao', 'the duplicate sidecar entry should collapse')
  assert(first.translation_alternates == nil, 'identical texts must not be duplicated')
  assert(merged.lines[1].translations.en == 'First line', 'sidecar language lost')
  -- Numeric character references decode as UTF-8.
  assert(merged.lines[2].text == '第二行', 'numeric character reference: ' .. merged.lines[2].text)
  assert(merged.lines[2].translation == 'Second line')
  assert(first.words[1].time == 0 and first.words[1].end_time == 1000)
end)

test('the lyrics pane shows ruby readings, empty beats and translations', function()
  local format = require('weiwei.lyrics.format')
  local ui = require('weiwei.ui.format')
  local model = assert(format.parse([[
  <tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:tts="http://www.w3.org/ns/ttml#styling">
    <body><div>
      <p begin="0" end="2" itunes:key="L1">
        <span tts:ruby="container">
          <span tts:ruby="base">所詮</span>
          <span tts:ruby="textContainer"><span tts:ruby="text" begin="0" end="1">しょせん</span></span>
        </span>
        <span ttm:role="x-translation">after all</span>
        <span ttm:role="x-bg"><span begin="1" end="1.5">(oh)</span></span>
      </p>
      <p begin="2" end="3" itunes:key="L2" amll:empty-beat="4" />
      <p begin="3" end="5" itunes:key="L3">next line</p>
    </div></body>
  </tt>]]))
  local rows = ui.lyrics_pane(model, 1500, { width = 40, count = 3 })
  local active = rows[1]
  local joined = {}
  for _, segment in ipairs(active.segments) do joined[#joined + 1] = segment.text end
  assert(table.concat(joined) == '所詮', 'active line render: ' .. table.concat(joined))
  local function trimmed(text) return (text:gsub('%s+$', '')) end
  assert(trimmed(rows[2].text) == 'しょせん' and rows[2].reading == true, 'the ruby reading must sit under the line')
  assert(trimmed(rows[3].text) == '(oh)' and rows[3].background == true, 'backing vocals need their own row: ' .. rows[3].text)
  assert(rows[4].text:match('♪'), 'empty beat marker missing: ' .. rows[4].text)
  assert(active.translation == 'after all', 'translation lost by the pane')
end)

test('TTML with broken markup is refused instead of guessed', function()
  local format = require('weiwei.lyrics.format')
  local model, err = format.parse('<tt><body><div><p begin="1.0">line</div></body></tt>')
  assert(model == nil and err, 'malformed TTML accepted')
  local dtd = format.parse('<tt><!DOCTYPE tt [<!ENTITY x "y">]><body/></tt>')
  assert(dtd == nil, 'a DTD must be refused')
end)

test('the timeline model normalizes timings and drives the karaoke wipe', function()
  local format = require('weiwei.lyrics.format')
  local model = require('weiwei.lyrics.model')
  local parsed = assert(format.parse('[00:10.00]one\n[00:12.00]two\n[00:14.00]<00:14.00>three <00:15.00>four\n'))
  assert(parsed.lines[1].end_time == 12000, 'end time not derived from the next line')
  local progress = model.progress(parsed, 12300)
  assert(progress.index == 2, 'active line: ' .. tostring(progress.index))
  assert(progress.line_fraction > 0 and progress.line_fraction < 1)
  local third = parsed.lines[3]
  assert(third.words[1].end_time == 15000, 'a word ends where the next one starts')
  assert(third.words[2].end_time == 18000, 'the last word takes the line tail: ' .. tostring(third.words[2].end_time))
  local early = model.segments(third, 14700)
  assert(early[1].state == 'active' and early[2].state == 'upcoming', 'word wipe start is wrong')
  assert(math.abs(early[1].fraction - 0.7) < 0.01, 'word fraction: ' .. tostring(early[1].fraction))
  local segments = model.segments(third, 15700)
  assert(segments[1].state == 'done' and segments[2].state == 'active', 'word wipe states wrong')
  assert(segments[2].fraction > 0.2 and segments[2].fraction < 0.3, 'word fraction: ' .. tostring(segments[2].fraction))
  local shifted = model.offset(parsed, -2000)
  assert(shifted.lines[1].time == 8000 and shifted.meta.offset_ms == -2000)
  assert(parsed.lines[1].time == 10000, 'offset must not mutate the input model')
  assert(model.to_text(parsed):find('one', 1, true))
  assert(model.duration(parsed) > 14000)
end)

test('the local provider wins and the agent caches its result', function()
  local directory = fixture_directory()
  write(directory .. '/song.mp3', id3v2({ TIT2 = 'Lantern', TPE1 = 'Mira', TLEN = '180000' }))
  write(directory .. '/song.lrc', '[00:01.00]local line one\n[00:03.00]local line two\n')
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, lyrics = { providers = { 'local' } } })
  local agent = require('weiwei.lyrics.agent')
  local track = require('weiwei.library').add(directory .. '/song.mp3')
  local result, error_message
  agent.run(track, function(err, data) result, error_message = data, err end, { config = weiwei.config })
  assert(result, 'no result from the local provider: ' .. tostring(error_message))
  assert(result.provider == 'local')
  assert(result.model.meta.timing == 'line')
  assert(result.model.lines[1].text == 'local line one')
  local cached
  agent.run(track, function(err, data) cached = data or { error = err } end, { config = weiwei.config })
  assert(cached.cached == true, 'the second lookup was not served from the cache')
  assert(cached.model.lines[1].text == 'local line one')
end)

test('LRCLIB is queried with a user agent, matched and cached, with fallback', function()
  local directory = fixture_directory()
  write(directory .. '/track.mp3', id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Ca sĩ', TLEN = '215000' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, lyrics = { providers = { 'local', 'lrclib' } } })
  local calls = scripted_http({
    { pattern = '/api/get?', body = '{"id":42,"trackName":"Đèn Biển","artistName":"Ca sĩ","duration":215.4,'
      .. '"syncedLyrics":"[00:01.00]from lrclib\\n[00:04.00]second line\\n","hasWordSync":false}' },
  })
  local agent = require('weiwei.lyrics.agent')
  local track = require('weiwei.library').add(directory .. '/track.mp3')
  local result
  agent.run(track, function(err, data) result = data or { error = err } end, { config = weiwei.config })
  assert(not result.error, 'lookup failed: ' .. tostring(result.error))
  assert(result.provider == 'lrclib', 'provider: ' .. tostring(result.provider))
  assert(result.model.lines[1].text == 'from lrclib')
  assert(#calls == 1, 'expected one request, got ' .. #calls)
  assert(calls[1]:find('track_name=', 1, true), 'track name not in the URL')
  assert(calls[1]:find('duration=215', 1, true), 'duration not in the URL')

  -- A 404 on /api/get falls back to /api/search, where the best match wins.
  require('weiwei.cache').clear()
  scripted_http({
    { pattern = '/api/search?', body = '[{"id":7,"trackName":"Đèn Biển","artistName":"Ca sĩ","duration":215,'
      .. '"plainLyrics":"plain only"}]' },
  })
  local fallback
  agent.run(track, function(err, data) fallback = data or { error = err } end, { config = weiwei.config, force = true })
  assert(fallback.model, 'search fallback failed: ' .. tostring(fallback.error))
  assert(fallback.provider == 'lrclib')
  -- The search hit only has plain text: it is returned as a degraded answer that
  -- the view can show without a wipe, not as a hard failure.
  assert(fallback.plain == true and fallback.model.meta.timing == 'none', 'plain fallback not flagged')
  assert(fallback.model.meta.plain_fallback == true)
  assert(fallback.warnings[1]:find('unsynchronised', 1, true))
  assert(fallback.model.lines[1].text == 'plain only')
end)

test('provider failures fall through to the next provider and are reported', function()
  local directory = fixture_directory()
  write(directory .. '/track.mp3', id3v2({ TIT2 = 'Unknown Song', TPE1 = 'Nobody', TLEN = '100000' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, lyrics = { providers = { 'local', 'lrclib' } } })
  scripted_http({ { pattern = '/api/', status = 500, body = '{"message":"boom"}' } })
  local agent = require('weiwei.lyrics.agent')
  local track = require('weiwei.library').add(directory .. '/track.mp3')
  local result, error_message
  agent.run(track, function(err, data) result, error_message = data, err end, { config = weiwei.config, force = true })
  assert(result == nil and error_message, 'a total failure must be reported')
  assert(error_message:find('local', 1, true), 'the first provider should appear in the report: ' .. error_message)
  assert(error_message:find('lrclib', 1, true), 'the second provider should appear in the report: ' .. error_message)
  local described = agent.describe(weiwei.config)
  assert(#described == 2 and described[1].name == 'local' and described[1].offline == true)
end)

test('the matching scorer prefers the right recording and rejects others', function()
  local matcher = require('weiwei.lyrics.matcher')
  local query = { title = 'Đèn Biển', artist = 'Ca sĩ', album = 'Album', duration_ms = 215000 }
  local good = matcher.score(query, { track_name = 'Đèn Biển', artist_name = 'Ca sĩ', album_name = 'Album', duration = 215 }, { minimum_score = 0.45 })
  local wrong_artist = matcher.score(query, { track_name = 'Đèn Biển', artist_name = 'Another Band', duration = 215 }, { minimum_score = 0.45 })
  local live = matcher.score(query, { track_name = 'Đèn Biển (Live)', artist_name = 'Ca sĩ', duration = 420 }, { minimum_score = 0.45 })
  assert(good.accepted and good.score > 0.95, 'exact match scored ' .. tostring(good.score))
  assert(good.score > wrong_artist.score, 'artist mismatch should lower the score')
  assert(not live.accepted, 'a live version with the wrong duration must be rejected')
  assert(live.reasons[1] == 'duration differs too much' or #live.reasons > 0)
  local normalized = matcher.similarity('Đèn Biển', 'den bien')
  assert(normalized > 0.9, 'diacritics should not prevent a match: ' .. tostring(normalized))
end)

test('REST templates expand placeholders and read dotted JSON paths', function()
  local rest = require('weiwei.lyrics.providers.rest')
  local expanded = rest.expand('https://example/api?title={title}&artist={artist}&duration={duration}',
    { title = 'Đèn Biển', artist = 'Ca sĩ', duration = 215 })
  assert(expanded:find('title=%C4%90%C3%A8n%20Bi%E1%BB%83n', 1, true), 'URL encoding failed: ' .. expanded)
  assert(expanded:find('duration=215', 1, true))
  local weiwei = fresh_weiwei({
    lyrics = { providers = { 'rest' }, rest = { templates = {
      { name = 'mine', url = 'https://example/lyrics?title={title}', paths = { 'data.lyrics' } } } } },
  })
  scripted_http({ { pattern = 'https://example/lyrics', body = '{"data":{"lyrics":"[00:01.00]rest line"}}' } })
  local agent = require('weiwei.lyrics.agent')
  local result, error_message
  agent.run({ title = 'Whatever' }, function(err, data) result, error_message = data, err end, { config = weiwei.config })
  assert(result, 'REST provider failed: ' .. tostring(error_message))
  assert(result.provider == 'rest')
  assert(result.model.lines[1].text == 'rest line')
  -- A template that returns nothing is reported, not silently ignored.
  scripted_http({ { pattern = 'https://example/lyrics', body = '{"data":{}}' } })
  local failed, failure = nil, nil
  agent.run({ title = 'Whatever else' }, function(err, data) failed, failure = data, err end, { config = weiwei.config, force = true })
  assert(failed == nil and failure, 'empty REST responses must fail')
  assert(failure:find('no lyrics field', 1, true), failure)
end)

test('the HTTP transport retries transient failures and never uses a shell', function()
  local http = require('weiwei.lyrics.http')
  local attempts, argv = 0, nil
  http.set_runner(function(vector, options, callback)
    argv = vector
    attempts = attempts + 1
    if attempts == 1 then return callback({ code = 28, stdout = '', stderr = 'timeout' }) end
    callback({ code = 0, stdout = '{"ok":true}\n200', stderr = '' })
  end)
  http.set_sleeper(function() end)
  local result
  http.fetch('https://lrclib.net/api/get?x=1', {
    attempts = 3, retry_delay_ms = 1, host = 'LRCLIB', headers = { ['User-Agent'] = 'WeiWei/0.1.0' },
  }, function(response) result = response end)
  assert(attempts == 2, 'expected a retry, got ' .. attempts .. ' attempts')
  assert(result.ok and result.status == 200)
  assert(result.body == '{"ok":true}')
  local joined = table.concat(argv, ' ')
  assert(joined:find('User-Agent: WeiWei/0.1.0', 1, true), 'user agent header missing')
  assert(not joined:find(';', 1, true) and not joined:find('|', 1, true), 'argv must not contain shell metacharacters')
  assert(argv[1] == 'curl', 'expected curl as the transport: ' .. tostring(argv[1]))
  -- Fatal statuses are not retried forever
  attempts = 0
  http.set_runner(function(_, _, callback)
    attempts = attempts + 1
    callback({ code = 0, stdout = '{"message":"bad"}\n404', stderr = '' })
  end)
  local missing
  http.fetch('https://lrclib.net/api/get?y=1', { attempts = 3 }, function(response) missing = response end)
  assert(attempts == 1, '404 must not be retried')
  assert(missing.ok == false and missing.status == 404)
end)

-- --------------------------------------------------------------- streaming --

test('yt-dlp invocations are argument vectors and parsing is offline', function()
  local directory = fixture_directory()
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, stream = { enabled = true } })
  local stream = require('weiwei.stream')
  local search_argv = stream.search_argv('đèn biển', weiwei.config)
  assert(search_argv[#search_argv] == 'ytsearch10:đèn biển', search_argv[#search_argv])
  assert(search_argv[1] == 'yt-dlp')
  assert(stream.search_argv('x', weiwei.config)[2] == '--dump-single-json')
  local audio_argv = stream.audio_url_argv('https://example/watch?v=1', weiwei.config)
  assert(table.concat(audio_argv, ' '):find('--get-url', 1, true), 'audio URL argv missing --get-url')
  local download_argv = stream.download_argv('https://example/watch?v=1', directory, weiwei.config)
  assert(table.concat(download_argv, ' '):find('--extract-audio', 1, true))

  local payload = '{"entries":[{"id":"abc","title":"Đèn Biển","uploader":"Ca sĩ Channel","duration":215,'
    .. '"webpage_url":"https://example/watch?v=abc"},{"id":"def","title":"Other Song","duration":300}]}'
  local tracks = assert(stream.parse_search(payload, weiwei.config))
  assert(#tracks == 2, 'expected 2 tracks, got ' .. #tracks)
  assert(tracks[1].source == 'stream')
  assert(tracks[1].duration_ms == 215000)
  assert(tracks[1].artist == 'Ca sĩ Channel', 'uploader should become the artist')
  assert(tracks[1].id == 'stream:abc')
  local url = assert(stream.parse_audio_url('https://cdn.example/audio.m4a\n'))
  assert(url == 'https://cdn.example/audio.m4a')
  assert(stream.parse_audio_url('') == nil)
  assert(stream.friendly_error('ERROR: Sign in to confirm your age'):find('signed-in', 1, true), 'error mapping failed')
  assert(stream.friendly_error('ERROR: Requested format is not available'):find('audio-only', 1, true))

  -- The whole search path runs against a scripted yt-dlp, so the binary only has
  -- to exist as far as the availability probe is concerned.
  vim.fn.executable = function() return 1 end
  stream.set_runner(function(argv, options, callback)
    if argv[#argv]:find('ytsearch', 1, true) then
      return callback({ code = 0, stdout = payload, stderr = '' })
    end
    if argv[#argv]:find('--get-url') then return callback({ code = 0, stdout = '' , stderr = '' }) end
    callback({ code = 0, stdout = 'https://cdn.example/audio.m4a\n--no-playlist', stderr = '' })
  end)
  local found
  stream.search('đèn biển', weiwei.config, function(err, result) found = result or { error = err } end)
  assert(found[1] and found[1].title == 'Đèn Biển', 'scripted streaming search failed')
  local resolved
  stream.resolve_audio_url('https://example/watch?v=abc', weiwei.config, function(err, url) resolved = url or err end)
  assert(resolved == 'https://cdn.example/audio.m4a', tostring(resolved))
  -- Without the binary, streaming reports why instead of crashing.
  vim.fn.executable = function(name) return name == 'yt-dlp' and 0 or 1 end
  local blocked, reason = stream.available(weiwei.config)
  assert(blocked == false and reason:find('yt-dlp', 1, true))
  vim.fn.executable = function() return 1 end
end)

test('unified search merges local and streaming results and explains gaps', function()
  local directory = fixture_directory()
  write(directory .. '/a.mp3', id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Ca sĩ' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, stream = { enabled = true } })
  local stream = require('weiwei.stream')
  stream.set_runner(function(argv, options, callback)
    callback({ code = 0, stdout = '{"entries":[{"id":"x","title":"Đèn Biển live","uploader":"Ca sĩ","duration":240}]}', stderr = '' })
  end)
  local results, notes
  weiwei.search('Đèn Biển', function(err, data, extra) results, notes = data or { error = err }, extra end)
  assert(results and #results == 2, 'expected a local and a streaming result')
  assert(results[1].source == 'local', 'local results come first at equal score')
  assert(results[2].source == 'stream')
  assert(type(notes) == 'table')
  -- With yt-dlp missing, the note explains it and local results still arrive.
  vim.fn.executable = function(name) return name == 'yt-dlp' and 0 or 1 end
  local local_only, local_notes
  weiwei.search('Đèn Biển', function(err, data, extra) local_only, local_notes = data, extra end)
  assert(#local_only == 1 and local_only[1].source == 'local')
  assert(local_notes[1]:find('streaming unavailable', 1, true), local_notes[1])
  vim.fn.executable = function() return 1 end
  local parsed = require('weiwei.search').parse('Lantern - Mira')
  assert(parsed.title == 'Lantern' and parsed.artist == 'Mira', 'combined query parsing failed')
end)

-- ------------------------------------------------------------------ termux --

--- Runs `fn` with temporary environment values, restoring them afterwards.
local function with_env(values, fn)
  local saved = {}
  for name, value in pairs(values) do
    saved[name] = vim.env[name]
    vim.env[name] = value
  end
  local ok, err = pcall(fn)
  for name in pairs(values) do vim.env[name] = saved[name] end
  if not ok then error(err, 0) end
end

--- Runs `fn` with only the listed binaries reported as executable.
local function with_executables(names, fn)
  local previous = vim.fn.executable
  vim.fn.executable = function(name) return names[name] and 1 or 0 end
  local ok, err = pcall(fn)
  vim.fn.executable = previous
  if not ok then error(err, 0) end
end

local TERMUX_ENV = { PREFIX = '/data/data/com.termux/files/usr', TERMUX_VERSION = '0.118.3' }

test('platform detection separates a desktop from Termux and its storage layout', function()
  local platform = require('weiwei.platform')
  platform.reset()
  -- Plain Linux/macOS: unchanged behaviour, no implicit library directories.
  assert(platform.is_termux() == false, 'desktop misdetected as Termux')
  assert(platform.name() == 'linux', platform.name())
  assert(#platform.default_library_directories() == 0, 'the desktop must not gain implicit directories')

  -- Neovim returns vim.NIL for unset variables: that must not be mistaken for a
  -- value (it is a userdata, not a string).
  local previous = vim.fn.getenv
  vim.fn.getenv = function() return vim.NIL end
  assert(platform.is_termux() == false, 'vim.NIL treated as a Termux marker')
  assert(platform.env('PREFIX') == nil)
  vim.fn.getenv = previous

  local home = python_mkdtemp('weiwei-termux-')
  python_mkdir(home .. '/storage/music')
  python_mkdir(home .. '/storage/shared/Music')
  with_env({ PREFIX = TERMUX_ENV.PREFIX, TERMUX_VERSION = TERMUX_ENV.TERMUX_VERSION, HOME = home }, function()
    assert(platform.is_termux(), 'PREFIX was ignored')
    assert(platform.name() == 'termux')
    assert(platform.prefix() == TERMUX_ENV.PREFIX)
    assert(platform.storage_available(), '~/storage should be detected')
    local directories = platform.default_library_directories()
    assert(#directories == 2, 'expected both music directories, got ' .. #directories)
    assert(directories[1] == home .. '/storage/music', directories[1])
    assert(directories[2] == home .. '/storage/shared/Music', directories[2])
    assert(platform.install_command({ 'mpv', 'yt-dlp', 'ffmpeg' }) == 'pkg install -y mpv yt-dlp ffmpeg')
    assert(platform.package_for('termux-notification') == 'termux-api')
    assert(platform.install_command({}) == nil)
  end)

  -- Without shared storage there is nothing to adopt, and the report says so.
  local bare = python_mkdtemp('weiwei-bare-')
  with_env({ PREFIX = TERMUX_ENV.PREFIX, HOME = bare }, function()
    assert(platform.is_termux())
    assert(platform.storage_available() == false)
    assert(#platform.default_library_directories() == 0)
  end)

  -- A Termux build that lost its environment is still recognised through uname.
  local sysname, release = vim.uv.os_uname().sysname, vim.uv.os_uname().release
  vim.uv.os_uname = function() return { sysname = 'Linux', release = 'android13-5.15.140', version = '#1 SMP' } end
  assert(platform.is_termux(), 'android kernel string not detected')
  vim.uv.os_uname = function() return { sysname = sysname, release = release, version = '' } end
  assert(platform.is_termux() == false, 'a normal kernel must not look like Android')
end)

test('the wake lock and the now-playing notification only run on a Termux device', function()
  local platform = require('weiwei.platform')
  platform.reset()
  local calls = {}
  platform.set_runner(function(argv, options, callback)
    calls[#calls + 1] = argv
    if callback then callback({ code = 0, stdout = '', stderr = '' }) end
    return { code = 0 }
  end)

  -- Not Termux: nothing happens, not even a spawn.
  assert(platform.wake_lock(true, { mode = 'auto' }) == false)
  assert(#calls == 0, 'the wake lock must not run on a desktop')
  assert(platform.notify('Title', 'Body') == false)
  assert(#calls == 0)
  -- `mode = never` is honoured even on the phone.
  with_env({ PREFIX = TERMUX_ENV.PREFIX, TERMUX_VERSION = '0.118.3' }, function()
    assert(platform.wake_lock(true, { mode = 'never' }) == false)
    -- Missing termux-tools: reported, and explained with the package name.
    with_executables({}, function()
      local ok, reason = platform.wake_lock(true, { mode = 'auto' })
      assert(ok == false and reason:find('termux-wake-lock', 1, true), tostring(reason))
      local notified, notify_reason = platform.notify('Title', 'Body', { mode = 'auto' })
      assert(notified == false and notify_reason:find('termux-api', 1, true), tostring(notify_reason))
    end)
    with_executables({ ['termux-wake-lock'] = true, ['termux-wake-unlock'] = true,
      ['termux-notification'] = true, ['termux-notification-remove'] = true }, function()
      assert(#calls == 0)
      assert(platform.wake_lock(true, { mode = 'auto' }))
      assert(platform.wake_lock_held())
      assert(table.concat(calls[1], ' ') == 'termux-wake-lock', table.concat(calls[1], ' '))
      -- Repeated calls are deduplicated: the UI hooks every transition.
      assert(platform.wake_lock(true, { mode = 'auto' }))
      assert(#calls == 1, 'the wake lock was acquired twice')
      assert(platform.notify('Đèn Biển', 'Ca sĩ · Album', { mode = 'auto' }))
      assert(table.concat(calls[2], ' '):find('termux-notification --id weiwei-now-playing --ongoing', 1, true),
        table.concat(calls[2], ' '))
      assert(calls[2][#calls[2]] == 'Ca sĩ · Album', 'the notification content is missing')
      assert(platform.wake_lock(false, { mode = 'auto' }))
      assert(platform.wake_lock_held() == false)
      assert(calls[3][1] == 'termux-wake-unlock')
      assert(platform.clear_notification())
      assert(calls[4][1] == 'termux-notification-remove' and calls[4][2] == 'weiwei-now-playing')
    end)
  end)
  platform.reset()
  platform.set_runner(nil)
end)

test('a Termux session adopts the phone music library and holds the lock while playing', function()
  local home = python_mkdtemp('weiwei-phone-')
  python_mkdir(home .. '/storage/music')
  local calls = {}
  local function capture(argv, options, callback)
    calls[#calls + 1] = table.concat(argv, ' ')
    if callback then callback({ code = 0, stdout = '', stderr = '' }) end
    return { code = 0 }
  end

  with_env({ PREFIX = TERMUX_ENV.PREFIX, TERMUX_VERSION = '0.118.3', HOME = home }, function()
    with_executables({ ['termux-wake-lock'] = true, ['termux-wake-unlock'] = true,
      ['termux-notification'] = true, ['termux-notification-remove'] = true }, function()
      -- An empty configuration adopts ~/storage/music ...
      local weiwei = fresh_weiwei({})
      assert(#weiwei.config.library.directories == 1
        and weiwei.config.library.directories[1] == home .. '/storage/music',
        'the phone music directory was not adopted')
      -- ... an explicit directory always wins ...
      local own = home .. '/own'
      python_mkdir(own)
      local explicit = fresh_weiwei({ library = { directories = { own } } })
      assert(#explicit.config.library.directories == 1 and explicit.config.library.directories[1] == own)
      -- ... and `termux.library_directories = {}` switches the detection off.
      local opted_out = fresh_weiwei({ termux = { library_directories = {} } })
      assert(#opted_out.config.library.directories == 0, 'auto-detection ignored the opt-out')

      -- Playback on the phone takes the wake lock and shows the track.
      local directory = fixture_directory()
      write(directory .. '/song.mp3', id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Ca sĩ', TLEN = '215000' }))
      local player_seat = fresh_weiwei({ library = { directories = { directory } }, player = { backend = 'stub' } })
      -- `fresh_weiwei` drops the cached modules, so the platform instance the
      -- player will use is only available after it: install the runner now.
      local platform = require('weiwei.platform')
      platform.set_runner(capture)
      local track = player_seat.library.tracks()[1]
      assert(player_seat.play_track(track))
      assert(platform.wake_lock_held(), 'playback must hold the wake lock')
      assert(calls[1] == 'termux-wake-lock', calls[1])
      assert(calls[2]:find('termux-notification', 1, true), 'no now-playing notification')
      assert(calls[2]:find('Đèn Biển', 1, true), calls[2])
      player_seat.player.stop()
      assert(platform.wake_lock_held() == false, 'stopping must release the wake lock')
      assert(calls[#calls] == 'termux-wake-unlock', calls[#calls])
      player_seat.shutdown()
      assert(calls[#calls]:find('termux-notification-remove', 1, true), calls[#calls])
    end)
  end)
  -- Reset the instance the plugin actually used (the last `fresh_weiwei`).
  local current = require('weiwei.platform')
  current.reset()
  current.set_runner(nil)
end)

test('health and the platform report describe a Termux device without failing', function()
  local home = python_mkdtemp('weiwei-report-')
  python_mkdir(home .. '/storage/music')
  with_env({ PREFIX = TERMUX_ENV.PREFIX, TERMUX_VERSION = '0.118.3', HOME = home }, function()
    -- mpv/yt-dlp/ffmpeg/curl are "missing" here, so the report has to explain
    -- exactly which packages to install instead of failing.
    with_executables({ ['termux-wake-lock'] = true, ['termux-wake-unlock'] = true }, function()
      local weiwei = fresh_weiwei({})
      local report = require('weiwei.health').check()
      local text = table.concat(report, '\n')
      assert(text:find('## Termux / Android', 1, true), text)
      assert(text:find('Termux session', 1, true))
      assert(text:find(home .. '/storage/music', 1, true), 'the music directory is missing from the report')
      assert(text:find('pkg install -y mpv yt-dlp ffmpeg curl', 1, true), text)
      assert(text:find('termux-api', 1, true), 'the notification hint is missing')

      local info = weiwei.show_platform()
      assert(info.termux == true and info.storage == true)
      assert(info.install_command == 'pkg install -y mpv yt-dlp ffmpeg curl')
      assert(#info.music_directories == 1)
      local health = weiwei.health()
      assert(health.platform.termux == true and health.platform.name == 'termux')
    end)
  end)
end)

-- -------------------------------------------------------------- interface --

test('key resolution, views and the composed workspace render', function()
  local keys = require('weiwei.ui.keys')
  local config = assert(require('weiwei.config').resolve({}))
  assert(keys.resolve('library', '<Space>', config).action == 'toggle_play')
  assert(keys.resolve('lyrics', ']', config).argument == 100)
  assert(keys.resolve('library', 'z', config).action == 'shuffle')
  assert(keys.resolve('library', 'nope', config) == nil)
  local custom = assert(require('weiwei.config').resolve({ ui = { keymaps = { ['<Space>'] = 'next' } } }))
  assert(keys.resolve('library', '<Space>', custom).action == 'next')
  assert(#keys.help() > 10)
  assert(keys.needs_row('enqueue') and not keys.needs_row('toggle_play'))

  local directory = fixture_directory()
  write(directory .. '/a.mp3', id3v2({ TIT2 = 'Đèn Biển', TPE1 = 'Ca sĩ', TLEN = '215000' }))
  write(directory .. '/a.lrc', '[00:01.00]<00:01.00>Đèn <00:02.00>biển\n[00:05.00]second line\n')
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, player = { backend = 'stub' },
    lyrics = { providers = { 'local' } } })
  local track = weiwei.library.tracks()[1]
  weiwei.play_track(track)
  weiwei.player.advance(1500)
  weiwei.load_lyrics(track)
  require('weiwei.ui.artwork').set_renderer(function(path, width, rows, callback) callback('no decoder in tests') end)
  local views = require('weiwei.ui.views')
  local state = require('weiwei.state').get()
  local lines, spans, title = views.render('library', state, { width = 60, config = weiwei.config })
  assert(title == ' Library ' and #lines >= 1)
  assert(#spans >= 1, 'expected highlight spans')
  local composed = views.compose(state, { width = 60, height = 24, config = weiwei.config })
  assert(#composed >= 10, 'composed workspace too small: ' .. #composed)
  local lyric_lines = views.render('lyrics', state, { width = 60, config = weiwei.config })
  assert(#lyric_lines > 3)
  local joined = table.concat(composed, '\n')
  assert(joined:find('Đèn Biển', 1, true), 'the track title must appear in the workspace')
  local status = require('weiwei.ui.format').statusline(state.player.track, state.player, state.queue)
  assert(status:find('vol 70%', 1, true), status)
  assert(require('weiwei.ui.format').progress(0.5, 10, 'bar') == '█████░░░░░')
  assert(require('weiwei.ui.format').progress(0.5, 10, 'line'):find('━', 1, true))
  local segments = require('weiwei.ui.format').progress_segments(0.5, 10, 'bar')
  assert(#segments == 2 and #segments[1].text == 15, 'progress byte split: ' .. tostring(#segments[1].text))
  local artwork = require('weiwei.ui.format').artwork_placeholder('Đèn Biển', 'Ca sĩ', 20, 5)
  assert(#artwork == 5, 'the placeholder must fill the requested rows')
end)

test('keyboard actions reach the plugin API', function()
  local directory = fixture_directory()
  write(directory .. '/a.mp3', id3v2({ TIT2 = 'One', TPE1 = 'A', TLEN = '120000' }))
  write(directory .. '/b.mp3', id3v2({ TIT2 = 'Two', TPE1 = 'B', TLEN = '120000' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } }, player = { backend = 'stub' },
    lyrics = { providers = { 'local' } } })
  local ui = require('weiwei.ui.init')
  weiwei.open()
  local function press(key)
    ui.handle_key(key)
  end
  press('2')
  assert(require('weiwei.state').get().view == 'queue')
  press('1')
  assert(require('weiwei.state').get().view == 'library')
  press('a')
  assert(#weiwei.queue.items == 1, 'enqueue from the library failed')
  press('<Down>')
  press('a')
  press('3')
  assert(require('weiwei.state').get().view == 'search')
  press('5')
  press('<CR>')
  assert(weiwei.player and weiwei.player.track, 'enter did not start playback')
  press('<Space>')
  assert(weiwei.player.status == 'paused', 'space did not pause')
  press('<Space>')
  assert(weiwei.player.status == 'playing')
  press('.')
  assert(weiwei.queue.index >= 2, 'next did not advance the queue')
  press('r')
  assert(weiwei.queue.repeat_mode == 'all', 'repeat cycle failed')
  press('z')
  assert(weiwei.queue.shuffle == true)
  press('x')
  assert(#weiwei.queue.items == 0, 'clear queue failed')
  press('?')
  press('q')
  assert(ui.is_open() == false, 'close failed')
end)

test('health reports every capability without failing on missing programs', function()
  local directory = fixture_directory()
  write(directory .. '/a.mp3', id3v2({ TIT2 = 'One', TPE1 = 'A' }))
  local weiwei = fresh_weiwei({ library = { directories = { directory } } })
  local health = weiwei.health()
  assert(health.version and health.config == true)
  assert(health.library.tracks == 1)
  assert(type(health.binaries) == 'table' and health.binaries.mpv ~= nil)
  assert(#health.lyrics >= 1, 'no lyrics providers reported')
  assert(health.cache.memory_entries >= 0)
  local lines = weiwei.show_health()
  assert(lines and lines.version)
  local report = require('weiwei.health').check()
  assert(#report > 5 and report[1]:find('WeiWei', 1, true))
  -- With every binary missing, the report still renders and the stub backend runs.
  vim.fn.executable = function() return 0 end
  local degraded = fresh_weiwei({ library = { directories = { directory } } })
  local report_lines = degraded.health()
  assert(report_lines.binaries.mpv == false)
  local lines_missing = degraded.show_health()
  assert(lines_missing.version)
  local keys = require('weiwei.ui.keys')
  local ui = require('weiwei.ui.init')
  ui.handle_key('i') -- must not raise without any external program
  assert(keys.resolve('library', 'i', degraded.config).action == 'health')
  vim.fn.executable = function() return 1 end
end)

print(string.format('# weiwei %d tests, %d failures', count, failures))
if failures > 0 then error('weiwei suite failed: ' .. failures) end
print('PASS: WeiWei configuration, library, queue, player, lyrics agents, streaming and UI builders')
