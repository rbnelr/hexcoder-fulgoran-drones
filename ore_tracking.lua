local g = require("common")
---@class Vault
local Vault = require("vault")

local INF_SCRAP_PROTO = prototypes.entity["vault-scrap"]
local INF_SCRAP_NORMAL = INF_SCRAP_PROTO.normal_resource_amount
local INF_SCRAP_MIN = INF_SCRAP_PROTO.minimum_resource_amount
local INF_SCRAP_MIN_RATIO = INF_SCRAP_MIN / INF_SCRAP_NORMAL

-- try to bump such that its not visible if floored to yield%
local INF_SCRAP_DEPLETED_BUMP_AMOUNT = math.max(math.floor(INF_SCRAP_PROTO.normal_resource_amount / 100 / 2), 1)

-- infinite resource minimum amount actually works like this
---@param ore_tile LuaEntity
local function get_inf_scrap_minimum (ore_tile)
	if ore_tile.initial_amount <= INF_SCRAP_NORMAL then
		return INF_SCRAP_MIN
	else
		return ore_tile.initial_amount * INF_SCRAP_MIN_RATIO
	end
end


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
local function _scrap_result_per_mining_drain(type)
	local resource = prototypes.entity[type] -- TODO: correct even for inf scrap?
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

-- TODO: remove? we likely want 1 to 1 anyway, instead need to account for infinite ore low yield rng
local DRAIN_TO_ORE = {
	["scrap"] = _scrap_result_per_mining_drain("scrap"),
	["vault-scrap"] = _scrap_result_per_mining_drain("vault-scrap"),
}

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
function Vault:get_initial_ore_slow()
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
	
	for _,ore_tile in pairs(surface.find_entities_filtered{position=self.entity.position, radius=circ_r, type="resource", name=g.SCRAP_TYPES}) do
		rendering.draw_circle{target=ore_tile.position, surface=surface, radius=0.4, width=1, color={0,0,1}, time_to_live=30}
	end
	
	if self.initial_ore_amount == nil then
		self.initial_ore_amount = count
	end
	
	return count
end]]

---@param original_fulgora LuaSurface
---@param where MapPosition|"all"
---@param radius? number
---@return LuaSurface
function Vault.recreate_initial_surface_and_load_chunks(original_fulgora, where, radius)
	--game.print("regenerating fulgora entities, please be patient...") obviously this won't be seen until this is done
	
	-- lazy create surface
	local fake_surface = game.surfaces["hexcoder_fake_fulgora"]
	if fake_surface == nil then
		fake_surface = game.create_surface("hexcoder_fake_fulgora", original_fulgora.map_gen_settings)
	end
	
	-- A later find_entities_filtered won't generate chunks for us (I think?)
	if where == "all" then
		for cpos in original_fulgora.get_chunks() do
			if original_fulgora.is_chunk_generated(cpos) then
				fake_surface.request_to_generate_chunks({ cpos.x*32+16, cpos.y*32+16 })
			end
		end
	else
		fake_surface.request_to_generate_chunks(where, radius/32+1)
	end
	fake_surface.force_generate_chunk_requests()
	
	--local test = {}
	--for cpos in fake_surface.get_chunks() do
	--	if fake_surface.is_chunk_generated(cpos) then
	--		table.insert(test, cpos)
	--	end
	--end

	-- do not delete fake fulgora in case multiple requests are made
	-- hopefully better perf? and safer?
	-- actually queued to be deleted, so multiple requests should be fine, maybe just worse perf if used every few seconds
	storage.last_used_fake_fulgora = game.tick

	if g.DEBUG then
		game.print("Created fake fulgora")
	end
	return fake_surface
end
script.on_nth_tick(60, function(event)
	local last_use = storage.last_used_fake_fulgora
	if last_use and event.tick - last_use > 11*60 then
		game.delete_surface("hexcoder_fake_fulgora")
		storage.last_used_fake_fulgora = nil
		
		if g.DEBUG then
			game.print("Deleted fake fulgora")
		end
	end
end)

