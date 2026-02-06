# broadcast-input-wezterm

Small, dependency-free broadcast input helper for WezTerm.
It adds a simple UI to send text (and optional Enter) to multiple panes.

## Install

1) Clone this repo into your WezTerm config directory:
   - Windows (PowerShell):
     ```powershell
     cd $env:USERPROFILE\.wezterm
     git clone https://github.com/h2cone/broadcast-input-wezterm.git
     ```
   - macOS/Linux:
     ```bash
     cd ~/.wezterm
     git clone https://github.com/h2cone/broadcast-input-wezterm.git
     ```
2) Require it from `.wezterm.lua` as:
   - `require("broadcast-input-wezterm.broadcast_input")`

## Quick start (minimal config)

```lua
local wezterm = require("wezterm")
local broadcast = require("broadcast-input-wezterm.broadcast_input")

local config = wezterm.config_builder()

-- Adds the broadcast UI and a default key binding (Ctrl+Shift+I).
broadcast.setup({ config = config })

return config
```

Default behavior:
- Scope: active tab, all panes
- Hotkey: Ctrl+Shift+I
- Event name: `trigger-broadcast`

## Customize the key binding

```lua
broadcast.setup({
  config = config,
  key_binding = { key = "B", mods = "ALT" },
})
```

Disable the default binding:

```lua
broadcast.setup({
  config = config,
  key_binding = false,
})
```

## Customize the UI

```lua
broadcast.setup({
  config = config,
  ui = {
    title = "Broadcast input",
    prompt = "Enter text to send:",
    choices = {
      { id = "broadcast", label = "Broadcast only" },
      { id = "submit", label = "Submit only (send Enter)" },
      { id = "broadcast_submit", label = "Broadcast and submit" },
    },
  },
})
```

## Customize broadcast behavior

When you pass `config`, put broadcast options under `broadcast`.

```lua
broadcast.setup({
  config = config,
  broadcast = {
    scope = "all_tabs",      -- "active_tab" or "all_tabs"
    tab_mode = "all_panes",  -- "all_panes" or "active_pane"
  },
})
```

## Advanced usage

If you want full control, create the API manually:

```lua
local api = broadcast.new({
  scope = "active_tab",
  tab_mode = "all_panes",
})

api.install_broadcast_ui() -- registers the default UI and event
```

You can also call these directly:
- `api.broadcast_text(window, text)`
- `api.broadcast_submit(window)`
- `api.broadcast_text_and_submit(window, text)`
- `api.prompt_and_broadcast(window, pane, opts)`
