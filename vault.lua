local g = require("common")
local dmg = require("disable_on_damage")

---@class Vault
---@field entity LuaEntity
---@field id obj_id
---@field near_wall LuaEntity?
---@field targets LuaEntity[] -- NOTE: entities can end up in two vaults target list!
---@field waypoints LuaEntity[]
---@field wave_rng number?
---@field wave_rng2 number?
---@field initial_ore_amount integer?
---@field wave_start_ore_amount integer?
---@field wave_size number?
---@field wave_freq number?
---@field wave_start_tick integer?
---@field wave_end_tick integer?
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
---@return Vault
function Vault.from_entity(vault)
	assert(vault.name == g.VAULT_NAME)
	
	-- simple entity has no unit_number!
	--local id = vault.unit_number ---@cast id -nil
	-- workaround, register on_object_destroyed
	local id = script.register_on_object_destroyed(vault)
	local v = storage.vaults[id]
	if v then return v end
	
	local v = setmetatable({
		entity = vault,
		id = id,
		targets={},
		waypoints={},
		wave_bots={},
		wave_emerging_queued={},
		wave_emerging_projectiles={},
		active_wave_bots={},
		wave_bots_count={},
	}, Vault)
	
	-- enemy structures cannot be mined, but decoratives like ruins can
	vault.force = g.DRONE_FORCE -- vault (simple-entity) can't actually have a force?
	vault.destructible = false -- can't damage
	
	v.near_wall = vault.surface.find_entity(g.VAULT_NEAR_WALL_NAME, vault.position)
	if v.near_wall == nil then
		v.near_wall = v.entity.surface.create_entity{
			name = g.VAULT_NEAR_WALL_NAME, position = v.entity.position,
		}
	end
	v.near_wall.destructible = false
	
	v:prepare() -- make sure to fix buildings
	
	storage.vaults[id] = v
	
	if g.DEBUG then
		--rendering.draw_rectangle{left_top=vault.bounding_box.left_top, right_bottom=vault.bounding_box.right_bottom,
		--	surface=vault.surface, filled=true, color={0,1,0}, time_to_live=60}
		game.print("init vault ".. serpent.line{vault})
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
	local R = g.VAULT_DEFENSE_RADIUS()*0.8
	
	self.waypoints = {}
	for i=1,count do
		local waypoint = self.entity.surface.create_entity{name=g.WAYPOINT,
			position = g.random_in_circle(self.entity.position, R)
		}
		waypoint.destructible = false
		
		table.insert(self.waypoints, waypoint)
	end
end

function Vault:wave_active()
	return (next(self.active_wave_bots) or next(self.wave_emerging_queued) or next(self.wave_emerging_projectiles)) ~= nil
end

function Vault:prepare()
	-- build new list, no cleanup needed for old one
	self.targets = {}
	
	local R = g.VAULT_DEFENSE_RADIUS()
	local p = self.entity.position
	for _,e in pairs(self.entity.surface.find_entities_filtered{
						position=p, radius=R, type = g.TARGETS }) do
		--game.print(serpent.line(e))
		
		if g.check_distance(e.position, p, R) then
			dmg.fix_building(e.unit_number, e)
			
			if not e.disabled_by_script then
				e.is_military_target = true
				self.targets[e.unit_number] = e
			end
		end
	end
	
	dmg.fix_all_icons()
end

function Vault:update_alert()
	local force = game.forces["player"]
	local cpos = { self.entity.position.x / 32, self.entity.position.y / 32 }
	if force.is_chunk_visible(self.entity.surface, cpos) then
		force.add_custom_alert(self.entity,
			{type="entity", name=g.VAULT_NAME},
			{"alert.active-attack",
			string.format("%.2f", self.wave_size or -1),
			string.format("%.2f", self.wave_freq or -1)}, true)
	end
end

function Vault:start_wave(size, freq)
	self:prepare()
	
	-- create new waypoints every attack, takes into account radius changes and ends up more random
	self:make_waypoints()
	
	-- 2.1 only
	game.forces["player"].add_custom_alert(self.entity,
		{type="entity", name=g.VAULT_NAME},
		{"alert.active-attack", string.format("%.2f", size), string.format("%.2f", freq)}, true)
	
	self.wave_start_tick = game.tick
	self.wave_size = size
	self.wave_freq = freq
	self.wave_bots_count = {}
	
	storage.active_vaults[self.id] = self
end
-- apparently I didn't make this actually stop 
function Vault:end_wave()
	--self.next_bot_id = nil
	
	self.wave_rng = nil -- every wave gets random variation for time and mining spawning
	self.wave_rng2 = nil
	self.wave_end_tick = game.tick
	
	--if self.entity.valid then
	--	game.forces["player"].remove_alert{entity=self.entity}
	--end
	
	-- reduce entity count, waypoints only while wave active
	self:delete_waypoints()
	
	storage.active_vaults[self.id] = nil
end

-- TODO: drone dying spawning stuff
-----@param event EventData.on_entity_died
--function Vault.on_drone_died(event)
--	if not (event.entity.force == g.DRONE_FORCE and g.IS_DRONE[event.entity.name]) then
--		return
--	end
--	
--end

return Vault