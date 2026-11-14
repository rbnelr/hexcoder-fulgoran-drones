local const = require("const")
local myutil = require("lib.myutil")
local common = require("control.common")
local recreare_fulgora = require("control.recreate_fulgora")

local ore = {}

local INF_SCRAP_NORMAL = common.INF_SCRAP_NORMAL
local INF_SCRAP_MIN = common.INF_SCRAP_MIN
local INF_SCRAP_DEPLETED_BUMP_AMOUNT = common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
local INF_SCRAP_DEPLETION_TO_MINING = common.INF_SCRAP_DEPLETION_TO_MINING
local get_inf_scrap_minimum = common.get_inf_scrap_minimum
local int_position_key = myutil.int_position_key

-- finite ore has no minimum, use the same 20% as inf ore as floor for depth
local FINITE_FLOOR_RATIO = common.INF_SCRAP_MIN_RATIO

---- Per-vault ore tracking

-- each vault tracks the scrap in its radius, for mining rate (wave size and frequency) and depth (progression)
-- this needs the previous amount per tile, comparing total amounts breaks with inf ore since drain reduces <100% yield, chunks generated later and depleted tiles also would complicate things
-- scan() adds the drain since the previous scan to mined, reset_mined() on wave start, so mining rate (mined / time since tick) effectively is average since last wave
-- the poll only scans while drills are around (and once more after they are gone), without drills nothing can be mined, so mined and depth stay valid
-- scan automatically handles newly added ores, and should mostly handle ores being replaced, finite ores are actually more complicated in this regard

-- mining rate (more drills/speed modules = more drone attacks):
-- based on observed drain (reduction in ore in patch), not produced ore, so prod research/modules are free (these are hard to track)
--  big-drill 50% drain (ore more with quality) can't be accounted for either, but I balance around that
-- inf ore below 100% yield only drains with chance = yield, so divide by yield, otherwise waves would fade as the vault gets mined (meaning large waves with lower yield throughput)
-- inf ore above 100% yield gives extra ore per drain, which is free like prod
-- we increase the inf ore drain (infinite_depletion_amount) so it does not take 100h to reach the minimum, divide that back out (finite ores do last that long)
-- inf ore stops draining at its minimum (on_resource_depleted), we give it <1% yield bumps in on_resource_depleted() so it keeps draining, should not be visible to user and works accurately

-- initial amount and depth:
-- inf ore has initial_amount, finite ore does not, so remember it per tracker in initial_amounts (first time seen, or from fake fulgora), overlapping vaults store shared tiles twice (rare)
-- depleted finite tiles disappear, their drainable amount stays summed in depleted_drainable
-- tiles that appear later (chunks generated later, restored tiles) have no previous amount, so they do not count as mined
-- depth = fraction of drainable amount gone, per tile down to a floor (tiles below it count as 0, not negative), inf ore floor is its minimum, so 100m depth = minimum yield (inf ore can only lose ~80%)
--  same 20% used for finite ores for simplicity, which also allows benefitting from max quality for some time until actually depleted
-- depth only depends on the ore (progression curve is applied later), so it is stored

-- vault.scrap_tracker always exists and is scanned on vault registration (depth for all vaults, waves happen without drills too)
-- per-tile amounts are only kept while drills are around (memory), on_drill_built() takes a new baseline
---@class OreTracker
---@field amounts table<tile_key, number>? -- amount at last scan, only while drills are around
---@field initial_amounts table<tile_key, number>? -- finite only: initial amount of present tiles, kept while idle
---@field depleted_drainable number? -- finite only: drainable amount of mined out tiles
---@field remaining number -- drainable amount left (current minum minimum)
---@field drainable number -- initially drainable (initial minus minimum), summed per tile
---@field depth number -- 0-1
---@field mined number -- mining rate since tick (drain, but adjusted when yield <100%)
---@field tick MapTick -- last reset_mined() (wave start) or creation
local OreTracker = {}
OreTracker.__index = OreTracker
ore.OreTracker = OreTracker

