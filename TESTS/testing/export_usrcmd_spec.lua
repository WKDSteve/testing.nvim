-- TESTS/testing/export_usrcmd_spec.lua -- `:Testing export`: which folder and repositories the child gets, what stops it
-- before it starts, what the person is told at its end, and one real run of the child.

---@diagnostic disable: assign-type-mismatch, missing-fields, need-check-nil, param-type-mismatch
---@diagnostic disable: duplicate-set-field

return function(H)
  local ok = H.ok
  local eq = H.eq
  local config = require("testing.config")
  local editor = require("testing.ci.editor")
  local notify_mod = require("testing.notify")
  local usrcmds = require("testing.bindings.usrcmds")

  local real_get, real_system, real_ask = notify_mod.get, editor.system, usrcmds.ask
  local said = {}
  local function say(level)
    return function(text)
      said[#said + 1] = { level = level, text = text }
    end
  end
  notify_mod.get = function()
    return { info = say("info"), warn = say("warn"), error = say("error") }
  end
  local function restore()
    notify_mod.get, editor.system, usrcmds.ask = real_get, real_system, real_ask
    config.reset()
  end

  local function joined(argv)
    return table.concat(argv, " ")
  end
  local function has(text, needle, msg)
    ok(text:find(needle, 1, true) ~= nil, ("%s: %q not in %q"):format(msg, needle, text))
  end
  local function hasnt(text, needle, msg)
    ok(text:find(needle, 1, true) == nil, ("%s: %q in %q"):format(msg, needle, text))
  end

  ---Run the command with a fake process that answers `res`; the argument lists it got.
  local function run(ctx, res)
    said = {}
    local calls = {}
    editor.system = function(argv, opts, cb)
      calls[#calls + 1] = { argv = argv, opts = opts }
      cb(res or { code = 0, stdout = "export: 2 repositories to /out\n", stderr = "" })
      return {}
    end
    usrcmds.export_run(ctx)
    vim.wait(50, function()
      return false
    end)
    return calls
  end
  local function last_said()
    return said[#said] or { text = "" }
  end

  local passed, problem = pcall(function()
    -- stopped before anything starts: no folder, no repositories, a wrong word
    config.setup({ ci = { repos = { roots = { "/r1" } } } })
    eq(#run({ args = {}, flags = {} }), 0, "no folder: nothing starts")
    has(last_said().text, "ci.export_dir", "no folder: says what to set")
    eq(#run({ args = { dir = "/out" }, flags = { remote = "sometimes" } }), 0, "wrong --remote")
    has(last_said().text, "always, never or ask", "wrong --remote: says the words")
    config.setup({ ci = { export_dir = "/out" } })
    eq(#run({ args = {}, flags = {} }), 0, "no repositories: nothing starts")
    has(last_said().text, "ci.repos.roots", "no repositories: says what to set")

    -- the setting, its exclude; include has another meaning in the export and stays out
    config.setup({
      ci = {
        export_dir = "/from-setting",
        repos = { roots = { "/r1", "/r2" }, include = { "only" }, exclude = { "scratch" } },
      },
    })
    local argv = joined(run({ args = {}, flags = {} })[1].argv)
    has(argv, "export --out=", "the subcommand")
    has(argv, "from-setting", "the folder of the setting")
    has(argv, "--repos-root=/r1", "first root")
    has(argv, "--repos-root=/r2", "second root")
    has(argv, "--exclude=scratch", "exclude")
    hasnt(argv, "--include", "include")
    hasnt(argv, "--root=", "no project root: the CLI would refuse it")
    has(argv, "--remote", "the default of ci.export_remote asks")

    -- the argument and the flags win; a relative folder is the one named here, not one below the child's cwd
    local calls = run({
      args = { dir = "rel-out" },
      flags = { ["repos-root"] = "/other", remote = "never" },
    })
    argv = joined(calls[1].argv)
    has(argv, "--out=" .. vim.fs.normalize(vim.fn.fnamemodify("rel-out", ":p")), "absolute folder")
    has(argv, "--repos-root=/other", "the flag replaces the roots")
    hasnt(argv, "/r1", "the roots of the setting are gone")
    hasnt(argv, "--remote", "never: GitHub is not asked")
    eq(calls[1].opts.timeout, editor.EXPORT_TIMEOUT * 1000, "more time than a short child")

    -- a setting may name a variable, as `ci.repos.roots` may: it is not a folder below the current one
    vim.env.TESTING_EXPORT_SPEC_DIR = "/env-out"
    config.setup({
      ci = { export_dir = "$TESTING_EXPORT_SPEC_DIR/x", repos = { roots = { "/r" } } },
    })
    argv = joined(run({ args = {}, flags = {} })[1].argv)
    vim.env.TESTING_EXPORT_SPEC_DIR = nil
    has(argv, "--out=" .. vim.fs.normalize(vim.fn.fnamemodify("/env-out/x", ":p")), "$VAR folder")

    -- ask: the answer goes to the child, Esc starts nothing
    config.setup({ ci = { repos = { roots = { "/r1" } }, export_remote = "ask" } })
    local answer, dismissed = 2, false
    usrcmds.ask = function(_, _, cb)
      cb(answer, dismissed)
    end
    has(joined(run({ args = { dir = "/o" }, flags = {} })[1].argv), "--remote", "ask: yes")
    answer = 1
    hasnt(joined(run({ args = { dir = "/o" }, flags = {} })[1].argv), "--remote", "ask: no")
    dismissed = true
    eq(#run({ args = { dir = "/o" }, flags = {} }), 0, "ask: Esc starts nothing")
    has(last_said().text, "cancelled", "ask: Esc says so")
    usrcmds.ask = real_ask

    -- what the person is told at the end
    config.setup({ ci = { repos = { roots = { "/r1" } } } })
    local ctx = { args = { dir = "/o" }, flags = {} }
    run(ctx)
    eq(last_said().level, "info", "written: a message")
    has(last_said().text, "export: 2 repositories", "written: the summary")

    run(ctx, { code = 0, stdout = "export: 0 repositories to /o\n", stderr = "" })
    eq(last_said().level, "warn", "nothing released: no success")
    has(last_said().text, "areas.json", "nothing released: says where to look")

    run(ctx, { code = 2, stdout = "", stderr = "testing export: /o is not an export folder\n" })
    eq(last_said().level, "error", "refused: an error")
    has(last_said().text, "not an export folder", "refused: the reason")

    run(ctx, { code = 124, stdout = "", stderr = "" })
    has(last_said().text, "exit 124", "killed without a word: still says something")

    local shown
    local real_output = package.loaded["lib.nvim.output"]
    package.loaded["lib.nvim.output"] = {
      create = function()
        return {
          dump = function(lines)
            shown = lines
          end,
        }
      end,
    }
    run(ctx, {
      code = 0,
      stdout = "export: 2 repositories to /o\n",
      stderr = "testing export: warning: first\ntesting export: warning: second\n",
    })
    eq(last_said().level, "info", "warnings: still written")
    eq(shown and shown[2], "testing export: warning: second", "warnings: in a viewer")
    shown = nil
    run(ctx, { code = 2, stdout = "", stderr = "testing export: one line\n" })
    eq(shown, nil, "one line of a refusal: the message says it all")
    package.loaded["lib.nvim.output"] = real_output

    -- a process that cannot start
    said = {}
    editor.system = function()
      error("no such program")
    end
    usrcmds.export_run(ctx)
    has(last_said().text, "no such program", "cannot start: says why")
    eq(last_said().level, "error", "cannot start: an error")
    editor.system = real_system

    -- a setting that is no folder costs only itself
    config.setup({ ci = { export_dir = 1, repos = { roots = { "/kept" } } } })
    eq(config.get().ci.export_dir, nil, "a wrong export_dir is dropped")
    eq(config.get().ci.repos.roots, { "/kept" }, "the rest of ci stays")
  end)
  restore()
  if not passed then
    error(problem, 0)
  end

  -- the real child: the arguments are ones the CLI takes, and the folder is written for the page
  local base = vim.fn.tempname()
  local repo = base .. "/repos/one.nvim"
  vim.fn.mkdir(repo .. "/lua", "p")
  local file = assert(io.open(repo .. "/.testing.lua", "w"))
  file:write("return {}\n")
  file:close()
  local out = base .. "/out"
  local res
  local started = editor.run_export(
    editor.export_argv({ out = out, roots = { base .. "/repos" } }),
    base,
    function(r)
      res = r
    end
  )
  ok(started, "real child: starts")
  ok(
    vim.wait(60000, function()
      return res ~= nil
    end),
    "real child: ends"
  )
  eq(res.code, 0, "real child: exit 0, stderr: " .. tostring(res.stderr))
  has(res.stdout, "export:", "real child: the summary")
  eq(vim.fn.filereadable(out .. "/testing-export.json"), 1, "real child: the manifest of the page")
  eq(vim.fn.filereadable(out .. "/fleet.json"), 1, "real child: the fleet")
  vim.fn.delete(base, "rf")
end
