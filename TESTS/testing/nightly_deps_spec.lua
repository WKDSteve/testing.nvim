-- @cache-inputs .github/workflows/
-- TESTS/testing/nightly_deps_spec.lua -- the Nightly workflow runs the whole suite without the cache, so it needs
-- every dependency checkout the push workflow (ci.yml, generated) gives the suite: a feature sheet that misses one is
-- skipped, and under CI a skipped feature sheet fails (testing.tests-view-pipeline needs filetree.nvim and ui.nvim;
-- the Nightly was red from 2026-11-22 for that).

return function(H)
  local ok = H.ok
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local root = vim.fs.dirname(vim.fs.dirname(here))

  ---The `.deps/<name>` paths a workflow checks out.
  ---@param text string
  ---@return table<string, boolean>
  local function deps_of(text)
    local set = {}
    for name in text:gmatch("\n%s*path:%s*%.deps/([%w%._%-]+)") do
      set[name] = true
    end
    return set
  end
  local function read(name)
    local fh = assert(io.open(root .. "/.github/workflows/" .. name, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
  end

  -- the reader itself (FALLEN-04): it finds what is there
  local probe =
    deps_of("steps:\n  - with:\n      path: .deps/lib.nvim\n      path: .deps/ui.nvim\n")
  ok(probe["lib.nvim"] and probe["ui.nvim"], "deps_of: finds the paths of a workflow")

  local ci, nightly = deps_of(read("ci.yml")), deps_of(read("nightly.yml"))
  ok(ci["filetree.nvim"], "ci.yml checks out filetree.nvim (the sheet that needs it)")
  for name in pairs(ci) do
    -- testing.nvim's own ci-verified checkout serves the generated workflow's runner; the Nightly runs this checkout
    if name ~= "testing.nvim" then
      ok(nightly[name], "nightly.yml checks out .deps/" .. name .. " as ci.yml does")
    end
  end
end
