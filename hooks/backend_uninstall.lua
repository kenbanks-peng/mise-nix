-- mise-nix uninstaller
-- Removes from nix profile first, then from mise

local profile = require("profile")
local vscode = require("vscode")
local jetbrains = require("jetbrains")
local logger = require("logger")
local cmd = require("cmd")

-- Uninstall a package: removes from nix first, then from mise
function PLUGIN:Uninstall(tool, version)
  logger.info("HOOK CALLED: backend_uninstall.lua - Uninstall()")
  -- Skip nix profile removal for VSCode extensions (they don't use profile registration)
  if not vscode.is_extension(tool) and not jetbrains.is_plugin(tool) then
    -- Step 1: Remove from nix profile first
    logger.step("Removing " .. tool .. "@" .. version .. " from nix profile...")

    if profile.has_entry_for_tool(tool) then
      local ok = profile.remove_by_tool(tool)
      if ok then
        logger.done("Removed from nix profile: " .. tool)
      else
        logger.warn("Could not remove from nix profile: " .. tool)
      end
    else
      logger.debug("Entry not found in profile for tool: " .. tool)
    end
  end

  -- Step 2: Remove from mise
  logger.step("Removing " .. tool .. "@" .. version .. " from mise...")
  cmd.exec(string.format('mise uninstall "nix:%s@%s"', tool, version))
end
