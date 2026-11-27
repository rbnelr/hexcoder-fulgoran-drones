local const = require("const")
local myutil = require("lib.myutil")
local common = require("control.common")
local original_mapgen = require("control.original_mapgen")

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

local ore = {}

local INF_SCRAP_NORMAL = common.INF_SCRAP_NORMAL
local INF_SCRAP_MIN = common.INF_SCRAP_MIN
local INF_SCRAP_DEPLETED_BUMP_AMOUNT = common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
local INF_SCRAP_DEPLETION_TO_MINING = common.INF_SCRAP_DEPLETION_TO_MINING
local get_inf_scrap_minimum = common.get_inf_scrap_minimum
local tile_position_key = myutil.tile_position_key

-- finite ore has no minimum, use the same 20% as inf ore as floor for depth
local FINITE_FLOOR_RATIO = common.INF_SCRAP_MIN_RATIO

--#region OreTracker (per-vault ore tracking)

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
-- depleted finite tiles disappear but keep their initial, so drainable keeps counting them (remaining only counts present tiles), a tile that reappears reuses it
-- tiles that appear later (chunks generated later, restored tiles) have no previous amount, so they do not count as mined
-- tiles in ungenerated chunks are unknown (not depleted) until generated, like inf ore
-- depth = fraction of drainable amount gone, per tile down to a floor (tiles below it count as 0, not negative), inf ore floor is its minimum, so 100m depth = minimum yield (inf ore can only lose ~80%)
--  same 20% used for finite ores for simplicity, which also allows benefitting from max quality for some time until actually depleted
-- depth only depends on the ore (progression curve is applied later), computed from remaining/drainable of the last scan

-- vault.scrap_tracker always exists and is scanned on vault registration (depth for all vaults, waves happen without drills too)
-- per-tile amounts are only kept while drills are around (memory), on_drill_built() takes a new baseline
---@class OreTracker
---@field amounts table<tile_key, number>? -- amount at last scan, only while drills are around
---@field initial_amounts table<tile_key, number>? -- finite only: initial amount of all tiles seen, incl. mined out ones, kept while idle
---@field remaining number -- drainable amount left (current minus minimum)
---@field drainable number -- initially drainable (initial minus minimum), summed per tile
---@field initial_total number? -- finite only: actual initial amount, incl. mined out tiles (drainable stops at the 20% floor, confusing in the gui)
---@field amount_total number? -- finite only: actual current amount
---@field mined number -- mining rate since tick (drain, but adjusted when yield <100%)
---@field mined_reset_tick MapTick -- last reset_mined() (wave start) or creation
---@field scan_tick MapTick -- last scan(), reset_mined() skips its scan if already scanned this tick
local OreTracker = {}
OreTracker.__index = OreTracker
ore.OreTracker = OreTracker

-- scans right away
-- finite tiles take their current amount as initial, fine for vaults registered after init (never mined, drills register nearby vaults before mining)
---@param vault Vault -- its scrap_tracker is not set yet
---@param source_event string?
---@return OreTracker
function OreTracker.new(vault, source_event)
	local self = setmetatable({
		mined = 0,
		mined_reset_tick = game.tick,
	}, OreTracker)

	if source_event ~= "on_chunk_generated" then
		self:scan_initial_finite(vault)
	end

	-- scan current amount for each vault
	-- infinite ores have initial already
	-- finite assume current amount is correct (no mining because mapgen vault) or scan_initial_finite was called if old vault in existing save
	local e = vault.entity
	self:scan(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, vault:has_drills())
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

-- scan unless already scanned this tick, and only while mining was possible since the last scan:
-- drills now, or at the last scan (amounts are only kept while drills are around, so that counts the mining until they were removed)
-- without drills nothing can be mined, so mined and depth stay valid
-- restore_ore and on_drill_built still call scan() directly, ore changes there without drills
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param has_drills boolean
function OreTracker:scan_if_needed(surface, position, radius, has_drills)
	if self.scan_tick ~= game.tick and (has_drills or self.amounts) then
		self:scan(surface, position, radius, has_drills)
	end
end

-- mined per minute since tick, call scan_if_needed first (find_current_mining_rate_and_depth does)
---@return number
function OreTracker:mining_rate()
	return self.mined / math.max((game.tick - self.mined_reset_tick) / 3600, 0.01)
end

-- start a new mining rate window, on wave start
-- scans first if needed, so mining before the reset does not land in the new window
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param has_drills boolean
function OreTracker:reset_mined(surface, position, radius, has_drills)
	self:scan_if_needed(surface, position, radius, has_drills)
	self.mined = 0
	self.mined_reset_tick = game.tick
end

