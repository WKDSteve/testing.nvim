-- TESTS/testing/export_lock_spec.lua -- one writer per export folder: a second `testing export` into the same folder
-- while the first holds the lock gives up with exit 2 and writes nothing; the lock is released after a success and
-- after a failure; another folder is not blocked.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local folder = require("testing.export.folder")
  local statelock = require("testing.statelock")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local base = fixture.base("lock")
  local fx = fixture.build(base)
  local function write(out, extra)
    local restore = fixture.install()
    local okw, res, err = pcall(folder.write, out, fixture.opts(fx, extra))
    restore()
    ok(okw, "folder.write raised: " .. tostring(res))
    return res, err
  end
  local quick = { lock = { timeout_ms = 150 } }

  local out = fx.root .. "/../export-lock"
  local lock = folder.lock_path(out, fx.state)

  -- held by another writer: refused, nothing written
  local held_res, held_err
  local locked = statelock.with(lock, function()
    held_res, held_err = write(out, quick)
  end)
  eq(locked, true, "the test could take the lock")
  eq(held_res, nil, "a second writer gets no result")
  eq(held_err and held_err.code, 2, "exit 2")
  has(held_err and held_err.message, "another export is writing", "and says why")
  eq(vim.uv.fs_stat(out), nil, "nothing was written")

  -- free: written, and the lock is released
  local res, err = write(out, quick)
  ok(res ~= nil, "the free folder is written: " .. vim.inspect(err))
  eq(vim.uv.fs_stat(lock .. ".lock"), nil, "the lock is released after a success")

  -- a refused folder (a failure inside the write) releases the lock as well
  local bad = fx.root .. "/../export-bad"
  fixture.write(bad .. "/foreign.txt", "x\n")
  local r2, e2 = write(bad, quick)
  eq(r2, nil, "a folder that is not the export's is refused")
  ok(e2 ~= nil, "with an error")
  eq(
    vim.uv.fs_stat(folder.lock_path(bad, fx.state) .. ".lock"),
    nil,
    "the lock is released after a failure"
  )

  -- another folder is not blocked by the first
  local other = fx.root .. "/../export-other"
  local blocked
  statelock.with(lock, function()
    blocked = write(other, quick)
  end)
  ok(blocked ~= nil, "a lock on one folder does not block another")

  -- a state directory that cannot be written is no second writer: its own message, exit 3
  local blocker = fx.root .. "/../not-a-dir"
  fixture.write(blocker, "x\n")
  local r3, e3 = write(fx.root .. "/../export-nolock", { state_dir = blocker .. "/state" })
  eq(r3, nil, "no lock, no write")
  eq(e3 and e3.code, 3, "exit 3, not 2")
  has(e3 and e3.message, "cannot lock", "and the message names the lock, not another writer")
  eq(vim.uv.fs_stat(fx.root .. "/../export-nolock"), nil, "nothing was written")

  vim.fn.delete(base, "rf")
end
