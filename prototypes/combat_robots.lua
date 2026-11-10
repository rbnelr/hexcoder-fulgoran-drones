local const = require("const")
local common = require("prototypes.common")
local meld = require("__core__.lualib.meld")

local combat_robots = {}

local BOT_NAMES = {"defender", "distractor", "destroyer"}

-- lights for hostile bots and their emerge/descend projectiles (same light, so it doesn't pop on spawn/descend)
-- cones like the car headlights (oriented), rotate with the bot (confirmed), projectiles only get the circular part (would point up/down)
-- NOTE: DRONE_TINT is keyed by "fulgoran-<bot>", color = const.DRONE_TINT["defender"] was nil (=white)

-- car headlight cone, scaled, pointing forward + rotation (0 = forward, 0.25 = right, ...)
-- car is scale 2, shift {+-0.6, -14}
-- shift is rotated manually, untested whether the engine also rotates it by rotation_shift (then cones end up offset diagonally, use {0, -dist} instead)
local function cone_light(scale, rotation, intensity, color)
	local dist = 7 * scale
	local a = rotation * 2 * math.pi
	return {
		type = "oriented",
		minimum_darkness = 0.3,
		picture = {
			filename = "__core__/graphics/light-cone.png",
			priority = "extra-high",
			flags = { "light" },
			scale = scale,
			width = 200, height = 200,
		},
		rotation_shift = rotation,
		shift = { dist * math.sin(a), -dist * math.cos(a) },
		size = 2,
		intensity = intensity,
		color = color,
	}
end

local DRONE_LIGHTS = {
	["defender"] = { -- small blue + big search light cone
		{ intensity = 1, size = 3, color = {0.25, 0.45, 1} },
		cone_light(1.25, 0, 0.6, {0.6, 0.8, 1}),
	},
	["distractor"] = { -- big yellow
		{ intensity = 0.6, size = 5, color = {1, 0.80, 0.20} },
	},
	["destroyer"] = { -- small red (+ four short cones)
		{ intensity = 1, size = 2.5, color = {1, 0.2, 0.2} },
	},
}

-- flicker test (destroyer), modifier is a multiplier on intensity, offset_flicker desyncs bots by position hash
local DESTROYER_FLICKER = {
	--flicker_interval = 50, -- ticks
	--flicker_min_modifier = 0.8,
	--flicker_max_modifier = 1.0,
	--offset_flicker = true, -- by position hash, flickers too much
}
for i = 0, 3 do
	table.insert(DRONE_LIGHTS["destroyer"], meld(cone_light(0.35, i * 0.25 + 0.125, 0.5, {1, 0.3, 0.3}), DESTROYER_FLICKER))
end

-- projectiles fly straight up/down, cones would point the wrong way
local function circular_lights(lights)
	local res = {}
	for _,light in pairs(lights) do
		if light.type ~= "oriented" then
			table.insert(res, util.table.deepcopy(light))
		end
	end
	return res
end

-- tint the mask layer of a dying particle like the hostile bot
local function tint_particle(particle, tint)
	for _,pictures in pairs(particle.pictures) do
		assert(pictures.layers and pictures.layers[2] and pictures.layers[2].filename:find("-mask"))
		local mask = pictures.layers[2]
		mask.apply_runtime_tint = false
		mask.tint = tint
		mask.tint_as_overlay = true
	end
end

-- projectile that looks like a drone
---@param name string vanilla bot name
---@param proj_name string
---@param accell number
---@param speeds table<string, number>
---@param action table? nil = only visual
local function drone_projectile(name, proj_name, accell, speeds, action)
	local bot = data.raw["combat-robot"][name]
	local animation = util.table.deepcopy(bot.idle)
	local animation_shadow = util.table.deepcopy(bot.shadow_idle)
	local tint = const.DRONE_TINT["fulgoran-"..name]

	assert(animation.layers and animation.layers[2] and animation.layers[2].filename:find("-mask"))
	animation.layers[2].apply_runtime_tint = false
	animation.layers[2].tint = tint
	animation.layers[2].tint_as_overlay = true

	return {
		type = "projectile",
		name = proj_name,
		flags = { "not-on-map" },
		hidden = true,
		acceleration = accell,
		max_speed = speeds[name] / 60,
		-- Does this allow me to spawn the projectile with an orientation?
		-- no, in fact descend projectiles are upside down if set to true
		rotatable = false,
		action = action,
		light = circular_lights(DRONE_LIGHTS[name]), -- was { intensity = 0.5, size = 4 }
		enable_drawing_with_mask = true,
		animation = animation,
		shadow = animation_shadow,
	}
end

-- projectile that looks like a drone, to create illusion of drones acending out of hole before they actually become active
-- TODO: tinting doesn't work for these yet

-- projectiles can be covered up by fulgoran-ruin-vault-near-wall
-- what was also suggested was rendering manually with LuaRendering (allow for fading in from black etc.)
-- and using smoke-with-trigger (which has features for fade in, but possibly can't actually move in a line?)
--- slow projectiles that look like bots and spawn bots on "hit", used to make it look like bots are ascending before actually being spawned
local function emerge_projectiles()
	for _,name in pairs(BOT_NAMES) do -- was pairs(data.raw["combat-robot"]), which asserts on modded combat robots
		data:extend{
			drone_projectile(name, "hexcoder-"..name.."-emerge", 0.01, const.EMERGE_SPEEDS, {
				type = "direct",
				action_delivery = {
					type = "instant",
					target_effects = {
						{
							type = "create-entity",
							entity_name = "fulgoran-"..name,
							trigger_created_entity = true,
						}
					}
				}
			}),
		}
		if const.DRONES_TRY_TO_RETURN then
			-- reverse of emerge: returning bot is destroy()ed by script and replaced by this, ends hidden behind the near-wall
			data:extend{ drone_projectile(name, "hexcoder-"..name.."-descend", 0.01, const.DESCEND_SPEEDS, nil) } 
		end
	end
end

-- buff HP and resistances by a lot, otherwise very few turret completely defeat even huge swarms
-- lengthen time to live
-- adjust friction and max_speed to prevent drones moving at unlimited speeds, make movements a bit more visually followable
-- separation_range/range_from_player adjust distance from target and each other
-- both both player and enemy versions for now
local function balance()
	meld(data.raw["combat-robot"]["defender"], {
		resistances = meld.overwrite{
			{ type = "acid",     percent = 50 }, -- was 80 eff HP  400
			{ type = "fire",     percent = 90 }, -- was 95 eff HP 2000
			{ type = "physical", percent = 70 }, -- was 0  eff HP  667
			{ type = "laser",    percent = 80 }, -- was 0  eff HP 1000
			{ type = "electric", percent = 50 }, -- was 0  eff HP  400
		},
		max_health = 200, -- was 60
		--time_to_live = 65*60, -- was 45sec

		separation_range = 1.6, -- was 1
		range_from_player = 2.5, -- was 6
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
		--time_to_live = 125*60, -- was 90sec
		time_to_live = 60*60,
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
		
		-- want to avoid seperation force from distractors around vault, but this likely does not work
		separation_range = 0,
		range_from_player = 0,
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
		--time_to_live = 120*60, -- was 120sec
		time_to_live = 70*60, -- shorter than distractors, distractors feel like they should last longest

		separation_range = 2.0, -- was 1.5
		range_from_player = 2.8, -- was 6
		friction = 0.020,
		max_speed = 0.2,
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
	
	-- lights for vanilla bots
	for _, name in pairs(BOT_NAMES) do
		data.raw["combat-robot"][name].light = util.table.deepcopy(DRONE_LIGHTS[name])
	end
end

-- distractor capsule takes 3 defenders, destroyer capsule 4 distractors (wrecks recycle into the lower capsule)
local function capsule_recipes()
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
		prerequisites = common.meld_add_or_assign{"battery-equipment"}
	})

	-- destroyer capsule takes 4 distractors, spawns 4 destroyers now instead of 5
	data.raw["projectile"]["destroyer-capsule"].action.action_delivery.target_effects.offsets = {
		{ 0, 0 },
		{ 0, 0.7 },
		{ 0.87*0.7, -0.5*0.7 },
		{-0.87*0.7, -0.5*0.7 } -- 0.87 ~= sin(120)   -0.5 ~= cos(120)
	} -- was {{-0.7, -0.7},{-0.7, 0.7},{0.7, -0.7},{0.7, 0.7},{0, 0}} ie. X
	meld(data.raw["recipe"]["destroyer-capsule"], {
		energy_required = 18,
		ingredients = meld.overwrite{
			{ type="item", name="steel-plate", amount=4 },
			{ type="item", name="processing-unit", amount=1 },
			{ type="item", name="supercapacitor", amount=2 }, -- supercapacitor since it has a electric attack, and to help sci
			{ type="item", name="distractor-capsule", amount=4 },
		}
	})
	meld(data.raw["technology"]["destroyer"], {
		prerequisites = common.meld_add_or_assign{"electromagnetic-plant"}
	})
end

-- Fits in data-update, but there we don't get automatic recylcling recipes!
-- dying particles that trigger the wreck script, dead-<bot> items and resources
local function harvestable_drones()
	capsule_recipes()

	data:extend{{
		type = "custom-event",
		name = const.MOD_NAME.."-on-create-combat-bot-remnant",
	}}

	local order = {
		["defender"]="a[defender]",
		["distractor"]="b[distractor]",
		["destroyer"]="c[destroyer]"
	}
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
	for _, name in pairs(BOT_NAMES) do
		local capsule = data.raw["capsule"][name.."-capsule"]
		local robot = data.raw["combat-robot"][name]
		local corpse = data.raw["corpse"][name.."-remnants"]
		local hostile_dying_particle = table.deepcopy(data.raw["optimized-particle"][name.."-dying-particle"])
		local hostile_expired_particle = nil
		local tint = const.DRONE_TINT["fulgoran-"..name]

		-- spawn dead bot resource (or regular remnant) via particle and custom event
		-- this will look nicer than reacting to on_entity_died|on_combat_robot_expired and also avoid spawning it on oil ocean
		-- only apply this to hostile version of bot, player version could also want this
		-- if future bot-on-bot fights are desirable, if so should only spawn resource on fulgora?
		hostile_dying_particle.name = "fulgoran-"..hostile_dying_particle.name

		local trigger = hostile_dying_particle.ended_on_ground_trigger_effect
		assert(trigger and trigger[1].type == "create-entity")
		trigger[1] = {
			type = "script",
			effect_id = "fulgoran-"..name,
			custom_event = const.MOD_NAME.."-on-create-combat-bot-remnant",
		}
		tint_particle(hostile_dying_particle, tint)

		-- expired bots (destroy_action) get a tinted particle that keeps the vanilla (untinted) remnants, no wreck
		-- so wreck resources only pile up where drones are actually killed
		if not const.EXPIRED_DRONES_HARVESTABLE then
			hostile_expired_particle = table.deepcopy(data.raw["optimized-particle"][name.."-dying-particle"])
			hostile_expired_particle.name = "fulgoran-"..name.."-expired-particle"
			tint_particle(hostile_expired_particle, tint)
		end

		local wreck_icon = corpse.icon

		local item = table.deepcopy(capsule)
		meld(item, {
			--name = "dead-"..name.."-capsule",
			name = "dead-"..name,
			type = "item",
			icon = wreck_icon,
			-- item is not craftable and has no autoplace, so maybe game thinks it's not obtainable, so does not show filter or signals
			-- and shows as red in factoriopedia, this fixes that
			flags = meld.overwrite{ "always-show" },
			--subgroup = corpse.subgroup,
			--order = capsule.order,
			subgroup = "fulgora-processes",
			order = "z[dead-bots]-"..order[name],
			capsule_action = meld.delete(),
			stack_size = 50,
		})

		local sprite = robot_resource_sprites[name]
		local resource = table.deepcopy(data.raw["resource"]["scrap"])
		meld(resource, {
			--type = "resource",
			name = "dead-"..name,
			icon = wreck_icon,
			--flags = {"placeable-neutral"},

			subgroup = corpse.subgroup,
			order = robot.order,

			cliff_removal_probability = 0, -- do not delete cliffs!
			tree_removal_probability = 0,
			tree_removal_max_distance = 0,

			autoplace = meld.delete(),

			minable = meld.overwrite{
				mining_time = 3.5,
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
					-- mining depletion advances vertically (variation)
					filename = const.MOD_DIR.."/graphics/"..name.."-resource.png",
					priority = "extra-high",
					width = sprite.base.width, height = sprite.base.height,
					shift = sprite.base.shift,
					scale = 0.5,
					frame_count = 3,
					variation_count = 1,
				},
				{
					filename = const.MOD_DIR.."/graphics/"..name.."-resource-mask.png",
					priority = "extra-high",
					width = sprite.mask.width, height = sprite.mask.height,
					shift = sprite.mask.shift,
					scale = 0.5,
					frame_count = 3,
					variation_count = 1,
					tint = tint,
					tint_as_overlay = true,
				},
			} },
			stage_counts = meld.overwrite{1},
			map_color = meld.overwrite{ 0.85, 0.4, 0.6 },

			factoriopedia_simulation = meld.overwrite(corpse.factoriopedia_simulation), -- actually just nil, but either way works
			factoriopedia_description = meld.overwrite(corpse.factoriopedia_description),
			--factoriopedia_alternative = item.name,
		})

		data:extend{hostile_dying_particle, resource, item}
		if hostile_expired_particle then
			data:extend{hostile_expired_particle}
		end
	end