-- scans right away
-- finite tiles take their current amount as initial, fine for vaults registered after init (never mined, drills register nearby vaults before mining)
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param has_drills boolean
---@param source_event string?
---@return OreTracker
function OreTracker.new(surface, position, radius, has_drills, source_event)
	local self = setmetatable({
		mined = 0,
		tick = game.tick,
	}, OreTracker)
	
	if source_event ~= "on_chunk_generated" then
		self:scan_initial_finite(surface, position, radius)
	end
	
	-- scan current amount for each vault
	-- infinite ores have initial already
	-- finite assume current amount is correct (no mining because mapgen vault) or scan_initial_finite was called if old vault in existing save
	self:scan(surface, position, radius, has_drills)
	return self
end

-- take a baseline before the new drill mines anything (no-op while drills were already around)
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
function OreTracker:on_drill_built(surface, position, radius)
	if self.amounts == nil then
		self:scan(surface, position, radius, true)
	end
end

-- mined per minute since tick
---@return number
function OreTracker:mining_rate()
	return self.mined / math.max((game.tick - self.tick) / 3600, 0.01)
end

-- start a new mining rate window, on wave start
function OreTracker:reset_mined()
	self.mined = 0
	self.tick = game.tick
end

---@param remaining number
---@param drainable number
---@return number depth 0-1
local function calc_depth(remaining, drainable)
	return drainable > 0 and math.min(math.max(1 - remaining / drainable, 0), 1) or 0
end

-- scan the active scrap type, off-island scrap of the other type (rarely touches radius) is ignored
-- per tile: drain since the previous scan is added to mined, tiles without previous amount count nothing (new tiles, first scan after drills returned)
-- also sets remaining, drainable and depth
-- has_drills: mining is possible until the next scan, keep the per-tile amounts, otherwise drop them (on_drill_built() takes a new baseline)
-- two versions for simplicity and potential perf, inf scrap is a startup setting
if const.INF_SCRAP_ENABLED then
	-- infinite: initial is initial_amount, minimum includes the bump, mined corrected for yield and our faster drain
	---@param surface LuaSurface
	---@param position MapPosition
	---@param radius number
	---@param has_drills boolean
	function OreTracker:scan(surface, position, radius, has_drills)
		local amounts = self.amounts or {}
		local mined, remaining, drainable = 0, 0, 0

		for _,ore in pairs(surface.find_entities_filtered{type="resource", name="vault-scrap", position=position, radius=radius}) do
			local amount = ore.amount
			local initial = ore.initial_amount ---@cast initial -nil
			local minimum = get_inf_scrap_minimum(initial) + INF_SCRAP_DEPLETED_BUMP_AMOUNT

			drainable = drainable + math.max(initial - minimum, 0)
			remaining = remaining + math.max(amount - minimum, 0)

			local key = int_position_key(ore.position)
			local prev_amount = amounts[key]
			if prev_amount and amount < prev_amount then
				local drained = prev_amount - amount
				local yield = amount / INF_SCRAP_NORMAL
				if yield < 1 then drained = drained / yield end
				mined = mined + drained * INF_SCRAP_DEPLETION_TO_MINING
			end
			amounts[key] = amount
		end

		self.amounts = has_drills and amounts or nil
		self.mined = self.mined + mined
		self.remaining = remaining
		self.drainable = drainable
		self.depth = calc_depth(remaining, drainable)
	end
	
	script.on_event(defines.events.on_resource_depleted, function(event)
		local ore = event.entity
		if ore.name ~= "vault-scrap" then return end
		init()

		--assert(ore.amount <= get_inf_scrap_minimum(ore.initial_amount))

		-- infinite at minimum: bump so it keeps depleting and mining stays visible to scan
		local position = ore.position
		local key = int_position_key(position)
		local bump = INF_SCRAP_DEPLETED_BUMP_AMOUNT
		local old_amount = ore.amount
		ore.amount = old_amount + bump

		-- update amounts of the ore trackers of nearby vaults
		for _,ve in pairs(ore.surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=const.VAULT_DEFENSE_RADIUS}) do
			local vault = get_vault(ve)
			local amounts = vault and vault.scrap_tracker.amounts
			local prev_amount = amounts and amounts[key]
			if prev_amount then ---@cast amounts -nil
				-- accumulate bump, don't set latest amount, as that would forget depletion before this
				-- this way new substraction produces correct result: sum of depletion before and after one or multiple bumps
				amounts[key] = prev_amount + bump
			end
		end

		--if const.DEBUG then
		--	game.print(const.PRINT_PREFIX.."on_resource_depleted ".. serpent.line{
		--		old_amount=old_amount,
		--		bamount=ore.amount,
		--		initial=ore.initial_amount,
		--		minimum=ore.prototype.minimum_resource_amount,
		--		normal=ore.prototype.normal_resource_amount,
		--		old_yield=old_amount / INF_SCRAP_NORMAL * 100,
		--		new_yield=ore.amount / INF_SCRAP_NORMAL * 100,
		--	})
		--end
	end)
