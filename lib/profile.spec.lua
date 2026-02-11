-- Mock dependencies for profile tests
local mock_shell_calls = {}
local mock_file_contents = {}
local mock_file_exists = {}

package.loaded["shell"] = {
  exec = function(cmd)
    table.insert(mock_shell_calls, cmd)

    -- Mock test -d commands (directory existence)
    if cmd:match("test %-d") then
      local path = cmd:match('test %-d "([^"]+)"')
      if mock_file_exists[path] then
        return ""
      else
        error("Directory does not exist")
      end
    end

    -- Mock test -e commands (file existence)
    if cmd:match("test %-e") then
      local path = cmd:match('test %-e "([^"]+)"')
      if mock_file_exists[path] then
        return ""
      else
        error("File does not exist")
      end
    end

    -- Mock mkdir -p
    if cmd:match("mkdir %-p") then
      local path = cmd:match('mkdir %-p "([^"]+)"')
      mock_file_exists[path] = true
      return ""
    end

    -- Mock rm -rf
    if cmd:match("rm %-rf") then
      local path = cmd:match('rm %-rf "([^"]+)"')
      mock_file_exists[path] = nil
      return ""
    end

    -- Mock nix profile install
    if cmd:match("nix profile install") then
      local profile_path = cmd:match('%-%-profile "([^"]+)"')
      if profile_path then
        mock_file_exists[profile_path] = true
        mock_file_exists[profile_path .. "/manifest.json"] = true
        -- Create a mock manifest
        mock_file_contents[profile_path .. "/manifest.json"] = [[
{
  "elements": [
    {
      "storePaths": ["/nix/store/abc123-hello-2.12.1"]
    }
  ]
}
]]
      end
      return "installing 'github:NixOS/nixpkgs#hello'"
    end

    -- Mock ls for listing versions
    if cmd:match("ls %-1") then
      return "2.12.0\n2.12.1\n2.13.0"
    end

    -- Mock find for cleanup
    if cmd:match("find.*%-type d %-empty %-delete") then
      return ""
    end

    return ""
  end,

  is_containerized = function()
    return false
  end,

  try_exec = function(fmt, ...)
    local cmd = string.format(fmt, ...)
    local ok, result = pcall(function()
      return package.loaded["shell"].exec(cmd)
    end)
    return ok, result
  end
}

package.loaded["platform"] = {
  get_env_prefix = function() return "" end,
  get_impure_flag = function() return "" end
}

package.loaded["logger"] = {
  debug = function() end,
  info = function() end,
  warn = function() end,
  step = function() end
}

-- Override io.open for mock file reading
local original_io_open = io.open
_G.io.open = function(filename, mode)
  if mode == "r" and mock_file_contents[filename] then
    -- Return a mock file handle
    local content = mock_file_contents[filename]
    local pos = 1
    return {
      read = function(self, format)
        if format == "*all" then
          return content
        end
        return nil
      end,
      close = function() end
    }
  end
  return nil
end

local profile = require("profile")

