-- @cache-env TESTING_DESKTOP_DRIVER
---@module 'testing.sheet.desktop'
---@brief Engine "desktop" of a test sheet: the real window of a program, the way a screen reader goes.
---@description
--- The steps go by accessible name to `sheet-driver` (appkit), a process that speaks `testing-sheet-driver/1`; on
--- Windows it uses UI Automation. The driver is `$TESTING_DESKTOP_DRIVER`, else `sheet-driver` on the PATH; without one
--- the sheet is a reported skip, never green. The program comes from `sheets.apps` of `.testing.lua`, the driver gets
--- its process and `window` (a part of the title).

local M = {}

---@param s Testing.Sheet
---@param opts table As `testing.sheet.driver_proc`, and `desktop_driver` (a path, for specs).
---@param ctx Testing.Sheet.DriverContext
---@return table driver See `testing.sheet.driver_rpc`.
function M.driver(s, opts, ctx)
  return require("testing.sheet.driver_proc").new(s, opts, ctx, {
    label = "desktop driver",
    prepare = function()
      local exe = opts.desktop_driver or vim.uv.os_getenv("TESTING_DESKTOP_DRIVER")
      if not exe or exe == "" then
        exe = vim.fn.exepath("sheet-driver")
      end
      if not exe or exe == "" then
        return nil,
          "sheet-driver is not installed (cargo build -p sheet-driver in appkit, $TESTING_DESKTOP_DRIVER)"
      end
      if vim.fn.executable(exe) ~= 1 then
        return nil, ("$TESTING_DESKTOP_DRIVER %s cannot be run"):format(exe)
      end
      return { exe }, nil
    end,
    options = function(app)
      return { pid = app and app.pid, window = app and app.window }
    end,
  })
end

return M
