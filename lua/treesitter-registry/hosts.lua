-- lua/treesitter-registry/hosts.lua
-- Git host adapters: version checks via `git ls-remote`.
--
-- No API rate limits, no authentication required, works universally for
-- public repos.  HTTP (lua/treesitter-registry/http.lua) is used only for
-- tarball downloads and raw-file fetches, not for version discovery.

local M = {}

-- ---------------------------------------------------------------------------
-- Host adapter interface
--
-- Each adapter implements:
--   latest_tag(url, callback)        → string? (latest semver tag e.g. "v0.25.0")
--   latest_head(url, branch, cb)     → string? (HEAD commit SHA or branch SHA)
-- ---------------------------------------------------------------------------

---@class HostAdapter
---@field latest_tag   fun(url: string, callback: fun(tag: string?, err: string?))
---@field latest_head  fun(url: string, branch: string?, callback: fun(sha: string?, err: string?))

-- ---------------------------------------------------------------------------
-- Generic adapter (git CLI, works for any host)
--
-- All host-specific adapters delegate here; the adapter lookup exists so
-- callers can extend per-host behaviour in the future.
-- ---------------------------------------------------------------------------
local generic = {}

function generic.latest_tag(url, callback)
  vim.system({
    'git',
    '-c',
    'versionsort.suffix=-',
    'ls-remote',
    '--tags',
    '--refs',
    '--sort=v:refname',
    url,
  }, { text = true }, function(r)
    if r.code ~= 0 then
      return callback(nil, r.stderr)
    end
    local lines = vim.split(vim.trim(r.stdout), '\n')
    for i = #lines, 1, -1 do
      local tag = lines[i]:match('\trefs/tags/(v[%d%.]+)$')
      if tag then
        return callback(tag, nil)
      end
    end
    callback(nil, 'no semver tags found')
  end)
end

function generic.latest_head(url, branch, callback)
  local cmd = { 'git', 'ls-remote', url }
  if branch then
    cmd[#cmd + 1] = 'refs/heads/' .. branch
  end
  vim.system(cmd, { text = true }, function(r)
    if r.code ~= 0 then
      return callback(nil, r.stderr)
    end
    local lines = vim.split(vim.trim(r.stdout), '\n')
    local target = branch and ('refs/heads/' .. branch) or 'HEAD'
    for _, line in ipairs(lines) do
      local sha, ref = line:match('^(%x+)\t(.+)$')
      if sha and ref == target then
        return callback(sha, nil)
      end
    end
    local sha = vim.split(lines[1] or '', '\t')[1]
    callback(sha ~= '' and sha or nil, sha == '' and 'empty response' or nil)
  end)
end

-- ---------------------------------------------------------------------------
-- GitHub adapter
-- ---------------------------------------------------------------------------
local github = {
  latest_tag = generic.latest_tag,
  latest_head = generic.latest_head,
}

-- ---------------------------------------------------------------------------
-- GitLab adapter
-- ---------------------------------------------------------------------------
local gitlab = {
  latest_tag = generic.latest_tag,
  latest_head = generic.latest_head,
}

-- ---------------------------------------------------------------------------
-- Adapter registry + resolver
-- ---------------------------------------------------------------------------

M._adapters = {
  ['github.com'] = github,
  ['gitlab.com'] = gitlab,
}

--- Return the adapter for a given repo URL.
---@param url string
---@return HostAdapter
function M.for_url(url)
  for host, adapter in pairs(M._adapters) do
    if url:find(host, 1, true) then
      return adapter
    end
  end
  return generic
end

--- Register a custom adapter for a git host.
---@param hostname string  e.g. "codeberg.org"
---@param adapter  HostAdapter
function M.register(hostname, adapter)
  M._adapters[hostname] = adapter
end

-- Codeberg (Gitea)
M.register('codeberg.org', {
  latest_tag = generic.latest_tag,
  latest_head = generic.latest_head,
})

return M
