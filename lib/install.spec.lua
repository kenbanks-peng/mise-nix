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
  choose_store_path_with_bin = function(outputs) return outputs[1], true end,
  get_nixpkgs_repo_url = function() return "https://github.com/NixOS/nixpkgs" end
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

package.loaded["flake"] = {
  parse_reference = function(flake_ref)
    return {
      url = "nixpkgs",
      attribute = "hello",
      full_ref = "nixpkgs#hello"
    }
  end,
  is_reference = function(ref) return ref and ref:match("#") end
}

package.loaded["profile"] = {
  install_and_get_store_path = function(flake_ref)
    return {"/nix/store/abc-hello"}
  end,
  get_entry_name = function(tool, version)
    return "mise." .. tool .. "." .. version
  end,
  has_entry = function(name) return false end,
  remove = function(name) return true end
}

package.loaded["vsix"] = {
  from_nixhub = function(tool, version, os, arch)
    return {
      tool = tool,
      version = "1.0.0",
      outputs = {"/nix/store/abc"},
      flake_ref = "nixpkgs#" .. tool
    }
  end,
  from_flake = function(flake_ref, version_hint)
    return {
      flake_ref = flake_ref,
      version = "1.0.0",
      outputs = {"/nix/store/def"}
    }
  end,
  choose_best_output = function(outputs, context) return outputs[1] end
}

package.loaded["vscode"] = {
  is_extension = function(tool) return tool and tool:match("vscode%-extensions%.") end,
  install_extension = function(nix_path, install_path, tool) return "ext.id" end
}

package.loaded["jetbrains"] = {
  is_plugin = function(tool) return tool and tool:match("jetbrains%-plugins%.") end,
  install_plugin_from_store = function(nix_path, tool) return "plugin.id" end
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
  step = function(msg) end
}

local install = require("install")

describe("Install module", function()
  it("should have all required functions", function()
    assert.is_function(install.standard_tool)
    assert.is_function(install.flake_with_hash_workaround)
    assert.is_function(install.from_nixhub)
    assert.is_function(install.from_flake)
    assert.is_function(install.install_via_profile)
  end)

  describe("standard_tool", function()
    it("should install without error", function()
      assert.has_no.errors(function()
        install.standard_tool("/nix/store/abc", "/usr/local/bin/tool", "nodejs")
      end)
    end)
  end)

  describe("install_via_profile", function()
    it("should install via profile and return outputs", function()
      local outputs = install.install_via_profile("nixpkgs#hello", "hello", "1.0.0")
      assert.is_table(outputs)
      assert.equal(1, #outputs)
      assert.equal("/nix/store/abc-hello", outputs[1])
    end)
  end)

  describe("from_nixhub", function()
    it("should install from nixhub using profile", function()
      local result = install.from_nixhub("nodejs", "18.0.0", "/install/path")
      assert.is_table(result)
      assert.equal("1.0.0", result.version)
      -- Now uses profile-based installation, returns first output from profile
      assert.equal("/nix/store/abc-hello", result.store_path)
    end)
  end)

  describe("from_flake", function()
    it("should install from flake using profile", function()
      local result = install.from_flake("nixpkgs#hello", "v1.0.0", "/install/path")
      assert.is_table(result)
      -- Now uses profile-based installation
      assert.equal("/nix/store/abc-hello", result.store_path)
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