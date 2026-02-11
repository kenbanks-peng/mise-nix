-- mise-nix installer (modular refactored version)
-- Main installation hook - delegates to specialized modules

local platform = require("platform")
local vscode = require("vscode")
local jetbrains = require("jetbrains")
local neovim = require("neovim")
local flake = require("flake")
local install = require("install")
local vsix = require("vsix")
local logger = require("logger")

function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool
  local requested_version = ctx.version
  local install_path = ctx.install_path

  -- STAGE 1: Check Nix availability
  logger.step(string.format("Installing %s%s...", tool, requested_version and "@" .. requested_version or ""))
  logger.info("Checking Nix availability...")
  platform.check_nix_available()

  -- STAGE 2: Check if package is available
  logger.info("Verifying package availability...")
  local list_ctx = { tool = tool, version = requested_version }
  local versions_result = self:BackendListVersions(list_ctx)

  if not versions_result or not versions_result.versions or #versions_result.versions == 0 then
    error(string.format("Package '%s' is not available or not found in nixpkgs", tool))
  end
  logger.done("Package is available")

  local result

  -- STAGE 3: Determine installation type and route to appropriate strategy
  if vscode.is_extension(tool) then
    logger.find("Detected VSCode extension")
    -- VSCode extensions: treat as flake references
    local flake_ref = tool:match("^vscode%-extensions%.") and ("nixpkgs#" .. tool) or tool
    result = install.from_flake(flake_ref, requested_version, install_path)

  elseif jetbrains.is_plugin(tool) then
    logger.find("Detected JetBrains plugin")
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
    logger.find("Detected Neovim plugin")
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
    logger.find("Detected flake reference")
    result = install.from_flake(tool, requested_version, install_path)

  elseif flake.is_reference(requested_version) then
    logger.find("Detected flake reference in version")
    result = install.from_flake(requested_version, "", install_path)

  else
    logger.info("Installing from nixpkgs via nixhub metadata")
    result = install.from_nixhub(tool, requested_version, install_path)
  end

  logger.done(string.format("Installation complete: %s@%s", tool, result.version))
  return { version = result.version }
end