local const = require("const")
local common = require("control.common")
local dmg = require("control.disable_on_damage")
local ore = require("control.ore_tracking")

---@class Vault
---@field entity LuaEntity
---@field id obj_id
---@field near_wall LuaEntity?
---@field dirty_ores boolean -- tiles may have been mined before tracking started (existing save, restored vault), see get_or_init_scrap
---@field scrap OreTracking? -- created on demand, see get_or_init_scrap
---@field targets LuaEntity[] -- NOTE: entities can end up in two vaults target list!, TODO: is currently only used for bot movement, and not ideal for it, want a list of vaild target that changes
---@field has_targets boolean -- has any targets (=vulnerable player entities)
---@field waypoints LuaEntity[]
---@field wave_rng number?
---@field wave_rng2 number?
---@field wave_size number?
---@field wave_freq number?
---@field wave_start_tick MapTick
---@field wave_end_tick MapTick
---@field wave_bots_count table<string, integer>
-- TODO: track sorted into buckets by tick or sort list?
---@field wave_emerging_queued table<integer, Emerging> -- current attack wave emerging bots (not yet spawned anything)
---@field wave_emerging_projectiles table<integer, LuaEntity> -- current attack wave emerging bots (projectiles that appear like bots that rise out of the vault)
---@field active_wave_bots table<integer, LuaEntity> -- current attack wave active bots
--@field next_bot_id integer?

---@class (exact) Emerging
--@field id integer
---@field tick integer -- spawn projectile on future tick
---@field name string -- emerging projectile name
---@field final_pos MapPosition -- position once reached the top

---@class Vault
local Vault = {}
Vault.__index = Vault

---@param vault LuaEntity
---@param source_event? string
---@return Vault
function Vault.from_entity(vault, source_event)
	assert(vault.name == const.VAULT_NAME)
	
	-- simple entity has no unit_number!
	--local id = vault.unit_number ---@cast id -nil
	-- workaround, register on_object_destroyed
	local id = script.register_on_object_destroyed(vault)
	local v = storage.vaults[id]
	if v then return v end
	
	local tick = game.tick
	
	local v = setmetatable({
		entity = vault,
		id = id,
		targets={},
		wave_start_tick = tick,
		wave_end_tick = tick,
		waypoints={},
		wave_bots={},
		wave_emerging_queued={},
		wave_emerging_projectiles={},
		active_wave_bots={},
		wave_bots_count={},
	}, Vault)
	storage.vaults[id] = v
	
	-- enemy structures cannot be mined, but decoratives like ruins can
	vault.force = const.DRONE_FORCE -- vault (simple-entity) can't actually have a force?
	vault.destructible = false -- can't damage
	
	-- snap to grid (but manually because engine assumes everything is odd number of tiles????)
	-- so we can comfortably build around it and are guaranteed to get full covereage with big mining drills
	-- (13x13 coverage gives 4 past drill edge, and vault is now exactly 14x8)
	local pos = vault.position
	pos.x = math.floor(pos.x+0.5) -- even width, center on integer (odd would be: math.floor(pos.x)+0.5)
	pos.y = math.floor(pos.y+0.5) -- even height, center on integer
	vault.teleport(pos,
		nil, -- same surface
		true, -- raise_teleported
		false) -- snap_to_grid
	
	v.near_wall = vault.surface.find_entity(const.VAULT_NEAR_WALL_NAME, vault.position)
	if v.near_wall == nil then
		v.near_wall = v.entity.surface.create_entity{
			name = const.VAULT_NEAR_WALL_NAME, position = v.entity.position,
			preserve_ghosts_and_corpses = true, -- ??
		}
	end
	v.near_wall.destructible = false
	
	-- ore tracking is created on demand (get_or_init_scrap), vaults nobody builds near or looks at never need it
	-- new chunk: nothing mined yet, so no fake fulgora needed for finite initial amounts
	v.dirty_ores = source_event ~= "on_chunk_generated"
	
	v:prepare() -- make sure to fix buildings
	
	if const.DEBUG then
		--rendering.draw_rectangle{left_top=vault.bounding_box.left_top, right_bottom=vault.bounding_box.right_bottom,
		--	surface=vault.surface, filled=true, color={0,1,0}, time_to_live=60}
		game.print(const.PRINT_PREFIX.."init vault ".. serpent.line{vault})
	end
	
	return v
end

