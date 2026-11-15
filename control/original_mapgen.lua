local const = require("const")
local common = require("control.common")
local util = require("util")
local myutil = require("lib.myutil")

local original_mapgen = {}

-- named noise expression from vanilla fulgora mapgen
-- =1 around vault islands (lots of space of oil ocean is included)
-- vanilla scrap autoplace uses it for the vault scrap (which is actual circular patch under vault + random noise-based patches elsewhere), both are ~100k per tile
-- =0 is other islands with only noise-based scrap at about 1k counts (I think)
local VAULT_MASK_NOISE = "fulgora_vaults_and_starting_vault"

--#region Fake surfaces

---@alias FakeSurfaces table<string, MapTick> -- fake surface name -> keep until tick

-- hidden copy of a real surface (its current map_gen_settings) to read the original mapgen state (vault positions, original ore amounts)
-- generic per real surface: named FAKE_PREFIX..real name ("hexcoder_fake_fulgora"), storage.fake_surfaces[fake name] = keep until tick
-- kept for some seconds after the last use, so multiple requests (overlapping vaults, init) share one generation
local FAKE_PREFIX = "hexcoder_fake_"
local DELETED_PREFIX = "hexcoder_deleted_fake_" -- must not start with FAKE_PREFIX
local FAKE_KEEP_TICKS = const.ORE_POLL_PERIOD+60

-- game.delete_surface is queued until the end of the tick, rename first so the name is free for a new fake surface right away
-- surface names must be unique or we crash, so include the surface index, which is unique among existing surfaces
---@param fake_surface LuaSurface
local function delete_surface_now(fake_surface)
	if const.DEBUG then
		log(dbg_print(string.format("Deleted surface %s (%d)", fake_surface.name, fake_surface.index)))
	end
	fake_surface.name = DELETED_PREFIX..fake_surface.index
	game.delete_surface(fake_surface)
end

