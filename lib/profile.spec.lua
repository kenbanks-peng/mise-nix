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
    it("should return path under XDG_STATE_HOME if set", function()
      local original = os.getenv
      os.getenv = function(name)
        if name == "XDG_STATE_HOME" then return "/custom/state" end
        if name == "HOME" then return "/home/user" end
        return nil
      end
      local path = profile.get_profile_path()
      os.getenv = original
      assert.equal("/custom/state/mise-nix/profile", path)
    end)

    it("should return path under HOME/.local/state if XDG not set", function()
      local original = os.getenv
      os.getenv = function(name)
        if name == "XDG_STATE_HOME" then return nil end
        if name == "HOME" then return "/home/user" end
        return nil
      end
      local path = profile.get_profile_path()
      os.getenv = original
      assert.equal("/home/user/.local/state/mise-nix/profile", path)
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
    it("should return store paths from build", function()
      local outputs = profile.install_and_get_store_path("nixpkgs#hello")
      assert.is_table(outputs)
      assert.equal(1, #outputs)
      assert.equal("/nix/store/abc-hello", outputs[1])
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
end)
