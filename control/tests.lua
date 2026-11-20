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

-- /vaults-test wave (size=<percent>) (depth=<m>) (quality=<1-5>) (tech=<science tier 1-7>) (inf=<levels>) (repeats=<n>) (noon=1)
-- run while hovering a vault ruin, defaults come from a map tag in its radius whose text starts with "test" (same keys), the command overrides them
-- without size/depth: what the vault would spawn now, without quality: from depth, without tech: the force's research stays
-- sweep: size x1, x1.5, x2 at the depth, then depth +20 m and +40 m at size x1, each as a day pass (dawn, time running) and a night pass (frozen), repeats times
-- each run: reset, wait (turret ammo refill), baseline (output without a wave), wave until all its drones died or left, then one json line in script-output
-- depth is set for real: the scrap around the vault is restored to the amount that gives that depth (drill quality, yield and gui follow)
-- tech: the weapon research is set for real to what a player at that science tier has (WAVE_SCIENCE_TIERS), inf adds levels to the fitting infinite techs (restored at the end)
-- output chests: infinity chests in the radius without ammo, read and cleared every update (so they must not use "remove unfiltered items")
-- ammo: requester chests requesting ammo are filled to their request count on reset (no delivery during a wave), infinity chests supply infinite ammo anyway

local common = require("control.common")
local ore = require("control.ore_tracking")
local spawning = require("control.spawning")
local myutil = require("lib.myutil")

local WAVE_RESET_WAIT = 10*60
local WAVE_BASELINE = 60*60
local WAVE_TIMEOUT = 10*60*60
local WAVE_SWEEP = { -- size multiplier, added depth in m
	{1, 0}, {1.5, 0}, {2, 0},
	{1, 20}, {1, 40},
}
-- day: dawn with time running, the accumulators must last until the night storms (realistic worst case)
-- night: frozen at midnight, lightning feeds the defense (best case)
-- noon (only with noon=1): frozen at noon, what the stored charge alone can defeat
local WAVE_PASSES = { "day", "night" }
local WAVE_TECH_SERIES = {
	"physical-projectile-damage", "weapon-shooting-speed",
	"laser-weapons-damage", "laser-shooting-speed",
	"electric-weapons-damage", "stronger-explosives",
}

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

-- science tiers for tech=<tier>: tier n allows the first n packs, every weapon tech whose packs are all allowed is researched
-- vanilla: 3 (military): physical/speed 4, explosives 2 | 4 (chemical): +lasers 4 | 5 (utility): physical/speed 6, lasers 6/7, electric 1, explosives 4
--          6 (space): physical/laser 7 (infinite), electric 2, explosives 6 | 7 (electromagnetic): electric 4 (infinite)
local WAVE_SCIENCE_TIERS = {
	"automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
	"utility-science-pack", "space-science-pack", "electromagnetic-science-pack",
}

