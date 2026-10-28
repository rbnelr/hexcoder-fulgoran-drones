local g = require("common")
---@class Vault
local Vault = require("vault")

-- mods can how much one mining operation actually outputs (on average), for example giving 0-5 ore per mining operation in 2.5x the time
-- this is actually respected by the value shown in the map view on hover (unlike mining prod or 50% drain on big miners)
-- so use this to match the map view
--local function scrap_result_per_mining_drain()
--	local minable = prototypes.entity["scrap"].mineable_properties
--	local product = minable.products[1]
--	local avg_result = product.amount or (product.amount_min + product.amount_max)/2
--	avg_result = avg_result * (product.independent_probability or 1)
--	-- shared_probability?
--	return avg_result
--end
local function scrap_result_per_mining_drain()
	local resource = prototypes.entity["scrap"]
	local minable = resource.mineable_properties
	local product = minable.products[1]
	local factor = product.amount or (product.amount_min + product.amount_max)/2
	factor = factor * (product.independent_probability or 1)
	-- shared_probability?
	
	-- currently, avg 8 scrap with mining time 4 and inf drain 80 => 8/10 = 0.1 product per drain
	-- not taking into account yield!
	-- observed_drain * factor = mining rate without drain% or productivity
	factor = factor / resource.infinite_depletion_resource_amount
	return factor
end

-- We want to know what the original ore amount was per vault scrap patch
-- We determine the current amount via a (expensive) find_entities_filtered scan
-- so we could just record the earliest number we see, but then installing the mod in a running game, or migrating may break this
-- however, installing the mod in a running game is unlikely, as the player would have removed the vault ruin anyway
-- still, we can attempt to find the original ore amount using calculate_tile_properties and entity:scrap:richness for all the tiles, however it's impossible to reconstruct entity:scrap:probability
-- so at least fully drained ore tiles can't be considered
-- however spawning a new fake fulgora seems to give identical ore gen, and can be scanned in a very simple function (though it lags a bit)
-- TODO: don't actually run this if we can be sure the vault is new (new chunk or value from migration?)
-- TODO: can also use this technique to respawn vault ruin even if player mined it originally for late installs (spawn ignoring collision with player entities)
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
	-- may actually have to wait then, if surface still exists but is queued for deletion can we actually still use it?
	-- doesn't seem to be a problem right now, probably because this gets called in a staggered way?
	local temp_surf = game.surfaces["hexcoder_fake_fulgora"]
	if temp_surf == nil then
		temp_surf = game.create_surface("hexcoder_fake_fulgora", surface.map_gen_settings)
	end
	
	-- I assume find_entities_filtered won't generate chunks for us
	temp_surf.request_to_generate_chunks(self.entity.position, circ_r/32+1) -- not sure about this radius
	temp_surf.force_generate_chunk_requests()
	
	local count = 0
	for _,ore_tile in pairs(temp_surf.find_entities_filtered{position=self.entity.position, radius=circ_r, type="resource", name={"scrap", "vault-scrap"}}) do
		--rendering.draw_circle{target=ore_tile.position, surface=surface, radius=0.4, width=1, color={0,0,1}, time_to_live=600}
		count = count + ore_tile.amount
	end
	game.delete_surface("hexcoder_fake_fulgora")
	
	count = math.floor(count * scrap_result_per_mining_drain())
	
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
	
	local e = self.entity
	
	local count = 0
	for _,ore_tile in pairs(e.surface.find_entities_filtered{
		position=e.position, radius=circ_r, type="resource", name={"scrap", "vault-scrap"}}) do
		count = count + ore_tile.amount
	end
	
	count = math.floor(count * scrap_result_per_mining_drain())
	
	if self.initial_ore_amount == nil then
		--self.initial_ore_amount = count
		self.initial_ore_amount = self:get_initial_ore() -- can lag!
	end
	
	return count
end

-- Changing the radius potentially changes total scanned ore
-- Previously this may have worked since I only used it to trigger waves after x amount of mining
-- For new mechanics we may want to handle radius changes (TODO: reset wave_start_ore_amount and try to determine new initial amount?)
---@return integer
function Vault:make_ore_infinite()
	-- TODO: profile, and if at all significant, split it into smaller chunks to rotate through
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	
	local position = self.entity.position
	local surface = self.entity.surface
	for _,ore_tile in pairs(surface.find_entities_filtered{
		  position=position, radius=circ_r, type="resource", name="scrap"}) do
		
		local inf_ore = surface.create_entity{name="vault-scrap", position=ore_tile.position, snap_to_grid=true, preserve_ghosts_and_corpses=true}
		inf_ore.amount = ore_tile.amount
		inf_ore.initial_amount = ore_tile.amount
		
		ore_tile.destroy()
	end
	
	local r = circ_r + g.max_drill_radius
	local area = {{position.x-r, position.y-r},
	              {position.x+r, position.y+r}}
	for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
		drill.update_connections()
	end
end

-- experimental way of spawning vaults in rare case where vault island is missing its ruin
--[[
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
			
			local vault = surface.create_entity{name=g.VAULT_NAME, position=pos, snap_to_grid=false, raise_built=true, move_stuck_players=true} -- preserve_ghosts_and_corpses ?
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
]]
