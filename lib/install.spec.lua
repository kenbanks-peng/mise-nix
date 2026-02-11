-- Mock dependencies for install tests
_G.RUNTIME = {
  osType = "Linux",
  archType = "amd64"
}

package.loaded["http"] = {
  get = function(opts)
    return {
      status_code = 200,
      body = '{"releases": [{"version": "1.0.0"}]}'
    }, nil
  end
}

package.loaded["json"] = {
  decode = function(str)
    return {releases = {{version = "1.0.0"}}}
  end
}

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

package.loaded["platform"] = {
  normalize_os = function(os) return os:lower() end,
  verify_build = function(path, tool) end,
  get_nixpkgs_repo_url = function() return "https://github.com/NixOS/nixpkgs" end,
  choose_store_path_with_bin = function(outputs) return outputs[1], true end
}

package.loaded["version"] = {
  resolve_version = function(tool, version, os, arch)
    return {
      version = "1.0.0",
      platforms = {{
        commit_hash = "abc123",
        attribute_path = tool
      }}
    }
  end
}

package.loaded["profile"] = {
  install = function(flake_ref)
    return "/nix/store/abc123-" .. flake_ref:match("#(.+)$"), 0
  end
}

package.loaded["flake"] = {
  install = function(flake_ref, version_hint)
    return {"/nix/store/def456-tool"}, "1.0.0", 0
  end
}

package.loaded["shell"] = {
  symlink_force = function(src, dst) end,
  is_containerized = function() return false end,
  try_exec = function(cmd, ...) return false, "" end
}

package.loaded["logger"] = {
  tool = function(msg) end,
  done = function(msg) end,
  find = function(msg) end,
  debug = function(msg) end,
  info = function(msg) end,
  warn = function(msg) end,
  hint = function(msg) end
}

local install = require("install")

describe("Install module", function()
  it("should have all required functions", function()
    assert.is_function(install.standard_tool)
    assert.is_function(install.flake_with_hash_workaround)
    assert.is_function(install.from_nixhub)
    assert.is_function(install.from_flake)
  end)

  describe("standard_tool", function()
    it("should install without error", function()
      assert.has_no.errors(function()
        install.standard_tool("/nix/store/abc", "/usr/local/bin/tool", "nodejs")
      end)
    end)
  end)

  describe("from_nixhub", function()
    it("should install from nixhub", function()
      local result = install.from_nixhub("nodejs", "18.0.0", "/install/path")
      assert.is_table(result)
      assert.equal("1.0.0", result.version)
      assert.equal("/nix/store/abc", result.store_path)
    end)
  end)

  describe("from_flake", function()
    it("should install from flake", function()
      local result = install.from_flake("nixpkgs#hello", "v1.0.0", "/install/path")
      assert.is_table(result)
      assert.equal("1.0.0", result.version)
      assert.equal("/nix/store/def", result.store_path)
    end)
  end)

  describe("flake_with_hash_workaround", function()
    it("should handle workaround without error", function()
      assert.has_no.errors(function()
        install.flake_with_hash_workaround("/nix/store/abc123-tool", "/install/path")
      end)
    end)
  end)
end)