-- Build orchestration using nix profile install
local version = require("version")
local platform = require("platform")
local flake = require("flake")
local profile = require("profile")
local logger = require("logger")

local M = {}

-- Install a package from nixhub metadata using nix profile install
function M.from_nixhub(tool, requested_version, current_os, current_arch)
  local start_time = os.time()
  logger.info(string.format("Resolving version: %s%s", tool, requested_version and "@" .. requested_version or " (latest)"))
  logger.debug("Starting nixhub resolution for " .. tool .. "@" .. (requested_version or "latest"))

  -- Resolve version to actual release
  local release = version.resolve_version(tool, requested_version, current_os, current_arch)
  logger.done(string.format("Resolved to version %s", release.version))
  logger.debug(string.format("Version resolution took %ds", os.time() - start_time))

  -- Get platform build info
  local platform_build = release.platforms and release.platforms[1]
  if not platform_build then
    error("No platform build found for version " .. release.version)
  end

  -- Build Nix flake reference
  local repo_url = platform.get_nixpkgs_repo_url()
  local repo_ref = repo_url:gsub("https://github.com/", "github:")
  local flake_ref = string.format("%s/%s#%s", repo_ref, platform_build.commit_hash, platform_build.attribute_path)
  logger.debug("Flake reference: " .. flake_ref)

  -- Install to default profile and get store path
  local install_start = os.time()
  local store_path, index = profile.install(flake_ref)
  logger.debug(string.format("Profile install took %ds", os.time() - install_start))

  return {
    tool = tool,
    version = release.version,
    outputs = {store_path},
    flake_ref = flake_ref,
    profile_index = index
  }
end

-- Install a package from flake reference using nix profile install
function M.from_flake(flake_ref, version_hint)
  local outputs, built_ref, index = flake.install(flake_ref, version_hint)

  return {
    flake_ref = flake_ref,
    version = built_ref,
    outputs = outputs,
    profile_index = index
  }
end

-- Choose best output path from build results
function M.choose_best_output(outputs, context_label)
  local chosen_path, has_binaries = platform.choose_store_path_with_bin(outputs)

  if not has_binaries then
    if context_label and context_label:match("vscode%-extensions%.") then
      logger.pack("VSCode extension package (no CLI binaries expected)")
    elseif context_label and context_label:match("vimPlugins%.") then
      logger.pack("Neovim plugin package (no CLI binaries expected)")
    else
      logger.warn("No binaries found. This package may be a library or data-only.")
      logger.hint("Using first available output for symlinking or build environment use.")
    end
  end

  return chosen_path
end

return M
