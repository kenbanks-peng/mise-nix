-- Mock dependencies for profile tests
package.loaded["cmd"] = {
  exec = function(command)
    return "mocked output"
  end
}

package.loaded["file"] = {
  join_path = function(...)
    local args = {...}
    return table.concat(args, "/")
  end,
  symlink = function(src, dst) end,
  exists = function(path) return true end
}

local shell_exec_results = {}
package.loaded["shell"] = {
  exec = function(cmd, ...)
    -- Return mocked results based on command
    if cmd:match("nix build") then
      return "/nix/store/abc-hello\n"
    elseif cmd:match("nix profile install") then
      return ""
    elseif cmd:match("nix profile list") then
      return '{"elements": {}}'
    elseif cmd:match("nix profile remove") then
      return ""
    end
    return ""
  end,
  try_exec = function(cmd, ...)
    if cmd:match("test %-L") then
      return true, ""
    elseif cmd:match("mkdir") then
      return true, ""
    elseif cmd:match("nix build") then
      return true, "/nix/store/abc-hello\n"
    elseif cmd:match("nix profile install") then
      return true, ""
    elseif cmd:match("nix profile list") then
      return true, '{"elements": {"0": {"storePaths": ["/nix/store/abc-hello"]}}}'
    elseif cmd:match("nix profile remove") then
      return true, ""
    end
    return false, ""
  end
}

package.loaded["logger"] = {
  step = function(msg) end,
  debug = function(msg) end,
  done = function(msg) end,
  warn = function(msg) end,
  info = function(msg) end
}

package.loaded["platform"] = {
  get_env_prefix = function() return "" end,
  get_impure_flag = function() return "" end
}

local profile = require("profile")