---@param remaining number
---@param drainable number
---@return number depth 0-1
local function calc_depth(remaining, drainable)
	return drainable > 0 and math.min(math.max(1 - remaining / drainable, 0), 1) or 0
end

-- depth from the last scan, without scanning
-- for overlapping vaults during drill quality updates, where a stale depth is fine
---@return number depth 0-1
function OreTracker:scanned_depth()
	return calc_depth(self.remaining, self.drainable)
end

-- mining rate since the last wave start and depth, scans if needed (scan_if_needed: once per tick, while drills are or were around)
---@param surface LuaSurface
---@param position MapPosition
---@param radius number
---@param has_drills boolean
---@return number mining_rate -- per minute
---@return number depth -- 0-1
function OreTracker:find_current_mining_rate_and_depth(surface, position, radius, has_drills)
	self:scan_if_needed(surface, position, radius, has_drills)
	return self:mining_rate(), calc_depth(self.remaining, self.drainable)
end
--#endregion

--#region Scan
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

		for _,ore in pairs(surface.find_entities_filtered{type="resource", name="infinite-scrap", position=position, radius=radius}) do
			local amount = ore.amount
			local initial = ore.initial_amount ---@cast initial -nil
			local minimum = get_inf_scrap_minimum(initial) + INF_SCRAP_DEPLETED_BUMP_AMOUNT

			drainable = drainable + math.max(initial - minimum, 0)
			remaining = remaining + math.max(amount - minimum, 0)

			local key = tile_position_key(ore.position)
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
		self.scan_tick = game.tick
	end
	
	-- registered in control/events.lua
	---@param event EventData.on_resource_depleted
	function ore.on_resource_depleted(event)
		local ore = event.entity
		if ore.name ~= "infinite-scrap" then return end
		init()

		--assert(ore.amount <= get_inf_scrap_minimum(ore.initial_amount))

		-- infinite at minimum: bump so it keeps depleting and mining stays visible to scan
		local position = ore.position
		local key = tile_position_key(position)
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
	end
else
	-- finite: registers initial on first sight, fake minimum is 20% of initial, mined out tiles keep their initial
	---@param surface LuaSurface
	---@param position MapPosition
	---@param radius number
	---@param has_drills boolean
	function OreTracker:scan(surface, position, radius, has_drills)
		local amounts = self.amounts or {}
		local initial_amounts = self.initial_amounts or {}

		local mined, remaining, drainable = 0, 0, 0
		local initial_total, amount_total = 0, 0

		-- present tiles: remaining, mined
		for _,ore in pairs(surface.find_entities_filtered{type="resource", name="scrap", position=position, radius=radius}) do
			local amount = ore.amount
			local key = tile_position_key(ore.position)

			local initial = initial_amounts[key]
			if initial == nil then
				-- no recorded initial, assume current amount
				-- happens on the first scan of a fresh vault, or for tiles that appear later
				initial = amount
				initial_amounts[key] = initial
			end

			remaining = remaining + math.max(amount - initial * FINITE_FLOOR_RATIO, 0)
			amount_total = amount_total + amount

			local prev_amount = amounts[key]
			if prev_amount and amount < prev_amount then
				mined = mined + (prev_amount - amount)
			end
			amounts[key] = amount
		end

		-- all tiles incl. mined out ones (nothing remaining): drainable
		for _,initial in pairs(initial_amounts) do
			drainable = drainable + initial * (1 - FINITE_FLOOR_RATIO)
			initial_total = initial_total + initial
		end

		self.amounts = has_drills and amounts or nil
		self.initial_amounts = initial_amounts

		self.mined = self.mined + mined
		self.remaining = remaining
		self.drainable = drainable
		self.initial_total = initial_total
		self.amount_total = amount_total
		self.scan_tick = game.tick
	end

	-- registered in control/events.lua
	---@param event EventData.on_resource_depleted
	function ore.on_resource_depleted(event)
		local ore = event.entity
		if ore.name ~= "scrap" then return end
		init()

		--if const.DEBUG then
		--	game.print(const.PRINT_PREFIX.."on_resource_depleted ".. serpent.line{ore})
		--end

		-- finite ore depleted, removed by the game after this
		-- last amount counts as mined, initial stays so depth keeps counting the tile
		local position = ore.position
		local key = tile_position_key(position)
		for _,ve in pairs(ore.surface.find_entities_filtered{name=const.VAULT_NAME, position=position, radius=const.VAULT_DEFENSE_RADIUS}) do
			local vault = get_vault(ve)
			local scrap = vault and vault.scrap_tracker
			local amounts = scrap and scrap.amounts
			local prev_amount = amounts and amounts[key]
			if prev_amount then
				---@cast scrap -nil
				---@cast amounts -nil
				scrap.mined = scrap.mined + prev_amount
				amounts[key] = nil
			end
		end
	end
