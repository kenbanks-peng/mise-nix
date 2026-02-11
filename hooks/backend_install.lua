-- mise-nix installer (modular refactored version)
-- Main installation hook - delegates to specialized modules

local platform = require("platform")
local flake = require("flake")
local install = require("install")
local logger = require("logger")

function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool
  local requested_version = ctx.version
  local install_path = ctx.install_path

  -- STAGE 1: Check Nix availability
  logger.step(string.format("Installing %s%s...", tool, requested_version and "@" .. requested_version or ""))
  logger.info("Checking Nix availability...")
  platform.check_nix_available()

  -- STAGE 2: Check if already installed by mise
  -- Check if the install_path symlink exists and points to a valid nix store path
  local shell = require("shell")
  local ok, current_target = shell.try_exec('readlink "%s" 2>/dev/null', install_path)
  if ok and current_target and current_target ~= "" then
    current_target = current_target:gsub("\n", "")
    -- Verify the target actually exists
    local target_exists = shell.try_exec('test -e "%s"', current_target)
    if target_exists then
      -- If a specific version was requested, verify it matches
      if requested_version and requested_version ~= "" and requested_version ~= "latest" then
        if not current_target:find(requested_version, 1, true) then
          logger.info("Different version already installed, proceeding with requested version")
        else
          logger.info("Requested version already installed and verified")
          return { version = requested_version }
        end
      else
        logger.info("Tool already installed and verified")
        -- Extract version from the store path
        local version_match = current_target:match("%-(%d+[%.%d]+)") or "installed"
        return { version = version_match }
      end
    end
  end

  -- Note: Package availability is already verified by mise calling BackendListVersions before install

  local result

  -- STAGE 3: Determine installation type and route to appropriate strategy
  if flake.is_reference(tool) then
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