-- lua/treesitter-registry/hosts.lua
-- Git host adapters: version-check APIs + tarball/raw-file URL construction.
--
-- Uses lua/treesitter-registry/http.lua (vim.system + curl binary) for all
-- HTTP traffic — no external Lua dependencies required.
--
-- Version check strategy per host:
--   github.com  → GitHub REST API (releases/tags endpoints; GITHUB_TOKEN is
--                 sent as Bearer auth when set, raising rate limits from
--                 60 → 5 000 req/hr for public repos)
--   gitlab.com  → GitLab REST API
--   others      → git ls-remote fallback (universal, no API token needed)

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Parse owner/repo from a git forge URL.
---@param url string
---@return string?, string?
local function owner_repo(url)
    local owner, repo = url:match("^https?://[^/]+/([^/]+)/([^/]+)/*$")
    if repo then
        repo = repo:gsub("%.git$", "")
    end
    return owner, repo
end

--- Return the GITHUB_TOKEN from the environment, or nil when unset / blank.
---@return string?
local function github_token()
    local t = vim.env.GITHUB_TOKEN
    if t and t ~= "" then
        return t
    end
    return nil
end

--- Build the standard GitHub API headers.
--- Includes Authorization: Bearer when a GITHUB_TOKEN is available.
---@return table<string,string>
local function github_headers()
    local h = {
        accept = "application/vnd.github+json",
        ["x-github-api-version"] = "2022-11-28",
    }
    local token = github_token()
    if token then
        h["authorization"] = "Bearer " .. token
    end
    return h
end

--- HTTP GET via treesitter-registry/http; calls callback(body, err).
---@param url      string
---@param headers  table<string,string>?  header key→value pairs
---@param callback fun(body: string?, err: string?)
local function http_get(url, headers, callback)
    local http = require("treesitter-registry.http")
    http.get(url, { headers = headers or {}, timeout = 10000 }, function(response, err)
        if err then
            callback(nil, err)
        elseif response.status >= 200 and response.status < 300 then
            callback(response.body, nil)
        else
            local msg = "HTTP " .. tostring(response.status)
            if response.body and response.body ~= "" then
                msg = msg .. ": " .. response.body
            end
            callback(nil, msg)
        end
    end)
end

--- Parse the latest semver tag from a list of tag objects.
--- Each object must have a `.name` field (tags endpoint) or `.tag_name`
--- field (releases endpoint). Returns highest vX.Y.Z tag.
---@param tags table[]
---@return string?
local function latest_semver(tags)
    local best, best_parts
    for _, t in ipairs(tags) do
        -- For releases: tag_name is the version, name is the human-readable title
        -- which may be null.  For tags: name is the tag, no tag_name field.
        -- JSON null → vim.NIL (userdata); guard against non-string values.
        local raw = t.tag_name or t.name
        local name = type(raw) == "string" and raw or ""
        local ma, mi, pa = name:match("^v?(%d+)%.(%d+)%.?(%d*)$")
        if ma then
            local parts = { tonumber(ma), tonumber(mi), tonumber(pa) or 0 }
            if
                not best_parts
                or parts[1] > best_parts[1]
                or (parts[1] == best_parts[1] and parts[2] > best_parts[2])
                or (parts[1] == best_parts[1] and parts[2] == best_parts[2] and parts[3] > best_parts[3])
            then
                best = name:match("^v") and name or ("v" .. name)
                best_parts = parts
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Host adapter interface
--
-- Each adapter implements:
--   latest_tag(url, callback)        → string? (latest semver tag e.g. "v0.25.0")
--   latest_head(url, branch, cb)     → string? (HEAD commit SHA or branch SHA)
--   tarball_url(url, ref)            → string? (nil = use git clone fallback)
--   raw_url(url, ref, path)          → string? (nil = use git archive fallback)
-- ---------------------------------------------------------------------------

---@class HostAdapter
---@field latest_tag   fun(url: string, callback: fun(tag: string?, err: string?))
---@field latest_head  fun(url: string, branch: string?, callback: fun(sha: string?, err: string?))
---@field tarball_url  fun(url: string, ref: string): string?
---@field raw_url      fun(url: string, ref: string, path: string): string?

