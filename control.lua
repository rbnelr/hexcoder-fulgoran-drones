local g = require("common")
local util = require("util")
local dmg = require("disable_on_damage")
local Vault = require("vault")
require("spawning")
local movement = require("bot_movement")
require("gui_util")

local TINT = {0.80, 0.05, 0.05}
local TINT_FILL = {TINT[1]*0.1,TINT[2]*0.1,TINT[3]*0.1,0.1}

-- 'somewhat lazy' init ideally called in every handler
function init()
	-- create enemy drone force
	if game.forces[g.DRONE_FORCE] == nil then
		local force = game.create_force(g.DRONE_FORCE)
		--force.custom_color = {255,215,0}
		force.custom_color = {230,50,255}
	end
	
	local s = storage
	local init = next(s) == nil
	--if s == nil then -- I was setting storage to nil, apparently default is {} though, so this should not be needed!
	--	s = {} ---@diagnostic disable-line
	--	storage = s
	--end
	if s.vaults == nil then s.vaults = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.render_objs == nil then s.render_objs = {} end
	
	if init then
		local surface = game.get_surface("fulgora")
		if surface then
			for _,e in pairs(surface.find_entities_filtered{name=g.VAULT_NAME}) do
				Vault.from_entity(e)
			end
			
			if g.TRY_SPAWN_MISSING_VAULTS then
				for cpos in surface.get_chunks() do
					if surface.is_chunk_generated(cpos) then
						Vault.try_place_missing_vault_ruin(surface, {{cpos.x*32,cpos.y*32}, {cpos.x*32+32,cpos.y*32+32}})
					end
				end
			end
		end
	end
end

-- detect vaults on startup and as they spawn in
---@param surface LuaSurface
---@param area BoundingBox
local function init_chunk(surface, area)
	local vaults = surface.find_entities_filtered{name=g.VAULT_NAME, area=area}
	if next(vaults) then
		for _,e in pairs(surface.find_entities_filtered{name=g.VAULT_NAME, area=area}) do
			Vault.from_entity(e)
		end
	elseif g.TRY_SPAWN_MISSING_VAULTS then
		Vault.try_place_missing_vault_ruin(surface, area)
	end
end

-- reset for dev purposes
-- but may also be used for deinstalling mod
local function reset()
	local surface = game.get_surface("fulgora")
	if surface then
		for _,e in pairs(surface.find_entities_filtered{name={g.VAULT_NEAR_WALL_NAME,g.WAYPOINT}}) do
			e.destroy()
		end
	end
	
	rendering.clear(g.MOD_NAME)
	
	for _,player in pairs(game.players) do
		local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
		if existing then
			existing.destroy()
		end
	end
	
	local drone_force = game.forces[g.DRONE_FORCE]
	if drone_force then
		-- can't delete forces directly (?), I guess this means that spawned bots now belong to the player until they timeout
		-- force still exists until next tick or so, may crash if calling init after this but not every tick!
		game.merge_forces(drone_force, game.forces["player"])
	end
	
	-- fix_building only makes sure buildings that are stuck depite being repaired get enabled
	-- if used for deinstall, want restore_building instead
	local s = storage
	if s and s.poll_repaired then
		for _,e in pairs(s.poll_repaired) do
			if e.entity and e.entity.valid then
				dmg.fix_building(e.entity.unit_number, e.entity)
			end
		end
	end
	-- this makes us forget vaults, active waves and bots
	storage = {}
	
	-- vaults will be rescanned, but active bots will linger until dying by timeout
end
--local _was_reset
--function g._dev_reset()
--	if g.DEBUG and not _was_reset then
--		_was_reset = true
--		reset()
--		init()
--	end
--end

script.on_event(defines.events.on_tick, function(event)
	--local prof = helpers.create_profiler()
	--g._dev_reset()
	init()
	
	-- TODO: could skip expensive checks by checking something like (last-get_resource_counts())>1000 first for whole planet?
	-- how? pause until condition met, then scan every chunk once, then pause again?
	
	g.stagger_tick(storage.poll_vaults, storage.vaults, g.ORE_POLL_PERIOD, function(vault)
		if vault.entity.valid then
			vault:update_waves()
		end
	end)
	
	dmg.on_tick(event)
	
	--for id,v in pairs(storage.vaults) do
	for id,v in pairs(storage.active_vaults) do
		if v.entity.valid then -- and v:wave_active()
			v:update_alert()
			v:update_emerging()
			
			movement.update(v)
		end
	end
	
	--prof.stop()
	--game.print(prof)
end)

local deathrattles = { ---@type function(EventData.on_object_destroyed)[]
	[defines.target_type.entity] = function(event)
		if storage.vaults ~= nil then
			local vault = storage.vaults[event.registration_number]
			if vault ~= nil then
				vault:destroy()
			end
		end
	end,
	[defines.target_type.player] = function(event)
		for _,v in pairs(storage.render_objs[event.useful_id]) do
			v.destroy()
		end
		storage.render_objs[event.useful_id] = nil
	end,
}
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if storage ~= nil and handler ~= nil then
		init()
		handler(event)
	end
