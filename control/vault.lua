local const = require("const")
local myutil = require("lib.myutil")
local dmg = require("control.disable_on_damage")
local ore = require("control.ore_tracking")
-- spawning and depth_scaling must not require this file (require cycle)
local spawning = require("control.spawning")
local depth_scaling = require("control.depth_scaling")

---@class Vault
---@field id obj_id
---@field entity LuaEntity
---@field waypoints LuaEntity[]
---
---@field scrap_tracker OreTracker
-- target lists are rebuilt by update_targets (every poll and targets add themselves on build), entries can turn invalid before next rebuild, entities can be in two vaults' lists
---@field targets table<unit_number, LuaEntity> -- all target buildings in radius, incl. disabled ones
---@field targets_remaining table<unit_number, LuaEntity> -- targets without the disabled ones, for bot movement
---@field mining_drills table<unit_number, LuaEntity> -- drills in radius, ore is only scanned while there are any
---
--- Waves
---@field cur_rng number? -- roll the same size/freq variations until wave actually starts, then reset
---@field cur_rng2 number?
---@field testing boolean? -- set by /vaults-test wave: no automatic waves, waves (counts, durations, size/freq, drone lifetime) without random variation
---@field wave_timer_start MapTick -- vault init or last wave start (we can't default to 0 or first wave never starts), independent of active/prev_wave (wave infos may be nil)
---@field active_wave WaveInfo?
---@field prev_wave WaveInfo?
---
-- TODO: track sorted into buckets by tick or sort list?
-- Bots that are spawning or already active (wave may overlap, mixed from all waves)
---@field emerging_queued Emerging[] -- queued spawns (sorted in reverse order)
---@field emerging_projectiles table<integer, LuaEntity> -- emerging bots (projectiles that appear like bots that rise out of the vault)
---@field active_bots table<integer, LuaEntity> -- active bots
--- descending bots (projectiles) are currently not tracked and wave counts as inactive if only descending bots remain

---@class (exact) WaveInfo
---@field start_tick MapTick
---@field end_tick MapTick?
---@field size number?
---@field freq number?
---@field threat number?
---@field bot_quality_tier number? -- 0-(MAX_BOT_QUALITY-1)
---@field bot_types table<string, integer>
---@field bot_qualities table<string, integer>

---@class (exact) Emerging
--@field id integer
---@field tick integer -- spawn projectile on future tick
---@field name string -- emerging projectile name
---@field quality string
---@field final_pos MapPosition -- position once reached the top

---@class Vault
local Vault = {}
Vault.__index = Vault

---@param entity LuaEntity
---@return Vault?
---@return obj_id on_object_destroyed_id
function get_vault(entity)
	assert(entity and entity.valid and entity.name == const.VAULT_NAME)
	
	-- simple entity has no unit_number! use register on_object_destroyed id
	local id = script.register_on_object_destroyed(entity)
	local vault = storage.vaults[id]
	return vault, id
end

-- global because lua makes circular ref hard, files we require here can't this file
---@param entity LuaEntity
---@param source_event? string -- if not on_chunk_generated, may have been mined before
---@return Vault
function get_or_init_vault(entity, source_event)
	assert(entity.name == const.VAULT_NAME)
	
	local vault, id = get_vault(entity)
	if vault then return vault end
	
	local vault = setmetatable({
		id = id,
		entity = entity,
		waypoints={},
		
		--scrap_tracker, after update_targets() (needs has_drills)
		
		wave_timer_start = game.tick, -- first wave counts from vault init
		
		--targets={}, targets_remaining={}, mining_drills={}, -- handled by update_targets()
		
		emerging_queued={},
		emerging_projectiles={},
		active_bots={},
	}, Vault)
	storage.vaults[id] = vault
	
	-- vault (simple-entity) can't actually have a force?
	--entity.force = const.DRONE_FORCE
	-- enemy structures cannot be mined, but decoratives like ruins can
	entity.destructible = false -- can't damage
	
	-- snap to grid (but manually because engine assumes everything is odd number of tiles????)
	-- so we can comfortably build around it and are guaranteed to get full covereage with big mining drills
	-- (13x13 coverage gives 4 past drill edge, and vault is now exactly 14x8)
	local pos = entity.position
	pos.x = math.floor(pos.x+0.5) -- even width, center on integer (odd would be: math.floor(pos.x)+0.5)
	pos.y = math.floor(pos.y+0.5) -- even height, center on integer
	if pos.x ~= entity.position.x or pos.y ~= entity.position.y then
		entity.teleport(pos,
			nil, -- same surface
			true, -- raise_teleported
			false) -- snap_to_grid
	end
	
	vault:update_targets() -- make sure to fix buildings
	
	-- scanned right away (depth for all vaults)
	vault.scrap_tracker = ore.OreTracker.new(vault, source_event)
	
	if const.DEBUG then
		--rendering.draw_rectangle{left_top=vault.bounding_box.left_top, right_bottom=vault.bounding_box.right_bottom,
		--	surface=vault.surface, filled=true, color={0,1,0}, time_to_live=60}
		local p = entity.position
		log(dbg_print(string.format("Registered vault ruin at [gps=%d,%d,%s] (from %s)", math.floor(p.x), math.floor(p.y), entity.surface.name, source_event or "lazy")))
	end
	
	return vault
end

-- currently only get called by on_object_destroyed
-- so either from editor or script vault entity destroy, or if surface is destroyed
-- we don't need to bother to end_wave or destroy bots as long as either are safe
function Vault:on_destroyed()
	--self:end_wave() -- deletes waypoints too
	
	self:delete_waypoints()
	
	self:update_alert()

	if self.entity and self.entity.valid then
		self.entity.destroy()
	end
	
	-- bots will die on their own, and are safe to orphan
	-- targets are not bound to vault, and can be forgotten as well
	
	-- TODO: reset target military state?
	
	storage.vaults[self.id] = nil
	storage.active_vaults[self.id] = nil
end

---@return boolean
function Vault:bots_active()
	-- ignoring decending projectiles for now
	return self.entity.valid and (next(self.active_bots) or next(self.emerging_queued) or next(self.emerging_projectiles)) and true or false
end
-- offially start wave and spawn it with given parameters
-- either called automatically by update_waves or forced by console command
-- nil parameters default to what update_waves would do now (size/freq from should_spawn_wave with the current rng, depth from the tracker, quality tier from depth)
---@param size number? -- multiplier on the depth bot counts
---@param freq number?
---@param bot_quality_tier number? -- 0-(MAX_BOT_QUALITY-1)
---@param depth number? -- 0-1, for bot counts and default quality tier
---@return WaveInfo
function Vault:start_wave(size, freq, bot_quality_tier, depth)
	-- end active wave if still active
	self:end_wave()

	-- TODO: update_targets here?

	if depth == nil then
		local _
		_, depth = self:find_current_mining_rate_and_depth()
	end
	if size == nil or freq == nil then
		local _, def_size, def_freq = spawning.should_spawn_wave(self, false) -- uses the real depth, not an overridden one
		size = size or def_size
		freq = freq or def_freq
	end
	bot_quality_tier = bot_quality_tier or depth_scaling.bot_tier(depth)
	
	-- mining rate is measured since the last wave start, scans if needed (not again this tick)
	local e = self.entity
	self.scrap_tracker:reset_mined(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, self:has_drills())
	self.wave_timer_start = game.tick

	-- every wave gets new random variation for time and size
	self.cur_rng = nil
	self.cur_rng2 = nil

	-- create new waypoints every attack, ends up more random (and previously handled radius changes)
	self:create_waypoints()

	local new_wave = spawning.spawn_wave_bots(self, size, freq, bot_quality_tier, depth)
	
	assert(self.active_wave == nil)
	self.active_wave = new_wave
	
	-- make vault active for bot updating
	storage.active_vaults[self.id] = self
	
	self:update_alert() -- needs self.active_wave
	
	return new_wave
end
-- poll (staggered on_tick in events.lua): targets, ore scan, drill quality, and start the automatic wave when due
function Vault:update_waves()
	self:update_targets()
	
	-- allow waves to overlap
	-- so current or prev wave counts start_tick is counted for mining rate
	-- if mining rate high enough or settings aggressive enough and bots still active waves will overlap
	-- existing bots will remain and eventually die or return while new ones emerge
	-- new wave start will counts as new wave for gui and for should_spawn_wave logic
	--if self:bots_active() then return end
	
	-- scan every poll while mining is possible (drills now or at the last scan, see OreTracker:scan_if_needed), keeps depth current for drill quality
	-- without drills no scans, rare min size waves still happen
	-- TODO: player could be near and mine by hand but well, probably does not matter
	self:find_current_mining_rate_and_depth()
	
	if self:has_drills() then
		depth_scaling.update_quality_for_vault_drills(self) -- drill quality from depth
	end
	
	if self.testing then return end -- the test starts its waves itself

	local trigger_wave, size, freq = spawning.should_spawn_wave(self, true)
	if trigger_wave then
		-- depth and quality tier default to the current depth
		self:start_wave(size, freq)
	end
end

-- offially end wave and optionally kill existing bots
-- does not make the vault inactive if bots are still active (if not on_tick does this)
-- clears prev_wave or makes active_wave the prev_wave
---@param kill_bots boolean?
---@param repair_buildings boolean? -- heal all targets in radius to full HP and enable the ones drones disabled (for testing)
function Vault:end_wave(kill_bots, repair_buildings)
	if self.active_wave then
		self.active_wave.end_tick = game.tick
		
		-- rng reset in start_wave
	
		-- active_wave becomes prev_wave
		-- never set prev_wave to nil
		self.prev_wave = self.active_wave
		self.active_wave = nil
	end
	
	if kill_bots then
		spawning.kill_all_bots(self, false)
		assert(not self:bots_active())
	end
	
	if repair_buildings then
		-- targets are refreshed every poll and on build, entries can be invalid
		for id,b in pairs(self.targets) do
			if b.valid then
				dmg.repair_and_restore_building(id, b)
			end
		end
	end

	if not self:bots_active() then
		-- reduce entity count, waypoints only while wave active
		self:delete_waypoints()
		
		-- stop updating bots
		storage.active_vaults[self.id] = nil
	end
	
	self:update_alert()
end

-- create random invisible waypoints to act as drone movement targets
-- because drones cannot be instructed to move to arbitrary positions
function Vault:create_waypoints()
	self:delete_waypoints()
	
	local count = 42 -- 30
	local R = const.VAULT_DEFENSE_RADIUS*0.8
	local minR = const.VAULT_SHAFT_RADIUS + 4
	
	self.waypoints = {}
	for i=1,count do
		local waypoint = self.entity.surface.create_entity{
			name=const.WAYPOINT,
			position = myutil.random_in_circle_center_bias(self.entity.position, R, minR), -- random_in_circle
			preserve_ghosts_and_corpses = true, -- ??
		}
		waypoint.destructible = false
		
		table.insert(self.waypoints, waypoint)
	end
end
function Vault:delete_waypoints()
	if self.waypoints then
		for id,e in pairs(self.waypoints) do
			e.destroy()
		end
		self.waypoints = {}
	end
end

---@param surface LuaSurface
---@param position MapPosition
---@return Vault[] nearby_vaults
function find_nearby_vaults(surface, position)
	local nearby_vaults = {}
	for _,v in pairs(surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=const.VAULT_DEFENSE_RADIUS}) do
		local vault = get_or_init_vault(v)
		table.insert(nearby_vaults, vault)
	end

	return nearby_vaults
