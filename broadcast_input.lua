-- Broadcast input for wezterm
local wezterm = require("wezterm")

local M = {}

local BROADCAST_EVENT_DEFAULT = "trigger-broadcast"
local BROADCAST_KEY_DEFAULT = "I"
local BROADCAST_MODS_DEFAULT = "CTRL|SHIFT"
local BROADCAST_PROMPT_DEFAULT = "Enter text to broadcast:"
local BROADCAST_CHOICES_DEFAULT = {
	{ id = "broadcast", label = "Broadcast only" },
	{ id = "submit", label = "Submit only (send Enter)" },
	{ id = "broadcast_submit", label = "Broadcast and submit" },
}

local function lower_or_empty(value)
	if not value then
		return ""
	end
	return string.lower(value)
end

local function get_process_argv(pane)
	local ok, info = pcall(function()
		return pane:get_foreground_process_info()
	end)
	if not ok or not info or not info.argv then
		return ""
	end

	local parts = {}
	for _, arg in ipairs(info.argv) do
		parts[#parts + 1] = tostring(arg)
	end
	return lower_or_empty(table.concat(parts, " "))
end

local function pane_context(pane)
	return {
		title = lower_or_empty(pane:get_title()),
		process = lower_or_empty(pane:get_foreground_process_name()),
		argv = get_process_argv(pane),
	}
end

local function normalize_submit_keys(value)
	if not value then
		return {}
	end
	if value.key then
		return { value }
	end
	if type(value) == "table" and value[1] and value[1].key then
		return value
	end
	return {}
end

local function resolve_submit_keys(target, state)
	if target.disable_submit_keys == true or target.submit_keys == false then
		return {}
	end
	if target.submit_keys then
		return normalize_submit_keys(target.submit_keys)
	end
	if target.submit_key then
		return normalize_submit_keys(target.submit_key)
	end
	if target.submit then
		return normalize_submit_keys(target.submit)
	end
	return state.default_submit_keys
end

local function match_pattern(ctx, fields, pattern)
	if pattern == "" then
		return false
	end
	for _, field in ipairs(fields) do
		local hay = ctx[field] or ""
		if hay ~= "" and string.find(hay, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function default_match_target(targets, pane, ctx, fields)
	for _, target in ipairs(targets) do
		if target.enabled ~= false then
			if type(target.match) == "function" then
				if target.match(pane, ctx) then
					return target
				end
			else
				local patterns = target.patterns or {}
				for _, raw in ipairs(patterns) do
					local pattern = string.lower(tostring(raw))
					if match_pattern(ctx, fields, pattern) then
						return target
					end
				end
			end
		end
	end
	return nil
end

local function collect_panes_default(window, state)
	local mux = window:mux_window()
	if not mux then
		return {}
	end

	local tabs = {}
	if state.scope == "all_tabs" then
		tabs = mux:tabs()
	else
		local active_tab = mux:active_tab()
		if active_tab then
			tabs = { active_tab }
		end
	end

	local panes = {}
	local seen = {}
	for _, tab in ipairs(tabs) do
		local tab_panes
		if state.tab_mode == "active_pane" then
			local active_pane = tab:active_pane()
			tab_panes = active_pane and { active_pane } or {}
		else
			tab_panes = tab:panes()
		end

		for _, pane in ipairs(tab_panes) do
			local pane_id = pane:pane_id()
			if not seen[pane_id] then
				seen[pane_id] = true
				panes[#panes + 1] = pane
			end
		end
	end

	return panes
end

local function collect_targets(window, state)
	local panes
	if type(state.collect_panes) == "function" then
		panes = state.collect_panes(window, state) or {}
	else
		panes = collect_panes_default(window, state)
	end

	local matches = {}
	for _, pane in ipairs(panes) do
		if not state.pane_filter or state.pane_filter(pane) then
			local ctx = pane_context(pane)
			local target

			if type(state.target_matcher) == "function" then
				target = state.target_matcher(pane, ctx, state.targets)
			elseif #state.targets == 0 then
				target = state.default_target
			else
				target = default_match_target(state.targets, pane, ctx, state.match_fields)
			end

			if target then
				matches[#matches + 1] = { pane = pane, target = target }
			elseif state.include_unmatched then
				matches[#matches + 1] = { pane = pane, target = state.default_target }
			end
		end
	end

	return matches
end

local function log_info(state, message)
	if state.log then
		wezterm.log_info(message)
	end
end

local function log_error(state, message)
	if state.log then
		wezterm.log_error(message)
	end
end

local function prompt_text(window, pane, description, on_submit)
	window:perform_action(
		wezterm.action.PromptInputLine({
			description = description,
			action = wezterm.action_callback(function(inner_window, inner_pane, line)
				if line == nil or line == "" then
					return
				end
				on_submit(inner_window, inner_pane, line)
			end),
		}),
		pane
	)
end

local function broadcast_prompt(api, window, pane, description, submit_after)
	prompt_text(window, pane, description, function(win, _, line)
		api.broadcast_text(win, line)
		if submit_after then
			api.broadcast_text(win, "\r")
		end
	end)
end

local function build_key_binding(event, key_binding)
	if key_binding == false then
		return nil
	end
	if type(key_binding) == "table" then
		local binding = {}
		for key, value in pairs(key_binding) do
			binding[key] = value
		end
		if not binding.key then
			binding.key = BROADCAST_KEY_DEFAULT
		end
		if not binding.mods then
			binding.mods = BROADCAST_MODS_DEFAULT
		end
		if not binding.action then
			binding.action = wezterm.action.EmitEvent(event)
		end
		return binding
	end
	return {
		key = BROADCAST_KEY_DEFAULT,
		mods = BROADCAST_MODS_DEFAULT,
		action = wezterm.action.EmitEvent(event),
	}
end

local function append_key_binding(config, event, key_binding)
	if not config then
		return
	end
	local binding = build_key_binding(event, key_binding)
	if not binding then
		return
	end
	config.keys = config.keys or {}
	table.insert(config.keys, binding)
end

local function safe_send_text(state, pane, text)
	local ok = pcall(function()
		pane:send_text(text)
	end)
	if not ok then
		log_error(state, "Failed to send text to pane")
	end
end

local function mods_to_mask(mods)
	if not mods or mods == "" then
		return 1
	end
	local mask = 1
	for token in string.gmatch(mods, "[^|]+") do
		local upper = string.upper(token)
		if upper == "SHIFT" then
			mask = mask + 1
		elseif upper == "ALT" or upper == "OPT" then
			mask = mask + 2
		elseif upper == "CTRL" or upper == "CONTROL" then
			mask = mask + 4
		elseif upper == "META" then
			mask = mask + 8
		end
	end
	return mask
end

local function encode_key_sequence(state, key)
	local name = key and key.key
	if not name then
		return nil
	end
	if string.lower(name) == "enter" then
		local mask = mods_to_mask(key.mods)
		if mask == 1 then
			return "\r"
		end
		if state.csi_u then
			return string.format("\x1b[13;%du", mask)
		end
		return "\r"
	end
	return nil
end

local function resolve_send_key_mode(target, state)
	if target and target.send_key_mode then
		return target.send_key_mode
	end
	return state.send_key_mode
end

local function safe_send_key(state, window, pane, key, mode)
	if mode == "text" then
		local sequence = encode_key_sequence(state, key)
		if sequence then
			safe_send_text(state, pane, sequence)
			return
		end
	end
	local ok = pcall(function()
		window:perform_action(
			wezterm.action.SendKey({
				key = key.key,
				mods = key.mods or "",
			}),
			pane
		)
	end)
	if not ok then
		log_error(state, "Failed to send submit key to pane")
	end
end

local function submit_to_pane(state, window, pane, target)
	if type(target.submit_action) == "function" then
		local ok = pcall(function()
			target.submit_action(window, pane, target)
		end)
		if not ok then
			log_error(state, "Failed to run submit_action")
		end
		return
	end

	local submit_text = target.submit_text
	if submit_text == nil then
		submit_text = state.default_submit_text
	end
	if submit_text and submit_text ~= "" then
		safe_send_text(state, pane, submit_text)
	end

	local keys = resolve_submit_keys(target, state)
	local send_key_mode = resolve_send_key_mode(target, state)
	for _, key in ipairs(keys) do
		if key and key.key then
			safe_send_key(state, window, pane, key, send_key_mode)
		end
	end
end

function M.new(opts)
	opts = opts or {}

	local state = {
		targets = opts.targets or {},
		default_submit_keys = normalize_submit_keys(opts.default_submit_keys or { key = "Enter" }),
		default_submit_text = opts.default_submit_text,
		scope = opts.scope or "active_tab",
		tab_mode = opts.tab_mode or "all_panes",
		match_fields = opts.match_fields or { "title", "process", "argv" },
		pane_filter = opts.pane_filter,
		target_matcher = opts.target_matcher,
		collect_panes = opts.collect_panes,
		include_unmatched = opts.include_unmatched == true,
		send_key_mode = opts.send_key_mode or "window",
		csi_u = opts.csi_u == true,
		log = opts.log ~= false,
	}

	state.default_target = {
		name = "default",
		submit_keys = state.default_submit_keys,
		submit_text = state.default_submit_text,
	}

	local api = {}

	function api.collect(window)
		return collect_targets(window, state)
	end

	function api.broadcast_text(window, text)
		local matches = collect_targets(window, state)
		log_info(state, "Broadcasting text to " .. #matches .. " target panes")
		for _, match in ipairs(matches) do
			safe_send_text(state, match.pane, text)
		end
		return matches
	end

	function api.broadcast_submit(window)
		local matches = collect_targets(window, state)
		log_info(state, "Broadcasting submit to " .. #matches .. " target panes")
		for _, match in ipairs(matches) do
			submit_to_pane(state, window, match.pane, match.target)
		end
		return matches
	end

	function api.broadcast_text_and_submit(window, text)
		local matches = collect_targets(window, state)
		log_info(state, "Broadcasting text+submit to " .. #matches .. " target panes")
		for _, match in ipairs(matches) do
			safe_send_text(state, match.pane, text)
			submit_to_pane(state, window, match.pane, match.target)
		end
		return matches
	end

	function api.prompt_and_broadcast(window, pane, prompt_opts)
		prompt_opts = prompt_opts or {}
		local description = prompt_opts.description or BROADCAST_PROMPT_DEFAULT
		local submit = prompt_opts.submit
		local allow_empty = prompt_opts.allow_empty
		window:perform_action(
			wezterm.action.PromptInputLine({
				description = description,
				action = wezterm.action_callback(function(inner_window, inner_pane, line)
					if line == nil then
						return
					end
					if line == "" and not allow_empty then
						return
					end
					if submit then
						api.broadcast_text_and_submit(inner_window, line)
					else
						api.broadcast_text(inner_window, line)
					end
				end),
			}),
			pane
		)
	end

	function api.install_broadcast_ui(opts)
		opts = opts or {}
		local event = opts.event or BROADCAST_EVENT_DEFAULT
		local title = opts.title or "Broadcast input"
		local prompt = opts.prompt or BROADCAST_PROMPT_DEFAULT
		local choices = opts.choices or BROADCAST_CHOICES_DEFAULT

		wezterm.on(event, function(window, pane)
			window:perform_action(
				wezterm.action.InputSelector({
					title = title,
					choices = choices,
					action = wezterm.action_callback(function(inner_window, inner_pane, id, _label)
						if not id then
							return
						end
						if id == "broadcast" then
							broadcast_prompt(api, inner_window, inner_pane, prompt, false)
							return
						end
						if id == "submit" then
							api.broadcast_text(inner_window, "\r")
							return
						end
						if id == "broadcast_submit" then
							broadcast_prompt(api, inner_window, inner_pane, prompt, true)
						end
					end),
				}),
				pane
			)
		end)
	end

	return api
end

function M.setup(opts)
	opts = opts or {}

	local has_wrapper_keys = opts.config ~= nil or opts.ui ~= nil or opts.key_binding ~= nil or opts.broadcast ~= nil
	local broadcast_opts = opts.broadcast
	if not has_wrapper_keys then
		broadcast_opts = opts
	elseif not broadcast_opts then
		broadcast_opts = {}
	end

	local api = M.new(broadcast_opts)
	if opts.ui ~= false then
		api.install_broadcast_ui(opts.ui)
	end
	local ui_opts = opts.ui or {}
	local event = ui_opts.event or BROADCAST_EVENT_DEFAULT
	append_key_binding(opts.config, event, opts.key_binding)
	return api
end

return M
