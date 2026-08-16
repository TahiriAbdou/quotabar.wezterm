# quotabar.wezterm

Claude Code usage quota in the WezTerm status bar.

```
 ⚡ 5h ███░░░░░ 42% (2h31m) ↑3h12m   ▪ 7d █░░░░░░░ 18% (4d12h)
```

- 5-hour and 7-day windows with usage bars and reset countdowns
- **Burn-rate projection** (`↑3h12m`) — a least-squares fit over the last hour
  of samples, showing when the 5h window will hit 100%. Hidden when usage is
  flat or falling, or when the window resets before the cap is reached.
- Colour-coded by threshold, cyberdream palette by default, fully configurable
- **Works under WSL**, which is the part other plugins get wrong

## Install

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

local quota = wezterm.plugin.require("https://github.com/TahiriAbdou/quotabar.wezterm")
quota.apply_to_config(config)

return config
```

Apply it **after** any `config.keys` you set, so its `Ctrl+Shift+U` binding is
appended rather than overwritten.

Requires `curl`. Nothing else.

## Platform support

| Platform | Credentials read from |
|---|---|
| macOS | Keychain (`Claude Code-credentials`), then `~/.claude/.credentials.json` |
| Linux | `~/.claude/.credentials.json` |
| Windows | `%USERPROFILE%\.claude\.credentials.json` |
| **Windows + WSL** | `wsl.exe -e cat $HOME/.claude/.credentials.json` |

### Why the WSL case needs special handling

WezTerm is a **Windows** process even when your shell is WSL. Plugins that
resolve credentials as `os.getenv("USERPROFILE") or os.getenv("HOME")` therefore
look in `C:\Users\<you>\.claude\`, which is empty — Claude Code runs inside the
distro, so the real file is at `~/.claude/.credentials.json` in Linux. The usual
symptom is a permanently blank status bar and no error.

This plugin falls through to reading it out of the distro directly. **No symlink
and no copied credential** — which also means token rotation is picked up
automatically, where a copy would go stale.

Set `wsl_distro` if you do not want the default distro.

### Process detection, deliberately absent

Some plugins gate the fetch on whether Claude is running, via `tasklist` on
Windows. That cannot see a WSL process, so the bar reads `not running` forever.
Quota is account-level and always fetchable, so this plugin simply doesn't check.

## Configuration

```lua
quota.apply_to_config(config, {
  poll_interval_secs = 60,
  position = "right",              -- or "left"
  dashboard_key = { key = "u", mods = "CTRL|SHIFT" },
  compact = false,                 -- hide reset countdowns
  show_burn_rate = true,
  credentials_path = nil,          -- explicit override, skips all detection
  wsl_distro = nil,                -- nil = default distro
  bars = { enabled = true, width = 8, full = "█", empty = "░" },
  icons = { claude = "⚡", week = "▪", burn = "↑" },
  colors = {
    ok = "#5eff6c", warn = "#f1ff5e", high = "#ffbd5e",
    crit = "#ff6e5e", dim = "#7b8496", text = "#ffffff",
  },
  thresholds = { warn = 50, high = 75, crit = 90 },
})
```

`Ctrl+Shift+U` opens the usage dashboard. Note it shadows WezTerm's built-in
`CharSelect` (the Unicode picker) — pass a different `dashboard_key`, or
`dashboard_key = false`, to keep it.

## Caveat

`https://api.anthropic.com/api/oauth/usage` is undocumented and unversioned. It
can change or disappear without notice; this plugin degrades to showing the
error rather than breaking your status bar.

## Credits

Two prior plugins, both MIT, mapped out this space first:

- [EdenGibson/wezterm-quota-limit](https://github.com/EdenGibson/wezterm-quota-limit)
  — the endpoint, headers and credential format
- [M-Marbouh/agent-quota.wezterm](https://github.com/M-Marbouh/agent-quota.wezterm)
  — the usage-bar presentation

## License

MIT — see [LICENSE](LICENSE).
