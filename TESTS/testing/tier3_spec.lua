-- TESTS/testing/tier3_spec.lua -- testing.tier3: where the tier 2.5/3 tools and the Playwright browsers are
-- found, with the environment and the file system injected.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local tier3 = require("testing.tier3")

  local function row(rows, name)
    for _, r in ipairs(rows) do
      if r.name == name then
        return r
      end
    end
  end

  -- an override that is a file wins over PATH; an override that is not a file falls through to PATH
  local rows = tier3.tools({
    getenv = function(name)
      if name == "TESTING_MSEDGEDRIVER" then
        return "/tools/msedgedriver"
      end
      if name == "TESTING_NODE" then
        return "/nowhere/node"
      end
    end,
    which = function(exe)
      if exe == "node" or exe == "wsl" then
        return "/bin/" .. exe
      end
    end,
    is_file = function(path)
      return path == "/tools/msedgedriver"
    end,
  })
  eq(row(rows, "msedgedriver").via, "$TESTING_MSEDGEDRIVER", "an override file is used")
  eq(row(rows, "msedgedriver").path, "/tools/msedgedriver", "... with its path")
  eq(row(rows, "node").via, "PATH", "an override that is no file falls back to PATH")
  eq(row(rows, "tauri-driver").path, nil, "a missing tool has no path")
  eq(row(rows, "wsl").tier, "2.5", "wsl belongs to tier 2.5")

  -- the browser cache: the variable, then LOCALAPPDATA, then HOME; 0 means "bundled", not a folder
  local function env(map)
    return function(name)
      return map[name]
    end
  end
  eq(
    tier3.browsers_dir({ getenv = env({ PLAYWRIGHT_BROWSERS_PATH = "/pw" }) }),
    "/pw",
    "the variable decides"
  )
  eq(
    tier3.browsers_dir({ getenv = env({ PLAYWRIGHT_BROWSERS_PATH = "0", LOCALAPPDATA = "C:/L" }) }),
    "C:/L/ms-playwright",
    "0 is ignored"
  )
  eq(tier3.browsers_dir({ getenv = env({ HOME = "/h" }) }), "/h/.cache/ms-playwright", "HOME cache")
  eq(tier3.browsers_dir({ getenv = env({}) }), nil, "nothing known, no folder")

  local browsers = tier3.browsers({
    getenv = env({ PLAYWRIGHT_BROWSERS_PATH = "/pw" }),
    list_dir = function()
      return {
        "chromium-1200",
        "chromium_headless_shell-1248",
        "chromium-1100",
        "firefox-1543",
        "ffmpeg-1011",
        ".links",
        "webkit-x",
      }
    end,
  })
  eq(
    browsers,
    { chromium = { "1100", "1200", "1248" }, firefox = { "1543" } },
    "engines with sorted revisions, the rest ignored"
  )
end
