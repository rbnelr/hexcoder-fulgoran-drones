-- in-game test setups, run via /vaults-test <test name> <param1> <param2> ...
-- params are split by spaces, converted to numbers where possible, and passed positionally after the player
-- a test function sets things up and may return an update function, which makes the test "active":
--  update is called every UPDATE_PERIOD ticks until it returns true (done)
-- active tests are file-local (functions can't go into storage): they don't survive save/load and aren't multiplayer safe, debug only
local const = require("const")
require("control.common") -- dbg_print

local tests = {}

---@alias TestUpdate fun(): boolean? -- return true when done
---@alias TestFunc fun(player: LuaPlayer, ...): TestUpdate?

---@type table<string, TestFunc>
local test_funcs = {}

---@type table<string, TestUpdate>
local active_tests = {}

local UPDATE_PERIOD = 10
local registered = false

local function print_and_log(msg, player)
	dbg_print(msg, false, nil, player)
	log(const.PRINT_PREFIX..msg)
end

local function update_all()
	for name,update in pairs(active_tests) do
		if update() then
			active_tests[name] = nil
		end
	end
	if next(active_tests) == nil then
		script.on_nth_tick(UPDATE_PERIOD, nil)
		registered = false
	end
end

---@param player LuaPlayer
---@param name string
---@param args any[]
function tests.run(player, name, args)
	local fn = test_funcs[name]
	if fn == nil then
		local names = {}
		for n in pairs(test_funcs) do table.insert(names, n) end
		table.sort(names)
		dbg_print("Unknown test '"..name.."', available: "..table.concat(names, ", "), true, nil, player)
		return
	end
	if active_tests[name] then
		dbg_print("Test '"..name.."' is already running", true, nil, player)
		return
	end

	local update = fn(player, table.unpack(args))
	if update then
		active_tests[name] = update
		if not registered then
			script.on_nth_tick(UPDATE_PERIOD, update_all)
			registered = true
		end
	end
end

--#region test_mining_quality_roll

local QUALITIES = { "normal", "uncommon", "rare", "epic", "legendary" }

-- quality roll models to compare against (release_plan.md 3.3 / 2.7), effect q: 1 == +100%
-- chained: step k succeeds with min(q * 0.1^(k-1), 1)
local function expected_chained(q)
	local p, reach = {0,0,0,0,0}, 1
	for k=1,4 do
		local s = math.min(q * 0.1^(k-1), 1)
		p[k] = p[k] + reach * (1 - s)
		reach = reach * s
	end
	p[5] = p[5] + reach
	return p
end
-- flat: guaranteed steps, then one step with the remaining chance, then flat 10% per further step (what roll_bot_quality_from_tier does)
local function expected_flat(q)
	local p, k = {0,0,0,0,0}, 0
	while k < 4 and q * 0.1^k >= 1 do k = k + 1 end
	if k == 4 then p[5] = 1 return p end
	local s = q * 0.1^k
	p[k+1] = 1 - s
	local reach = s
	k = k + 1
	while k < 4 do
		p[k+1] = reach * 0.9
		reach = reach * 0.1
		k = k + 1
	end
	p[5] = p[5] + reach
	return p
end

-- layout relative to the ore tile (0,0), drills face each other in pairs and share a chest between them:
--  top pair rows -5..-1, bottom pair rows 1..5, ore in row 0, chests in column 0
--  beacon rows above and below (only speed reaches the drills, beacons don't allow quality)
--  power: an energy interface + substation on each side
-- big drill resource_searching_radius 6.49, vector_to_place_result {0,-2.85}
local DRILL_LAYOUT = {
	{ pos={-2.5,-2.5}, dir=defines.direction.east },
	{ pos={ 3.5,-2.5}, dir=defines.direction.west },
	{ pos={-2.5, 3.5}, dir=defines.direction.east },
	{ pos={ 3.5, 3.5}, dir=defines.direction.west },
}
local CHEST_LAYOUT = { {0.5,-2.5}, {0.5,3.5} }
local BEACON_LAYOUT = {
	{-4.5,-6.5}, {-1.5,-6.5}, {1.5,-6.5}, {4.5,-6.5},
	{-4.5, 7.5}, {-1.5, 7.5}, {1.5, 7.5}, {4.5, 7.5},
}
local POWER_LAYOUT = {
	{ name="substation", pos={-7,1} }, { name="electric-energy-interface", pos={-7,-1} },
	{ name="substation", pos={ 8,1} }, { name="electric-energy-interface", pos={ 8,-1} },
}
local MINING_AREA = {{-9,-9}, {10,10}} -- union of the drills' mining areas, must not contain other resources

---@param player LuaPlayer
---@param num_ore number? outputs to mine (default 10000), the tile gets half of that (big drill drain 50%)
---@param quality_bonus number? total drill quality effect, 1 == +100% (default 0.5)
---@return TestUpdate?
function test_funcs.test_mining_quality_roll(player, num_ore, quality_bonus)
	num_ore = tonumber(num_ore) or 10000
	quality_bonus = tonumber(quality_bonus) or 0.5

	local surface = player.surface
	local force = player.force --[[@as LuaForce]]
	local origin = { x=math.floor(player.position.x), y=math.floor(player.position.y) - 16 }
	local function at(p) return { x=origin.x + p[1], y=origin.y + p[2] } end

	-- engine caps output quality at unlocked qualities
	for _,q in ipairs(QUALITIES) do
		if not force.is_quality_unlocked(q) then
			dbg_print("Warning: quality '"..q.."' is locked, results will be capped", true, nil, player)
		end
	end

	-- the mod rewrites local_effect of drills near vaults on every poll
	if surface.count_entities_filtered{name=const.VAULT_NAME, position=at({0.5,0.5}), radius=const.VAULT_DEFENSE_RADIUS + 10} > 0 then
		dbg_print("Too close to a vault ruin (its poll would overwrite the drills' quality effect), move away", true, nil, player)
		return
	end
	if surface.count_entities_filtered{area={at(MINING_AREA[1]), at(MINING_AREA[2])}, type="resource"} > 0 then
		dbg_print("Resources in the test area (16 tiles north of you), move to an empty spot", true, nil, player)
		return
	end

	-- check everything first so nothing is left half built
	local to_place = {}
	for _,d in ipairs(DRILL_LAYOUT) do table.insert(to_place, { name="big-mining-drill", position=at(d.pos), direction=d.dir }) end
	for _,p in ipairs(CHEST_LAYOUT)  do table.insert(to_place, { name="steel-chest", position=at(p) }) end
	for _,p in ipairs(BEACON_LAYOUT) do table.insert(to_place, { name="beacon", position=at(p), quality="legendary" }) end
	for _,p in ipairs(POWER_LAYOUT)  do table.insert(to_place, { name=p.name, position=at(p.pos) }) end
	for _,e in ipairs(to_place) do
		if not surface.can_place_entity{name=e.name, position=e.position, direction=e.direction, force=force} then
			dbg_print("Can't place "..e.name.." in the test area (16 tiles north of you), move to an empty spot", true, nil, player)
			return
		end
	end

	local ore = surface.create_entity{name="scrap", position=at({0.5,0.5}), amount=math.max(math.ceil(num_ore / 2), 1)}
	if ore == nil then
		dbg_print("Failed to create the scrap tile", true, nil, player)
		return
	end

	local entities, drills, chests = {}, {}, {}
	for _,e in ipairs(to_place) do
		local ent = surface.create_entity{name=e.name, position=e.position, direction=e.direction, quality=e.quality, force=force}
		---@cast ent -nil
		table.insert(entities, ent)
		if ent.type == "mining-drill" then
			table.insert(drills, ent)
			ent.get_module_inventory().insert{name="speed-module-3", count=4, quality="legendary"} ---@diagnostic disable-line
			-- speed modules have a quality penalty in the drill, compensated in the first update once drill.effects is known
			local effect = ent.local_effect or {}
			effect.quality = quality_bonus
			ent.local_effect = effect
			ent.disabled_by_script = true
		elseif ent.type == "beacon" then
			ent.get_module_inventory().insert{name="speed-module-3", count=2, quality="legendary"} ---@diagnostic disable-line
		elseif ent.type == "container" then
			table.insert(chests, ent)
		end
	end

	local counts = {} ---@type table<string, integer>
	local calibrated = false
	local start_tick = game.tick

	local function collect()
		for _,chest in ipairs(chests) do
			if chest.valid then
				local inv = chest.get_inventory(defines.inventory.chest) ---@cast inv -nil
				for _,item in pairs(inv.get_contents()) do
					local q = item.quality or "normal"
					counts[q] = (counts[q] or 0) + item.count
				end
				inv.clear()
			end
		end
	end

	local function cleanup()
		for _,e in ipairs(entities) do
			if e.valid then e.destroy() end
		end
		if ore.valid then ore.destroy() end
	end

	print_and_log(string.format("test_mining_quality_roll: %d ore (tile amount %d), quality %+.0f%%, at %d,%d",
		num_ore, ore.amount, quality_bonus*100, origin.x, origin.y), player)

	return function()
		if not calibrated then
			-- set local_effect so the drill's total quality effect is exactly quality_bonus
			for _,drill in ipairs(drills) do
				if not drill.valid then cleanup() return true end
				local actual = drill.effects and drill.effects.quality or 0
				local effect = drill.local_effect ---@cast effect -nil
				effect.quality = (effect.quality or 0) + (quality_bonus - actual)
				drill.local_effect = effect
			end
			calibrated = true
			return false -- let the new effects apply before enabling
		end

		for _,drill in ipairs(drills) do
			if drill.valid and drill.disabled_by_script then
				drill.disabled_by_script = false
			end
		end

		collect()
		if ore.valid then return false end

		-- done, tile mined out
		local total = 0
		for _,c in pairs(counts) do total = total + c end
		local effective = {}
		for _,drill in ipairs(drills) do
			table.insert(effective, string.format("%+.2f%%", (drill.valid and drill.effects and drill.effects.quality or 0)*100))
		end
		local chained = expected_chained(quality_bonus)
		local flat = expected_flat(quality_bonus)

		print_and_log(string.format("test_mining_quality_roll done: %d outputs in %.1fs, quality %+.0f%%, drill effects: %s, mining productivity bonus %+.0f%%",
			total, (game.tick - start_tick)/60, quality_bonus*100, table.concat(effective, " "), force.mining_drill_productivity_bonus*100), player)
		print_and_log("  quality   | count  | actual  | chained | flat 10%", player)
		for i,q in ipairs(QUALITIES) do
			local c = counts[q] or 0
			print_and_log(string.format("  %-9s | %6d | %6.2f%% | %6.2f%% | %6.2f%%",
				q, c, total > 0 and c / total * 100 or 0, chained[i]*100, flat[i]*100), player)
		end

		cleanup()
		return true
	end
end
--#endregion

--#region wave

-- /vaults-test wave (options): the hovered vault | /vaults-test wave all (options): every vault with a test map tag on fulgora, in parallel
-- per site config from a map tag in its radius whose text starts with "test": "test <name> threat=<percent> (depth=<percent>) (quality=<1-5>) (tech=<level>)"
--  the words without = are the setup name, without threat: what the vault would spawn now, without quality: from depth
--  threat is the base wave threat at research level 2, snapped to the threat ladder 25, 35, 50, 70, 100, 140, 200, ... (x1.4/x1.43 per step, x2 per two)
--  depth fixes the depth for every research level (default: from the research level, WAVE_TECH_DEPTH)
--  tag tech is only used when testing a single vault, with several sites the techs list applies to all (research is per force)
-- grid: research levels above 2 add ladder steps (WAVE_TECH_STEPS: L4 +2 = x2, L7 +4 = x4), every site runs base + steps,
--  so all sites with the same base share the same threat columns; the wave size follows from threat / threat per size at the depth
-- options (command, override the tags; lists comma separated):
--  techs=<levels>    weapon research levels to test (see WAVE_DEFAULT_TECHS), default 2,4,7 for several sites, the tag/tech= for one, else research unchanged
--  steps=<n>         ladder steps above each site's base threat (at its research level), default 0,1,2 (x1, x1.4, x2)
--  threat=<percent>, depth=<percent> as in the tag, for all sites
--  day=0 / night=0   drop the day / night pass, noon=1 adds a frozen noon pass
--  repeats=<n>       repeat the whole grid
--  hold_kept=<%>     a wave counts as held if all drones died, mining kept >= this (default 50) and
--  hold_turrets=<%>  turret downtime <= this (default 10)
-- every site runs every config, grid order: tech, pass, step (ascending), each run: reset all sites, wait (ammo refill), baseline (output without a wave), all waves at once until every drone died or left
-- depth is the progression in % (after the progression curve, so the quality tiers scale linearly with it, wave counts use the ore depth before the curve as in the game)
-- it's set for real: the scrap around the vault is restored to the amount that gives the matching ore depth (drill quality, yield and gui follow)
-- tech: every weapon research series is set for real to that level (even dps steps, science packs ignored), restored at the end
-- day: time running, waves start at dawn (end of night, wait and baseline before it), the accumulators must last the whole day (realistic worst case), night: frozen at midnight (best case), noon: frozen at noon (stored charge only)
-- output chests: infinity chests in the radius without ammo, read and cleared every update (so they must not use "remove unfiltered items")
-- power: accumulators charged and storage tanks with steam (or empty at test start) filled with 500 degree steam on reset
-- ammo: requester chests requesting ammo are filled to their request count on reset and again after the wait, infinity chests supply infinite ammo anyway
-- results: one json line per run and site in script-output/vaults-test/

local common = require("control.common")
local ore = require("control.ore_tracking")
local spawning = require("control.spawning")
local depth_scaling = require("control.depth_scaling")
local myutil = require("lib.myutil")

local WAVE_RESET_WAIT = 5*60
local WAVE_BASELINE = 20*60
local WAVE_TIMEOUT = 5*60*60
local WAVE_DEFAULT_STEPS = { 0, 1, 2 }
-- depth (progression %) per research level, interpolated in between, clamped outside
-- +25% depth is about x1.7 threat per size, a research step about x2 dps, so each level faces its own composition and quality
local WAVE_TECH_DEPTH = { {depth=0, val=0}, {depth=2, val=25}, {depth=4, val=50}, {depth=7, val=75}, {depth=10, val=100} } -- depth=research level, val=depth %
-- threat ladder steps added per research level (interpolated, rounded): L4 +2 (x2), L7 +4 (x4)
-- measured limit gain L2 -> L7 (run of 2026-11-23): guns x6, uranium x8+, lasers and tesla about x3, large mixed sites about x4
local WAVE_TECH_STEPS = { {depth=0, val=-2}, {depth=2, val=0}, {depth=4, val=2}, {depth=7, val=4}, {depth=10, val=6} } -- depth=research level, val=steps

-- threat ladder: step n = 25% * 2^floor(n/2), odd steps x1.4 (25, 35, 50, 70, 100, 140, ...)
---@param n integer
local function ladder_threat(n)
	return 25 * 2^math.floor(n / 2) * (n % 2 == 1 and 1.4 or 1)
end
-- nearest ladder step of a threat in %
---@param threat number
local function ladder_step(threat)
	return math.floor(math.log(math.max(threat, 1) / 25) / math.log(math.sqrt(2)) + 0.5)
end
local WAVE_HOLD_KEPT = 50 -- %
local WAVE_HOLD_TURRETS = 10 -- %
local WAVE_TECH_SERIES = {
	"physical-projectile-damage", "weapon-shooting-speed",
	"laser-weapons-damage", "laser-shooting-speed",
	"electric-weapons-damage", "stronger-explosives",
}

-- tech=<level>: every weapon research series researched up to that level (capped at its max, e.g. weapon shooting speed 6),
-- ignoring science packs, so the dps steps are even rather than matching a player's science
-- vanilla dps multipliers (gun turret: (1+bullet dmg)*(1+turret attack)*(1+shooting speed), laser turret: (1+dmg)*(1+speed)):
--  level  1     2     3     4     5     6     7     8     9     10
--  gun    1.33  1.87  2.94  4.61  6.80  10.0  12.1  14.4  16.9  19.6
--  laser  1.32  1.82  2.72  3.99  5.98  8.91  12.8  15.0  17.3  19.5
-- levels 2, 4, 6, 10 step about x2 each
local WAVE_DEFAULT_TECHS = { 2, 4, 7 } -- 10 on request (techs=2,4,6,12)

-- the techs of the weapon research series (series-1, series-2, ... until one is missing)
---@param force LuaForce
---@return LuaTechnology[]
local function weapon_techs(force)
	local techs = {}
	for _,series in ipairs(WAVE_TECH_SERIES) do
		local i = 1
		while force.technologies[series.."-"..i] do
			table.insert(techs, force.technologies[series.."-"..i])
			i = i + 1
		end
	end
	return techs
end

---@param force LuaForce
---@return table<LuaTechnology, {researched: boolean, level: integer}>
local function save_research(force)
	local saved = {}
	for _,tech in pairs(weapon_techs(force)) do
		saved[tech] = { researched=tech.researched, level=tech.level }
	end
	return saved
end

-- writing level n of an infinite tech researches it up to n-1, reset_technology_effects recomputes all bonuses from the research state
---@param force LuaForce
---@param level integer
local function set_research_level(force, level)
	for _,tech in pairs(weapon_techs(force)) do
		local proto = tech.prototype
		if proto.max_level > proto.level then
			tech.researched = false
			tech.level = math.max(level + 1, proto.level)
		else
			tech.researched = proto.level <= level
		end
	end
	force.reset_technology_effects()
end

---@param force LuaForce
---@param saved table<LuaTechnology, {researched: boolean, level: integer}>
local function restore_research(force, saved)
	for tech,s in pairs(saved) do
		if tech.valid then
			if tech.prototype.max_level > tech.prototype.level then tech.level = s.level end
			tech.researched = s.researched
		end
	end
	force.reset_technology_effects()
end

local COMPARE = { -- unicode forms as UTF-8 byte escapes (Lua 5.2 has no \u{} escapes)
	["="]  = function(a, b) return a == b end,
	["!="] = function(a, b) return a ~= b end, ["\226\137\160"] = function(a, b) return a ~= b end,
	["<"]  = function(a, b) return a < b end,
	[">"]  = function(a, b) return a > b end,
	["<="] = function(a, b) return a <= b end, ["\226\137\164"] = function(a, b) return a <= b end,
	[">="] = function(a, b) return a >= b end, ["\226\137\165"] = function(a, b) return a >= b end,
}
-- event filters of the hooked events, left to right like the engine ("and" combines with the result so far, otherwise "or")
-- only the filter kinds control/events.lua uses
---@param filters table[]?
---@param event table
---@return boolean
local function filter_matches(filters, event)
	if filters == nil or #filters == 0 then return true end
	local result = false
	for i,f in ipairs(filters) do
		local m
		if f.filter == "type" then m = event.entity.type == f.type
		elseif f.filter == "name" then m = event.entity.name == f.name
		elseif f.filter == "final-health" then m = COMPARE[f.comparison](event.final_health, f.value)
		else error("filter_matches: unsupported event filter "..tostring(f.filter)) end
		if f.invert then m = not m end
		if i == 1 then result = m
		elseif f.mode == "and" then result = result and m
		else result = result or m end
	end
	return result
end

-- record events unfiltered, then call the registered handler for the events its filter lets through
---@param handlers table<defines.events, fun(event: table)>
---@return table<defines.events, {handler: function?, filters: table[]?}> saved
local function hook_events(handlers)
	local saved = {}
	for id,fn in pairs(handlers) do
		local orig = script.get_event_handler(id)
		local filters = script.get_event_filter(id)
		saved[id] = { handler=orig, filters=filters }
		script.on_event(id, function(event)
			fn(event)
			if orig and filter_matches(filters, event) then orig(event) end
		end)
	end
	return saved
end
local function unhook_events(saved)
	for id,s in pairs(saved) do
		script.on_event(id, s.handler, s.handler and s.filters or nil)
	end
end

---@param text string
---@param args table<string, string>
local function parse_key_values(text, args)
	for k,v in string.gmatch(text, "([%w_]+)=(%S+)") do
		args[k] = v
	end
end

---@param name string
---@return boolean
local function is_ammo(name)
	local item = prototypes.item[name]
	return item ~= nil and item.type == "ammo"
end

---@param counts table<string, integer>
---@param inv LuaInventory
local function add_contents(counts, inv)
	for _,it in pairs(inv.get_contents()) do
		local key = it.name..":"..it.quality
		counts[key] = (counts[key] or 0) + it.count
	end
end

---@param counts table<string, integer>
---@return integer
local function total(counts)
	local n = 0
	for _,c in pairs(counts) do n = n + c end
	return n
end

---@param chest LuaEntity
---@return CompiledLogisticFilter[] -- ammo requests of a requester chest, empty for other chests
local function ammo_requests(chest)
	local point = chest.type == "logistic-container" and chest.get_logistic_point(defines.logistic_member_index.logistic_container)
	local requests = {}
	if point and point.mode == defines.logistic_mode.requester then
		for _,f in pairs(point.filters or {}) do
			if f.name and is_ammo(f.name) and f.count > 0 then table.insert(requests, f) end
		end
	end
	return requests
end

-- test depth is the progression (after the progression curve, what scales the quality tiers), the ore depth is its inverse
-- restore ore depth by restoring scrap: tiles above their floor scale linearly with the restore fraction, so ore depth is about linear in it
-- one guess from the floor ratio, then one correction through (restore=1, ore depth=0) and the measured point
---@param surface LuaSurface
---@param vault Vault
---@param depth number -- progression 0-1
---@param guess number? -- restore fraction from a previous run at this depth
---@return number restore, number actual_depth progression, number ore_depth
local function set_depth(surface, vault, depth, guess)
	local target = depth_scaling.depth_for_progression(depth)
	local floor = common.INF_SCRAP_MIN_RATIO
	local restore = guess or (floor + (1 - floor) * (1 - target))
	ore.change_ore(surface, vault, restore, false)
	local _, actual = vault:find_current_mining_rate_and_depth()
	if math.abs(depth_scaling.progression_curve(actual) - depth) > 0.01 and actual > 0 and target > 0 then
		restore = 1 - (1 - restore) * target / actual
		ore.change_ore(surface, vault, restore, false)
		_, actual = vault:find_current_mining_rate_and_depth()
	end
	return restore, depth_scaling.progression_curve(actual), actual
end

-- setup name: the words of a test tag that aren't key=value, e.g. "test Laser-19r tech=4 depth=10" -> "Laser-19r"
---@param text string
---@return string?
local function tag_setup_name(text)
	local words = {}
	for word in string.gmatch(text:gsub("^%s*test", "", 1), "%S+") do
		if not word:find("=") then table.insert(words, word) end
	end
	return #words > 0 and table.concat(words, " ") or nil
end

local WAVE_TAG_KEYS = { threat=true, depth=true, quality=true, tech=true }

---@class WaveTestSite
---@field vault Vault
---@field entity LuaEntity -- vault ruin
---@field name string?
---@field pos MapPosition
---@field base_step integer -- ladder step of the base threat (at research level 2)
---@field fixed_depth number? -- from the tag, else from the research level
---@field current_depth number -- the vault's depth at test start, used when research stays unchanged
---@field fixed_tier number?
---@field tag_tech number?
---@field output_chests LuaEntity[]
---@field ammo_chests LuaEntity[]
---@field accumulators LuaEntity[]
---@field steam_tanks LuaEntity[] -- storage tanks with steam (or empty) at test start, refilled with 500 degree steam
---@field belts LuaEntity[]
---@field inserters LuaEntity[]
---@field restore_for_depth table<number, number> -- depth -> restore fraction found by set_depth
---@field r table? -- state of the current run

-- per site setup: config from its test tag (tag tech ignored with several sites), chests and entities in its radius
---@param player LuaPlayer
---@param entity LuaEntity
---@param cmd table<string, string>
---@return WaveTestSite
local function wave_site(player, entity, cmd)
	local vault = get_or_init_vault(entity)
	local surface = entity.surface
	local pos = entity.position
	local R = const.VAULT_DEFENSE_RADIUS
	local area = {{pos.x - R, pos.y - R}, {pos.x + R, pos.y + R}}

	local args = {} ---@type table<string, string>
	local name
	for _,tag in pairs(player.force.find_chart_tags(surface, area)) do
		if tag.text:match("^%s*test") then
			local tag_args = {} ---@type table<string, string>
			parse_key_values(tag.text, tag_args)
			for k,v in pairs(tag_args) do
				-- typos like "Namesize=100" (missing space) would otherwise silently fall back to the vault's own values
				if not WAVE_TAG_KEYS[k] then
					print_and_log(string.format("Wave test: unknown key \"%s\" in test tag \"%s\" at [gps=%d,%d,%s], known: threat, depth, quality, tech",
						k, tag.text, tag.position.x, tag.position.y, surface.name), player)
				elseif tonumber(v) == nil then
					print_and_log(string.format("Wave test: \"%s=%s\" is not a number in test tag \"%s\" at [gps=%d,%d,%s]",
						k, v, tag.text, tag.position.x, tag.position.y, surface.name), player)
				else
					args[k] = v
				end
			end
			name = name or tag_setup_name(tag.text)
		end
	end
	for k,v in pairs(cmd) do args[k] = v end

	local threat = args.threat and tonumber(args.threat)
	local _, ore_depth = vault:find_current_mining_rate_and_depth()
	if not threat then
		local _, size = spawning.should_spawn_wave(vault, false) -- without variation (testing is set before)
		threat = select(2, spawning.estimate_bot_counts(size, ore_depth))
	end
	local site = { vault=vault, entity=entity, name=name, pos=pos,
		base_step = ladder_step(threat),
		fixed_depth = args.depth and tonumber(args.depth) / 100 or nil,
		current_depth = depth_scaling.progression_curve(ore_depth),
		fixed_tier = args.quality and math.max(tonumber(args.quality) - 1, 0) or nil,
		tag_tech = args.tech and tonumber(args.tech) or nil,
		output_chests={}, ammo_chests={}, restore_for_depth={} }

	-- chests: output = infinity chests without ammo, ammo = requester chests requesting ammo
	for _,chest in pairs(surface.find_entities_filtered{position=pos, radius=R, type={"logistic-container", "infinity-container"}}) do
		if chest.type == "infinity-container" then
			local has_ammo = false
			for _,it in pairs(chest.get_inventory(defines.inventory.chest).get_contents()) do
				if is_ammo(it.name) then has_ammo = true break end
			end
			if not has_ammo then table.insert(site.output_chests, chest) end
		elseif #ammo_requests(chest) > 0 then
			table.insert(site.ammo_chests, chest)
		end
	end
	site.accumulators = surface.find_entities_filtered{position=pos, radius=R, type="accumulator"}
	site.steam_tanks = {}
	for _,tank in pairs(surface.find_entities_filtered{position=pos, radius=R, type="storage-tank"}) do
		local fluid = tank.get_fluid(1)
		if fluid == nil or fluid.name == "steam" then table.insert(site.steam_tanks, tank) end
	end
	-- items in transit between drills and output chests, so a window counts what was mined in it, not what arrived at the chests
	site.belts = surface.find_entities_filtered{position=pos, radius=R,
		type={"transport-belt", "underground-belt", "splitter", "lane-splitter", "linked-belt", "loader", "loader-1x1"}}
	site.inserters = surface.find_entities_filtered{position=pos, radius=R, type="inserter"}
	return site
end

-- fraction of drills / electric turrets at low or no power, sampled every update
local LOW_POWER = { [defines.entity_status.low_power]=true, [defines.entity_status.no_power]=true }
local function new_power() return { drills=0, drills_low=0, turrets=0, turrets_low=0 } end
---@param site WaveTestSite
local function sample_power(site, acc)
	for _,e in pairs(site.vault.targets) do
		if e.valid then
			if e.type == "mining-drill" then
				acc.drills = acc.drills + 1
				if LOW_POWER[e.status] then acc.drills_low = acc.drills_low + 1 end
			elseif e.type == "electric-turret" then
				acc.turrets = acc.turrets + 1
				if LOW_POWER[e.status] then acc.turrets_low = acc.turrets_low + 1 end
			end
		end
	end
end
---@return {drills: number?, turrets: number?}
local function power_fractions(acc)
	return { drills = acc.drills > 0 and acc.drills_low / acc.drills or nil,
	         turrets = acc.turrets > 0 and acc.turrets_low / acc.turrets or nil }
end

-- non-ammo items on the belts and in the inserter hands in the radius
---@param site WaveTestSite
---@return table<string, integer>
local function transit_counts(site)
	local counts = {}
	local function add(name, quality, count)
		if is_ammo(name) then return end
		local key = name..":"..quality
		counts[key] = (counts[key] or 0) + count
	end
	for _,belt in pairs(site.belts) do
		if belt.valid then
			for i=1,belt.get_max_transport_line_index() do
				for _,it in pairs(belt.get_transport_line(i).get_contents()) do add(it.name, it.quality, it.count) end
			end
		end
	end
	for _,ins in pairs(site.inserters) do
		local stack = ins.valid and ins.held_stack
		if stack and stack.valid_for_read then add(stack.name, stack.quality.name, stack.count) end
	end
	return counts
end
-- chest items of a window plus the change in transit over it = mined in the window
---@return table<string, integer>
local function mined_in_window(chest_items, start_transit, end_transit)
	local mined = {}
	for k,c in pairs(chest_items) do mined[k] = c end
	for k,c in pairs(end_transit) do mined[k] = (mined[k] or 0) + c end
	for k,c in pairs(start_transit) do mined[k] = (mined[k] or 0) - c end
	return mined
end

---@param site WaveTestSite
---@param counts table<string, integer>?
local function read_outputs(site, counts)
	for _,chest in pairs(site.output_chests) do
		if chest.valid then
			local inv = chest.get_inventory(defines.inventory.chest) ---@cast inv -nil
			if counts then add_contents(counts, inv) end
			inv.clear()
		end
	end
end
---@param site WaveTestSite
local function ammo_counts(site)
	local counts = {}
	for _,chest in pairs(site.ammo_chests) do
		if chest.valid then add_contents(counts, chest.get_inventory(defines.inventory.chest)) end
	end
	return counts
end
-- top up to the request counts, as if the delivery arrived instantly after the wave
---@param site WaveTestSite
local function refill_ammo(site)
	for _,chest in pairs(site.ammo_chests) do
		if chest.valid then
			local inv = chest.get_inventory(defines.inventory.chest) ---@cast inv -nil
			for _,f in pairs(ammo_requests(chest)) do
				local item = { name=f.name, quality=f.quality or "normal" }
				local missing = f.count - inv.get_item_count(item)
				if missing > 0 then inv.insert{ name=item.name, quality=item.quality, count=missing } end
			end
		end
	end
end
---@param site WaveTestSite
local function refill_power(site)
	for _,acc in pairs(site.accumulators) do
		if acc.valid then acc.energy = acc.electric_buffer_size end
	end
	for _,tank in pairs(site.steam_tanks) do
		if tank.valid then tank.set_fluid(1, { name="steam", amount=tank.get_fluid_capacity(1), temperature=500 }) end
	end
end
---@param site WaveTestSite
local function steam_amount(site)
	local n = 0
	for _,tank in pairs(site.steam_tanks) do
		local fluid = tank.valid and tank.get_fluid(1)
		if fluid and fluid.name == "steam" then n = n + fluid.amount end
	end
	return n
end
---@param site WaveTestSite
local function accumulator_energy(site)
	local e = 0
	for _,acc in pairs(site.accumulators) do
		if acc.valid then e = e + acc.energy end
	end
	return e
end

---@param text string
---@return number[]
local function number_list(text)
	local list = {}
	for v in string.gmatch(text, "[^,]+") do table.insert(list, tonumber(v)) end
	return list
end

-- one wave test over the given vaults in parallel: every run applies the same tech, time of day, size multiplier and depth offset to all sites
-- (tech and time are shared by the force and surface), each site with its own base size and depth
---@param player LuaPlayer
---@param entities LuaEntity[] -- vault ruins
---@param cmd table<string, string> -- command key=value options
---@return TestUpdate
local function wave_test(player, entities, cmd)
	init()
	local surface = entities[1].surface
	local force = player.force --[[@as LuaForce]]
	local R = const.VAULT_DEFENSE_RADIUS

	-- no automatic waves of any vault (neighbors' drones would mix into the measurement), no variation in the test's waves
	-- the flag is in storage: a save during the test keeps it until the next full reset (mod update) or another finished test
	for _,v in pairs(storage.vaults) do v.testing = true end

	local sites = {} ---@type WaveTestSite[]
	for _,e in ipairs(entities) do table.insert(sites, wave_site(player, e, cmd)) end

	-- config grid, see the options at the top of this region
	local num = function(k, default) return cmd[k] and tonumber(cmd[k]) or default end
	local techs
	if cmd.techs then techs = number_list(cmd.techs)
	elseif cmd.tech then techs = { tonumber(cmd.tech) }
	elseif #sites == 1 and sites[1].tag_tech then techs = { sites[1].tag_tech }
	elseif #sites > 1 then techs = WAVE_DEFAULT_TECHS
	else techs = { false } end -- false: research unchanged
	local steps = cmd.steps and number_list(cmd.steps) or WAVE_DEFAULT_STEPS
	local passes = {}
	if num("day", 1) == 1 then table.insert(passes, "day") end
	if num("night", 1) == 1 then table.insert(passes, "night") end
	if num("noon", 0) == 1 then table.insert(passes, "noon") end
	local repeats = num("repeats", 1)
	local hold_kept = num("hold_kept", WAVE_HOLD_KEPT) / 100
	local hold_turrets = num("hold_turrets", WAVE_HOLD_TURRETS) / 100
	table.sort(steps)

	-- tech outermost, so research changes as rarely as possible
	local runs = {}
	for r=1,repeats do
		for _,tech in ipairs(techs) do
			for _,pass in ipairs(passes) do
				for _,step in ipairs(steps) do
					table.insert(runs, { repeat_i=r, tech=tech, pass=pass, step=math.floor(step) })
				end
			end
		end
	end

	local wreck_names = {}
	for short in pairs(const.BOT_NAMES) do
		if prototypes.entity["dead-"..short] then table.insert(wreck_names, "dead-"..short) end
	end
	local saved_research = save_research(force)
	local current_tech = nil
	local orig_daytime, orig_freeze = surface.daytime, surface.freeze_daytime
	local filename = string.format("vaults-test/wave-%d.jsonl", game.tick)

	local names = {}
	for _,s in ipairs(sites) do
		table.insert(names, string.format("%s (%d out, %d ammo chests, %d steam tanks)", s.name or string.format("[gps=%d,%d]", s.pos.x, s.pos.y), #s.output_chests, #s.ammo_chests, #s.steam_tanks))
		if #s.output_chests == 0 then print_and_log("  "..(s.name or "site").." has no output infinity chests, its mining output will read 0", player) end
	end
	local tech_names = {}
	for _,t in ipairs(techs) do table.insert(tech_names, t and tostring(t) or "unchanged") end
	print_and_log(string.format("Wave test: %d sites, %d runs (techs %s, steps +%s, %s) -> script-output/%s\n  %s",
		#sites, #runs, table.concat(tech_names, ","), table.concat(steps, ","), table.concat(passes, "/"),
		filename, table.concat(names, ", ")), player)

	-- entity -> site, for the event hooks (targets at wave start, drones by their owner vault)
	local recording = false
	local entity_site = {} ---@type table<integer, WaveTestSite>
	local function stat(e)
		if not (e and e.valid and e.unit_number) then return nil end
		local site = entity_site[e.unit_number]
		if site == nil and const.IS_DRONE[e.name] then
			local owner = e.combat_robot_owner
			for _,s in ipairs(sites) do
				if s.r and owner == s.entity then site = s break end
			end
			if site then entity_site[e.unit_number] = site end
		end
		if site == nil or site.r == nil then return nil end
		local stats = site.r.stats
		local st = stats[e.unit_number]
		if st == nil then
			st = { entity=e, name=e.name, quality=e.quality.name, type=e.type, x=e.position.x, y=e.position.y,
				damage_taken=0, damage_dealt=0, kills=0, min_health=e.health, disabled_ticks=0, times_disabled=0,
				spawn_tick=const.IS_DRONE[e.name] and game.tick or nil }
			stats[e.unit_number] = st
			if e.type == "ammo-turret" or e.type == "electric-turret" or e.type == "fluid-turret" then
				-- target filters: the vs_drone key is the turret name plus its filter, e.g. "rocket-turret [fulgoran-distractor,fulgoran-destroyer only]"
				local names = {}
				for _,proto in ipairs(e.priority_targets) do table.insert(names, proto.name) end
				st.priority_targets = names
				st.ignore_unprioritised = e.ignore_unprioritised_targets
				st.key = #names > 0 and string.format("%s [%s%s]", e.name, table.concat(names, ","), st.ignore_unprioritised and " only" or "") or e.name
			end
		end
		return st
	end

	-- damage, hits and kills on drones per cause (turret name and target filter) and drone type, misses have no event
	---@param event EventData.on_entity_damaged|EventData.on_entity_died
	---@param st table -- stat of the damaged drone
	local function vs_drone(event, st)
		local site = entity_site[event.entity.unit_number]
		if not (site and site.r) then return nil end
		local cause = event.cause
		local cs = stat(cause)
		local cause_name = cs and cs.key or cause and cause.valid and cause.name or "none"
		local by_cause = site.r.vs_drone[cause_name] or {}
		site.r.vs_drone[cause_name] = by_cause
		local v = by_cause[st.name] or { damage=0, hits=0, kills=0 }
		by_cause[st.name] = v
		return v
	end

	-- Tesla chains hit over several ticks (jump_delay_ticks 6, max_jumps 10, so up to ~60 ticks plus forks), the turret
	-- fires every 120 ticks (no tesla speed research, quality doesn't change the cooldown, low power only makes it slower):
	-- a hit by the same turret TESLA_SHOT_TICKS or more after the first hit of its current shot starts a new shot.
	-- Checks: chain_ticks_max (longest shot, must stay well below TESLA_SHOT_TICKS), shots_with_start (shots with a start
	-- beam hit, the first target of a shot), by_source (start beam vs bounce beams).
	-- shots_by_gap counts the other way (a hit more than TESLA_SHOT_GAP ticks after the turret's previous hit), both should match
	local TESLA_SHOT_TICKS = 110 -- forked chains measured up to 98 ticks
	local TESLA_SHOT_GAP = 30
	local tesla_shots = {} ---@type table<integer, {site: WaveTestSite, rec: table, start: integer, tick: integer, hits: integer, targets: table<integer, true>, ntargets: integer, has_start: boolean}>
	local function end_tesla_shot(ts)
		local rec = ts.rec
		local k = tostring(ts.hits) -- string keys, sparse integer keys don't survive table_to_json
		rec.hits_per_shot[k] = (rec.hits_per_shot[k] or 0) + 1
		rec.targets = rec.targets + ts.ntargets
		rec.chain_ticks_max = math.max(rec.chain_ticks_max, ts.tick - ts.start)
		if ts.has_start then rec.shots_with_start = rec.shots_with_start + 1 end
	end
	---@param event EventData.on_entity_damaged
	---@param site WaveTestSite -- site of the damaged drone
	---@param cs table -- stat of the turret
	---@param st table -- stat of the damaged drone
	local function tesla_hit(event, site, cs, st)
		local rec = site.r.tesla[cs.key]
		if rec == nil then
			rec = { shots=0, shots_by_gap=0, shots_with_start=0, hits=0, targets=0, damage=0, raw_damage=0, chain_ticks_max=0, hits_per_shot={}, by_source={}, by_drone={} }
			site.r.tesla[cs.key] = rec
		end
		local id = event.cause.unit_number ---@cast id -nil
		local ts = tesla_shots[id]
		if ts == nil or event.tick - ts.tick > TESLA_SHOT_GAP then rec.shots_by_gap = rec.shots_by_gap + 1 end
		if ts == nil or event.tick - ts.start >= TESLA_SHOT_TICKS then
			if ts then end_tesla_shot(ts) end
			ts = { site=site, rec=rec, start=event.tick, tick=event.tick, hits=0, targets={}, ntargets=0, has_start=false }
			tesla_shots[id] = ts
			rec.shots = rec.shots + 1
		end
		ts.tick = event.tick
		ts.hits = ts.hits + 1
		local target = event.entity.unit_number ---@cast target -nil
		if not ts.targets[target] then
			ts.targets[target] = true
			ts.ntargets = ts.ntargets + 1
		end
		rec.hits = rec.hits + 1
		rec.damage = rec.damage + event.final_damage_amount
		rec.raw_damage = rec.raw_damage + event.original_damage_amount
		local src = event.source and event.source.valid and event.source.name or "none"
		rec.by_source[src] = (rec.by_source[src] or 0) + 1
		if src:find("beam%-start$") then ts.has_start = true end
		local d = rec.by_drone[st.name] or { hits=0, damage=0 }
		rec.by_drone[st.name] = d
		d.hits = d.hits + 1
		d.damage = d.damage + event.final_damage_amount
	end
	---@param site WaveTestSite
	local function end_tesla_shots(site)
		for id,ts in pairs(tesla_shots) do
			if ts.site == site then
				end_tesla_shot(ts)
				tesla_shots[id] = nil
			end
		end
	end

	local saved_handlers = hook_events{
		[defines.events.on_entity_damaged] = function(event)
			if not recording then return end
			local st = stat(event.entity)
			if st then
				st.damage_taken = st.damage_taken + event.final_damage_amount
				st.min_health = math.min(st.min_health, event.final_health)
				if st.spawn_tick then
					local v = vs_drone(event, st)
					if v then
						v.damage = v.damage + event.final_damage_amount
						v.hits = v.hits + 1
					end
					local cs = stat(event.cause)
					local site = entity_site[event.entity.unit_number]
					if cs and cs.type == "electric-turret" and event.damage_type.name == "electric" and site and site.r then
						tesla_hit(event, site, cs, st)
					end
				end
			end
			local cs = stat(event.cause)
			if cs then cs.damage_dealt = cs.damage_dealt + event.final_damage_amount end
		end,
		[defines.events.on_entity_died] = function(event)
			if not recording then return end
			local st = stat(event.entity)
			if st then
				st.killed = true
				st.end_tick = event.tick
				st.killer = event.cause and event.cause.valid and event.cause.name or nil
				if st.spawn_tick then
					local v = vs_drone(event, st)
					if v then v.kills = v.kills + 1 end
				end
			end
			local cs = stat(event.cause)
			if cs then cs.kills = cs.kills + 1 end
		end,
	}

	local idx, phase, phase_end, wave_start = 1, "reset", 0, 0
	local run

	local function reset()
		if run.tech ~= current_tech then
			if run.tech then set_research_level(force, run.tech) else restore_research(force, saved_research) end
			current_tech = run.tech
		end
		if run.pass == "day" then
			-- running, so the wait and baseline end at dawn (end of night), start_waves sets dawn exactly
			surface.freeze_daytime = false
			surface.daytime = (surface.dawn - (WAVE_RESET_WAIT + WAVE_BASELINE) / surface.ticks_per_day) % 1
		elseif run.pass == "noon" then
			surface.daytime = 0 -- noon
			surface.freeze_daytime = true
		else
			surface.daytime = 0.5 -- midnight
			surface.freeze_daytime = true
		end
		local active = 0
		for _,site in ipairs(sites) do
			site.r = nil
			if site.entity.valid then
				local depth = site.fixed_depth or run.tech and common.eval_curve(WAVE_TECH_DEPTH, run.tech) / 100 or site.current_depth
				depth = math.min(math.max(depth, 0), 1)
				local tech_steps = run.tech and math.floor(common.eval_curve(WAVE_TECH_STEPS, run.tech) + 0.5) or 0
				local threat_step = site.base_step + tech_steps + run.step
				local threat = ladder_threat(threat_step)
				local vault = site.vault
				vault:update_targets()
				vault:end_wave(true, true) -- kill drones, repair and restore buildings
				refill_ammo(site)
				refill_power(site) -- accumulators full, steam tanks full of 500 degree steam
				-- wrecks left from the previous run would be mined during the next baseline
				if #wreck_names > 0 then
					for _,w in pairs(surface.find_entities_filtered{position=site.pos, radius=R, type="resource", name=wreck_names}) do
						w.destroy()
					end
				end
				local restore, actual, ore_depth = set_depth(surface, vault, depth, site.restore_for_depth[depth])
				site.restore_for_depth[depth] = restore
				-- size from the actual ore depth, wave counts use it (start_wave gets depth nil = the vault's real depth)
				local threat_per_size = select(2, spawning.estimate_bot_counts(1, ore_depth))
				local size = threat_per_size > 0 and threat / threat_per_size or 0
				site.r = { depth=depth, threat=threat, threat_step=threat_step, size=size, ore_restore=restore, actual_depth=actual, ore_depth=ore_depth, stats={} }
				active = active + 1
			end
		end
		return active
	end

	local function start_waves()
		if run.pass == "day" then surface.daytime = surface.dawn end -- waves start when the night ends
		entity_site = {}
		for _,site in ipairs(sites) do
			local r = site.r
			if r then
				site.vault:update_targets()
				for id,e in pairs(site.vault.targets) do
					entity_site[id] = site
					stat(e)
				end
				r.ammo_start, r.energy_start, r.steam_start = ammo_counts(site), accumulator_energy(site), steam_amount(site)
				r.wave_items = {}
				r.wave_transit_start = transit_counts(site)
				r.baseline_transit_end = r.wave_transit_start
				r.wave_power = new_power()
				r.peak_alive, r.peak_disabled = 0, 0
				r.vs_drone = {}
				r.tesla = {}
				-- the vault's own mining rate (drain, corrected for yield, as the waves use it; window since the ore restore in reset: wait + baseline)
				-- and the wave it would spawn by itself at that rate (no variation while testing), for comparing with what the site holds
				r.mining_rate = site.vault:find_current_mining_rate_and_depth()
				local _, natural_size, natural_freq = spawning.should_spawn_wave(site.vault, false)
				if natural_size then
					r.natural_wave = { size=natural_size, freq=natural_freq, period_s=natural_freq and 60 / natural_freq or nil,
						threat=select(2, spawning.estimate_bot_counts(natural_size, r.ore_depth)) }
				end
			end
		end
		tesla_shots = {}
		wave_start = game.tick
		recording = true
		for _,site in ipairs(sites) do
			if site.r then
				site.r.wave = site.vault:start_wave(site.r.size, nil, site.fixed_tier, nil) -- depth and default tier from the vault's real (restored) depth
			end
		end
	end

	---@param site WaveTestSite
	local function poll_wave(site)
		local r = site.r ---@cast r -nil
		local alive = 0
		for _,bot in pairs(site.vault.active_bots) do
			if bot.valid then
				stat(bot)
				alive = alive + 1
			end
		end
		r.peak_alive = math.max(r.peak_alive, alive)
		local disabled = 0
		for _,st in pairs(r.stats) do
			if st.spawn_tick then
				if not st.entity.valid and not st.end_tick then
					st.end_tick = game.tick -- gone without dying: expired or returned into the vault
				end
			elseif st.entity.valid and st.entity.disabled_by_script then
				if not st.was_disabled then st.times_disabled = st.times_disabled + 1 end
				st.was_disabled = true
				st.disabled_ticks = st.disabled_ticks + UPDATE_PERIOD
				disabled = disabled + 1
			else
				st.was_disabled = false
			end
		end
		r.peak_disabled = math.max(r.peak_disabled, disabled)
	end

	---@param site WaveTestSite
	local function finish_site(site)
		local r = site.r ---@cast r -nil
		local wave_ticks = game.tick - wave_start
		end_tesla_shots(site)
		local ammo_end = ammo_counts(site)
		local ammo_used = {}
		for k,c in pairs(r.ammo_start) do
			local used = c - (ammo_end[k] or 0)
			if used ~= 0 then ammo_used[k] = used end
		end

		-- summaries, entity references stripped
		local bots, buildings, by_type = {}, {}, {}
		local turret_count, turret_disabled_ticks = 0, 0
		for _,st in pairs(r.stats) do
			st.entity, st.was_disabled = nil, nil
			if st.spawn_tick then
				table.insert(bots, st)
				local t = by_type[st.name] or { spawned=0, killed=0, left=0, damage_taken=0, damage_dealt=0, lifetime_ticks=0 }
				by_type[st.name] = t
				t.spawned = t.spawned + 1
				if st.killed then t.killed = t.killed + 1 elseif st.end_tick then t.left = t.left + 1 end
				t.damage_taken = t.damage_taken + st.damage_taken
				t.damage_dealt = t.damage_dealt + st.damage_dealt
				t.lifetime_ticks = t.lifetime_ticks + ((st.end_tick or game.tick) - st.spawn_tick)
			else
				table.insert(buildings, st)
				if st.type == "ammo-turret" or st.type == "electric-turret" or st.type == "fluid-turret" then
					turret_count = turret_count + 1
					turret_disabled_ticks = turret_disabled_ticks + st.disabled_ticks
				end
			end
		end

		local baseline_mined = mined_in_window(r.baseline_items, r.baseline_transit_start, r.baseline_transit_end)
		local wave_mined = mined_in_window(r.wave_items, r.wave_transit_start, transit_counts(site))
		local base_rate = total(baseline_mined) / WAVE_BASELINE
		local wave_rate = total(wave_mined) / math.max(wave_ticks, 1)
		local mining_kept = base_rate > 0 and wave_rate / base_rate or nil
		local turret_downtime = turret_count > 0 and turret_disabled_ticks / (turret_count * math.max(wave_ticks, 1)) or 0
		local killed, spawned = 0, 0
		for _,t in pairs(by_type) do
			killed = killed + t.killed
			spawned = spawned + t.spawned
		end
		local timed_out = wave_ticks >= WAVE_TIMEOUT
		local held = not timed_out and killed == spawned and turret_downtime <= hold_turrets and (mining_kept or 1) >= hold_kept

		local out = {
			test = "wave", file = filename, setup = site.name, vault = { x=site.pos.x, y=site.pos.y },
			run = idx, runs = #runs, repeat_i = run.repeat_i, pass = run.pass, tech = run.tech or nil,
			step = run.step, base_threat = ladder_threat(site.base_step), -- base threat at research level 2, in %
			threat = r.threat, threat_step = r.threat_step, -- target threat in % (wave.threat is the rolled one) and its ladder step
			fixed_depth = site.fixed_depth,
			mining_rate = r.mining_rate, -- per minute, the vault's own measurement after the baseline (drain, yield corrected)
			natural_wave = r.natural_wave, -- {size (capped), freq per minute, period_s, threat} the vault would spawn by itself at that rate
			size = r.size, depth = r.depth, actual_depth = r.actual_depth, ore_depth = r.ore_depth, ore_restore = r.ore_restore, -- depths as progression, ore_depth before the curve
			quality_tier = r.wave.bot_quality_tier,
			wave = r.wave, -- size, freq, threat, bot_types, bot_qualities, ticks
			held = held, timed_out = timed_out,
			wave_ticks = wave_ticks, baseline_ticks = WAVE_BASELINE,
			baseline_items = r.baseline_items, wave_items = r.wave_items, -- arrived in the output chests
			baseline_mined = baseline_mined, wave_mined = wave_mined, -- plus the change on belts and in inserters, mining_kept uses these
			mining_kept = mining_kept, turret_downtime = turret_downtime,
			peak_bots_alive = r.peak_alive, peak_buildings_disabled = r.peak_disabled, turrets = turret_count,
			ammo_used = ammo_used,
			accumulator_energy = { start=r.energy_start, ["end"]=accumulator_energy(site) },
			steam = { start=r.steam_start, ["end"]=steam_amount(site) }, -- units in the steam tanks
			low_power = { baseline=power_fractions(r.baseline_power), wave=power_fractions(r.wave_power) }, -- fraction of samples at low/no power
			bots_by_type = by_type, bots = bots, buildings = buildings,
			vs_drone = r.vs_drone, -- cause (turret name plus target filter) -> drone name -> {damage, hits, kills}, "none" without a cause
			-- electric turret key (as in vs_drone) -> {shots, shots_by_gap, shots_with_start, chain_ticks_max, hits, targets (distinct drones per shot, summed), damage, raw_damage (before resistances),
			-- hits_per_shot (hit count as string -> shots), by_source (beam name -> hits), by_drone (name -> {hits, damage})}
			tesla = r.tesla,
		}
		helpers.write_file(filename, helpers.table_to_json(out).."\n", true)

		print_and_log(string.format("  run %d/%d %s %s tech %s: size %.0f%% depth %.0f%% | %s, threat %.0f%%, %d/%d killed, turrets down %.0f%%, mining kept %s, low power drills %s%s",
			idx, #runs, site.name or "site", run.pass, tostring(run.tech or "-"), r.size * 100, r.actual_depth * 100,
			held and "HELD" or "FAILED", r.wave.threat or 0, killed, spawned, turret_downtime * 100,
			mining_kept and string.format("%.0f%%", mining_kept * 100) or "--",
			out.low_power.wave.drills and string.format("%.0f%%", out.low_power.wave.drills * 100) or "--",
			timed_out and " (timed out)" or ""), player)
		site.r.done = true
	end

	local function cleanup()
		recording = false
		unhook_events(saved_handlers)
		for _,v in pairs(storage.vaults) do
			v.testing = nil
			v.wave_timer_start = game.tick -- next automatic wave a full period after the test
		end
		for _,site in ipairs(sites) do
			if site.entity.valid then
				site.vault:update_targets()
				site.vault:end_wave(true, true)
				refill_ammo(site)
			end
		end
		restore_research(force, saved_research)
		surface.daytime, surface.freeze_daytime = orig_daytime, orig_freeze
		print_and_log("Wave test done -> script-output/"..filename, player)
	end

	return function()
		local tick = game.tick
		run = runs[idx]

		if phase == "reset" then
			if reset() == 0 then -- all vaults gone
				idx = idx + 1
				if idx > #runs then
					cleanup()
					return true
				end
				return false
			end
			phase, phase_end = "wait", tick + WAVE_RESET_WAIT
		elseif phase == "wait" then
			if tick >= phase_end then
				for _,site in ipairs(sites) do
					local r = site.r
					if r then
						refill_ammo(site) -- again after the inserters filled the turrets, so the chests hold their full buffer too
						read_outputs(site, nil) -- drop what was mined during the wait
						r.baseline_items = {}
						r.baseline_transit_start = transit_counts(site)
						r.baseline_power = new_power()
					end
				end
				phase, phase_end = "baseline", tick + WAVE_BASELINE
			end
		elseif phase == "baseline" then
			for _,site in ipairs(sites) do
				if site.r then
					read_outputs(site, site.r.baseline_items)
					sample_power(site, site.r.baseline_power)
				end
			end
			if tick >= phase_end then
				start_waves()
				phase = "wave"
			end
		elseif phase == "wave" then
			local running = false
			for _,site in ipairs(sites) do
				local r = site.r
				if r and not r.done then
					read_outputs(site, r.wave_items)
					sample_power(site, r.wave_power)
					poll_wave(site)
					if not site.entity.valid or not site.vault:bots_active() or tick - wave_start >= WAVE_TIMEOUT then
						if site.entity.valid then finish_site(site) else r.done = true end
					else
						running = true
					end
				end
			end
			if not running then
				recording = false
				idx = idx + 1
				if idx > #runs then
					cleanup()
					return true
				end
				phase = "reset"
			end
		end
	end
end

-- /vaults-test wave (key=value...): the hovered vault
-- /vaults-test wave all (key=value...): every vault with a "test" map tag on fulgora, all in parallel, all runs into one file
function test_funcs.wave(player, first, ...)
	local cmd = {} ---@type table<string, string>
	parse_key_values(table.concat({ first ~= "all" and first or "", ... }, " "), cmd)
	if first ~= "all" then
		local sel = player.selected
		if not (sel and sel.valid and sel.name == const.VAULT_NAME) then
			dbg_print("Hover a vault ruin to run the wave test (or /vaults-test wave all)", true, nil, player)
			return
		end
		return wave_test(player, { sel }, cmd)
	end

	local surface = game.get_surface("fulgora")
	if surface == nil then
		dbg_print("Fulgora does not exist yet", true, nil, player)
		return
	end
	-- vaults with a test tag in their radius, nearest vault per tag, each vault once
	local R = const.VAULT_DEFENSE_RADIUS
	local vaults, seen = {}, {} ---@type LuaEntity[], table<integer, true>
	for _,tag in pairs(player.force.find_chart_tags(surface)) do
		if tag.text:match("^%s*test") then
			local nearest = surface.find_entities_filtered{name=const.VAULT_NAME, position=tag.position, radius=R}
			table.sort(nearest, function(a, b)
				return myutil.get_distance(a.position, tag.position) < myutil.get_distance(b.position, tag.position)
			end)
			local v = nearest[1]
			local id = v and script.register_on_object_destroyed(v)
			if v and not seen[id] then
				seen[id] = true
				table.insert(vaults, v)
			end
		end
	end
	if #vaults == 0 then
		dbg_print("No vault ruin with a \"test ...\" map tag in its radius on fulgora", true, nil, player)
		return
	end
	return wave_test(player, vaults, cmd)
end

--#endregion

---- command

-- debug only: control.lua requires this whole file only with const.DEBUG, prefixed since a plain /test would collide with other mods' commands
commands.add_command("vaults-test", "<test name> [params...]\nrun an in-game test setup, params are split by spaces (numbers converted)", function(command)
	local player = game.get_player(command.player_index) ---@cast player -nil
	local args = {}
	for arg in string.gmatch(command.parameter or "", "%S+") do
		table.insert(args, tonumber(arg) or arg)
	end
	local name = table.remove(args, 1)
	tests.run(player, name and tostring(name) or "", args) -- "" prints the list
end)

return tests
