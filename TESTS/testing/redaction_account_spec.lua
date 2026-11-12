-- TESTS/testing/redaction_account_spec.lua -- the redaction of a free text (`testing.run.inproc.redact_text`, the
-- trace of `testing.rpc.trace`) asks the system for the account once per process, not on every text: the account
-- cannot change while the process runs. The environment can (a spec sets `vim.env`), so a variable set after the first
-- text is still redacted in the next one.

return function(H)
  local ok, eq = H.ok, H.eq
  local inproc = require("testing.run.inproc")
  local trace = require("testing.rpc.trace")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-redact"
  vim.fn.mkdir(root, "p")

  local function write_trace(text)
    local path = root .. "/trace.json"
    local art, err = trace.write({ calls = { { text = text } } }, { root = root, path = path })
    ok(art ~= nil, "trace.write: " .. tostring(err))
    local fh = assert(io.open(path, "rb"))
    local s = fh:read("a")
    fh:close()
    return s
  end

  -- the first text of this process may ask; after that nobody does
  inproc.redact_text("warm up", root)
  write_trace("warm up")
  local real, asked = vim.uv.os_get_passwd, 0
  vim.uv.os_get_passwd = function(...)
    asked = asked + 1
    return real(...)
  end
  local pass, perr = pcall(function()
    for _ = 1, 3 do
      inproc.redact_text("a text", root)
      write_trace("a text")
    end
  end)
  vim.uv.os_get_passwd = real
  ok(pass, "the texts are redacted: " .. tostring(perr))
  eq(asked, 0, "the account is asked once per process, not per text")

  -- the environment is read on every call: a variable set now is redacted in the next text
  local name = "TESTING_REDACT_PROBE_" .. tostring(vim.uv.hrtime() % 100000)
  vim.env[name] = "probe-value-7f3a"
  local out = inproc.redact_text(name .. "=probe-value-7f3a", root)
  local traced = write_trace(name .. "=probe-value-7f3a")
  vim.env[name] = nil
  ok(
    not out:find("probe-value-7f3a", 1, true),
    "redact_text: a variable set after the first text: " .. out
  )
  ok(not traced:find("probe-value-7f3a", 1, true), "trace: the same: " .. traced)

  vim.fn.delete(root, "rf")
end
