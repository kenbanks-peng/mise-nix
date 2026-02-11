function PLUGIN:BackendListVersions(ctx)
  local flake = require("flake")
  local platform = require("platform")
  local nixhub = require("nixhub")
  local version = require("version")
  local logger = require("logger")
  local tool = ctx.tool

  if not tool or tool == "" then
    error("Tool name cannot be empty")
  end

  -- Check Nix availability first - no point proceeding if Nix isn't available
  logger.debug("Checking Nix availability...")
  platform.check_nix_available()

  logger.debug("Listing available versions for: " .. tool)

  -- If this is a flake reference, we return available versions for that flake
  if flake.is_reference(tool) then
    logger.find("Detected flake reference")
    logger.info("Querying flake versions...")
    local versions = flake.get_versions(tool)
    logger.done(string.format("Found %d version(s)", #versions))
    return { versions = versions }
  end

  -- If the requested version is a flake reference, return the version itself
  -- since flakes don't have traditional version lists
  local requested_version = ctx.version
  if requested_version and flake.is_reference(requested_version) then
    return { versions = { requested_version } }
  end

  -- If a specific version is requested and it's already in the Nix profile,
  -- return it immediately without querying nixhub (optimization for install workflow)
  if requested_version and requested_version ~= "" and requested_version ~= "latest" then
    logger.debug(string.format("Checking if %s@%s is already in profile...", tool, requested_version))
    local profile = require("profile")
    local store_path, installed_version, _ = profile.find_by_package_name(tool)
    logger.debug(string.format("Profile check result: store_path=%s, installed_version=%s", tostring(store_path), tostring(installed_version)))
    if store_path and installed_version and installed_version == requested_version then
      logger.done(string.format("Version %s already in Nix profile", requested_version))
      return { versions = { requested_version } }
    end
  end

  -- Use traditional nixhub.io workflow for regular package names
  logger.debug("Querying nixhub for package metadata...")
  local current_os = platform.normalize_os(RUNTIME.osType)
  local current_arch = RUNTIME.archType:lower()

  local success, data, response = nixhub.fetch_metadata(tool)

  -- If package not found in nixhub, return empty list
  -- This allows flake reference versions to work (e.g., nix:mytool@gitlab+group/repo#default)
  -- The actual validation happens during install when we have access to the version
  if not success or not data or not data.releases then
    logger.warn("Package not found in nixhub")
    return { versions = {} }
  end

  logger.debug("Filtering compatible versions...")
  local versions = {}
  for _, release in ipairs(data.releases) do
    local release_version = release.version
    if version.is_valid(release_version)
        and version.is_compatible(release.platforms_summary, current_os, current_arch) then
      table.insert(versions, release_version)
    end
  end

  -- For ls-remote, return empty list if no compatible versions found
  if #versions == 0 then
    logger.warn("No compatible versions found for current platform")
    return { versions = {} }
  end

  -- Reverse so latest versions appear at the bottom of the list
  local reversed = {}
  for i = #versions, 1, -1 do
    table.insert(reversed, versions[i])
  end

  logger.done(string.format("%s available in nixhub", tool))
  return { versions = reversed }
end