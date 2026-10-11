local dmg = require("disable_on_damage")
local g = require("common")

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
---@field wave_bots table<string, integer>
-- TODO: track sorted into buckets by tick or sort list?
---@field wave_emerging table<integer, Emerging> -- current attack wave emerging bots (queues projectiles, not active projectiles)
--@field wave_emerging_projectiles table<obj_id, LuaEntity> -- current attack wave active bots
---@field wave_emerging_projectiles table<integer, LuaEntity> -- current attack wave active bots
---@field active_wave_bots table<integer, LuaEntity> -- current attack wave active bots
--@field next_bot_id integer?

---@class (exact) Emerging
--@field id integer
---@field tick integer
---@field name string -- emerging projectile name
---@field final_pos MapPosition

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
		wave_emerging={},
		wave_emerging_projectiles={},
		active_wave_bots={}
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
	return (next(self.active_wave_bots) or next(self.wave_emerging) or next(self.wave_emerging_projectiles)) ~= nil
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
	self.wave_bots = {}
	
	storage.active_vaults[self.id] = self
end
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

-- only needed for my own stupid mod where mining one scrap ore actually gives more than one result so we can be probabalistic
-- note that the map view hover also does applies this factor
local function average_scrap_mining_result()
	local minable = prototypes.entity.scrap.mineable_properties
	local product = minable.products[1]
	local avg_result = product.amount or (product.amount_min + product.amount_max)/2
	avg_result = avg_result * (product.independent_probability or 1)
	-- shared_probability?
	return avg_result
end

--[[
---@return integer
function Vault:get_initial_ore()
	-- TODO: profile, and if at all significant, split it into smaller chunks to rotate through
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	
	local vx = self.entity.position.x
	local vy = self.entity.position.y
	local x0 = math.floor(vx - circ_r) -- center of tile correct for calculate_tile_properties ?
	local x1 = math.floor(vx + circ_r)
	local y0 = math.ceil(vy - circ_r)
	local y1 = math.ceil(vy + circ_r)
	--local x0 = math.floor(vx - circ_r)+0.5 -- center of tile correct for calculate_tile_properties ?
	--local x1 = math.floor(vx + circ_r)+0.5
	--local y0 = math.ceil(vy - circ_r)+0.5
	--local y1 = math.ceil(vy + circ_r)+0.5
	
	local surface = self.entity.surface
	local prop_names = {"entity:scrap:richness", "entity:scrap:probability", "fulgora_scrap_small", "resource_autoplace_all_patches"}
	local tile_pos = {}
	local count = 0
	
	--for x=x0,x1 do
	--	for y=y0,y1 do
	--		if g.check_distance2(x,y, vx,vy, circ_r) then
	--			tile_pos[1] = {x, y} -- is center correct here?
	--			local props = surface.calculate_tile_properties(prop_names, tile_pos)
	--			
	--			local frequency = 1
	--			local richness = 1
	--			local val = (1 + props.fulgora_structure_subnoise[1]) * 1000 * (7 / (6 + frequency) + 100 * props.fulgora_vaults_and_starting_vault[1]) * richness
	--			
	--			if val > 0 then
	--				rendering.draw_circle{target=tile_pos[1], surface=surface, radius=0.25, width=1, color={0,1,0}, time_to_live=30}
	--			end
	--		end
	--	end
	--end
	
	-- way faster than individual calculate_tile_properties calls
	for x=x0,x1 do
		for y=y0,y1 do
			if g.check_distance2(x,y, vx,vy, circ_r) then
				-- orignal probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.015) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"
				-- don't bother trying to evaluate starting area
				table.insert(tile_pos, {x, y})
			end
		end
	end
	local props = surface.calculate_tile_properties(prop_names, tile_pos)
	for i=1,#tile_pos do
		local prob = props["entity:scrap:probability"][i]
		local rich = props["entity:scrap:richness"][i]
		local noise = props["fulgora_scrap_small"][i]
		--local autopl = props["resource_autoplace_all_patches"][i]
		
		if prob > 0.0 then
			local p = tile_pos[i]
			rendering.draw_circle{target={p[1]+0.5, p[2]+0.5}, surface=surface, radius=0.25, width=1, color={0,1,0}, time_to_live=30}
		end
	end
	
	for _,ore_tile in pairs(surface.find_entities_filtered{position=self.entity.position, radius=circ_r, type="resource", name="scrap"}) do
		rendering.draw_circle{target=ore_tile.position, surface=surface, radius=0.4, width=1, color={0,0,1}, time_to_live=30}
	end
	
	if self.initial_ore_amount == nil then
		self.initial_ore_amount = count
	end
	
	return count
end]]
---@return integer
function Vault:get_initial_ore()
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	
	local surface = self.entity.surface
	
	-- deleting is queued, seems like it sometimes can still exist
	local temp_surf = game.surfaces["hexcoder_fake_fulgora"]
	if temp_surf == nil then
		temp_surf = game.create_surface("hexcoder_fake_fulgora", surface.map_gen_settings)
	end
	
	-- I assume find_entities_filtered won't generate chunks for us
	temp_surf.request_to_generate_chunks(self.entity.position, circ_r/32+1) -- not sure about this radius
	temp_surf.force_generate_chunk_requests()
	
	local count = 0
	for _,ore_tile in pairs(temp_surf.find_entities_filtered{position=self.entity.position, radius=circ_r, type="resource", name="scrap"}) do
		--rendering.draw_circle{target=ore_tile.position, surface=surface, radius=0.4, width=1, color={0,0,1}, time_to_live=600}
		count = count + ore_tile.amount
	end
	game.delete_surface("hexcoder_fake_fulgora")
	
	count = math.floor(count * average_scrap_mining_result()) -- mods can how much one mining operation actually outputs (on average)
	
	return count
end

-- Changing the radius potentially changes total scanned ore
-- Previously this may have worked since I only used it to trigger waves after x amount of mining
-- For new mechanics we may want to handle radius changes (TODO: reset wave_start_ore_amount and try to determine new initial amount?)
---@return integer
function Vault:get_ore_remaining()
	-- TODO: profile, and if at all significant, split it into smaller chunks to rotate through
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	
	-- actually it's a circle?
	--local square_r = circ_r * 0.71 + 5 -- can only check rectangle, don't check outside visual circle, so radius*cos(pi/4)
	
	local count = 0
	for _,ore_tile in pairs(self.entity.surface.find_entities_filtered{
		position=self.entity.position, radius=circ_r, type="resource", name="scrap"}) do
		count = count + ore_tile.amount
	end
	
	count = math.floor(count * average_scrap_mining_result())
	
	if self.initial_ore_amount == nil then
		--self.initial_ore_amount = count
		self.initial_ore_amount = self:get_initial_ore()
	end
	
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
		local near_vaults = surface.find_entities_filtered{name=g.VAULT_NAME, position=pos, radius=25}
		if next(near_vaults) then
			-- chunk area did not contain a vault, but in neighbouring chunk (next to suitable vault pos) there already is one
			found = nil
		end
	end
	
	if found then
		--game.print("Spawning missing vault ruin: "..serpent.line(found))
		
		local bb = prototypes.entity[g.VAULT_NAME].collision_box
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
			
			local vault = surface.create_entity{name=g.VAULT_NAME, position=pos, snap_to_grid=false, raise_built=true, move_stuck_players=true}
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

-- TODO: drone dying spawning stuff
-----@param event EventData.on_entity_died
--function Vault.on_drone_died(event)
--	if not (event.entity.force == g.DRONE_FORCE and g.IS_DRONE[event.entity.name]) then
--		return
--	end
--	
--end

return Vault