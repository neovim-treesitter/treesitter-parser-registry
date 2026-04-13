-- lua/treesitter-registry.lua
-- Public API for the treesitter-parser-registry plugin.
--
-- Loads the bundled registry.json from this plugin's own directory on the
-- rtp and exposes a simple load/get interface.  No HTTP, no caching, no
-- external dependencies — the registry data ships with the plugin and is
-- updated when the user updates the plugin via their package manager.

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Locate this plugin's own registry.json on the rtp.
---@return string?
local function find_registry_json()
  -- Use the Lua module path to find our plugin root, then resolve
  -- registry.json relative to it.
  local info = debug.getinfo(1, 'S')
  if info and info.source and info.source:sub(1, 1) == '@' then
    local this_file = info.source:sub(2)
    local plugin_root = vim.fn.fnamemodify(this_file, ':h:h')
    local path = vim.fs.joinpath(plugin_root, 'registry.json')
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  -- Fallback: search the rtp (handles edge cases like bundled plugins)
  local found = vim.api.nvim_get_runtime_file('registry.json', false)
  if found and #found > 0 then
    return found[1]
  end
  return nil
end

--- Decode a file path as JSON.  Strips the `$schema` key (JSON Schema
--- metadata, not a language entry).
---@param path string
---@return table?  data
---@return string? err
local function decode_registry(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or #lines == 0 then
    return nil, 'could not read ' .. path
  end
  local dok, data = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not dok or type(data) ~= 'table' then
    return nil, 'JSON decode failed for ' .. path
  end
  ---@cast data table
  data['$schema'] = nil
  return data, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- The last-successfully-loaded registry table, or nil.
---@type table?
M.loaded = nil

--- Synchronous lookup in the last-loaded registry.
--- Returns nil if the registry has not been loaded yet.
---@param lang string
---@return table?
function M.get(lang)
  if not M.loaded then
    return nil
  end
  return M.loaded[lang]
end

--- Load the registry from this plugin's bundled registry.json.
---
--- Synchronous filesystem read — no network, no cache, no TTL.
--- To update the registry data the user simply updates this plugin.
---
---@param callback  fun(registry: table?, err: string?)
---@param opts      table?   unused, reserved for future options
function M.load(callback, opts)
  _ = opts

  local path = find_registry_json()
  if not path then
    return callback(
      nil,
      'treesitter-registry: registry.json not found.\n'
        .. 'Ensure the treesitter-parser-registry plugin is installed.'
    )
  end

  local data, err = decode_registry(path)
  if not data then
    return callback(nil, 'treesitter-registry: ' .. (err or 'unknown error'))
  end

  M.loaded = data
  callback(data, nil)
end

return M
