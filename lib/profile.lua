-- Nix profile management for mise-nix
-- Provides wrapper functions around `nix profile` commands for proper package management

local shell = require("shell")
local logger = require("logger")
local platform = require("platform")

local M = {}

-- Get the profile path for mise-nix managed packages
function M.get_profile_path()
  local state_dir = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
  return state_dir .. "/mise-nix/profile"
end

-- Generate a sanitized entry name for a tool@version
function M.get_entry_name(tool, version)
  -- Sanitize tool and version for nix profile naming
  local safe_tool = tool:gsub("[^%w%-_]", "-")
  local safe_version = version:gsub("[^%w%-_.]", "-")
  return "mise." .. safe_tool .. "." .. safe_version
end

-- Ensure profile directory exists
function M.ensure_profile_dir()
  local profile_path = M.get_profile_path()
  local profile_dir = profile_path:match("^(.+)/[^/]+$")
  if profile_dir then
    shell.try_exec('mkdir -p "%s"', profile_dir)
  end
end

-- Install a package to the profile
-- Returns the store paths from the installation
function M.install(flake_ref, entry_name)
  M.ensure_profile_dir()
  local profile_path = M.get_profile_path()

  local env_prefix = platform.get_env_prefix()
  local impure_flag = platform.get_impure_flag()

  -- Use nix profile install with the profile path
  local cmdline = string.format(
    '%snix profile install %s--profile "%s" "%s"',
    env_prefix, impure_flag, profile_path, flake_ref
  )

  logger.step("Installing " .. flake_ref .. " to profile...")
  logger.debug("Command: " .. cmdline)

  local ok, result = shell.try_exec(cmdline)
  if not ok then
    error("Failed to install package to profile: " .. (result or "unknown error"))
  end

  return true
end

-- Remove a package from the profile by entry pattern
function M.remove(entry_pattern)
  local profile_path = M.get_profile_path()

  -- First check if the profile exists
  local profile_exists = shell.try_exec('test -L "%s"', profile_path)
  if not profile_exists then
    logger.debug("Profile does not exist, nothing to remove")
    return true
  end

  -- Use nix profile remove with a regex pattern
  local cmdline = string.format(
    'nix profile remove --profile "%s" ".*%s.*" 2>&1 || true',
    profile_path, entry_pattern:gsub("%.", "\\.")
  )

  logger.step("Removing from profile: " .. entry_pattern)
  logger.debug("Command: " .. cmdline)

  shell.try_exec(cmdline)
  return true
end

-- List all entries in the profile
-- Returns a table of entries with their store paths
function M.list()
  local profile_path = M.get_profile_path()

  -- Check if profile exists
  local profile_exists = shell.try_exec('test -L "%s"', profile_path)
  if not profile_exists then
    return {}
  end

  local cmdline = string.format('nix profile list --json --profile "%s" 2>/dev/null', profile_path)
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
  local profile_path = M.get_profile_path()

  local cmdline = string.format('nix profile list --json --profile "%s" 2>/dev/null', profile_path)
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

-- Check if an entry pattern exists in the profile
function M.has_entry(entry_pattern)
  local _, raw_json = M.list()
  if not raw_json then return false end

  -- Check if the pattern appears in the profile
  return raw_json:match(entry_pattern:gsub("%.", "%%.")) ~= nil
end

-- Get store path by building with nix profile install and reading back
-- This is the main function used during installation
function M.install_and_get_store_path(flake_ref)
  M.ensure_profile_dir()
  local profile_path = M.get_profile_path()

  local env_prefix = platform.get_env_prefix()
  local impure_flag = platform.get_impure_flag()

  -- Build using nix build first to get the store path directly
  -- This is more reliable than parsing nix profile list output
  local build_cmdline = string.format(
    '%snix build %s--no-link --print-out-paths "%s"',
    env_prefix, impure_flag, flake_ref
  )

  logger.step("Building " .. flake_ref .. "...")
  logger.debug("Build command: " .. build_cmdline)

  local build_ok, build_result = shell.try_exec(build_cmdline)
  if not build_ok or not build_result or build_result == "" then
    error("Failed to build package: " .. (build_result or "unknown error"))
  end

  -- Parse outputs from nix build
  local outputs = {}
  for path in build_result:gmatch("[^\n]+") do
    if path:match("^/nix/store/") then
      table.insert(outputs, path)
    end
  end

  if #outputs == 0 then
    error("No outputs returned by nix build for: " .. flake_ref)
  end

  -- Now install to profile for proper registration
  local install_cmdline = string.format(
    '%snix profile install %s--profile "%s" "%s" 2>&1',
    env_prefix, impure_flag, profile_path, flake_ref
  )

  logger.step("Registering in profile...")
  logger.debug("Install command: " .. install_cmdline)

  local install_ok, install_result = shell.try_exec(install_cmdline)
  if not install_ok then
    -- Installation might fail if already installed, which is fine
    logger.debug("Profile install result: " .. (install_result or ""))
  end

  return outputs
end

return M