end

-- Add hostile versions of combat bot entities to be able to color them individually instead of one color per force
-- and to allow hostile ones to spawn resource and player ones not
local function hostile_copies()
	for _, name in pairs(BOT_NAMES) do
		local hostile_bot = table.deepcopy(data.raw["combat-robot"][name])
		hostile_bot.name = "fulgoran-"..hostile_bot.name
		hostile_bot.localised_name = {"", {"entity-name."..name}, " (Fulgoran)"}
		-- If seperate stats, then don't hide?
		-- needs to be visible for circuit signals, but now it's visible for follower robot count, can this be fixed?
		hostile_bot.subgroup = "enemies"
		hostile_bot.icons = {
			{ icon = hostile_bot.icon,
				icon_size = 64, scale = .5 },
			{ icon = "__base__/graphics/icons/signal/signal-skull.png",
				icon_size = 64, scale = .25, shift = {10, 11} },
		}
		hostile_bot.icon = nil
		--hostile_bot.hidden = true
		--hostile_bot.hidden_in_factoriopedia = true
		--hostile_bot.factoriopedia_alternative = name

		if const.HARVESTABLE_BOTS then
			local dying_particle = "fulgoran-"..name.."-dying-particle"
			local expired_particle = "fulgoran-"..name.."-expired-particle"
			
			-- killed (dying_trigger_effect) and expired (destroy_action) are separate
			local dying_trigger = hostile_bot.dying_trigger_effect
			assert(dying_trigger and dying_trigger[1].type == "create-particle")
			dying_trigger[1].particle_name = dying_particle

			local destroy_action = hostile_bot.destroy_action
			assert(destroy_action and destroy_action.action_delivery)
			local src_effects = destroy_action.action_delivery.source_effects
			assert(src_effects and src_effects[1] and src_effects[1].type == "create-particle")
			src_effects[1].particle_name = const.EXPIRED_DRONES_HARVESTABLE and dying_particle or expired_particle
		end

		local mask = hostile_bot.idle.layers[2]
		mask.apply_runtime_tint = false -- I think this means no force based tinting
		mask.tint = const.DRONE_TINT[hostile_bot.name]
		mask.tint_as_overlay = true

		mask = hostile_bot.in_motion.layers[2]
		mask.apply_runtime_tint = false -- I think this means no force based tinting
		mask.tint = const.DRONE_TINT[hostile_bot.name]
		mask.tint_as_overlay = true

		hostile_bot.light = util.table.deepcopy(DRONE_LIGHTS[name])

		data:extend{hostile_bot}
	end
