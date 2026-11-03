-- scripts/bench-median.lua -- the reference of the nightly bench job (.github/workflows/bench.yml).
--
--   nvim -n -i NONE --headless -u NONE -l scripts/bench-median.lua <out.json> <baseline.json>...
--
-- Writes `<out.json>`: per case the median of the medians of the given baselines (the last green nightly runs of the
-- same runner type; `testing.budget.median_baseline`). Exit 0 written, 2 usage / nothing readable, 3 no lib.nvim.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))
vim.opt.rtp:prepend(repo)

local deps = require("testing.deps")
local lib, why = deps.resolve("lib.nvim", repo)
if not lib then
  io.stderr:write((why or "testing: lib.nvim was not found") .. "\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

local args = vim.deepcopy(_G.arg or {})
local out = table.remove(args, 1)
if not out or #args == 0 then
  io.stderr:write("usage: bench-median.lua <out.json> <baseline.json>...\n")
  os.exit(2)
end
local ok, err, skipped = require("testing.budget").write_median(out, args)
for _, line in ipairs(skipped) do
  io.stderr:write("skipped: " .. line .. "\n")
end
if not ok then
  io.stderr:write("bench-median: " .. tostring(err) .. "\n")
  os.exit(2)
end
io.stdout:write(("median of %d baseline(s) written: %s\n"):format(#args - #skipped, out))
