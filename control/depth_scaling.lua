local const = require("const")
local common = require("control.common")
local myutil = require("lib.myutil")
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
	local rng = math.random()
	--if     rng >= chance then    -- tier = tier + 1
	--elseif rng >= chance*0.1 then   tier = tier + 2
	--elseif rng >= chance*0.01 then  tier = tier + 3
	--elseif rng >= chance*0.001 then tier = tier + 4
	--else                            tier = tier + 5 end
	--return math.min(tier, 4)
	while tier < const.MAX_QUALITY_ID do
		tier = tier + 1
		if rng >= chance then break end
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
		local tier = depth_scaling.scrap_tier(vault.latest_depth)
		
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

---@param scan OreScan
function Vault:update_quality_for_vault_drills(scan)
	-- cache depth on update, nearby_vaults will be slightly out of date, but depth changes slowly
	self.latest_depth = ore.OreTracker.get_depth(scan)
	
	local nearby_vaults = self:find_this_and_overlapping_vaults()

	local e = self.entity
	-- TODO: cache drills
	for _,drill in pairs(e.surface.find_entities_filtered{type="mining-drill", position=e.position, radius=const.VAULT_DEFENSE_RADIUS}) do
		update_drill_local_quality_effect(drill, nearby_vaults)
	end
end

---@param drill LuaEntity
function depth_scaling.update_quality_for_single_drill(drill)
	update_drill_local_quality_effect(drill, find_nearby_vaults(drill))
end

---@param surface LuaSurface
function depth_scaling.update_quality_for_all_vaults(surface)
	---@type LuaEntity[]|{v:Vault, scan:OreScan}[]
	local vaults = surface.find_entities_filtered{name=const.VAULT_NAME}
	local vaults_to_update = {}
	for k,v in pairs(vaults) do
		local vault = get_or_init_vault(v)
		if vault.has_drills then -- avoid untouched vaults to prevent lag?
			vaults_to_update[k] = { v=vault, scan=vault:scan_ore() }
		end
	end
	-- scan all first, then update
	for _,v in pairs(vaults_to_update) do
		v.v:update_quality_for_vault_drills(v.scan)
	end
end

return depth_scaling
