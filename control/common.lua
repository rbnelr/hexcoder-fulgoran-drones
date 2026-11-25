local const = require("const")
local myutil = require("lib.myutil")
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
		-- on_tick does the expensive update once per tick, re-reading the settings is cheap
		-- was an early out when already set, but while the game is paused no tick clears the flag, so changing a setting again before unpausing was skipped and the cache stayed wrong
		storage.settings_changed = true
	end
	
	if event.setting_type == "runtime-global" then
		local g = settings.global
		common.PROGRESSION_CURVE = g[const.MOD_NAME.."-progression-curve"].value --[[@as double]]
		common.MAX_SCRAP_QUALITY = g[const.MOD_NAME.."-max-scrap-quality"].value --[[@as double]]
		common.MAX_BOT_QUALITY   = g[const.MOD_NAME.."-max-bot-quality"].value --[[@as double]]
		common.WAVE_FREQ_MULT    = g[const.MOD_NAME.."-wave-freq"].value --[[@as double]]
		common.WAVE_SIZE_MULT    = g[const.MOD_NAME.."-wave-size"].value --[[@as double]]
		common.WAVE_MAX_TIME     = g[const.MOD_NAME.."-wave-max-time"].value --[[@as double]]
		common.DECAY_HARVESTABLE_BOTS = g[const.MOD_NAME.."-decay-dead-bot-resource"].value --[[@as boolean]]
	end
end
-- get each load, then update in on_runtime_mod_setting_changed
common.update_runtime_settings({name="_mod_load", setting_type="runtime-global"})

-- "Prepare for uninstall": mod paused, reset() has run, only on_runtime_mod_setting_changed is registered (control/events.lua)
-- read at load to decide what to register, then updated in initialize.on_runtime_mod_setting_changed
common.UNINSTALL_SETTING_NAME = const.MOD_NAME.."-uninstall"
common.UNINSTALL = settings.global[common.UNINSTALL_SETTING_NAME].value --[[@as boolean]]

---- Infinite scrap

local INF_SCRAP_PROTO = prototypes.entity["infinite-scrap"]
common.INF_SCRAP_NORMAL = INF_SCRAP_PROTO.normal_resource_amount
common.INF_SCRAP_MIN = INF_SCRAP_PROTO.minimum_resource_amount
common.INF_SCRAP_MIN_RATIO = common.INF_SCRAP_MIN / common.INF_SCRAP_NORMAL

-- try to bump such that its not visible in gui (yield floored to %)
common.INF_SCRAP_DEPLETED_BUMP_AMOUNT = math.max(math.floor(INF_SCRAP_PROTO.normal_resource_amount / 100 / 2), 1)

-- we drain faster so inf scrap does not last 100h until it reaches minimum, this does not change yield (other than reducing yield faster)
common.INF_SCRAP_DEPLETION_TO_MINING = 1 / INF_SCRAP_PROTO.infinite_depletion_resource_amount -- == const.INF_DEPLETION_RATE

common.WAVE_MIN_TIME = 20/60 -- allow for endless waves, 20 seconds to ensure mining rate is accurate, TODO: could lower
-- size multiplier limits, apply to variation*mining rate multiplier, applies to bot counts which depend on depth
common.WAVE_MIN_SIZE = 0.1 -- TODO: tune
common.WAVE_MAX_SIZE = 20 -- TODO: tune

common.BASE_MINING_RATE = 1000 -- 1500 is ~10 big drills, mining below full speed, this can go up to 10k with a more drills and speed modules
common.BASE_FREQUENCY = 1 / 10

---@alias AnimCurve {depth:number, val:number}[]

---@type AnimCurve
common.DEPTH_FREQ_CURVE = {{depth=0, val=0.5}, {depth=1, val=3}} -- TODO: tune

---@type table<string, AnimCurve>
common.BOT_COUNTS_CURVE = { -- TODO: tune, depth curve was 25% to 150% of whatever size was
	["fulgoran-defender"  ] = {{depth=0, val=0.75*25}, {depth=0.3, val=0.45*62.5}, {depth=0.7, val=0.20*112.5}, {depth=1, val=30}},
	["fulgoran-distractor"] = {{depth=0, val=0.25*25/6}, {depth=0.3, val=0.35*62.5/6}, {depth=0.7, val=0.45*112.5/6}, {depth=1, val=0.50*150/6}},
	["fulgoran-destroyer" ] = {{depth=0, val=0.00*25/10}, {depth=0.3, val=0.20*62.5/10}, {depth=0.7, val=0.35*112.5/10}, {depth=1, val=0.40*150/10}},
}

-- wave threat interpreted as %, 100% is a wave a basic "reasonable" defense setup usually manages
-- later game setups
common.THREAT_PER_BOT = { -- TODO: tune
	["fulgoran-defender"] = 1,
	["fulgoran-distractor"] = 6,
	["fulgoran-destroyer"] = 10,
}

