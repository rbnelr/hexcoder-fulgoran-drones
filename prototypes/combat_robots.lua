local const = require("const")
local common = require("prototypes.common")
local meld = require("__core__.lualib.meld")

local combat_robots = {}

local BOT_NAMES = {
	["defender"]="fulgoran-defender",
	["distractor"]="fulgoran-distractor",
	["destroyer"]="fulgoran-destroyer",
}

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

-- flicker is kinda ugly, the idea was that these ancient drones are a little bit broken, so lights flicker
-- TODO: manually combine 4 cones into a new graphic, maybe then flicker will look better
local DESTROYER_FLICKER = {
	--flicker_interval = 50, -- ticks
	--flicker_min_modifier = 0.8,
	--flicker_max_modifier = 1.0,
	--offset_flicker = true, -- by position hash, flickers too much
}
for i = 0, 3 do
	table.insert(DRONE_LIGHTS["destroyer"], meld(cone_light(0.35, i * 0.25, 0.5, {1, 0.3, 0.3}), DESTROYER_FLICKER))
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
---@param hostile_name string
---@param proj_name string
---@param accell number
---@param speeds table<string, number>
---@param action table? nil = only visual
local function drone_projectile(name, hostile_name, proj_name, accell, speeds, action)
	local bot = data.raw["combat-robot"][name]
	local animation = util.table.deepcopy(bot.idle)
	local animation_shadow = util.table.deepcopy(bot.shadow_idle)
	local tint = const.DRONE_TINT[hostile_name]

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
	for name, hostile_name in pairs(BOT_NAMES) do -- was pairs(data.raw["combat-robot"]), which asserts on modded combat robots
		data:extend{
			drone_projectile(name, hostile_name, "hexcoder-"..name.."-emerge", 0.01, const.EMERGE_SPEEDS, {
				type = "direct",
				action_delivery = {
					type = "instant",
					target_effects = {
						{
							type = "create-entity",
							entity_name = hostile_name,
							trigger_created_entity = true,
						}
					}
				}
			}),
		}
		if const.DRONES_TRY_TO_RETURN then
			-- reverse of emerge: returning bot is destroy()ed by script and replaced by this, ends hidden behind the near-wall
			data:extend{ drone_projectile(name, hostile_name, "hexcoder-"..name.."-descend", 0.01, const.DESCEND_SPEEDS, nil) } 
		end
	end
end

-- hostile distractor laser in the drone tint (vanilla laser-beam is shared with the laser turret, so copy)
-- the vanilla laser textures are pure red (255,0,0 glow), tint can only multiply, so the color textures are recolored copies
-- (fulgoran-laser-body/end.png, generated from the vanilla ones, tint {0.57, 0.78, 0.21}, white core kept)
-- light layers are white and the ground light is tinted in the prototype, so those just get the tint
local function hostile_laser_beam(hostile_name)
	local tint = const.DRONE_TINT[hostile_name]
	local beam = table.deepcopy(data.raw["beam"]["laser-beam"])
	beam.name = hostile_name.."-laser-beam"
	beam.localised_name = {"entity-name.laser-beam"}
	local recolored = {
		["__base__/graphics/entity/laser-turret/laser-body.png"] = const.MOD_DIR.."/graphics/fulgoran-laser-body.png",
		["__base__/graphics/entity/laser-turret/laser-end.png"] = const.MOD_DIR.."/graphics/fulgoran-laser-end.png",
	}
	local function recolor(anim)
		for _,layer in pairs(anim and anim.layers or {}) do
			if recolored[layer.filename] then
				layer.filename = recolored[layer.filename]
			elseif layer.draw_as_light then
				layer.tint = tint
			end
		end
	end
	local gs = beam.graphics_set.beam
	recolor(gs.head)
	recolor(gs.tail)
	for _,body in pairs(gs.body or {}) do recolor(body) end
	for _,ground in pairs(beam.graphics_set.ground or {}) do
		ground.tint = { tint[1] * 0.5, tint[2] * 0.5, tint[3] * 0.5 } -- was {0.5, 0.05, 0.05}
	end
	data:extend{beam}
	return beam.name
