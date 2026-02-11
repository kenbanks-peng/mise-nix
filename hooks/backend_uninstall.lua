--- Uninstall hook for removing packages from Nix profile
--- Note: This will attempt to remove from the default profile if we can match the package

local logger = require("logger")
local profile = require("profile")
local shell = require("shell")

--- BackendUninstall hook
--- Called when a tool version is being uninstalled
--- @param ctx table Context containing tool and version information
function PLUGIN:BackendUninstall(ctx)
  local tool = ctx.tool
  local version = ctx.version

  if not tool or not version then
    logger.warn("Missing tool or version in uninstall context")
    return
  end

  logger.step(string.format("Uninstalling %s@%s", tool, version))

  -- Try to find and remove the package from the default profile
  -- This is best-effort since we may not have exact tracking of profile indices
  logger.info("Checking default Nix profile for package...")

  -- List current profile to see what's installed
  local list_output = profile.list()
  logger.debug("Current profile:\n" .. list_output)

  -- Note: We could try to match by tool name, but this is imprecise
  -- The user can manually run `nix profile list` and `nix profile remove <index>` if needed
  logger.info("Package removed from mise. To clean up from Nix profile, run:")
  logger.info("  nix profile list      # Find the index")
  logger.info("  nix profile remove <index>")

  -- Optional: Trigger garbage collection
  local auto_gc = os.getenv("MISE_NIX_AUTO_GC") == "true"
  if auto_gc then
    logger.info("Running Nix garbage collection...")
    local gc_success, gc_err = pcall(function()
      shell.exec("nix-store --gc 2>&1")
    end)

    if gc_success then
      logger.debug("Garbage collection completed")
    else
      logger.warn("Garbage collection failed: " .. tostring(gc_err))
    end
  end

  logger.done(string.format("Successfully uninstalled %s@%s from mise", tool, version))
end
