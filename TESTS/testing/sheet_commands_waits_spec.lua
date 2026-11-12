-- TESTS/testing/sheet_commands_waits_spec.lua -- the sheet testing.commands waits for the END of each `:Testing <sub>`
-- that runs in a child, not for its start. `testing.bindings.usrcmds` says `testing <sub>: <root>` when the child
-- starts; a wait that this message already satisfies lets the next command run beside the child (surface,
-- conformance and budget at once), and the steps after it missed their deadlines on the hosted runners (macOS step 19,
-- ubuntu step 23 `:checkhealth`). Every wait after such a command is evaluated here with only the start message said
-- and every report shown: it must still be false. And it must end on the child's real verdict (`interpret`), for
-- every exit code a report command can have.
return function(H)
  local ok = H.ok

  local here = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
  local sheet = dofile(here .. "/TESTS/sheets/commands.sheet.lua")
  ok(type(sheet) == "table" and sheet.id == "testing.commands", "the sheet loads")

  -- the sheet's own helpers, from its first step, in an editor that does nothing
  local fake_g = {}
  local noop = function() end
  local fake_vim = {
    fs = {
      normalize = function(p)
        return p
      end,
    },
    fn = {
      tempname = function()
        return "/tmp/x"
      end,
      mkdir = noop,
      writefile = noop,
      fnameescape = function(p)
        return p
      end,
    },
    env = {},
    cmd = { cd = noop },
    api = {
      nvim_list_bufs = function()
        return {}
      end,
    },
  }
  -- `_G` and `vim` are the fakes; the standard library is the real one
  local env = setmetatable({ _G = fake_g, vim = fake_vim }, { __index = _G })
  local setup = assert(load(sheet.steps[1].lua, "=setup", "t", env))
  setup()
  ok(type(fake_g.mark) == "function" and type(fake_g.said) == "function", "the helpers are defined")
  -- the worst case for a wait: every report is already in a buffer
  fake_g.shown = function()
    return true
  end

  -- the subcommands that run in a child (testing.bindings.child), and the commands that start one
  local function child_sub(code)
    local cmd = code:match('vim%.cmd%("Testing ?([%w ]*)"%)')
    if not cmd then
      return nil
    end
    local first = cmd:match("^(%w+)") or ""
    if first == "" or first == "run" or first == "last" or first == "file" then
      return "run"
    end
    for _, sub in ipairs({ "list", "doctor", "conformance", "surface", "budget" }) do
      if first == sub then
        return sub
      end
    end
    return nil
  end

  -- the child's verdict of a green run reads the IR it wrote: one passed spec, as in the fixture project
  local child = require("testing.bindings.child")
  local ir_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ '{"summary":{"pass":1,"skip":0,"xfail":0}}' }, ir_path)

  local pending, checked = nil, 0
  for i, step in ipairs(sheet.steps) do
    if i > 1 and step.lua then
      local sub = child_sub(step.lua)
      if sub then
        fake_g.mark()
        fake_vim.notify(("testing %s: %s"):format(sub, "/tmp/x"))
        pending = sub
      else
        pending = nil
      end
    elseif step.wait and pending then
      local wait = assert(load("return " .. step.wait, "=wait", "t", env))
      local okw, value = pcall(wait)
      ok(okw, ("step %d: the wait runs (%s)"):format(i, tostring(value)))
      ok(
        not value,
        ("step %d (%s): the start of `:Testing %s` must not end the wait: %s"):format(
          i,
          step.note or "",
          pending,
          step.wait
        )
      )
      -- the wait must END on the child's real verdict (testing.bindings.child.interpret), else a broken
      -- `_G.ended` or a changed message would only time out on the runners
      -- a wait on `_G.ended` ends on every verdict (done, findings, failed); one on a green message only on exit 0
      local codes = step.wait:find("_G.ended(", 1, true) and { 0, 1, 2 } or { 0 }
      for _, code in ipairs(codes) do
        fake_g.mark()
        fake_vim.notify(("testing %s: %s"):format(pending, "/tmp/x"))
        local verdict = child.interpret(
          pending,
          { code = code, stdout = "", stderr = "boom" },
          { json = ir_path }
        )
        fake_vim.notify(verdict.message)
        local oke, ended = pcall(wait)
        ok(
          oke and ended == true,
          ("step %d: the end of `:Testing %s` (exit %d, %q) ends the wait: %s"):format(
            i,
            pending,
            code,
            verdict.message,
            tostring(ended)
          )
        )
      end
      checked = checked + 1
      pending = nil
    end
  end
  ok(
    checked >= 7,
    ("every child command of the sheet is followed by a wait that was checked (%d)"):format(checked)
  )
  vim.fn.delete(ir_path)
end