---@return LuaEntity[]
function Vault:get_initial_ore_slow()
	local position = self.entity.position
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	local fake_surface = Vault.recreate_initial_surface_and_load_chunks(self.entity.surface, position, circ_r)
	
	return fake_surface.find_entities_filtered{position=position, radius=circ_r, type="resource", name=g.SCRAP_TYPES}
end

---@return integer
function Vault:get_initial_ore_count()
	local count = 0
	for _,ore_tile in pairs(self:get_initial_ore_slow()) do
		--rendering.draw_circle{target=ore_tile.position, surface=surface, radius=0.4, width=1, color={0,0,1}, time_to_live=600}
		count = count + ore_tile.amount * DRAIN_TO_ORE[ore_tile.name]
	end
	
	count = math.floor(count)
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
		position=e.position, radius=circ_r, type="resource", name=g.SCRAP_TYPES}) do
		if ore_tile.name == "vault-scrap" then
			if ore_tile.amount <= INF_SCRAP_MIN then
				--ore_tile.amount = INF_SCRAP_MIN + INF_SCRAP_DEPLETED_BUMP_AMOUNT
				
				Vault.update_drill_connections_near(ore_tile.surface, ore_tile.position)
			end
		end
		count = count + ore_tile.amount * DRAIN_TO_ORE[ore_tile.name]
	end
	
	count = math.floor(count)
	
	if self.initial_ore_amount == nil then
		--self.initial_ore_amount = count
		self.initial_ore_amount = self:get_initial_ore_count() -- can lag!
	end
	
	return count
end

