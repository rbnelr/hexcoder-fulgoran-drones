local dmg = require("disable_on_damage")

---@class Vault
local Vault = {}
Vault.__index = Vault

---@param vault LuaEntity
---@return Vault
function init_vault(vault)
	-- simple entity has no unit_number!
	--local id = vault.unit_number ---@cast id -nil
	-- workaround, register on_object_destroyed
	local id = script.register_on_object_destroyed(vault)
	
	local v = storage.vaults[id] or setmetatable({ targets={}, waypoints={}, wave_bots={}, wave_emerging={} }, Vault)
	v.entity = vault
	storage.vaults[id] = v
	return v
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

--function Vault:wave_active()
--	return (next(self.wave_bots) or next(self.wave_emerging)) ~= nil
--end

function Vault:prepare()
	self:delete_waypoints()
	
	-- build new list, no cleanup needed for old one
	self.targets = {}
	
	local R = VAULT_DEFENSE_RADIUS()
	local p = self.entity.position
	for _,e in pairs(self.entity.surface.find_entities_filtered{
						position=p, radius=R, type = TARGETS }) do
		--game.print(serpent.line(e))
		-- is actually in clircle?
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

return Vault