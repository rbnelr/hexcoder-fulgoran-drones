local meld = require("__core__.lualib.meld")
require("common")

for _,type in pairs(TARGETS) do
	for _,e in pairs(data.raw[type]) do
		e.allow_run_time_change_of_is_military_target = true
	end
end

meld(data.raw["combat-robot"]["defender"], {
	resistances = meld.overwrite{
		{ type = "acid", percent = 80 },
		{ type = "fire", percent = 95 },
		{ type = "physical", percent = 30 },
		{ type = "laser", percent = 10 },
		{ type = "electric", percent = 70 }
	},
	max_health = 100,
	time_to_live = 45*60,
	
	separation_range = 2,
	range_from_player = 5,
	--friction = 0.016,
	max_speed = 0.4,
})
meld(data.raw["combat-robot"]["distractor"], {
	resistances = meld.overwrite{
		{ type = "acid", percent = 80 },
		{ type = "fire", percent = 95 },
		{ type = "physical", percent = 70 },
		{ type = "laser", percent = 70 },
		{ type = "electric", percent = 80 }
	},
	max_health = 280,
	time_to_live = 60*60
})
meld(data.raw["combat-robot"]["destroyer"], {
	resistances = meld.overwrite{
		{ type = "acid", percent = 80 },
		{ type = "fire", percent = 95 },
		{ type = "physical", percent = 55 },
		{ type = "laser", percent = 65 },
		{ type = "electric", percent = 65 }
	},
	max_health = 175,
	time_to_live = 65*60,
	
	separation_range = 3,
	range_from_player = 4,
	friction = 0.020,
	max_speed = 0.2,
})

meld(data.raw["simple-entity"]["fulgoran-ruin-vault"], {
	selection_priority = 0, -- doesn't do anything?
	minable = meld.overwrite{minable=false, mining_time=999999999},
	max_health = 999999999, healing_per_tick = 999999999,
	loot = meld.delete(),
})
data:extend{
	{
		type = "simple-entity", -- use optimized-decorative instead?
		name = "fulgoran-ruin-vault-near-wall",
		flags = {"placeable-neutral", "placeable-off-grid"},
		order = "b[decorative]-l[rock]-d[fulgora]-e[ruin]-g[vault]",
		hidden = true,
		selection_priority = 100,
		minable = {minable=false, mining_time=999999999},
		max_health = 999999999, healing_per_tick = 999999999,
		pictures = {
			{width = 960, height = 640, filename = "__hexcoder-fulgoran-drones__/graphics/fulgoran-ruin-vault-near-wall.png",
			shift = util.by_pixel( 18.5/2, -6/2), scale = 0.5}
		},
		--render_layer = "higher-object-under",
		render_layer = "air-object",
		icon = data.raw["simple-entity"]["fulgoran-ruin-vault"].icon,
		collision_box = nil,
		collision_mask = { layers = {} },
		selection_box = {{0,0}, {0,0}},
		selectable_in_game = false,
	}
}


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
data.raw["electric-turret"]["laser-turret"].rotation_speed = 0.06
