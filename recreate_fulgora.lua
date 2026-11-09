local const = require("const")
local common = require("control.common")

local M = {}

-- named noise expression from vanilla fulgora mapgen
-- =1 around vault islands (lots of space of oil ocean is included)
-- vanilla scrap autoplace uses it for the vault scrap (which is actual circular patch under vault + random noise-based patches elsewhere), both are ~100k per tile
-- =0 is other islands with only noise-based scrap at about 1k counts (I think)
local VAULT_MASK_NOISE = "fulgora_vaults_and_starting_vault"

-- Recreate the initial fulgora surface as a hidden temporary surface to base ore counts off and to restore destroyed vaults or depleted ores
-- can be slow, should be avoided in regular modded playthrough
-- "all": only chunks on vault islands (4x4 grid of VAULT_MASK_NOISE test points per chunk), unless all_chunks
--   vaults and vault scrap only exist there, the mask includes a lot of ocean around the islands, so scrap is well inside
---@param original_fulgora LuaSurface
---@param where MapPosition|"all"
---@param radius? number
---@param all_chunks? boolean -- "all" without the vault island filter (benchmark/verification)
---@return LuaSurface
---@return integer? requested -- chunks requested for "all"
function M.recreate_initial_surface_and_load_chunks(original_fulgora, where, radius, all_chunks)
	--game.print("regenerating fulgora entities, please be patient...") obviously this won't be seen until this is done

	-- lazy create surface
	local fake_surface = game.surfaces["hexcoder_fake_fulgora"]
	if fake_surface == nil then
		-- tried trimming the autoplace (only scrap and vaults, no decoratives/cliffs): changes positions and amounts (even vault count) and is not faster
		-- should not matter if map_gen_settings with or without inf-scrap is used, so hopefully reusing old fake_surface is fine
		fake_surface = game.create_surface("hexcoder_fake_fulgora", original_fulgora.map_gen_settings)
	end
	
	-- find_entities_filtered on this surface won't generate chunks for us, we need to do this
	local requested
	if where == "all" then
		-- all chunks on map
		local prof_filter = helpers.create_profiler()
		requested = 0
		if all_chunks then
			-- generate all chunks that real surface has
			for cpos in original_fulgora.get_chunks() do
				if original_fulgora.is_chunk_generated(cpos) then
					fake_surface.request_to_generate_chunks({ cpos.x*32+16, cpos.y*32+16 })
					requested = requested + 1
				end
			end
		else
			local chunks, positions = {}, {}
			-- generate all chunks that a test shows have vault islands tiles, this test should be unlikely to miss any scrap meant for vaults
			for cpos in original_fulgora.get_chunks() do
				if original_fulgora.is_chunk_generated(cpos) then
					chunks[#chunks+1] = cpos
					local x, y = cpos.x*32, cpos.y*32
					for gy = 4, 28, 8 do
						for gx = 4, 28, 8 do
							positions[#positions+1] = {x=x+gx, y=y+gy}
						end
					end
				end
			end
			
			if next(positions) then
				-- one batched query for all chunks, 16 points each
				local mask = original_fulgora.calculate_tile_properties({VAULT_MASK_NOISE}, positions)[VAULT_MASK_NOISE]
				assert(mask, "calculate_tile_properties does not know "..VAULT_MASK_NOISE)
				for i,cpos in ipairs(chunks) do
					for j = (i-1)*16+1, i*16 do
						if mask[j] > 0.5 then
							fake_surface.request_to_generate_chunks({ cpos.x*32+16, cpos.y*32+16 })
							requested = requested + 1
							break
						end
					end
				end
			end
		end
		
		prof_filter.stop()
		if const.DEBUG then
			log({"", const.PRINT_PREFIX, string.format("fake fulgora: requested %d chunks, vault island filter ", requested), prof_filter})
		end
	else
		-- generate around "where", is radius square or circular?
		fake_surface.request_to_generate_chunks(where, radius/32+1)
	end
	fake_surface.force_generate_chunk_requests()
	
	-- do not delete fake fulgora in case multiple requests are made
	-- hopefully better perf? and safer?
	-- actually queued to be deleted, so multiple requests should be fine, maybe just worse perf if used every few seconds
	storage.last_used_fake_fulgora = game.tick

	if const.DEBUG then
		game.print(const.PRINT_PREFIX.."Created fake fulgora")
	end
	return fake_surface, requested
end
function M.delete_fake_fulgora()
	local fake_surface = game.surfaces["hexcoder_fake_fulgora"]
	if fake_surface ~= nil then
		game.delete_surface("hexcoder_fake_fulgora")
		storage.last_used_fake_fulgora = nil
		
		if const.DEBUG then
			game.print(const.PRINT_PREFIX.."Deleted fake fulgora")
		end
	end
end
-- actually delete fake fulgora after multiple requests could use it (unused for some seconds)
script.on_nth_tick(60, function(event)
	local last_use = storage.last_used_fake_fulgora
	if last_use and event.tick - last_use > const.ORE_POLL_PERIOD+60 then
		M.delete_fake_fulgora()
	end
end)


---- Whole map restore

-- add or remove vault-scrap in the surface autoplace settings, only affects chunks generated later
-- data stage does this for the planet, but an existing surface keeps the settings it was created with
---@param surface LuaSurface
function M.update_autoplace_settings(surface)
	local mgs = surface.map_gen_settings
	local settings = mgs.autoplace_settings.entity.settings
	if (settings["vault-scrap"] ~= nil) ~= const.INF_SCRAP_ENABLED then
		-- runtime AutoplaceControl needs all fields, copy the scrap one (also keeps per-surface scrap settings)
		settings["vault-scrap"] = const.INF_SCRAP_ENABLED and (settings["scrap"] or {frequency=1, size=1, richness=1}) or nil
		surface.map_gen_settings = mgs
		
		-- delete to be sure recreate_initial_surface_and_load_chunks() generates correct surface, but we check both SCRAP_TYPES here anyway
		-- actually this is bad because it keep existing for this tick, ugh...
		--M.delete_fake_fulgora()
	end
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

			-- Print for user
			game.print(const.PRINT_PREFIX.."Respawned vault ".. serpent.line{new_vault})
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
	---- TODO: recreate_initial_surface_and_load_chunks
	--
	--return "success"
end

-- swap the given original (fake fulgora) tiles to the inf scrap setting, if they are on a vault island
-- iterates the original tiles, so fully drained finite tiles come back as infinite (at minimum)
-- keeps amounts, infinite initial_amount from the original amount
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
				-- skip
			elseif old_ore == nil or old_ore.name ~= to then
				local amount = old_ore and old_ore.amount or 0 -- nil: fully drained finite tile
				local initial
				if to == "vault-scrap" then
					-- same rules as ore.restore_ore: initial is the original amount (raised if current is higher)
					-- amount raised to minimum + bump, or on_resource_depleted never gets called and the estimation will be wrong
					initial = math.max(orig_ore.amount, amount)
					if initial < common.INF_SCRAP_MIN then initial = common.INF_SCRAP_MIN + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT end -- important to avoid depth bug (?)
					local minimum = common.get_inf_scrap_minimum(initial) + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
					if amount < minimum then amount = minimum end
				end

				if amount > 0 then -- drained finite tile stays drained
					if old_ore then
						old_ore.destroy()
					end
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

-- everything needed when the mod is added to a running game, updated, or the inf scrap setting changed
-- slow (fake fulgora for every generated chunk), freezes the game
---@param surface LuaSurface
function M.convert_ore_and_restore_vaults(surface)
	-- before fake fulgora gets created, it copies the settings
	M.update_autoplace_settings(surface)

	local prof_fake = helpers.create_profiler()
	local fake_surface = M.recreate_initial_surface_and_load_chunks(surface, "all")
	prof_fake.stop()

	local prof_scrap = helpers.create_profiler()
	local converted = convert_vault_scrap(surface, fake_surface, const.INF_SCRAP_ENABLED and "vault-scrap" or "scrap", "all")
	prof_scrap.stop()

	-- after conversion, so trackers of respawned vaults (built event) start from converted ore
	local prof_vaults = helpers.create_profiler()
	local respawned = respawn_vaults(surface, fake_surface, "all")
	prof_vaults.stop()

	game.print({"", const.PRINT_PREFIX, "restored map, fake fulgora ", prof_fake})
	log({"", const.PRINT_PREFIX, "restored map, fake fulgora ", prof_fake})
	game.print({"", const.PRINT_PREFIX, string.format("respawned %d vaults ", respawned), prof_vaults})
	log({"", const.PRINT_PREFIX, string.format("respawned %d vaults ", respawned), prof_vaults})
	game.print({"", const.PRINT_PREFIX, string.format("converted %d vault scrap tiles to %s ", converted, const.INF_SCRAP_ENABLED and "infinite" or "finite"), prof_scrap})
	log({"", const.PRINT_PREFIX, string.format("converted %d vault scrap tiles to %s ", converted, const.INF_SCRAP_ENABLED and "infinite" or "finite"), prof_scrap})
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
function M.try_place_missing_vault_ruin(surface, area)
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


return M
