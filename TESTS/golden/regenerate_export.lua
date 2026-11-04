-- Regenerates the golden files of the contract `testing-export/1` from the synthetic fixture fleet.
--
--   nvim -n -i NONE --headless -u NONE -l TESTS/golden/regenerate_export.lua
--
-- A golden file is what a client of `testing-export/1` can rely on byte for byte: a change of one is a change of the
-- contract. Run this on purpose, read `git diff TESTS/golden`, and commit the files together with the code change.
-- The files are the export folder of the fixture as `testing.export.export` returns it (fleet.json,
-- repos/<key>.json, testing-export.json); TESTS/testing/export_contract_spec.lua compares them.

local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local plugin_root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.rtp:prepend(plugin_root)

local deps = require("testing.deps")
local lib = deps.resolve("lib.nvim", plugin_root)
if not lib then
  io.stderr:write("regenerate_export: lib.nvim was not found\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

local fixture = dofile(plugin_root .. "/TESTS/testing/export_fixture.lua")
local base = fixture.base("golden")
local fx = fixture.build(base)
local restore = fixture.install()
local bundle, err = require("testing.export").export(fixture.opts(fx))
-- `testing call hello` with the fixture's clock and engine (TESTS/testing/export_call_spec.lua compares it)
local hello, herr =
  require("testing.export").encode(require("testing.export").hello(), { indent = 2 })
-- `testing call finding --params` of the repository beta (the same spec compares it)
local found = require("testing.finding").collect({
  dir = fx.beta,
  state_dir = fx.state,
  classes = { path = fx.areas },
})
local findings, ferr = require("testing.export").encode(
  require("testing.export").findings(require("testing.export").deps.key(fx.beta), found or {}),
  { indent = 2 }
)
restore()
if not hello then
  io.stderr:write("regenerate_export: hello: " .. tostring(herr) .. "\n")
  os.exit(1)
end
if not found or not findings then
  io.stderr:write("regenerate_export: findings: " .. tostring(ferr) .. "\n")
  os.exit(1)
end
fixture.write(fixture.HELLO_GOLDEN, hello)
io.stdout:write(("wrote %s (%d bytes)\n"):format(vim.fs.basename(fixture.HELLO_GOLDEN), #hello))
fixture.write(fixture.FINDINGS_GOLDEN, findings)
io.stdout:write(
  ("wrote %s (%d bytes)\n"):format(vim.fs.basename(fixture.FINDINGS_GOLDEN), #findings)
)
vim.fn.delete(base, "rf")
if not bundle then
  io.stderr:write("regenerate_export: " .. tostring(err) .. "\n")
  os.exit(1)
end

vim.fn.delete(fixture.GOLDEN_DIR, "rf")
local files = vim.list_extend(vim.list_slice(bundle.files, 1), { bundle.manifest })
for _, f in ipairs(files) do
  fixture.write(fixture.GOLDEN_DIR .. "/" .. f.path, f.text)
  io.stdout:write(("wrote %s (%d bytes)\n"):format(f.path, f.bytes))
end
os.exit(0)
