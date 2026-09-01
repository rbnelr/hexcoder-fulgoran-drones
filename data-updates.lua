local meld = require("__core__.lualib.meld")
local g = require("common")

-- for disable_on_damage to work
for _,type in pairs(g.TARGETS) do
	for _,e in pairs(data.raw[type]) do
		e.allow_run_time_change_of_is_military_target = true
	end
end

-- non-destroyable vault ruin
meld(data.raw["simple-entity"][g.VAULT_NAME], {
	selection_priority = 45, -- normal buildings are 50, ore is 40
	minable = meld.delete(),--meld.overwrite{minable=false, mining_time=999999999},
	max_health = 1000000, healing_per_tick = 1000000/60,
	loot = meld.delete(),
})
-- cannot mine vault ruin, need to adjust tech trigger
meld(data.raw["technology"]["recycling"], {
	research_trigger = meld.overwrite{
		type = "mine-entity",
		--entities = {"fulgoran-ruin-colossal", "fulgoran-ruin-huge"} -- 2.1
		entity = "fulgoran-ruin-colossal" -- needed for 2.0
	}
})

-- vault ruin graphic to hide spawning drones, and create illusion that they ascend out of hole
data:extend{
	{
		type = "simple-entity", -- use optimized-decorative instead?
		name = g.VAULT_NEAR_WALL_NAME,
		flags = {"placeable-neutral", "placeable-off-grid"},
		order = "b[decorative]-l[rock]-d[fulgora]-e[ruin]-g[vault]",
		hidden = true,
		selection_priority = 1,
		--minable = {minable=false, mining_time=999999999},
		max_health = 1000000, healing_per_tick = 1000000/60,
		pictures = {
			{width = 960, height = 640, filename = "__hexcoder-fulgoran-drones__/graphics/fulgoran-ruin-vault-near-wall.png",
			shift = util.by_pixel( 18.5/2, -6/2), scale = 0.5}
		},
		--render_layer = "higher-object-under",
		render_layer = "air-object",
		icon = data.raw["simple-entity"][g.VAULT_NAME].icon,
		collision_box = nil,
		collision_mask = { layers = {} },
		selection_box = {{0,0}, {0,0}},
		selectable_in_game = false,
	}
}

if settings.startup[g.MOD_NAME.."-buff-drones"].value then
	-- buff HP and resistances by a lot, otherwise very few turret completely defeat even huge swarms
	-- lengthen time to live
	-- adjust friction and max_speed to prevent drones moving at unlimited speeds, make movements a bit more visually followable
	-- separation_range/range_from_player adjust distance from target and each other

	meld(data.raw["combat-robot"]["defender"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80 eff HP  400
			{ type = "fire",     percent = 90 }, -- was 95 eff HP 2000
			{ type = "physical", percent = 70 }, -- was 0  eff HP  667
			{ type = "laser",    percent = 80 }, -- was 0  eff HP 1000
			{ type = "electric", percent = 50 }, -- was 0  eff HP  400
		},
		max_health = 200, -- was 60
		time_to_live = 65*60, -- was 45
		
		separation_range = 2,
		range_from_player = 5,
		--friction = 0.016,
		max_speed = 0.3,
		selection_priority = 55, -- make selectable over buildings, was 35, normal buildings are 50, ore is 40
		-- can spawn item like this, could probably trigger script too, to add scrap resource, but I don't actually want that anymore
		--loot =
		--{
		--	{
		--		type = "item",
		--		name = "stone",
		--		amount_min = 2,
		--		amount_max = 10,
		--		independent_probability = 1
		--	}
		--}
	})
	meld(data.raw["combat-robot"]["distractor"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80               eff HP  1100
			{ type = "fire",     percent = 90 }, -- was 95               eff HP  5500
			{ type = "physical", percent = 70 }, -- was 0                eff HP  1833
			{ type = "laser",    percent = 80, decrease = 5 }, -- was 0  eff HP ~2750
			{ type = "electric", percent = 50 }, -- was 0                eff HP  1100
		},
		max_health = 550, -- was 180
		time_to_live = 125*60, -- was 90
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
	meld(data.raw["combat-robot"]["destroyer"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80                eff HP   800
			{ type = "fire",     percent = 90 }, -- was 95                eff HP  4000
			{ type = "physical", percent = 85, decrease = 5 }, -- was 0   eff HP ~2667
			{ type = "laser",    percent = 80, decrease = 3 }, -- was 0   eff HP ~2000
			{ type = "electric", percent = 90, decrease = 20 }, -- was 0  eff HP ~4000
		},
		max_health = 400, -- was 60, now same as a turret
		time_to_live = 120*60, -- was 120
		
		separation_range = 3,
		range_from_player = 4,
		friction = 0.020,
		max_speed = 0.2,
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
end

if settings.startup[g.MOD_NAME.."-nerf-turret-turn"].value then
	-- was 0.015   0.0025 -> very slow against biters (esp turret nests that get surrounded)
	data.raw["ammo-turret"]["gun-turret"].rotation_speed = 0.005 -- was 0.015
	data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.007 -- was 0.01   0.004
end

-- try to fix the missing vaults
-- bumping threshold can fix it, but it's not safe to bump by much without causing duplicate vaults!

-- preventing other ruins from spawning sometimes makes the vault spawn
-- despite the order giving the vault priority!?
-- maybe just bad luck due to rng changing?
--local ruins = {
--	"fulgoran-ruin-small",
--	"fulgoran-ruin-medium",
--	"fulgoran-ruin-big",
--	"fulgoran-ruin-stonehenge",
--	"fulgoran-ruin-colossal",
--	"fulgoran-ruin-huge",
--}
--data.raw["simple-entity"]["fulgoran-ruin-small"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-medium"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-big"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-stonehenge"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-colossal"].autoplace.probability_expression = "0"
--data.raw["simple-entity"]["fulgoran-ruin-huge"].autoplace.probability_expression = "0"

--for _,r in pairs(ruins) do
--	local a = data.raw["simple-entity"][VAULT_NAME].autoplace.order
--	local b = data.raw["simple-entity"][r].autoplace.order
--	assert(a < b)
--end

-- Seemingly sometimes this helps, but sometimes it does not
--data.raw["simple-entity"][VAULT_NAME].autoplace.placement_density = 10
--data.raw["simple-entity"][VAULT_NAME].autoplace.probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.0175) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"

--meld(data.raw["simple-entity"][VAULT_NAME], {
--	autoplace = {
--		placement_density = 10, -- was 1
--		-- thres was 0.015
--		--probability_expression = "(min(fulgora_spots, (1 - fulgora_starting_vault_cone) / 2) < 0.020) * min(fulgora_vaults_and_starting_vault, 1 - fulgora_starting_mask)"
--	}
--})
