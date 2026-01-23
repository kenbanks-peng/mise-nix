-- Nix profile management for mise-nix
-- Provides wrapper functions around `nix profile` commands for proper package management

local shell = require("shell")
local logger = require("logger")
local platform = require("platform")

local M = {}

-- Get the default nix profile path
function M.get_profile_path()
  return os.getenv("HOME") .. "/.nix-profile"
end

-- Generate a sanitized entry name for a tool@version
function M.get_entry_name(tool, version)
  -- Sanitize tool and version for nix profile naming
  local safe_tool = tool:gsub("[^%w%-_]", "-")
  local safe_version = version:gsub("[^%w%-_.]", "-")
  return "mise." .. safe_tool .. "." .. safe_version
end

-- Install a package to the profile
-- Returns the store paths from the installation
function M.install(flake_ref, entry_name)
  local env_prefix = platform.get_env_prefix()
  local impure_flag = platform.get_impure_flag()

  -- Use nix profile install (uses default profile)
  local cmdline = string.format(
    '%snix profile install %s"%s"',
    env_prefix, impure_flag, flake_ref
  )

  logger.step("Installing " .. flake_ref .. " to profile...")
  logger.debug("Command: " .. cmdline)

  local ok, result = shell.try_exec(cmdline)
  if not ok then
    error("Failed to install package to profile: " .. tostring(result or "unknown error"))
  end

  return true
end

-- Remove a package from the profile by entry pattern (legacy - use remove_by_tool instead)
function M.remove(entry_pattern)
  local profile_path = M.get_profile_path()

  -- First check if the profile exists
  local profile_exists = shell.try_exec('[ -L "%s" ]', profile_path)
  if not profile_exists then
    logger.debug("Profile does not exist, nothing to remove")
    return true
  end

  -- Use nix profile remove with a regex pattern (uses default profile)
  local cmdline = string.format(
    'nix profile remove ".*%s.*" 2>&1 || true',
    entry_pattern:gsub("%.", "\\.")
  )

  logger.step("Removing from profile: " .. entry_pattern)
  logger.debug("Command: " .. cmdline)

  shell.try_exec(cmdline)
  return true
end

-- Remove a package from the profile by tool name
-- This matches the actual entry names nix uses (e.g., "hello", "hello-1")
function M.remove_by_tool(tool_name)
  local profile_path = M.get_profile_path()

  -- First check if the profile exists
  local profile_exists = shell.try_exec('[ -L "%s" ]', profile_path)
  if not profile_exists then
    logger.debug("Profile does not exist, nothing to remove")
    return true
  end

  -- Nix profile entry names are based on the attribute path's last component
  -- e.g., "hello", and duplicates become "hello-1", "hello-2", etc.
  -- Use regex to match: ^hello$ or ^hello-[0-9]+$
  local escaped_name = tool_name:gsub("([%.%+%[%]%(%)%$%^])", "\\%1")
  local pattern = string.format("^%s(-[0-9]+)?$", escaped_name)

  -- Use default profile
  local cmdline = string.format(
    'nix profile remove "%s" 2>&1',
    pattern
  )

  logger.step("Removing from profile: " .. tool_name)
  logger.debug("Command: " .. cmdline)

  local ok, result = shell.try_exec(cmdline)
  if not ok then
    logger.debug("Remove result: " .. tostring(result or ""))
  end
  return true
end

-- List all entries in the profile
-- Returns a table of entries with their store paths
function M.list()
  local profile_path = M.get_profile_path()

  -- Check if profile exists
  local profile_exists = shell.try_exec('[ -L "%s" ]', profile_path)
  if not profile_exists then
    return {}
  end

  -- Use default profile
  local cmdline = 'nix profile list --json 2>/dev/null'
  local ok, result = shell.try_exec(cmdline)

  if not ok or not result or result == "" then
    return {}
  end

  -- Parse JSON output
  -- The format is: {"elements": {"<name>": {"active": true, "storePaths": [...], ...}}}
  local entries = {}

  -- Simple JSON parsing for the structure we need
  -- Look for storePaths arrays
  for store_path in result:gmatch('"(/nix/store/[^"]+)"') do
    table.insert(entries, { store_path = store_path })
  end

  return entries, result
end

