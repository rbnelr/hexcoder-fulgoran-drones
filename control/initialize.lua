local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local depth_scaling = require("control.depth_scaling")
local dmg = require("control.disable_on_damage")
local ore = require("control.ore_tracking")
local original_mapgen = require("control.original_mapgen")
local dead_bots = require("control.dead_bots")

---@class obj_id : integer -- register_on_object_destroyed-based id

---@class ModStorage
---@field vaults table<obj_id, Vault> -- all registed vaults, should be all since init() and chunkgen register them as soon as they appear
---@field poll_vaults StaggerTickState -- stagger_tick state for vaults
---@field active_vaults table<obj_id, Vault> -- waves with active waves only
---
---@field update_drill_connections table<chunk_key, BoundingBox>
---
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---
---@field poll_decay PollDecay?
---
---@field render_objs table<player_index, LuaRenderObject[]>
---
---@field friend_end_tick integer?
---@field fake_surfaces FakeSurfaces? -- original_mapgen
---@field settings_changed boolean?
---@field highest_quality_unlocked integer -- 1-5
---
---@field startup_settings table<string, any> -- copy of our startup settings at the last init/on_configuration_changed, see get_startup_settings

-- mod lifecycle handlers (registered in control/events.lua), the global init() is defined here too
-- not named init because of the global function (file was init.lua)
local initialize = {}

