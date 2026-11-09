local const = require("const")
local common = require("control.common")
local recreare_fulgora = require("recreate_fulgora")

local ore = {}

local INF_SCRAP_PROTO = prototypes.entity["vault-scrap"]
local INF_SCRAP_NORMAL = INF_SCRAP_PROTO.normal_resource_amount
local INF_SCRAP_MIN = INF_SCRAP_PROTO.minimum_resource_amount
local INF_SCRAP_MIN_RATIO = INF_SCRAP_MIN / INF_SCRAP_NORMAL

-- try to bump such that its not visible in gui (yield floored to %)
local INF_SCRAP_DEPLETED_BUMP_AMOUNT = math.max(math.floor(INF_SCRAP_PROTO.normal_resource_amount / 100 / 2), 1)

-- we drain faster so inf scrap does not last 100h until it reaches minimum, this does not change yield (other than reducing yield faster)
local INF_SCRAP_DEPLETION_TO_MINING = 1 / INF_SCRAP_PROTO.infinite_depletion_resource_amount -- == const.INF_DEPLETION_RATE

-- infinite resource minimum amount is actually increased if initial yield > 100%
---@param initial_amount integer
local function get_inf_scrap_minimum(initial_amount)
	if initial_amount <= INF_SCRAP_NORMAL then
		return INF_SCRAP_MIN -- 20% of normal
	else
		return math.floor(initial_amount * INF_SCRAP_MIN_RATIO) -- 20% of initial amount, is floored correct?
	end
end

-- update drills which touch tile at position, or in position+square radius (for vault)
---@param surface LuaSurface
---@param position MapPosition
---@param radius? number -- default to 0
function ore.update_drill_connections_near(surface, position, radius)
	local r = const.max_drill_radius + (radius or 0) -- square radius!
	local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
	-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
	for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
		--local p = drill.position
		--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
		drill.update_connections()
	end
end

---- Per-vault ore tracking

---@class OreScan
-- amount of mining since last commit()
-- mining is proportional to mining speed
--  does not account for big drill drain%, prod modules or prod research, or mining results that are not 1 ore
-- its based on observed resource drain, but also taking into account reduced drain for infinite ores below 100% remaining yield
---@field total_mined number
---@field total_remaining number
---@field total_initial number
---@field total_for_depth number
---@field _amounts table<integer, number> -- returned for commit to work, callers should prefer to not touch it

---@class OreTracking
---@field amounts table<tile_key, number> -- amount at last commit
---@field depleted_finite table<tile_key, true> -- mined out finite tiles (set in on_resource_depleted), needed to sum initial in storage.finite_initial
local OreTracking = {}
OreTracking.__index = OreTracking
ore.OreTracking = OreTracking

---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param update_initial? boolean -- see reset
---@return OreTracking
function OreTracking.new(surface, position, radius, update_initial)
	local self = setmetatable({ amounts = {}, tick = game.tick, depleted_finite = {} }, OreTracking)
	self:reset(surface, position, radius, update_initial)
	return self
end

