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
  -- Try to use built-in JSON support if available (mise has json module)
  local has_json, json_module = pcall(require, "json")
  if has_json and json_module and json_module.decode then
    return json_module.decode(json_str)
  end

  -- Manual parsing fallback for manifest.json structure
  local result = {}

  -- Check if elements is an array or object by looking at the first character after "elements":
  local elements_start = json_str:match('"elements"%s*:%s*([%[{])')

  if elements_start == "{" then
    -- New format: elements is an object
    result.elements = {}

    -- Extract the entire elements object
    local elements_obj = json_str:match('"elements"%s*:%s*(%b{})')
    if elements_obj then
      -- Remove outer braces
      local inner = elements_obj:sub(2, -2)

      -- Parse each package entry
      local current_pos = 1
      while current_pos < #inner do
        -- Find next package entry: "package_name":{...}
        local pkg_name_start, pkg_name_end, pkg_name = inner:find('"([^"]+)"%s*:%s*{', current_pos)
        if not pkg_name_start then break end

        -- Find the matching closing brace for this package
        local depth = 1
        local content_start = pkg_name_end + 1
        local i = content_start
        while i <= #inner and depth > 0 do
          local char = inner:sub(i, i)
          if char == "{" then
            depth = depth + 1
          elseif char == "}" then
            depth = depth - 1
          end
          i = i + 1
        end

        local pkg_content = inner:sub(content_start, i - 2)

        -- Extract url and storePaths
        local url = pkg_content:match('"url"%s*:%s*"([^"]+)"')
        local store_paths_match = pkg_content:match('"storePaths"%s*:%s*%[([^%]]+)%]')

        result.elements[pkg_name] = {}
        if url then
          result.elements[pkg_name].url = url
        end
        if store_paths_match then
          result.elements[pkg_name].storePaths = {}
          for path in store_paths_match:gmatch('"([^"]+)"') do
            table.insert(result.elements[pkg_name].storePaths, path)
          end
        end

        current_pos = i
      end
    end
  elseif elements_start == "[" then
    -- Old format: elements is an array
    local elements_match = json_str:match('"elements"%s*:%s*%[(.-)%]')
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
--- @return number|string|nil The element index (number for old format) or package name (string for new format)
function M.find_store_path_for_flake(flake_ref)
  local manifest = M.get_manifest()

  if not manifest or not manifest.elements then
    return nil, nil
  end

  -- Extract the package attribute from the flake ref (e.g., "hello" from "github:NixOS/nixpkgs/...#hello")
  local package_attr = flake_ref:match("#(.+)$")

  -- Normalize the flake ref for comparison (remove the #attribute part)
  local normalized_ref = flake_ref:gsub("#.+$", "")
                                  :gsub("^github:", "")
                                  :gsub("^gitlab:", "")
                                  :gsub("^NixOS/nixpkgs/", "")
                                  :gsub("^nixos/nixpkgs/", "")

  -- Handle new manifest format (object/dictionary) - manifest version 3+
  -- Check if elements is an object by looking for string keys
  local is_object = false
  for k, _ in pairs(manifest.elements) do
    if type(k) == "string" then
      is_object = true
      break
    end
  end

  if is_object then
    -- New format: elements is an object with package names as keys
    for name, element in pairs(manifest.elements) do
      if element.url then
        local element_url = element.url:gsub("^github:", "")
                                      :gsub("^gitlab:", "")
                                      :gsub("^NixOS/nixpkgs/", "")
                                      :gsub("^nixos/nixpkgs/", "")

        -- Check if URLs match (accounting for different formats)
        -- Match by commit hash or by package name
        if element_url:find(normalized_ref, 1, true) or
           normalized_ref:find(element_url, 1, true) or
           (package_attr and name == package_attr) then
          if element.storePaths and #element.storePaths > 0 then
            return element.storePaths[1], name
          end
        end
      end
    end
  else
    -- Old format: elements is an array
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
  end

  return nil, nil
end

--- Install a package using nix profile install
--- @param flake_ref string The flake reference to install
--- @return string The store path of the installed package
--- @return number|string|nil The profile element index (number for old format) or package name (string for new format)
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

--- Remove a package from the default profile by index or name
--- @param index number|string The profile element index (0-based) or package name
function M.remove(index)
  if not index then
    logger.debug("No profile index provided, skipping removal")
    return
  end

  logger.debug("Removing profile element: " .. tostring(index))

  -- For new manifest format, index is a package name (string)
  -- For old format, index is a number
  local cmd
  if type(index) == "string" then
    cmd = string.format('nix profile remove "%s" 2>&1', index)
  else
    cmd = string.format('nix profile remove %d 2>&1', index)
  end

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