-- copy of this mod's startup settings, to tell which of them changed in on_configuration_changed
-- (data.mod_startup_settings_changed is true for any mod's startup settings, and on install)
---@return table<string, any>
local function get_startup_settings()
	local copy = {}
	local prefix = const.MOD_NAME.."-"
	for name, setting in pairs(settings.startup) do
		if string.sub(name, 1, #prefix) == prefix then
			copy[name] = setting.value
		end
	end
	return copy
end

-- 'somewhat lazy' init ideally called in every handler, intentionally global
-- used during dev, but manually resetting via ctrl+alt on load makes this obsolete
-- TODO: remove init() calls everywhere?
---@param convert_scrap boolean? -- first init only: convert vault island scrap to the inf scrap setting and respawn missing vaults (slow, fake fulgora)
--                                  default true (on_init, lazy calls), false when only the mod version or vault radius changed (migrate)
function init(convert_scrap)
	local s = storage
	local init = next(s) == nil
	
	if s.vaults == nil then s.vaults = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.update_drill_connections == nil then s.update_drill_connections = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.render_objs == nil then s.render_objs = {} end
	if s.startup_settings == nil then s.startup_settings = get_startup_settings() end
	
	-- create enemy drone force
	if game.forces[const.DRONE_FORCE] == nil then
		local force = game.create_force(const.DRONE_FORCE)
		force.custom_color = {230,50,255} -- now tinting individually via actual graphic tints
		-- TODO: can give force robot livetime bonus
	end
	
	if init then
		if const.DEBUG then
			log(dbg_print("Doing mod init"))
		end
		
		local surface = game.get_surface("fulgora")
		if surface then
			if convert_scrap ~= false then
				-- respawn vaults, and convert vault scrap between finite<->infinite on existing chunks
				original_mapgen.convert_ore_and_restore_scrap_near_vaults(surface) -- freezes the game for a bit, warn user or make user trigger it manually?
			end

			for _,e in pairs(surface.find_entities_filtered{name=const.VAULT_NAME}) do
				get_or_init_vault(e, "init")
			end
			
			--if const.TRY_SPAWN_MISSING_VAULTS then
			--	for cpos in surface.get_chunks() do
			--		if surface.is_chunk_generated(cpos) then
			--			Vault.try_place_missing_vault_ruin(surface, {{cpos.x*32,cpos.y*32}, {cpos.x*32+32,cpos.y*32+32}})
			--		end
			--	end
			--end
			
			if const.HARVESTABLE_BOTS then
				dead_bots.split_existing_bot_resources(surface)
			end
		end
		
		dead_bots.update_unlocked_qualities()
		dead_bots.init_decay(surface)
		
		--dmg.fix_all_icons() -- TODO: slow and probably useless at release, used to happen in update_targets and was potentially very slow
	end
end

-- safely clear mod storage and reset all game state for dev purposes or deinstalling mod
-- manually delete our entities (hidden waypoints, drones) (not needed for uninstall, could be slow)
-- reset local_effect.quality on drills around mods (important since that would get stuck otherwise)
-- clear this mods LuaRendering and remove guis
-- delete drone force (would keep existing)
-- delete fake surface (would keep existing)
-- reset buildings disabled by drones, important or else disabled machines would get stuck
--   (reset disabled_by_script, is_military_target, custom_status message and disabled icon)
-- storage forgets about vaults, but they will be found and initialized again by init()
--  (and restored to identical state other than the active wave and rnd)
-- leaves the world as if the mod did not exist (also the uninstall), except the dead-<bot> wrecks (deleted with their prototypes on removal)
---@param convert_scrap boolean? -- infinite-scrap -> scrap (uninstall, inf scrap setting changed)
---@param reason string? -- logged, from describe_config_changes
local function reset(convert_scrap, reason)
	if const.DEBUG then
		log(dbg_print("Doing mod reset"..(reason and (": "..reason) or "")))
	end
	
	local surface = game.get_surface("fulgora")
	if surface then
		-- delete neutral entities
		for _,e in pairs(surface.find_entities_filtered{name=const.WAYPOINT}) do
			e.destroy()
		end
		-- delete left over hostile drones
		for _,e in pairs(surface.find_entities_filtered{force=const.DRONE_FORCE}) do
			e.destroy()
		end
		-- emerge/descend projectiles have the drone force too, so they are gone
		-- dying particles are not entities, one still in the air lands and creates a wreck if the handler is registered (harmless)

		depth_scaling.reset_all_drills_local_quality_effect(surface)

		-- buildings as if the mod did not exist: enabled again if we disabled them (not healed), prototype military state
		-- (fix_building only enabled stuck buildings that were already repaired), init() makes the ones around vaults military again
		-- icons go with rendering.clear below
		for _,e in pairs(surface.find_entities_filtered{type=const.TARGETS}) do
			dmg.restore_building(e.unit_number, e, nil, false)
		end

		if convert_scrap then
			-- same amount, so removing the mod (deletes infinite-scrap) keeps the scrap, init(true) converts it back
			original_mapgen.convert_scrap_in_place(surface, "scrap", "all")
			original_mapgen.update_autoplace_settings(surface, false) -- chunks generated from now on get scrap too
		end
	end
	
	rendering.clear(const.MOD_NAME)
	
	for _,player in pairs(game.players) do
		local existing = player.gui.left["hexcoder_fulgoran_drones_vault"]
		if existing then
			existing.destroy()
		end
		local pinned = player.gui.left["hexcoder_fulgoran_drones_vault_pinned"]
		if pinned then
			pinned.destroy()
		end
	end
	
	local drone_force = game.forces[const.DRONE_FORCE]
	if drone_force then
		-- can't delete forces directly (?), I guess this means that spawned bots now belong to the player until they timeout
		-- force still exists until next tick or so, may crash if calling init after this but not every tick!
		game.merge_forces(drone_force, game.forces["player"])
	end
	
	original_mapgen.delete_all_fake_surfaces()

	--
	storage = {}
end

-- what a mod update or an important startup setting change needs, no real migrations yet
---@param convert_scrap boolean -- only when the scrap type changes, skips the slow fake fulgora otherwise
---@param reason string? -- logged
local function migrate(convert_scrap, reason)
	reset(convert_scrap, reason)
	init(convert_scrap)
end


script.register_metatable("Vault", Vault)
script.register_metatable("OreTracker", ore.OreTracker)

-- ctrl+alt+click when loading to trigger on_configuration_changed without version change, but mod_changes will be empty!
local DO_DEV_RESET = true
---@param data ConfigurationChangedData
function initialize.on_configuration_changed(data)
	if common.UNINSTALL then return end -- paused, reset() already ran, init() runs when unticked

	-- changes -> mod version changed (including install on running game, has old_version==nil)
	-- mod_startup_settings_changed -> startup settings (of any mod!) have changed (or install on running game), so compare our own copy instead
	local mod_change = data.mod_changes[const.MOD_NAME]
	
	local old_settings = storage.startup_settings or {} -- nil: save from before startup_settings existed, everything counts as changed
	local new_settings = get_startup_settings()
	storage.startup_settings = new_settings
	
	local changed_settings = {} ---@type table<string, true>
	for name, value in pairs(new_settings) do
		if old_settings[name] ~= value then changed_settings[name] = true end -- all ours are bool/number, no table compare needed
	end
	-- only these need the reset, the rest only affects the data stage (or the game removes prototypes itself), debug is covered by dev_reset
	local inf_scrap_changed = changed_settings[const.MOD_NAME.."-inf-scrap"] or false -- converts the ore finite<->infinite
	local important_setting_changed = inf_scrap_changed or
		changed_settings[const.MOD_NAME.."-vault-defense-radius"] -- trackers were scanned with the old radius
	-- could potentially despawn bot resource at higher quality when no quality is wanted, but not worth it
	
	-- dev reset calls on_configuration_changed even with no changes,
	-- unfortunately this also triggers on any third party mod changes
	local dev_reset = DO_DEV_RESET and const.DEBUG
	
	if mod_change or important_setting_changed or dev_reset then
		-- only logged when we act on it (in reset), third party mod changes alone are not interesting
		data.migrations = nil -- one empty table per prototype type, just noise
		data["_dev_reset"] = dev_reset -- include in print
		data["_changed_settings"] = changed_settings
		local reason = serpent.line(data)

		-- installing on existing save does on_init then on_configuration_changed (with mod_startup_settings_changed=true!)
		-- do not reset+init again!
		if mod_change and mod_change.old_version == nil then return end

		-- reset + init, kinda works, but may be arkward
		-- scrap only converted when the inf scrap setting changed (also for saves without startup_settings: everything counts as changed)
		migrate(inf_scrap_changed, reason)
		return
	end
end

function initialize.on_init()
	if common.UNINSTALL then return end -- new game or late install with the checkbox on: stay uninitialized until unticked
	init()
end

-- ticking "Prepare for uninstall" runs reset(), unticking init(), control/events.lua then unregisters/registers the other handlers
---@param event EventData.on_runtime_mod_setting_changed
function initialize.on_runtime_mod_setting_changed(event)
	if event.setting == common.UNINSTALL_SETTING_NAME then
		common.UNINSTALL = settings.global[common.UNINSTALL_SETTING_NAME].value --[[@as boolean]]
		if common.UNINSTALL then
			reset(true, "uninstall")
			
			log(dbg_print("Prepared for uninstall: Killed waves, restored buildings, drill quality removed, infinite scrap converted to normal scrap."))
			log(dbg_print("Save the game now, then remove the mod.", true))
		else
			common.update_runtime_settings({name="_mod_load", setting_type="runtime-global"}) -- re-cache once resumed
			
			init(true)
			
			log(dbg_print("Resuming after prepare for uninstall.", true))
		end
	elseif not common.UNINSTALL then -- prepared for uninstall: storage stays empty (settings_changed hack), init() needs that for the first init
		common.update_runtime_settings(event)
	end
end

return initialize
