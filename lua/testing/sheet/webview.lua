-- @cache-env TESTING_NODE TESTING_TAURI_DRIVER TESTING_MSEDGEDRIVER
---@module 'testing.sheet.webview'
---@brief Engine "webview" of a test sheet: the page inside the WebView2 of an app (Tauri), through WebDriver.
---@description
--- `webview_runner.mjs` (node, no client library) speaks `testing-sheet-driver/1` on its stdin and plain W3C WebDriver
--- to `tauri-driver`, which starts the app with `msedgedriver` and drives its page. The app comes from `sheets.apps` of
--- `.testing.lua` (built here, started by the driver, with its `env` and `${temp}`). `wait` and `expect` are JavaScript
--- in the page as in the browser engine; `open`, `scheme` and `drag` do not exist here. Without node, tauri-driver or
--- msedgedriver ($TESTING_NODE, $TESTING_TAURI_DRIVER, $TESTING_MSEDGEDRIVER, else the PATH) the sheet is a reported skip.

local M = {}

---@return string
local function runner_path()
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.normalize(here)) .. "/webview_runner.mjs"
end

---The three programs, or nil and the reason of the skip.
---@param tools? Testing.Tier3.Row[] For specs.
---@return { node: string, tauri_driver: string, msedgedriver: string }|nil found, string|nil why
function M.prerequisites(tools)
  local found = {}
  for _, row in ipairs(tools or require("testing.tier3").tools()) do
    found[row.name] = row.path
  end
  if require("testing.platform").is_macos() then
    return nil, "Tauri has no WebDriver on macOS"
  end
  for _, name in ipairs({ "node", "tauri-driver", "msedgedriver" }) do
    if not found[name] then
      return nil,
        ("%s is not installed (a webview sheet runs node, tauri-driver and msedgedriver)"):format(
          name
        )
    end
  end
  return {
    node = found.node,
    tauri_driver = found["tauri-driver"],
    msedgedriver = found.msedgedriver,
  },
    nil
end

---@param s Testing.Sheet
---@param opts table As `testing.sheet.driver_proc`, and for specs `tools` (rows of `testing.tier3`) and
---`tauri_driver_argv` (a stand-in for tauri-driver: a program and its first arguments).
---@param ctx Testing.Sheet.DriverContext
---@return table driver See `testing.sheet.driver_rpc`.
function M.driver(s, opts, ctx)
  local found
  return require("testing.sheet.driver_proc").new(s, opts, ctx, {
    label = "webview driver",
    driver_starts_app = true,
    prepare = function()
      local why
      found, why = M.prerequisites(opts.tools)
      if not found then
        return nil, why
      end
      return { found.node, runner_path() }, nil
    end,
    options = function(app)
      found = found or M.prerequisites(opts.tools) or {}
      return {
        headed = opts.headed == true,
        tauri_driver = opts.tauri_driver_argv or found.tauri_driver,
        msedgedriver = found.msedgedriver,
        cwd = ctx.root,
        application = app and app.argv and app.argv[1],
        args = app and app.argv and vim.list_slice(app.argv, 2) or {},
        env = app and app.env or vim.empty_dict(),
      }
    end,
  })
end

return M