end

-- Add hostile versions of combat bot entities to be able to color them individually instead of one color per force
-- and to allow hostile ones to spawn resource and player ones not
local function hostile_copies()
	for name, hostile_name in pairs(BOT_NAMES) do
		local hostile_bot = table.deepcopy(data.raw["combat-robot"][name])
		hostile_bot.name = hostile_name
		hostile_bot.localised_name = {"", {"entity-name."..name}, " (Fulgoran)"}
		hostile_bot.subgroup = "enemies"
		hostile_bot.icons = {
			{ icon = hostile_bot.icon,
				icon_size = 64, scale = .5 },
			{ icon = "__base__/graphics/icons/signal/signal-skull.png",
				icon_size = 64, scale = .25, shift = {10, 10} },
		}
		hostile_bot.icon = nil
		-- If seperate stats, then don't hide?
		-- needs to be visible for circuit signals, but now it's visible for follower robot count, can this be fixed?
		--hostile_bot.hidden = true
		--hostile_bot.hidden_in_factoriopedia = true
		--hostile_bot.factoriopedia_alternative = name

		local mask = hostile_bot.idle.layers[2]
		mask.apply_runtime_tint = false -- I think this means no force based tinting
		mask.tint = const.DRONE_TINT[hostile_bot.name]
		mask.tint_as_overlay = true

		mask = hostile_bot.in_motion.layers[2]
		mask.apply_runtime_tint = false -- I think this means no force based tinting
		mask.tint = const.DRONE_TINT[hostile_bot.name]
		mask.tint_as_overlay = true

		hostile_bot.light = util.table.deepcopy(DRONE_LIGHTS[name])

		if name == "distractor" then
			local delivery = hostile_bot.attack_parameters.ammo_type.action.action_delivery
			assert(delivery.type == "beam" and delivery.beam == "laser-beam")
			delivery.beam = hostile_laser_beam(hostile_name)
		end

		data:extend{hostile_bot}
	end
end