-- ---------------------------------------------------------------------------
-- GitHub adapter
-- Uses REST API v3 — GITHUB_TOKEN is sent as Bearer auth when available,
-- raising the rate limit from 60 to 5 000 req/hour for public repos.
-- ---------------------------------------------------------------------------
local github = {}

function github.latest_tag(url, callback)
    local owner, repo = owner_repo(url)
    if not owner then
        return callback(nil, "could not parse owner/repo from: " .. url)
    end

    local api = string.format("https://api.github.com/repos/%s/%s/releases", owner, repo)
    local headers = github_headers()

    http_get(api, headers, function(body, err)
        if body then
            local ok, releases = pcall(vim.json.decode, body)
            if ok and type(releases) == "table" and #releases > 0 then
                local tag = latest_semver(releases)
                if tag then
                    return callback(tag, nil)
                end
            end
        end

        local tags_api = string.format("https://api.github.com/repos/%s/%s/tags", owner, repo)
        http_get(tags_api, headers, function(tbody, terr)
            if not tbody then
                return callback(nil, terr or err)
            end
            local tok, tags = pcall(vim.json.decode, tbody)
            if not tok or type(tags) ~= "table" then
                return callback(nil, "JSON decode failed")
            end
            callback(latest_semver(tags), nil)
        end)
    end)
end

function github.latest_head(url, branch, callback)
    local owner, repo = owner_repo(url)
    if not owner then
        return callback(nil, "could not parse owner/repo from: " .. url)
    end

    local ref = branch or "HEAD"
    local api = string.format("https://api.github.com/repos/%s/%s/commits/%s", owner, repo, ref)
    local headers = github_headers()

    http_get(api, headers, function(body, err)
        if not body then
            return callback(nil, err)
        end
        local ok, data = pcall(vim.json.decode, body)
        if ok and type(data) == "table" and data.sha then
            callback(data.sha, nil)
        else
            callback(nil, "could not extract SHA from response")
        end
    end)
end

function github.tarball_url(url, ref)
    return url .. "/archive/" .. ref .. ".tar.gz"
end

function github.raw_url(url, ref, path)
    local owner, repo = owner_repo(url)
    if owner and repo then
        return string.format(
            "https://api.github.com/repos/%s/%s/contents/%s?ref=%s",
            owner, repo, path, ref
        )
    end
    local raw = url:gsub("^https://github%.com/", "https://raw.githubusercontent.com/")
    return raw .. "/" .. ref .. "/" .. path
end

-- ---------------------------------------------------------------------------
-- GitLab adapter
-- ---------------------------------------------------------------------------
local gitlab = {}

function gitlab.latest_tag(url, callback)
    local owner, repo = owner_repo(url)
    if not owner then
        return callback(nil, "could not parse: " .. url)
    end

    local encoded = vim.uri_encode and vim.uri_encode(owner .. "/" .. repo)
        or (owner .. "%2F" .. repo)
    local api = string.format("https://gitlab.com/api/v4/projects/%s/releases", encoded)

    http_get(api, { accept = "application/json" }, function(body, err)
        if body then
            local ok, releases = pcall(vim.json.decode, body)
            if ok and #releases > 0 then
                local tag = latest_semver(releases)
                if tag then
                    return callback(tag, nil)
                end
            end
        end
        local tags_api = string.format(
            "https://gitlab.com/api/v4/projects/%s/repository/tags?order_by=version", encoded
        )
        http_get(tags_api, {}, function(tbody, terr)
            if not tbody then
                return callback(nil, terr or err)
            end
            local tok, tags = pcall(vim.json.decode, tbody)
            callback(tok and latest_semver(tags) or nil, tok and nil or "decode failed")
        end)
    end)
end

function gitlab.latest_head(url, branch, callback)
    local owner, repo = owner_repo(url)
    if not owner then
        return callback(nil, "could not parse: " .. url)
    end
    local encoded = owner .. "%2F" .. repo
    local ref = branch or "HEAD"
    local api = string.format(
        "https://gitlab.com/api/v4/projects/%s/repository/commits/%s", encoded, ref
    )
    http_get(api, {}, function(body, err)
        if not body then
            return callback(nil, err)
        end
        local ok, data = pcall(vim.json.decode, body)
        callback(ok and data.id or nil, ok and nil or "decode failed")
    end)
