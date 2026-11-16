-- TESTS/testing/ci_runner_guard_share_spec.lua -- the jobs of one run ask GitHub's compare API once (runner-guard rule 6).
-- Six hook processes of one run (`GITHUB_RUN_ID`, `GITHUB_SHA`) start at the same time; a fake `gh` logs every
-- comparison and takes a second to answer. One of them asks, the others wait for its answer and come to the same
-- verdict. Before, six comparisons ran at once and emptied the rate limit (2026-11-14).
-- @cache-allow spawn
-- (it starts editors that run the hook)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.dirname(vim.fs.dirname(here))
  local lib = assert(require("testing.deps").resolve("lib.nvim", repo)).dir

  local SHA0 = string.rep("a", 40)
  local SHA = string.rep("b", 40)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-guard-share"
  vim.fn.mkdir(root, "p")
  local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  write(
    root .. "/reviewed.json",
    vim.json.encode({
      v = 1,
      repos = { ["wkdsteve/tasks.nvim"] = { mode = "auto", shas = { { sha = SHA0, at = 1 } } } },
    })
  )
  write(root .. "/allowed_signers", "me@x ssh-ed25519 AAAA\n")
  -- one file per comparison, not lines appended to one file: two processes appending at the same moment lose a line on
  -- Windows (the C runtime seeks to the end, then writes), and "no run id: no sharing" saw 1 of 2 (run 43921883913)
  local log = root .. "/compare"

  -- one hook process: the check with a fake gh that logs a comparison and answers it a second later
  local script = root .. "/hook.lua"
  write(
    script,
    ([[
local repo, lib, root, log, run_id, attempt = %q, %q, %q, %q, arg[1], arg[2]
vim.opt.rtp:prepend(lib)
vim.opt.rtp:prepend(repo)
local guard = require("testing.ci.runner_guard")
local out = {}
local sv = { out = function(s) out[#out + 1] = s end, err = function(s) out[#out + 1] = s end }
local code = guard.main({ "check" }, sv, {
  env = {
    GITHUB_EVENT_NAME = "push", GITHUB_ACTOR = "WKDSteve", GITHUB_TRIGGERING_ACTOR = "WKDSteve",
    GITHUB_REPOSITORY = "WKDSteve/tasks.nvim", GITHUB_REPOSITORY_OWNER = "WKDSteve",
    GITHUB_SHA = %q, GITHUB_RUN_ID = run_id ~= "-" and run_id or nil, GITHUB_RUN_ATTEMPT = attempt,
  },
  root = root, now = 5, nvim = "/x/nvim", script = "/x/scripts/testing.lua", ssh_keygen = vim.v.progpath,
  gh = function(args)
    if args[4] == ".private" then
      return "false\n"
    end
    if (args[2] or ""):find("/compare/", 1, true) then
      vim.fn.mkdir(log, "p")
      local f = assert(io.open(("%%s/%%d-%%d"):format(log, vim.fn.getpid(), vim.uv.hrtime()), "wb"))
      f:write(args[2] .. "\n")
      f:close()
      vim.uv.sleep(1000)
      return vim.json.encode({ status = "diverged" })
    end
    return nil, "unexpected " .. table.concat(args, " ")
  end,
})
io.stdout:write(table.concat(out, "\n"))
os.exit(code)
]]):format(repo, lib, root, log, SHA)
  )

  ---Start `n` hook processes at once; their exit codes and outputs, and how many comparisons GitHub saw.
  local function jobs(n, run_id, attempt)
    vim.fn.delete(log, "rf")
    local procs = {}
    for i = 1, n do
      procs[i] = vim.system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        script,
        run_id,
        attempt or "1",
      }, { text = true })
    end
    local codes, outs = {}, {}
    for i, p in ipairs(procs) do
      local r = p:wait(60000)
      codes[i], outs[i] = r.code, (r.stdout or "") .. (r.stderr or "")
    end
    local asked = #vim.fn.glob(log .. "/*", true, true)
    return codes, outs, asked
  end

  -- 1. six jobs of one run: one comparison, one verdict -------------------------------------------------------------
  local codes, outs, asked, _ = jobs(6, "777")
  eq(asked, 1, "six jobs of one run ask GitHub once")
  eq(codes, { 1, 1, 1, 1, 1, 1 }, "... and all refuse")
  for i, o in ipairs(outs) do
    ok(
      o:find("none of the last 1 reviewed commits is an ancestor", 1, true) ~= nil,
      ("job %d gives the same reason: %s"):format(i, o)
    )
  end
  ok(vim.uv.fs_stat(root .. "/_answers/777-1-" .. SHA .. ".lock") == nil, "no lock is left behind")

  -- 2. a later job of the same run reads the answer, a new run asks again -------------------------------------------
  codes, _, asked = jobs(1, "777")
  eq({ codes[1], asked }, { 1, 0 }, "a later job of the run reads the kept answer")
  -- a re-run (`gh run rerun --failed`, the advice after a failed query) keeps the run id: a new attempt asks again
  codes, _, asked = jobs(1, "777", "2")
  eq({ codes[1], asked }, { 1, 1 }, "a re-run of the run (attempt 2) asks again")
  codes, _, asked = jobs(2, "778")
  eq({ codes[1], codes[2], asked }, { 1, 1, 1 }, "another run asks once more")

  -- 3. a folder for the answers that cannot be made (here: a file in its place; on macOS mkdir() also raised E739
  -- when another hook made it in the same moment) is no crash of the hook: the job asks for itself
  vim.fn.delete(root .. "/_answers", "rf")
  write(root .. "/_answers", "not a folder")
  local codes3, outs3, asked3 = jobs(1, "779")
  eq({ codes3[1], asked3 }, { 1, 1 }, "no answer folder: the job asks GitHub itself")
  ok(
    outs3[1]:find("none of the last 1 reviewed commits", 1, true) ~= nil,
    "... and gives its verdict: " .. outs3[1]
  )
  os.remove(root .. "/_answers")

  -- 4. without a run id each job asks for itself ------------------------------------------------------------------
  _, _, asked = jobs(2, "-") -- "-": no run id (an empty argument does not reach the process on Windows)
  eq(asked, 2, "no run id: no sharing")

  vim.fn.delete(root, "rf")
end
