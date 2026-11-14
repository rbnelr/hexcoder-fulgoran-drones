local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local depth_scaling = require("control.depth_scaling")
local gui_util = require("lib.gui_util")
local GUI = gui_util.GUI

local gui = {}

local VIS_RADIUS_TINT = {0.80, 0.05, 0.05}
local VIS_RADIUS_TINT_FILL = {VIS_RADIUS_TINT[1]*0.1,VIS_RADIUS_TINT[2]*0.1,VIS_RADIUS_TINT[3]*0.1,0.1}

-- Show vault radius on hover
---@param player LuaPlayer
function gui.update_viz(player)
	init()
	
	local draws = storage.render_objs[player.index]
	if draws then -- remove previous rendering
		for _,d in pairs(draws) do
			d.destroy()
		end
		draws = nil
	end
	
	local selected = player.selected
	if selected and selected.name == const.VAULT_NAME then
		draws = {}
		
		local surf = selected.surface
		local r = const.VAULT_DEFENSE_RADIUS
		local pl = {player}
		draws[1] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=VIS_RADIUS_TINT_FILL, render_mode="chart"}
		draws[2] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=80, color=VIS_RADIUS_TINT, render_mode="chart"}
		
		draws[3] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=VIS_RADIUS_TINT_FILL}
		draws[4] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=5, color=VIS_RADIUS_TINT}
		
		--local p = selected.position
		--local sr = r*0.71
		--rendering.draw_rectangle{left_top={p.x-sr, p.y-sr}, right_bottom={p.x+sr, p.y+sr}, surface=surf, filled=true, color=TINT_FILL}
	end
	
	storage.render_objs[player.index] = draws
end

function gui.update_all_viz()
	for _,player in pairs(game.players) do
		gui.update_viz(player)
		gui.update_info_gui(player)
	end
end

---- Vault GUI

---@return GuiDef
local function get_window_def()
	local window = GUI{type="frame", name="hexcoder_fulgoran_drones_vault", direction="vertical"}:add{
		GUI{type="flow", style={horizontal_spacing=8}}:add{
			GUI{type="label", caption="Vault Ruin", style={base="frame_title", top_margin=-3, bottom_margin=3}, ignored_by_interaction=true}
		},
	}
	
	--[[
		Prev/active wave: size %, freq/m  bots: 5 A  6 B  12 C
		Mining: Since last (rate/m)
		ETA  size %, freq/m
		Mining Depth: total mined, "depth" in m, <bar for depth with quality indicator?
	]]
	
	window:add{
		gui_util.gui_hflow{}:add{
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", name="cur_cap", caption="", style={base="caption_label"}},
				GUI{type="label", name="cur1", caption=""},
				GUI{type="label", name="cur2", caption=""},
				GUI{type="label", name="cur3", caption=""},
				GUI{type="label", name="cur4", caption=""},
			},
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", name="last_cap", caption="", style={base="caption_label"}},
				GUI{type="label", name="last1", caption=""},
				GUI{type="label", name="last2", caption=""},
				GUI{type="label", name="last3", caption=""},
				GUI{type="label", name="last4", caption=""},
			},
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", caption="Mining", style={base="caption_label"}},
				GUI{type="label", name="mining1", caption=""},
				GUI{type="label", name="mining2", caption=""},
				GUI{type="label", name="mining3", caption=""},
			},
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", caption="Quality Tier", style={base="caption_label"}},
				GUI{type="label", name="quality1", caption=""},
				GUI{type="label", name="quality2", caption=""},
				GUI{type="label", name="quality3", caption=""},
			},
		}
	}
	
	return window
end
local vauld_gui_def = get_window_def()