local _threat_curve = {}
for type,curve in pairs(common.BOT_COUNTS_CURVE) do
	for i,v in pairs(curve) do
		_threat_curve[i] = _threat_curve[i] or {depth=v.depth, val=0}
		assert(_threat_curve[i].depth == v.depth)
		_threat_curve[i].val = _threat_curve[i].val + (v.val * common.THREAT_PER_BOT[type])
	end
end


-- infinite resource minimum amount is actually increased if initial yield > 100%
---@param initial_amount integer
function common.get_inf_scrap_minimum(initial_amount)
	if initial_amount <= common.INF_SCRAP_NORMAL then
		return common.INF_SCRAP_MIN -- 20% of normal
	else
		return math.floor(initial_amount * common.INF_SCRAP_MIN_RATIO) -- 20% of initial amount, is floored correct?
	end
end

-- valid initial and amount for setting infinite-scrap (convert, restore), pass initial = max(original, amount) so amount never ends up > initial
-- initial below the minimum is raised to minimum + bump
-- amount is raised to minimum + bump, or on_resource_depleted never gets called and the estimation will be wrong
-- set initial_amount before amount, the minimum depends on it
---@param initial number
---@param amount number
---@return number initial
---@return number amount
function common.clamp_inf_scrap(initial, amount)
	if initial < common.INF_SCRAP_MIN then initial = common.INF_SCRAP_MIN + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT end
	local minimum = common.get_inf_scrap_minimum(initial) + common.INF_SCRAP_DEPLETED_BUMP_AMOUNT
	if amount < minimum then amount = minimum end
	return initial, amount
end

-- Need to check drill radius for drill update_connections() to make it actually mine spawned dead bot resource
-- this should handle modded drills with large resource, but if drill with large radius exists we may get heavily performance degradation since update_connections() can be extremely slow
-- 
common.max_drill_radius = 0
for _,drill in pairs(prototypes.get_entity_filtered{{filter="type", type="mining-drill"}}) do
	for quality,_ in pairs(prototypes.quality) do
		local radius = drill.get_mining_drill_radius(quality)
		if radius > common.max_drill_radius then common.max_drill_radius = radius end
	end
end

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

-- debug print that also logs, call like this so log keep the right source line ref:
-- if const.DEBUG then log(dbg_print{"mgs ", "appended", <LocalisedString>}) end  or
-- if const.DEBUG then log(dbg_print(<LocalisedString>, sound, color)) end
-- command feedback (one player, no log): dbg_print("...", true, nil, player)
---@param msg LocalisedString
---@param sound boolean?
---@param color Color?
---@param player LuaPlayer? -- print only to this player, default all players
---@return LocalisedString
function dbg_print(msg, sound, color, player)
	msg = {"", const.PRINT_PREFIX, msg}
	local print_settings = {
		skip = defines.print_skip.never, -- don't deduplicate messages
		game_state = false, -- messages disappear (isn't this generally the case? like you can't scroll up in the console)
		sound = sound and defines.print_sound.use_player_settings or defines.print_sound.never,
		color = color or {1, 0.5, 0},
	}
	if player then
		player.print(msg, print_settings)
	else
		game.print(msg, print_settings)
	end
	return msg
end


-- returns uniform random in x-range to x+range
---@param x number
---@param range number absolute variation, for relative call like rand_variation(x, x*0.3)
---@param rng number? must be 0-1
---@return number result uniform in x +- range
function common.rand_variation(x, range, rng)
	rng = rng or math.random()
	return x + (rng*2-1) * range
end

-- varies a number x randomly by +- number*range
-- then rounds such that on average equals x
-- (rand_variation followed by floor or rand would bias the results)
---@param x number 
---@param range number absolute variation, for relative call like rand_variation_int(x, x*0.3)
---@param rng number? must be 0-1
---@return integer result uniform in x +- range, but integer
function common.rand_variation_int(x, range, rng)
	-- hard to explain in a comment how this works
	rng = rng or math.random()
	local w = math.max(1, myutil.round(2 * range))
	--return myutil.round(x + (rng - 0.5) * w)
	return math.floor(x + (rng - 0.5) * w + 0.5)
end

-- round to integer without biasing average, ie. 5.1 round to 5 90% of the time and to 6 10% of the time
---@param x number 
---@param rng number? must be 0-1
---@return integer result floor(x) or floor(x)+1 weighted by fract(x)
function common.rand_rounding(x, rng)
	rng = rng or math.random()
	return math.floor(x + rng)
end

---@param at number
---@param a number
---@param bt number
---@param b number
---@param t number
---@return number
local function interpolate(at, a, bt, b, t)
	local k = (t-at) / (bt-at)
	k = math.min(math.max(k, 0), 1)
	local k2 = (1-k)
	return k2 * a + k * b
end
---@param curve AnimCurve
---@param depth number
---@return number?
function common.eval_curve(curve, depth)
	local i = 1
	local count = #curve
	if count <= 1 then
		return count == 1 and curve[1].val or nil
	end
	while i < count - 1 and depth > curve[i+1].depth do
		i = i + 1
	end -- depth can be past end, if so interpolate clamps depth
	local a, b = curve[i], curve[i+1]
	
	return interpolate(a.depth, a.val, b.depth, b.val, depth)
end

return common
