-- claude-quota.wezterm
-- Claude Code usage quota in the WezTerm status bar.
--
-- Works on macOS, Linux, native Windows, and Windows-hosting-WSL, which is the
-- case other plugins get wrong: WezTerm is a Windows process even when your
-- shell is WSL, so $USERPROFILE/.claude/ is empty and the credentials actually
-- live inside the distro. See resolve_credentials() below.

local wezterm = require("wezterm")

local M = {}

-- ---------------------------------------------------------------- config --

local config = {
  poll_interval_secs = 60,
  position = "right",             -- "left" or "right"
  dashboard_key = { key = "u", mods = "CTRL|SHIFT" },
  compact = false,                -- hide the reset countdowns
  show_burn_rate = true,          -- project when the 5h window hits 100%
  credentials_path = nil,         -- explicit override; skips all detection
  wsl_distro = nil,               -- nil = default distro
  bars = { enabled = true, width = 8, full = "█", empty = "░" },
  icons = { claude = "⚡", week = "▪", burn = "↑" },
  colors = {                      -- cyberdream
    ok    = "#5eff6c",
    warn  = "#f1ff5e",
    high  = "#ffbd5e",
    crit  = "#ff6e5e",
    dim   = "#7b8496",
    text  = "#ffffff",
  },
  thresholds = { warn = 50, high = 75, crit = 90 },
}

-- ------------------------------------------------------------- platform --

local TRIPLE = tostring(wezterm.target_triple or "")
local IS_WINDOWS = TRIPLE:find("windows", 1, true) ~= nil
local IS_MACOS = TRIPLE:find("darwin", 1, true) ~= nil

-- ----------------------------------------------------------------- state --

local cached = nil
local last_fetch = 0
local last_error = nil
local handler_registered = false
local cred_path_cache = nil
local wsl_home_cache = nil
local history = {}   -- { {t = epoch, pct = number}, ... } for the 5h window

-- ------------------------------------------------------------- utilities --

local function run(argv)
  local ok, stdout, stderr = wezterm.run_child_process(argv)
  return ok, stdout, stderr
end

local function file_readable(path)
  if not path then return false end
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- ----------------------------------------------------------- credentials --

-- The WSL home directory, as seen from the Windows side. Cached: spawning
-- wsl.exe is comparatively slow and $HOME never changes mid-session.
local function wsl_home()
  if wsl_home_cache ~= nil then return wsl_home_cache end
  local argv = { "wsl.exe" }
  if config.wsl_distro then
    table.insert(argv, "-d")
    table.insert(argv, config.wsl_distro)
  end
  table.insert(argv, "-e")
  table.insert(argv, "printenv")
  table.insert(argv, "HOME")
  local ok, stdout = run(argv)
  if ok and stdout then
    wsl_home_cache = stdout:gsub("%s+$", "")
  else
    wsl_home_cache = false
  end
  return wsl_home_cache
end

-- Read the credentials blob, trying each location this platform might use.
-- Returns content, source-label, error.
local function resolve_credentials()
  -- 1. explicit override always wins
  if config.credentials_path then
    local c = read_file(config.credentials_path)
    if c then return c, "configured", nil end
    return nil, nil, "credentials_path set but unreadable"
  end

  -- 2. macOS keeps them in the Keychain
  if IS_MACOS then
    local ok, stdout = run({
      "security", "find-generic-password",
      "-s", "Claude Code-credentials", "-w",
    })
    if ok and stdout and stdout ~= "" then
      return stdout:gsub("%s+$", ""), "keychain", nil
    end
  end

  -- 3. the ordinary home-directory location (correct on macOS and Linux)
  local home = os.getenv("HOME")
  if not IS_WINDOWS and home then
    local p = home .. "/.claude/.credentials.json"
    local c = read_file(p)
    if c then return c, "home", nil end
  end

  if IS_WINDOWS then
    -- 4. native Windows install
    local profile = os.getenv("USERPROFILE")
    if profile then
      local p = profile .. "\\.claude\\.credentials.json"
      local c = read_file(p)
      if c then return c, "userprofile", nil end
    end

    -- 5. WezTerm is on Windows but Claude Code runs inside WSL. Read it out of
    --    the distro directly - no symlink, no copied secret.
    local wh = wsl_home()
    if wh then
      local argv = { "wsl.exe" }
      if config.wsl_distro then
        table.insert(argv, "-d")
        table.insert(argv, config.wsl_distro)
      end
      table.insert(argv, "-e")
      table.insert(argv, "cat")
      table.insert(argv, wh .. "/.claude/.credentials.json")
      local ok, stdout = run(argv)
      if ok and stdout and stdout ~= "" then
        return stdout, "wsl", nil
      end
    end
  end

  return nil, nil, "no credentials found"