function Vault:destroy()
	self:end_wave() -- deletes waypoints too
	
	if self.near_wall and self.near_wall.valid then
		self.near_wall.destroy()
	end
	
	if self.entity and self.entity.valid then
		self.entity.destroy()
	end
	
	-- bots will die on their own, and are safe to orphan
	-- targets are not bound to vault, and can be forgotten as well
	
	storage.vaults[self.id] = nil
end

-- ore tracking on demand: update_waves only scans with player buildings in range, gui forces it
-- update_initial needs fake fulgora (slow), only done once here, and naturally staggered by the vault polling
---@return OreTracking
function Vault:get_or_init_scrap()
	if self.scrap == nil then
		local e = self.entity
		self.scrap = ore.OreTracking.new(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, self.dirty_ores)
	end
	return self.scrap
end

---@return OreScan
function Vault:scan_ore()
	local e = self.entity
	return self:get_or_init_scrap():scan(e.surface, e.position, const.VAULT_DEFENSE_RADIUS)
end

-- create random invisible waypoints to act as drone movement targets
-- because drones cannot be instructed to move to arbitrary positions
function Vault:delete_waypoints()
	if self.waypoints then
		for id,e in pairs(self.waypoints) do
			e.destroy()
		end
		self.waypoints = {}
	end
end
function Vault:make_waypoints()
	self:delete_waypoints()
	
	local count = 30
	local R = const.VAULT_DEFENSE_RADIUS*0.8
	
	self.waypoints = {}
	for i=1,count do
		local waypoint = self.entity.surface.create_entity{
			name=const.WAYPOINT,
			position = common.random_in_circle(self.entity.position, R),
			preserve_ghosts_and_corpses = true, -- ??
		}
		waypoint.destructible = false
		
		table.insert(self.waypoints, waypoint)
	end
end

function Vault:wave_active()
	-- ignoring decending projectiles for now
	return (next(self.active_wave_bots) or next(self.wave_emerging_queued) or next(self.wave_emerging_projectiles)) ~= nil
end

function Vault:prepare()
	-- build new list, no cleanup needed for old one
	self.targets = {}
	self.has_targets = false
	
	local R = const.VAULT_DEFENSE_RADIUS
	local p = self.entity.position
	for _,e in pairs(self.entity.surface.find_entities_filtered{
						position=p, radius=R, type = const.TARGETS }) do
		--game.print(serpent.line(e))
		
		if common.check_distance(e.position, p, R) then -- TODO: distance check is not actually needed? since radius is circular?
			dmg.fix_building(e.unit_number, e)
			
			if not e.disabled_by_script then
				e.is_military_target = true
				self.targets[e.unit_number] = e
			end
			
			self.has_targets = true
		end
	end
	
	dmg.fix_all_icons()
end

function Vault:start_wave(size, freq)
	self:prepare()
	
	-- create new waypoints every attack, takes into account radius changes and ends up more random
	self:make_waypoints()
	
	self.wave_start_tick = game.tick
	self.wave_size = size
	self.wave_freq = freq
	self.wave_bots_count = {}
	
	storage.active_vaults[self.id] = self
	
	self:update_alert()
end
function Vault:end_wave()
	--self.next_bot_id = nil
	
	self.wave_rng = nil -- every wave gets random variation for time and mining spawning
	self.wave_rng2 = nil
	self.wave_end_tick = game.tick
	
	-- reduce entity count, waypoints only while wave active
	self:delete_waypoints()
	
	storage.active_vaults[self.id] = nil
	
	self:remove_alert()
end

function Vault:_reset_wave_for_mining_rate() -- for restore-ore
	--self:end_wave()
	self.wave_start_tick = game.tick
	self.wave_end_tick = game.tick
end

-- do alerts not stay until deleted?
-- if so need to refresh via this
function Vault:update_alert()
	local force = game.forces["player"]
	
	--local radar_visible = force.is_chunk_visible(self.entity.surface, { self.entity.position.x / 32, self.entity.position.y / 32 })
	local built_nearby = self.has_targets
	
	-- radar_visible or built_nearby ?
	if built_nearby or const.DEBUG then -- radar_visible and   or const.DEBUG
		-- 2.1 only
		force.add_custom_alert(self.entity,
			{type="entity", name=const.VAULT_NAME},
			{"alert.active-attack",
			 string.format("%.0f", self.wave_size*100 or -1),
			-- string.format("%.2f", self.wave_freq or -1)
			}, true)
	end
end
function Vault:remove_alert()
	if self.entity.valid then
		game.forces["player"].remove_alert{entity=self.entity}
	end
end

return Vault