describe("Profile module", function()
  before_each(function()
    mock_shell_calls = {}
    mock_file_contents = {}
    mock_file_exists = {}

    -- Setup HOME environment
    os.getenv = function(var)
      if var == "HOME" then
        return "/home/testuser"
      elseif var == "MISE_NIX_USE_PROFILES" then
        return "true"
      end
      return nil
    end
  end)

  after_each(function()
    -- Restore io.open
    _G.io.open = original_io_open
  end)

  it("should have all required functions", function()
    assert.is_function(profile.get_profile_path)
    assert.is_function(profile.profile_exists)
    assert.is_function(profile.get_manifest)
    assert.is_function(profile.get_store_path_from_manifest)
    assert.is_function(profile.install_to_profile)
    assert.is_function(profile.remove_profile)
    assert.is_function(profile.list_tool_versions)
    assert.is_function(profile.cleanup_empty_dirs)
  end)

  describe("get_profile_path", function()
    it("should generate correct profile path", function()
      local path = profile.get_profile_path("hello", "2.12.1")
      assert.equal("/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1", path)
    end)

    it("should sanitize tool and version names", function()
      local path = profile.get_profile_path("my@tool!", "v1.0.0/beta")
      assert.match("my_tool_", path)
      assert.match("v1.0.0_beta", path)
    end)

    it("should error if tool is missing", function()
      assert.has_error(function()
        profile.get_profile_path("", "1.0.0")
      end)
    end)

    it("should error if version is missing", function()
      assert.has_error(function()
        profile.get_profile_path("hello", "")
      end)
    end)
  end)

  describe("profile_exists", function()
    it("should return true for existing profiles", function()
      mock_file_exists["/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"] = true
      local exists = profile.profile_exists("/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1")
      assert.is_true(exists)
    end)

    it("should return false for non-existing profiles", function()
      local exists = profile.profile_exists("/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1")
      assert.is_false(exists)
    end)
  end)

  describe("get_manifest", function()
    it("should parse manifest.json correctly", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      mock_file_contents[profile_path .. "/manifest.json"] = [[
{
  "elements": [
    {
      "storePaths": ["/nix/store/abc123-hello-2.12.1", "/nix/store/def456-docs"]
    }
  ]
}
]]
      local manifest = profile.get_manifest(profile_path)
      assert.is_not_nil(manifest)
      assert.is_not_nil(manifest.elements)
      assert.equal(1, #manifest.elements)
      assert.is_not_nil(manifest.elements[1].storePaths)
    end)

    it("should return nil for missing manifest", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      local manifest = profile.get_manifest(profile_path)
      assert.is_nil(manifest)
    end)

    it("should handle empty manifest gracefully", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      mock_file_contents[profile_path .. "/manifest.json"] = ""
      local manifest = profile.get_manifest(profile_path)
      assert.is_nil(manifest)
    end)
  end)

  describe("get_store_path_from_manifest", function()
    it("should extract store path from manifest", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      mock_file_contents[profile_path .. "/manifest.json"] = [[
{
  "elements": [
    {
      "storePaths": ["/nix/store/abc123-hello-2.12.1"]
    }
  ]
}
]]
      mock_file_exists["/nix/store/abc123-hello-2.12.1"] = true

      local store_path = profile.get_store_path_from_manifest(profile_path)
      assert.equal("/nix/store/abc123-hello-2.12.1", store_path)
    end)

    it("should error if manifest is missing", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      assert.has_error(function()
        profile.get_store_path_from_manifest(profile_path)
      end)
    end)

    it("should error if store path does not exist", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      mock_file_contents[profile_path .. "/manifest.json"] = [[
{
  "elements": [
    {
      "storePaths": ["/nix/store/nonexistent"]
    }
  ]
}
]]
      assert.has_error(function()
        profile.get_store_path_from_manifest(profile_path)
      end)
    end)
  end)

  describe("install_to_profile", function()
    it("should install package to profile", function()
      local flake_ref = "github:NixOS/nixpkgs/abc123#hello"
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"

      local store_path = profile.install_to_profile(flake_ref, profile_path)

      -- Check that nix profile install was called
      local found_install_cmd = false
      for _, cmd in ipairs(mock_shell_calls) do
        if cmd:match("nix profile install") then
          found_install_cmd = true
          assert.match(flake_ref, cmd)
          assert.match(profile_path, cmd)
        end
      end
      assert.is_true(found_install_cmd)

      -- Check that store path was returned
      assert.equal("/nix/store/abc123-hello-2.12.1", store_path)
    end)

    it("should skip install in containerized environment if profile exists", function()
      package.loaded["shell"].is_containerized = function() return true end

      local flake_ref = "github:NixOS/nixpkgs/abc123#hello"
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"

      -- Pre-populate profile
      mock_file_exists[profile_path] = true
      mock_file_exists[profile_path .. "/manifest.json"] = true
      mock_file_contents[profile_path .. "/manifest.json"] = [[
{
  "elements": [
    {
      "storePaths": ["/nix/store/abc123-hello-2.12.1"]
    }
  ]
}
]]
      mock_file_exists["/nix/store/abc123-hello-2.12.1"] = true

      local store_path = profile.install_to_profile(flake_ref, profile_path)

      -- Check that nix profile install was NOT called (should be skipped)
      local found_install_cmd = false
      for _, cmd in ipairs(mock_shell_calls) do
        if cmd:match("nix profile install") then
          found_install_cmd = true
        end
      end
      assert.is_false(found_install_cmd)

      -- But store path should still be returned
      assert.equal("/nix/store/abc123-hello-2.12.1", store_path)

      -- Restore
      package.loaded["shell"].is_containerized = function() return false end
    end)
  end)

  describe("remove_profile", function()
    it("should remove existing profile", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"
      mock_file_exists[profile_path] = true

      profile.remove_profile(profile_path)

      -- Check that rm -rf was called
      local found_rm_cmd = false
      for _, cmd in ipairs(mock_shell_calls) do
        if cmd:match("rm %-rf") and cmd:match(profile_path) then
          found_rm_cmd = true
        end
      end
      assert.is_true(found_rm_cmd)
    end)

    it("should handle non-existing profile gracefully", function()
      local profile_path = "/home/testuser/.local/share/mise-nix/profiles/hello/2.12.1"

      -- Should not error
      assert.has_no_errors(function()
        profile.remove_profile(profile_path)
      end)
    end)
  end)

  describe("list_tool_versions", function()
    it("should list installed versions", function()
      mock_file_exists["/home/testuser/.local/share/mise-nix/profiles/hello"] = true

      local versions = profile.list_tool_versions("hello")

      assert.is_table(versions)
      assert.equal(3, #versions)
      assert.equal("2.12.0", versions[1])
      assert.equal("2.12.1", versions[2])
      assert.equal("2.13.0", versions[3])
    end)

    it("should return empty table for tool with no versions", function()
      local versions = profile.list_tool_versions("nonexistent")
      assert.is_table(versions)
      assert.equal(0, #versions)
    end)
  end)

  describe("cleanup_empty_dirs", function()
    it("should run find command to clean up empty directories", function()
      profile.cleanup_empty_dirs()

      local found_find_cmd = false
      for _, cmd in ipairs(mock_shell_calls) do
        if cmd:match("find") and cmd:match("%-empty %-delete") then
          found_find_cmd = true
        end
      end
      assert.is_true(found_find_cmd)
    end)

    it("should handle missing base directory gracefully", function()
      assert.has_no_errors(function()
        profile.cleanup_empty_dirs()
      end)
    end)
  end)
end)