end

local function get_token()
  local content, source, err = resolve_credentials()
  if not content then return nil, nil, err end
  local token = content:match('"claudeAiOauth"%s*:%s*{[^}]*"accessToken"%s*:%s*"([^"]+)"')
  if not token then
    token = content:match('"accessToken"%s*:%s*"([^"]+)"')
  end
  if not token then return nil, nil, "no accessToken in credentials" end
  return token, source, nil
end

-- ------------------------------------------------------------------- api --

local function call_api(token)
  local ok, stdout = run({
    "curl", "-s", "-m", "5", "-w", "\n%{http_code}",
    "https://api.anthropic.com/api/oauth/usage",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "Content-Type: application/json",
    "-H", "User-Agent: claude-quota.wezterm",
  })
  if not ok or not stdout or stdout == "" then
    return nil, nil, "curl failed"
  end
  local body, code = stdout:match("^(.*)\n(%d+)$")
  if not body then return stdout, nil, nil end
  return body, tonumber(code), nil
end

-- --------------------------------------------------------------- parsing --

-- resets_at is ISO 8601 in UTC, e.g. 2026-03-08T04:59:59.000000+00:00
local function seconds_until(iso)
  if not iso then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local target = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    isdst = false,
  })
  -- os.time() interprets the table as local time; correct back to UTC
  local utc_offset = os.difftime(os.time(), os.time(os.date("!*t")))
  return target + utc_offset - os.time()
end

local function fmt_duration(secs)
  if not secs or secs < 0 then return "?" end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  if d > 0 then return string.format("%dd%dh", d, h) end
  if h > 0 then return string.format("%dh%dm", h, m) end
  return string.format("%dm", m)
end

-- ------------------------------------------------------------- burn rate --

