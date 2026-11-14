local const = require("const")
local common = {}

---@type ModStorage
storage = storage

-- This actually sucks becaue on_runtime_mod_setting_changed gets called for each setting changed
-- so caching all settings there is questionable
-- and updating things like update_quality_for_all_vaults is straight up a bad idea, without annoying hacks like settings_changed

---- Runtime settings (store here, not in storage)
---@param event EventData.on_runtime_mod_setting_changed|{name:"_mod_load", setting_type:string}
function common.update_runtime_settings(event)
	if event.name ~= "_mod_load" then
		if storage.settings_changed then return end -- dumb hack
		storage.settings_changed = true
	end
	
	if event.setting_type == "runtime-global" then
		local g = settings.global
		common.PROGRESSION_CURVE = g[const.MOD_NAME.."-progression-curve"].value --[[@as double]]
		common.MAX_SCRAP_QUALITY = g[const.MOD_NAME.."-max-scrap-quality"].value --[[@as double]]
		common.MAX_BOT_QUALITY   = g[const.MOD_NAME.."-max-bot-quality"].value --[[@as double]]
		common.WAVE_FREQ         = g[const.MOD_NAME.."-wave-freq"].value --[[@as double]]
		common.WAVE_SIZE         = g[const.MOD_NAME.."-wave-size"].value --[[@as double]]
		common.WAVE_MIN_TIME     = g[const.MOD_NAME.."-wave-min-time"].value --[[@as double]]
		common.WAVE_MAX_TIME     = g[const.MOD_NAME.."-wave-max-time"].value --[[@as double]]
	end
end
-- get each load, then update in on_runtime_mod_setting_changed
common.update_runtime_settings({name="_mod_load", setting_type="runtime-global"})

---- Infinite vault scrap

local INF_SCRAP_PROTO = prototypes.entity["vault-scrap"]
common.INF_SCRAP_NORMAL = INF_SCRAP_PROTO.normal_resource_amount
common.INF_SCRAP_MIN = INF_SCRAP_PROTO.minimum_resource_amount
common.INF_SCRAP_MIN_RATIO = common.INF_SCRAP_MIN / common.INF_SCRAP_NORMAL

-- try to bump such that its not visible in gui (yield floored to %)
common.INF_SCRAP_DEPLETED_BUMP_AMOUNT = math.max(math.floor(INF_SCRAP_PROTO.normal_resource_amount / 100 / 2), 1)

-- we drain faster so inf scrap does not last 100h until it reaches minimum, this does not change yield (other than reducing yield faster)
common.INF_SCRAP_DEPLETION_TO_MINING = 1 / INF_SCRAP_PROTO.infinite_depletion_resource_amount -- == const.INF_DEPLETION_RATE

-- infinite resource minimum amount is actually increased if initial yield > 100%
---@param initial_amount integer
function common.get_inf_scrap_minimum(initial_amount)
	if initial_amount <= common.INF_SCRAP_NORMAL then
		return common.INF_SCRAP_MIN -- 20% of normal
	else
		return math.floor(initial_amount * common.INF_SCRAP_MIN_RATIO) -- 20% of initial amount, is floored correct?
	end
end

-- This is super dodgy, if there are modded drills with high radius we may miss to update them (they won't mine the newly added bot resource)
common.max_drill_radius = 0
for _,drill in pairs(prototypes.get_entity_filtered{{filter="type", type="mining-drill"}}) do
	for quality,_ in pairs(prototypes.quality) do
		local radius = drill.get_mining_drill_radius(quality)
		if radius > common.max_drill_radius then common.max_drill_radius = radius end
	end
end

const.QUALITY_IDS = {[1]="normal"}
do
	local q = prototypes.quality["normal"]
	while q.next do
		q = q.next
		table.insert(const.QUALITY_IDS, q.name)
	end
end
const.MAX_QUALITY_ID = #const.QUALITY_IDS

-- update drills which touch tile at position, or in position+square radius (for vault)
---@param surface LuaSurface
---@param position MapPosition
---@param radius? number -- default to 0
function common.update_drill_connections_near(surface, position, radius)
	local r = common.max_drill_radius + (radius or 0) -- square radius!
	local area = {{position.x-r, position.y-r}, {position.x+r, position.y+r}}
	-- this includes collision box of drill, not really what we want, but I would have added 1 to radius to make sure anyway
	for _,drill in pairs(surface.find_entities_filtered{area=area, type="mining-drill"}) do
		--local p = drill.position
		--rendering.draw_rectangle{left_top={p.x-2.5, p.y-2.5}, right_bottom={p.x+2.5, p.y+2.5}, surface=surface, filled=false, color={0,0,1}, time_to_live=60*5}
		drill.update_connections()
	end
end

return common