end)

local function append(tbl1, tbl2)
	local t = util.table.deepcopy(tbl1)
	for k,v in pairs(tbl2) do
		table.insert(t, v)
	end
	return t
end
local built_filter = append(dmg.event_filter, {
	{filter="type", type="simple-entity"},
	{filter="name", name=g.VAULT_NAME, mode="and"}
})
local died_filter = append(dmg.event_filter, {
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[1], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[2], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[3], mode="and"}
})
	
for _, name in pairs({
	defines.events.on_built_entity, -- also triggered by editor
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
}) do
	script.on_event(name, function(event)
		init()
		local entity = event.entity or event.destination --[[@as LuaEntity]]
		if entity.type == "simple-entity" then
			-- can't actually be built in game, but still do generic built events
			if entity.name == g.VAULT_NAME then
				Vault.from_entity(entity)
			end
		else
			dmg.on_entity_event(entity)
		end
	end, built_filter)
end

-----@param event EventData.on_entity_died
--local function remove_alert(event)
--	local surf = game.surfaces["fulgora"]
--	local force = game.forces["player"]
--	if event.entity.force == force then
--		--local pos = event.entity.position
--		--for _,p in pairs(game.players) do
--		--	--p.remove_alert{entity=event.entity}
--		--	p.remove_alert{surface=surf, position=pos} -- alert does not exist yet, and if removed after it exists the sound still plays!
--		--end
--		
--		--event.entity.destroy() works but messes things up, like no corpses or loot
--	end
--	--game.remove_alert{type=defines.alert_type.entity_destroyed, surface="fulgora"}
--	--game.remove_alert{type=defines.alert_type.entity_under_attack, surface="fulgora"}
--end

--script.on_event(defines.events.on_entity_died, function(event)
--	if event.entity.type == "combat-robot" then
--		Vault.on_drone_died(event)
--	else
--		dmg.on_entity_event(event.entity)
--	end
--end, died_filter)
script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.surface.name == "fulgora" then
		init()
		if event.entity.type == "combat-robot" then
			--Vault.on_drone_died(event) -- not needed right now, needed for drone 
		elseif g.IS_TARGET[event.entity.name] then
			dmg.on_entity_event(event.entity)
		end
		--remove_alert(event)
	end
end)
--script.on_event(defines.events.on_post_entity_died, function(event)
--	local surf = game.surfaces["fulgora"]
--	if event.force.name == g.DRONE_FORCE and
--	   event.surface_index == surf.index then
--		--remove_alert(event)
--		
--		local pos = event.position
--		for _,p in pairs(game.players) do
--			--p.remove_alert{entity=event.entity}
--			p.remove_alert{surface=surf, position=pos}
--		end
--	end
--end) -- can be filtered to only enemy force killing things, but my actual drone force only exists after init

script.on_event(defines.events.on_chunk_generated, function(event)
	if event.surface.name == "fulgora" then
		init()
		init_chunk(event.surface, event.area)
	end
end)

script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.on_dmg_filter)


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
---@return string
local function update_info_gui_content(vault, gui)
		
	local time_since_start = (game.tick - (vault.wave_start_tick or 0)) / 3600
	local time_between = (game.tick - (vault.wave_end_tick or 0)) / 3600
	
	local remain_ore = vault:get_ore_remaining()
	local initial_ore = vault.initial_ore_amount
	local mined_since_last = (vault.wave_start_ore_amount or remain_ore) - remain_ore
	local mined_total = (initial_ore or remain_ore) - remain_ore
	if mined_since_last < 0 then mined_since_last = 0 end
	if mined_total < 0 then mined_total = 0  vault.initial_ore_amount = vault:get_initial_ore() end
	
	local mining_rate = mined_since_last / time_since_start
	
	-- prev or current wave bots
	local s_bots = "Bots: "
	for n,c in pairs(vault.wave_bots) do
		s_bots = s_bots..string.format("%d [entity=%s,quality=normal], ", c, n)
	end
	--gui.all_text.caption = string.format("Bots: %d active %d emerging %d queued",
	--	table_size(vault.active_wave_bots),
	--	table_size(vault.wave_emerging_projectiles),
	--	table_size(vault.wave_emerging)
	--)
	
	local depth = mined_total / initial_ore * 100
	
	--gui.mining1.caption = string.format("%6d (%d/m)", mined_since_last, mining_rate)
	gui.mining1.caption = string.format("Rate: %d/min", mining_rate)
	gui.mining2.caption = string.format("Progess: %4.2fM / %4.2fM", mined_total/1000000, initial_ore/1000000) -- "[font=default-bold]%4.2fM[/font] / [font=default-bold]%4.2fM[/font]"
	--gui.mining3.caption = string.format("Depth: %dm (%s)", depth, )
	
	if vault:wave_active() then
		gui.cur_cap.caption = string.format("Wave active for %.1fmin!", time_since_start)
		gui.cur1.caption = string.format("Size: %3.0f %%", (vault.wave_size or 0) * 100)
		gui.cur2.caption = string.format("Freq: %.1fmin", (1/(vault.wave_freq or 0)))
		gui.cur3.caption = s_bots
		
		gui.last_cap.caption = "Last Wave"
		gui.last1.caption = ""
		gui.last2.caption = ""
		gui.last3.caption = ""
	else
		-- Note that this factors in random variation
		local trigger_wave, size, freq, eta = vault:should_spawn_wave(mined_since_last, time_since_start, time_between, false)
		
		gui.cur_cap.caption = string.format("Next Wave est. in %.1fmin", eta or 0)
		gui.cur1.caption = string.format("Size: %3.0f%%", (size or 0) * 100)
		gui.cur2.caption = string.format("Freq: %.1fmin", 1/(freq or 0)) -- despite being used internally, maybe displaying frequency is a bit weird, eta for next, and time since last might be enough
		gui.cur3.caption = ""
		
		gui.last_cap.caption = string.format("Last wave %.1fmin ago", time_since_start)
		gui.last1.caption = string.format("Size: %3.0f%%", (vault.wave_size or 0) * 100)
		gui.last2.caption = string.format("Freq: %.1fmin", (1/(vault.wave_freq or 0)))
		gui.last3.caption = s_bots
	end