end

---@return Vault[]
function Vault:find_this_and_overlapping_vaults()
	local e = self.entity
	local overlapping = {}
	-- anything in 2x the radius can overlap
	for _,ve in pairs(e.surface.find_entities_filtered{name=const.VAULT_NAME, position=e.position, radius=const.VAULT_DEFENSE_RADIUS*2}) do
		local vault = get_or_init_vault(ve)
		table.insert(overlapping, vault)
	end
	return overlapping
end

---@return boolean
function Vault:has_targets()
	return next(self.targets) ~= nil
end
---@return boolean
function Vault:has_drills()
	return next(self.mining_drills) ~= nil
end

-- OreTracker:find_current_mining_rate_and_depth with this vault's position, radius and drills (scans if needed)
---@return number mining_rate -- per minute
---@return number depth -- 0-1
function Vault:find_current_mining_rate_and_depth()
	local e = self.entity
	return self.scrap_tracker:find_current_mining_rate_and_depth(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, self:has_drills())
end

function Vault:update_targets()
	-- build new lists, no cleanup needed for old ones
	self.targets = {}
	self.targets_remaining = {}
	self.mining_drills = {}

	-- technically we scan for center of entity, not bounding box, which is probably fine
	-- but for drills that means it you can technically have drill that mines ore inside the radius, while itself being outside
	-- TODO: could handle this, (count it in mining_drills, and potentially even making it a target) but this really shouldn't happen in gameplay
	for _,entity in pairs(self.entity.surface.find_entities_filtered{
			position=self.entity.position, radius=const.VAULT_DEFENSE_RADIUS, type=const.TARGETS }) do
		--game.print(serpent.line(e))
		local id = entity.unit_number ---@cast id -nil

		dmg.fix_building(id, entity)

		self.targets[id] = entity
		
		if not entity.disabled_by_script then
			entity.is_military_target = true
			self.targets_remaining[id] = entity
		end

		if entity.type == "mining-drill" then
			self.mining_drills[id] = entity
		end
	end