-- weapon research as a player at that science tier would have it, infinite techs that fit get inf extra levels
-- writing level n of an infinite tech researches it up to n-1, reset_technology_effects recomputes all bonuses from the research state
---@param force LuaForce
---@param tier integer
---@param inf integer
local function set_research_tier(force, tier, inf)
	local allowed = {}
	for i=1,math.min(tier, #WAVE_SCIENCE_TIERS) do allowed[WAVE_SCIENCE_TIERS[i]] = true end
	for _,tech in pairs(weapon_techs(force)) do
		local proto = tech.prototype
		local fits = true
		for _,ing in pairs(proto.research_unit_ingredients) do
			if not allowed[ing.name] then fits = false break end
		end
		if proto.max_level > proto.level then
			tech.researched = false
			tech.level = fits and proto.level + inf + 1 or proto.level
		else
			tech.researched = fits
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
---@param args table<string, number>
local function parse_key_values(text, args)
	for k,v in string.gmatch(text, "(%w+)=([%d%.]+)") do
		args[k] = tonumber(v)
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

-- restore depth by restoring scrap: tiles above their floor scale linearly with the restore fraction, so depth is about linear in it
-- one guess from the floor ratio, then one correction through (restore=1, depth=0) and the measured point
---@param surface LuaSurface
---@param vault Vault
---@param depth number -- 0-1
---@param guess number? -- restore fraction from a previous run at this depth
---@return number restore, number actual_depth
local function set_depth(surface, vault, depth, guess)
	local floor = common.INF_SCRAP_MIN_RATIO
	local restore = guess or (floor + (1 - floor) * (1 - depth))
	ore.change_ore(surface, vault, restore, false)
	local _, actual = vault:find_current_mining_rate_and_depth()
	if math.abs(actual - depth) > 0.01 and actual > 0 and depth > 0 then
		restore = 1 - (1 - restore) * depth / actual
		ore.change_ore(surface, vault, restore, false)
		_, actual = vault:find_current_mining_rate_and_depth()
	end
	return restore, actual
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

-- one wave test sweep at a vault, returns the update function (true when done)
---@param player LuaPlayer
---@param sel LuaEntity -- vault ruin
---@param args_text string -- command key=value overrides
---@param filename string? -- json lines file in script-output, nil: own file per test
---@return TestUpdate
local function wave_test(player, sel, args_text, filename)
	init()
	local vault = get_or_init_vault(sel)
	local surface = sel.surface
	local force = player.force --[[@as LuaForce]]
	local pos = sel.position
	local R = const.VAULT_DEFENSE_RADIUS
	local area = {{pos.x - R, pos.y - R}, {pos.x + R, pos.y + R}}

	-- config: map tag defaults, then command args
	local args = {} ---@type table<string, number>
	local setup_name
	for _,tag in pairs(force.find_chart_tags(surface, area)) do
		if tag.text:match("^%s*test") then
			parse_key_values(tag.text, args)
			setup_name = setup_name or tag_setup_name(tag.text)
		end
	end
	parse_key_values(args_text, args)

	-- no automatic waves of any vault (neighbors' drones would mix into the measurement), no variation in the test's waves
	-- the flag is in storage: a save during the test keeps it until the next full reset (mod update) or another finished test
	for _,v in pairs(storage.vaults) do v.testing = true end

	local _, base_size = spawning.should_spawn_wave(vault, false) -- without variation (testing)
	local _, base_depth = vault:find_current_mining_rate_and_depth()
	base_size = args.size and args.size / 100 or base_size ---@cast base_size number
	base_depth = args.depth and args.depth / 100 or base_depth
	local fixed_tier = args.quality and math.max(args.quality - 1, 0) or nil
	local repeats = args.repeats or 1

	local runs = {}
	for r=1,repeats do
		local last_depth
		for _,step in ipairs(WAVE_SWEEP) do
			local depth = math.min(base_depth + step[2] / 100, 1)
			if step[2] == 0 or depth ~= last_depth then -- depth clamped at 100 m: skip duplicates
				for _,pass in ipairs(WAVE_PASSES) do
					table.insert(runs, { repeat_i=r, size=base_size * step[1], depth=depth, pass=pass })
				end
				if args.noon == 1 then
					table.insert(runs, { repeat_i=r, size=base_size * step[1], depth=depth, pass="noon" })
				end
			end
			last_depth = depth
		end
	end

	-- chests: output = infinity chests without ammo, ammo = requester chests requesting ammo
	local output_chests = {} ---@type LuaEntity[]
	local ammo_chests = {} ---@type LuaEntity[]
	for _,chest in pairs(surface.find_entities_filtered{position=pos, radius=R, type={"logistic-container", "infinity-container"}}) do
		if chest.type == "infinity-container" then
			local has_ammo = false
			for _,it in pairs(chest.get_inventory(defines.inventory.chest).get_contents()) do
				if is_ammo(it.name) then has_ammo = true break end
			end
			if not has_ammo then table.insert(output_chests, chest) end
		elseif #ammo_requests(chest) > 0 then
			table.insert(ammo_chests, chest)
		end
	end
	local accumulators = surface.find_entities_filtered{position=pos, radius=R, type="accumulator"}
	local wreck_names = {}
	for short in pairs(const.BOT_NAMES) do
		if prototypes.entity["dead-"..short] then table.insert(wreck_names, "dead-"..short) end
	end

	local saved_research = args.tech and save_research(force)
	if args.tech then set_research_tier(force, args.tech, args.inf or 0) end
	local orig_daytime, orig_freeze = surface.daytime, surface.freeze_daytime
	local restore_for_depth = {} ---@type table<number, number> -- depth -> restore fraction found by set_depth
	filename = filename or string.format("vaults-test/wave-%d.jsonl", game.tick)

	print_and_log(string.format("Wave test %sat [gps=%d,%d,%s]: %d runs, base size %.0f%%, depth %.0f m, tech %s, %d output chests, %d ammo requester chests -> script-output/%s",
		setup_name and (setup_name.." ") or "", math.floor(pos.x), math.floor(pos.y), surface.name, #runs, base_size * 100, base_depth * 100, tostring(args.tech or "unchanged"),
		#output_chests, #ammo_chests, filename), player)
	if #output_chests == 0 then
		print_and_log("  no output infinity chests found, mining output will read 0", player)
	end

	-- fraction of drills / electric turrets at low or no power, sampled every update
	local LOW_POWER = { [defines.entity_status.low_power]=true, [defines.entity_status.no_power]=true }
	---@param acc {drills: integer, drills_low: integer, turrets: integer, turrets_low: integer}
	local function sample_power(acc)
		for _,e in pairs(vault.targets) do
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
	local function new_power() return { drills=0, drills_low=0, turrets=0, turrets_low=0 } end
	---@return {drills: number?, turrets: number?}
	local function power_fractions(acc)
		return { drills = acc.drills > 0 and acc.drills_low / acc.drills or nil,
		         turrets = acc.turrets > 0 and acc.turrets_low / acc.turrets or nil }
	end

	---@param counts table<string, integer>?
	local function read_outputs(counts)
		for _,chest in pairs(output_chests) do
			if chest.valid then
				local inv = chest.get_inventory(defines.inventory.chest) ---@cast inv -nil
				if counts then add_contents(counts, inv) end
				inv.clear()
			end
		end
	end
	local function ammo_counts()
		local counts = {}
		for _,chest in pairs(ammo_chests) do
			if chest.valid then add_contents(counts, chest.get_inventory(defines.inventory.chest)) end
		end
		return counts
	end
	-- top up to the request counts, as if the delivery arrived instantly after the wave
	local function refill_ammo()
		for _,chest in pairs(ammo_chests) do
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
	local function accumulator_energy()
		local e = 0
		for _,acc in pairs(accumulators) do
			if acc.valid then e = e + acc.energy end
		end
		return e
	end

	-- per run state
	local idx, phase, phase_end = 1, "reset", 0
	local run, stats, targets_set, recording
	local peak_alive, peak_disabled, ammo_start, energy_start, wave_start = 0, 0, {}, 0, 0
	stats, targets_set = {}, {}

	-- entity stats, only for drones and the vault's targets
	local function stat(e)
		if not (e and e.valid and e.unit_number) then return nil end
		local s = stats[e.unit_number]
		if s == nil and (const.IS_DRONE[e.name] or targets_set[e.unit_number]) then
			s = { entity=e, name=e.name, quality=e.quality.name, type=e.type, x=e.position.x, y=e.position.y,
				damage_taken=0, damage_dealt=0, kills=0, min_health=e.health, disabled_ticks=0, times_disabled=0,
				spawn_tick=const.IS_DRONE[e.name] and game.tick or nil }
			stats[e.unit_number] = s
		end
		return s
	end

	local saved_handlers = hook_events{
		[defines.events.on_entity_damaged] = function(event)
			if not recording then return end
			local s = stat(event.entity)
			if s then
				s.damage_taken = s.damage_taken + event.final_damage_amount
				s.min_health = math.min(s.min_health, event.final_health)
			end
			local cs = stat(event.cause)
			if cs then cs.damage_dealt = cs.damage_dealt + event.final_damage_amount end
		end,
		[defines.events.on_entity_died] = function(event)
			if not recording then return end
			local s = stat(event.entity)
			if s then
				s.killed = true
				s.end_tick = event.tick
				s.killer = event.cause and event.cause.valid and event.cause.name or nil
			end
			local cs = stat(event.cause)
			if cs then cs.kills = cs.kills + 1 end
		end,
	}

	local function reset()
		vault:update_targets()
		vault:end_wave(true, true) -- kill drones, repair and restore buildings
		refill_ammo()
		for _,acc in pairs(accumulators) do
			if acc.valid then acc.energy = acc.electric_buffer_size end
		end
		-- wrecks left from the previous run would be mined during the next baseline
		if #wreck_names > 0 then
			for _,w in pairs(surface.find_entities_filtered{position=pos, radius=R, type="resource", name=wreck_names}) do
				w.destroy()
			end
		end
		local restore, actual = set_depth(surface, vault, run.depth, restore_for_depth[run.depth])
		restore_for_depth[run.depth] = restore
		run.ore_restore, run.actual_depth = restore, actual
		if run.pass == "day" then
			surface.freeze_daytime = false
			surface.daytime = surface.dawn
		elseif run.pass == "noon" then
			surface.daytime = 0 -- noon
			surface.freeze_daytime = true
		else
			surface.daytime = 0.5 -- midnight
			surface.freeze_daytime = true
		end
	end

	local function start_wave()
		stats, targets_set, peak_alive, peak_disabled = {}, {}, 0, 0
		vault:update_targets()
		for id,e in pairs(vault.targets) do
			targets_set[id] = true
			stat(e)
		end
		ammo_start, energy_start = ammo_counts(), accumulator_energy()
		run.wave_items = {}
		run.wave_power = new_power()
		wave_start = game.tick
		recording = true
		run.wave = vault:start_wave(run.size, nil, fixed_tier, nil) -- depth and default tier from the vault's real (restored) depth
	end

	local function poll_wave()
		local alive = 0
		for _,bot in pairs(vault.active_bots) do
			if bot.valid then
				stat(bot)
				alive = alive + 1
			end
		end
		peak_alive = math.max(peak_alive, alive)
		local disabled = 0
		for _,s in pairs(stats) do
			if s.spawn_tick then
				if not s.entity.valid and not s.end_tick then
					s.end_tick = game.tick -- gone without dying: expired or returned into the vault
				end
			elseif s.entity.valid and s.entity.disabled_by_script then
				if not s.was_disabled then s.times_disabled = s.times_disabled + 1 end
				s.was_disabled = true
				s.disabled_ticks = s.disabled_ticks + UPDATE_PERIOD
				disabled = disabled + 1
			else
				s.was_disabled = false
			end
		end
		peak_disabled = math.max(peak_disabled, disabled)
	end

	local function finish_run()
		recording = false
		local wave_ticks = game.tick - wave_start
		local ammo_end = ammo_counts()
		local ammo_used = {}
		for k,c in pairs(ammo_start) do
			local used = c - (ammo_end[k] or 0)
			if used ~= 0 then ammo_used[k] = used end
		end

		-- summaries, entity references stripped
		local bots, buildings, by_type = {}, {}, {}
		local turret_count = 0
		for _,s in pairs(stats) do
			s.entity, s.was_disabled = nil, nil
			if s.spawn_tick then
				table.insert(bots, s)
				local t = by_type[s.name] or { spawned=0, killed=0, left=0, damage_taken=0, damage_dealt=0, lifetime_ticks=0 }
				by_type[s.name] = t
				t.spawned = t.spawned + 1
				if s.killed then t.killed = t.killed + 1 elseif s.end_tick then t.left = t.left + 1 end
				t.damage_taken = t.damage_taken + s.damage_taken
				t.damage_dealt = t.damage_dealt + s.damage_dealt
				t.lifetime_ticks = t.lifetime_ticks + ((s.end_tick or game.tick) - s.spawn_tick)
			else
				table.insert(buildings, s)
				if s.type == "ammo-turret" or s.type == "electric-turret" or s.type == "fluid-turret" then
					turret_count = turret_count + 1
				end
			end
		end

		local base_rate = total(run.baseline_items) / WAVE_BASELINE
		local wave_rate = total(run.wave_items) / math.max(wave_ticks, 1)
		local out = {
			test = "wave", file = filename, setup = setup_name, vault = { x=pos.x, y=pos.y },
			run = idx, runs = #runs, repeat_i = run.repeat_i, pass = run.pass,
			size = run.size, depth = run.depth, actual_depth = run.actual_depth, ore_restore = run.ore_restore,
			quality_tier = run.wave.bot_quality_tier, tech = args.tech, inf = args.inf,
			wave = run.wave, -- size, freq, threat, bot_types, bot_qualities, ticks
			timed_out = wave_ticks >= WAVE_TIMEOUT,
			wave_ticks = wave_ticks, baseline_ticks = WAVE_BASELINE,
			baseline_items = run.baseline_items, wave_items = run.wave_items,
			mining_kept = base_rate > 0 and wave_rate / base_rate or nil,
			peak_bots_alive = peak_alive, peak_buildings_disabled = peak_disabled, turrets = turret_count,
			ammo_used = ammo_used,
			accumulator_energy = { start=energy_start, ["end"]=accumulator_energy() },
			low_power = { baseline=power_fractions(run.baseline_power), wave=power_fractions(run.wave_power) }, -- fraction of samples at low/no power
			bots_by_type = by_type, bots = bots, buildings = buildings,
		}
		helpers.write_file(filename, helpers.table_to_json(out).."\n", true)

		local killed, spawned = 0, 0
		for _,t in pairs(by_type) do
			killed = killed + t.killed
			spawned = spawned + t.spawned
		end
		print_and_log(string.format("  run %d/%d %s: size %.0f%% depth %.0f m (target %.0f) tier %.1f | threat %.0f%%, %d/%d drones killed, peak %d alive, mining kept %s, low power drills %s, peak disabled %d%s",
			idx, #runs, run.pass, run.size * 100, run.actual_depth * 100, run.depth * 100, run.wave.bot_quality_tier + 1, run.wave.threat or 0, killed, spawned, peak_alive,
			out.mining_kept and string.format("%.0f%%", out.mining_kept * 100) or "--",
			out.low_power.wave.drills and string.format("%.0f%%", out.low_power.wave.drills * 100) or "--", peak_disabled, out.timed_out and " (timed out)" or ""), player)
	end

	local function cleanup()
		recording = false
		unhook_events(saved_handlers)
		for _,v in pairs(storage.vaults) do
			v.testing = nil
			v.wave_timer_start = game.tick -- next automatic wave a full period after the test
		end
		if vault.entity.valid then
			vault:update_targets()
			vault:end_wave(true, true)
		end
		refill_ammo()
		if saved_research then restore_research(force, saved_research) end
		surface.daytime, surface.freeze_daytime = orig_daytime, orig_freeze
		print_and_log("Wave test done -> script-output/"..filename, player)
	end

	return function()
		if not vault.entity.valid then
			print_and_log("Wave test aborted: vault gone", player)
			cleanup()
			return true
		end
		local tick = game.tick
		run = runs[idx]

		if phase == "reset" then
			reset()
			phase, phase_end = "wait", tick + WAVE_RESET_WAIT
		elseif phase == "wait" then
			if tick >= phase_end then
				read_outputs(nil) -- drop what was mined during the wait
				run.baseline_items = {}
				run.baseline_power = new_power()
				phase, phase_end = "baseline", tick + WAVE_BASELINE
			end
		elseif phase == "baseline" then
			read_outputs(run.baseline_items)
			sample_power(run.baseline_power)
			if tick >= phase_end then
				start_wave()
				phase = "wave"
			end
		elseif phase == "wave" then
			read_outputs(run.wave_items)
			sample_power(run.wave_power)
			poll_wave()
			if not vault:bots_active() or tick - wave_start >= WAVE_TIMEOUT then
				finish_run()
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
-- /vaults-test wave all (key=value...): every vault with a "test" map tag on fulgora, one after another, all runs into one file (key=value overrides all tags)
-- in sequence since a test changes force research, daytime and the testing flag of all vaults (parallel would need equal tech and passes)
function test_funcs.wave(player, first, ...)
	local rest = { ... }
	if first ~= "all" then
		local sel = player.selected
		if not (sel and sel.valid and sel.name == const.VAULT_NAME) then
			dbg_print("Hover a vault ruin to run the wave test (or /vaults-test wave all)", true, nil, player)
			return
		end
		return wave_test(player, sel, table.concat({ first or "", table.unpack(rest) }, " "))
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

	local args_text = table.concat(rest, " ")
	local filename = string.format("vaults-test/batch-%d.jsonl", game.tick)
	print_and_log(string.format("Wave test batch: %d setups -> script-output/%s", #vaults, filename), player)
	local idx, current = 0, nil
	return function()
		if current == nil then
			idx = idx + 1
			if idx > #vaults then
				print_and_log("Wave test batch done -> script-output/"..filename, player)
				return true
			end
			local v = vaults[idx]
			if v.valid then current = wave_test(player, v, args_text, filename) end
			return false
		end
		if current() then current = nil end
		return false
	end
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
