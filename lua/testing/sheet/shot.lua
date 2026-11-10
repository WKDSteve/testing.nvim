---@module 'testing.sheet.shot'
---@brief The picture of an rpc sheet's screen (`shot = name`): the screen drawn as a page and photographed by a browser.
---@description
--- An rpc sheet runs its editor embedded and headless (`testing.rpc`): there is no window to photograph. The screen of
--- `child.screen()` carries every cell with its character, colours and styles, so `testing.screen.html` draws it as an
--- HTML page and the browser engine (`testing.sheet.browser`: node and playwright-core) photographs the grid:
---
---   take(screen, { sheet, size, root, name, out_dir?, browser? })
---     -> path                     TESTS/sheets/out/<id>.<name>.<cols>x<rows>.png
---     -> nil, nil, skip_reason    node or playwright-core or a browser is missing: a reported skip, never a picture
---                                 that is not there and never a green run that pretends there is one
---     -> nil, failure             the browser failed
---
--- The picture is the input of the AI judge and of README images. The font is the browser's (`testing.screen.HTML_FONT`),
--- not a terminal's: what the picture proves is the screen's text and colours, not a terminal's rendering. The page and
--- the browser's folder are temporary and gone again on every way out (a raise included).

local M = {}

-- The window of the browser: the grid is photographed as an element, also where it is larger than the window.
M.VIEWPORT_MAX = { cols = 1600, rows = 1200 }

---@class Testing.Sheet.ShotOpts
---@field sheet Testing.Sheet
---@field size { rows: integer, cols: integer }
---@field root string
---@field name string The `shot` name (letters, digits, `_`, `-`: `testing.sheet` checked it).
---@field out_dir? string Default `<root>/TESTS/sheets/out`.
---@field browser? table Options of `testing.sheet.browser.run` (`run`, `node`, `playwright_dir` for specs).

---How long the browser may take for a screen of `cells` cells: loading the page and photographing it.
---@param cells integer
---@return integer ms
function M.timeout_ms(cells)
  return 10000 + math.floor(cells / 20)
end

---@param screen table A screen of `child.screen()`.
---@param o Testing.Sheet.ShotOpts
---@return string|nil path
---@return string|nil failure
---@return string|nil skip
function M.take(screen, o)
  local page = vim.fn.tempname() .. ".screen.html"
  local work = vim.fn.tempname() .. "-shot"
  local function cleanup()
    os.remove(page)
    vim.fn.delete(work, "rf")
  end
  local ok, path, failure, skip = pcall(function()
    local f = io.open(page, "wb")
    if not f then
      return nil, "the page of the screen cannot be written"
    end
    f:write((require("testing.screen").html(screen)))
    f:close()
    local px = require("testing.screen").HTML_CELL_PX
    local viewport = {
      cols = math.min(o.size.cols * px.line + 32, M.VIEWPORT_MAX.cols),
      rows = math.min(o.size.rows * px.line + 32, M.VIEWPORT_MAX.rows),
    }
    local timeout = M.timeout_ms(o.size.cols * o.size.rows)
    ---@diagnostic disable-next-line: missing-fields
    local res = require("testing.sheet.browser").run({
      id = o.sheet.id,
      sizes = { viewport },
      steps = {
        { open = page, timeout = timeout },
        { shot = o.name, element = "#screen", timeout = timeout },
      },
    }, vim.tbl_extend("force", { root = o.root, out_dir = work }, o.browser or {}))
    if res.status == "skip" then
      return nil, nil, res.skipped or "the browser engine is not available"
    end
    if not res.ok then
      return nil, ("the picture of the screen failed: %s"):format(tostring(res.failures[1]))
    end
    local made = (res.snapshots[1] or ""):match("^screenshot (.+)$")
    if not made or not vim.uv.fs_stat(made) then
      return nil, "the browser made no picture"
    end
    local out_dir = o.out_dir or (o.root .. "/TESTS/sheets/out")
    vim.fn.mkdir(out_dir, "p")
    local target = ("%s/%s.%s.%dx%d.png"):format(
      out_dir,
      o.sheet.id,
      o.name,
      o.size.cols,
      o.size.rows
    )
    os.remove(target)
    if not vim.uv.fs_copyfile(made, target) then
      return nil, ("the picture cannot be written to %s"):format(target)
    end
    return target
  end)
  cleanup()
  if not ok then
    return nil, ("the picture of the screen failed: %s"):format(tostring(path))
  end
  return path, failure, skip
end

return M