-- does not change the mined baseline, safe to call any time (gui)
-- registers finite tiles on first sight
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@return OreScan
function OreTracking:scan(surface, position, radius)
	local old_amounts = self.amounts
	local amounts = {}
	local depleted_finite = self.depleted_finite
	local finite_initial = storage.finite_initial
	local total_mined, total_remaining, total_initial, total_for_depth = 0, 0, 0, 0
	
	-- TODO: does find_entities_filtered skip chunks that are not fully generated yet?
	-- if vault does first ever scan near the edge of the map, we probably could queue chunkgen here and wait on it?
	-- but maybe we just ignore it, should not happen in practice
	
	for _,ore in pairs(surface.find_entities_filtered{type="resource", name=const.SCRAP_TYPES, position=position, radius=radius}) do
		local amount = ore.amount
		local key = common.int_position_key(ore.position)
		local infinite = ore.name == "vault-scrap"
		local prev_amount = old_amounts[key]
		
		if infinite then
			local initial = ore.initial_amount
			total_initial = total_initial + initial
			
			local min_for_depth = get_inf_scrap_minimum(initial) + INF_SCRAP_DEPLETED_BUMP_AMOUNT
			total_for_depth = total_for_depth + (initial - min_for_depth)
			
			total_remaining = total_remaining + (amount - min_for_depth)
		else
			local initial = finite_initial[key]
			if initial == nil then
				-- no recorded initial, assume current amount
				-- happens once vault does a scan for the first time
				initial = amount
				finite_initial[key] = amount
			end
			total_initial = total_initial + initial
			total_for_depth = total_for_depth + initial
			total_remaining = total_remaining + amount
		end
		
		-- recreated by modify_ore, why do this here and not just in modify_ore?
		if depleted_finite[key] then
			depleted_finite[key] = nil
		end
		
		if prev_amount and amount < prev_amount then
			local mined = prev_amount - amount
			if infinite then
				local yield = amount / INF_SCRAP_NORMAL
				if yield < 1 then mined = mined / yield end
				mined = mined * INF_SCRAP_DEPLETION_TO_MINING
			end
			total_mined = total_mined + mined
		end
		
		amounts[key] = amount
	end
	
	for key in pairs(depleted_finite) do
		local initial = finite_initial[key] or 0
		total_initial = total_initial + initial
		total_for_depth = total_for_depth + initial
		
		-- mined out since last commit (amount 0 now)
		total_mined = total_mined + (old_amounts[key] or 0)
	end
	
	return {
		total_mined = total_mined,
		total_remaining = total_remaining,
		total_initial = total_initial,
		total_for_depth = total_for_depth,
		_amounts = amounts,
	}
end

-- start counting mined from this scan
---@param scan OreScan
function OreTracking:commit(scan)
	self.amounts = scan._amounts
	self.tick = game.tick
end

-- take current amounts as baseline without counting anything as mined
-- from_original: also rebuild finite initial amounts and mined out finite tiles from fake fulgora (slow)
--   needed when tiles may have been mined or replaced while not tracked (radius change, existing save, modify_ore)
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param update_initial? boolean
function OreTracking:reset(surface, position, radius, update_initial)
	if update_initial then
		self:update_finite_initial(surface, position, radius)
	end
	
	self.amounts = {}
	self:commit(self:scan(surface, position, radius))
end

-- rebuild finite initial amounts and mined out finite tiles from fake fulgora (slow)
-- needed to catch depleted tiles while they were not tracked (radius increase or new install on existing save)
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
function OreTracking:update_finite_initial(surface, position, radius)
	local finite_initial = storage.finite_initial
	
	local fake_surface = recreare_fulgora.recreate_initial_surface_and_load_chunks(surface, position, radius)
	local initial_ores = fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name="scrap"}
	
	local current = {}
	for _,ore in pairs(surface.find_entities_filtered{type="resource", name="scrap", position=position, radius=radius}) do
		current[common.int_position_key(ore.position)] = ore
	end
	
	local depleted_finite = {}
	for _,orig in pairs(initial_ores) do
		local key = common.int_position_key(orig.position)
		local ore = current[key]
		if ore == nil then
			finite_initial[key] = orig.amount
			depleted_finite[key] = true
		else
			finite_initial[key] = math.max(orig.amount, ore.amount) -- modify_ore restore > 100%
		end
	end
	self.depleted_finite = depleted_finite
end

-- depth ratio (0-1) initial amount - minimum amount for infinite ores (or same percentage for finite ore)
---@param scan OreScan
---@return number
function OreTracking.get_depth(scan)
	if scan.total_for_depth <= 0 then return 0 end
	local depth = 1 - scan.total_remaining / scan.total_for_depth
	return math.min(math.max(depth, 0), 1)
end

