---@module 'testing.sheet.driver_proc'
---@brief An engine of a test sheet as a process of its own: `testing-sheet-driver/1` over stdin and stdout.
---@description
--- One JSON line per command on stdin, one per answer on stdout (schema under `schemas/`), so a driver can be written in
--- any language. `testing.sheet.session` steps through what `new` returns, like `testing.sheet.driver_rpc`. A sheet's app
--- (`testing.sheet.app`) starts here, with the first size, after what a skip depends on, and ends with the driver.

local M = {}

---@class Testing.Sheet.DriverHow
---@field label string What the messages call it: `browser driver`.
---@field prepare fun(): string[]|nil, string|nil The argv of the driver, or nil and the reason of a skip.
---@field options fun(app: Testing.Sheet.App|nil): table The `options` of an `open` command.

---@param s Testing.Sheet
---@param opts table `driver_argv`, `driver_margin_ms`, `driver_stop_ms`, `out_dir`.
---@param ctx Testing.Sheet.DriverContext
---@param how Testing.Sheet.DriverHow
---@return table driver See `testing.sheet.driver_rpc`.
function M.new(s, opts, ctx, how)
  local margin = opts.driver_margin_ms or 60000
  local stop_ms = opts.driver_stop_ms or 6000
  local proc, exit_code, app
  local answers, partial, stderr = {}, "", {}

  ---Fast context: only tables.
  local function on_stdout(_, data)
    if not data then
      return
    end
    partial = partial .. data
    for line in partial:gmatch("([^\n]*)\n") do
      answers[#answers + 1] = line
    end
    partial = partial:match("([^\n]*)$") or ""
  end

  ---Closed stdin first: the driver takes its browser with it, a killed one may leave a window behind. Kill only what
  ---does not listen.
  local function stop()
    if not proc or exit_code ~= nil then
      return
    end
    pcall(proc.write, proc, nil)
    vim.wait(stop_ms, function()
      return exit_code ~= nil
    end, 10)
    if exit_code == nil then
      pcall(proc.kill, proc, 9)
    end
  end

  ---@return string|nil skip_reason, string|nil failure_reason
  local function start()
    local argv = opts.driver_argv
    if not argv then
      local prepared, skip_why = how.prepare()
      if not prepared then
        return skip_why
      end
      argv = prepared
    end
    local ok, obj = pcall(vim.system, argv, {
      stdin = true,
      text = false,
      stdout = on_stdout,
      stderr = function(_, data)
        if data and #stderr < 50 then
          stderr[#stderr + 1] = data
        end
      end,
    }, function(done)
      exit_code = done.code
    end)
    if not ok then
      return nil, ("the %s did not start: %s"):format(how.label, tostring(obj))
    end
    proc = obj
    return nil
  end

  ---One command, one answer. Nil and why when there is no answer: the driver ended, is too slow, or the run was
  ---cancelled. The last two end the driver: it may still be working on the command.
  ---@param msg table
  ---@param ms integer
  ---@return table|nil answer, string|nil why
  local function request(msg, ms)
    if not proc then
      return nil, ("the %s is not running"):format(how.label)
    end
    pcall(proc.write, proc, vim.json.encode(msg) .. "\n")
    vim.wait(ms, function()
      return #answers > 0 or exit_code ~= nil or ctx.cancelled()
    end, 10)
    local line = table.remove(answers, 1)
    if line then
      local decoded, doc = pcall(vim.json.decode, line)
      if not decoded or type(doc) ~= "table" then
        stop()
        return nil, ("the %s answered something else: %s"):format(how.label, line:sub(1, 200))
      end
      return doc
    end
    if exit_code ~= nil then
      local why = vim.trim(table.concat(stderr)):sub(1, 300)
      return nil, ("the %s ended (exit %d): %s"):format(how.label, exit_code, why)
    end
    stop()
    if ctx.cancelled() then
      return nil, "aborted"
    end
    return nil, ("the %s did not answer in %d ms"):format(how.label, ms)
  end

  local D = {}

  ---@param size { rows: integer, cols: integer }
  ---@return { failure?: string, skip?: string }|nil
  function D.open_size(size)
    local tag = ("%dx%d"):format(size.cols, size.rows)
    if not proc then
      local skip_why, fail_why = start()
      if skip_why then
        return { skip = skip_why }
      end
      if fail_why then
        return { failure = ("%s: %s"):format(tag, fail_why) }
      end
    end
    -- one app for all sizes, as one browser
    if s.app and not app then
      local started, aerr, skip =
        require("testing.sheet.app").start(s.app, ctx.root, { cancelled = ctx.cancelled })
      if skip then
        return { skip = skip }
      end
      if not started then
        return { failure = ("%s: the app %s did not start: %s"):format(tag, s.app, tostring(aerr)) }
      end
      app = started
    end
    local answer, why = request({
      cmd = "open",
      sheet = {
        id = s.id,
        root = ctx.root,
        out_dir = opts.out_dir or (ctx.root .. "/TESTS/sheets/out"),
      },
      size = size,
      options = how.options(app),
    }, margin)
    if not answer then
      return { failure = ("%s: %s"):format(tag, why) }
    end
    if answer.skip then
      return { skip = tostring(answer.skip) }
    end
    if not answer.ok then
      return { failure = ("%s: %s"):format(tag, tostring(answer.error or answer.reason)) }
    end
    return nil
  end

  ---@param step Testing.Sheet.Step
  ---@param n integer
  ---@return { reason?: string, shot?: string }
  function D.run(step, n)
    if app then
      local expanded, eerr = require("testing.sheet.app").expand_step(step, app.vars)
      if not expanded then
        return { reason = eerr }
      end
      step = expanded
    end
    local answer, why = request({ cmd = "step", n = n, step = step }, (step.timeout or 0) + margin)
    if not answer then
      return { reason = why }
    end
    if not answer.ok then
      return { reason = tostring(answer.reason or answer.error) }
    end
    return { shot = answer.shot }
  end

  ---The target stays until the next size opens: a window still shows the last step.
  function D.close_size() end

  function D.close()
    if proc then
      if exit_code == nil and not ctx.cancelled() then
        request({ cmd = "close" }, 10000)
      end
      stop()
      proc = nil
    end
    if app then
      app.stop()
      app = nil
    end
  end

  return D
end

return M