end

-- initial amount per tile in the vault's radius
-- original vaults (original_mapgen.is_original_vault): from fake fulgora, incl. mined out tiles
--  tiles in chunks the real surface has not generated are left out (fake fulgora generates all around), scan registers those tiles once generated
-- other vaults (cloned, moved): the original ore at their position belongs to something else, so use what we know:
--  inf: initial_amount of each tile, finite: tracker initials (incl. mined out tiles), else the current amount
---@param vault Vault
---@param tracker OreTracker? -- the vault's tracker, nil while it is created
---@return table<tile_key, number>
local function find_initial_amounts(vault, tracker)
	local e = vault.entity
	local surface, position, radius = e.surface, e.position, const.VAULT_DEFENSE_RADIUS
	local initial_amounts = {}

	local fake_surface = original_mapgen.recreate_initial_surface_and_load_chunks(surface, original_mapgen.chunks_in_radius(surface, position, radius))
	if original_mapgen.is_original_vault(fake_surface, position) then
		---@cast fake_surface -nil
		-- both types, fake fulgora may have been created with the other inf scrap setting (reused surface), so its types can't be trusted
		for _,orig in pairs(fake_surface.find_entities_filtered{position=position, radius=radius, type="resource", name=const.SCRAP_TYPES}) do
			local pos = orig.position
			if surface.is_chunk_generated{x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)} then
				initial_amounts[tile_position_key(pos)] = orig.amount
			end
		end
	else
		local known = tracker and tracker.initial_amounts -- finite only
		if known then
			for key, initial in pairs(known) do
				initial_amounts[key] = initial
			end
		end
		for _,o in pairs(surface.find_entities_filtered{type="resource", name=const.ACTIVE_SCRAP, position=position, radius=radius}) do
			local key = tile_position_key(o.position)
			if initial_amounts[key] == nil then
				initial_amounts[key] = o.initial_amount or o.amount -- initial_amount: infinite only
			end
		end
	end
	return initial_amounts
end

-- finite: rebuild initial amounts incl. mined out tiles (find_initial_amounts), scan() after this to update depth
-- needed when tiles may have been mined or changed while not tracked (new install on existing save, change_ore)
-- inf ore has initial_amount, nothing to do
---@param vault Vault
function OreTracker:scan_initial_finite(vault)
	if const.INF_SCRAP_ENABLED then return end
	self.initial_amounts = find_initial_amounts(vault, self)
end
--#endregion

--#region Restore

-- restore the scrap around a vault to restore * its initial amount (find_initial_amounts), fully drained tiles are recreated
-- only touches the active scrap type (with inf scrap on, a missing tile or finite scrap is off-island or not converted, ignored)
-- note: for infinite ores, the yield % depends on the "normal" amount as defined in the ore prototype
--       and the actual minimum depends on the initial amount
---@param vault Vault
---@param restore number -- 0-1
local function restore_scrap_near_vault(vault, restore)
	local surface = vault.entity.surface
	for key, initial in pairs(find_initial_amounts(vault, vault.scrap_tracker)) do
		local position = myutil.tile_position_key_to_center(key)
		local amount = math.ceil(initial * restore)

		local o = surface.find_entity(const.ACTIVE_SCRAP, position)
		if o == nil and not const.INF_SCRAP_ENABLED then
			-- fully drained, only finite tiles can deplete, find_initial_amounts only returns tiles in generated chunks
			o = surface.create_entity{name="scrap", position=position, snap_to_grid=true, preserve_ghosts_and_corpses=true}
		end

		if o ~= nil then
			if const.INF_SCRAP_ENABLED then
				-- this enforces minimum if setting to a low percentage
				-- also need to bump if setting amount to under minimum, or on_resource_depleted never gets called and estimation will be wrong!
				-- initial below the minimum raised too, important to avoid depth bug (?)
				local inf_initial
				inf_initial, amount = common.clamp_inf_scrap(initial, amount)
				o.initial_amount = inf_initial -- before amount, the minimum depends on it
			elseif amount < 1 then
				amount = 1 -- not allowed to set amount=0, and 0 would deplete finite tiles without on_resource_depleted
			end
			o.amount = amount
		end
	end
end