script.on_event(defines.events.on_resource_depleted, function(event)
	local ore = event.entity
	local name = ore.name
	if name ~= "vault-scrap" and name ~= "scrap" then return end
	init()
	
	--assert(ore.amount <= get_inf_scrap_minimum(ore.initial_amount)) -- ore can spawn or be created by modify_ore with lower than minimum amount (bumps will make it end up at minimum, I think)
	
	local key = common.int_position_key(ore.position)
	if name == "vault-scrap" then
		-- infinite at minimum: bump so it keeps depleting and mining stays visible to scan
		local bump = INF_SCRAP_DEPLETED_BUMP_AMOUNT
		local old_amount = ore.amount
		ore.amount = old_amount + bump
		
		-- update amounts for each nearby vaults ore tracker
		for _,vault in pairs(storage.vaults) do
			local tracking = vault.scrap
			local prev_amount = tracking and tracking.amounts[key]
			if prev_amount then
				-- accumulate bump, don't set latest amount, as that would forget depletion before this
				-- this way new substraction produces correct result: sum of depletion before and after one or multiple bumps
				tracking.amounts[key] = prev_amount + bump
			end
		end
		
		if const.DEBUG then
			game.print("on_resource_depleted ".. serpent.line{
				old_amount=old_amount,
				bamount=ore.amount,
				initial=ore.initial_amount,
				minimum=ore.prototype.minimum_resource_amount,
				normal=ore.prototype.normal_resource_amount,
				old_yield=old_amount / INF_SCRAP_NORMAL * 100,
				new_yield=ore.amount / INF_SCRAP_NORMAL * 100,
			})
		end
	else
		if const.DEBUG then
			game.print("on_resource_depleted ".. serpent.line{ore})
		end
		
		-- finite ore depleted, removed by the game after this
		-- register it as depleted_finite so scan can keep reading initial count for each vault
		for _,vault in pairs(storage.vaults) do
			local tracking = vault.scrap
			if tracking and tracking.amounts[key] then
				tracking.depleted_finite[key] = true
			end
		end
	end
end)

