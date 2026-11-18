local const = require("const")
local common = require("control.common")
local myutil = require("lib.myutil")
local dmg = require("control.disable_on_damage")
---@class Vault
local Vault = require("control.vault")
local depth_scaling = require("control.depth_scaling")
local dead_bots = require("control.dead_bots")
local movement = require("control.bot_movement")
local gui = require("control.gui")
local spawning = require("control.spawning")
local ore = require("control.ore_tracking")
local original_mapgen = require("control.original_mapgen")
local initialize = require("control.initialize")
local drills_without_ore = require("control.drills_without_ore")

-- All event registrations of the mod are in register_all() at the end of this file, other files only export their handlers
-- (one handler per event and nth_tick period per mod, so this also avoids conflicts)
-- commands stay in control/commands.lua and control/tests.lua (tests also registers its own on_nth_tick at runtime)

local deathrattles = { ---@type function(EventData.on_object_destroyed)[]
	[defines.target_type.entity] = function(event)
		if storage.vaults ~= nil then
			local vault = storage.vaults[event.registration_number]
			if vault ~= nil then
				vault:on_destroyed()
			end
		end
		-- TODO: also update_targets for vaults or is this fine?
		-- entities should basically never die anyway, and polling and bot movement handles invalid entities, I think
	end,
	[defines.target_type.player] = function(event)
		for _,v in pairs(storage.render_objs[event.useful_id] or {}) do
			v.destroy()
		end
		storage.render_objs[event.useful_id] = nil
	end,
}
---@param event EventData.on_object_destroyed
local function on_object_destroyed(event)
	local handler = deathrattles[event.type]
	if handler ~= nil then
		init()
		handler(event)
	end
end

local function on_entity_create(event)
	init()
	local entity = event.entity or event.destination --[[@as LuaEntity]] ---@diagnostic disable-line
	if entity.type == "simple-entity" then
		-- can't actually be built in game, but still do generic built events
		if entity.name == const.VAULT_NAME then
			get_or_init_vault(entity, "built")
		end
	elseif entity.surface.name == "fulgora" then
		dmg.on_entity_event(entity)
		
		for _,vault in pairs(find_nearby_vaults(entity)) do
			vault:update_targets()
			if entity.type == "mining-drill" then
				local e = vault.entity
				vault.scrap_tracker:on_drill_built(e.surface, e.position, const.VAULT_DEFENSE_RADIUS)
			end
		end
		if entity.type == "mining-drill" then
			depth_scaling.update_quality_for_single_drill(entity)
		end
	end
end

local built_filter = myutil.merge(dmg.filter_targets, {
	{filter="type", type="simple-entity"},
	{filter="name", name=const.VAULT_NAME, mode="and"}
})

-- player builds additionally check drills (and drill ghosts) without ore away from vaults, when the setting allows placing them everywhere
local player_built_filter = built_filter
if const.ALLOW_DRILLS_WITHOUT_ORE then
	player_built_filter = myutil.merge(built_filter, {{filter="ghost_type", type="mining-drill"}})
end
---@param event EventData.on_built_entity
local function on_built_entity(event)
	if const.ALLOW_DRILLS_WITHOUT_ORE then
		if drills_without_ore.on_built_entity(event) then return end -- removed
		if event.entity.type == "entity-ghost" then return end -- only passed the filter for the drill check
	end
	on_entity_create(event)
end
---@param event EventData.on_entity_died
local function on_entity_died(event)
	if event.entity.surface.name == "fulgora" then
		if const.IS_TARGET[event.entity.type] then
			-- TODO: why am I calling this again? I think to reset non-military state so that revived entity will actually get attacked
			-- currently entities are prevented from dying to enemies (but player could kill them)
			-- except Vault:update_targets handles military target state, this even might be useless
			dmg.on_entity_event(event.entity)
		end
		--remove_alert(event)
	end
end

-- register vaults in newly generated chunks (fresh, nothing can have been mined there yet)
---@param event EventData.on_chunk_generated
local function on_chunk_generated(event)
	if event.surface.name == "fulgora" then
		init()
		for _,e in pairs(event.surface.find_entities_filtered{name=const.VAULT_NAME, area=event.area}) do
			get_or_init_vault(e, "on_chunk_generated")
		end
	end
end

