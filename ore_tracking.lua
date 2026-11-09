local const = require("const")
local common = require("control.common")
local recreare_fulgora = require("recreate_fulgora")

local ore = {}

local INF_SCRAP_NORMAL = common.INF_SCRAP_NORMAL
local INF_SCRAP_MIN = common.INF_SCRAP_MIN
local INF_SCRAP_DEPLETED_BUMP_AMOUNT = common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
local INF_SCRAP_DEPLETION_TO_MINING = common.INF_SCRAP_DEPLETION_TO_MINING
local get_inf_scrap_minimum = common.get_inf_scrap_minimum

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
		
		-- recreated by restore_ore or convert_ore_and_restore_vaults, why do this here and not just there?
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
--   needed when tiles may have been mined or replaced while not tracked (radius change, existing save, restore_ore)
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
			finite_initial[key] = math.max(orig.amount, ore.amount) -- restore_ore > 100%
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
	
	--assert(ore.amount <= get_inf_scrap_minimum(ore.initial_amount)) -- ore can spawn or be created by restore_ore with lower than minimum amount (bumps will make it end up at minimum, I think)
	
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
			game.print(const.PRINT_PREFIX.."on_resource_depleted ".. serpent.line{
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
			game.print(const.PRINT_PREFIX.."on_resource_depleted ".. serpent.line{ore})
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

-- Restore the scrap around a vault ruin to a percentage of the original (mapgen) amount, read from fake fulgora
-- only changes amounts, never the type (that is recreate_fulgora.convert_ore_and_restore_vaults, from the inf scrap setting)
-- fully drained (finite) tiles are recreated as finite scrap
-- note: for infinite ores, the yield % depends on the "normal" amount as defined in the ore prototype
--       and the actual minimum depends on the initial amount
-- note: restore >100% will inflate the initial amount to be higher, but <100% will not set it lower
-- TODO: add parameter (and mod setting) to override richness, so that time to reach say, 20% of scrap can be adjusted for finite ores (max quality at 20%?)
--       and for inf ores, the richness would increase the normal amount such that
---@param vault Vault
---@param restore number -- fraction of the original amount, >= 0, may be > 1 (infinite clamps to its minimum, finite to 1)
function ore.restore_ore(vault, restore)
	local position = vault.entity.position
	local surface = vault.entity.surface
	local radius = common.VAULT_DEFENSE_RADIUS()

	local fake_surface = recreare_fulgora.recreate_initial_surface_and_load_chunks(surface, position, radius)
	local orig_ores = fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name=const.SCRAP_TYPES}

	for _,orig_ore in pairs(orig_ores) do
		local orig_amount = orig_ore.amount
		local amount = math.ceil(orig_amount * restore)

		local old_ore = surface.find_entities_filtered{position=orig_ore.position, type="resource", name=const.SCRAP_TYPES}[1] -- TODO: why not find_entity?
		if old_ore == nil then
			-- fully drained, only finite tiles can deplete
			old_ore = surface.create_entity{name="scrap", position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true} ---@cast old_ore -nil
		end

		if old_ore.name == "vault-scrap" then
			local initial = math.max(orig_amount, amount)
			if initial < INF_SCRAP_MIN then initial = INF_SCRAP_MIN + INF_SCRAP_DEPLETED_BUMP_AMOUNT end -- important to avoid depth bug (?)
			old_ore.initial_amount = initial -- before amount, the minimum depends on it

			-- this enforces minimum if setting to a low percentage
			-- also need to bump if setting amount to under minimum, or on_resource_depleted never gets called and estimation will be wrong!
			local minimum = get_inf_scrap_minimum(initial) + INF_SCRAP_DEPLETED_BUMP_AMOUNT
			if amount < minimum then amount = minimum end
		elseif amount < 1 then
			amount = 1 -- not allowed to set amount=0, and 0 would deplete finite tiles without on_resource_depleted
		end
		old_ore.amount = amount
	end

	-- important!, otherwise we may get negative or positive huge mining rates and trigger huge waves
	-- find overlapping vaults (ore is part of more than one radius) and update their initial amounts (finite initial raised for restore > 100%, drained tiles)
	for _,e in pairs(surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=radius*2}) do
		local vault = storage.vaults[script.register_on_object_destroyed(e)] -- HACK: to get vault witout require("vault")
		if vault and vault.scrap then
			vault.scrap:reset(surface, e.position, radius, true)
			vault:_reset_wave_for_mining_rate() -- reset wave_end_tick so gui shows new mining rate for convenience
		end
	end

	-- recreated drained tiles
	common.update_drill_connections_near(surface, position, radius)
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