end

-- dead-<bot>-recycling: copy of the capsule recycling with capsules swapped for wrecks
-- must run after the recycler generated the recycling recipes (its data-updates)
local function dead_bot_recycling()
	for _, name in pairs(BOT_NAMES) do
		local real_recyc = data.raw["recipe"][name.."-capsule-recycling"]
		local auto_recyc = data.raw["recipe"]["dead-"..name.."-recycling"]

		local dead_recyc = meld(table.deepcopy(real_recyc), {
			name = auto_recyc.name,
			-- item to recycle is not craftable and has no autoplace, so maybe game thinks it's not obtainable, so does not show filter or signals
			-- and shows as red in factoriopedia, this fixes that
			flags = meld.overwrite{ "always-show" },
			ingredients = meld.overwrite{{ type="item", name="dead-"..name, amount=1 }},
			icons = auto_recyc.icons,
			localised_name = auto_recyc.localised_name,
			enabled = true,
		})
		for _,v in pairs(dead_recyc.results) do
			if v.name:find("-capsule") then
				v.name = "dead-"..v.name:gsub("-capsule", "")
			end
		end
		data.raw["recipe"]["dead-"..name.."-recycling"] = dead_recyc
	end
end

function combat_robots.data()
	emerge_projectiles()
	if settings.startup[const.MOD_NAME.."-buff-drones"].value then
		balance()
	end
	if const.HARVESTABLE_BOTS then
		harvestable_drones()
	end
	hostile_copies() -- after balance and harvestable, copies the final vanilla bots
end

function combat_robots.data_updates()
	if const.HARVESTABLE_BOTS then
		dead_bot_recycling()
	end
end

return combat_robots
