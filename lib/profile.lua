--- Profile management using Nix's default profile
--- All packages are installed via `nix profile install` to the default profile

local M = {}

local shell = require("shell")
local platform = require("platform")
local logger = require("logger")

--- Get the default Nix profile path
--- @return string The default profile path
local function get_default_profile_path()
  local home = os.getenv("HOME")
  if not home then
    error("HOME environment variable not set")
  end
  return home .. "/.nix-profile"
end

--- Get the default profile manifest path
--- @return string The manifest.json path
local function get_manifest_path()
  return get_default_profile_path() .. "/manifest.json"
end

--- Parse JSON content (simple implementation for manifest.json)
--- @param json_str string The JSON string to parse
--- @return table The parsed JSON object
local function parse_json(json_str)
  -- Try to use built-in JSON support if available
  if json and json.decode then
    return json.decode(json_str)
  end

  -- Fallback: Use Nix to parse JSON
  local temp_file = os.tmpname()
  local temp_out = os.tmpname()

  local f = io.open(temp_file, "w")
  if not f then
    error("Failed to create temporary file for JSON parsing")
  end
  f:write(json_str)
  f:close()

  -- Use nix eval to parse JSON
  local cmd = string.format(
    'nix eval --impure --raw --expr \'builtins.toJSON (builtins.fromJSON (builtins.readFile "%s"))\' > "%s"',
    temp_file, temp_out
  )

  pcall(function()
    shell.exec(cmd)
  end)

  -- Read the output and parse manually
  local out_f = io.open(temp_out, "r")
  if not out_f then
    os.remove(temp_file)
    os.remove(temp_out)
    error("Failed to parse JSON")
  end

  local content = out_f:read("*all")
  out_f:close()

  os.remove(temp_file)
  os.remove(temp_out)

  -- Basic JSON parsing for our specific manifest structure
  local result = {}

  -- Extract elements array
  local elements_match = content:match('"elements"%s*:%s*%[(.-)%]')
  if elements_match then
    result.elements = {}

    -- Parse each element
    local element_index = 1
    for element_str in elements_match:gmatch("%b{}") do
      result.elements[element_index] = {}

      -- Extract storePaths
      local store_paths_match = element_str:match('"storePaths"%s*:%s*%[([^%]]+)%]')
      if store_paths_match then
        result.elements[element_index].storePaths = {}
        for path in store_paths_match:gmatch('"([^"]+)"') do
          table.insert(result.elements[element_index].storePaths, path)
        end
      end

      -- Extract url (for matching)
      local url_match = element_str:match('"url"%s*:%s*"([^"]+)"')
      if url_match then
        result.elements[element_index].url = url_match
      end

      element_index = element_index + 1
    end
  end

  return result
end

--- Read and parse the default profile manifest
--- @return table|nil The parsed manifest, or nil if not found
function M.get_manifest()
  local manifest_file = get_manifest_path()

  local f = io.open(manifest_file, "r")
  if not f then
    return nil
  end

  local content = f:read("*all")
  f:close()

  if not content or content == "" then
    return nil
  end

  local success, manifest = pcall(function()
    return parse_json(content)
  end)

  if not success then
    logger.warn("Failed to parse manifest.json: " .. tostring(manifest))
    return nil
  end

  return manifest
end

--- Find the store path for a specific flake reference in the manifest
--- @param flake_ref string The flake reference to search for
--- @return string|nil The store path, or nil if not found
--- @return number|nil The element index in the profile
function M.find_store_path_for_flake(flake_ref)
  local manifest = M.get_manifest()

  if not manifest or not manifest.elements then
    return nil, nil
  end

  -- Normalize the flake ref for comparison
  local normalized_ref = flake_ref:gsub("^github:", "github.com/")
                                  :gsub("^gitlab:", "gitlab.com/")

  -- Search through manifest elements
  for i, element in ipairs(manifest.elements) do
    if element.url then
      local normalized_url = element.url:gsub("^github:", "github.com/")
                                       :gsub("^gitlab:", "gitlab.com/")

      -- Check if URLs match (accounting for different formats)
      if normalized_url:find(normalized_ref, 1, true) or
         normalized_ref:find(normalized_url, 1, true) then
        if element.storePaths and #element.storePaths > 0 then
          return element.storePaths[1], i - 1  -- Nix uses 0-based indexing
        end
      end
    end
  end

  return nil, nil
end

--- Install a package using nix profile install
--- @param flake_ref string The flake reference to install
--- @return string The store path of the installed package
--- @return number The profile element index
function M.install(flake_ref)
  logger.debug("Installing to default profile: " .. flake_ref)

  -- Check if already installed in containerized environments
  if shell.is_containerized() then
    local existing_path, existing_index = M.find_store_path_for_flake(flake_ref)
    if existing_path then
      logger.debug("Package already installed in default profile")
      return existing_path, existing_index
    end
  end

  -- Build nix profile install command (no --profile flag, uses default)
  local env_prefix = platform.get_env_prefix()
  local impure_flag = platform.get_impure_flag()

  local cmd = string.format(
    '%snix profile install %s"%s" 2>&1',
    env_prefix,
    impure_flag,
    flake_ref
  )

  logger.debug("Running: " .. cmd)

  local output = shell.exec(cmd)
  logger.debug("Profile install output: " .. (output or ""))

  -- Find the newly installed package in the manifest
  local store_path, index = M.find_store_path_for_flake(flake_ref)

  if not store_path then
    error("Failed to find store path in profile after installation: " .. flake_ref)
  end

  -- Validate store path exists
  local validate_cmd = string.format('test -e "%s"', store_path)
  local success = pcall(function()
    shell.exec(validate_cmd)
  end)

  if not success then
    error("Store path from profile does not exist: " .. store_path)
  end

  logger.debug("Store path from profile: " .. store_path)

  return store_path, index
end

--- Remove a package from the default profile by index
--- @param index number The profile element index (0-based)
function M.remove(index)
  if not index then
    logger.debug("No profile index provided, skipping removal")
    return
  end

  logger.debug("Removing profile element at index: " .. index)

  local cmd = string.format('nix profile remove %d 2>&1', index)

  local success, err = pcall(function()
    shell.exec(cmd)
  end)

  if not success then
    logger.warn("Failed to remove from profile: " .. tostring(err))
  end
end

--- List all packages in the default profile
--- @return string The output from nix profile list
function M.list()
  local cmd = "nix profile list 2>&1"
  local output = shell.exec(cmd)
  return output or ""
end

return M