describe("Profile module", function()
  describe("get_profile_path", function()
    it("should return the default nix profile path", function()
      local original = os.getenv
      os.getenv = function(name)
        if name == "HOME" then return "/home/user" end
        return nil
      end
      local path = profile.get_profile_path()
      os.getenv = original
      assert.equal("/home/user/.nix-profile", path)
    end)
  end)

  describe("get_entry_name", function()
    it("should create sanitized entry name", function()
      local name = profile.get_entry_name("hello", "2.12.1")
      assert.equal("mise.hello.2.12.1", name)
    end)

    it("should sanitize special characters in tool name", function()
      local name = profile.get_entry_name("vscode-extensions.foo.bar", "1.0.0")
      assert.equal("mise.vscode-extensions-foo-bar.1.0.0", name)
    end)

    it("should sanitize special characters in version", function()
      local name = profile.get_entry_name("python", "3.11+debug")
      assert.equal("mise.python.3.11-debug", name)
    end)
  end)

  describe("install_and_get_store_path", function()
    it("should return store paths from build when not already installed", function()
      local outputs = profile.install_and_get_store_path("nixpkgs#hello")
      assert.is_table(outputs)
      assert.equal(1, #outputs)
      assert.equal("/nix/store/abc-hello", outputs[1])
    end)

    it("should skip build when already installed", function()
      local build_called = false
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, '{"elements": {"hello": {"originalUrl": "github:NixOS/nixpkgs/abc123#hello", "storePaths": ["/nix/store/existing-hello"]}}}'
        elseif cmd:match("nix build") then
          build_called = true
          return true, "/nix/store/new-hello"
        end
        return original_try_exec(cmd, ...)
      end

      local outputs = profile.install_and_get_store_path("github:NixOS/nixpkgs/abc123#hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.is_table(outputs)
      assert.equal("/nix/store/existing-hello", outputs[1])
      assert.is_false(build_called)
    end)
  end)

  describe("list", function()
    it("should return empty table if profile does not exist", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return false, ""
        end
        return original_try_exec(cmd, ...)
      end

      local entries = profile.list()
      package.loaded["shell"].try_exec = original_try_exec

      assert.is_table(entries)
      assert.equal(0, #entries)
    end)
  end)

  describe("remove", function()
    it("should return true on successful removal", function()
      local result = profile.remove("mise.hello.2.12.1")
      assert.is_true(result)
    end)
  end)

  describe("has_entry", function()
    it("should return false for non-existent entry", function()
      local result = profile.has_entry("mise.nonexistent.1.0.0")
      assert.is_false(result)
    end)
  end)

  describe("has_entry_for_tool", function()
    it("should return true when tool exists in profile", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, '{"elements": {"hello": {"storePaths": ["/nix/store/abc-hello"]}, "hello-1": {"storePaths": ["/nix/store/def-hello"]}}}'
        end
        return original_try_exec(cmd, ...)
      end

      local result = profile.has_entry_for_tool("hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.is_true(result)
    end)

    it("should return false when tool does not exist", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, '{"elements": {"other-tool": {"storePaths": ["/nix/store/xyz"]}}}'
        end
        return original_try_exec(cmd, ...)
      end

      local result = profile.has_entry_for_tool("hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.is_false(result)
    end)
  end)

  describe("remove_by_tool", function()
    it("should return true on successful removal", function()
      local result = profile.remove_by_tool("hello")
      assert.is_true(result)
    end)

    it("should handle tool names with special regex characters", function()
      local result = profile.remove_by_tool("c++")
      assert.is_true(result)
    end)
  end)

  describe("_flake_refs_match", function()
    it("should match identical references", function()
      local result = profile._flake_refs_match(
        "github:NixOS/nixpkgs/abc123#hello",
        "github:NixOS/nixpkgs/abc123#hello"
      )
      assert.is_true(result)
    end)

    it("should match short hash to full hash", function()
      local result = profile._flake_refs_match(
        "github:NixOS/nixpkgs/abc123#hello",
        "github:NixOS/nixpkgs/abc123456789abcdef#hello"
      )
      assert.is_true(result)
    end)

    it("should not match different attributes", function()
      local result = profile._flake_refs_match(
        "github:NixOS/nixpkgs/abc123#hello",
        "github:NixOS/nixpkgs/abc123#goodbye"
      )
      assert.is_false(result)
    end)

    it("should not match different commits", function()
      local result = profile._flake_refs_match(
        "github:NixOS/nixpkgs/abc123#hello",
        "github:NixOS/nixpkgs/def456#hello"
      )
      assert.is_false(result)
    end)

    it("should not match different repos", function()
      local result = profile._flake_refs_match(
        "github:NixOS/nixpkgs/abc123#hello",
        "github:Other/repo/abc123#hello"
      )
      assert.is_false(result)
    end)
  end)

  describe("get_installed_store_path", function()
    it("should return store path when flake is already installed", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, [[{
            "elements": {
              "hello": {
                "originalUrl": "github:NixOS/nixpkgs/abc123#hello",
                "storePaths": ["/nix/store/xyz-hello-2.12"]
              }
            }
          }]]
        end
        return original_try_exec(cmd, ...)
      end

      local result = profile.get_installed_store_path("github:NixOS/nixpkgs/abc123#hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.equal("/nix/store/xyz-hello-2.12", result)
    end)

    it("should return nil when flake is not installed", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, [[{
            "elements": {
              "other": {
                "originalUrl": "github:NixOS/nixpkgs/def456#other",
                "storePaths": ["/nix/store/xyz-other-1.0"]
              }
            }
          }]]
        end
        return original_try_exec(cmd, ...)
      end

      local result = profile.get_installed_store_path("github:NixOS/nixpkgs/abc123#hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.is_nil(result)
    end)

    it("should match short hash to full hash in profile", function()
      local original_try_exec = package.loaded["shell"].try_exec
      package.loaded["shell"].try_exec = function(cmd, ...)
        if cmd:match("test %-L") then
          return true, ""
        elseif cmd:match("nix profile list") then
          return true, [[{
            "elements": {
              "hello": {
                "originalUrl": "github:NixOS/nixpkgs/abc123456789abcdef0123456789abcdef012345#hello",
                "storePaths": ["/nix/store/xyz-hello-2.12"]
              }
            }
          }]]
        end
        return original_try_exec(cmd, ...)
      end

      -- Short hash should match the full hash in the profile
      local result = profile.get_installed_store_path("github:NixOS/nixpkgs/abc123#hello")
      package.loaded["shell"].try_exec = original_try_exec

      assert.equal("/nix/store/xyz-hello-2.12", result)
    end)
  end)
end)
