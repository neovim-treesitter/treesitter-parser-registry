-- lua/treesitter-registry/http.lua
-- Minimal async HTTP client backed by the system curl binary and vim.system.
-- Zero external dependencies.
--
-- Public API:
--   M.get(url, opts, callback)         — async GET, body in memory
--   M.download(url, output, opts, cb)  — async GET, write body to file

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Build the curl argument list from an options table.
---@param url     string
---@param opts    { headers: table<string,string>?, timeout: number?, extra: string[]? }?
---@return string[]
local function build_args(url, opts)
  opts = opts or {}
  -- -s  suppress progress, -S  show errors even with -s
  local args = { 'curl', '-s', '-S' }

  -- Headers
  if opts.headers then
    for k, v in pairs(opts.headers) do
      args[#args + 1] = '-H'
      args[#args + 1] = k .. ': ' .. v
    end
  end

  -- Timeout (curl expects seconds, our API accepts ms for compat)
  if opts.timeout then
    args[#args + 1] = '--max-time'
    args[#args + 1] = tostring(math.ceil(opts.timeout / 1000))
  end

  -- Extra raw args (e.g. -L, --retry, --fail, -w)
  if opts.extra then
    for _, a in ipairs(opts.extra) do
      args[#args + 1] = a
    end
  end

  args[#args + 1] = url
  return args
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Async HTTP GET.  Response body is returned in memory.
---
--- callback(response, err) where response = { status: integer, body: string }
--- and err is a string on curl failure, or nil on success.
---
---@param url      string
---@param opts     { headers: table<string,string>?, timeout: number? }?
---@param callback fun(response: { status: integer, body: string }?, err: string?)
function M.get(url, opts, callback)
  opts = opts or {}
  -- Append -w to emit the HTTP status as the last line of stdout.
  local extra = { '-w', '\n%{http_code}' }
  local args = build_args(url, { headers = opts.headers, timeout = opts.timeout, extra = extra })

  vim.system(args, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, 'curl exit ' .. obj.code .. ': ' .. (obj.stderr or ''))
        return
      end
      -- Last line is the HTTP status code injected by -w.
      local stdout = obj.stdout or ''
      local last_nl = stdout:find('\n[^\n]*$')
      local body, status_str
      if last_nl then
        body = stdout:sub(1, last_nl - 1)
        status_str = stdout:sub(last_nl + 1)
      else
        body = ''
        status_str = stdout
      end
      local status = tonumber(status_str) or 0
      callback({ status = status, body = body }, nil)
    end)
  end)
end

--- Async file download.  The response body is written directly to `output`.
---
--- Follows redirects (-L), retries transient failures (--retry 3), and fails
--- on HTTP errors (--fail).  Optional extra headers can be added via opts.
---
--- callback(response, err) where response = { status: integer, body: string }
--- (body is typically empty for downloads).
---
---@param url      string
---@param output   string   destination file path
---@param opts     { headers: table<string,string>?, timeout: number? }?
---@param callback fun(response: { status: integer, body: string }?, err: string?)
function M.download(url, output, opts, callback)
  opts = opts or {}
  local extra = {
    '-L',
    '--retry',
    '3',
    '--fail',
    '--show-error',
    '-o',
    output,
    '-w',
    '%{http_code}',
  }
  local args = build_args(url, { headers = opts.headers, timeout = opts.timeout, extra = extra })

  vim.system(args, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, 'curl exit ' .. obj.code .. ': ' .. (obj.stderr or ''))
        return
      end
      local status = tonumber(obj.stdout) or 200
      callback({ status = status, body = '' }, nil)
    end)
  end)
end

return M
