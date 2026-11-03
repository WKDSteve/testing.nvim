-- TESTS/testing/trust_prompt_many_spec.lua -- `:Testing ci repos` asks once for all the repositories of the run that
-- are not trusted: yes stores each of them, no stores none and the run starts anyway, nothing is asked when all are
-- trusted or when there is no UI, and the repositories of the run are those `repos_args` names.

---@diagnostic disable: duplicate-set-field, missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local trust = require("testing.trust")
  local prompt = require("testing.bindings.trust_prompt")
  local editor = require("testing.ci.editor")

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-trust-many"
  local store = base .. "/state/trust.json"
  local function repo(name)
    local dir = base .. "/repos/" .. name
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "return { ci = { default = 'fast' } }" }, dir .. "/.testing.lua")
    return dir
  end
  local a, b, c = repo("a.nvim"), repo("b.nvim"), repo("c.nvim")
  local dirs = { a, b, c }

  local real = { select = vim.ui.select, interactive = prompt.interactive, ctx = prompt.ctx }
  prompt.ctx = { env = {}, store = store }
  local ui, answer, asked, shown = true, prompt.YES_ALL, 0, nil
  prompt.interactive = function()
    return ui
  end
  vim.ui.select = function(items, opts, cb)
    asked = asked + 1
    shown = opts.prompt
    eq(items, { prompt.YES_ALL, prompt.NO }, "select: yes or no")
    cb(answer)
  end
  local function decide(dir)
    return trust.decide(dir, { env = {}, store = store }).trusted
  end

  -- one is trusted already: the question is about the other two, asked once
  assert(trust.add(b, prompt.ctx))
  eq(prompt.untrusted(dirs), { a, c }, "the untrusted ones are found")
  local done = 0
  local stored
  prompt.ask_many(dirs, function(s)
    done = done + 1
    stored = s
  end)
  eq(asked, 1, "asked once for all of them")
  has(shown, "2 of the repositories", "the question counts them")
  has(shown, "a.nvim, c.nvim", "and names them")
  eq(done, 1, "the run goes on once")
  eq(stored, { a, c }, "both were stored")
  ok(decide(a) and decide(c), "they are trusted now")

  -- nothing left to ask
  asked = 0
  prompt.ask_many(dirs, function() end)
  eq(asked, 0, "all trusted: no question")

  -- no: nothing stored, the run goes on
  os.remove(store)
  asked, answer = 0, prompt.NO
  stored = "unset"
  prompt.ask_many(dirs, function(s)
    stored = s
  end)
  eq(asked, 1, "asked")
  eq(stored, nil, "no: nothing stored")
  ok(not decide(a), "and a stays untrusted")

  -- no UI: no question, the run goes on
  asked, ui = 0, false
  local went = false
  prompt.ask_many(dirs, function()
    went = true
  end)
  eq(asked, 0, "headless: no question")
  ok(went, "headless: the run goes on")

  -- the repositories of the run are those the arguments name
  local listed = editor.repos_dirs({ "--repos-root=" .. base .. "/repos" })
  table.sort(listed)
  eq(
    vim.tbl_map(vim.fs.basename, listed),
    { "a.nvim", "b.nvim", "c.nvim" },
    "repos_dirs: the repositories below the root"
  )
  eq(
    editor.repos_dirs({ "--no-such-option" }),
    {},
    "repos_dirs: arguments that do not parse give none"
  )

  vim.ui.select, prompt.interactive, prompt.ctx = real.select, real.interactive, real.ctx
  vim.fn.delete(base, "rf")
end
