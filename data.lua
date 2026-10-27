local g = require("common")

--[[
local sounds = require("__base__.prototypes.entity.sounds")
data:extend{
	{
		type = "capsule",
		name = "hexcoder-defender-emerge",
		localised_name = {"", "Spawn emerging defender robot"},
		icon = "__base__/graphics/icons/defender-capsule.png",
		capsule_action = {
			type = "throw",
			attack_parameters = {
				type = "projectile",
				activation_type = "throw",
				ammo_category = "capsule",
				cooldown = 5,
				cooldown_deviation = .8,
				--projectile_creation_distance = 0.6,
				projectile_creation_offsets = {
					{-1,-1},
					{1,-1},
					{-1,1},
					{1,1},
				},
				range = 20,
				ammo_type = {
					target_type = "position",
					action = {
						{
							type = "direct",
							action_delivery = {
								type = "projectile",
								projectile = "hexcoder-defender-emerge",
								starting_speed = 0.0
							}
						},
						{
							type = "direct",
							action_delivery =
							{
								type = "instant",
								target_effects =
								{
									{
										type = "play-sound",
										sound = sounds.throw_projectile
									}
								}
							}
						}
					}
				}
			}
		},
		subgroup = "capsule",
		order = "d[defender]-b[capsule]",
		stack_size = 100,
		weight = 10 * kg
	},
}
]]

-- projectile that looks like a drone, to create illusion of drones acending out of hole before they actually become active
-- TODO: tinting doesn't work for these yet

