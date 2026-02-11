-- mise-nix installer (modular refactored version)
-- Main installation hook - delegates to specialized modules

local platform = require("platform")
local vscode = require("vscode")
local jetbrains = require("jetbrains")
local neovim = require("neovim")
local flake = require("flake")
local install = require("install")
local vsix = require("vsix")

-- Check if package is already installed
local function is_already_installed(tool, install_path)
  -- For VSCode extensions
  if vscode.is_extension(tool) then
    local ext_id = vscode.extract_extension_id(tool)
    if ext_id then
      -- Check if extension is installed in VSCode
      local ok, output = pcall(function()
        return os.execute("code --list-extensions 2>/dev/null | grep -i '" .. ext_id:gsub("%.", "%.") .. "' >/dev/null 2>&1")
      end)
      return ok and output == 0
    end
    return false
  end

  -- For JetBrains plugins
  if jetbrains.is_plugin(tool) then
    local plugin_info = jetbrains.extract_plugin_info(tool)
    if plugin_info then
      local plugins_dir = jetbrains.get_plugins_dir(plugin_info.ide, plugin_info.version)
      -- Check for JAR files or plugin directory
      local jar_exists = os.execute(string.format('find "%s" -name "*%s*.jar" 2>/dev/null | grep -q .',
        plugins_dir, plugin_info.plugin_id:gsub("%.", "%%."))) == 0
      local dir_exists = os.execute(string.format('test -d "%s/%s"', plugins_dir, plugin_info.plugin_id)) == 0
      return jar_exists or dir_exists
    end
    return false
  end

  -- For Neovim plugins
  if neovim.is_plugin(tool) then
    local plugin_name = neovim.extract_plugin_name(tool)
    if plugin_name then
      local plugins_dir = neovim.get_plugins_dir()
      local plugin_path = plugins_dir .. "/" .. plugin_name
      return os.execute(string.format('test -L "%s" -o -d "%s"', plugin_path, plugin_path)) == 0
    end
    return false
  end

  -- For standard tools (check if symlink or directory exists at install_path)
  if install_path and install_path ~= "" then
    return os.execute(string.format('test -e "%s"', install_path)) == 0
  end

  return false
end

function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool
  local requested_version = ctx.version
  local install_path = ctx.install_path

  platform.check_nix_available()

  -- VERIFICATION 1: Check if package is available
  local list_ctx = { tool = tool, version = requested_version }
  local versions_result = self:BackendListVersions(list_ctx)

  if not versions_result or not versions_result.versions or #versions_result.versions == 0 then
    error(string.format("Package '%s' is not available or not found in nixpkgs", tool))
  end

  -- VERIFICATION 2: Check if already installed
  if is_already_installed(tool, install_path) then
    -- Determine the actual version (use requested or "latest" if not specified)
    local installed_version = requested_version and requested_version ~= "" and requested_version or "latest"
    print(string.format("Package '%s' version '%s' is already installed", tool, installed_version))
    return { version = installed_version }
  end

  local result

  -- Route to appropriate installation strategy
  if vscode.is_extension(tool) then
    -- VSCode extensions: treat as flake references
    local flake_ref = tool:match("^vscode%-extensions%.") and ("nixpkgs#" .. tool) or tool
    result = install.from_flake(flake_ref, requested_version, install_path)

  elseif jetbrains.is_plugin(tool) then
    -- JetBrains plugins: build flake reference to nix-jetbrains-plugins
    local plugin_info = jetbrains.extract_plugin_info(tool)
    if plugin_info then
      -- Build the flake reference based on the nix-jetbrains-plugins structure
      -- The correct path is: plugins.<system>.<ide>.<version>."<plugin_id>"
      local flake_ref = string.format("github:theCapypara/nix-jetbrains-plugins#plugins.%s.%s.\"%s\".\"%s\"",
        plugin_info.system, plugin_info.ide, plugin_info.version, plugin_info.plugin_id)
      -- Build the plugin and then install it to the JetBrains plugin directory
      local build_result = vsix.from_flake(flake_ref, "")
      local nix_store_path = vsix.choose_best_output(build_result.outputs, flake_ref)
      platform.verify_build(nix_store_path, flake_ref)
      jetbrains.install_plugin_from_store(nix_store_path, tool)
      result = {
        version = build_result.version,
        store_path = nix_store_path,
        is_jetbrains = true
      }
    else
      error("Invalid JetBrains plugin format: " .. tool)
    end

  elseif neovim.is_plugin(tool) then
    -- Neovim plugins: build from nixpkgs vimPlugins and install to pack directory
    local flake_ref = neovim.extract_flake_ref(tool)
    local build_result = vsix.from_flake("nixpkgs#" .. flake_ref, requested_version or "")
    local nix_store_path = vsix.choose_best_output(build_result.outputs, flake_ref)
    platform.verify_build(nix_store_path, flake_ref)
    neovim.install_plugin_from_store(nix_store_path, tool)
    result = {
      version = build_result.version,
      store_path = nix_store_path,
      is_neovim = true
    }

  elseif flake.is_reference(tool) then
    result = install.from_flake(tool, requested_version, install_path)

  elseif flake.is_reference(requested_version) then
    result = install.from_flake(requested_version, "", install_path)

  else
    result = install.from_nixhub(tool, requested_version, install_path)
  end

  return { version = result.version }
end