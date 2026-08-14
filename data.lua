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
		picture = g.DEBUG and data.raw["container"]["wooden-chest"].picture or nil,
	}
}
