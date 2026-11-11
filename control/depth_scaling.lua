local const = require("const")
local common = require("control.common")
local ore = require("control.ore_tracking")
---@class Vault
local Vault = require("control.vault")

local depth_scaling = {}

-- progression of wave size/freq/bot quality and quality of mined scrap scales with "depth"
-- depth goes from 0-1, so %, but is displayed as 0-100m (meters)
--  depth is linear to scrap depletion
--  and maxes out at the minimum yield is for infinite ores (20%, but infinite is weird), and also 20% for finite ore
-- MAX_SCRAP_QUALITY setting is 1-5, translated to 0-4, being X tiers upgrade, 0=100% common, 4=100% legendary
--  TODO: decide and describe exact way distribution of scrap is determined in practice 
-- drill quality modifier:
--  0% = 100% common
--  100% = 100% upgraded to uncommon, then 10% upgraded to rare, 10% of that upgraded to epic etc.
--  I thought >100% would not do anything, but it seems the 10% chance to "upgrade again" actually scales with the quality boost too
-- (Not sure if the engine actually iterates or predetermined each chance and rolls once)
--  meaning 200% is 100% >= uncommon, 20% >= rare etc.
-- weirdly this means 1000% is 100% >= uncommon, but then 100% >= rare and 10% >= epic so no uncommon is output
-- so quality rewards basically scale in powers of 10

-- quality output of regular scrap mined with drill quality effect ("-" = under 1%)
-- "value" tiers: 1, 1.3, 1.6, 1.9, 2.5 (most quality effects scale like this)
-- "science" tiers: 1x, 2x, 3x, 4x, 6x (science yield scales like this)
-- TODO: now that tiers are established, list them too
-- | effect   | normal | uncommon | rare | epic | legendary | eff. value | eff. science |
-- |----------|--------|----------|------|------|-----------|------------|--------------|
-- | +0%      |   100% |        - |    - |    - |         - |       1.00 |         1.00 |
-- | +50%     |    50% |      48% |   2% |    - |         - |       1.16 |         1.53 |
-- | +100%    |      - |      90% |  10% |    - |         - |       1.33 |         2.10 |
-- | +500%    |      - |      50% |  48% |   2% |         - |       1.46 |         2.53 |
-- | +1000%   |      - |        - |  90% |  10% |         - |       1.63 |         3.10 |
-- | +5000%   |      - |        - |  50% |  48% |        3% |       1.76 |         3.55 |
-- | +10000%  |      - |        - |    - |  90% |       10% |       1.96 |         4.20 |
-- | +50000%  |      - |        - |    - |  50% |       50% |       2.20 |         5.00 |
-- | +100000% |      - |        - |    - |    - |      100% |       2.50 |         6.00 |

-- TODO: handle quality tech unlocks, no quality output at all without quality?
-- TODO: handle quality level unlocks, should happen automatically for drills, but is needed for drones
-- TODO: quality level unlocks should maybe be reflected in the gui and also cap scrap_tier() etc., so drills are visibly capped
-- though if we cap at scrap_tier() the distance falloff would punish more than if we dont or just cap each drill's, but capping each drill changes the distribution

-- drill has max qualtiy boost = 1000 (100000%), ie. 100% legendary from regular scrap
local MAX_DRILL_QUALITY_BOOST = prototypes.entity["big-mining-drill"].effect_receiver.quality_limits.high

-- vault is 14x8, drills are 5x5, so horizontal min possible distance is (7+2.5)
local QSCRAP_DIST_FALLOFF_MIN_DIST = 12 -- 12 allows drills touching the corners to get the full tier, while further away suffers
local QSCRAP_DIST_FALLOFF = 1 -- falloff at max dist (defense radius) in tiers

-- TODO: absolute multiplier, or table based to ensure all qualities are seen without reducing average value too much?
local QSCRAP_TIER_SPREAD = 0.5 -- random reduction (total) per drill to achive a spread of qualities
local QSCRAP_SPREAD_RANGE = 1
local QSCRAP_SPREAD_TOP_HEAVY = 2

---@param depth number 0-1
---@return number 0-1
local function progression_curve(depth)
	depth = math.min(math.max(depth, 0), 1)
	return depth ^ (1 / common.PROGRESSION_CURVE)
end

-- Setting is 1-5 (to match quality numbering and dots in icons), also display in gui like that
-- return as 0-4, or else distance scaling is too strong
---@param depth number 0-1
---@return number scrap_tier 0-(MAX_SCRAP_QUALITY-1)
function depth_scaling.scrap_tier(depth)
	return progression_curve(depth) * (common.MAX_SCRAP_QUALITY-1)