-- Fits in data-update, but there we don't get automatic recylcling recipes!
-- dying particles that trigger the wreck script, dead-<bot> items and resources
local function harvestable_drones()
	data:extend{
		{ type = "custom-event", name = const.MOD_NAME.."-on-create-combat-bot-remnant" },
		{ type = "custom-event", name = const.MOD_NAME.."-on-combat-bot-died" }
	}

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
	for name, hostile_name in pairs(BOT_NAMES) do
		local capsule = data.raw["capsule"][name.."-capsule"]
		local robot = data.raw["combat-robot"][hostile_name]
		local corpse = data.raw["corpse"][name.."-remnants"]
		local tint = const.DRONE_TINT[hostile_name]
		local wreck_icon = corpse.icon
		local resource_name = "dead-"..name
		
	---- Dying particle
		-- expired bots (destroy_action) get a tinted particle that keeps the vanilla (untinted) remnants, no wreck
		-- so wreck resources only pile up where drones are actually killed
		-- does not need quality variants and this no script trigger
		local hostile_expired_particle = nil
		if not const.EXPIRED_DRONES_HARVESTABLE then
			hostile_expired_particle = table.deepcopy(data.raw["optimized-particle"][name.."-dying-particle"])
			hostile_expired_particle.name = hostile_name.."-expired-particle"
			tint_particle(hostile_expired_particle, tint)
			data:extend{hostile_expired_particle}
		end
		
		local spawn_quality_dying_particle_trigger = {
			type = "script",
			effect_id = hostile_name,
			custom_event = const.MOD_NAME.."-on-combat-bot-died", -- spawn particle with correct quality manually
		}
		
		-- killed (dying_trigger_effect) and expired (destroy_action) are separate
		--  weird that being destroyed is the nautral one, and dying is the violent one
		-- original create-particle:
		--  initial_height=1.8
		--  initial_vertical_speed=0
		--  frame_speed = 1 for dying_trigger_effect,  0.5 for destroy_action
		--  frame_speed_deviation = 0.5
		--  speed_from_center = 0
		--  speed_from_center_deviation = 0.2 for dying_trigger_effect,  0.1 for destroy_action
		--  offset_deviation = {-0.01,-0.01}, {0.01,0.01}
		--  offsets = {0, 0.5}
		do
			local dt = robot.dying_trigger_effect
			assert(dt and dt[1].type == "create-particle")
			dt[1] = spawn_quality_dying_particle_trigger
			--table.insert(dt, spawn_quality_dying_particle_trigger)
		end
		do
			local destroy_action = robot.destroy_action
			assert(destroy_action and destroy_action.action_delivery)
			local se = destroy_action.action_delivery.source_effects
			assert(se and se[1] and se[1].type == "create-particle")
			if hostile_expired_particle then
				se[1].particle_name = hostile_expired_particle.name
			else
				se[1] = spawn_quality_dying_particle_trigger
			end
		end
		
	---- Dead drone item
		local item = table.deepcopy(capsule)
		meld(item, {
			name = resource_name,
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

	---- Dead drone resource
		local sprite = robot_resource_sprites[name]
		local resource = table.deepcopy(data.raw["resource"]["scrap"])
		meld(resource, {
			name = resource_name, -- same name as item, shows up as (Entity/item)
			icon = wreck_icon,
			--flags = {"placeable-neutral"},

			subgroup = corpse.subgroup,
			order = robot.order,

			cliff_removal_probability = 0, -- do not delete cliffs!
			tree_removal_probability = 0,
			tree_removal_max_distance = 0,

			autoplace = meld.delete(),
			
			minable = meld.overwrite{
				mining_time = 0.4, -- had this at 3.5, but that's dumb
				results = {{
					type="item",
					name=item.name,
					amount=1,
					ignored_by_productivity=1, -- do we want this?
					--affected_by_quality = false, -- probably want this, TODO: not working?
					quality_min = "normal", quality_max = "normal", -- this does work
				}},
			},
			stages = meld.overwrite{ sheets = {
				{
					-- for resources variations (each tile looking different) are frames in animation sheet
					-- mining depletion advances vertically (variation)
					filename = const.MOD_DIR.."/graphics/"..name.."-resource.png",
					priority = "extra-high", flags = {"low-object"},
					width = sprite.base.width, height = sprite.base.height,
					shift = sprite.base.shift,
					scale = 0.5,
					frame_count = 3,
					variation_count = 1,
				},
				{
					filename = const.MOD_DIR.."/graphics/"..name.."-resource-mask.png",
					priority = "extra-high", flags = {"low-object"},
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

		data:extend{resource, item}
	end
end
-- Need to make quality variants for bot resource, because afaik resources can't have quality
local function harvestable_drones_quality_resource()
	for name, hostile_name in pairs(BOT_NAMES) do
		local res_name = "dead-"..name
		local tint = const.DRONE_TINT[hostile_name]
		local normal_resource = data.raw["resource"][res_name]
			
		-- The particle is visually flies off spinning in a random direction, landing 2-3 tiles away and normally spawning the remnant (corpse)
		-- this will look nicer than reacting to on_entity_died|on_combat_robot_expired and also avoid spawning it on oil ocean
		-- only apply this to hostile version of bot
		-- player version could also want this for future bot-on-bot fights
		--  (if so only spawn on fulgora?)
		local base_dying_particle = data.raw["optimized-particle"][name.."-dying-particle"]
		
		local Q = data.raw["quality"]["normal"]
		while Q do
			local Qres_name = res_name
			if Q.name ~= "normal" then
				Qres_name = res_name.."-"..Q.name
				local Qres = meld(table.deepcopy(normal_resource), {
					name = Qres_name,
					localised_name = {"", {"entity-name."..res_name}, " (", {"quality-name."..Q.name}, ")"},
					icons = {
						{ icon = normal_resource.icon, icon_size = 64, scale = .5 },
						{ icon = Q.icon, icon_size = 64, scale = .25, shift = {-10, 10} },
					},
					icon = meld.delete(),
					order = normal_resource.order.."-"..Q.order,
					hidden = true,
					
					minable = {
						results = {{
							quality_min = Q.name, quality_max = Q.name,
						}},
					},
				})
				if const.BOT_RESOURCE_QUALITY_BADGES then
					-- add a fake quality badge to resource graphics
					-- this does not disappear in alt mode like normal badges!
					table.insert(Qres.stages.sheets, {
						filename = Q.icon,
						priority = "extra-high", flags = {"low-object", "icon"}, -- no idea if flags are correct, without it's aliased
						width = 64, height = 64,
						scale = 0.125,
						shift = {-0.375, 0.375},
						variation_count = 1,
						frame_sequence = {1, 1, 1},
					})
				end
				
				data:extend{Qres}
			end
			
			-- variants of dying particle for each quality, as particle don't seem to track quality
			do
				local dp = table.deepcopy(base_dying_particle)
				dp.name = hostile_name.."-dying-particle-"..Q.name
				tint_particle(dp, tint)
				-- render_layer set on the vanilla particle in set_render_layers
				
				local trigger = dp.ended_on_ground_trigger_effect
				assert(trigger and trigger[1].type == "create-entity")
				trigger[1] = {
					type = "script",
					effect_id = Qres_name,
					custom_event = const.MOD_NAME.."-on-create-combat-bot-remnant",
				}
				data:extend{dp}
			end
			
			Q = data.raw["quality"][Q.next]
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
		max_speed = 0.28, -- was nil
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
		max_speed = 0.15, -- was nil
		selection_priority = 55, -- was 35, normal buildings are 50, ore is 40
	})
	
	-- lights for vanilla bots
	for name, hostile_name in pairs(BOT_NAMES) do
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

-- dead-<bot>-recycling: copy of the capsule recycling with capsules swapped for wrecks
-- must run after the recycler generated the recycling recipes (its data-updates)
local function dead_bot_recycling()
	for name, hostile_name in pairs(BOT_NAMES) do
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
	if const.BUFFED_DRONES then
		balance()
	end
	hostile_copies()
	if const.HARVESTABLE_BOTS then
		capsule_recipes()
		harvestable_drones()
	end
end

function combat_robots.data_updates()
	if const.HARVESTABLE_BOTS then
		dead_bot_recycling()
	end
end

-- Render layers, relative to the vault near-wall ("smoke", see vault_ruin.lua), which hides emerging drones (projectiles, drawn at "projectile", no render_layer field)
-- Layer order (low to high): object (buildings, trees) < higher-object-* < elevated rails < explosion < projectile < smoke (near-wall) < air-object (drones, flying robots)
-- Between layers order is strict, within a layer things are sorted (by y?)
--  beams default to "projectile" and explosions to "explosion", so attacks were drawn under the near-wall while the drones were over it
--  => all beams (combat robots, laser turret, tesla turret/gun, electric, modded) and beam explosions (bullet-trails tracers) go to "air-object"
--     they were already above all buildings, so this only changes order against smoke, the near-wall and flying things
--  => effects at combat robots (source_effects, e.g. defender gunshot, only used by defender in vanilla) go to "air-object" too
--     hits at the target stay, so they still hide behind the wall if the target is behind it
--  => combat robot dying particles go to "projectile": over explosions (death explosion hid the falling debris) and buildings, but still under the near-wall
--     (default "object" sorts with buildings, so debris falling behind a building was hidden)
-- all in place (no copies), shared prototypes are changed for everything using them
-- final_fixes so prototypes changed by other mods' data-updates are included
-- must run before harvestable_drones_quality_resource, which copies the vanilla dying particles
local AIR_LAYER = "air-object"
local DYING_PARTICLE_LAYER = "projectile"

local function as_list(t)
	if t == nil then return {} end
	if t.type then return {t} end -- single item, not array
	return t
end

---@param effects table? TriggerEffect
---@param explosion_layer string?
---@param particle_layer string?
local function set_effects_layer(effects, explosion_layer, particle_layer)
	for _,eff in pairs(as_list(effects)) do
		local explosion = (eff.type == "create-explosion" or eff.type == "create-entity") and data.raw["explosion"][eff.entity_name]
		local particle = eff.type == "create-particle" and data.raw["optimized-particle"][eff.particle_name]
		if explosion and explosion_layer then
			explosion.render_layer = explosion_layer
		elseif particle and particle_layer then
			particle.render_layer = particle_layer
		end
	end
end

---@param trigger table? Trigger
---@param explosion_layer string?
---@param particle_layer string?
local function set_trigger_source_layer(trigger, explosion_layer, particle_layer)
	for _,action in pairs(as_list(trigger)) do
		for _,delivery in pairs(as_list(action.action_delivery)) do
			set_effects_layer(delivery.source_effects, explosion_layer, particle_layer)
		end
	end
end

local function set_render_layers()
	for _,b in pairs(data.raw["beam"]) do
		if b.graphics_set and b.graphics_set.beam then b.graphics_set.beam.render_layer = AIR_LAYER end
	end
	for _,e in pairs(data.raw["explosion"]) do
		if e.beam then e.render_layer = AIR_LAYER end
	end
	for _,robot in pairs(data.raw["combat-robot"]) do
		local ammo_type = robot.attack_parameters and robot.attack_parameters.ammo_type
		set_trigger_source_layer(ammo_type and ammo_type.action, AIR_LAYER, AIR_LAYER)
		-- killed / expired
		set_effects_layer(robot.dying_trigger_effect, nil, DYING_PARTICLE_LAYER)
		set_trigger_source_layer(robot.destroy_action, nil, DYING_PARTICLE_LAYER)
	end
end

-- bullet-trails mod only adds tracers to ammo items, combat robots have their own ammo_type, so defenders had none
-- tracer = explosion with beam = true in target_effects (like the mod does for ammo), drawn from shooter to target
-- its explosions are defined in its data.lua, so they exist in final_fixes no matter the load order (no dependency needed)
local BULLET_TRAILS = {
	["fulgoran-defender"] = "bullet-beam-cyan-faint", -- matches the hostile defender tint
	default = "bullet-beam-white-faint", -- what the mod uses for unknown "bullet" ammo
}
local function add_bullet_trails()
	if not mods["bullet-trails"] then return end
	for name,robot in pairs(data.raw["combat-robot"]) do
		local ap = robot.attack_parameters
		local trail = BULLET_TRAILS[name] or BULLET_TRAILS.default
		if ap and ap.ammo_category == "bullet" and ap.ammo_type and data.raw["explosion"][trail] then
			local action = as_list(ap.ammo_type.action)[1]
			local delivery = action and as_list(action.action_delivery)[1]
			if delivery and delivery.type == "instant" then
				local effects = as_list(delivery.target_effects)
				delivery.target_effects = effects
				local has_trail = false
				for _,eff in pairs(effects) do
					if eff.entity_name and eff.entity_name:find("bullet-beam-", 1, true) then has_trail = true end
				end
				if not has_trail then
					table.insert(effects, { type = "create-explosion", entity_name = trail })
				end
			end
		end
	end
end

function combat_robots.final_fixes()
	add_bullet_trails()
	set_render_layers()
	if const.HARVESTABLE_BOTS then
		harvestable_drones_quality_resource()
	end
end

return combat_robots
