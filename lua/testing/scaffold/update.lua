---@module 'testing.scaffold.update'
---@brief `testing init --update`: bring `scripts/test.sh` and `TESTS/minimal_init.lua` of a repository to the current
---templates, keeping what is the repository's own.
---@description
--- `testing init` never overwrites, and `--force` replaces all eight files (`.testing.lua` and the CI job included).
--- A fix in the templates (an exit code, the throwaway state directory, the `ci` verb) therefore never reached the
--- repositories set up before it. `M.plan(root)` renders the two bootstrap files again and compares them with what
--- is there; `M.apply(plan)` writes the ones that changed. Nothing else is touched (`.testing.lua` and the CI job are
--- the repository's to edit).
---
--- Kept from the existing files, so a re-render does not undo a deliberate choice:
---   * the dependencies: the `DEPS=(...)` line of `scripts/test.sh` (runner first; the list `.testing.lua` gave when
---     the file was generated), else `deps = { ... }` read from the text of `.testing.lua`; the plugin name from
---     `plugin = "..."` of `.testing.lua`, else detected (`testing.scaffold.detect_plugin`). `.testing.lua` is READ AS
---     TEXT, never executed: running it is what the workspace trust gate decides, not a file generator;
---   * the `--sentinel '<NAME>'` argument of the run line (`testing migrate` sets it for a project whose old runner
---     printed its own sentinel);
---   * a `scripts/test.sh` that does not export `NVIM_APPNAME` on purpose (docmap.nvim): the template's export goes,
---     the file's own comment that says why stays;
---   * what a gate `TESTS/minimal_init.lua` sets up after the runtimepath (the "Carried over" section of a migration,
---     swap and shada settings, ...): everything between the template's runtimepath loop and its last line;
---   * a `TESTS/minimal_init.lua` that is not the gate yet (no four-place lookup) is replaced by it, and what it set up
---     besides the runtimepath is carried over like `testing migrate` does (`testing.migrate.legacy_init.carry`).
--- The new minimal_init is formatted with the repository's `stylua.toml` (as `testing migrate` does), so a file that
--- differs from the template only in formatting is not reported as changed.
---
--- Whatever else is the repository's own (an `OPTIONAL_DEPS` list, a helper of its own) is NOT kept: every code line
--- of the old file that is not in the new one is listed in `dropped` (except the exact lines of an older template,
--- `M.SUPERSEDED_SH`, which are counted), every such comment line in `dropped_comments`, and the diff shows both. Read
--- the plan before `apply`; the CLI shows it and writes only with `--write`. `apply` holds back a file with a risk or
--- with uncommitted changes unless forced.
---
--- Never raises: problems end in `errors` (whole plan) or `risks` (one file).

local scaffold = require("testing.scaffold")
local legacy_init = require("testing.migrate.legacy_init")
local text = require("testing.migrate.text")

local M = {}

---@class Testing.Scaffold.UpdateFile
---@field rel string Path below the root.
---@field before string|nil The file as it is (line ends as LF), nil when it does not exist.
---@field after string The file as the templates render it today, with the kept parts.
---@field changed boolean `after` differs from `before`.
---@field code_changed boolean Differs in more than comments, blank lines and indentation (what `--check` reports).
---@field dropped_comments string[] Comment lines of the old file that the new one does not have.
---@field lost_comments string[] Comment runs of the repository's own that found no place in the new render: `apply` holds the file back.
---@field diff string|nil Unified diff `before` -> `after` (nil when unchanged).
---@field kept string[] What was kept from the old file, one line each.
---@field dropped string[] Code lines of the old file (no comments, no blank lines) that the new one does not have.
---@field risks string[] Problems of this file (a carried block that could not be kept, ...): `apply` holds it back.
---@field notes? string[] Hints that hold nothing back (no stylua to format with).
---@field exec boolean The file is a script (mode 0755).

---@class Testing.Scaffold.UpdatePlan
---@field root string Absolute, forward slashes.
---@field plugin string|nil
---@field deps string[]
---@field files Testing.Scaffold.UpdateFile[]
---@field errors string[]

---@param path string
---@return string|nil
local function read(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("a")
  fh:close()
  return s and (s:gsub("\r\n", "\n")) or nil
end

---Dependencies besides the runner: the `DEPS=(...)` line of `scripts/test.sh`, else `deps = { ... }` in the text of
---`.testing.lua`, else the default. A word that is not a valid name is a risk, and a source that gives a word it
---cannot read is not used (the next one is): a dependency must never vanish from the new files without a word.
---@param test_sh string|nil
---@param dot string|nil
---@return string[] deps
---@return string|nil from Where they came from.
---@return string[] risks
local function deps_of(test_sh, dot)
  local valid = require("testing.deps").is_valid_name
  local risks = {}
  ---Names of a list's words (quoted with ' or ", or bare); nil when one of them is not a valid name.
  ---@param list string
  ---@param from string
  ---@return string[]|nil
  local function names(list, from)
    local out = {}
    for word in list:gmatch("[^%s,{}]+") do
      local name = word:match("^'(.*)'$") or word:match('^"(.*)"$') or word
      if not valid(name) then
        risks[#risks + 1] = ("%s names a dependency this cannot read: %s"):format(
          from,
          text.show(word, 80)
        )
        return nil
      end
      if name ~= "testing.nvim" and not vim.tbl_contains(out, name) then
        out[#out + 1] = name
      end
    end
    return out
  end
  local line = test_sh and test_sh:match("\nDEPS=%(([^)\n]*)%)")
  local got = line and names(line, "the DEPS line of scripts/test.sh")
  if got then
    return got, "scripts/test.sh", risks
  end
  local list = dot and dot:match("\n%s*deps%s*=%s*(%b{})")
  got = list and names(list, "`deps` of .testing.lua")
  if got then
    return got, ".testing.lua", risks
  end
  return vim.deepcopy(scaffold.DEFAULT_DEPS), nil, risks
end

---Lines of `s` that are code: trimmed, no blank lines, no comment lines (`#` for shell, `--` for Lua).
---@param s string
---@param comment string Lua pattern of a comment start.
---@return string[]
local function code_lines(s, comment)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    local t = vim.trim(line)
    if t ~= "" and not t:match("^" .. comment) then
      out[#out + 1] = t
    end
  end
  return out
end

---Lines of `s` that are comments (trimmed).
---@param s string
---@param comment string Lua pattern of a comment start.
---@return string[]
local function comment_lines(s, comment)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    local t = vim.trim(line)
    if t:match("^" .. comment) and not t:match("^#!") then
      out[#out + 1] = t
    end
  end
  return out
end

---Lines of `pick(before)` that `pick(after)` does not have (in the order of `before`, once each).
---@param before string|nil
---@param after string
---@param comment string
---@param pick? fun(s: string, comment: string): string[] Default: the code lines.
---@return string[]
local function dropped_lines(before, after, comment, pick)
  pick = pick or code_lines
  if not before then
    return {}
  end
  local have = {}
  for _, l in ipairs(pick(after, comment)) do
    have[l] = true
  end
  local out, seen = {}, {}
  for _, l in ipairs(pick(before, comment)) do
    if not have[l] and not seen[l] then
      seen[l] = true
      out[#out + 1] = l
    end
  end
  return out
end

---Does `before` set NVIM_APPNAME in a line of code (an export or an assignment, also indented or inside an `if`)?
---@param before string
---@return boolean
local function sets_appname(before)
  for _, l in ipairs(code_lines(before, "#")) do
    if l:find("NVIM_APPNAME=", 1, true) then
      return true
    end
  end
  return false
end

---Lines that earlier versions of `test.sh.tpl` (and the fleet patches that added `conformance` and `surface`) wrote
---and the current one replaces: not the repository's own, so they are counted, not listed as lost. Exactly the forms
---that were written (the verbs `conformance`, `surface`, `ci`, the run line with at most the `--sentinel`), so a block
---or a run argument of the repository's own is never hidden here. `<v>` stands for one of the verbs.
---@type string[]
M.SUPERSEDED_SH = {}
do
  local nvim = 'nvim %-n %-i NONE %-%-headless %-u NONE %-l "%$DRIVER" '
  for _, prefix in ipairs({ "^exec ", "^" }) do
    for _, verb in ipairs({ "conformance", "surface" }) do
      M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix .. nvim .. verb .. ' %. "%$@"$'
    end
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix .. nvim .. 'run %. "%$@"$'
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix
      .. nvim
      .. "run %. %-%-sentinel '[%u%d_]+' \"%$@\"$"
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = prefix
      .. nvim
      .. 'ci %${ci_args%[@%]%+"%${ci_args%[@%]}"} "%$@"$'
  end
  for _, verb in ipairs({ "conformance", "surface", "ci" }) do
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = '^if %[%[ "%${1:%-}" == "' .. verb .. '" %]%]; then$'
    M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = '^if %[ "%${1:%-}" = "' .. verb .. '" %]; then$'
  end
  M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] =
    '^export NVIM_APPNAME="%${NVIM_APPNAME:%-[%w_%-]+%-tests}"$'
  -- the old `fail()` ended with a fixed code; the new one exits with $FAIL_CODE (3 under `ci`)
  M.SUPERSEDED_SH[#M.SUPERSEDED_SH + 1] = "^exit 1$"
end

---@param line string Trimmed.
---@return boolean
local function superseded(line)
  for _, pat in ipairs(M.SUPERSEDED_SH) do
    if line:match(pat) then
      return true
    end
  end
  return false
end

---Replace the template's `export NVIM_APPNAME=` (and the comment right above it) by the old file's own comment about
---not setting it, when the old file has no such export.
---@param after string
---@param before string
---@return string after
---@return boolean done
local function keep_no_appname(after, before)
  if sets_appname(before) then
    return after, false
  end
  local lines = vim.split(after, "\n", { plain = true })
  local at
  for i, l in ipairs(lines) do
    if l:match("^export NVIM_APPNAME=") then
      at = i
    end
  end
  if not at then
    return after, false
  end
  local first = at
  while first > 1 and lines[first - 1]:match("^#") do
    first = first - 1
  end
  -- the old file's comment block that names NVIM_APPNAME, without the template's own comment lines (a block can run
  -- into the template's next comment)
  local own = {}
  local template_line = {}
  for _, l in ipairs(lines) do
    template_line[l] = true
  end
  local old = vim.split(before, "\n", { plain = true })
  local i = 1
  while i <= #old do
    if old[i]:match("^#") then
      local j = i
      while j + 1 <= #old and old[j + 1]:match("^#") do
        j = j + 1
      end
      local mine = vim.tbl_filter(function(l)
        return not template_line[l]
      end, vim.list_slice(old, i, j))
      if table.concat(mine, "\n"):find("NVIM_APPNAME", 1, true) then
        own = mine
        break
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  if #own == 0 then
    own = { "# NVIM_APPNAME is not set here (the previous scripts/test.sh did not set it either)." }
  end
  local out = vim.list_slice(lines, 1, first - 1)
  vim.list_extend(out, own)
  vim.list_extend(out, vim.list_slice(lines, at + 1))
  return table.concat(out, "\n"), true
end

---The loop that puts the dependencies on the runtimepath: the end of the template's own body (also collapsed onto one
---line by a formatter).
local RTP_LOOP = "vim%.opt%.rtp:append%(found%[name%]%)%s*end[ \t]*\n"

---What a gate minimal_init sets up after the template's body: the text between the runtimepath loop and the last
---line (`legacy_init.GATE_TAIL`), or to the end when the file has no such line. Nil when there is nothing.
---@param before string
---@return string|nil extra
local function gate_extra(before)
  local _, loop_end = before:find(RTP_LOOP)
  if not loop_end then
    return nil
  end
  local rest = before:sub(loop_end + 1)
  local tail = rest:find(legacy_init.GATE_TAIL, 1, true)
  local extra = tail and rest:sub(1, tail - 1) or rest
  extra = extra:gsub("^%s+", ""):gsub("%s+$", "")
  return extra ~= "" and extra or nil
end

---A repository's own lines that `--update` keeps: everything from a `<comment> testing:keep begin` line to the
---matching `<comment> testing:keep end` line (markers included). The block is put back after the nearest line above
---it that the new render has exactly once (`fi`, `end` and blank lines say nothing about where a block stood), behind
---the lines that stood between that line and the block, which must be the same in the new render. If no such line
---exists or the lines in between differ, the block cannot be placed: the file is held back (a risk) instead of
---losing it or moving it into another branch of the script.
---@param before string|nil The old file.
---@param after string The new render.
---@param prefix string Comment start as written in the file (`#` or `--`).
---@return string after
---@return string[] kept
---@return string[] risks
local function keep_blocks(before, after, prefix)
  if not before then
    return after, {}, {}
  end
  local begin_tag, end_tag = prefix .. " testing:keep begin", prefix .. " testing:keep end"
  local old = vim.split(before, "\n", { plain = true })
  local out = vim.split(after, "\n", { plain = true })
  local counts, where = {}, {}
  for k, l in ipairs(out) do
    counts[l] = (counts[l] or 0) + 1
    where[l] = k
  end
  local placements, kept, risks = {}, {}, {}
  local i = 1
  while i <= #old do
    local line = vim.trim(old[i])
    if line == begin_tag or line:sub(1, #begin_tag + 1) == begin_tag .. " " then
      local last
      for j = i + 1, #old do
        if vim.trim(old[j]) == end_tag then
          last = j
          break
        end
      end
      if not last then
        risks[#risks + 1] = ("a '%s' block has no '%s' line: it is not kept, copy it by hand"):format(
          begin_tag,
          end_tag
        )
        break
      end
      local block = vim.list_slice(old, i, last)
      local anchor, gap
      for j = i - 1, 1, -1 do
        if vim.trim(old[j]) ~= "" and counts[old[j]] == 1 then
          anchor, gap = old[j], vim.list_slice(old, j + 1, i - 1)
          break
        end
      end
      local at = anchor and where[anchor]
      local fits = at ~= nil
      for n, g in ipairs(gap or {}) do
        if out[at + n] ~= g then
          fits = false
          break
        end
      end
      if fits then
        placements[#placements + 1] = { pos = at + #gap, lines = block }
        kept[#kept + 1] = ("%d line(s) between the testing:keep markers"):format(#block)
      else
        risks[#risks + 1] = ("the block '%s ...' cannot be placed: the new file has no unique line above its place that is followed by the same lines as before: copy it by hand"):format(
          begin_tag
        )
      end
      i = last
    end
    i = i + 1
  end
  -- from the bottom up: an insertion does not move the places above it
  table.sort(placements, function(a, b)
    return a.pos > b.pos
  end)
  for _, p in ipairs(placements) do
    for n, l in ipairs(p.lines) do
      table.insert(out, p.pos + n, l)
    end
  end
  return table.concat(out, "\n"), kept, risks
end

---The repository's own explanatory comments: a run of comment lines of the old file that the new render has none of
---(not even reworded) and that stands right above a code line the new render has exactly once, with no comment of the
---template above that line. It is put back above that line, so a reason written down for a deliberate choice (why
---`ui.nvim` is no dependency) does not vanish in a re-render. A comment the template has in another wording stays
---the template's: only a place without any comment in the new file takes the old one.
---@param before string|nil The old file.
---@param after string The new render.
---@param prefix string Comment start as written in the file (`#` or `--`).
---@return string after
---@return string[] kept
---@return string[] lost Own comment runs that found no place (the first line of each): `--write` holds the file back.
local function keep_comments(before, after, prefix)
  if not before then
    return after, {}, {}
  end
  local function is_comment(l)
    local t = vim.trim(l)
    return t:sub(1, #prefix) == prefix and t:sub(1, 2) ~= "#!"
  end
  local old = vim.split(before, "\n", { plain = true })
  local out = vim.split(after, "\n", { plain = true })
  local present, counts, where = {}, {}, {}
  for k, l in ipairs(out) do
    present[vim.trim(l)] = true
    counts[l] = (counts[l] or 0) + 1
    where[l] = k
  end
  local placements, kept, lost = {}, {}, {}
  local i = 1
  while i <= #old do
    if is_comment(old[i]) then
      local j = i
      while j < #old and is_comment(old[j + 1]) do
        j = j + 1
      end
      local run = vim.list_slice(old, i, j)
      local own = true
      for _, l in ipairs(run) do
        if present[vim.trim(l)] or vim.trim(l):find("testing:keep", 1, true) then
          own = false
          break
        end
      end
      local anchor = old[j + 1]
      if own and anchor and vim.trim(anchor) ~= "" and counts[anchor] == 1 then
        local at = where[anchor]
        if at == 1 or not is_comment(out[at - 1]) then
          placements[#placements + 1] = { pos = at - 1, lines = run }
          kept[#kept + 1] = ("%d comment line(s) above `%s`"):format(
            #run,
            vim.trim(anchor):sub(1, 40)
          )
        end
        -- else: the template has its own comment there (an older wording), the new one replaces it
      elseif own then
        -- no line of the new render to hang it on (the line below it differs or is gone): the reason would vanish
        lost[#lost + 1] = ("%d comment line(s) starting `%s`"):format(
          #run,
          vim.trim(run[1]):sub(1, 60)
        )
      end
      i = j
    end
    i = i + 1
  end
  -- from the bottom up: an insertion does not move the places above it
  table.sort(placements, function(a, b)
    return a.pos > b.pos
  end)
  for _, pl in ipairs(placements) do
    for n, l in ipairs(pl.lines) do
      table.insert(out, pl.pos + n, l)
    end
  end
  return table.concat(out, "\n"), kept, lost
end

---A file that is the repository's own on purpose: `<comment> testing:keep-file <reason>` in its first lines. The
---update leaves it as it is and says why (a `--check` does not count it).
---@param before string|nil
---@param prefix string
---@return string|nil reason
local function keep_file(before, prefix)
  if not before then
    return nil
  end
  local tag = prefix .. " testing:keep-file"
  for n, line in ipairs(vim.split(before, "\n", { plain = true })) do
    if n > 20 then
      break
    end
    local t = vim.trim(line)
    if t == tag or t:sub(1, #tag + 1) == tag .. " " then
      local reason = vim.trim(t:sub(#tag + 1))
      return reason ~= "" and reason or "no reason given"
    end
  end
  return nil
end

---One file of the plan.
---@param rel string
---@param before string|nil
---@param after string
---@param comment string Lua pattern of a comment start.
---@param parts { kept: string[], dropped: string[], risks: string[], lost_comments?: string[], exec: boolean }
---@return Testing.Scaffold.UpdateFile
local function entry(rel, before, after, comment, parts)
  local changed = before ~= after
  return {
    rel = rel,
    before = before,
    after = after,
    changed = changed,
    code_changed = before == nil
      or not vim.deep_equal(code_lines(before, comment), code_lines(after, comment)),
    diff = changed and text.unified(before, after, rel) or nil,
    kept = parts.kept,
    dropped = parts.dropped,
    dropped_comments = dropped_lines(before, after, comment, comment_lines),
    risks = parts.risks,
    lost_comments = parts.lost_comments or {},
    exec = parts.exec,
  }
end

---Plan the update of the two bootstrap files below `root`.
---@param root string
---@param opts? { owner?: string, format?: table } `format`: options of `testing.migrate.format.lua` (specs).
---@return Testing.Scaffold.UpdatePlan
function M.plan(root, opts)
  opts = opts or {}
  ---@type Testing.Scaffold.UpdatePlan
  local plan = { root = "", deps = {}, files = {}, errors = {} }
  local ok, perr = pcall(function()
    if type(root) ~= "string" or root == "" then
      plan.errors[#plan.errors + 1] = "no root given"
      return
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
    plan.root = abs
    if vim.fn.isdirectory(abs) ~= 1 then
      plan.errors[#plan.errors + 1] = abs .. ": not a directory"
      return
    end
    local old_sh = read(abs .. "/scripts/test.sh")
    local old_minit = read(abs .. "/TESTS/minimal_init.lua")
    local dot = read(abs .. "/.testing.lua")
    if not (old_sh or old_minit or dot) then
      plan.errors[#plan.errors + 1] = abs
        .. ": no testing setup to update (no .testing.lua, scripts/test.sh or TESTS/minimal_init.lua); run `testing init`"
      return
    end

    local plugin = dot and scaffold.sanitize_plugin(dot:match('\n%s*plugin%s*=%s*"([^"\n]+)"'))
      or scaffold.detect_plugin(abs)
    if not plugin then
      plan.errors[#plan.errors + 1] = "cannot derive the plugin name; set `plugin` in .testing.lua"
      return
    end
    plan.plugin = plugin
    local deps, deps_from, deps_risks = deps_of(old_sh, dot)
    plan.deps = deps

    -- ------------------------------------------------------------ scripts/test.sh
    do
      local kept, risks, lost_comments = {}, vim.deepcopy(deps_risks), {}
      if deps_from then
        kept[#kept + 1] = ("dependencies from %s: %s"):format(
          deps_from,
          #deps > 0 and table.concat(deps, ", ") or "none"
        )
      end
      local extra = { RUN_ARGS = "" }
      local sentinel = old_sh and old_sh:match("run %.( %-%-sentinel '[%u%d_]+') \"%$@\"")
      if sentinel then
        extra.RUN_ARGS = sentinel
        kept[#kept + 1] = "the run line's" .. sentinel
      end
      local vars, verr =
        scaffold.build_vars(plugin, deps, opts.owner or scaffold.DEFAULT_OWNER, extra)
      local after, rerr
      if vars then
        after, rerr = scaffold.render_template("test.sh.tpl", vars)
      end
      if not after then
        plan.errors[#plan.errors + 1] = "scripts/test.sh: " .. tostring(verr or rerr)
        return
      end
      if old_sh then
        local done
        after, done = keep_no_appname(after, old_sh)
        if done then
          kept[#kept + 1] =
            "no NVIM_APPNAME export (the file did not set one), with its own comment"
        end
      end
      local own = keep_file(old_sh, "#")
      if own then
        -- the repository's own file (the dogfood script of testing.nvim): nothing of the template reaches it
        after = old_sh --[[@as string]]
        kept = { ("the file is the repository's own (testing:keep-file): %s"):format(own) }
        risks = {}
      else
        local blocks, block_risks
        after, blocks, block_risks = keep_blocks(old_sh, after, "#")
        vim.list_extend(kept, blocks)
        vim.list_extend(risks, block_risks)
        local own_comments
        after, own_comments, lost_comments = keep_comments(old_sh, after, "#")
        vim.list_extend(kept, own_comments)
      end
      local dropped, older = {}, 0
      for _, l in ipairs(dropped_lines(old_sh, after, "#")) do
        if superseded(l) then
          older = older + 1
        else
          dropped[#dropped + 1] = l
        end
      end
      if older > 0 then
        kept[#kept + 1] = ("%d line(s) of an older template version replaced"):format(older)
      end
      plan.files[#plan.files + 1] = entry("scripts/test.sh", old_sh, after, "#", {
        kept = kept,
        dropped = dropped,
        risks = risks,
        lost_comments = lost_comments,
        exec = true,
      })
    end

    -- ------------------------------------------------------------ TESTS/minimal_init.lua
    do
      local kept, risks, lost_comments = {}, {}, {}
      local vars, verr = scaffold.build_vars(plugin, deps, opts.owner or scaffold.DEFAULT_OWNER)
      local after, rerr
      if vars then
        after, rerr = scaffold.render_template("minimal_init.lua.tpl", vars)
      end
      if not after then
        plan.errors[#plan.errors + 1] = "TESTS/minimal_init.lua: " .. tostring(verr or rerr)
        return
      end
      if legacy_init.is_gate(old_minit) then
        ---@cast old_minit string
        local extra = gate_extra(old_minit)
        local at = after:find(legacy_init.GATE_TAIL, 1, true)
        if extra and at then
          local candidate = after:sub(1, at - 1) .. extra .. "\n\n" .. after:sub(at)
          if loadstring(candidate) then
            after = candidate
            kept[#kept + 1] = ("what the file sets up after the runtimepath (%d line(s))"):format(
              #vim.split(extra, "\n", { plain = true })
            )
          else
            risks[#risks + 1] =
              "what the file sets up after the runtimepath would not compile in the new file: copy it by hand (the diff shows it)"
          end
        end
      elseif old_minit then
        local carried, carry_risks
        after, carried, carry_risks = legacy_init.carry(
          after,
          legacy_init.split(old_minit),
          "TESTS/minimal_init.lua",
          "replaced by testing init --update"
        )
        vim.list_extend(risks, carry_risks)
        kept[#kept + 1] = ("the file was not the gate yet (no four-place lookup): replaced, %d block(s) carried over"):format(
          carried
        )
      end
      local own = keep_file(old_minit, "--")
      local hint
      if own then
        after = old_minit --[[@as string]]
        kept = { ("the file is the repository's own (testing:keep-file): %s"):format(own) }
        risks = {}
      else
        local blocks, block_risks
        after, blocks, block_risks = keep_blocks(old_minit, after, "--")
        vim.list_extend(kept, blocks)
        vim.list_extend(risks, block_risks)
        local own_comments
        after, own_comments, lost_comments = keep_comments(old_minit, after, "--")
        vim.list_extend(kept, own_comments)
        if #blocks > 0 and #block_risks == 0 and not loadstring(after) then
          risks[#risks + 1] =
            "the testing:keep block would not compile in the new file: copy it by hand (the diff shows it)"
        end
        after, hint =
          require("testing.migrate.format").lua(after, "TESTS/minimal_init.lua", abs, opts.format)
      end
      local f = entry("TESTS/minimal_init.lua", old_minit, after, "%-%-", {
        kept = kept,
        dropped = dropped_lines(old_minit, after, "%-%-"),
        risks = risks,
        lost_comments = lost_comments,
        exec = false,
      })
      -- no stylua: the file is written as the template has it (not a reason to hold it back)
      f.notes = hint and { hint } or {}
      plan.files[#plan.files + 1] = f
    end
  end)
  if not ok then
    plan.errors[#plan.errors + 1] = "internal error: " .. tostring(perr)
  end
  return plan
end

---Uncommitted changes of `rel` (modified, staged or untracked): what `apply` would destroy for good. Nil outside a
---git work tree, or when git cannot answer (then nothing can be told, and nothing is held for it).
---@param root string
---@param rel string
---@return string|nil status The porcelain line.
local function uncommitted(root, rel)
  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", root, "status", "--porcelain", "--", rel }, { text = true })
      :wait()
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local line = vim.trim(res.stdout or "")
  return line ~= "" and line or nil
end

---@class Testing.Scaffold.UpdateHeld
---@field rel string
---@field why string

---Write the files of the plan that changed. Nothing is written when the plan has errors. A file whose plan has a risk,
---or that has uncommitted changes (they would be gone for good), is held back unless `opts.force`; a file that would
---lose comments of the repository's own (`lost_comments`) also unless `opts.force_comments`.
---@param plan Testing.Scaffold.UpdatePlan
---@param opts? { force?: boolean, force_comments?: boolean, git?: fun(root: string, rel: string): string|nil } `git`: the uncommitted-check (specs).
---@return string[] written Paths below the root.
---@return string[] errors
---@return Testing.Scaffold.UpdateHeld[] held
function M.apply(plan, opts)
  opts = opts or {}
  local written, errors, held = {}, {}, {}
  if #plan.errors > 0 then
    return written, vim.deepcopy(plan.errors), held
  end
  local check = opts.git or uncommitted
  for _, f in ipairs(plan.files) do
    local dirty = f.changed and f.before ~= nil and not opts.force and check(plan.root, f.rel)
    if f.changed and not opts.force and #f.risks > 0 then
      held[#held + 1] = { rel = f.rel, why = "it has a risk (see above); --force writes it anyway" }
    elseif f.changed and not opts.force and not opts.force_comments and #f.lost_comments > 0 then
      held[#held + 1] = {
        rel = f.rel,
        why = "comments of your own would be lost (see above); put them back by hand, or --force-comments",
      }
    elseif dirty then
      held[#held + 1] = {
        rel = f.rel,
        why = ("it has uncommitted changes (%s); commit them first, or --force"):format(dirty),
      }
    elseif f.changed then
      local path = plan.root .. "/" .. f.rel
      local made, merr = require("lib.nvim.fs.mkdirp")(vim.fs.dirname(path))
      local ok, err
      if made then
        ok, err = require("lib.nvim.fs.write.atomic")(path, f.after)
      end
      if made and ok then
        if f.exec then
          -- best effort: a file system without modes keeps what it has (git's index mode is yours to set)
          pcall(vim.uv.fs_chmod, path, tonumber("755", 8))
        end
        written[#written + 1] = f.rel
      else
        errors[#errors + 1] = ("%s: %s"):format(f.rel, tostring(merr or err))
      end
    end
  end
  return written, errors, held
end

---The plan as text lines: per file whether it changes, what was kept, what would be lost, its risks, and (with
---`diff`) the diff. Every value from the repository is shown through `testing.migrate.text.show`.
---@param plan Testing.Scaffold.UpdatePlan
---@param o? { diff?: boolean, written?: string[], held?: Testing.Scaffold.UpdateHeld[] } A held file shows its diff always.
---@return string[] lines
function M.lines(plan, o)
  o = o or {}
  local out = { ("testing init --update %s"):format(text.show(plan.root, 200)) }
  for _, e in ipairs(plan.errors) do
    out[#out + 1] = "error: " .. text.show(e, 300)
  end
  local written, held = {}, {}
  for _, w in ipairs(o.written or {}) do
    written[w] = true
  end
  for _, h in ipairs(o.held or {}) do
    held[h.rel] = h.why
  end
  for _, f in ipairs(plan.files) do
    local state = not f.changed and "up to date"
      or (written[f.rel] and "updated")
      or (held[f.rel] and ("not written: " .. held[f.rel]))
      or (f.before and "out of date" or "missing")
    if f.changed and not f.code_changed then
      state = state .. " (comments only)"
    end
    out[#out + 1] = ("%-24s %s"):format(f.rel, state)
    if f.changed then
      for _, k in ipairs(f.kept) do
        out[#out + 1] = "  kept: " .. text.show(k, 200)
      end
      if #f.dropped > 0 then
        out[#out + 1] = ("  only in the old file (%d code line(s); keep them by hand if they are yours):"):format(
          #f.dropped
        )
        for i, l in ipairs(f.dropped) do
          if i > 20 then
            out[#out + 1] = ("    ... %d more"):format(#f.dropped - 20)
            break
          end
          out[#out + 1] = "    " .. text.show(l, 160)
        end
      end
      if #f.dropped_comments > 0 then
        out[#out + 1] = ("  comments only in the old file (%d; a reason you wrote down goes with them):"):format(
          #f.dropped_comments
        )
        for i, l in ipairs(f.dropped_comments) do
          if i > 10 then
            out[#out + 1] = ("    ... %d more"):format(#f.dropped_comments - 10)
            break
          end
          out[#out + 1] = "    " .. text.show(l, 160)
        end
      end
      for _, l in ipairs(f.lost_comments) do
        out[#out + 1] = "  lost comments: " .. text.show(l, 200)
      end
      if f.exec and f.before == nil and written[f.rel] then
        -- NTFS has no mode bits: git records a new file as 100644, and a clone on Linux or macOS cannot run it
        out[#out + 1] = "  next: git add " .. f.rel .. " && git update-index --chmod=+x " .. f.rel
      end
    end
    for _, r in ipairs(f.risks) do
      out[#out + 1] = "  risk: " .. text.show(r, 300)
    end
    for _, n in ipairs(f.notes or {}) do
      out[#out + 1] = "  note: " .. text.show(n, 300)
    end
    if (o.diff or held[f.rel]) and f.diff then
      for line in (f.diff .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = "  " .. text.show(line, 400)
      end
    end
  end
  return out
end

return M
