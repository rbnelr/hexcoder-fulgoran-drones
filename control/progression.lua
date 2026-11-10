local const = require("const")
local common = require("control.common")
local ore = require("control.ore_tracking")

-- Per-vault progression from depth: scaling curves and quality selection
-- depth comes from OreTracking.get_depth (0-1, 1 = minimum yield for inf scrap, same 20% for finite)
-- first prototype: only drill quality (local_effect), see release_plan.md 3.3

local progression = {}

---- Depth curve

-- progress always maxes out at 100% depth, speed only changes the curve shape: progress = depth ^ (1 / speed)
-- speed 1 = linear, 2 = sqrt (front-loaded, 50% progress at 25% depth), 0.5 = square (back-loaded, 50% at 71%)
-- TODO: setting (replaces "-evolution-speed", name and user-facing remap pending)
progression.PROGRESSION_SPEED = 2
progression.MAX_SCRAP_QUALITY = 1.5 -- 4 -- X tiers upgrade, hit at max depth, 4 is 100% legendary
progression.MAX_DRILL_QUALITY_BOOST = prototypes.entity["big-mining-drill"].effect_receiver.quality_limits.high -- 1000x / 100000%, ie 100% legendary

---@param depth number 0-1
---@return number progress 0-1
function progression.depth_to_progress(depth)
	depth = math.min(math.max(depth, 0), 1)
	return depth ^ (1 / progression.PROGRESSION_SPEED)
end

---- Drill quality

-- only rewrite drills when the vault's quality changed by at least this (effects have 0.01% resolution)
local DRILL_QUALITY_UPDATE_STEP = 0.001

---@param progress number 0-1
---@return number quality effect for LuaEntity.local_effect 1==+100%, up to +100000%, which gives 100% legendary
function progression.drill_quality_effect(progress)
	local x = progress * progression.MAX_SCRAP_QUALITY
	local tier = math.floor(x)
	local fract = (x - tier)
	if tier <= 0 then
		return fract -- 0-1, not 0.1-1
	end
	local lo = 10 ^ (tier - 1) -- tier 1: 1..10, tier 2: 10..100, ...
	return math.min(lo * (1 + 9 * fract), progression.MAX_DRILL_QUALITY_BOOST)
end

-- set a drill's local_effect quality to the best of all vaults whose radius contains it (overlapping radii take the max)
-- only touches the quality field, other fields of local_effect are kept
-- vaults without a cached quality (never scanned) count as 0
---@param drill LuaEntity
function progression.update_drill(drill)
	local effect = drill.local_effect
	if effect == nil then return end -- no effect receiver
	
	-- in case update drill increased quality, we could skip this, and do max with previous amount
	-- likely only way for quality to decrease is settings change or restore-ore, so reset things in those cases
	local quality = 0
	for _,e in pairs(drill.surface.find_entities_filtered{name=const.VAULT_NAME, position=drill.position, radius=const.VAULT_DEFENSE_RADIUS}) do
		local vault = storage.vaults[script.register_on_object_destroyed(e)] -- HACK: to get vault without require("vault")
		if vault and vault.drill_quality and vault.drill_quality > quality then
			quality = vault.drill_quality
		end
	end

	if (effect.quality or 0) ~= quality then
		effect.quality = quality
		drill.local_effect = effect
	end
end

-- cache depth and drill quality from a scan, rewrite drills in radius if the quality changed enough
---@param vault Vault
---@param scan OreScan
function progression.update_vault(vault, scan)
	vault.depth = ore.OreTracking.get_depth(scan)
	local quality = progression.drill_quality_effect(progression.depth_to_progress(vault.depth))

	if vault.drill_quality ~= nil and math.abs(quality - vault.drill_quality) < DRILL_QUALITY_UPDATE_STEP then return end
	vault.drill_quality = quality

	local e = vault.entity
	for _,drill in pairs(e.surface.find_entities_filtered{type="mining-drill", position=e.position, radius=const.VAULT_DEFENSE_RADIUS}) do
		progression.update_drill(drill)
	end
end

-- remove our quality from all drills on the surface (reset: radius change, mod update, uninstall prep)
-- also clears quality that another mod put into local_effect on these drills
---@param surface LuaSurface
function progression.clear_drills(surface)
	for _,drill in pairs(surface.find_entities_filtered{type="mining-drill"}) do
		local effect = drill.local_effect
		if effect and effect.quality and effect.quality ~= 0 then
			effect.quality = 0
			drill.local_effect = effect
		end
	end
end

return progression
