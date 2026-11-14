-- TESTS/testing/tree_live_spec.lua -- a run that is going, in the tree: one case of the stream into the store
-- (`testing.state.apply_case`), the marks `queued` and `running` over the last result (`testing.explorer.live`),
-- the nodes that change without a walk of the tree (`nodes.set_many`), and `testing.integrations.tree` told a
-- recorded stream of events: every case moves its node, what is above it and the badge of its file, and at the end
-- what is shown is what a fresh read of the stored result gives. The stream is written by the real emitter and read
-- by the real reader; the registry is lib.nvim's own.

-- the case body is the guard: an assertion before each use proves the value, and a nil raises and fails the case
---@diagnostic disable: need-check-nil, duplicate-set-field

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local state = require("testing.state")
  local result = require("testing.core.result")
  local live = require("testing.explorer.live")
  local nodes = require("testing.explorer.nodes")
  local tree = require("testing.integrations.tree")
  local follow = require("testing.bindings.live")
  local events = require("testing.run.events")
  local reader_mod = require("testing.run.events_reader")
  local registry = require("lib.nvim.tree.registry")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  local sopts = { state_dir = sdir }
  local A, B, NEW = "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/new_spec.lua"
  for _, rel in ipairs({ A, B, NEW }) do
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ 'describe("d", function() end)' }, path)
  end

  ---@param cases table[]  { file, name, status, ms }
  local function ir(cases, id)
    local res = result.new({ root = root, id = id or "2026-01-01T00:00:00Z-0001" })
    for _, c in ipairs(cases) do
      local case = result.new_case({ file = c[1], describe = { "d" }, name = c[2], line = 2 })
      case.status = c[3]
      case.duration_ms = c[4] or 1
      if c[3] == "fail" then
        case.assertions = { { ok = false, msg = "was wrong", line = 3 } }
      end
      result.add_case(res, case)
    end
    return result.finalize(res)
  end
  local function id_of(file, name)
    return file .. "::d::" .. name
  end
  local FIRST = {
    { A, "one", "pass" },
    { A, "two", "fail" },
    { B, "one", "pass" },
    { B, "two", "pass" },
  }
  local SECOND = {
    { A, "one", "pass", 5 },
    { A, "two", "pass", 6 },
    { B, "one", "fail", 7 },
    { B, "two", "pass", 8 },
    { NEW, "fresh", "pass", 9 },
  }
  local ran_all = { ran_files = { [A] = true, [B] = true, [NEW] = true } }

  ---The events the real emitter writes for a run of `cases`, read back by the real reader.
  ---@param cases table[]
  ---@param upto? integer  Stop after this many events (a run that was killed).
  ---@return table[] events
  local function stream(cases, upto)
    local lines = {}
    local em = events.new(function(line)
      lines[#lines + 1] = line
      return true
    end, { run = 1 })
    local res = ir(cases, "2026-01-02T00:00:00Z-0002")
    local files, seen = {}, {}
    for _, c in ipairs(res.cases) do
      if not seen[c.file] then
        seen[c.file] = true
        files[#files + 1] = c.file
      end
    end
    em:start({ project = "p", files_total = #files, files_selected = #files, files = files })
    local open
    for _, c in ipairs(res.cases) do
      if c.file ~= open then
        if open then
          em:file_end(open)
        end
        open = c.file
        em:file_start(open)
      end
      em:case(c)
    end
    if open then
      em:file_end(open)
    end
    em:done(1, res)
    local out = {}
    local reader = reader_mod.new({
      on_event = function(ev)
        out[#out + 1] = ev
      end,
    })
    for i, line in ipairs(lines) do
      if not upto or i <= upto then
        reader:feed(line .. "\n")
      end
    end
    if upto then
      reader:finish(nil)
    end
    return out
  end

  ---@return Testing.State
  local function first_state()
    local st = state.new(root)
    state.apply(st, ir(FIRST), { ran_files = { [A] = true, [B] = true } })
    return st
  end

  -- one case into the store -----------------------------------------------------------
  do
    local st = first_state()
    local told = 0
    state.subscribe(st, function(_, event)
      told = told + (event == "case" and 1 or 0)
    end)
    local two = state.case(st, id_of(A, "two"))
    eq(two.message, "was wrong", "the red case has what it said")
    local same = state.apply_case(st, { id = two.id, file = A, status = "fail", duration_ms = 40 })
    eq(
      { same == two, two.duration_ms, two.message },
      { true, 40, "was wrong" },
      "the same status again: the duration moves, what it said stays"
    )
    state.apply_case(st, { id = two.id, file = A, status = "pass", duration_ms = 41 })
    eq(
      { two.status, two.message, two.fails, st.summary.fail, st.summary.pass },
      { "pass", nil, nil, 0, 4 },
      "another status: the text of the old outcome is gone, the counters follow"
    )
    local added = state.apply_case(
      st,
      { id = id_of(NEW, "fresh"), file = NEW, status = "skip", duration_ms = 0 }
    )
    eq(
      { added.name, state.case(st, added.id) == added, st.summary.skip, #st.cases },
      { "fresh", true, 1, 5 },
      "a case the store does not know is added, named after the end of its id"
    )
    eq(told, 3, "every one is told to the subscribers as `case`")
    eq(st.files[NEW], nil, "a case of a run in progress is no record of its file")
    for name, bad in pairs({
      ["a status nobody knows"] = { id = "x::y", file = A, status = "running", duration_ms = 1 },
      ["a file outside the project"] = {
        id = "x::y",
        file = "../x.lua",
        status = "pass",
        duration_ms = 1,
      },
      ["no duration"] = { id = "x::y", file = A, status = "pass" },
      ["the id of a case of another file"] = {
        id = two.id,
        file = B,
        status = "fail",
        duration_ms = 1,
      },
      ["not a table"] = "junk",
    }) do
      eq(state.apply_case(st, bad), nil, "refused: " .. name)
    end
    eq({ #st.cases, two.status, told }, { 5, "pass", 3 }, "... and nothing changed for it")
  end

  -- the marks ---------------------------------------------------------------------------
  do
    local st = first_state()
    local session = live.new(st)
    local evs = stream(SECOND)
    eq(
      vim.tbl_map(function(ev)
        return ev.event
      end, evs),
      {
        "run_start",
        "file_start",
        "case",
        "case",
        "file_end",
        "file_start",
        "case",
        "case",
        "file_end",
        "file_start",
        "case",
        "file_end",
        "run_done",
      },
      "the stream of the run"
    )
    local dirty = live.feed(session, evs[1])
    eq(
      { live.status(session, id_of(A, "one")), live.status(session, id_of(B, "two")) },
      { "queued", "queued" },
      "run_start: the cases of the planned files are queued"
    )
    eq(session.file_marks[NEW], "queued", "... a file the store has no case of is queued as a file")
    eq(vim.tbl_count(dirty.cases), 4, "... and every one of them is to be drawn again")
    eq(state.case(st, id_of(A, "two")).status, "fail", "a mark is no status of the store")

    dirty = live.feed(session, evs[2])
    eq(
      { live.status(session, id_of(A, "one")), live.status(session, id_of(B, "one")) },
      { "running", "queued" },
      "file_start: the cases of that file are running, the others wait"
    )
    eq(dirty.files, { [A] = true }, "... one file changed")
    eq(live.file_summary(session, A).mark, "running", "the summary of a running file says so")

    dirty = live.feed(session, evs[3])
    dirty = live.feed(session, evs[4], dirty)
    eq(
      { live.status(session, id_of(A, "one")), live.status(session, id_of(A, "two")) },
      { "pass", "pass" },
      "case: the result replaces the mark"
    )
    eq(dirty.cases, {
      [id_of(A, "one")] = true,
      [id_of(A, "two")] = true,
    }, "... two events, one answer")
    eq(session.fresh[A], true, "the file has a result of this run")
    eq(
      { live.file_summary(session, A).mark, live.file_summary(session, A).red },
      { nil, 0 },
      "the summary of the file as the run stands"
    )

    -- a run narrowed to one case: the other case of the file gets no result
    local narrow = live.new(first_state())
    live.feed(narrow, { event = "file_start", file = B })
    live.feed(
      narrow,
      { event = "case", file = B, id = id_of(B, "one"), status = "fail", duration_ms = 2 }
    )
    eq(live.status(narrow, id_of(B, "two")), "running", "a case without a result yet is running")
    dirty = live.feed(narrow, { event = "file_end", file = B })
    eq(
      { live.status(narrow, id_of(B, "two")), dirty.cases[id_of(B, "two")] },
      { "pass", true },
      "file_end: a case that got no result shows what it showed before"
    )

    -- killed: the reader ends the stream itself
    local killed = live.new(first_state())
    local cut = stream(SECOND, 3)
    eq(
      { cut[#cut].event, cut[#cut].aborted, cut[#cut].synthetic },
      { "run_done", true, true },
      "a stream that stops gets its end from the reader"
    )
    local last
    for _, ev in ipairs(cut) do
      last = live.feed(killed, ev)
    end
    eq(
      { last.done, next(killed.marks), next(killed.file_marks), killed.active },
      { true, nil, nil, false },
      "run_done: no mark is left, whether the run ended or was killed"
    )
    eq(last.cases[id_of(A, "two")], true, "... and what was marked is to be drawn again")
    eq(live.feed(killed, "junk").done, false, "what is no event changes nothing")

    -- a file name that points out of the project is nobody's file
    local hostile = live.new(first_state())
    local none = live.feed(
      hostile,
      { event = "run_start", files = { "../../etc/x_spec.lua", "C:/x_spec.lua" } }
    )
    none = live.feed(hostile, { event = "file_start", file = "/abs/x_spec.lua" }, none)
    none = live.feed(
      hostile,
      {
        event = "case",
        file = "../x_spec.lua",
        id = "../x_spec.lua::a",
        status = "pass",
        duration_ms = 1,
      },
      none
    )
    eq(
      { next(none.files), next(none.cases), next(hostile.file_marks), #hostile.st.cases },
      { nil, nil, nil, 4 },
      "a file outside the project is not marked, not stored and never looked at"
    )
  end

  -- nodes that change without a walk -------------------------------------------------------
  do
    local st = first_state()
    local top = nodes.build({ root = root, cases = st.cases, files = { NEW } })
    local index = nodes.index(top)
    local two = index.by_case[id_of(A, "two")]
    eq({ two.status, index.by_file[A].columns[1] }, { "fail", "1/2" }, "before: one red of two")
    local updates = nodes.set_many(index, {
      { id = two.data.testing.case, status = "pass", duration_ms = 30 },
      { id = "nobody::knows", status = "fail" },
    })
    eq(
      vim.tbl_map(function(u)
        return u.id
      end, updates),
      {
        two.id,
        "tests:describe:" .. A .. "::d",
        "tests:file:" .. A,
        "tests:dir:TESTS",
      },
      "the case and what is above it, deepest first; an unknown case is nobody's"
    )
    eq(
      { updates[1].status, updates[1].icon, updates[1].columns },
      { "pass", "✓", { "30ms" } },
      "the update of the case: what emit.push takes"
    )
    eq(
      { updates[3].icon, updates[3].columns, updates[3].status },
      { "✓", { "2", "31ms" }, nil },
      "the update of its file: the sign, the count and the time again"
    )
    eq(index.by_file[A].open, true, "what was open stays as it is: a change is no reason to fold")
    updates = nodes.set_many(index, { { file = NEW, status = "running" } })
    eq(
      { updates[1].id, updates[1].status, updates[1].icon, updates[1].columns },
      { "tests:file:" .. NEW, "running", "●", {} },
      "a file without cases in the tree changes as a file"
    )
    eq(index.top.children[1].icon, "●", "... and its folder is running")
    eq(
      #nodes.set_many(index, { { file = A, status = "running" } }),
      0,
      "a file that has cases in the tree does not"
    )
    local marked = nodes.build({
      root = root,
      cases = st.cases,
      stale = { [A] = true },
      live = { [id_of(A, "one")] = "running" },
    })
    eq(
      nodes.index(marked).by_case[id_of(A, "one")].status,
      "running",
      "build: a mark is drawn instead of the recorded status, stale or not"
    )
  end

  -- the tree, told a recorded run ----------------------------------------------------------------
  registry.reset()
  local real_load = state.load
  local finish = function()
    state.load = real_load
    tree.unregister()
    registry.reset()
  end
  local worked, err = pcall(function()
    -- the result before the run is on disk, as a run leaves it
    assert(state.record(root, ir(FIRST), { ran_files = { [A] = true, [B] = true } }, sopts))
    eq(follow.wanted(), false, "nobody listens before a tree reads the entries")
    tree.register({
      root = function()
        return root
      end,
      state_opts = sopts,
    })
    local source, decorator = registry.get("source", "tests"), registry.get("decorator", "tests")
    local keys = {}
    local stop_badges = decorator.subscribe(function(paths)
      for _, path in ipairs(paths or {}) do
        keys[#keys + 1] = path
      end
    end)
    eq(follow.wanted(), true, "a tree that draws the badges listens to the runs of this editor")
    local top = source.root({})
    local pushed, resets = {}, 0
    local stop_view = source.subscribe({}, {
      push = function(update)
        pushed[#pushed + 1] = update
      end,
      reset = function()
        resets = resets + 1
      end,
      invalidate = function() end,
    })
    local function node(id)
      local index = nodes.index(top)
      return index.by_case[id]
    end
    local function last_push(id)
      for i = #pushed, 1, -1 do
        if pushed[i].id == id then
          return pushed[i]
        end
      end
      return nil
    end
    local function key(rel)
      return nodes.norm(root .. "/" .. rel)
    end
    eq(decorator.get(key(A)).text, "✗ 1/2", "before the run: the badge of the red file")

    local evs = stream(SECOND)
    tree.on_events("/somewhere/else", { evs[1] })
    eq(#pushed, 0, "the run of another project is not this tree's")

    tree.on_events(root, { evs[1] })
    eq(
      last_push("tests:case:" .. id_of(A, "one")).status,
      "queued",
      "run_start: a case is pushed as queued"
    )
    eq(decorator.get(key(A)).status, "running", "... and the badge of its file says a run is going")
    ok(vim.tbl_contains(keys, key(A)), "... told to the tree by its path")
    eq(
      last_push("tests:file:" .. NEW).status,
      "queued",
      "... a file that never ran is queued as a file"
    )

    tree.on_events(root, { evs[2], evs[3] })
    local one = last_push("tests:case:" .. id_of(A, "one"))
    eq(
      { one.status, one.icon, one.columns },
      { "pass", "✓", { "5ms" } },
      "case: the node gets its result, sign and time in one update"
    )
    eq(
      last_push("tests:case:" .. id_of(A, "two")).status,
      "running",
      "... while the next case of the file is running"
    )
    eq(last_push("tests:file:" .. A).icon, "●", "... and so is the file above it")
    eq(node(id_of(A, "one")).status, "pass", "the nodes the tree holds were changed in place")

    -- the view is built again in the middle of the run (a reset of the tree): the marks are in it
    top = source.root({})
    eq(node(id_of(A, "two")).status, "running", "a root built during the run carries its marks")
    eq(nodes.index(top).by_file[NEW].status, "queued", "... the mark of a file that never ran too")

    tree.on_events(root, { evs[4], evs[5] })
    eq(decorator.get(key(A)).text, "✓", "file done: its badge is what its cases say, not stale")
    eq(
      last_push("tests:file:" .. A).columns,
      { "2", "11ms" },
      "... and the file counts no red case"
    )

    tree.on_events(root, { evs[6], evs[7], evs[8], evs[9], evs[10], evs[11], evs[12] })
    eq(decorator.get(key(B)).text, "✗ 1/2", "a case that turned red moves the badge of its file")
    eq(
      last_push("tests:file:" .. NEW).status,
      "pass",
      "a file that never ran shows the result of its case"
    )

    -- the end: the run stored its result, the stream says done
    local shown_before = {}
    for _, c in ipairs(SECOND) do
      local n = node(id_of(c[1], c[2]))
      shown_before[id_of(c[1], c[2])] = n and n.status or last_push("tests:file:" .. c[1]).status
    end
    assert(state.record(root, ir(SECOND, "2026-01-02T00:00:00Z-0002"), ran_all, sopts))
    local before = resets
    tree.on_events(root, { evs[13] })
    ok(resets > before, "run_done: the stored result is read and the view asked to build again")
    top = source.root({})
    local reread = state.load(root, sopts)
    local shown_after, on_disk = {}, {}
    for _, c in ipairs(reread.cases) do
      on_disk[c.id] = c.status
      shown_after[c.id] = node(c.id).status
    end
    eq(shown_after, on_disk, "after the run the view shows what a fresh read of the result gives")
    eq(shown_before, on_disk, "... and so did the live state right before the end")
    eq(decorator.get(key(B)).text, "✗ 1/2", "... the badges too")

    -- a run that is killed: the last good result stays, nothing is left running
    local cut = stream(FIRST, 3)
    tree.on_events(root, { cut[1], cut[2], cut[3] })
    eq(decorator.get(key(A)).status, "running", "a second run starts")
    tree.on_events(root, { cut[#cut] })
    top = source.root({})
    local running = {}
    for id, n in pairs(nodes.index(top).by_case) do
      if n.status == "running" or n.status == "queued" then
        running[#running + 1] = id
      end
    end
    eq(running, {}, "killed: no node stays running or queued")
    eq(
      { decorator.get(key(A)).text, node(id_of(B, "one")).status },
      { "✓", "fail" },
      "... and the last good result is what is shown"
    )

    stop_view()
    eq(follow.wanted(), true, "the badges still listen")
    stop_badges()
    eq(follow.wanted(), false, "no tree, nobody listens: a run is not followed")
    local count = #pushed
    tree.on_events(root, { evs[1] })
    eq(#pushed, count, "... and an event that still arrives is nobody's")
  end)
  finish()
  if not worked then
    error(err, 0)
  end
end
