-- TESTS/testing/live_follow_spec.lua -- testing.bindings.live: a run started from the editor, followed through its
-- event file. Nobody listening means no file, no flag and no timer; a listener gets the events in batches as the
-- file grows, also a line that arrives in two pieces; the end of the process ends the stream (a run that was
-- killed gets its `run_done` from the reader), closes the timer and removes the file. And the child: `--events`
-- reaches the command line of a run exactly when somebody listens.

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local follow = require("testing.bindings.live")
  local child = require("testing.bindings.child")
  local events = require("testing.run.events")
  local uv = vim.uv or vim.loop

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local begin_opts = { state_opts = { state_dir = sdir }, poll_ms = 10 }

  local function timers()
    local n = 0
    uv.walk(function(handle)
      if handle:get_type() == "timer" and not handle:is_closing() then
        n = n + 1
      end
    end)
    return n
  end
  local function append(path, text)
    local f = assert(io.open(path, "ab"))
    f:write(text)
    f:close()
  end
  local function line(kind, fields)
    return assert(events.line(kind, fields, { run = 1, ts = 1 }))
  end

  -- nobody listens ----------------------------------------------------------------------
  local timers_before = timers()
  eq(follow.wanted(), false, "nobody listens")
  eq(follow.begin(root, begin_opts), nil, "... so a run is not followed")
  eq(uv.fs_stat(follow.dir(root, begin_opts.state_opts)) ~= nil, false, "... no folder is made")
  eq(timers(), timers_before, "... and no timer started")

  local got = {}
  local unlisten = follow.listen(function(r, batch)
    got[#got + 1] = {
      root = r,
      kinds = vim.tbl_map(function(ev)
        return ev.event
      end, batch),
      batch = batch,
    }
  end)
  local worked, err = pcall(function()
    eq(follow.wanted(), true, "somebody listens")

    -- a run that ends ---------------------------------------------------------------------
    local run = follow.begin(root, begin_opts)
    ok(run ~= nil, "a run is followed")
    eq(
      vim.fs.dirname(vim.fs.normalize(run.path)),
      vim.fs.normalize(follow.dir(root, begin_opts.state_opts)),
      "its events go to a folder of their own below the state folder of the project"
    )
    ok(uv.fs_stat(run.path) ~= nil, "the file is there before the child opens it")
    eq({ follow.active(), timers() }, { 1, timers_before + 1 }, "one run, one timer")

    append(run.path, line("run_start", { files = { "TESTS/a_spec.lua" } }) .. "\n")
    vim.wait(2000, function()
      return #got >= 1
    end, 5)
    eq(
      { got[1] and got[1].root, got[1] and got[1].kinds },
      { root, { "run_start" } },
      "a line written to the file reaches the listener, with the root of the run"
    )

    local case = line("case", {
      file = "TESTS/a_spec.lua",
      id = "TESTS/a_spec.lua::d::one",
      status = "pass",
      duration_ms = 3,
    })
    append(run.path, line("file_start", { file = "TESTS/a_spec.lua" }) .. "\n" .. case:sub(1, 20))
    vim.wait(2000, function()
      return #got >= 2
    end, 5)
    eq(got[2] and got[2].kinds, { "file_start" }, "half a line is not an event yet")
    append(run.path, case:sub(21) .. "\n" .. line("run_done", { exit_code = 0 }) .. "\n")
    run.finish(0)
    local kinds = {}
    for i = 3, #got do
      vim.list_extend(kinds, got[i].kinds)
    end
    eq(
      kinds,
      { "case", "run_done" },
      "the rest of the line and the end arrive, at the latest when the process ends"
    )
    eq(got[#got].batch[#got[#got].batch].synthetic, nil, "the end is the one the run wrote")
    eq(
      { follow.active(), timers(), uv.fs_stat(run.path) ~= nil },
      { 0, timers_before, false },
      "after the run: no run followed, no timer more than before, the file is gone"
    )
    local count = #got
    run.finish(0)
    eq(#got, count, "finish twice tells nothing twice")

    -- a run that is killed ------------------------------------------------------------------
    got = {}
    run = follow.begin(root, begin_opts)
    append(
      run.path,
      line("run_start", {}) .. "\n" .. line("file_start", { file = "x_spec.lua" }) .. "\n"
    )
    run.finish(nil)
    local all = {}
    for _, batch in ipairs(got) do
      vim.list_extend(all, batch.batch)
    end
    eq(
      vim.tbl_map(function(ev)
        return ev.event
      end, all),
      { "run_start", "file_start", "run_done" },
      "a stream without an end gets one"
    )
    eq(
      { all[3].aborted, all[3].synthetic },
      { true, true },
      "... marked as made up by the reader: the run was killed"
    )
    eq({ follow.active(), timers() }, { 0, timers_before }, "... and nothing is left of it either")

    -- what is no event is no event -------------------------------------------------------------
    got = {}
    run = follow.begin(root, begin_opts)
    append(
      run.path,
      "not json\n" .. '{"v":1,"event":"case","file":"a","id":"a::b","status":"dancing"}\n'
    )
    run.finish(1)
    eq(#got, 1, "junk in the file is not handed on")
    eq(got[1].kinds, { "run_done" }, "... only the end of the stream is")

    -- the child ---------------------------------------------------------------------------------
    local argv = child.build_argv("run", { root = root, events = "E:/x/events.ndjson" })
    ok(
      vim.tbl_contains(argv, "--events=E:/x/events.ndjson"),
      "build_argv: events is a flag of a run"
    )
    eq(
      vim.tbl_contains(child.build_argv("list", { root = root, events = "x" }), "--events=x"),
      false,
      "... of a run only"
    )

    local seen
    local function system(cmd, _, on_exit)
      seen = cmd
      on_exit({ code = 3, stdout = "", stderr = "" })
      return {}
    end
    local function events_flag()
      for _, arg in ipairs(seen or {}) do
        if arg:match("^%-%-events=") then
          return arg:sub(#"--events=" + 1)
        end
      end
      return nil
    end
    local verdicts = 0
    local function done()
      verdicts = verdicts + 1
    end
    got = {}
    eq(
      child.start("run", { root = root, system = system, live = begin_opts }, done),
      true,
      "a run starts"
    )
    local path = events_flag()
    ok(path ~= nil, "while somebody listens the run gets --events")
    ok(path:find("/live/events-", 1, true) ~= nil, "... a file of the live folder of the project")
    vim.wait(2000, function()
      return verdicts == 1
    end, 5)
    eq(verdicts, 1, "the verdict is reported as ever")
    eq(got[#got] and got[#got].kinds, { "run_done" }, "the end of the process ends the stream")
    eq(
      { follow.active(), timers(), uv.fs_stat(path) ~= nil },
      { 0, timers_before, false },
      "... and releases the timer and the file"
    )

    eq(
      child.start("run", { root = root, system = system, events = "E:/mine.ndjson" }, done),
      true,
      "a run with an event file of the caller's"
    )
    eq(events_flag(), "E:/mine.ndjson", "... keeps it: nothing is followed in its place")
    vim.wait(2000, function()
      return verdicts == 2
    end, 5)

    unlisten()
    eq(follow.wanted(), false, "the listener is gone")
    eq(
      child.start("run", { root = root, system = system, live = begin_opts }, done),
      true,
      "a run starts"
    )
    eq(events_flag(), nil, "nobody listens: the run gets no --events")
    vim.wait(2000, function()
      return verdicts == 3
    end, 5)
    eq(timers(), timers_before, "no timer is left")
  end)
  unlisten()
  vim.fn.delete(sdir, "rf")
  vim.fn.delete(root, "rf")
  if not worked then
    error(err, 0)
  end
end
