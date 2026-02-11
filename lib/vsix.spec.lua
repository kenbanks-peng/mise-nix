-- Mock dependencies for build tests
package.loaded["platform"] = {
  get_nixpkgs_repo_url = function() return "https://github.com/NixOS/nixpkgs" end,
  choose_store_path_with_bin = function(outputs) return outputs[1], true end,
  get_impure_flag = function() return "" end,
  get_env_prefix = function() return "" end,
  get_nix_build_prefix = function() return "" end,
  needs_impure_mode = function() return false end
}

package.loaded["flake"] = {
  build = function(flake_ref, version_hint) return {"/nix/store/abc"}, "built_ref" end,
  build_with_profile = function(flake_ref, version_hint) return {"/nix/store/profile-abc"}, "built_ref" end
}

package.loaded["profile"] = {
  get_profile_path = function(tool, version) return "/home/user/.local/share/mise-nix/profiles/" .. tool .. "/" .. version end,
  install_to_profile = function(flake_ref, profile_path) return "/nix/store/profile-abc123" end
}

package.loaded["version"] = {
  resolve_version = function(tool, version, os, arch)
    return {
      version = "1.0.0",
      platforms = {{commit_hash = "abc123", attribute_path = "hello"}}
    }
  end
}

package.loaded["shell"] = {
  exec = function(cmd) return "/nix/store/abc123" end
}

package.loaded["logger"] = {
  step = function(msg) end,
  pack = function(msg) end,
  warn = function(msg) end,
  hint = function(msg) end,
  debug = function(msg) end,
  info = function(msg) end
}

local vsix = require("vsix")

describe("Build module", function()
  it("should have all required functions", function()
    assert.is_function(vsix.from_nixhub)
    assert.is_function(vsix.from_flake)
    assert.is_function(vsix.from_nixhub_with_profile)
    assert.is_function(vsix.from_flake_with_profile)
    assert.is_function(vsix.choose_best_output)
  end)

  describe("from_nixhub", function()
    it("should build package from nixhub", function()
      local result = vsix.from_nixhub("hello", "latest", "linux", "amd64")
      assert.is_table(result)
      assert.equal("hello", result.tool)
      assert.equal("1.0.0", result.version)
      assert.is_table(result.outputs)
    end)
  end)

  describe("from_flake", function()
    it("should build package from flake reference", function()
      local result = vsix.from_flake("nixpkgs#hello", "v1.0.0")
      assert.is_table(result)
      assert.equal("nixpkgs#hello", result.flake_ref)
      assert.is_table(result.outputs)
    end)
  end)

  describe("choose_best_output", function()
    it("should choose output without error", function()
      local outputs = {"/nix/store/abc"}
      local chosen = vsix.choose_best_output(outputs, "nodejs")
      assert.equal("/nix/store/abc", chosen)
    end)
  end)

  describe("from_nixhub_with_profile", function()
    it("should build package from nixhub using profiles", function()
      local result = vsix.from_nixhub_with_profile("hello", "latest", "linux", "amd64")
      assert.is_table(result)
      assert.equal("hello", result.tool)
      assert.equal("1.0.0", result.version)
      assert.is_table(result.outputs)
      assert.equal("/nix/store/profile-abc123", result.outputs[1])
    end)
  end)

  describe("from_flake_with_profile", function()
    it("should build package from flake reference using profiles", function()
      local result = vsix.from_flake_with_profile("nixpkgs#hello", "v1.0.0")
      assert.is_table(result)
      assert.equal("nixpkgs#hello", result.flake_ref)
      assert.is_table(result.outputs)
    end)
  end)
end)