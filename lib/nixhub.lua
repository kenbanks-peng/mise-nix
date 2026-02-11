-- Nixhub.io API integration for package metadata
local http = require("http")
local json = require("json")

local M = {}

-- Simple in-memory cache to avoid redundant network calls during installation
local metadata_cache = {}
local cache_ttl = 300 -- 5 minutes

-- Get the base URL for nixhub API
function M.get_base_url()
  return os.getenv("MISE_NIX_NIXHUB_BASE_URL") or "https://www.nixhub.io"
end

-- Fetch tool metadata from nixhub.io
function M.fetch_metadata(tool)
  -- Check cache first
  local cached = metadata_cache[tool]
  if cached and (os.time() - cached.timestamp) < cache_ttl then
    return cached.success, cached.data, cached.response
  end

  -- Cache miss or expired - fetch from network
  local url = M.get_base_url() .. "/packages/" .. tool .. "?_data=routes%2F_nixhub.packages.%24pkg._index"

  -- Use native HTTP module
  local resp, err = http.get({
    url = url,
    headers = {
      ['User-Agent'] = 'mise-nix'
    },
    timeout = 30000  -- 30 second timeout to prevent hanging
  })

  if err ~= nil then
    return false, nil, "HTTP request failed: " .. err
  end

  if resp.status_code ~= 200 then
    return false, nil, "HTTP error: " .. resp.status_code
  end

  if not resp.body or resp.body == "" then
    return false, nil, "Empty response from nixhub.io"
  end

  local success, data = pcall(json.decode, resp.body)

  -- Cache the result
  metadata_cache[tool] = {
    success = success,
    data = data,
    response = resp.body,
    timestamp = os.time()
  }

  return success, data, resp.body
end

-- Validate that metadata fetch was successful and contains expected data
function M.validate_metadata(success, data, tool, response)
  if not success or not data or not data.releases then
    -- Create a more user-friendly error message
    local error_msg = "Package not found: " .. tool .. " at https://nixhub.io. Search for available packages at https://search.nixos.org/packages"
    
    -- Only include response details if they're meaningful
    if response and response:match("^{") then
      -- It's JSON, try to extract just the message
      local message = response:match('"message":"([^"]+)"')
      if message and message ~= "Unexpected Server Error" then
        error_msg = "Package not found: " .. tool .. " (" .. message .. ") at https://nixhub.io. Search for available packages at https://search.nixos.org/packages"
      end
    elseif response and #response > 0 and #response < 200 then
      -- Short, potentially useful response
      error_msg = "Package not found: " .. tool .. " (" .. response .. ") at https://nixhub.io. Search for available packages at https://search.nixos.org/packages"
    end
    
    error(error_msg)
  end
end

return M