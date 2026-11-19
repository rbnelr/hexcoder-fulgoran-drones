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

---- test_mining_quality_roll

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
