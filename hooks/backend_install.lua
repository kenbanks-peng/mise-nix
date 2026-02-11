-- mise-nix installer (modular refactored version)
-- Main installation hook - delegates to specialized modules

local flake = require("flake")
local install = require("install")
local logger = require("logger")

function PLUGIN:BackendInstall(ctx)
  local tool = ctx.tool
  local requested_version = ctx.version
  local install_path = ctx.install_path

  -- STAGE 1: Check if already installed by mise
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
          logger.done("Already installed: " .. tool .. "@" .. requested_version)
          return { version = requested_version }
        end
      else
        logger.done("Already installed: " .. tool)
        -- Extract version from the store path
        local version_match = current_target:match("%-(%d+[%.%d]+)") or "installed"
        return { version = version_match }
      end
    end
  end

  -- STAGE 3: Check if already in Nix profile (for standard packages)
  -- Skip this check for flake references since we need the full flake ref to check those
  if not flake.is_reference(tool) and not flake.is_reference(requested_version) then
    local profile = require("profile")
    local store_path, installed_version, index = profile.find_by_package_name(tool)
    if store_path then
      -- Check if version matches what was requested
      if requested_version and requested_version ~= "" and requested_version ~= "latest" then
        if installed_version and installed_version == requested_version then
          logger.done(string.format("%s@%s already installed in nix", tool, installed_version))
          -- Install symlink and return
          install.standard_tool(store_path, install_path, tool)
          return { version = installed_version }
        else
          logger.info(string.format("Found %s@%s in profile, but need version %s", tool, installed_version or "unknown", requested_version))
        end
      else
        -- No specific version requested, use what's in the profile
        logger.done(string.format("%s@%s already installed in nix", tool, installed_version or "unknown"))
        install.standard_tool(store_path, install_path, tool)
        return { version = installed_version or "unknown" }
      end
    end
  end

  -- Note: Package availability is already verified by mise calling BackendListVersions before install

  local result

  -- STAGE 4: Determine installation type and route to appropriate strategy
  if flake.is_reference(tool) then
    logger.find("Detected flake reference")
    result = install.from_flake(tool, requested_version, install_path)

  elseif flake.is_reference(requested_version) then
    logger.find("Detected flake reference in version")
    result = install.from_flake(requested_version, "", install_path)

  else
    logger.debug("Installing from nixpkgs via nixhub metadata")
    result = install.from_nixhub(tool, requested_version, install_path)
  end

  return { version = result.version }
end