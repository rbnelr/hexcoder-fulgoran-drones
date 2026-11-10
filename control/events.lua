local const = require("const")
local common = require("control.common")
local dmg = require("control.disable_on_damage")
---@class Vault
local Vault = require("control.vault")
local dead_bots = require("control.dead_bots")
local movement = require("control.bot_movement")
local gui = require("control.gui")

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
local built_filter = common.merge(dmg.event_filter, {
	{filter="type", type="simple-entity"},
	{filter="name", name=const.VAULT_NAME, mode="and"}
})
-- Not triggered by map generator, on_chunk_generated handles newly generated ones
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
		local entity = event.entity or event.destination --[[@as LuaEntity]] ---@diagnostic disable-line
		if entity.type == "simple-entity" then
			-- can't actually be built in game, but still do generic built events
			if entity.name == const.VAULT_NAME then
				Vault.from_entity(entity)
			end
		else
			dmg.on_entity_event(entity)
			
			-- start ore scans for vaults this is near, see update_waves (cleared again by prepare at wave start)
			if entity.surface.name == "fulgora" then
				for _,e in pairs(entity.surface.find_entities_filtered{name=const.VAULT_NAME, position=entity.position, radius=const.VAULT_DEFENSE_RADIUS}) do
					local vault = storage.vaults[script.register_on_object_destroyed(e)]
					if vault then
						vault.has_targets = true
					end
				end
			end
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

if const.HARVESTABLE_BOTS then -- was const.HARVEST_BOTS (nil, handler never registered)
	-- only triggers for hostile prototypes
	script.on_event(const.MOD_NAME.."-on-create-combat-bot-remnant", function(event)
		local surface = game.get_surface(event.surface_index) ---@diagnostic disable-line
		if surface and surface.name == "fulgora" then
			init()
			
			dead_bots.add_dead_bot_resource(surface, event.target_position, const.DRONE_RESOURCE[event.effect_id], 1) ---@diagnostic disable-line
			-- could selectively spawn normal corpse here, but not needed right now
		end
	end)
end

script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.surface.name == "fulgora" then
		if const.IS_TARGET[event.entity.name] then
			-- why am I calling this again? I think to reset non-military state so that revived entity will actually get attacked
			-- currently entities are prevented from dying to enemies (but player could kill them)
			dmg.on_entity_event(event.entity)
		end
		--remove_alert(event)
	end
end, dmg.event_filter)

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

script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.on_dmg_filter)

-- detect vaults as they spawn in during mapgen
---@param surface LuaSurface
---@param area BoundingBox
local function init_chunk(surface, area)
	local vaults = surface.find_entities_filtered{name=const.VAULT_NAME, area=area}
	if next(vaults) then
		for _,e in pairs(vaults) do
			Vault.from_entity(e, "on_chunk_generated")
		end
	end
	--elseif const.TRY_SPAWN_MISSING_VAULTS then
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
	--common._dev_reset()
	init()
	
	-- TODO: could skip expensive checks by checking something like (last-get_resource_counts())>1000 first for whole planet?
	-- how? pause until condition met, then scan every chunk once, then pause again?
	
	common.stagger_tick(storage.poll_vaults, storage.vaults, const.ORE_POLL_PERIOD, function(vault)
		if vault.entity.valid then
			vault:update_waves()
		end
	end)
	
	dmg.on_tick(event)
	
	local update_alerts = event.tick % 30 == 0
	
	--for id,v in pairs(storage.vaults) do
	for id,v in pairs(storage.active_vaults) do
		if v.entity.valid then -- and v:wave_active()
			if update_alerts then
				v:update_alert()
			end
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
	if (selected and selected.name == const.VAULT_NAME) or (prev and prev.name == const.VAULT_NAME) then
		init()
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
