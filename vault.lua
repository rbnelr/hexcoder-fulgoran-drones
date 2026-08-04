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
	vault.force = DRONE_FORCE -- vault (simple-entity) can't actually have a force?
	vault.destructible = false -- can't damage
	
	v.shaft_near_wall = vault.surface.find_entity(VAULT_NEAR_WALL_NAME, vault.position)
	if v.shaft_near_wall == nil then
		v.shaft_near_wall = v.entity.surface.create_entity{
			name = VAULT_NEAR_WALL_NAME, position = v.entity.position,
		}
	end
	v.shaft_near_wall.destructible = false
	
	v:prepare() -- make sure to fix buildings
	
	storage.vaults[id] = v
	
	rendering.draw_rectangle{left_top=vault.bounding_box.left_top, right_bottom=vault.bounding_box.right_bottom,
		surface=vault.surface, filled=true, color={0,1,0}, time_to_live=60}
	
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
		{"alert.active-attack", string.format("%.2f", size), string.format("%.2f", freq)}, true)
	
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
function Vault:get_ore_remaining()
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
	--		width=5, surface=self.entity.surface, color={0,1,0}, time_to_live=60 }
	--	game.print("check_ore_depletion: "..serpent.line{self.entity, count, delta, time, speed})
	--end
	
	return count
end

---@param surface LuaSurface
---@param area BoundingBox
---@param ore_tiles LuaEntity[]
local function try_place_missing_vault_ruin2(surface, area, ore_tiles)
	--local prof = helpers.create_profiler()
	
	-- scan more ore around the chunk, I think this makes sense
	--local r = 10
	--local near_ore_tiles = surf.find_entities_filtered{type="resource", name="scrap",
	--	area={{area.left_top.x-r, area.left_top.y-r}, {area.right_bottom.x+r, area.right_bottom.y+r}}
	--}
	
	local custom_thres = 0.03
	local prop_names = {"fulgora_spots", "fulgora_vaults_and_starting_vault"}
	local tile_pos = {}
	
	local found
	local found_prob
	
	for _,ore_tile in pairs(ore_tiles) do
		-- orignal probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.015) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"
		-- don't bother trying to evaluate starting area
		tile_pos[1] = ore_tile.position
		local props = surface.calculate_tile_properties(prop_names, tile_pos)
		local prob = props.fulgora_spots[1] * props.fulgora_vaults_and_starting_vault[1]
		if prob < custom_thres then
			-- find closest ore tile to center of 'vault spot'
			if found_prob == nil or prob < found_prob then
				found = ore_tile
				found_prob = prob
			end
		end
	end
	
	local pos = found and found.position
	
	-- this does not actually prevent spawning 'missing' vault where actually there was once close
	-- I assume this has to be because the neighbouring chunk is not actually generated yet?
	-- so we manually spawn vaults that would not actually be missing, but this works out ok actually
	if found then
		local near_vaults = surface.find_entities_filtered{name=VAULT_NAME, position=pos, radius=25}
		if next(near_vaults) then
			-- chunk area did not contain a vault, but in neighbouring chunk (next to suitable vault pos) there already is one
			found = nil
		end
	end
	
	if found then
		--game.print("Spawning missing vault ruin: "..serpent.line(found))
		
		local bb = prototypes.entity[VAULT_NAME].collision_box
		local p0 = {pos.x+bb.left_top.x, pos.y+bb.left_top.y}
		local p1 = {pos.x+bb.right_bottom.x, pos.y+bb.right_bottom.y}
		local colliding = surface.find_entities_filtered{
			area={p0, p1}, collision_mask={
				"is_lower_object", "is_object", "item", "object" -- not player
			},
			--force="neutral" -- don't destroy player creations!
		}
		local safe_to_spawn = true
		for _,e in pairs(colliding) do
			if e.force.name == "player" and e.name ~= "fulgoran-ruin-attractor" then -- fulgoran lighting-attractor has player force for some reason
				safe_to_spawn = false
				break
			end
		end
		
		if safe_to_spawn then
			for _,e in pairs(colliding) do
				e.destroy()
			end
			
			local vault = surface.create_entity{name=VAULT_NAME, position=pos, snap_to_grid=false, raise_built=true, move_stuck_players=true}
			if vault ~= nil then
				game.print("Spawned missing vault ruin: "..serpent.line(vault))
			end
		end
	end
	
	--prof.stop()
	--game.print(prof)
end

---@param surface LuaSurface
---@param area BoundingBox
function Vault.try_place_missing_vault_ruin(surface, area)
	--local prof = helpers.create_profiler()
	
	-- no vault ruin, count total scrap in chunk
	local count = 0
	local ore_tiles = surface.find_entities_filtered{type="resource", name="scrap", area=area}
	for _,ore_tile in pairs(ore_tiles) do
		count = count + ore_tile.amount
	end
	
	--prof.stop()
	--game.print(prof)
	
	if count > 1000000 then
		-- >1M scrap, there should have been a vault ruin somewhere in this chunk, but its missing!
		try_place_missing_vault_ruin2(surface, area, ore_tiles)
	end
end

return Vault