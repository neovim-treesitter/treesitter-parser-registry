-- lua/treesitter-registry.lua
-- Fetch, cache and decode the treesitter-parser-registry.
-- Vendored by installers; also ships with the registry repo as reference.
--
-- Requires: nvim-lua/plenary.nvim

local curl = require("plenary.curl")

local M = {}

-- Single indirection point: swap this for a CDN URL without changing callers.
local REGISTRY_URL =
  "https://raw.githubusercontent.com/neovim-treesitter/treesitter-parser-registry/main/registry.json"

-- Registry is stable data (new langs added rarely). 7-day TTL.
local REGISTRY_TTL = 604800

--- Returns the path to the cached registry JSON file.
---@param cache_dir string
---@return string
local function reg_path(cache_dir)
  return vim.fs.joinpath(cache_dir, "treesitter-registry.json")
end

--- Returns the path to the registry cache metadata file.
---@param cache_dir string
---@return string
local function meta_path(cache_dir)
  return vim.fs.joinpath(cache_dir, "treesitter-registry-meta.lua")
end

--- Load registry. Uses local cache when fresh; fetches otherwise.
--- Falls back to stale cache if fetch fails (with a warning).
---@param cache_dir string  writable directory for cached files
---@param opts      { force?: boolean }?
---@param callback  fun(registry: table?, err: string?)
function M.load(cache_dir, opts, callback)
  opts = opts or {}
  local rp = reg_path(cache_dir)
  local mp = meta_path(cache_dir)

  -- Check freshness unless force-refresh requested
  if not opts.force then
    local ok, meta = pcall(dofile, mp)
    if ok and type(meta) == "table" then
      if (os.time() - (meta.fetched_at or 0)) < REGISTRY_TTL then
        local lines = vim.fn.readfile(rp)
        if #lines > 0 then
          local dok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
          if dok then return callback(decoded, nil) end
        end
      end
    end
  end

  -- Fetch fresh copy
  curl.get(REGISTRY_URL, {
    headers = { accept = "application/json" },
    timeout = 15000,
    callback = vim.schedule_wrap(function(response)
      if response.status ~= 200 then
        -- Stale fallback
        local lines = vim.fn.readfile(rp)
        if #lines > 0 then
          local dok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
          if dok then
            vim.notify("treesitter-registry: using stale cache (fetch failed)", vim.log.levels.WARN)
            return callback(decoded, nil)
          end
        end
        return callback(nil, "treesitter-registry: fetch failed and no cache available")
      end

      vim.fn.mkdir(cache_dir, "p")
      vim.fn.writefile(vim.split(response.body, "\n"), rp)
      vim.fn.writefile(
        { "return { fetched_at = " .. os.time() .. " }" },
        mp
      )

      local dok, decoded = pcall(vim.json.decode, response.body)
      if not dok then
        return callback(nil, "treesitter-registry: JSON decode failed")
      end
      callback(decoded, nil)
    end),
  })
end

return M
