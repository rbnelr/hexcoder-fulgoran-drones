local meld = require("__core__.lualib.meld")
require("common")

for _,type in pairs(TARGETS) do
	for _,e in pairs(data.raw[type]) do
		e.allow_run_time_change_of_is_military_target = true
	end
end

meld(data.raw["combat-robot"]["defender"], {
	resistances = meld.overwrite{
		{ type = "acid",     percent = 80 }, -- was 80
		{ type = "fire",     percent = 95 }, -- was 95
		{ type = "physical", percent = 60 }, -- was 0
		{ type = "laser",    percent = 80 }, -- was 0
		{ type = "electric", percent = 60 }, -- was 0
	},
	max_health = 100, -- was 60
	time_to_live = 65*60, -- was 45
	
	separation_range = 2,
	range_from_player = 5,
	--friction = 0.016,
	max_speed = 0.3,
	selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
})
meld(data.raw["combat-robot"]["distractor"], {
	resistances = meld.overwrite{
		{ type = "acid",     percent = 80 }, -- was 80
		{ type = "fire",     percent = 95 }, -- was 95
		{ type = "physical", percent = 70 }, -- was 0
		{ type = "laser",    percent = 90, decrease = 5 }, -- was 0
		{ type = "electric", percent = 70 }, -- was 0
	},
	max_health = 360, -- was 180
	time_to_live = 125*60, -- was 90
	selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
})
meld(data.raw["combat-robot"]["destroyer"], {
	resistances = meld.overwrite{
		{ type = "acid",     percent = 80 }, -- was 80
		{ type = "fire",     percent = 95 }, -- was 95
		{ type = "physical", percent = 75, decrease = 3 }, -- was 0
		{ type = "laser",    percent = 86, decrease = 3 }, -- was 0
		{ type = "electric", percent = 80, decrease = 12 }, -- was 0
	},
	max_health = 220, -- was 60
	time_to_live = 120*60, -- was 120
	
	separation_range = 3,
	range_from_player = 4,
	friction = 0.020,
	max_speed = 0.2,
	selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
})

meld(data.raw["simple-entity"][VAULT_NAME], {
	selection_priority = 45, -- normal buildings are 50, ore is 40
	minable = meld.delete(),--meld.overwrite{minable=false, mining_time=999999999},
	max_health = 1000000, healing_per_tick = 1000000/60,
	loot = meld.delete(),
})
data:extend{
	{
		type = "simple-entity", -- use optimized-decorative instead?
		name = VAULT_NEAR_WALL_NAME,
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
		icon = data.raw["simple-entity"][VAULT_NAME].icon,
		collision_box = nil,
		collision_mask = { layers = {} },
		selection_box = {{0,0}, {0,0}},
		selectable_in_game = false,
	}
}

meld(data.raw["technology"]["recycling"], {
	research_trigger = meld.overwrite{
		type = "mine-entity",
		entities = {"fulgoran-ruin-colossal", "fulgoran-ruin-huge"} -- can't actually mine fulgoran-ruin-vault now!
	}
})


--local robot1 = table.deepcopy(data.raw["combat-robot"]["defender"])
--local robot2 = table.deepcopy(data.raw["combat-robot"]["distractor"])
--local robot3 = table.deepcopy(data.raw["combat-robot"]["destroyer"])
--meld(robot1, { name = "fulgoran-defender",
--	localised_name = {"", {"entity-name.defender"}, " (fulgoran)"},
--	time_to_live = 40*60
--})
--meld(robot2, { name = "fulgoran-distractor",
--	localised_name = {"", {"entity-name.distractor"}, " (fulgoran)"},
--	time_to_live = 60*60
--})
--meld(robot3, { name = "fulgoran-destroyer",
--	localised_name = {"", {"entity-name.destroyer"}, " (fulgoran)"},
--	time_to_live = 60*60
--})
--data:extend{ robot1, robot2, robot3 }

data.raw["ammo-turret"]["gun-turret"].rotation_speed = 0.002
data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.04