---@param vault Vault
---@param gui GuiRefs
function gui.update_info_gui_content(vault, gui)
	local function bot_list(wave)
		local types = wave and wave.bot_types
		local str = "Bots: --"
		if types and next(types) then
			str = "Bots:"
			for n,c in pairs(types) do
				str = str..string.format("  %d[entity=%s,quality=normal]", c, n)
			end
		end
		return str
	end
	local function bot_quality_list(wave)
		local qualities = wave and wave.bot_qualities
		local str = "  "
		if qualities and next(qualities) then
			local total = 0
			for _,qn in ipairs(const.QUALITY_IDS) do
				local count = qualities[qn]
				if count then total = total + count end
			end
			for _,qn in ipairs(const.QUALITY_IDS) do
				local count = qualities[qn]
				if count then
					str = str..string.format("  %.0f%%[quality=%s]", count / total * 100, qn)
				end
			end
		end
		return str
	end
	
	local time_since_start = (game.tick - vault.wave_timer_start) / 3600
	--local time_between = (game.tick - (vault.wave_end_tick)) / 3600
	
	local scrap = vault.scrap_tracker
	local e = vault.entity
	scrap:scan(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, vault.has_drills)
	local mining_rate = scrap:mining_rate()
	
	-- represent per vault evolution as "depth mined" in approx 0-100 meters (really just %)
	local depth = scrap.depth
	
	--gui.mining1.caption = string.format("%6d (%d/m)", scrap.mined, mining_rate)
	gui.mining1.caption = string.format("Rate: %d/min", mining_rate)
	-- finite: actual amounts, drainable stops at the 20% floor, inf: drainable (down to the minimum)
	-- TODO: this may be confusing, but better have a depth that seems arbitrary than a obviously wrong total
	local total = scrap.initial_total or scrap.drainable
	local drained = scrap.initial_total and (total - scrap.amount_total) or (total - scrap.remaining)
	gui.mining2.caption = string.format("Drained: %4.2fM / %4.2fM", drained/1000000, total/1000000) -- "[font=default-bold]%4.2fM[/font] / [font=default-bold]%4.2fM[/font]"
	gui.mining3.caption = string.format("Depth: %dm", depth*100)
	
	-- size, freq and bots of a started wave, or -- if none
	---@param l1 LuaGuiElement
	---@param l2 LuaGuiElement
	---@param l3 LuaGuiElement
	---@param l4 LuaGuiElement
	---@param wave WaveInfo?
	local function show_wave(l1, l2, l3, l4, wave)
		l1.caption = wave and wave.size and string.format("Size: %3.0f%%", wave.size * 100) or "Size: --"
		l2.caption = wave and wave.freq and string.format("Freq: %.1fmin", 1/wave.freq) or "Freq: --"
		l3.caption = wave and bot_list(wave) or bot_list(nil)
		l4.caption = wave and bot_quality_list(wave) or bot_quality_list(nil)
	end
	
	-- waves may overlap, bots of the previous wave can still be around while the active one spawns
	local active, prev = vault.active_wave, vault.prev_wave
	if active then
		gui.cur_cap.caption = string.format("Wave active for %.1fmin!", (game.tick - active.start_tick) / 3600)
		show_wave(gui.cur1, gui.cur2, gui.cur3, gui.cur4, active)
	else
		-- Note that this factors in random variation
		local trigger_wave, size, freq, eta = vault:should_spawn_wave(mining_rate, time_since_start, false)
		
		gui.cur_cap.caption = eta and string.format("Next Wave est. in %.1fmin", eta) or "Next Wave est. in --"
		gui.cur1.caption = size and string.format("Size: %3.0f%%", (size or 0) * 100) or "Size: --"
		gui.cur2.caption = freq and string.format("Freq: %.1fmin", 1/freq) or "Freq: --" -- despite being used internally, maybe displaying frequency is a bit weird, eta for next, and time since last might be enough
		gui.cur3.caption = bot_list(nil)
		gui.cur4.caption = bot_quality_list(nil)
	end
	
	gui.last_cap.caption = prev and string.format("Last wave %.1fmin ago", (game.tick - prev.start_tick) / 3600) or "No wave yet"
	show_wave(gui.last1, gui.last2, gui.last3, gui.last4, prev)
	
	gui.quality1.caption = string.format("Scrap: %.1f", depth_scaling.scrap_tier(depth)+1)
	gui.quality2.caption = string.format("Drones: %.1f", depth_scaling.bot_tier(depth)+1)
end

---@param player LuaPlayer
function gui.update_info_gui(player)
	local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
	if existing then
		existing.destroy()
	end
	
	local selected = player.selected
	if selected and selected.valid and selected.name == const.VAULT_NAME then
		local vault = get_or_init_vault(selected)
		
		local window, refs = vauld_gui_def:add_to(player.gui.left)
		gui.update_info_gui_content(vault, refs)
	end
end

return gui