end

---@param scrap_tier number 0-(MAX_SCRAP_QUALITY-1)
---@return number quality effect for LuaEntity.local_effect 1==+100%, up to +100000%, which gives 100% legendary
local function quality_level_to_drill_effect(scrap_tier)
	local tier = math.floor(scrap_tier)
	local fract = (scrap_tier - tier)
	if tier <= 0 then
		return fract -- tier 1: 0-1, not 0.1-1 like needed for the later tiers
	end
	local lo = 10 ^ (tier - 1) -- tier 2: 1..10, tier 3: 10..100, ...
	return math.min(lo * (1 + 9 * fract), MAX_DRILL_QUALITY_BOOST)
end

---@param drill LuaEntity
---@param nearby_vaults { vault:Vault, tier:number }[]
local function update_drill_local_quality_effect(drill, nearby_vaults)
	local max_tier = 0
	local r = const.VAULT_DEFENSE_RADIUS - QSCRAP_DIST_FALLOFF_MIN_DIST
	for _,v in pairs(nearby_vaults) do
		-- linear falloff is fine for now
		-- TODO: 0 at edges fine (those are usually deep in oil ocean)
		local dist = common.get_distance(drill.position, v.vault.entity.position)
		local dist_factor = (dist - QSCRAP_DIST_FALLOFF_MIN_DIST) / r
		dist_factor = math.max(dist_factor, 0)
		if dist_factor < 1 then
			local falloff = dist_factor * QSCRAP_DIST_FALLOFF
			max_tier = math.max(v.tier - falloff, max_tier)
		end
	end
	
	-- TODO: position-hash based multiplier to avoid guaranteed quality, instead make it a distribution
	-- TODO: add tick based seed to hash to also vary over time, to avoid cheesing?
	-- actually... time+position just means unique random number per drill, just run a rand then...
	local effective_tier = max_tier
	--effective_tier = effective_tier - QSCRAP_TIER_SPREAD * math.random()
	--effective_tier = effective_tier * math.random()
	effective_tier = effective_tier * (1 - QSCRAP_SPREAD_RANGE * math.random() ^ QSCRAP_SPREAD_TOP_HEAVY)
	
	local effect = drill.local_effect or {}
	effect.quality = quality_level_to_drill_effect(effective_tier)
	drill.local_effect = effect
end

---@param surface LuaSurface
function depth_scaling.reset_all_drills_local_quality_effect(surface)
	for _,drill in pairs(surface.find_entities_filtered{type="mining-drill"}) do
		local effect = drill.local_effect
		if effect and effect.quality then
			effect.quality = nil
			drill.local_effect = effect
		end
	end
end

---@param scan OreScan
function Vault:update_quality(scan)
	-- cache depth on update, nearby_vaults will be slightly out of date, but depth changes slowly
	self.depth = ore.OreTracking.get_depth(scan)
	
	local nearby_vaults = {}
	for _,vault in pairs(self:get_this_and_overlapping_vaults()) do
		table.insert(nearby_vaults, {
			vault = vault,
			tier = depth_scaling.scrap_tier(vault.depth)
		})
	end

	local e = self.entity
	-- TODO: cache drills
	for _,drill in pairs(e.surface.find_entities_filtered{type="mining-drill", position=e.position, radius=const.VAULT_DEFENSE_RADIUS}) do
		update_drill_local_quality_effect(drill, nearby_vaults)
	end
end

---@param drill LuaEntity
function depth_scaling.update_quality_for_single_drill(drill)
	local nearby_vaults = {}
	for _,v in pairs(drill.surface.find_entities_filtered{name=const.VAULT_NAME, position=drill.position, radius=const.VAULT_DEFENSE_RADIUS}) do
		local vault = vault_from_entity(v)
		table.insert(nearby_vaults, {
			vault = vault,
			tier = depth_scaling.scrap_tier(vault.depth)
		})
	end

	update_drill_local_quality_effect(drill, nearby_vaults)
end

---@param surface LuaSurface
function depth_scaling.update_quality_for_all_vaults(surface)
	---@type LuaEntity[]|{v:Vault, scan:OreScan}[]
	local vaults = surface.find_entities_filtered{name=const.VAULT_NAME}
	for k,v in pairs(vaults) do
		local vault = vault_from_entity(v)
		vaults[k] = { v=vault, scan=vault:scan_ore() }
	end
	-- scan all first, then update
	for _,v in pairs(vaults) do
		v.v:update_quality(v.scan)
	end
end

return depth_scaling
