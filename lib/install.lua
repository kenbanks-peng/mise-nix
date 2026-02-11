-- Installation strategies using nix profile install
local platform = require("platform")
local version = require("version")
local profile = require("profile")
local flake = require("flake")
local shell = require("shell")
local logger = require("logger")

local M = {}

-- Standard tool installation via symlink (PVC-optimized)
function M.standard_tool(nix_store_path, install_path, label)
  logger.tool("Installing as standard tool: " .. label)

  -- In containerized environments, check if symlink already exists and is correct
  if shell.is_containerized() then
    local ok, current_target = shell.try_exec('readlink "%s" 2>/dev/null', install_path)
    if ok and current_target:match(nix_store_path .. "$") then
      logger.debug("Symlink already correct: " .. install_path)
      return
    end
  end

  shell.symlink_force(nix_store_path, install_path)
end

-- Flake installation with hash workaround for direct references (PVC-optimized)
function M.flake_with_hash_workaround(nix_store_path, install_path)
  -- WORKAROUND: mise expects a directory named after the nix store hash for direct flake references
  local nix_hash = nix_store_path:match("/nix/store/([^/]+)")
  if not nix_hash then return end

  local install_dir = install_path:match("^(.+)/[^/]+$")
  if not install_dir then return end

  local hash_path = install_dir .. "/" .. nix_hash

  -- In containerized environments, check if target already points correctly to avoid unnecessary I/O
  if shell.is_containerized() then
    local ok, current_target = shell.try_exec('readlink "%s" 2>/dev/null', hash_path)
    if ok and current_target:match(nix_store_path .. "$") then
      logger.debug("Hash symlink already correct: " .. hash_path)
      return
    end
  end

  shell.symlink_force(nix_store_path, hash_path)
end

-- Choose best output path from build results
local function choose_best_output(outputs, context_label)
  local chosen_path, has_binaries = platform.choose_store_path_with_bin(outputs)

  if not has_binaries then
    logger.warn("No binaries found. This package may be a library or data-only.")
    logger.hint("Using first available output for symlinking or build environment use.")
  end

  return chosen_path
end

-- Install from nixhub with automatic version resolution
function M.from_nixhub(tool, requested_version, install_path)
  local current_os = platform.normalize_os(RUNTIME.osType)
  local current_arch = RUNTIME.archType:lower()

  -- Resolve version
  logger.info(string.format("Resolving version: %s%s", tool, requested_version and "@" .. requested_version or " (latest)"))
  local release = version.resolve_version(tool, requested_version, current_os, current_arch)
  logger.done(string.format("Resolved to version %s", release.version))

  -- Get platform build info
  local platform_build = release.platforms and release.platforms[1]
  if not platform_build then
    error("No platform build found for version " .. release.version)
  end

  -- Build Nix flake reference
  local repo_url = platform.get_nixpkgs_repo_url()
  local repo_ref = repo_url:gsub("https://github.com/", "github:")
  local flake_ref = string.format("%s/%s#%s", repo_ref, platform_build.commit_hash, platform_build.attribute_path)

  -- Install to profile and get store path
  local store_path, index = profile.install(flake_ref)
  local nix_store_path = choose_best_output({store_path}, tool)

  -- Verify the build succeeded
  platform.verify_build(nix_store_path, tool)

  -- Install as standard tool
  M.standard_tool(nix_store_path, install_path, tool)

  logger.done(string.format("Successfully installed %s@%s", tool, release.version))

  return {
    version = release.version,
    store_path = nix_store_path,
    profile_index = index
  }
end

-- Install from flake reference
function M.from_flake(flake_ref, version_hint, install_path)
  local outputs, built_ref, index = flake.install(flake_ref, version_hint)
  local nix_store_path = choose_best_output(outputs, flake_ref)

  -- Verify the build succeeded
  platform.verify_build(nix_store_path, flake_ref)

  -- Install as standard tool
  M.standard_tool(nix_store_path, install_path, flake_ref)
  M.flake_with_hash_workaround(nix_store_path, install_path)

  logger.done("Successfully installed " .. built_ref)

  return {
    version = built_ref,
    store_path = nix_store_path,
    profile_index = index
  }
end

return M
