-- HTTP transport for the lyrics providers.
--
-- Neovim has no Lua HTTP client, so requests go through an external `curl` (or,
-- if curl is missing, a one-shot `node` process) started with an argument
-- vector — never a shell string. The transport is injectable so the Lua test
-- harness can drive the whole provider stack offline, and every request is
-- bounded by a timeout.
local util = require('weiwei.util')

local M = {}

local runner = nil -- function(argv, options, callback)
local sleeper = nil -- function(milliseconds) for retry backoff

function M.set_runner(fn) runner = fn end
function M.set_sleeper(fn) sleeper = fn end

local function sleep(milliseconds)
  if sleeper then return sleeper(milliseconds) end
  if vim and vim.uv and vim.uv.sleep then vim.uv.sleep(milliseconds) return end
  if vim and vim.fn and vim.fn.system and vim.fn.executable('sleep') == 1 then return end
  -- No sleep primitive: retries still work, they just do not back off.
end

function M.sleep(milliseconds) sleep(milliseconds) end

--- True when HTTP requests can be made at all.
function M.available()
  if runner then return true end
  if vim and vim.fn and vim.fn.executable then
    return vim.fn.executable('curl') == 1 or vim.fn.executable('node') == 1
  end
  return false
end

--- Which program would be used, for `:WeiWeiHealth`.
function M.backend()
  if runner then return 'injected' end
  if vim and vim.fn and vim.fn.executable then
    if vim.fn.executable('curl') == 1 then return 'curl' end
    if vim.fn.executable('node') == 1 then return 'node' end
  end
  return nil
end

local function default_runner(argv, options, callback)
  if not (vim and vim.system) then
    callback({ code = 127, stdout = '', stderr = 'no process API available' })
    return
  end
  local ok, process = pcall(vim.system, argv, { text = true, timeout = options.timeout_ms }, function(result)
    callback({ code = result.code, stdout = result.stdout or '', stderr = result.stderr or '' })
  end)
  if not ok then callback({ code = 127, stdout = '', stderr = tostring(process) }) end
  return process
end

local NODE_SCRIPT = [[
const url = process.argv[1];
const timeout = Number(process.argv[2] || 10000);
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), timeout);
const options = { signal: controller.signal, redirect: 'follow' };
for (const header of process.argv.slice(3)) {
  const at = header.indexOf(':');
  if (at > 0) { options.headers = options.headers || {}; options.headers[header.slice(0, at).trim()] = header.slice(at + 1).trim(); }
}
fetch(url, options).then(async response => {
  const body = await response.text();
  // Trailing status line, the same shape curl's --write-out produces.
  process.stdout.write(body + '\n' + response.status);
}).catch(error => { process.stderr.write(String(error && error.message || error)); process.exit(1); })
  .finally(() => clearTimeout(timer));
]]

--- Performs one request.
--- @param url string
--- @param options table|nil { method, headers { name = value }, body, timeout_ms, user_agent }
--- @param callback function(result) with `{ ok, status, body, error }`
function M.request(url, options, callback)
  options = options or {}
  local timeout_ms = math.max(1000, math.floor(tonumber(options.timeout_ms) or 10000))
  local headers = options.headers or {}
  local argv
  if M.backend() == 'node' then
    argv = { 'node', '-e', NODE_SCRIPT, url, tostring(timeout_ms) }
    for name, value in util.ordered_pairs(headers) do argv[#argv + 1] = name .. ': ' .. tostring(value) end
  else
    local seconds = string.format('%.1f', timeout_ms / 1000)
    argv = { 'curl', '--silent', '--show-error', '--location', '--compressed',
      '--max-time', seconds, '--write-out', '\n%{http_code}' }
    if options.method == 'POST' then argv[#argv + 1] = '--request'; argv[#argv + 1] = 'POST' end
    for name, value in util.ordered_pairs(headers) do argv[#argv + 1] = '--header'; argv[#argv + 1] = name .. ': ' .. tostring(value) end
    if options.body then argv[#argv + 1] = '--data-binary'; argv[#argv + 1] = options.body end
    argv[#argv + 1] = url
  end
  local active = runner or default_runner
  active(argv, { timeout_ms = timeout_ms }, function(result)
    if not result then
      return callback({ ok = false, error = 'no response from the HTTP transport' })
    end
    local code = tonumber(result.code) or -1
    if code ~= 0 then
      local message = util.trim(result.stderr or '')
      if message == '' then message = 'transport exited with status ' .. tostring(code) end
      -- curl reports timeouts as exit 28, which is worth naming explicitly.
      if code == 28 then message = 'request timed out after ' .. timeout_ms .. ' ms' end
      return callback({ ok = false, error = message })
    end
    local stdout = result.stdout or ''
    local body, status = stdout:match('^(.*)\n(%d%d%d)$')
    if status then
      return callback({ ok = true, status = tonumber(status), body = body })
    end
    -- No status line (an injected runner in tests, for example): treat the whole
    -- output as the body with an implicit 200.
    return callback({ ok = true, status = 200, body = stdout })
  end)
end

--- Request with bounded retries. Retries on transport failures, 5xx and 429;
--- a caller-supplied `retry_after_ms` (from a provider's `Retry-After`) wins.
function M.fetch(url, options, callback)
  options = options or {}
  local attempts = math.max(1, math.floor(tonumber(options.attempts) or 1))
  local delay = math.max(0, math.floor(tonumber(options.retry_delay_ms) or 300))
  local attempt = 0
  local function failure(result)
    return {
      ok = false, status = result.status, body = result.body,
      error = result.error or string.format('HTTP %s from %s', tostring(result.status), options.host or 'provider'),
    }
  end
  local function run()
    attempt = attempt + 1
    M.request(url, options, function(result)
      local retryable = (not result.ok)
        or (result.status and (result.status >= 500 or result.status == 429))
      if not retryable then
        if not result.ok then return callback(result) end
        if result.status and result.status >= 400 then return callback(failure(result)) end
        return callback(result)
      end
      if attempt >= attempts then
        if not result.ok then return callback(result) end
        return callback(failure(result))
      end
      local wait = options.retry_after_ms or delay * attempt
      util.log('debug', string.format('retrying %s in %d ms (attempt %d/%d)', url, wait, attempt, attempts))
      sleep(wait)
      run()
    end)
  end
  run()
end

return M