-- Convert the scrap around vault ruins to the inf scrap setting and/or restore it to a percentage of its initial amount
-- convert: original vaults (fake fulgora has a vault at the same position) like the map conversion (vault islands only),
--  other vaults (cloned, moved) convert all scrap in radius in place (current amount as initial)
-- restore: restore_scrap_near_vault, initial amounts from find_initial_amounts (fake fulgora for original vaults, what we know for others)
-- TODO: add parameter (and mod setting) to override richness, so that time to reach say, 20% of scrap can be adjusted for finite ores (max quality at 20%?)
--       and for inf ores, the richness would increase the normal amount such that
---@param surface LuaSurface
---@param where Vault|"all" -- "all": every vault ruin on surface (slow, one fake fulgora request per vault)
---@param restore number? -- fraction of the initial amount, 0-1 (infinite clamps to its minimum, finite to 1), nil: no restore
---@param convert boolean -- convert scrap of the other type to the inf scrap setting first
function ore.change_ore(surface, where, restore, convert)
	local radius = const.VAULT_DEFENSE_RADIUS

	local vaults = {}
	if where == "all" then
		for _,ve in pairs(surface.find_entities_filtered{name=const.VAULT_NAME}) do
			table.insert(vaults, get_or_init_vault(ve))
		end
	else
		vaults[1] = where
	end

	local rescan = {} ---@type table<Vault, true> -- this and overlapping vaults, once each
	for _,vault in ipairs(vaults) do
		if convert then
			local position = vault.entity.position
			local fake_surface = original_mapgen.recreate_initial_surface_and_load_chunks(surface, original_mapgen.chunks_in_radius(surface, position, radius))
			if original_mapgen.is_original_vault(fake_surface, position) then
				---@cast fake_surface -nil
				original_mapgen.convert_scrap_on_vault_islands(surface, fake_surface, const.ACTIVE_SCRAP, position, radius)
			else
				local _, initials = original_mapgen.convert_scrap_in_place(surface, const.ACTIVE_SCRAP, position, radius)
				-- infinite-scrap -> scrap: the finite tracker never saw these tiles, keep their initial_amount (merged, the tracker knows other tiles too)
				local initial_amounts = vault.scrap_tracker.initial_amounts
				if initial_amounts then
					for key, initial in pairs(initials) do
						initial_amounts[key] = initial
					end
				end
			end
		end

		if restore then
			restore_scrap_near_vault(vault, restore)
		end

		for _,v in pairs(vault:find_this_and_overlapping_vaults()) do
			rescan[v] = true
		end
	end

	-- rescan overlapping vaults (ore is part of more than one radius), finite initials of converted and recreated tiles
	-- tiles a vault has no initial for take the current amount (scan), fine for overlapping vaults that are not original
	-- important!, lowered amounts count as mined, clear that or it triggers huge waves
	-- this also restarts the mining rate window, so the gui shows the new rate instead of an average (wave timer is kept)
	for v in pairs(rescan) do
		local e = v.entity
		local tracker = v.scrap_tracker
		tracker:scan_initial_finite(v)
		tracker:scan(e.surface, e.position, radius, v:has_drills())
		tracker:reset_mined(e.surface, e.position, radius, v:has_drills()) -- no scan, already scanned above
	end

	-- recreated drained tiles
	for _,vault in ipairs(vaults) do
		common.update_drill_connections_near(surface, vault.entity.position, radius)
	end
end
--#endregion

--#region Debug drain visualisation
local VIS_DRAIN = false
if const.DEBUG and VIS_DRAIN then
	-- on_nth_tick(1) in control/events.lua, nil when off
	---@param event NthTickEventData
	function ore.debug_vis_drain(event)
		local player = game.get_player(1) ---@cast player -nil
		for _,vault in pairs(player.surface.find_entities_filtered{name=const.VAULT_NAME, position=player.position, radius=40}) do
			for _,drill in pairs(player.surface.find_entities_filtered{type="mining-drill", position=vault.position, radius=const.VAULT_DEFENSE_RADIUS}) do
				local active_ore = drill.mining_target
				local amount = active_ore and active_ore.amount
				
				if active_ore then
					if active_ore.prototype.infinite_resource then
						local yield = amount / INF_SCRAP_NORMAL
						local color = yield > 1 and {0,1,0} or {1,1,0}
						
						rendering.draw_circle{surface=active_ore.surface, target=active_ore, radius=0.5, color=color, time_to_live=1}
						rendering.draw_text{text=string.format("%d", amount),
							surface=active_ore.surface, target=active_ore, color=color, time_to_live=1}
						rendering.draw_text{text=string.format("%d%%", yield * 100),
							surface=active_ore.surface, target={type="entity", entity=active_ore, offset={0,-.4}}, color=color, time_to_live=1}
					else
						local color = {0,0,1}
						
						rendering.draw_circle{surface=active_ore.surface, target=active_ore, radius=0.5, color=color, time_to_live=1}
						rendering.draw_text{text=string.format("%d", amount),
							surface=active_ore.surface, target=active_ore, color=color, time_to_live=1}
					end
					
				end
			end
		end

		--game.print("drains: "..serpent.line(drains))
	end
end
--#endregion

return ore
