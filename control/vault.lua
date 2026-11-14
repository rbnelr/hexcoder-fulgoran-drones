local const = require("const")
local myutil = require("lib.myutil")
local dmg = require("control.disable_on_damage")
local ore = require("control.ore_tracking")

---@class Vault
---@field id obj_id
---@field entity LuaEntity
---@field near_wall LuaEntity?
---@field waypoints LuaEntity[]
---
---@field scrap_tracker OreTracker
---@field targets LuaEntity[] -- NOTE: entities can end up in two vaults target list!, TODO: is currently only used for bot movement, and not ideal for it, want a list of vaild target that changes
---@field has_drills boolean -- mining drills in radius, ore is only scanned while true. TODO: just cache the list of drills here instead? would help quality update performance
---
--- Waves
---@field cur_rng number? -- roll the same size/freq variations until wave actually starts, then reset
---@field cur_rng2 number?
---@field wave_timer_start MapTick -- vault init or last wave start (we can't default to 0 or first wave never starts), independent of active/prev_wave (wave infos may be nil)
---@field active_wave WaveInfo?
---@field prev_wave WaveInfo?
---
-- TODO: track sorted into buckets by tick or sort list?
-- Bots that are spawning or already active (wave may overlap, mixed from all waves)
---@field emerging_queued table<integer, Emerging> -- queued spawns
---@field emerging_projectiles table<integer, LuaEntity> -- emerging bots (projectiles that appear like bots that rise out of the vault)
---@field active_bots table<integer, LuaEntity> -- active bots
--- descending bots (projectiles) are currently not tracked and wave counts as inactive if only descending bots remain

---@class (exact) WaveInfo
---@field start_tick MapTick
---@field end_tick MapTick?
---@field size number?
---@field freq number?
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
		
		--targets={}, -- handled by update_targets()
		--has_drills=false,
		
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
	
	vault.near_wall = entity.surface.find_entity(const.VAULT_NEAR_WALL_NAME, entity.position)
	if vault.near_wall == nil then
		vault.near_wall = vault.entity.surface.create_entity{
			name = const.VAULT_NEAR_WALL_NAME, position = vault.entity.position,
			preserve_ghosts_and_corpses = true, -- ??
		}
		vault.near_wall.destructible = false
	end
	
	vault:update_targets() -- make sure to fix buildings
	
	-- scanned right away (depth for all vaults)
	vault.scrap_tracker = ore.OreTracker.new(entity.surface, entity.position, const.VAULT_DEFENSE_RADIUS, vault.has_drills, source_event)
	
	if const.DEBUG then
		--rendering.draw_rectangle{left_top=vault.bounding_box.left_top, right_bottom=vault.bounding_box.right_bottom,
		--	surface=vault.surface, filled=true, color={0,1,0}, time_to_live=60}
		game.print(const.PRINT_PREFIX.."init vault ".. serpent.line{entity})
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
	
	if self.near_wall and self.near_wall.valid then
		self.near_wall.destroy()
	end
	
	if self.entity and self.entity.valid then
		self.entity.destroy()
	end
	
	-- bots will die on their own, and are safe to orphan
	-- targets are not bound to vault, and can be forgotten as well
	
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
---@param size number?
---@param freq number?
---@param bot_quality_tier number? -- 0-(MAX_BOT_QUALITY-1)
function Vault:start_wave(size, freq, bot_quality_tier)
	-- end active wave if still active
	self:end_wave()
	
	-- TODO: update_targets here?
	
	-- mining rate is measured since the last wave start, no scan needed (mined is kept up to date by the poll scans)
	self.scrap_tracker:reset_mined()
	self.wave_timer_start = game.tick
	
	-- create new waypoints every attack, ends up more random (and previously handled radius changes)
	self:create_waypoints()
	
	local new_wave = self:_spawn_wave_bots(size, freq, bot_quality_tier)
	
	assert(self.active_wave == nil)
	self.active_wave = new_wave
	
	-- make vault active for bot updating
	storage.active_vaults[self.id] = self
	
	self:update_alert() -- needs self.active_wave
	
	return new_wave
end
-- offially end wave and optionally kill existing bots
-- does not make the vault inactive if bots are still active (if not on_tick does this)
-- clears prev_wave or makes active_wave the prev_wave
---@param force_inactive boolean? -- kill all bots
function Vault:end_wave(force_inactive)
	--self.next_bot_id = nil
	if self.active_wave then
		self.active_wave.end_tick = game.tick
		
		-- rng reset in update_waves
		
		if force_inactive then
			self:_kill_all_bots(false)
			assert(not self:bots_active())
			
			-- no longer needs to be updated
			storage.active_vaults[self.id] = nil
		end
	
		-- active wave (or nil) becomes previous wave
		-- never set prev_wave to nil so we can call end_wave() before start_wave
		self.prev_wave = self.active_wave
		self.active_wave = nil
		
		if not self:bots_active() then
			-- reduce entity count, waypoints only while wave active
			self:delete_waypoints()
			
			-- stop updating bots
			storage.active_vaults[self.id] = nil
		end
		
		-- do not reset active_vaults, since bots may still exist, wait for on_tick to clear it
		
		self:update_alert()
	end
end

-- create random invisible waypoints to act as drone movement targets
-- because drones cannot be instructed to move to arbitrary positions
function Vault:create_waypoints()
	self:delete_waypoints()
	
	local count = 30
	local R = const.VAULT_DEFENSE_RADIUS*0.8
	-- TODO: test if a random_in_circle_center_bias would be better
	
	self.waypoints = {}
	for i=1,count do
		local waypoint = self.entity.surface.create_entity{
			name=const.WAYPOINT,
			position = myutil.random_in_circle(self.entity.position, R),
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

---@param target LuaEntity
---@return Vault[] nearby_vaults
function find_nearby_vaults(target)
	assert(const.IS_TARGET[target.type])
	local nearby_vaults = {}
	for _,v in pairs(target.surface.find_entities_filtered{name=const.VAULT_NAME, position=target.position, radius=const.VAULT_DEFENSE_RADIUS}) do
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
function Vault:update_targets()
	-- build new list, no cleanup needed for old one
	self.targets = {}
	self.has_drills = false
	
	-- technically we scan for center of entity, not bounding box, which is probably fine
	-- but for drills that means it you can technically have drill that mines ore inside the radius, while itself being outside
	-- TODO: could handle this, (count it for has_drills, and potentially even making it a target) but this really shouldn't happen in gameplay
	local p = self.entity.position
	for _,e in pairs(self.entity.surface.find_entities_filtered{
						position=p, radius=const.VAULT_DEFENSE_RADIUS, type = const.TARGETS }) do
		--game.print(serpent.line(e))
		
		dmg.fix_building(e.unit_number, e)
		
		if not e.disabled_by_script then
			e.is_military_target = true
			self.targets[e.unit_number] = e
		end
		
		if e.type == "mining-drill" then
			self.has_drills = true
		end
	end
	
	dmg.fix_all_icons()
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
				string.format("%.0f", latest_wave.size*100 or -1),
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