-- Get store path for the most recently installed package
-- After nix profile install, we need to find the store path for our package
function M.get_store_path_for_flake(flake_ref)
  -- Use default profile
  local cmdline = 'nix profile list --json 2>/dev/null'
  local ok, result = shell.try_exec(cmdline)

  if not ok or not result or result == "" then
    return nil
  end

  -- Parse the JSON to find store paths
  -- The profile list output contains "storePaths" for each element
  -- We want to find the path that corresponds to our flake ref

  -- Extract all store paths from the JSON
  local store_paths = {}
  for store_path in result:gmatch('"(/nix/store/[^"]+)"') do
    -- Skip paths that are clearly not the package output (like -source, -go-modules, etc)
    if not store_path:match("%-source$") and
       not store_path:match("%-go%-modules$") and
       not store_path:match("%-vendor$") then
      table.insert(store_paths, store_path)
    end
  end

  -- Return the most recently added (last) store path
  if #store_paths > 0 then
    return store_paths[#store_paths]
  end

  return nil
end

-- Check if an entry pattern exists in the profile (legacy - use has_entry_for_tool instead)
function M.has_entry(entry_pattern)
  local _, raw_json = M.list()
  if not raw_json then return false end

  -- Check if the pattern appears in the profile
  return raw_json:match(entry_pattern:gsub("%.", "%%.")) ~= nil
end

-- Check if an entry for the tool exists in the profile
-- This matches the actual entry names nix uses (e.g., "hello", "hello-1")
function M.has_entry_for_tool(tool_name)
  local _, raw_json = M.list()
  if not raw_json then return false end

  -- Check if the tool name appears as a key in the elements
  -- Matches "hello": or "hello-1": etc.
  local escaped_name = tool_name:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  local pattern = '"' .. escaped_name .. '":'
  local pattern_numbered = '"' .. escaped_name .. '%-[0-9]+":'
  return raw_json:match(pattern) ~= nil or raw_json:match(pattern_numbered) ~= nil
end

-- Check if a flake reference is already installed in the profile
-- Returns the store path if installed, nil otherwise
function M.get_installed_store_path(flake_ref)
  local _, raw_json = M.list()
  if not raw_json then return nil end

  -- Parse JSON to find matching flake reference
  -- nix profile list --json includes "url" or "originalUrl" for each element
  -- We check if our flake_ref matches (accounting for partial matches like short commit hashes)

  -- Extract the attribute path from the flake_ref (e.g., "hello" from "github:NixOS/nixpkgs/abc#hello")
  local attr = flake_ref:match("#([^#]+)$")

  -- Try to find an element with matching URL/originalUrl
  -- The JSON structure is: {"elements": {"name": {"url": "...", "storePaths": [...]}}}

  -- Look for originalUrl matches first (more reliable), then url
  for url_field in raw_json:gmatch('"originalUrl"%s*:%s*"([^"]+)"') do
    if M._flake_refs_match(flake_ref, url_field) then
      -- Found a match, extract the corresponding store path
      -- We need to find the store path in the same element block
      -- For simplicity, we'll search for storePaths near this URL
      local store_path = M._extract_store_path_for_url(raw_json, url_field)
      if store_path then
        return store_path
      end
    end
  end

  -- Also check "url" field
  for url_field in raw_json:gmatch('"url"%s*:%s*"([^"]+)"') do
    if M._flake_refs_match(flake_ref, url_field) then
      local store_path = M._extract_store_path_for_url(raw_json, url_field)
      if store_path then
        return store_path
      end
    end
  end

  return nil
end

-- Check if two flake references match (accounting for short vs full commit hashes)
-- Note: nix profile stores originalUrl WITHOUT the #attr part, so we allow matching
-- when one ref has an attribute and the other doesn't
function M._flake_refs_match(ref1, ref2)
  -- Exact match
  if ref1 == ref2 then return true end

  -- Extract components: base URL, revision, and attribute
  local function parse_flake_ref(ref)
    local attr = ref:match("#([^#]+)$") or ""
    local base = ref:gsub("#[^#]+$", "")
    -- Extract commit/rev from the base (after last /)
    local rev = base:match("/([a-fA-F0-9]+)$")
    local url_base = base:gsub("/[a-fA-F0-9]+$", "")
    return { url_base = url_base, rev = rev, attr = attr, full = ref }
  end

  local p1 = parse_flake_ref(ref1)
  local p2 = parse_flake_ref(ref2)

  -- URL bases must match
  if p1.url_base ~= p2.url_base then return false end

  -- Attributes must match, unless one is empty (nix profile stores URL without #attr)
  if p1.attr ~= "" and p2.attr ~= "" and p1.attr ~= p2.attr then return false end

  -- Revisions must match (one can be a prefix of the other for short hashes)
  if p1.rev and p2.rev then
    if p1.rev:sub(1, #p2.rev) == p2.rev or p2.rev:sub(1, #p1.rev) == p1.rev then
      return true
    end
    return false
  end

  -- If one has no revision specified, they don't match (different versions)
  return false
end

-- Extract the store path associated with a URL in the profile JSON
function M._extract_store_path_for_url(json, url)
  -- Find the element block containing this URL and extract its storePaths
  -- This is a simplified parser - looks for storePaths array after the URL

  -- Escape URL for pattern matching
  local escaped_url = url:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")

  -- Find position of this URL in the JSON
  local url_pos = json:find('"' .. escaped_url .. '"')
  if not url_pos then return nil end

  -- Look for storePaths after this position (within a reasonable range)
  local search_range = json:sub(url_pos, url_pos + 2000)
  local store_path = search_range:match('"storePaths"%s*:%s*%[%s*"(/nix/store/[^"]+)"')

  return store_path
end

-- Install to profile and get the store path
-- This is the main function used during installation
function M.install_and_get_store_path(flake_ref)
  -- Check if this flake reference is already installed in the profile
  local existing_store_path = M.get_installed_store_path(flake_ref)
  if existing_store_path then
    logger.step("Already installed in profile: " .. flake_ref)
    logger.debug("Existing store path: " .. existing_store_path)
    return { existing_store_path }
  end

  local env_prefix = platform.get_env_prefix()
  local impure_flag = platform.get_impure_flag()

  -- Install to profile (builds and registers in one step)
  local install_cmdline = string.format(
    '%snix profile install %s"%s" 2>&1',
    env_prefix, impure_flag, flake_ref
  )

  logger.step("Installing " .. flake_ref .. "...")
  logger.debug("Install command: " .. install_cmdline)

  local install_ok, install_result = shell.try_exec(install_cmdline)
  if not install_ok then
    error("Failed to install package: " .. tostring(install_result or "unknown error"))
  end

  -- Get the store path from the profile
  local store_path = M.get_installed_store_path(flake_ref)
  if not store_path then
    error("Package installed but store path not found in profile")
  end

  logger.debug("Store path: " .. store_path)
  return { store_path }
end

return M
