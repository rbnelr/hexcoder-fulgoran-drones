local const = require("const")
local common = require("control.common")
local myutil = require("lib.myutil")

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

-- verified 2026-11-16 (/vaults-test test_mining_quality_roll, 100k outputs per effect, +50% to +99900%):
--  P(quality >= k) = min(q * 10^-(k-1), 1), not chained per step (was assumed chained, which undercounted the higher qualities)
--  roll_bot_quality_from_tier rolls the same way
-- quality output of regular scrap mined with drill quality effect ("-" = under 0.1%)
-- "value" tiers: 1, 1.3, 1.6, 1.9, 2.5 (most quality effects scale like this)
-- "science" tiers: 1x, 2x, 3x, 4x, 6x (science yield scales like this)
-- "tier": scrap_tier() that quality_level_to_drill_effect() maps to this effect (before distance falloff and spread)
--  0-1 linear, then each tier is 10x effect, linear within the tier (so x.44 = 5x the tier's start), MAX_SCRAP_QUALITY = max tier + 1
-- | tier | effect   | normal | uncommon | rare | epic | legendary | eff. value | eff. science |
-- |------|----------|--------|----------|------|------|-----------|------------|--------------|
-- | 0    | +0%      |   100% |        - |    - |    - |         - |       1.00 |         1.00 |
-- | 0.5  | +50%     |    50% |      45% | 4.5% | 0.5% |         - |       1.17 |         1.56 |
-- | 1    | +100%    |      - |      90% |   9% | 0.9% |      0.1% |       1.33 |         2.11 |
-- | 1.44 | +500%    |      - |      50% |  45% | 4.5% |      0.5% |       1.47 |         2.56 |
-- | 2    | +1000%   |      - |        - |  90% |   9% |        1% |       1.64 |         3.12 |
-- | 2.44 | +5000%   |      - |        - |  50% |  45% |        5% |       1.78 |         3.60 |
-- | 3    | +10000%  |      - |        - |    - |  90% |       10% |       1.96 |         4.20 |
-- | 3.44 | +50000%  |      - |        - |    - |  50% |       50% |       2.20 |         5.00 |
-- | 4    | +100000% |      - |        - |    - |    - |      100% |       2.50 |         6.00 |

-- quality scrap is capped to quality tech unlocks by the engine
-- bots are capped by us via dead_bots.downgrade_locked_qualities()
-- TODO: quality level unlocks should maybe be reflected in the gui and also cap scrap_tier() etc., so drills are visibly capped
-- if we cap at scrap_tier() the distance falloff would punish more than if we dont or just cap each drill's, but capping each drill changes the distribution

-- Assemblers track the minimum quality bonus during each crafting cycle (normal and prod bard) to avoid cheesing by inserting just before finishing
-- I've tested and mining drills _do no_, this means me swapping local_effect.quality every 10s with a randomly distributed number
--  does not bias numbers downwards like I would have expected, however even if it did, at 1-10 scrap/s, every 10s would be a tiny difference

-- drill has max qualtiy boost = 1000 (100000%), ie. 100% legendary from regular scrap
local MAX_DRILL_QUALITY_BOOST = prototypes.entity["big-mining-drill"].effect_receiver.quality_limits.high

-- Could add settings that change quality spread shape
-- eg. range=1, top_heavy=2 => encounter any quality, most of Q_k at Tier_k, but a mix of everything
--     range=0.5, top_heavy=1 => stop seeing Q0 at tier 2 and Q1 at tier 4, 

-- vault is 14x8, drills are 5x5, so horizontal min possible distance is (7+2.5)
local QSCRAP_DIST_FALLOFF_MIN_DIST = 12 -- 12 allows drills touching the corners to get the full tier, while further away suffers
local QSCRAP_DIST_FALLOFF = 1 -- falloff at max dist (defense radius) in tiers

local QSCRAP_SPREAD_RANGE = 1
local QSCRAP_SPREAD_TOP_HEAVY = 2

local BOT_SPREAD_RANGE = 0.5
local BOT_SPREAD_TOP_HEAVY = 2

-- rough output mix with spread: effective tier = tier * (1 - range * rand^top_heavy), averages (1 - range/3) * tier
-- (numerically integrated with the verified roll, "-" = under 0.1%, value/science weights as in the table above)
-- scrap (range 1, top-heavy 2), drill within QSCRAP_DIST_FALLOFF_MIN_DIST (at the radius edge: tier - QSCRAP_DIST_FALLOFF)
--  never gets rid of normal scrap, since the tier can spread down to 0
-- | tier | normal | uncommon | rare | epic | legendary | value | science |
-- |------|--------|----------|------|------|-----------|-------|---------|
-- | 0.5  |    67% |      30% | 3.0% | 0.3% |         - |  1.11 |    1.37 |
-- | 1    |    33% |      60% | 6.0% | 0.6% |         - |  1.22 |    1.74 |
-- | 1.5  |    19% |      55% |  23% | 2.3% |      0.3% |  1.33 |    2.09 |
-- | 2    |    14% |      35% |  46% | 4.6% |      0.5% |  1.43 |    2.43 |
-- | 2.5  |    11% |      24% |  45% |  18% |      2.0% |  1.54 |    2.78 |
-- | 3    |   8.9% |      19% |  31% |  38% |      4.2% |  1.64 |    3.14 |
-- | 3.5  |   7.5% |      15% |  22% |  38% |       17% |  1.78 |    3.59 |
-- | 4    |   6.5% |      13% |  17% |  27% |       36% |  1.93 |    4.09 |
-- bots (range 0.5, top-heavy 2)
-- | tier | normal | uncommon | rare | epic | legendary | value | science |
-- |------|--------|----------|------|------|-----------|-------|---------|
-- | 0.5  |    58% |      38% | 3.8% | 0.4% |         - |  1.14 |    1.46 |
-- | 1    |    17% |      75% | 7.5% | 0.8% |         - |  1.28 |    1.93 |
-- | 1.5  |   2.2% |      64% |  31% | 3.1% |      0.3% |  1.41 |    2.36 |
-- | 2    |      - |      30% |  63% | 6.3% |      0.7% |  1.54 |    2.78 |
-- | 2.5  |      - |      11% |  61% |  25% |      2.8% |  1.67 |    3.22 |
-- | 3    |      - |     4.0% |  37% |  53% |      5.9% |  1.80 |    3.66 |
-- | 3.5  |      - |     0.8% |  22% |  53% |       24% |  1.97 |    4.24 |
-- | 4    |      - |        - |  12% |  36% |       51% |  2.17 |    4.90 |

---@param depth number 0-1
---@return number 0-1
local function progression_curve(depth)
	depth = math.min(math.max(depth, 0), 1)
	return depth ^ (1 / common.PROGRESSION_CURVE)
end
depth_scaling.progression_curve = progression_curve

-- inverse of progression_curve
---@param progression number 0-1
---@return number depth 0-1
function depth_scaling.depth_for_progression(progression)
	progression = math.min(math.max(progression, 0), 1)
	return progression ^ common.PROGRESSION_CURVE
end

-- Setting is 1-5 (to match quality numbering and dots in icons), also display in gui like that
-- return as 0-4, or else distance scaling is too strong
---@param depth number 0-1
---@return number scrap_tier 0-(MAX_SCRAP_QUALITY-1)
function depth_scaling.scrap_tier(depth)
	return progression_curve(depth) * (common.MAX_SCRAP_QUALITY-1)
end

---@param depth number 0-1
---@return number bot_tier 0-(MAX_BOT_QUALITY-1)
function depth_scaling.bot_tier(depth)
	return progression_curve(depth) * (common.MAX_BOT_QUALITY-1)
end

---@param scrap_tier number 0-(MAX_SCRAP_QUALITY-1)
---@return number quality effect for LuaEntity.local_effect 1==+100%, up to +100000%, which gives 100% legendary
local function quality_level_to_drill_effect(scrap_tier)
	local tier = math.floor(scrap_tier)
	local chance = (scrap_tier - tier)
	if tier <= 0 then
		return chance -- tier 1: 0-1, not 0.1-1 like needed for the later tiers
	end
	local lo = 10 ^ (tier - 1) -- tier 2: 1..10, tier 3: 10..100, ...
	return math.min(lo * (1 + 9 * chance), MAX_DRILL_QUALITY_BOOST)
end

-- bots spawn as quality no matter what quality is researched TODO: check if this can be made to work
---@param bot_tier number 0-(MAX_BOT_QUALITY-1)
---@return number quality 1-5
function depth_scaling.roll_bot_quality_from_tier(bot_tier)
	bot_tier = bot_tier * (1 - BOT_SPREAD_RANGE * math.random() ^ BOT_SPREAD_TOP_HEAVY)
	
	local tier = math.floor(bot_tier)
	local chance = (bot_tier - tier)
	if tier > 0 then
		chance = 0.1 + chance*0.9
	end
	
	-- LuaQualityPrototype.roll_quality does also exist, but would need to run quality_level_to_drill_effect to get effect?
	--local roll = math.random() / chance -- clever, but div by 0!
	--local up
	--if     roll >= 1.0 then   up = 1
	--elseif roll >= 0.1 then   up = 2
	--elseif roll >= 0.01 then  up = 3
	--elseif roll >= 0.001 then up = 4
	--else                      up = 5 end
	--return math.min(tier + up, const.MAX_QUALITY_ID)
	
	-- TODO: handle modded quality chances (the 10% can be an arbitary number
	-- could store in array next to QUALITY_IDS (quality prototype next_probability/chain_probability)
	local rnd = math.random()
	-- decrease chance each iteration, don't test when we reach max
	tier = tier + 1
	while tier < const.MAX_QUALITY_ID and rnd < chance do
		tier = tier + 1
		chance = chance*0.1
	end
	return tier
end

---@param drill LuaEntity
---@param nearby_vaults Vault[] -- either vaults that thouch this drill or, more if using the overlapping list for all drills from one vault
local function update_drill_local_quality_effect(drill, nearby_vaults)
	local effect = drill.local_effect
	if effect == nil then return end -- no effect receiver?
	
	local max_tier = 0
	local r = const.VAULT_DEFENSE_RADIUS - QSCRAP_DIST_FALLOFF_MIN_DIST
	for _,vault in pairs(nearby_vaults) do
		-- scrap_tier does some math over and over for each drill if we update all drills around vault
		-- but its preferable over building that into its own list in the caller, if this impacts perf could optimize via caching in here?
		local tier = depth_scaling.scrap_tier(vault.scrap_tracker:scanned_depth())
		
		-- linear falloff by a constant along radius
		local dist = myutil.get_distance(drill.position, vault.entity.position)
		local dist_factor = (dist - QSCRAP_DIST_FALLOFF_MIN_DIST) / r
		dist_factor = math.max(dist_factor, 0)
		if dist_factor < 1 then
			local falloff = dist_factor * QSCRAP_DIST_FALLOFF
			max_tier = math.max(tier - falloff, max_tier)
		end
	end
	
	-- TODO: position-hash based multiplier to avoid guaranteed quality, instead make it a distribution
	-- TODO: add tick based seed to hash to also vary over time, to avoid cheesing?
	-- actually... time+position just means unique random number per drill, just run a rand then...
	local effective_tier = max_tier
	--effective_tier = effective_tier - QSCRAP_TIER_SPREAD * math.random()
	--effective_tier = effective_tier * math.random()
	effective_tier = effective_tier * (1 - QSCRAP_SPREAD_RANGE * math.random() ^ QSCRAP_SPREAD_TOP_HEAVY)
	
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

-- depth is stored in the ore trackers (updated by their poll), nearby vaults may be slightly out of date, but depth changes slowly
---@param vault Vault
function depth_scaling.update_quality_for_vault_drills(vault)
	local nearby_vaults = vault:find_this_and_overlapping_vaults()

	for _,drill in pairs(vault.mining_drills) do
		if drill.valid then
			update_drill_local_quality_effect(drill, nearby_vaults)
		end
	end
end

---@param drill LuaEntity
function depth_scaling.update_quality_for_single_drill(drill)
	update_drill_local_quality_effect(drill, find_nearby_vaults(drill.surface, drill.position))
end

-- settings changed (progression curve, max quality), depth itself does not change, so no scans
---@param surface LuaSurface
function depth_scaling.update_quality_for_all_vaults(surface)
	for _,v in pairs(surface.find_entities_filtered{name=const.VAULT_NAME}) do
		local vault = get_or_init_vault(v)
		if vault:has_drills() then
			depth_scaling.update_quality_for_vault_drills(vault)
		end
	end
end

return depth_scaling
