local g = require("common")
local util = require("util")
local dmg = require("disable_on_damage")
local Vault = require("vault")
require("ore_tracking")
require("spawning")
local dead_bots = require("dead_bots")
local movement = require("bot_movement")
local gui = require("gui")

---- Init

-- 'somewhat lazy' init ideally called in every handler
function init()
	-- create enemy drone force
	if game.forces[g.DRONE_FORCE] == nil then
		local force = game.create_force(g.DRONE_FORCE)
		--force.custom_color = {255,215,0}
		force.custom_color = {230,50,255}
		-- TODO: can give force robot livetime bonus
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
			
			--if g.TRY_SPAWN_MISSING_VAULTS then
			--	for cpos in surface.get_chunks() do
			--		if surface.is_chunk_generated(cpos) then
			--			Vault.try_place_missing_vault_ruin(surface, {{cpos.x*32,cpos.y*32}, {cpos.x*32+32,cpos.y*32+32}})
			--		end
			--	end
			--end
		end
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
	if handler ~= nil then
		init()
		handler(event)
	end
end)

---- Events

-- TODO: explain
local built_filter = g.merge(dmg.event_filter, {
	{filter="type", type="simple-entity"},
	{filter="name", name=g.VAULT_NAME, mode="and"}
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

-- could also trigger this via bots dying-particle trigger event?
-- any reason not to just react to on_entity_died?
-----@param event EventData.on_entity_died
local function on_drone_died(event)
	init()
	
	local drone = event.entity or event.robot
	--if drone.force == g.DRONE_FORCE and g.IS_DRONE[drone.name] then
	if drone and g.IS_DRONE[drone.name] then
		-- TODO: position may be of but but not of corpse, would like to get corpse position, use dying-particle trigger after all?
		dead_bots.add_dead_bot_resource(drone.surface, drone.position, drone.name, 1)
	end
end

local died_filter = g.merge(dmg.event_filter, {
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[1], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[2], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[3], mode="and"}
})
script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.surface.name == "fulgora" then
		if event.entity.type == "combat-robot" then
			on_drone_died(event) -- combat robot got killed (not if expired due to time!)
		elseif g.IS_TARGET[event.entity.name] then
			-- why am I calling this again? I think to reset non-military state so that revived entity will actually get attacked
			-- currently entities are prevented from dying to enemies (but player could kill them)
			dmg.on_entity_event(event.entity)
		end
		--remove_alert(event)
	end
end, died_filter)
script.on_event(defines.events.on_combat_robot_expired, on_drone_died)

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

script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.on_dmg_filter)

-- detect vaults as they spawn in during mapgen
---@param surface LuaSurface
---@param area BoundingBox
local function init_chunk(surface, area)
	local vaults = surface.find_entities_filtered{name=g.VAULT_NAME, area=area}
	if next(vaults) then
		for _,e in pairs(surface.find_entities_filtered{name=g.VAULT_NAME, area=area}) do
			local vault = Vault.from_entity(e)
			-- avoid lag from get_initial_ore() hack if not actually installing in running game
			-- so initial_ore is just current ore
			vault.initial_ore_amount = vault:get_ore_remaining()
		end
	end
	--elseif g.TRY_SPAWN_MISSING_VAULTS then
	--	Vault.try_place_missing_vault_ruin(surface, area)
	--end
end
script.on_event(defines.events.on_chunk_generated, function(event)
	if event.surface.name == "fulgora" then
		init()
		init_chunk(event.surface, event.area)
	end
end)

---- Tick

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

script.on_event(defines.events.on_selected_entity_changed, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	local prev = event.last_entity
	if (selected and selected.name == g.VAULT_NAME) or (prev and prev.name == g.VAULT_NAME) then
		init()
		if g.DEBUG and selected and selected.name == g.VAULT_NAME then
			--Vault.from_entity(player.selected):dbg_print(player)
		end
		gui.update_viz(player)
		gui.update_info_gui(player)
	end
end)
-- on_selected_entity_changed viz can get stuck sometimes
-- seemingly on_selected_entity_changed does not handle going into map view, and there's no event for map view switch?
-- so poll for this, shoudl be okay
script.on_nth_tick(30, function(event)
	init()
	gui.update_all_viz()
end)

---- Commands

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
			Vault.from_entity(sel):stop_wave_and_kill_bots(true)
			Vault.from_entity(sel):spawn_wave(size, 1, true)
		end
	end)
	commands.add_command("fulg-kill-wave", "", function(command)
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 1
		
		-- vault for testing
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == g.VAULT_NAME then
			Vault.from_entity(sel):stop_wave_and_kill_bots(true)
		end
	end)
	
	commands.add_command("fulg-spawn-bot-res", "", function(command)
		init()
		
		local args = command.parameter and string.gmatch(command.parameter, "[^%s]+")
		local type = args and args() or "destroyer"
		local count = args and args()
		count = count and tonumber(count) or 1
		
		-- vault for testing
		local player = game.get_player(command.player_index)
		
		dead_bots.add_dead_bot_resource(player.surface, player.position, type, count)
	end)
end

---- Init

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

script.on_init(init)
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
