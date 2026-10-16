-- Track matching for lyrics candidates.
--
-- Providers return many near-misses: live versions, covers, remixes and
-- same-titled songs by other artists. Picking the wrong one silently is worse
-- than reporting "no lyrics", so every candidate is scored and the best one must
-- clear a threshold. Scoring is deliberately explainable: each component
-- contributes a documented weight, and the reason string is kept for the UI and
-- for `:WeiWeiLyricsInfo`.
local model = require('weiwei.lyrics.model')

local M = {}

local WEIGHTS = {
  title = 0.45,
  artist = 0.3,
  album = 0.1,
  duration = 0.15,
}

--- Token-set similarity in 0..1: Jaccard with a bonus for containment, so
--- "Song (Live)" still matches "Song" without matching an unrelated title that
--- merely shares a word.
function M.similarity(left, right)
  local a = model.tokens(left)
  local b = model.tokens(right)
  if #a == 0 or #b == 0 then return 0 end
  local set_a, set_b = {}, {}
  for _, token in ipairs(a) do set_a[token] = true end
  for _, token in ipairs(b) do set_b[token] = true end
  local shared = 0
  for token in pairs(set_a) do if set_b[token] then shared = shared + 1 end end
  if shared == 0 then
    -- Fall back to substring matching for CJK titles and glued words.
    local left_key, right_key = table.concat(a, ' '), table.concat(b, ' ')
    if left_key:find(right_key, 1, true) or right_key:find(left_key, 1, true) then return 0.75 end
    return 0
  end
  local union = 0
  for token in pairs(set_a) do union = union + 1 end
  for token in pairs(set_b) do if not set_a[token] then union = union + 1 end end
  local jaccard = shared / union
  local containment = shared / math.min(#a, #b)
  return math.max(jaccard, containment * 0.9)
end

--- Duration agreement in 0..1. Unknown durations score neutrally instead of
--- penalizing the candidate.
function M.duration_score(expected_ms, candidate_ms, tolerance_seconds)
  if not expected_ms or expected_ms <= 0 or not candidate_ms or candidate_ms <= 0 then return nil end
  local tolerance = math.max(1, (tolerance_seconds or 2) * 1000)
  local delta = math.abs(expected_ms - candidate_ms)
  if delta <= tolerance then return 1 end
  if delta >= tolerance * 6 then return 0 end
  return math.max(0, 1 - (delta - tolerance) / (tolerance * 5))
end

--- Scores a candidate against the query.
--- @param query table { title, artist, album, duration_ms }
--- @param candidate table { track_name|title, artist_name|artist, album_name|album, duration|duration_ms, has_word_sync }
--- @param options table|nil { duration_tolerance_seconds, minimum_score, require_duration, prefer_word_sync }
--- @return table { score, accepted, parts, reasons }
function M.score(query, candidate, options)
  options = options or {}
  query = query or {}
  candidate = candidate or {}
  local parts = {}
  local reasons = {}

  local title = candidate.track_name or candidate.title or candidate.name
  parts.title = M.similarity(query.title, title)
  local artist = candidate.artist_name or candidate.artist or candidate.uploader
  parts.artist = M.similarity(query.artist, artist)
  if M.similarity(query.artist, artist) == 0 and model.key(query.artist or '') == '' then parts.artist = nil end
  parts.album = M.similarity(query.album, candidate.album_name or candidate.album)
  if parts.album == 0 then parts.album = nil end
  local duration = M.duration_score(
    query.duration_ms or (query.duration and query.duration * 1000),
    candidate.duration_ms or (candidate.duration and candidate.duration * 1000),
    options.duration_tolerance_seconds)

  local total, weight = 0, 0
  for key, value in pairs(parts) do
    if value ~= nil then
      total = total + value * WEIGHTS[key]
      weight = weight + WEIGHTS[key]
      if value >= 0.8 then reasons[#reasons + 1] = key .. ' matched' end
    end
  end
  if duration ~= nil then
    total = total + duration * WEIGHTS.duration
    weight = weight + WEIGHTS.duration
    parts.duration = duration
    if duration >= 0.8 then reasons[#reasons + 1] = 'duration matched' end
  end

  -- An explicit candidate duration that disagrees badly is disqualifying even if
  -- the text matches: it is almost always a different version of the song.
  local disqualified = false
  if duration ~= nil and duration <= 0.2 and options.require_duration ~= false then
    disqualified = true
    reasons[#reasons + 1] = 'duration differs too much'
  end
  local score = weight > 0 and (total / weight) or 0
  if candidate.has_word_sync or candidate.words then
    score = math.min(1, score + (options.prefer_word_sync == false and 0 or 0.05))
    reasons[#reasons + 1] = 'word-level timing'
  end
  if candidate.instrumental then reasons[#reasons + 1] = 'marked instrumental' end

  local minimum = options.minimum_score or 0.45
  return {
    score = score,
    accepted = not disqualified and score >= minimum,
    parts = parts,
    reasons = reasons,
    duration_delta_ms = duration ~= nil and math.abs((query.duration_ms or 0) - ((candidate.duration_ms or (candidate.duration or 0) * 1000))) or nil,
  }
end

--- Ranks candidates and returns the accepted one, or nil plus the best score.
--- @return table|nil best, table scores
function M.choose(query, candidates, options)
  local scores = {}
  local best, best_score = nil, nil
  for index, candidate in ipairs(candidates or {}) do
    local score = M.score(query, candidate, options)
    scores[index] = score
    if score.accepted and (not best_score or score.score > best_score.score) then
      best, best_score = candidate, score
      best.index = index
    end
  end
  return best, scores
end

return M