end

function gitlab.tarball_url(url, ref)
    local repo = url:match("/([^/]+)$")
    return url .. "/-/archive/" .. ref .. "/" .. repo .. "-" .. ref .. ".tar.gz"
end

function gitlab.raw_url(url, ref, path)
    return url .. "/-/raw/" .. ref .. "/" .. path
end

-- ---------------------------------------------------------------------------
-- Generic fallback adapter (git CLI, works for any host)
-- tarball_url / raw_url return nil → callers use git clone / git archive
-- ---------------------------------------------------------------------------
local generic = {}

function generic.latest_tag(url, callback)
    vim.system(
        {
            "git", "-c", "versionsort.suffix=-",
            "ls-remote", "--tags", "--refs", "--sort=v:refname", url,
        },
        { text = true },
        function(r)
            if r.code ~= 0 then
                return callback(nil, r.stderr)
            end
            local lines = vim.split(vim.trim(r.stdout), "\n")
            for i = #lines, 1, -1 do
                local tag = lines[i]:match("\trefs/tags/(v[%d%.]+)$")
                if tag then
                    return callback(tag, nil)
                end
            end
            callback(nil, "no semver tags found")
        end
    )
end

function generic.latest_head(url, branch, callback)
    local cmd = { "git", "ls-remote", url }
    if branch then
        cmd[#cmd + 1] = "refs/heads/" .. branch
    end
    vim.system(cmd, { text = true }, function(r)
        if r.code ~= 0 then
            return callback(nil, r.stderr)
        end
        local lines = vim.split(vim.trim(r.stdout), "\n")
        local target = branch and ("refs/heads/" .. branch) or "HEAD"
        for _, line in ipairs(lines) do
            local sha, ref = line:match("^(%x+)\t(.+)$")
            if sha and ref == target then
                return callback(sha, nil)
            end
        end
        local sha = vim.split(lines[1] or "", "\t")[1]
        callback(sha ~= "" and sha or nil, sha == "" and "empty response" or nil)
    end)
end

function generic.tarball_url(_url, _ref)
    return nil
end

function generic.raw_url(_url, _ref, _path)
    return nil
end

-- ---------------------------------------------------------------------------
-- Adapter registry + resolver
-- ---------------------------------------------------------------------------

M._adapters = {
    ["github.com"] = github,
    ["gitlab.com"] = gitlab,
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

-- Export github_token for reuse by other modules (e.g. treesitter-registry.lua)
M.github_token = github_token

-- Codeberg (Gitea) registered as a convenience — same API shape as GitHub
M.register("codeberg.org", {
    latest_tag = function(url, cb)
        local owner, repo = owner_repo(url)
        if not owner then
            return cb(nil, "parse error")
        end
        local api = string.format("https://codeberg.org/api/v1/repos/%s/%s/tags", owner, repo)
        http_get(api, {}, function(body, err)
            if not body then
                return cb(nil, err)
            end
            local ok, tags = pcall(vim.json.decode, body)
            cb(ok and latest_semver(tags) or nil, nil)
        end)
    end,
    latest_head = function(url, branch, cb)
        local owner, repo = owner_repo(url)
        local ref = branch or "HEAD"
        local api = string.format(
            "https://codeberg.org/api/v1/repos/%s/%s/commits?sha=%s&limit=1",
            owner, repo, ref
        )
        http_get(api, {}, function(body, err)
            if not body then
                return cb(nil, err)
            end
            local ok, data = pcall(vim.json.decode, body)
            cb(ok and data[1] and data[1].sha or nil, nil)
        end)
    end,
    tarball_url = function(url, ref)
        return url .. "/archive/" .. ref .. ".tar.gz"
    end,
    raw_url = function(url, ref, path)
        return url .. "/raw/branch/" .. ref .. "/" .. path
    end,
})

return M
