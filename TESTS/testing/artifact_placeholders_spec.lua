-- TESTS/testing/artifact_placeholders_spec.lua -- D.8 "artifacts": a screen snapshot and a trace file of
-- a case that shows the repository, the home, the temp and the state directory contain `<REPO>`,
-- `<HOME>`, `<TMP>` and `<STATE>` and none of the real paths. One fixture, both artifact kinds.

return function(H)
  local ok = H.ok
  local screen = require("testing.screen")
  local trace_mod = require("testing.rpc.trace")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-placeholders"
  vim.fn.mkdir(root .. "/TESTS", "p")

  -- the real roots of this machine, as the runner names them; a file below each of them
  local roots = require("testing.run.inproc").path_roots(root)
  local names = { repo = "<REPO>", home = "<HOME>", tmp = "<TMP>", state = "<STATE>" }
  local shown = {
    repo = root .. "/lua/x.lua",
    home = assert(roots.home) .. "/projects/y.lua",
    tmp = assert(roots.tmp) .. "/other-run/z.lua",
    state = assert(roots.state) .. "/testing/w.json",
  }

  ---Whether `text` still holds `path` in any spelling the artifacts could use (case-insensitive).
  local function leaks(text, path)
    local low = text:lower()
    local fwd = vim.fs.normalize(path):lower()
    local back = fwd:gsub("/", "\\")
    return low:find(fwd, 1, true) ~= nil
      or low:find(back, 1, true) ~= nil
      or low:find((back:gsub("\\", "\\\\")), 1, true) ~= nil
  end

  local function check(kind, text)
    for key, token in pairs(names) do
      ok(text:find(token, 1, true) ~= nil, kind .. ": " .. token .. " is in the artifact ")
      ok(
        not leaks(text, roots[key]),
        kind .. ": the real " .. key .. " path is not in the artifact"
      )
    end
  end

  local body_ok, body_err = xpcall(function()
    -- the snapshot
    do
      local lines = {}
      for _, key in ipairs({ "repo", "home", "tmp", "state" }) do
        lines[#lines + 1] = shown[key]
      end
      local cols = 0
      for _, l in ipairs(lines) do
        cols = math.max(cols, #l)
      end
      local cells, attrs = {}, {}
      for i, l in ipairs(lines) do
        local padded = l .. (" "):rep(cols - #l)
        cells[i] = {}
        for ch in padded:gmatch(".") do
          cells[i][#cells[i] + 1] = ch
        end
        attrs[i] = ("a"):rep(cols)
        lines[i] = padded
      end
      local res = screen.compare("paths", {
        size = { rows = #lines, cols = cols },
        cursor = { row = 1, col = 1 },
        mode = "n",
        lines = lines,
        attrs = attrs,
        cells = cells,
        cell_attrs = attrs,
      }, {
        roots = roots,
        root = root,
        file = root .. "/TESTS/paths_spec.lua",
        ci = false,
      })
      ok(res.ok ~= false, "the snapshot is written: " .. vim.inspect(res))
      local f = assert(io.open(root .. "/TESTS/__snapshots__/paths_spec/paths.snap", "rb"))
      local text = f:read("*a")
      f:close()
      check("snapshot", text)
    end

    -- the trace
    do
      local t = trace_mod.new()
      local c = t:start("nvim_exec_lua", { "return 1" })
      t:finish(c, "error", "failed in " .. shown.repo)
      t:event("notify", ("%s %s"):format(shown.home, shown.tmp))
      local snap = t:snapshot({
        reason = "crash",
        child = { pid = 1 },
        stderr = "at " .. shown.state .. "\n",
      })
      local path = root .. "/trace/case.trace.json"
      local artifact, err = trace_mod.write(snap, { path = path, root = root })
      ok(artifact ~= nil, "the trace is written: " .. tostring(err))
      local f = assert(io.open(path, "rb"))
      local text = f:read("*a")
      f:close()
      check("trace", text)
    end
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not body_ok then
    error(body_err, 0)
  end
end