-- This function can swap out the scrap areound a vault ruin between normal or infinite scrap
-- it can either keep the amount the same or restore it to a desired percentage of the original ore by regenerating a fake nauvis surface
-- there are other ways to potentially check the original ore amount but none that work with both finite ores and when installing on running games etc.
-- when swapping to infinite scrap, the game will show yeild%, but internally keep using the same amount units
-- note: that for infinite ores, the yield % depends on the "normal" amount as defined in the ore prototype
--       and that the actual minimum depends on the initial amount
-- note: restore >100% will inflate the orig_amount to be higher, but <100% will not set it lower
-- TODO: add parameter (and mod setting) to override richness, so that time to reach say, 20% of scrap can be adjusted for finite ores (max quality at 20%?)
--       and for inf ores, the richness would increase the normal amount such that 
---@param vault Vault
---@param mode "finite"|"infinite"
---@param restore number|"keep" -- restore to x percent of initial (mapgen) amount or keep existing amounts
---@param source_event string?
---@return string
function ore.modify_ore(vault, mode, restore, source_event)
	local from = {"scrap", "vault-scrap"}
	local to = mode == "finite" and "scrap" or "vault-scrap"
	
	local position = vault.entity.position
	local surface = vault.entity.surface
	local radius = common.VAULT_DEFENSE_RADIUS()

	local new_count = 0
	local initial_count = 0
	
	-- get old ore before we add new
	local old_ores = surface.find_entities_filtered{type="resource", name=from, position=position, radius=radius}
	
	local fake_surface = recreare_fulgora.recreate_initial_surface_and_load_chunks(surface, position, radius)
	local initial_ores = fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name=const.SCRAP_TYPES}
	
	if restore == "keep" then
		-- a bit weird:
		-- spawn new ore copied from newly generated fake fulgora, then only check old ore tiles for amount
		-- do not iterate old_ore, since tiles may be depleted and infinite ores need their initial_amount set, which works best if accurate
		for _,orig_ore in pairs(initial_ores) do
			local old_ore = surface.find_entities_filtered{name=from, position=orig_ore.position} -- check if get_closest(old_ores, ...) actually makes sense here
			
			local amount = old_ore[1] and old_ore[1].amount or 0
			local orig_amount = orig_ore.amount
			
			local new_initial_amount
			
			if to == "vault-scrap" then
				if orig_amount < INF_SCRAP_MIN then orig_amount = INF_SCRAP_MIN + INF_SCRAP_DEPLETED_BUMP_AMOUNT end -- important to avoid depth bug (?)
				
				new_initial_amount = orig_amount
				-- this enforces minimum if setting to a low percentage
				-- also need to bump if setting amount to under minimum, or on_resource_depleted never gets called and estimation will be wrong!
				local minimum = get_inf_scrap_minimum(new_initial_amount) + INF_SCRAP_DEPLETED_BUMP_AMOUNT -- needs to be called after initial_amount is set!
				if amount < minimum then amount = minimum end
				
				assert(amount <= new_initial_amount)
			end
			
			if amount > 0 then
				local new_ore = surface.create_entity{name=to, position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast new_ore -nil
				
				if new_initial_amount then
					new_ore.initial_amount = new_initial_amount 
				end
				new_ore.amount = amount
			end
			
			if source_event == "on_chunk_generated" then
				--assert(old_ore[1] and amount == orig_amount) -- probably triggers because neighbour chunks are not loaded yet
			end
				
			new_count = new_count + amount
			initial_count = initial_count + orig_amount
		end
	else
		-- spawn new ore copied from newly generated fake fulgora
		-- and simply multiply amount
		for _,orig_ore in pairs(initial_ores) do
			local new_ore = surface.create_entity{name=to, position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast new_ore -nil
			
			local orig_amount = orig_ore.amount
			local amount = math.max(math.ceil(orig_amount * restore), 1) -- not allowed to set amount=0, and 0 would deplete finite tiles without on_resource_depleted
			orig_amount = amount > orig_amount and amount or orig_amount
			
			if to == "vault-scrap" then
				if orig_amount < INF_SCRAP_MIN then orig_amount = INF_SCRAP_MIN + INF_SCRAP_DEPLETED_BUMP_AMOUNT end -- important to avoid depth bug (?)
				
				new_ore.initial_amount = orig_amount
				-- this enforces minimum if setting to a low percentage
				-- also need to bump if setting amount to under minimum, or on_resource_depleted never gets called and estimation will be wrong!
				local minimum = get_inf_scrap_minimum(orig_amount) + INF_SCRAP_DEPLETED_BUMP_AMOUNT -- needs to be called after initial_amount is set!
				if amount < minimum then amount = minimum end
				
				assert(amount <= new_ore.initial_amount)
			end
			new_ore.amount = amount
			
			new_count = new_count + amount
			initial_count = initial_count + orig_amount
		end
	end

	assert(new_count <= initial_count)
	
	-- actually delete it
	for _,old_ore in pairs(old_ores) do
		old_ore.destroy()
	end

	-- find overlapping vaults (ore is part of more than one radius)
	-- and update their initial amounts
	for _,e in pairs(surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=radius*2}) do
		local vault = storage.vaults[script.register_on_object_destroyed(e)] -- HACK: to get vault witout require("vault")
		if vault and vault.scrap then
			vault.scrap:reset(surface, e.position, radius, true)
			vault:_reset_wave_for_mining_rate() -- reset wave_end_tick so gui shows new mining rate for convenience
		end
	end
	
	-- updates all possible drills
	ore.update_drill_connections_near(surface, position, radius)

	return "success"
end

local VIS_DRAIN = true
if const.DEBUG and VIS_DRAIN then
	script.on_nth_tick(1, function(event)
		local player = game.get_player(1) ---@cast player -nil
		for _,vault in pairs(player.surface.find_entities_filtered{name=const.VAULT_NAME, position=player.position, radius=40}) do
			for _,drill in pairs(player.surface.find_entities_filtered{type="mining-drill", position=vault.position, radius=common.VAULT_DEFENSE_RADIUS()}) do
				local active_ore = drill.mining_target
				local amount = active_ore and active_ore.amount
				
				if active_ore then
					local yield = amount / INF_SCRAP_NORMAL
					local color = yield > 1 and {0,1,0} or {1,1,0}
					
					rendering.draw_circle{surface=active_ore.surface, target=active_ore, radius=0.5, color=color, time_to_live=1}
					rendering.draw_text{text=string.format("%d", amount),
						surface=active_ore.surface, target=active_ore, color=color, time_to_live=1}
					rendering.draw_text{text=string.format("%d%%", yield * 100),
						surface=active_ore.surface, target={type="entity", entity=active_ore, offset={0,-.4}}, color=color, time_to_live=1}
				end
			end
		end

		--game.print("drains: "..serpent.line(drains))
	end)
end

return ore
