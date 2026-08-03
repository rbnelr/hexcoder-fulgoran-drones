local dmg = require("disable_on_damage")

---@class Vault
local Vault = {}
Vault.__index = Vault

---@param vault LuaEntity
---@return Vault
function init_vault(vault)
	assert(vault.name == VAULT_NAME)
	
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
		wave_emerging={},
		wave_emerging_projectiles={},
		wave_bots={}
	}, Vault)
	
	-- enemy structures cannot be mined, but decoratives like ruins can
	vault.force = DRONE_FORCE
	vault.destructible = false -- can't damage
	-- 
	
	v.shaft_near_wall = vault.surface.find_entity(VAULT_NEAR_WALL_NAME, vault.position)
	if v.shaft_near_wall == nil then
		v.shaft_near_wall = v.entity.surface.create_entity{
			name = VAULT_NEAR_WALL_NAME, position = v.entity.position,
		}
	end
	v.shaft_near_wall.destructible = false
	
	v:prepare() -- make sure to fix buildings
	
	storage.vaults[id] = v
	return v
end

function Vault:destroy()
	self:end_wave() -- deletes waypoints too
	
	if self.shaft_near_wall and self.shaft_near_wall.valid then
		self.shaft_near_wall.destroy()
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
function Vault:make_waypoints()
	local count = 30
	local R = VAULT_DEFENSE_RADIUS()*0.8
	
	self.waypoints = {}
	for i=1,count do
		local waypoint = self.entity.surface.create_entity{name=WAYPOINT,
			position = random_in_circle(self.entity.position, R)
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

function Vault:wave_active()
	return (next(self.wave_bots) or next(self.wave_emerging) or next(self.wave_emerging_projectiles)) ~= nil
end

function Vault:prepare()
	self:delete_waypoints()
	
	-- build new list, no cleanup needed for old one
	self.targets = {}
	
	local R = VAULT_DEFENSE_RADIUS()
	local p = self.entity.position
	for _,e in pairs(self.entity.surface.find_entities_filtered{
						position=p, radius=R, type = TARGETS }) do
		--game.print(serpent.line(e))
		
		if check_distance(e.position, p, R) then
			dmg.fix_building(e.unit_number, e)
			
			if not e.disabled_by_script then
				e.is_military_target = true
				self.targets[e.unit_number] = e
			end
		end
	end
	
	dmg.fix_all_icons()
	
	-- create new waypoints every attack, takes into account radius changes and ends up more random
	self:make_waypoints()
end

function Vault:start_wave(size, freq)
	self:prepare()
	
	self.wave_start_tick = game.tick
	
	game.forces["player"].add_custom_alert(self.entity,
		{type="entity", name=VAULT_NAME},
		{"alert.active-attack", size, freq}, true)
	
	storage.active_vaults[self.id] = self
end
function Vault:end_wave()
	--self.next_bot_id = nil
	
	self.wave_end_tick = game.tick
	self.wave_rng = nil -- every wave gets random variation for time and mining spawning
	self.wave_rng2 = nil
	
	if self.entity.valid then
		game.forces["player"].remove_alert{entity=self.entity}
	end
	
	self:delete_waypoints()
	
	storage.active_vaults[self.id] = nil
end

---@return integer
function Vault:get_ore_depletion()
	-- TODO: profile, and if at all significant, split it into smaller chunks to rotate through
	local circ_r = VAULT_DEFENSE_RADIUS()
	local square_r = circ_r * 0.71 + 5 -- can only check rectangle, don't check outside visual circle, so radius*cos(pi/4)
	local count = 0
	for _,ore_tile in pairs(self.entity.surface.find_entities_filtered{
		position=self.entity.position, radius=square_r, type="resource", name="scrap"}) do
		count = count + ore_tile.amount
	end
	
	--if game.get_player(1).selected == self.entity then
	--	local time = (game.tick - (_ore_prev_tick or 0)) / 60
	--	local delta = count - (_ore_prev or 0)
	--	local speed = (delta / time) * 60
	--	_ore_prev_tick = game.tick
	--	_ore_prev = count
	--	rendering.draw_rectangle{
	--		left_top=    {x=self.entity.position.x-square_r, y=self.entity.position.y-square_r},
	--		right_bottom={x=self.entity.position.x+square_r, y=self.entity.position.y+square_r},
	--		width=5, surface=self.entity.surface, color={0,1,0}, time_to_live=30 }
	--	game.print("check_ore_depletion: "..serpent.line{self.entity, count, delta, time, speed})
	--end
	
	return count
end

return Vault