---@param name string -- fake surface name, or the real surface name (auto prefixed)
function original_mapgen.delete_fake_surface(name)
	if string.sub(name, 1, #FAKE_PREFIX) ~= FAKE_PREFIX then
		name = FAKE_PREFIX..name
	end
	local fake_surface = game.surfaces[name]
	if fake_surface ~= nil then
		delete_surface_now(fake_surface)
	end
	local fake_surfaces = storage.fake_surfaces
	if fake_surfaces then
		fake_surfaces[name] = nil
	end
end

-- all fake surfaces, including stale ones storage does not know about, for reset and uninstall
function original_mapgen.delete_all_fake_surfaces()
	local fake_names = {}
	for _,surface in pairs(game.surfaces) do
		if string.sub(surface.name, 1, #FAKE_PREFIX) == FAKE_PREFIX then
			fake_names[#fake_names+1] = surface.name -- collect first, renaming changes game.surfaces
		end
	end
	for _,name in ipairs(fake_names) do
		original_mapgen.delete_fake_surface(name)
	end
	storage.fake_surfaces = nil -- also entries whose surface is already gone
end

-- actually delete fake surfaces after multiple requests could use them (unused for some seconds)
script.on_nth_tick(60, function(event)
	local fake_surfaces = storage.fake_surfaces
	if fake_surfaces == nil then return end
	for name, tick in pairs(fake_surfaces) do
		if event.tick > tick then
			original_mapgen.delete_fake_surface(name) -- clears fake_surfaces[name], assigning nil to an existing key is fine while iterating
		end
	end
end)

-- create a new fake surface with copied map_gen_settings from real_surface
-- use previously generated version if it has not been auto-deleted, to hopefully improve performance
-- recreate it if it is stale, its chunks would have wrong positions/amounts (and its vault-scrap is gone if the mod was removed while it existed):
--  not in storage: non-clean uninstall, storage reset, mod re-added (storage existance should match surface existance)
--  map_gen_settings differ from the real surface: inf scrap autoplace switched (update_autoplace_settings), editor changes
-- delete_fake_surface then recreate_surface_safe on the same tick is fine, delete_surface_now frees the name
---@param real_surface LuaSurface
---@return LuaSurface fake_surface
local function recreate_surface_safe(real_surface)
	local fake_name = FAKE_PREFIX..real_surface.name
	local fake_surfaces = storage.fake_surfaces
	if fake_surfaces == nil then
		fake_surfaces = {}
		storage.fake_surfaces = fake_surfaces
	end
	local mgs = real_surface.map_gen_settings

	local fake_surface = game.surfaces[fake_name]
	if fake_surface ~= nil then
		local stale = fake_surfaces[fake_name] == nil -- fake surface found that we don't remember
			or not util.table.compare(fake_surface.map_gen_settings, mgs) -- map_gen_settings differ
		if stale then
			original_mapgen.delete_fake_surface(fake_name)
			fake_surface = nil
		end
	end

	if fake_surface == nil then
		-- tried trimming the autoplace (only scrap and vaults, no decoratives/cliffs): changes positions and amounts (even vault count) and is not faster
		fake_surface = game.create_surface(fake_name, mgs)

		if const.DEBUG then
			log(dbg_print(string.format("Created surface %s (%d)", fake_surface.name, fake_surface.index)))
		end
	end

	-- do not delete fake surface in case multiple requests are made
	-- hopefully better perf? and safer?
	fake_surfaces[fake_name] = game.tick + FAKE_KEEP_TICKS
	return fake_surface
end
--#endregion

--#region Chunk selection for recreate_initial_surface_and_load_chunks
-- only chunks generated on the real surface: ore elsewhere does not exist yet (mapgen creates it correctly later), so there is nothing to compare or restore
-- returned as lists (no generators, coroutines are not available in factorio), so the caller can skip creating the fake surface for 0 chunks

-- all generated chunks of the real surface (benchmark/verification)
---@param real_surface LuaSurface
---@return ChunkPosition[]
function original_mapgen.all_chunks(real_surface)
	local chunks = {}
	for cpos in real_surface.get_chunks() do
		if real_surface.is_chunk_generated(cpos) then
			chunks[#chunks+1] = cpos
		end
	end
	return chunks
end

-- generated chunks that a test shows have vault islands tiles (4x4 grid of VAULT_MASK_NOISE test points per chunk)
-- vaults and vault scrap only exist there, the mask includes a lot of ocean around the islands, so scrap is well inside, this test should be unlikely to miss any scrap meant for vaults
-- this should skip at least 50% of chunks to generate and actually speeds the the fake surface mapgen up by about 2x
---@param real_surface LuaSurface
---@return ChunkPosition[]
function original_mapgen.vault_island_chunks(real_surface)
	local prof_filter = helpers.create_profiler()
	local chunks, positions = {}, {}
	for cpos in real_surface.get_chunks() do
		if real_surface.is_chunk_generated(cpos) then
			chunks[#chunks+1] = cpos
			local x, y = cpos.x*32, cpos.y*32
			for gy = 4, 28, 8 do
				for gx = 4, 28, 8 do
					positions[#positions+1] = {x=x+gx, y=y+gy}
				end
			end
		end
	end

	local island_chunks = {}
	if next(positions) then
		-- one batched query for all chunks, 16 points each
		local mask = real_surface.calculate_tile_properties({VAULT_MASK_NOISE}, positions)[VAULT_MASK_NOISE]
		assert(mask, "calculate_tile_properties does not know "..VAULT_MASK_NOISE)
		for i,cpos in ipairs(chunks) do
			for j = (i-1)*16+1, i*16 do
				if mask[j] > 0.5 then
					island_chunks[#island_chunks+1] = cpos
					break
				end
			end
		end
	end

	prof_filter.stop()
	if const.DEBUG then
		log(dbg_print{"", string.format("Vault island filter (%d of %d chunks): ", #island_chunks, #chunks), prof_filter})
	end
	return island_chunks
end

-- generated chunks touching the circle (was request_to_generate_chunks(position, radius/32+1), a larger square)
-- +1 tile margin, find_entities_filtered with radius also finds resources whose bounding box touches the circle
-- measured (/fulg-bench-chunks, radius 55): request radius is a square centered on the position's chunk, only requested chunks get entities,
--  but every generated area gets a 3 chunk deep ring of partially generated chunks (~60ms for a single chunk, then ~4-5ms per extra chunk)
--  so one request per chunk costs nothing extra, the bounding square was already 16 instead of 25 chunks (133 vs 173ms)
---@param real_surface LuaSurface
---@param position MapPosition
---@param radius number
---@return ChunkPosition[]
function original_mapgen.chunks_in_radius(real_surface, position, radius)
	local chunks = {}
	local r = radius + 1
	local px, py = position.x, position.y
	local y0 = math.floor((py - r) / 32)
	local y1 = math.floor((py + r) / 32)
	local x0 = math.floor((px - r) / 32)
	local x1 = math.floor((px + r) / 32)
	for cy = y0, y1 do
		for cx = x0, x1 do
			-- skip corner chunks of the bounding square the circle does not reach: nearest point of the chunk to position
			local nearest = {
				x = math.min(math.max(px, cx*32), cx*32+32),
				y = math.min(math.max(py, cy*32), cy*32+32),
			}
			local cpos = {x=cx, y=cy}
			if myutil.check_distance(position, nearest, r) and real_surface.is_chunk_generated(cpos) then
				chunks[#chunks+1] = cpos
			end
		end
	end
	return chunks
end

-- Recreate the initial surface as a hidden temporary surface to base ore counts off and to restore destroyed vaults or depleted ores
-- can be slow, should be avoided in regular modded playthrough
-- the fake surface is only created if there is at least one chunk (fulgora may exist without generated chunks yet, e.g. fulgora start during init)
---@param real_surface LuaSurface
---@param chunks ChunkPosition[] -- original_mapgen.vault_island_chunks / original_mapgen.chunks_in_radius / original_mapgen.all_chunks
---@return LuaSurface? fake_surface -- nil if there are no chunks to generate
function original_mapgen.recreate_initial_surface_and_load_chunks(real_surface, chunks)
	--game.print("regenerating fulgora entities, please be patient...") obviously this won't be seen until this is done

	if next(chunks) == nil then return nil end

	local fake_surface = recreate_surface_safe(real_surface)

	-- the find_entities_filtered we want to do on this surface won't generate chunks for us, we need to call request_to_generate_chunks
	-- no-op for chunks the reused surface already has
	for _,cpos in ipairs(chunks) do
		fake_surface.request_to_generate_chunks({ cpos.x*32+16, cpos.y*32+16 })
	end
	fake_surface.force_generate_chunk_requests()

	return fake_surface
end
--#endregion

--#region Whole map restore

-- add or remove vault-scrap in the surface autoplace settings, only affects chunks generated later
-- data stage does this for the planet, but an existing surface keeps the settings it was created with
---@param surface LuaSurface
function original_mapgen.update_autoplace_settings(surface)
	local mgs = surface.map_gen_settings
	local settings = mgs.autoplace_settings.entity.settings
	if (settings["vault-scrap"] ~= nil) ~= const.INF_SCRAP_ENABLED then
		-- runtime AutoplaceControl needs all fields, copy the scrap one (also keeps per-surface scrap settings)
		settings["vault-scrap"] = const.INF_SCRAP_ENABLED and (settings["scrap"] or {frequency=1, size=1, richness=1}) or nil
		surface.map_gen_settings = mgs
		
		-- no need to delete the fake surface here, recreate_surface_safe recreates it when the map_gen_settings differ (and can now do that on the same tick)
		--original_mapgen.delete_fake_surface(surface.name)
	end
end

-- swap ores between normal and infinite variant on surface
-- by checking all given orig_ores from recreated (fake) surface, deleting their equivalents on surface and spawning new ones of the <to> type
-- check if the ores are scrap on a vault island (specific to fulgora, but could make this generic)
-- tries to keep amount the same, but if 0 on surface (tile is actually missing), it restores it
-- also enforces correct minimum for infinite ores and assigns their initial_amount to the amount from the fake surface
-- ore trackers need no reset, amounts stay the same (or get raised to the infinite minimum, which does not count as mined)
-- does not update drills
---@param surface LuaSurface
---@param orig_ores LuaEntity[] -- from fake fulgora
---@param to "scrap"|"vault-scrap"
---@return integer converted
local function convert_ores(surface, orig_ores, to)
	local converted = 0
	if #orig_ores == 0 then return 0 end

	local positions = {}
	for i,e in ipairs(orig_ores) do
		positions[i] = e.position
	end
	local mask = surface.calculate_tile_properties({VAULT_MASK_NOISE}, positions)[VAULT_MASK_NOISE]
	assert(mask, "calculate_tile_properties does not know "..VAULT_MASK_NOISE)

	for i,orig_ore in ipairs(orig_ores) do
		if mask[i] > 0.5 then
			local position = positions[i]
			-- measured: same speed as find_entity, a prebuilt position key lookup was slower
			local old_ore = surface.find_entities_filtered{position=position, type="resource", name=const.SCRAP_TYPES}[1]

			-- fake fulgora may have chunks the surface does not, never create ore there
			if old_ore == nil and not surface.is_chunk_generated{x=math.floor(position.x / 32), y=math.floor(position.y / 32)} then
				-- can't create scrap in non-generated chunks (I think)
			elseif old_ore == nil or old_ore.name ~= to then
				-- ore drained or wrong type
				local amount = old_ore and old_ore.amount or 0 -- nil: fully drained finite tile
				local initial
				if to == "vault-scrap" then
					-- same rules as ore.restore_ore: initial is the original amount (raised if current is higher)
					-- amount raised to minimum + bump, or on_resource_depleted never gets called and the estimation will be wrong
					initial = math.max(orig_ore.amount, amount)
					-- also bump this to be safe, don't want amount > initial
					if initial < common.INF_SCRAP_MIN then initial = common.INF_SCRAP_MIN + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT end
					-- enforce correct minimum + bump to make sure on_resource_depleted still triggers
					local minimum = common.get_inf_scrap_minimum(initial) + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
					if amount < minimum then amount = minimum end
				end
				
				if old_ore then
					old_ore.destroy()
				end
				if amount > 0 then -- drained finite tile stays drained
					local new_ore = surface.create_entity{name=to, position=position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast new_ore -nil
					if initial then
						new_ore.initial_amount = initial -- before amount, the minimum depends on it
					end
					new_ore.amount = amount

					converted = converted + 1
				end
			end
		end
	end
	
	--game.print("convert_ores: ".. serpent.line{converted=converted, num_orig_ores=#orig_ores})
	--log("convert_ores: ".. serpent.line{converted=converted, num_orig_ores=#orig_ores})
	
	return converted
end

-- swap scrap on vault islands to the inf scrap setting, around where or on the whole map
-- one find on fake fulgora and one mask query, measured ~2.5x faster than per chunk
---@param surface LuaSurface
---@param fake_surface LuaSurface -- with the chunks generated
---@param to "scrap"|"vault-scrap"
---@param where MapPosition|"all"
---@param radius? number
---@return integer converted
local function convert_vault_scrap(surface, fake_surface, to, where, radius)
	local orig_ores = where == "all" and
		fake_surface.find_entities_filtered{type="resource", name=const.SCRAP_TYPES} or
		fake_surface.find_entities_filtered{position=where, radius=radius, type="resource", name=const.SCRAP_TYPES}

	local converted = convert_ores(surface, orig_ores, to)
	if converted > 0 then
		if where == "all" then
			for _,drill in pairs(surface.find_entities_filtered{type="mining-drill"}) do
				drill.update_connections()
			end
		else
			common.update_drill_connections_near(surface, where, radius)
		end
	end
	return converted
end

-- respawn destroyed vaults, around where or on the whole map
---@param surface LuaSurface
---@param fake_surface LuaSurface
---@param where MapPosition|"all"
---@param radius? number
---@return integer respawned
local function respawn_vaults(surface, fake_surface, where, radius)
	local respawned = 0

	local initial_vaults = where == "all" and
		fake_surface.find_entities_filtered{name=const.VAULT_NAME} or
		fake_surface.find_entities_filtered{position=where, radius=radius, name=const.VAULT_NAME}

	-- this is conventient, but ignores existing vaults and just overlaps them
	--fake_surfase.clone_entities{entities=initial_vaults,
	--	destination_offset={0,0}, destination_surface=surface,
	--	snap_to_grid = false,
	--	create_build_effect_smoke=true}

	for _,v in pairs(initial_vaults) do
		if surface.find_entity(const.VAULT_NAME, v.position) == nil then
			-- Missing entity!
			-- need to use create_entity() not Entity.clone(), as described above
			local new_vault = surface.create_entity{
				name = v.name, position = v.position,
				raise_built = true, -- trigger built event to init vault
				move_stuck_players = true,
				preserve_ghosts_and_corpses = true,
				create_build_effect_smoke = true, -- this is nice as feedback
			}

			-- Print for user, gps tag is clickable in chat
			local p = v.position
			log(dbg_print(string.format("Respawned vault ruin at [gps=%d,%d,%s]", math.floor(p.x), math.floor(p.y), surface.name)))
			respawned = respawned + 1
		end
	end

	return respawned

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
	--	--surface.regenerate_decorative(const.VAULT_NAME, chunks) -- vaults are not decorations (at least my version?)
	--	surface.regenerate_entity(const.VAULT_NAME, chunks)
	--	-- regenerate_entity does not return sucess or number of entities actually added!
	--end
	--
	--return "success"
end

-- everything needed when the mod is added to a running game, updated, or the inf scrap setting changed
-- slow (fake fulgora for every generated chunk), freezes the game
---@param surface LuaSurface
function original_mapgen.convert_ore_and_restore_vaults(surface)
	-- before the fake surface gets created, it copies the settings
	original_mapgen.update_autoplace_settings(surface)

	local prof_total = helpers.create_profiler()
	local prof_fake = helpers.create_profiler()
	local chunks = original_mapgen.vault_island_chunks(surface)
	local fake_surface = original_mapgen.recreate_initial_surface_and_load_chunks(surface, chunks)
	prof_fake.stop()
	if fake_surface == nil then
		-- no generated vault island chunks yet (fulgora without chunks), mapgen creates vaults and scrap with the current settings
		if const.DEBUG then
			log(dbg_print("Ore conversion skipped: no generated vault island chunks"))
		end
		return
	end

	local prof_scrap = helpers.create_profiler()
	local converted = convert_vault_scrap(surface, fake_surface, const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap", "all")
	prof_scrap.stop()

	-- after conversion, so trackers of respawned vaults (built event) start from converted ore
	local prof_vaults = helpers.create_profiler()
	local respawned = respawn_vaults(surface, fake_surface, "all")
	prof_vaults.stop()

	prof_total.stop()

	-- always print, also outside of debug: the game froze for this, the time tells the user why (profiler text is fixed "Duration: ...ms", so only once)
	log(dbg_print{"", string.format("Checked vault ruins and scrap on %d chunks: converted %d tiles to %s, respawned %d vault ruins. ",
		#chunks, converted, const.INF_SCRAP_ENABLED and "infinite" or "finite", respawned), prof_total})
	if const.DEBUG then
		log(dbg_print{"", "Fake surface: ", prof_fake, ", ore conversion: ", prof_scrap, ", vault respawn: ", prof_vaults})
	end
end
--#endregion

--#region Missing vault experiments
-- experimental way of spawning vaults in rare case where vault island is missing its ruin
--[[
---@param surface LuaSurface
---@param area BoundingBox
---@param ore_tiles LuaEntity[]
local function try_place_missing_vault_ruin2(surface, area, ore_tiles)
	--local prof = helpers.create_profiler()
	
	-- scan more ore around the chunk, I think this makes sense
	--local r = 10
	--local near_ore_tiles = surf.find_entities_filtered{type="resource", name=const.SCRAP_TYPES,
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
		local near_vaults = surface.find_entities_filtered{name=const.VAULT_NAME, position=pos, radius=25}
		if next(near_vaults) then
			-- chunk area did not contain a vault, but in neighbouring chunk (next to suitable vault pos) there already is one
			found = nil
		end
	end
	
	if found then
		--game.print("Spawning missing vault ruin: "..serpent.line(found))
		
		local bb = prototypes.entity[const.VAULT_NAME].collision_box
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
			
			local vault = surface.create_entity{name=const.VAULT_NAME, position=pos, snap_to_grid=false, raise_built=true, move_stuck_players=true} -- preserve_ghosts_and_corpses ?
			if vault ~= nil then
				game.print(const.PRINT_PREFIX.."Spawned missing vault ruin: "..serpent.line(vault))
			end
		end
	end
	
	--prof.stop()
	--game.print(prof)
end

---@param surface LuaSurface
---@param area BoundingBox
function original_mapgen.try_place_missing_vault_ruin(surface, area)
	--local prof = helpers.create_profiler()
	
	-- no vault ruin, count total scrap in chunk
	local count = 0
	local ore_tiles = surface.find_entities_filtered{type="resource", name=const.SCRAP_TYPES, area=area}
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
--#endregion

return original_mapgen
