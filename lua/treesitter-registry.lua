-- lua/treesitter-registry.lua
-- Fetch, cache and decode the treesitter-parser-registry.
-- Vendored by installers; also ships with the registry repo as reference.
--
-- Uses lua/treesitter-registry/http.lua (vim.system + curl binary) for all
-- HTTP traffic — no external Lua dependencies required.

local M = {}

-- GitHub Contents API endpoint — returns raw JSON when Accept header is set.
local REGISTRY_URL =
    "https://api.github.com/repos/neovim-treesitter/treesitter-parser-registry/contents/registry.json?ref=main"

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
                    if dok then
                        return callback(decoded, nil)
                    end
                end
            end
        end
    end

    -- Fetch fresh copy
    local http = require("treesitter-registry.http")
    local headers = {
        accept = "application/vnd.github.raw+json",
        ["x-github-api-version"] = "2022-11-28",
    }
    local token = vim.env.GITHUB_TOKEN
    if token and token ~= "" then
        headers["authorization"] = "Bearer " .. token
    end
    http.get(REGISTRY_URL, { headers = headers, timeout = 15000 }, function(response, err)
        if err or (response and response.status ~= 200) then
            -- Stale fallback
            local rok, lines = pcall(vim.fn.readfile, rp)
            if rok and #lines > 0 then
                local dok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
                if dok then
                    vim.notify(
                        "treesitter-registry: using stale cache (fetch failed"
                            .. (response and ", HTTP " .. tostring(response.status) or "")
                            .. (err and ", " .. err or "")
                            .. ")",
                        vim.log.levels.WARN
                    )
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
    end)
end

return M
