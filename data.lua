local sounds = require("__base__.prototypes.entity.sounds")
require("common")

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
	{
		type = "projectile",
		name = "hexcoder-defender-emerge",
		flags = { "not-on-map" },
		hidden = true,
		acceleration = 0.005,
		max_speed = 0.4 / 60,
		rotatable = false,
		action = {
			type = "direct",
			action_delivery = {
				type = "instant",
				target_effects = {
					{
						type = "create-entity",
						show_in_tooltip = true,
						entity_name = "defender"
					}
				}
			}
		},
		light = { intensity = 0.5, size = 4 },
		enable_drawing_with_mask = true,
		animation = {
			layers = {
				{
					filename = "__base__/graphics/entity/combat-robot-capsule/defender-capsule.png",
					flags = { "no-crop" },
					width = 28,
					height = 20,
					priority = "high"
				},
				{
					filename = "__base__/graphics/entity/combat-robot-capsule/defender-capsule-mask.png",
					flags = { "no-crop" },
					width = 28,
					height = 20,
					priority = "high",
					apply_runtime_tint = true
				}
			}
		},
		shadow = {
			filename = "__base__/graphics/entity/combat-robot-capsule/defender-capsule-shadow.png",
			flags = { "no-crop" },
			width = 26,
			height = 20,
			priority = "high"
		},
	},
}

data:extend{
	{
		name = mod_name.."-waypoint",
		type = "simple-entity",
		picture = data.raw["container"]["wooden-chest"].picture,
	}
}
