-- Installation strategies for different package types
local platform = require("platform")
local vsix = require("vsix")
local vscode = require("vscode")
local jetbrains = require("jetbrains")
local shell = require("shell")
local logger = require("logger")
local profile = require("profile")

local M = {}

-- Standard tool installation via profile and symlink
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

-- Install package via nix profile for proper registration
-- This builds, registers in profile, and returns outputs
function M.install_via_profile(flake_ref, tool, version)
  logger.debug("Installing via profile: " .. flake_ref)

  -- Build and register in profile
  local outputs = profile.install_and_get_store_path(flake_ref)

  logger.debug("Profile installation complete, got " .. #outputs .. " outputs")

  return outputs
end

-- Install from nixhub with automatic version resolution
function M.from_nixhub(tool, requested_version, install_path)
  local version_module = require("version")
  local current_os = platform.normalize_os(RUNTIME.osType)
  local current_arch = RUNTIME.archType:lower()

  -- Resolve version to actual release
  local release = version_module.resolve_version(tool, requested_version, current_os, current_arch)

  -- Get platform build info
  local platform_build = release.platforms and release.platforms[1]
  if not platform_build then
    error("No platform build found for version " .. release.version)
  end

  -- Build Nix flake reference
  local repo_url = platform.get_nixpkgs_repo_url()
  local repo_ref = repo_url:gsub("https://github.com/", "github:")
  local flake_ref = string.format("%s/%s#%s", repo_ref, platform_build.commit_hash, platform_build.attribute_path)

  logger.step(string.format("Installing %s@%s...", tool, release.version))

  local outputs
  local nix_store_path

  -- Handle VSCode extensions and JetBrains plugins specially (no profile registration needed)
  if vscode.is_extension(tool) then
    -- Use direct build for VSCode extensions
    outputs = vsix.from_nixhub(tool, requested_version, current_os, current_arch).outputs
    nix_store_path = vsix.choose_best_output(outputs, tool)
    platform.verify_build(nix_store_path, tool)
    vscode.install_extension(nix_store_path, tool)
  elseif jetbrains.is_plugin(tool) then
    -- Use direct build for JetBrains plugins
    outputs = vsix.from_nixhub(tool, requested_version, current_os, current_arch).outputs
    nix_store_path = vsix.choose_best_output(outputs, tool)
    platform.verify_build(nix_store_path, tool)
    jetbrains.install_plugin_from_store(nix_store_path, tool)
  else
    -- Standard tools: use profile-based installation for proper registration
    outputs = M.install_via_profile(flake_ref, tool, release.version)
    nix_store_path = platform.choose_store_path_with_bin(outputs)
    platform.verify_build(nix_store_path, tool)
    M.standard_tool(nix_store_path, install_path, tool)
  end

  logger.done(string.format("Successfully installed %s@%s", tool, release.version))

  return {
    version = release.version,
    store_path = nix_store_path,
    is_vscode = vscode.is_extension(tool),
    is_jetbrains = jetbrains.is_plugin(tool)
  }
end

-- Install from flake reference
function M.from_flake(flake_ref, version_hint, install_path)
  local flake = require("flake")

  local is_vscode = vscode.is_extension(flake_ref)
  local is_jetbrains = jetbrains.is_plugin(flake_ref)

  local outputs
  local nix_store_path
  local built_ref

  -- Handle VSCode extensions and JetBrains plugins specially (no profile registration needed)
  if is_vscode then
    logger.find("Detected VSCode extension flake: " .. flake_ref)
    local build_result = vsix.from_flake(flake_ref, version_hint)
    outputs = build_result.outputs
    built_ref = build_result.version
    nix_store_path = vsix.choose_best_output(outputs, flake_ref)
    platform.verify_build(nix_store_path, flake_ref)
    vscode.install_extension(nix_store_path, flake_ref)
  elseif is_jetbrains then
    logger.find("Detected JetBrains plugin flake: " .. flake_ref)
    local build_result = vsix.from_flake(flake_ref, version_hint)
    outputs = build_result.outputs
    built_ref = build_result.version
    nix_store_path = vsix.choose_best_output(outputs, flake_ref)
    platform.verify_build(nix_store_path, flake_ref)
    jetbrains.install_plugin_from_store(nix_store_path, flake_ref)
  else
    -- Standard tools: use profile-based installation for proper registration
    -- First parse and build the flake reference
    local parsed = flake.parse_reference(flake_ref)
    local build_ref = parsed.full_ref

    -- If version is specified, incorporate it into the flake ref
    if version_hint and version_hint ~= "latest" and version_hint ~= "local" and version_hint ~= "" then
      if parsed.url:match("github:") or parsed.url:match("gitlab:") then
        local base_url = parsed.url:gsub("/[a-fA-F0-9]+$", ""):gsub("/v?%d+%.%d+%.%d+.*$", "")
        build_ref = base_url .. "/" .. version_hint .. "#" .. parsed.attribute
      elseif parsed.url:match("git%+") then
        local separator = parsed.url:find("?") and "&" or "?"
        local cleaned_url = parsed.url:gsub("[%?&]ref=[^&#]+", ""):gsub("[%?&]rev=[^&#]+", ""):gsub("[?&]$", "")
        build_ref = cleaned_url .. separator .. "rev=" .. version_hint .. "#" .. parsed.attribute
      end
    end

    outputs = M.install_via_profile(build_ref, flake_ref, version_hint or "latest")
    nix_store_path = platform.choose_store_path_with_bin(outputs)
    built_ref = build_ref

    platform.verify_build(nix_store_path, flake_ref)
    M.standard_tool(nix_store_path, install_path, flake_ref)
    M.flake_with_hash_workaround(nix_store_path, install_path)
  end

  logger.done("Successfully installed " .. (built_ref or flake_ref))

  return {
    version = built_ref or flake_ref,
    store_path = nix_store_path,
    is_vscode = is_vscode,
    is_jetbrains = is_jetbrains
  }
end

return M