else
	-- finite: registers initial on first sight, fake minimum is 20% of initial, mined out tiles are in depleted_drainable
	---@param surface LuaSurface
	---@param position MapPosition
	---@param radius number
	---@param has_drills boolean
	function OreTracker:scan(surface, position, radius, has_drills)
		local amounts = self.amounts or {}
		local initial_amounts = self.initial_amounts
		if initial_amounts == nil then
			initial_amounts = {}
			self.initial_amounts = initial_amounts
		end
		local mined, remaining, drainable = 0, 0, self.depleted_drainable or 0

		for _,ore in pairs(surface.find_entities_filtered{type="resource", name="scrap", position=position, radius=radius}) do
			local amount = ore.amount
			local key = int_position_key(ore.position)

			local initial = initial_amounts[key]
			if initial == nil then
				-- no recorded initial, assume current amount
				-- happens on the first scan of a fresh vault, or for tiles that appear later
				initial = amount
				initial_amounts[key] = amount
			end
			local minimum = initial * FINITE_FLOOR_RATIO

			drainable = drainable + (initial - minimum)
			remaining = remaining + math.max(amount - minimum, 0)
			
			local prev_amount = amounts[key]
			if prev_amount and amount < prev_amount then
				mined = mined + (prev_amount - amount)
			end
			amounts[key] = amount
		end

		self.amounts = has_drills and amounts or nil
		self.mined = self.mined + mined
		self.remaining = remaining
		self.drainable = drainable
		self.depth = calc_depth(remaining, drainable)
	end
	
	script.on_event(defines.events.on_resource_depleted, function(event)
		local ore = event.entity
		if ore.name ~= "scrap" then return end
		init()

		--if const.DEBUG then
		--	game.print(const.PRINT_PREFIX.."on_resource_depleted ".. serpent.line{ore})
		--end

		-- finite ore depleted, removed by the game after this
		-- last amount counts as mined, drainable amount moves to depleted_drainable so depth keeps counting the tile
		local position = ore.position
		local key = int_position_key(position)
		for _,ve in pairs(ore.surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=const.VAULT_DEFENSE_RADIUS}) do
			local vault = get_vault(ve)
			local scrap = vault and vault.scrap_tracker
			local initial_amounts = scrap and scrap.initial_amounts
			local initial = initial_amounts and initial_amounts[key]
			if initial then
				---@cast scrap -nil
				---@cast initial_amounts -nil
				initial_amounts[key] = nil
				scrap.depleted_drainable = (scrap.depleted_drainable or 0) + initial * (1 - FINITE_FLOOR_RATIO)
				
				local amounts = scrap.amounts
				local prev_amount = amounts and amounts[key]
				if prev_amount then ---@cast amounts -nil
					scrap.mined = scrap.mined + prev_amount
					amounts[key] = nil
				end
			end
		end
	end)
end

