local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
require("control.spawning") -- adds functions to Vault
local depth_scaling = require("control.depth_scaling") -- adds functions to Vault
local dmg = require("control.disable_on_damage")
local ore = require("control.ore_tracking")
local recreate_fulgora = require("control.recreate_fulgora")

-- 'somewhat lazy' init ideally called in every handler, intentionally global
-- used during dev, but new DEV_REINIT_EACH_LOAD makes this obsolete
-- TODO: remove init() calls everywhere?
function init()
	local s = storage
	local init = next(s) == nil
	
	if s.vaults == nil then s.vaults = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.render_objs == nil then s.render_objs = {} end
	if s.finite_initial == nil then s.finite_initial = {} end
	
	-- create enemy drone force
	if game.forces[const.DRONE_FORCE] == nil then
		local force = game.create_force(const.DRONE_FORCE)
		force.custom_color = {230,50,255} -- now tinting individually via actual graphic tints
		-- TODO: can give force robot livetime bonus
	end
	
	if init then
		local surface = game.get_surface("fulgora")
		if surface then
			-- respawn vaults, vault scrap to inf scrap setting
			recreate_fulgora.convert_ore_and_restore_vaults(surface) -- freezes the game for a bit, warn user or make user trigger it manually?
			
			for _,e in pairs(surface.find_entities_filtered{name=const.VAULT_NAME}) do
				vault_from_entity(e)
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
		
		depth_scaling.reset_all_drills_local_quality_effect(surface)
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


script.register_metatable("Vault", Vault)
script.register_metatable("OreTracking", ore.OreTracking)

---@class obj_id : integer -- register_on_object_destroyed-based id
---@class unit_number : integer
---@class player_index : integer
---@class tile_key : integer

---@class ModStorage
---@field vaults table<obj_id, Vault> -- all registed vaults, should be all since init() and chunkgen register them as soon as they appear
---@field poll_vaults StaggerTickState -- stagger_tick state for vaults
---@field active_vaults table<obj_id, Vault> -- waves with active waves only
---
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---@field friend_end_tick integer?
---
---@field render_objs table<player_index, LuaRenderObject[]?>
---
---@field last_used_fake_fulgora MapTick?
---@field finite_initial table<tile_key, integer> -- initial amount for finite scrap tiles around vaults (kept after mined out), see OreTracking

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

script.on_init(init)
-- ctrl+alt+click when loading to trigger on_configuration_changed without version change, but mod_changes will be empty!
script.on_configuration_changed(function(data)
	local setting_changed = data.mod_startup_settings_changed
	local changes = data.mod_changes[const.MOD_NAME]
	local dev_reset = const.DEBUG
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

script.on_event(defines.events.on_runtime_mod_setting_changed, common.update_runtime_settings)