end

-- do alerts not stay until deleted?
-- if so need to refresh via this
function Vault:update_alert()
	local bots_active = self:bots_active()
	
	local force = game.forces["player"]
	--local radar_visible = force.is_chunk_visible(self.entity.surface, { self.entity.position.x / 32, self.entity.position.y / 32 })
	local built_nearby = self:has_targets()
	
	-- radar_visible or built_nearby ?
	if bots_active and (built_nearby or const.DEBUG) then -- radar_visible and   or const.DEBUG
		-- 2.1 only
		-- since alerts disappear after a time, we need to refresh them
		-- wave can be force-ended while bots are still active, so displaying latest wave should work
		-- displaying prev_wave is correct if there is no active_wave
		-- TODO: display number of remaining bots too?
		local latest_wave = self.active_wave or self.prev_wave
		if latest_wave then
			force.add_custom_alert(self.entity,
				{type="entity", name=const.VAULT_NAME},
				{"alert.active-attack",
				string.format("%.0f", latest_wave.threat or -1),
				--string.format("%.0f", latest_wave.size or -1),
				-- string.format("%.2f", latest_wave.freq or -1)
				}, true)
		end
	else
		if self.entity.valid then
			game.forces["player"].remove_alert{entity=self.entity}
		end
	end
end

return Vault