-- projectiles can be covered up by fulgoran-ruin-vault-near-wall
-- what was also suggested was rendering manually with LuaRendering (allow for fading in from black etc.)
-- and using smoke-with-trigger (which has features for fade in, but possibly can't actually move in a line?)
--- slow projectiles that look like bots and spawn bots on "hit", used to make it look like bots are ascending before actually being spawned
for name,bot in pairs(data.raw["combat-robot"]) do
	local animation = util.table.deepcopy(bot.idle)
	local animation_shadow = util.table.deepcopy(bot.shadow_idle)
	
	--animation.layers[2].tint = {255,215,0} -- not working
	--animation.layers[2].apply_runtime_tint = true
	
	data:extend{
		{
			type = "projectile",
			name = "hexcoder-"..name.."-emerge",
			flags = { "not-on-map" },
			hidden = true,
			acceleration = 0.01,
			max_speed = g.EMERGE_SPEEDS[name] / 60,
			rotatable = true, -- Does this allow me to spawn the projectile with an orientation?
			action = {
				type = "direct",
				action_delivery = {
					type = "instant",
					target_effects = {
						{
							type = "create-entity",
							show_in_tooltip = true,
							entity_name = name,
							trigger_created_entity = true,
						}
					}
				}
			},
			light = { intensity = 0.5, size = 4 },
			enable_drawing_with_mask = true,
			animation = animation,
			shadow = animation_shadow,
		},
	}
end

-- hidden entity to act as a waypoint around the vault for random drone movement, since drone can't move to arbitrary positions
data:extend{
	{
		name = g.WAYPOINT,
		type = "simple-entity",
		--picture = g.DEBUG and data.raw["container"]["wooden-chest"].picture or nil,
	}
}

local meld = require("__core__.lualib.meld")
-- Fits in data-update, but there we don't get automatic recylcling recipies!

-- distractor capsule takes 3 defenders, spawns 3 distractors
meld(data.raw["recipe"]["distractor-capsule"], {
	ingredients = meld.overwrite{
		{ type="item", name="advanced-circuit", amount=3 },
		-- personal battery recycles into ~ 1.25 batteries and steel
		-- battery since it's a laser turret drone, and to give more batteries for sci
		-- 1 distractor recycles into 0.9375 batteries
		{ type="item", name="battery-equipment", amount=3 },
		{ type="item", name="defender-capsule", amount=3 },
	}
})
meld(data.raw["technology"]["distractor"], {
	prerequisites = g.meld_append_unique{"battery-equipment"}
})

-- destroyer capsule takes 4 distractors, spawns 4 destroyers now instead of 5
data.raw["projectile"]["destroyer-capsule"].action.action_delivery.target_effects.offsets = {
	{ 0, 0 },
	{ 0, 0.7 },
	{ 0.87*0.7, -0.5*0.7 },
	{-0.87*0.7, -0.5*0.7 } -- 0.87 ~= sin(120)   -0.5 ~= cos(120)
} -- was {{-0.7, -0.7},{-0.7, 0.7},{0.7, -0.7},{0.7, 0.7},{0, 0}} ie. X
meld(data.raw["recipe"]["destroyer-capsule"], {
	ingredients = meld.overwrite{
		{ type="item", name="steel-plate", amount=4 },
		{ type="item", name="processing-unit", amount=1 },
		{ type="item", name="supercapacitor", amount=2 }, -- supercapacitor since it has a electric attack, and to help sci
		{ type="item", name="distractor-capsule", amount=4 },
	}
})
meld(data.raw["technology"]["destroyer"], {
	prerequisites = g.meld_append_unique{"electromagnetic-plant"}
})

local robot_resource_sprites = {
	["defender"] = {
		base = { width = 98, height = 94, shift = util.by_pixel(0.5, 0), },
		mask = { width = 98, height = 54, shift = util.by_pixel(0.5, -2.5), },
	},
	["distractor"] = {
		base = { width = 112, height = 110, shift = util.by_pixel(-0.5, 0), },
		mask = { width = 112, height = 60, shift = util.by_pixel(-0.5, -2.5), },
	},
	["destroyer"] = {
		base = { width = 120, height = 108, shift = util.by_pixel(1.5, 0), },
		mask = { width = 120, height =  64, shift = util.by_pixel(1.5, -11), },
	},
}
for _, name in pairs({"defender", "distractor", "destroyer"}) do
	local capsule = data.raw["capsule"][name.."-capsule"]
	local robot = data.raw["combat-robot"][name]
	local corpse = data.raw["corpse"][name.."-remnants"]
	
	-- TODO: make the icon actually the wreck graphic, but try to tint it first
	local wreck_icon = corpse.icon
	
	local item = table.deepcopy(capsule)
	meld(item, {
		name = "dead-"..name.."-capsule",
		type = "item",
		icon = wreck_icon,
		subgroup = corpse.subgroup,
		order = capsule.order,
		capsule_action = meld.delete(),
	})
	
	local sprite = robot_resource_sprites[name]
	local resource = table.deepcopy(data.raw["resource"]["scrap"])
	meld(resource, {
		--type = "resource",
		name = "resource-dead-"..name,
		icon = wreck_icon,
		--flags = {"placeable-neutral"},
		
		subgroup = corpse.subgroup,
		order = robot.order,
		
		tree_removal_probability = meld.delete(),
		tree_removal_max_distance = meld.delete(),
		autoplace = meld.delete(),
		
		minable = meld.overwrite{
			mining_time = 5,
			results = {{
				type="item",
				name=item.name,
				amount=1,
				ignored_by_productivity=1
			}},
		},
		stages = meld.overwrite{ sheets = {
			--{
			--	-- for resources variations (each tile looking different) are frames in animation sheet
			--	-- mining depletion advances vertially (variation)
			--	filename = "__base__/graphics/entity/destroyer-robot/destroyer-robot.png",
			--	priority = "extra-high",
			--	width = 88, height = 77,
			--	y = 77,
			--	shift = util.by_pixel(2.5, -1.25),
			--	scale = 0.5,
			--	frame_count = 32,
			--	variation_count = 1,
			--},
			--{
			--	filename = "__base__/graphics/entity/destroyer-robot/destroyer-robot-mask.png",
			--	priority = "extra-high",
			--	width = 52, height = 42,
			--	y = 42,
			--	shift = util.by_pixel(2.5, -7),
			--	scale = 0.5,
			--	frame_count = 32,
			--	variation_count = 1,
			--	tint = {1,0,0}
			--},
			{
				-- for resources variations (each tile looking different) are frames in animation sheet
				-- mining depletion advances vertially (variation)
				filename = g.MOD_DIR.."/graphics/"..name.."-resource.png",
				priority = "extra-high",
				width = sprite.base.width, height = sprite.base.height,
				shift = sprite.base.shift,
				scale = 0.5,
				frame_count = 3,
				variation_count = 1,
			},
			{
				filename = g.MOD_DIR.."/graphics/"..name.."-resource-mask.png",
				priority = "extra-high",
				width = sprite.mask.width, height = sprite.mask.height,
				shift = sprite.mask.shift,
				scale = 0.5,
				frame_count = 3,
				variation_count = 1,
				tint = g.DRONE_TINT[name],
				tint_as_overlay = true,
			},
		} },
		stage_counts = meld.overwrite{1},
		map_color = meld.overwrite{ 0.85, 0.4, 0.6 },
		
		factoriopedia_simulation = meld.overwrite(corpse.factoriopedia_simulation), -- actually just nil, but either way works
		factoriopedia_description = meld.overwrite(corpse.factoriopedia_description),
		--factoriopedia_alternative = item.name,
	})
	
	data:extend{resource, item}
end
