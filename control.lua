local const = require("const")
local common = require("control.common")
local dmg = require("disable_on_damage")
local Vault = require("vault")
local ore = require("ore_tracking")
local recreate_fulgora = require("recreate_fulgora")
require("spawning")
local dead_bots = require("dead_bots")
local movement = require("bot_movement")
local gui = require("gui")

---- Init

-- 'somewhat lazy' init ideally called in every handler
function init()

	-- create enemy drone force
	if game.forces[const.DRONE_FORCE] == nil then
		local force = game.create_force(const.DRONE_FORCE)
		force.custom_color = {230,50,255} -- now tinting individually via actual graphic tints
		-- TODO: can give force robot livetime bonus
	end
	
	local s = storage
	local init = next(s) == nil
	
	if s.vaults == nil then s.vaults = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.render_objs == nil then s.render_objs = {} end
	if s.finite_initial == nil then s.finite_initial = {} end
	
	if init then
		local surface = game.get_surface("fulgora")
		if surface then
			-- respawn vaults, vault scrap to inf scrap setting
			recreate_fulgora.convert_ore_and_restore_vaults(surface) -- freezes the game for a bit, warn user or make user trigger it manually?
			
			for _,e in pairs(surface.find_entities_filtered{name=const.VAULT_NAME}) do
				Vault.from_entity(e)
			end
			
			--if const.TRY_SPAWN_MISSING_VAULTS then
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
		-- delete neutral entities
		for _,e in pairs(surface.find_entities_filtered{name={const.VAULT_NEAR_WALL_NAME,const.WAYPOINT}}) do
			e.destroy()
		end
		-- delete left over hostile drones
		for _,e in pairs(surface.find_entities_filtered{force=const.DRONE_FORCE}) do
			e.destroy()
		end
	end
	
	rendering.clear(const.MOD_NAME)
	
	for _,player in pairs(game.players) do
		local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
		if existing then
			existing.destroy()
		end
	end
	
	local drone_force = game.forces[const.DRONE_FORCE]
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

local HARVEST_BOTS = settings.startup[const.MOD_NAME.."-dead-bot-resource"].value

if HARVEST_BOTS then
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

---- Commands

