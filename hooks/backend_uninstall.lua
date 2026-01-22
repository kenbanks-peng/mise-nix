-- mise-nix uninstaller
-- Handles cleanup when packages are uninstalled via mise

local profile = require("profile")
local vscode = require("vscode")
local jetbrains = require("jetbrains")
local logger = require("logger")

function PLUGIN:BackendUninstall(ctx)
  local tool = ctx.tool
  local version = ctx.version

  -- Skip for VSCode extensions (they don't use profile registration)
  if vscode.is_extension(tool) then
    logger.debug("Skipping profile cleanup for VSCode extension: " .. tool)
    return
  end

  -- Skip for JetBrains plugins (they don't use profile registration)
  if jetbrains.is_plugin(tool) then
    logger.debug("Skipping profile cleanup for JetBrains plugin: " .. tool)
    return
  end

  -- Remove from nix profile
  local entry_name = profile.get_entry_name(tool, version)
  logger.step("Removing " .. tool .. "@" .. version .. " from nix profile...")

  if profile.has_entry(entry_name) then
    local ok = profile.remove(entry_name)
    if ok then
      logger.done("Removed from nix profile: " .. entry_name)
    else
      logger.warn("Could not remove from nix profile: " .. entry_name)
    end
  else
    logger.debug("Entry not found in profile: " .. entry_name)
  end
end