-- This was an attempt at preventing alerts on select entities via script, but it did not work
-- we can't disable or mute alterts per surface, only per type
-- and I seem to remember the problem here was that they alerts still audibly happen, even if I make them disappear instantly
-- TODO: maybe explore this more, ideally make a setting to disable alerts on damaged or destroyed objects near vaults (also could use this in other mods)
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
--script.on_event(defines.events.on_post_entity_died, function(event)
--	local surf = game.surfaces["fulgora"]
--	if event.force.name == const.DRONE_FORCE and
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

---- Tick
---@param event EventData.on_tick
local function on_tick(event)
	--local prof = helpers.create_profiler()
	--common._dev_reset()
	init()
	
	if storage.settings_changed then
		storage.settings_changed = nil
		local fulgora = game.surfaces["fulgora"]
		if fulgora then
			depth_scaling.update_quality_for_all_vaults(fulgora)
		end
	end
	
	myutil.stagger_tick(storage.poll_vaults, storage.vaults, const.ORE_POLL_PERIOD, function(vault)
		if vault.entity.valid then
			vault:update_waves()
		end
	end)
	
	dmg.on_tick(event)
	
	local update_alerts = event.tick % 30 == 0
	
	for id,vault in pairs(storage.active_vaults) do
		if vault:bots_active() then
			if update_alerts then
				vault:update_alert()
			end
			spawning.update_emerging(vault)
			
			movement.update(vault)
		else
			vault:end_wave(true) -- true: actually make wave inactive
			
			assert(next(vault.waypoints) == nil)
		end
	end
	
	-- vault gui threat counter, the rest of the gui is refreshed in on_nth_tick below
	for _,player in pairs(game.connected_players) do
		gui.update_info_gui_fast(player)
	end
	
	--prof.stop()
	--game.print(prof)
end

---- Gui + viz circle
---@param event EventData.on_selected_entity_changed
local function on_selected_entity_changed(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	local prev = event.last_entity
	if (selected and selected.name == const.VAULT_NAME) or (prev and prev.name == const.VAULT_NAME) then
		init()
		gui.update_viz(player)
		gui.update_info_gui(player)
	end
end
-- on_selected_entity_changed viz can get stuck sometimes
-- seemingly on_selected_entity_changed does not handle going into map view, and there's no event for map view switch?
-- so poll for this, should be okay
---@param event NthTickEventData
local function poll_viz(event)
	init()
	gui.update_all_viz()
end

---- Registration
local function register_all()
	script.on_event(defines.events.on_object_destroyed, on_object_destroyed)

	-- None are triggered by map generator, on_chunk_generated handles newly generated vaults
	script.on_event(defines.events.on_built_entity, on_built_entity, player_built_filter)
	script.on_event(defines.events.on_robot_built_entity, on_entity_create, built_filter)
	script.on_event(defines.events.on_space_platform_built_entity, on_entity_create, built_filter)
	script.on_event(defines.events.script_raised_built, on_entity_create, built_filter)
	script.on_event(defines.events.script_raised_revive, on_entity_create, built_filter)
	script.on_event(defines.events.on_entity_cloned, on_entity_create, built_filter) -- source to destination

	script.on_event(defines.events.on_entity_died, on_entity_died, dmg.filter_targets)
	script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.filter_targets_on_dmg)
	script.on_event(defines.events.on_chunk_generated, on_chunk_generated)
	script.on_event(defines.events.on_trigger_created_entity, spawning.on_trigger_created_entity)
	script.on_event(defines.events.on_resource_depleted, ore.on_resource_depleted) -- inf or finite version, by the inf scrap setting

	script.on_event(defines.events.on_research_finished, dead_bots.update_unlocked_qualities)
	script.on_event(defines.events.on_research_reversed, dead_bots.update_unlocked_qualities) -- unresearched from editor
	if const.HARVESTABLE_BOTS then
		script.on_event(const.MOD_NAME.."-on-create-combat-bot-remnant", dead_bots.on_create_remnant)
		script.on_event(const.MOD_NAME.."-on-combat-bot-died", dead_bots.on_bot_died)
	end

	script.on_event(defines.events.on_tick, on_tick)
	script.on_event(defines.events.on_selected_entity_changed, on_selected_entity_changed)

	script.on_nth_tick(20, poll_viz)
	script.on_nth_tick(60, original_mapgen.delete_unused_fake_surfaces)
	script.on_nth_tick(10*60, dead_bots.update_unlocked_qualities) -- catch research_all_technologies() etc.
	if ore.debug_vis_drain then
		script.on_nth_tick(1, ore.debug_vis_drain)
	end
end

-- generic, so nothing registered above can be missed (unregistering an unregistered event is fine)
local function unregister_all()
	for _,id in pairs(defines.events) do
		if id ~= defines.events.on_runtime_mod_setting_changed then
			script.on_event(id, nil)
		end
	end
	script.on_nth_tick(nil) -- all periods, also the one of control/tests.lua
	if const.HARVESTABLE_BOTS then -- custom events only exist with the setting
		script.on_event(const.MOD_NAME.."-on-create-combat-bot-remnant", nil)
		script.on_event(const.MOD_NAME.."-on-combat-bot-died", nil)
	end
end

-- "Prepare for uninstall" (common.UNINSTALL): only this handler stays registered, so no code runs while paused
-- what is registered must always follow the setting: a joining player registers from the main chunk with the current value
---@param event EventData.on_runtime_mod_setting_changed
local function on_runtime_mod_setting_changed(event)
	local was_uninstall = common.UNINSTALL
	
	initialize.on_runtime_mod_setting_changed(event) -- reset() or init() on uninstall toggle
	
	if common.UNINSTALL ~= was_uninstall then
		if common.UNINSTALL then
			unregister_all()
		else
			register_all()
		end
	end
end

-- on_init only gets called on mod install, both on new game start with mod installed and late install on existing save
-- on_init and on_configuration_changed only run at load, so they stay registered and check common.UNINSTALL themselves
script.on_init(initialize.on_init)
script.on_configuration_changed(initialize.on_configuration_changed)
script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
if not common.UNINSTALL then
	register_all()
end