-- finite: rebuild initial amounts and mined out tiles from fake fulgora (slow, cheap during init since convert just generated it), scan() after this to update depth
-- needed when tiles may have been mined or changed while not tracked (new install on existing save, restore_ore)
-- inf ore has initial_amount, nothing to do
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
function OreTracker:scan_initial_finite(surface, position, radius)
	if const.INF_SCRAP_ENABLED then return end
	
	local fake_surface = recreare_fulgora.recreate_initial_surface_and_load_chunks(surface, position, radius)
	-- both types on both surfaces, fake fulgora may have been created with the other inf scrap setting (reused surface), so its types can't be trusted
	local initial_ores = fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name=const.SCRAP_TYPES}
	
	local current = {}
	for _,ore in pairs(surface.find_entities_filtered{type="resource", name=const.SCRAP_TYPES, position=position, radius=radius}) do
		current[int_position_key(ore.position)] = ore
	end
	
	local initial_amounts = {}
	local depleted_drainable = 0
	for _,orig in pairs(initial_ores) do
		local key = int_position_key(orig.position)
		local ore = current[key]
		if ore == nil then
			-- missing tiles were finite, inf ore never disappears
			depleted_drainable = depleted_drainable + orig.amount * (1 - FINITE_FLOOR_RATIO)
		elseif ore.name == "scrap" then
			initial_amounts[key] = math.max(orig.amount, ore.amount) -- restore_ore > 100%
		end
	end
	self.initial_amounts = initial_amounts
	self.depleted_drainable = depleted_drainable
end

-- Restore the scrap around a vault ruin to a percentage of the original (mapgen) amount, read from fake fulgora
-- only changes amounts, never the type (that is recreate_fulgora.convert_ore_and_restore_vaults, from the inf scrap setting)
-- only touches the active scrap type, fully drained tiles are recreated (only with inf scrap off, inf ore never drains)
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
	local radius = const.VAULT_DEFENSE_RADIUS

	local fake_surface = recreare_fulgora.recreate_initial_surface_and_load_chunks(surface, position, radius)
	local orig_ores = fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name=const.SCRAP_TYPES}

	for _,orig_ore in pairs(orig_ores) do
		local orig_amount = orig_ore.amount
		local amount = math.ceil(orig_amount * restore)

		---@type LuaEntity? -- typecheck does not allow surface.create_entity in if to assign LuaEntity? to this unless I do this
		local old_ore = surface.find_entities_filtered{position=orig_ore.position, type="resource", name=const.ACTIVE_SCRAP}[1] -- TODO: why not find_entity?
		if old_ore == nil and not const.INF_SCRAP_ENABLED then
			-- fully drained, only finite tiles can deplete (with inf scrap on, a missing tile is off-island finite scrap, ignored)
			old_ore = surface.create_entity{name="scrap", position=orig_ore.position, snap_to_grid=true, preserve_ghosts_and_corpses=true}
		end
		
		if old_ore ~= nil then -- may fail if chunks are not generated yet?
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
	end
	
	-- rescan overlapping vaults (ore is part of more than one radius), finite initial raised for restore > 100% and drained tiles
	-- important!, lowered amounts count as mined, clear that or it triggers huge waves
	-- this also restarts the mining rate window, so the gui shows the new rate instead of an average (wave timer is kept)
	for _,v in pairs(vault:find_this_and_overlapping_vaults()) do
		local e = v.entity
		local tracker = v.scrap_tracker
		tracker:scan_initial_finite(e.surface, e.position, radius)
		tracker:scan(e.surface, e.position, radius, v.has_drills)
		tracker:reset_mined()
	end

	-- recreated drained tiles
	common.update_drill_connections_near(surface, position, radius)
end

local VIS_DRAIN = false
if const.DEBUG and VIS_DRAIN then
	script.on_nth_tick(1, function(event)
		local player = game.get_player(1) ---@cast player -nil
		for _,vault in pairs(player.surface.find_entities_filtered{name=const.VAULT_NAME, position=player.position, radius=40}) do
			for _,drill in pairs(player.surface.find_entities_filtered{type="mining-drill", position=vault.position, radius=const.VAULT_DEFENSE_RADIUS}) do
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
