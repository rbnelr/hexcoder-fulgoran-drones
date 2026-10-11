local g = require("common")
local Vault = require("vault")
require("gui_util")

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
	if selected and selected.name == g.VAULT_NAME then
		draws = {}
		
		local surf = selected.surface
		local r = g.VAULT_DEFENSE_RADIUS()
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
		gui_hflow{}:add{
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", name="cur_cap", caption="", style={base="caption_label"}},
				GUI{type="label", name="cur1", caption=""},
				GUI{type="label", name="cur2", caption=""},
				GUI{type="label", name="cur3", caption=""},
			},
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", name="last_cap", caption="", style={base="caption_label"}},
				GUI{type="label", name="last1", caption=""},
				GUI{type="label", name="last2", caption=""},
				GUI{type="label", name="last3", caption=""},
			},
			GUI{type="frame", direction="vertical", style={base="inside_deep_frame", padding=4}}:add{
				GUI{type="label", caption="Mining", style={base="caption_label"}},
				GUI{type="label", name="mining1", caption=""},
				GUI{type="label", name="mining2", caption=""},
				GUI{type="label", name="mining3", caption=""},
			},
		}
	}
	
	return window
end
local vauld_gui_def = get_window_def()

---@param vault Vault
---@param gui GuiRefs
function gui.update_info_gui_content(vault, gui)
	local function bot_list(bots)
		local str = "Bots: --"
		if bots and next(bots) then
			str = "Bots:"
			for n,c in pairs(bots) do
				str = str..string.format("  %d[entity=%s,quality=normal]", c, n)
			end
		end
		return str
	end
	
	local time_since_start = (game.tick - (vault.wave_start_tick or 0)) / 3600
	local time_between = (game.tick - (vault.wave_end_tick or 0)) / 3600
	
	local remain_ore = vault:get_ore_remaining()
	local initial_ore = vault.initial_ore_amount
	local mined_since_last = (vault.wave_start_ore_amount or remain_ore) - remain_ore
	local mined_total = (initial_ore or remain_ore) - remain_ore
	if mined_since_last < 0 then mined_since_last = 0 end
	if mined_total < 0 then mined_total = 0  vault.initial_ore_amount = vault:get_initial_ore() end
	
	local mining_rate = mined_since_last / time_since_start
	
	-- represent per vault evolution as "depth mined" in approx 0-100 meters (really just %)
	-- TODO: figure out how to scale evolution wave modifier and quality levels from mined amount (diminishing returns, and probably should not be tied to total patch size, but reach the higher tiers after a few million)
	local depth = mined_total / initial_ore * 100
	
	--gui.mining1.caption = string.format("%6d (%d/m)", mined_since_last, mining_rate)
	gui.mining1.caption = string.format("Rate: %d/min", mining_rate)
	gui.mining2.caption = string.format("Drained: %4.2fM / %4.2fM", mined_total/1000000, initial_ore/1000000) -- "[font=default-bold]%4.2fM[/font] / [font=default-bold]%4.2fM[/font]"
	gui.mining3.caption = string.format("Depth: %dm", depth)
	
	if vault:wave_active() then
		gui.cur_cap.caption = string.format("Wave active for %.1fmin!", time_since_start)
		gui.cur1.caption = string.format("Size: %3.0f %%", (vault.wave_size or 0) * 100)
		gui.cur2.caption = string.format("Freq: %.1fmin", (1/(vault.wave_freq or 0)))
		gui.cur3.caption = bot_list(vault.wave_bots_count)
		
		gui.last_cap.caption = string.format("Last wave %.1fmin ago", time_since_start)
		gui.last1.caption = "Size: --"
		gui.last2.caption = "Freq: --"
		gui.last3.caption = bot_list(nil)
	else
		-- Note that this factors in random variation
		local trigger_wave, size, freq, eta = vault:should_spawn_wave(mined_since_last, time_since_start, time_between, false)
		
		gui.cur_cap.caption = eta and string.format("Next Wave est. in %.1fmin", eta) or "Next Wave est. in --"
		gui.cur1.caption = size and string.format("Size: %3.0f%%", (size or 0) * 100) or "Size: --"
		gui.cur2.caption = freq and string.format("Freq: %.1fmin", 1/freq) or "Freq: --" -- despite being used internally, maybe displaying frequency is a bit weird, eta for next, and time since last might be enough
		gui.cur3.caption = bot_list(nil)
		
		gui.last_cap.caption = string.format("Last wave %.1fmin ago", time_since_start)
		gui.last1.caption = vault.wave_size and string.format("Size: %3.0f%%", vault.wave_size  * 100) or "Size: --"
		gui.last2.caption = vault.wave_freq and string.format("Freq: %.1fmin", 1/vault.wave_freq) or "Freq: --"
		gui.last3.caption = bot_list(vault.wave_bots_count)
	end
end

---@param player LuaPlayer
function gui.update_info_gui(player)
	local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
	if existing then
		existing.destroy()
	end
	
	local selected = player.selected
	if selected and selected.valid and selected.name == g.VAULT_NAME then
		local vault = Vault.from_entity(selected)
		
		local window, refs = vauld_gui_def:add_to(player.gui.left)
		gui.update_info_gui_content(vault, refs)
	end
end

return gui