end

---@param player LuaPlayer
local function update_info_gui(player)
	local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
	if existing then
		existing.destroy()
	end
	
	local selected = player.selected
	if selected and selected.valid and selected.name == g.VAULT_NAME then
		local vault = Vault.from_entity(selected)
		
		local window, refs = vauld_gui_def:add_to(player.gui.left)
		update_info_gui_content(vault, refs)
	end
end

-- Show vault radius on hover
---@param player LuaPlayer
local function update_viz(player)
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
		draws[1] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=TINT_FILL, render_mode="chart"}
		draws[2] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=80, color=TINT, render_mode="chart"}
		
		draws[3] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=TINT_FILL}
		draws[4] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=5, color=TINT}
		
		--local p = selected.position
		--local sr = r*0.71
		--rendering.draw_rectangle{left_top={p.x-sr, p.y-sr}, right_bottom={p.x+sr, p.y+sr}, surface=surf, filled=true, color=TINT_FILL}
	end
	
	storage.render_objs[player.index] = draws
end
local function update_all_viz()
	init()
	for _,player in pairs(game.players) do
		update_viz(player)
		update_info_gui(player)
	end
end

script.on_event(defines.events.on_selected_entity_changed, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	local prev = event.last_entity
	if (selected and selected.name == g.VAULT_NAME) or (prev and prev.name == g.VAULT_NAME) then
		init()
		if g.DEBUG and selected and selected.name == g.VAULT_NAME then
			--Vault.from_entity(player.selected):dbg_print(player)
		end
		update_viz(player)
		update_info_gui(player)
	end
end)

-- on_selected_entity_changed viz can get stuck sometimes
-- seemingly on_selected_entity_changed does not handle going into map view, an there's no event?
-- so poll as well
script.on_nth_tick(30, function(event)
	init()
	update_all_viz()
end)

if g.DEBUG then
	--local _prev_ore = nil
	--commands.add_command("fulg-ore", "", function(command)
	--	init()
	--	local player = game.get_player(command.player_index) ---@cast player -nil
	--	
	--	local selected = player.selected
	--	if selected == nil then return end
	--	
	--	local count = Vault.from_entity(selected):get_ore_remaining()
	--	
	--	local diff = _prev_ore and count - _prev_ore or nil
	--	_prev_ore = count
	--	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..selected.position.x..", "..selected.position.y..")")
	--end)

	commands.add_command("fulg-attack", "", function(command)
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 1
		
		-- vault for testing
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == g.VAULT_NAME then
			Vault.from_entity(sel):spawn_wave(size, 1, true)
		end
	end)
end

script.register_metatable("Vault", Vault)

---@class obj_id : integer -- register_on_object_destroyed-based id
---@class unit_number : integer
---@class player_index : integer

---@class ModStorage
---@field vaults table<obj_id, Vault>
---@field friend_end_tick integer?
---@field poll_vaults table
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---@field active_vaults table<obj_id, Vault>
---@field render_objs table<player_index, LuaRenderObject[]?>

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

--script.on_init(init)

-- ctrl+alt+click when loading to trigger on_configuration_changed without version change, but mod_changes will be empty!
script.on_configuration_changed(function(data)
	local changes = data.mod_changes[g.MOD_NAME]
	if changes or g.DEBUG then
		if g.DEBUG then -- dev reset
			reset()
			init()
			return
		end
		
		-- reset + init works too, why is this a pattern I see often? because this can be used instead of script.on_init?
		--local old = changes.old_version
		--if not old then
		--	init()
		--	return
		--end
		
		-- reset + init, kinda works, but may be arkward
		reset()
		init()
	end
end)