-- Changing the radius potentially changes total scanned ore
-- Previously this may have worked since I only used it to trigger waves after x amount of mining
-- For new mechanics we may want to handle radius changes (TODO: reset wave_start_ore_amount and try to determine new initial amount?)
---@param mode "finite"|"infinite"
---@param restore number|"keep" -- restore to x percent or initial or keep
---@return string
function Vault:modify_ore(mode, restore)
	local circ_r = g.VAULT_DEFENSE_RADIUS()
	local position = self.entity.position
	local surface = self.entity.surface
	local from = {"scrap", "vault-scrap"}
	local to = mode == "finite" and "scrap" or "vault-scrap"

	local minimum = INF_SCRAP_MIN + INF_SCRAP_DEPLETED_BUMP_AMOUNT
	local new_count = 0
	local initial_count = 0
	
	-- get old ore before we add new
	local old_ores = surface.find_entities_filtered{type="resource", name=from, position=position, radius=circ_r}
	
	if restore == "keep" then
		-- a bit weird:
		-- spawn new ore copied from newly generated fake fulgora, then only check old ore tiles for amount
		-- do not iterate old_ore, since tiles may be depleted and infinite ores need their initial_amount set, which works best if accurate
		-- TODO: hold on, why do we need to set initial_amount? we don't actually read it and instead track the initial amount per vault on our own
		-- and yield depends on normal_resource_amount, not this
		for _,orig_ore in pairs(self:get_initial_ore_slow()) do
			local new_ore = surface.create_entity{name=to, position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast new_ore -nil
			local old_ore = surface.find_entities_filtered{name=from, position=orig_ore.position} -- check if get_closest(old_ores, ...) actually makes sense here
			
			local amount = old_ore and old_ore[1].amount or 0
			local orig_amount = orig_ore.amount
			
			if to == "vault-scrap" then
				if amount < minimum then amount = minimum end
				new_ore.initial_amount = orig_amount
			end
			new_ore.amount = amount

			new_count = new_count + amount * DRAIN_TO_ORE[new_ore.name]
			initial_count = initial_count + orig_amount * DRAIN_TO_ORE[orig_ore.name]
		end
	elseif restore > 0 or to == "vault-scrap" then -- not allowed to set amount=0
		-- spawn new ore copied from newly generated fake fulgora
		-- and simply multiply amount
		for _,orig_ore in pairs(self:get_initial_ore_slow()) do
			local new_ore = surface.create_entity{name=to, position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast new_ore -nil
			
			local orig_amount = orig_ore.amount
			local amount = math.ceil(orig_amount * restore)
			
			if to == "vault-scrap" then
				-- enfore minimum for infinite ores (20% of each tile normal amount, Note: restore=20% is of mapgen amount, which is different)
				if amount < minimum then amount = minimum end
				new_ore.initial_amount = amount > orig_amount and amount or orig_amount
			end
			new_ore.amount = amount
			
			new_count = new_count + amount * DRAIN_TO_ORE[new_ore.name]
			initial_count = initial_count + orig_amount * DRAIN_TO_ORE[orig_ore.name]
		end
	end

	-- actually delete it
	for _,old_ore in pairs(old_ores) do
		old_ore.destroy()
	end

	new_count = math.floor(new_count)
	initial_count = math.floor(initial_count)
	
	-- probably best to inflate original amount in case of restore=>100% to avoid negative drained ore in gui etc.
	if initial_count < new_count then
		initial_count = new_count
	end

	-- important!, otherwise we may get negative or positive huge mining rates and trigger huge waves
	self:reset_ore_tracking("modify_ore", new_count, initial_count)
	
	self:update_drill_connections_near_vault()

	return "success"
end

function Vault:update_drill_connections_near_vault ()
	local position = self.entity.position
	local r = g.max_drill_radius + g.VAULT_DEFENSE_RADIUS() -- square radius!
	local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
	for _,drill in pairs(self.entity.surface.find_entities_filtered{area=area, type="mining-drill"}) do
		drill.update_connections()
	end
end
---@param surface LuaSurface
---@param position MapPosition
function Vault.update_drill_connections_near (surface, position)
	local r = g.max_drill_radius -- square radius!
	local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
	-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
	for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
		--local p = drill.position
		--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
		drill.update_connections()
	end
end

local lone_drills = {}
local ore_cache = {}

---@param pos MapPosition
---@return integer
local function int_position_key(pos)
	local x = math.floor(pos.x or pos[1]) ---@cast x integer
	local y = math.floor(pos.y or pos[2]) ---@cast y integer
	return y * 65536 + x -- TODO: lookup my old version of this, I remember that for chunks this was possible up to the map bounds
end

-- Ores don't have unit_numbers, need to key via position (?)
-- YARM does this: but I'm not sure that this ideal, I would prefer a integer hash instead of a string (allocation?)
--[[
---Add an entity to the ore tracker if not already present. The entity must
---be valid and be a resource type.
---@param entity LuaEntity Must be a resource entity
---@return number? index The index of the entity within the ore tracker cache, or nil if the entity could not be added
function ore_tracker_module.add_entity(entity)
    if not entity or not entity.valid or entity.type ~= "resource" then
        return nil
    end

    -- If it's already in the cache, we just return its index
    local index = ore_tracker_module.index_of(entity)
    if index then
        return index
    end

    -- Otherwise, create the tracking data and store it, and put it in the position_cache
    local tracking_data = internal.new_resource_tracking_data(entity)

    local entities = storage.ore_tracker.entities
    local next_index = #entities + 1
    entities[next_index] = tracking_data

    local position_key = internal.entity_position_to_string(entity)
    ore_tracker_module.position_cache[position_key] = next_index

    return next_index
end

---Get an entity's tracking index (if it's in the cache)
---@param entity LuaEntity Must be a valid resource entity
---@return integer? # The tracker index of the given entity
function ore_tracker_module.index_of(entity)
    local position_key = internal.entity_position_to_string(entity)
    local its_index = ore_tracker_module.position_cache[position_key]

    if its_index then
        -- We're accessing the entity anyway, let's also use this opportunity to
        -- update the tracker values (and be 1000% certain that it's tracking
        -- the right entity).
        internal.update_tracking_data(entity, its_index)
    end

    return its_index
end

---Convert an entity's location into a string usable as table key. Like `position_to_string`, but
---taking the surface into account as well.
---@param entity LuaEntity
---@return string # A string like "nauvis@12345,12345" where the coordinates are upscaled 100x
function internal.entity_position_to_string(entity)
    -- Scale up x/y so (hopefully) any floating point component disappears, then
    -- force them to be integer with %d. Not using util.positiontostr as it uses %g
    -- and keeps the floating point component.
    return string.format("%s@%d,%d", entity.surface.name, entity.position.x * 100, entity.position.y * 100)
end
]]

-- /c local p=game.player local r = p.surface.create_entity{name="scrap", position=p.position} p.selected.update_connections()
script.on_event(defines.events.on_resource_depleted, function(event)
	local ore = event.entity

	if ore.name == "vault-scrap" then
		assert(ore.prototype.infinite_resource)
		--assert(e.prototype.minimum_resource_amount == e.amount) -- what, why is this not true sometimes? is it inaccurate with the wrong numbers?
		assert(ore.amount == get_inf_scrap_minimum(ore))
		
		--local vaults = ore.surface.find_entities_filtered{name=g.VAULT_NAME, position=position, radius=g.VAULT_DEFENSE_RADIUS()}
		--if next(vaults) == nil then
			local bump = INF_SCRAP_DEPLETED_BUMP_AMOUNT
			local bumped_amount = ore.amount + bump

			game.print("on_resource_depleted ".. serpent.line{e=e,
				amount=ore.amount,
				bumped_amount=bumped_amount,
				initial=ore.initial_amount,
				minimum=ore.prototype.minimum_resource_amount,
				normal=ore.prototype.normal_resource_amount,
				old_yield=ore.amount / INF_SCRAP_NORMAL * 100,
				new_yield=bumped_amount / INF_SCRAP_NORMAL * 100,
			})

			--local r = g.max_drill_radius -- square radius!
			--local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
			--for _,drill in pairs(ore.surface.find_entities_filtered{area=area, type="mining-drill"}) do
			--	local data = lone_drills[drill.unit_number] or { e = drill }
			--	--data.extra_drain = (data.extra_drain or 0) + bump
			--	lone_drills[drill.unit_number] = data
			--end
			
			ore.amount = bumped_amount
			-- need to account for bump here
			-- if we set amount directly, we lose mined amount since last poll, instead also bump whatever latest is
			local ore_key = int_position_key(ore.position)
			ore_cache[ore_key] = ore_cache[ore_key] + bump or bumped_amount
			
			-- probably should iterate through ores, not through vaults, which has more even cost
			-- then cache last amount and est. mining rate, in that case bump might be accounted for differently?
			-- will vaults then iterate their ore, or even store cached lists of ore keys, or should ore tracking lookup vault and accumulate rate?
			-- it's arkward since ores usually are part of one vault, but rarely can be part of two
		--end
	end

	--if e.name == "vault-scrap" then
	--	
	--	e.amount = e.amount + INF_SCRAP_DEPLETE_BUMP_AMOUNT
--
	--	Vault.update_drill_connections_near(e.surface, e.position)
	--	
	--	--local vaults = e.surface.find_entities_filtered{name=g.VAULT_NAME, position=e.position, radius=g.VAULT_DEFENSE_RADIUS()}
	--	for _,v in pairs(vaults) do
	--	--for _,v in pairs(e.surface.find_entities_filtered{name=g.VAULT_NAME, position=e.position, radius=g.VAULT_DEFENSE_RADIUS()}) do
	--		local vault = Vault.from_entity(v)
	--		vault.extra_ore_drain = vault.extra_ore_drain + INF_SCRAP_DEPLETE_BUMP_AMOUNT * DRAIN_TO_ORE["vault-scrap"]
	--	end
	--end
end)
script.on_nth_tick(60*10, function(event)
	--local drains = {}

	local player = game.get_player(1) ---@cast player -nil
	for _,drill in pairs(player.surface.find_entities_filtered{type="mining-drill", position=player.position, radius=20}) do
		lone_drills[drill.unit_number] = lone_drills[drill.unit_number] or { e = drill }
	end

	for uid,drill in pairs(lone_drills) do
		local drill_e = drill.e
		if not drill_e.valid then
			lone_drills[uid] = nil
		else
			local position = drill_e.position
			local r = g.max_drill_radius -- square radius!
			local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
			local nearby_ore = drill_e.surface.find_entities_filtered{name=g.SCRAP_TYPES, area=area}
			local normal = INF_SCRAP_NORMAL

			local total_amount = 0
			local total_mining_rate = 0
			for _,ore in pairs(nearby_ore) do
				local amount = ore.amount
				total_amount = total_amount + amount
				
				local ore_key = int_position_key(ore.position)
				local last_amount = ore_cache[ore_key] or amount -- todo: adjust last amount on deplection bump, not extra_drain
				ore_cache[ore_key] = amount

				if amount < last_amount then
					-- est mining rate based on drain, this does not take into account big drill drain% bonus (nor productivity)
					-- for infinite resources, drain done 1x per mining op (reduced by drain%)
					-- but only while yield is about 100%, below that there is an RNG roll that futher skips drain events
					-- this is likely to make drain proportional with actual production yield
					-- because drain events are unlikely at low yields, tracking mining rate becomes less accurate (but hopefully evens out over while patch total?)
					local drain = last_amount - amount
					if ore.name == "scrap" then
						total_mining_rate = total_mining_rate + drain
					else
						-- est entire timestep based on current yield
						local yield = amount / normal
						total_mining_rate = total_mining_rate + (yield < 1 and drain / yield or drain) -- TODO: whats's faster: math.max or this 
					end
				end
			end

			local latest_drain = (drill.last_count or 0) - total_amount + (drill.extra_drain or 0)
			latest_drain = latest_drain / 10 * 60 -- per minute
			
			drill.latest_mining_rate = total_mining_rate / 10 * 60 -- per minute
			drill.last_count = total_amount
			
			game.print("drain: "..serpent.line{uid=uid, drill=drill, latest_drain=latest_drain, ore_cache=ore_cache})
			
			drill.extra_drain = 0
		end
	end

	--game.print("drains: "..serpent.line(drains))
end)

---@param surface LuaSurface
---@param where MapPosition|"all"
---@param radius? number
---@return string
function Vault.restore_destroyed_vaults(surface, where, radius)
	
	game.print("Respawning destroyed vaults...")

	local fake_surfase = Vault.recreate_initial_surface_and_load_chunks(surface, where, radius)
	
	local initial_vaults = where == "all" and
		fake_surfase.find_entities_filtered{name=g.VAULT_NAME} or
		fake_surfase.find_entities_filtered{position=where, radius=radius, name=g.VAULT_NAME}

	-- this is conventient, but ignores existing vaults and just overlaps them
	--fake_surfase.clone_entities{entities=initial_vaults,
	--	destination_offset={0,0}, destination_surface=surface,
	--	snap_to_grid = false,
	--	create_build_effect_smoke=true}
	
	for _,v in pairs(initial_vaults) do
		if surface.find_entity(g.VAULT_NAME, v.position) == nil then
			-- Missing entity!
			-- need to use create_entity() not Entity.clone(), as described above
			local new_vault = surface.create_entity{
				name = v.name, position = v.position,
				raise_built = true, -- trigger built event to init vault
				move_stuck_players = true,
				preserve_ghosts_and_corpses = true,
				create_build_effect_smoke = true, -- this is nice as feedback
			}
			
			-- Print for user
			game.print("Respawned vault ".. serpent.line{new_vault})
		end
	end

	return "success"

	---- This version does not actually work if player entities or even ghosts are in the way, this is not really what I had in mind...
	--local chunks = {}
	--if where ~= "all" then
	--	local p = where
	--	local cp = { x=math.floor(p.x/32), y=math.floor(p.y/32) }
	--	chunks = { -- player chunk and neighbours
	--		{cp.x-1, cp.y-1}, {cp.x, cp.y-1}, {cp.x+1, cp.y-1},
	--		{cp.x-1, cp.y  }, cp,             {cp.x+1, cp.y  },
	--		{cp.x-1, cp.y+1}, {cp.x, cp.y+1}, {cp.x+1, cp.y+1},
	--	}
	--end
	--
	--if surface then
	--	--surface.regenerate_decorative(g.VAULT_NAME, chunks) -- vaults are not decorations (at least my version?)
	--	surface.regenerate_entity(g.VAULT_NAME, chunks)
	--	-- regenerate_entity does not return sucess or number of entities actually added!
	--end
	---- TODO: recreate_initial_surface_and_load_chunks
	--
	--return "success"
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
	--local near_ore_tiles = surf.find_entities_filtered{type="resource", name=g.SCRAP_TYPES,
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
	local ore_tiles = surface.find_entities_filtered{type="resource", name=g.SCRAP_TYPES, area=area}
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