-- Record one sample. Called only from fetch(), never from the renderer:
-- update-status fires on every prompt redraw, which would otherwise pack the
-- history with dozens of identical samples per minute and flatten the slope.
local function record_sample(pct)
  local now = os.time()
  local last = history[#history]

  -- A large drop means the window reset; previous samples no longer describe
  -- the same window, so start over.
  if last and pct < last.pct - 5 then
    history = {}
  end
  if last and last.t == now then return end   -- one sample per second, at most
  table.insert(history, { t = now, pct = pct })

  -- keep roughly the last hour of samples
  while #history > 0 and now - history[1].t > 3600 do
    table.remove(history, 1)
  end
end

-- Least-squares slope over recorded samples, projected to 100%. Returns
-- seconds until the window is exhausted, or nil when usage is flat or falling.
local function burn_rate_eta(pct)
  if #history < 3 then return nil end

  local n, sx, sy, sxy, sxx = #history, 0, 0, 0, 0
  for _, p in ipairs(history) do
    local x = p.t - history[1].t
    sx, sy = sx + x, sy + p.pct
    sxy, sxx = sxy + x * p.pct, sxx + x * x
  end
  local denom = n * sxx - sx * sx
  if denom == 0 then return nil end
  local slope = (n * sxy - sx * sy) / denom   -- percent per second
  if slope <= 0 then return nil end
  local remaining = 100 - pct
  if remaining <= 0 then return 0 end
  return remaining / slope
end

-- ------------------------------------------------------------- rendering --

local ESC, RESET = "\x1b[", "\x1b[0m"

local function fg(hex)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return string.format("%s38;2;%d;%d;%dm", ESC, r, g, b)
end

local function colour_for(pct)
  local t = config.thresholds
  if pct >= t.crit then return fg(config.colors.crit) end
  if pct >= t.high then return fg(config.colors.high) end
  if pct >= t.warn then return fg(config.colors.warn) end
  return fg(config.colors.ok)
end

local function bar(pct)
  if not config.bars.enabled then return nil end
  local w = config.bars.width
  local filled = math.floor((math.min(pct, 100) / 100) * w + 0.5)
  return colour_for(pct) .. string.rep(config.bars.full, filled)
    .. fg(config.colors.dim) .. string.rep(config.bars.empty, w - filled)
end

local function window_segment(label, pct, resets_at, eta)
  local dim, text = fg(config.colors.dim), fg(config.colors.text)
  local s = text .. label .. " "
  local b = bar(pct)
  if b then s = s .. b .. " " end
  s = s .. colour_for(pct) .. string.format("%.0f%%", pct)
  if not config.compact then
    local left = seconds_until(resets_at)
    if left then s = s .. dim .. " (" .. fmt_duration(left) .. ")" end
  end
  if eta then
    s = s .. dim .. " " .. config.icons.burn .. fmt_duration(eta)
  end
  return s
end

local function build_status(data)
  local dim = fg(config.colors.dim)
  local icon = dim .. " " .. config.icons.claude .. " "

  if data.error then
    return icon .. fg(config.colors.crit) .. tostring(data.error) .. RESET
  end

  local five = data.five_hour or {}
  local seven = data.seven_day or {}
  local five_pct = five.utilization or 0
  local seven_pct = seven.utilization or 0

  local eta = nil
  if config.show_burn_rate then
    local secs = burn_rate_eta(five_pct)
    -- only worth showing if the cap arrives before the window resets anyway
    local until_reset = seconds_until(five.resets_at)
    if secs and (not until_reset or secs < until_reset) then eta = secs end
  end

  local s = icon
    .. window_segment("5h", five_pct, five.resets_at, eta)
    .. dim .. "  " .. config.icons.week .. " "
    .. window_segment("7d", seven_pct, seven.resets_at, nil)
  return s .. RESET
end

-- ----------------------------------------------------------------- fetch --

local function fetch()
  local now = os.time()
  if cached and (now - last_fetch) < config.poll_interval_secs then
    return cached
  end

  local token, _, err = get_token()
  if not token then
    last_fetch, last_error = now, err
    cached = { error = err }
    return cached
  end

  local body, code, curl_err = call_api(token)
  last_fetch = now

  if curl_err then
    cached = { error = curl_err }
    return cached
  end
  if code and code ~= 200 then
    cached = { error = "http " .. tostring(code) }
    return cached
  end

  local ok, parsed = pcall(wezterm.json_parse, body)
  if not ok or type(parsed) ~= "table" then
    cached = { error = "bad response" }
    return cached
  end

  last_error = nil
  cached = parsed
  if parsed.five_hour and parsed.five_hour.utilization then
    record_sample(parsed.five_hour.utilization)
  end
  return cached
end

-- ----------------------------------------------------------------- setup --

local DASHBOARD_URL = "https://console.anthropic.com/settings/usage"

local function deep_merge(base, override)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(override) do
    if type(v) == "table" and type(out[k]) == "table" then
      out[k] = deep_merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

function M.apply_to_config(c, opts)
  if opts then config = deep_merge(config, opts) end

  if config.dashboard_key then
    local keys = c.keys or {}
    table.insert(keys, {
      key = config.dashboard_key.key,
      mods = config.dashboard_key.mods,
      action = wezterm.action.EmitEvent("claude-quota-dashboard"),
    })
    c.keys = keys
    wezterm.on("claude-quota-dashboard", function()
      wezterm.open_with(DASHBOARD_URL)
    end)
  end

  if handler_registered then return end
  handler_registered = true

  wezterm.on("update-status", function(window, _)
    local ok, err = pcall(function()
      local status = build_status(fetch())
      if config.position == "left" then
        window:set_left_status(status)
      else
        window:set_right_status(status)
      end
    end)
    if not ok then
      wezterm.log_error("claude-quota: " .. tostring(err))
    end
  end)
end

-- exposed for testing
M._internal = {
  resolve_credentials = resolve_credentials,
  wsl_home = wsl_home,
  seconds_until = seconds_until,
  fmt_duration = fmt_duration,
  record_sample = record_sample,
  burn_rate_eta = burn_rate_eta,
  build_status = build_status,
  reset_history = function() history = {} end,
  seed_history = function(samples) history = samples end,
}

return M