if const.DEBUG then
	-- /c local s = game.player.surface; s.clear();
	-- /c local s = game.player.surface; s.request_to_generate_chunks({0, 0}, 20); s.force_generate_chunk_requests(); game.player.force.chart_all(s)
	
	-- TEMPORARY (disabled, recreate_fulgora.debug_convert_all was removed): compare whole map conversion variants, use a test save
	-- converts away from the setting and back, so the map ends up as before (finite tiles below the inf minimum stay raised)
	-- "full": fake fulgora for all chunks instead of only vault islands, to compare counts and time
	--commands.add_command("fulg-bench-convert", "[single|single-find-entity|single-lookup|chunks] [full] (default: all, vault island chunks only)", function(command)
		--init()
		--local player = game.get_player(command.player_index) ---@cast player -nil
		--local surface = game.get_surface("fulgora")
		--if not surface then
			--player.print("no fulgora")
			--return
		--end

		--local variants, all_chunks = {}, false
		--for arg in string.gmatch(command.parameter or "", "%S+") do
			--if arg == "full" then all_chunks = true else variants[#variants+1] = arg end
		--end
		--if #variants == 0 then variants = {"single", "single-find-entity", "single-lookup", "chunks"} end

		---- fresh fake surface for a fair time, deletion is queued until the end of the tick
		--if game.surfaces["hexcoder_fake_fulgora"] then
			--recreate_fulgora.delete_fake_fulgora()
			--player.print("deleted existing fake fulgora, run the command again")
			--return
		--end

		--local prof_fake = helpers.create_profiler()
		--local fake_surface, requested = recreate_fulgora.recreate_initial_surface_and_load_chunks(surface, "all", nil, all_chunks)
		--prof_fake.stop()
		--local msg_fake = {"", string.format("fake fulgora (%s, %d chunks) ", all_chunks and "full" or "vault islands", requested or 0), prof_fake}
		--player.print(msg_fake)
		--log(msg_fake)

		--local current = const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap"
		--local other = const.INF_SCRAP_ENABLED and "scrap" or "vault-scrap"
		--for _,variant in ipairs(variants) do
			--local c1, p1 = recreate_fulgora.debug_convert_all(surface, fake_surface, variant, other)
			--local c2, p2 = recreate_fulgora.debug_convert_all(surface, fake_surface, variant, current)
			--local msg = {"", string.format("%s: to %s %d ", variant, other, c1), p1, string.format("  back to %s %d ", current, c2), p2}
			--player.print(msg)
			--log(msg)
		--end
	--end)

	commands.add_command("fulg-attack", "", function(command)
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 1
		
		-- vault for testing
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			local vault = Vault.from_entity(sel)
			vault:stop_wave_and_kill_bots(true)
			vault:spawn_wave(size, 1, true)
		end
	end)
	commands.add_command("fulg-kill-wave", "", function(command)
		init()
		
		local size = command.parameter and tonumber(command.parameter) or 1
		
		-- vault for testing
		local sel = game.get_player(command.player_index).selected
		if sel and sel.valid and sel.name == const.VAULT_NAME then
			Vault.from_entity(sel):stop_wave_and_kill_bots(true)
		end
	end)
	
	--commands.add_command("fulg-spawn-bot-res", "", function(command)
	--	init()
	--	
	--	local args = command.parameter and string.gmatch(command.parameter, "[^%s]+")
	--	local type = args and args() or "destroyer"
	--	local countstr = args and args()
	--	local count = countstr and tonumber(countstr) or 1
	--	
	--	-- vault for testing
	--	local player = game.get_player(command.player_index) ---@cast player -nil
	--	
	--	local res_name = const.DRONE_RESOURCE["fulgoran-"..type]
	--	dead_bots.add_dead_bot_resource(player.surface, player.position, res_name, count)
	--end)
end

commands.add_command("fulg-restore-ore",
		"<percent>\nrestore the scrap around the hovered vault ruin to a percentage of its original amount (>= 0, may be > 100; infinite scrap clamps to its minimum, finite to 1)\nalso recreates fully mined tiles",
		function(command)
	init()

	local player = game.get_player(command.player_index) ---@cast player -nil

	local percent = tonumber(command.parameter or "")
	if not percent or percent < 0 then
		player.print(const.PRINT_PREFIX.."please pass a percentage >= 0")
		return
	end

	local sel = player.selected
	if sel and sel.valid and sel.name == const.VAULT_NAME then
		ore.restore_ore(Vault.from_entity(sel), percent / 100)
		player.print(const.PRINT_PREFIX.."ore restored")
	else
		player.print(const.PRINT_PREFIX.."need to hover a vault!")
	end
end)

---- Init

script.register_metatable("Vault", Vault)
script.register_metatable("OreTracking", ore.OreTracking)

---@class obj_id : integer -- register_on_object_destroyed-based id
---@class unit_number : integer
---@class player_index : integer
---@class tile_key : integer

---@class ModStorage
---@field vaults table<obj_id, Vault>
---@field friend_end_tick integer?
---@field poll_vaults table
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---@field active_vaults table<obj_id, Vault>
---@field render_objs table<player_index, LuaRenderObject[]?>
---@field last_used_fake_fulgora MapTick?
---@field finite_initial table<tile_key, integer> -- initial amount for finite scrap tiles around vaults (kept after mined out), see OreTracking

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

script.on_init(init)
-- ctrl+alt+click when loading to trigger on_configuration_changed without version change, but mod_changes will be empty!
local DEV_REINIT_EACH_LOAD = true
script.on_configuration_changed(function(data)
	local setting_changed = data.mod_startup_settings_changed
	local changes = data.mod_changes[const.MOD_NAME]
	local dev_reset = const.DEBUG and DEV_REINIT_EACH_LOAD
	if changes or setting_changed or dev_reset then
		if dev_reset then -- dev reset
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
		return
	end
	-- setting_changed: inf scrap toggle handled by reset + init (recreate_fulgora.convert_ore_and_restore_vaults)
	-- vault-scrap prototype is always defined (hidden when off), so it is not deleted
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	-- TODO: anything to handler here?
end)
