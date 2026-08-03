mod_name = "hexcoder-fulgoran-drones"
require("common")
local dmg = require("disable_on_damage")
require("vault")
require("spawning")
local movement = require("bot_movement")

local TINT = {0.80, 0.05, 0.05}
local TINT_FILL = {TINT[1]*0.1,TINT[2]*0.1,TINT[3]*0.1,0.1}

function init()
	-- create enemy drone force
	if game.forces[DRONE_FORCE] == nil then
		local force = game.create_force(DRONE_FORCE)
		--force.custom_color = {255,215,0}
		force.custom_color = {230,50,255}
	end
	
	local s = storage
	local init = s == nil
	if s == nil then s = {} storage = s end ---@diagnostic disable-line
	if s.vaults == nil then s.vaults = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.viz == nil then s.viz = {} end
	--if s.marked_military == nil then s.marked_military = {} end
	
	if init then
		local surf = game.get_surface("fulgora")
		if surf then
			for _,e in pairs(surf.find_entities_filtered{name=VAULT_NAME}) do
				init_vault(e)
			end
		end
	end
end
local function reset()
	local surf = game.get_surface("fulgora")
	if surf then
		for _,e in pairs(surf.find_entities_filtered{name={VAULT_NEAR_WALL_NAME,WAYPOINT}}) do
			e.destroy()
		end
	end
	
	rendering.clear(mod_name)
	
	game.merge_forces(game.forces[DRONE_FORCE], game.forces["player"]) -- can't delete forces directly (?)
	
	local s = storage
	if s and s.poll_repaired then
		for _,e in pairs(s.poll_repaired) do
			if e.entity and e.entity.valid then
				dmg.fix_building(e.entity.unit_number, e)
			end
		end
	end
	storage = nil
end

local _prev_ore = nil
commands.add_command("fulg-ore", "", function(command)
	init()
	local player = game.get_player(command.player_index) ---@cast player -nil
	
	local selected = player.selected
	if selected == nil then return end
	
	local count = init_vault(selected):get_ore_depletion()
	
	local diff = _prev_ore and count - _prev_ore or nil
	_prev_ore = count
	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..selected.position.x..", "..selected.position.y..")")
end)

commands.add_command("fulg-attack", "", function(command)
	init()

	-- vault for testing
	local sel = game.get_player(command.player_index).selected
	if sel and sel.valid and sel.name == VAULT_NAME then
		init_vault(sel):spawn_wave()
	end
end)

script.on_event(defines.events.on_tick, function(event)
	--local prof = helpers.create_profiler()
	
	if not _was_reset then reset() _was_reset = true end -- for dev
	init()
	
	stagger_tick(storage.poll_vaults, storage.vaults, ORE_POLL_PERIOD, function(vault)
		if vault.entity.valid then
			vault:update_waves()
		end
	end)
	
	dmg.on_tick(event)
	
	--for id,v in pairs(storage.vaults) do
	for id,v in pairs(storage.active_vaults) do
		if v.entity.valid then -- and v:wave_active()
			v:update_emerging()
			
			movement.update(v)
		end
	end
	
	--prof.stop()
	--game.print(prof)
end)

local deathrattles = {} ---@type function(EventData.on_object_destroyed)[]
deathrattles[defines.target_type.entity] = function(event) ---@param event EventData.on_object_destroyed
	if storage == nil then return end
	if storage.vaults ~= nil then
		local vault = storage.vaults[event.registration_number]
		if vault ~= nil then
			vault:destroy()
		end
	end
end
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if handler then handler(event) end
end)

for _, event in pairs({
	defines.events.on_built_entity, -- also triggered by editor
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
}) do
	local filter = util.table.deepcopy(dmg.event_filter)
	table.insert(filter, {filter="type", type="simple-entity"})
	table.insert(filter, {filter="name", name=VAULT_NAME, mode="and"})
	
	script.on_event(event, function(event)
		local entity = event.entity or event.destination --[[@as LuaEntity]]
		if entity.type == "simple-entity" then
			-- can't actually be built in game, but still do generic built events
			if entity.name == VAULT_NAME then
				init_vault(entity)
			end
		else
			dmg.on_entity_built(entity)
		end
	end, filter)
end
script.on_event(defines.events.on_entity_died, function(event)
	dmg.on_entity_built(event.entity)
end, dmg.event_filter)

script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.on_dmg_filter)

-- Show linked entity on hover
-- TODO: can get stuck sometimes, seemingly on_selected_entity_changed does not handle going into map view, an there's no event?
-- -> poll
---@param player LuaPlayer
local function update_viz(player)
	init()
	
	local draws = storage.viz[player.index] or {}
	if draws then
		for _,d in pairs(draws) do
			d.destroy()
		end
		draws = {}
	end
	
	local selected = player.selected
	if selected and selected.name == VAULT_NAME then
		local surf = selected.surface
		local r = VAULT_DEFENSE_RADIUS()
		draws[1] = rendering.draw_circle{target=selected, radius=r, surface=surf, filled=true, color=TINT_FILL, render_mode="chart"}
		draws[2] = rendering.draw_circle{target=selected, radius=r, surface=surf, width=80, color=TINT, render_mode="chart"}
		
		draws[3] = rendering.draw_circle{target=selected, radius=r, surface=surf, filled=true, color=TINT_FILL}
		draws[4] = rendering.draw_circle{target=selected, radius=r, surface=surf, width=5, color=TINT}
		
		--local p = selected.position
		--local sr = r*0.71
		--rendering.draw_rectangle{left_top={p.x-sr, p.y-sr}, right_bottom={p.x+sr, p.y+sr}, surface=surf, filled=true, color=TINT_FILL}
		storage.viz[player.index] = draws
	else
		storage.viz[player.index] = nil
	end
end
local function dbg_vaults()
	for _,p in pairs(game.players) do
		if p.selected and p.selected.valid and p.selected.name == VAULT_NAME then
			local v = init_vault(p.selected)
			if v:wave_active() then
				p.print("Wave active: "..table_size(v.wave_bots).." bots "
				        ..table_size(v.wave_emerging_projectiles).." proj "..table_size(v.wave_emerging).." queued")
			else
				local time = (game.tick - (v.wave_start_tick or 0)) / 3600
				local ore = v:get_ore_depletion() - (v.prev_wave_start_ore_amount or 0)
				local speed = ore / time
				p.print("Last wave: "..time.." min ago  ore: "..ore.." ("..speed.."/m)", {volume_modifier=0})
			end
		end
	end
end

function update_all_viz()
	for _,p in pairs(game.players) do
		update_viz(p)
	end
end
script.on_event(defines.events.on_selected_entity_changed, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	local prev = event.last_entity
	if (selected and selected.name == VAULT_NAME) or (prev and prev.name == VAULT_NAME) then
		update_viz(player)
	end
end)
script.on_nth_tick(30, function(event)
	update_all_viz()
	dbg_vaults()
end)

script.on_init(init)

---@class obj_id : integer -- register_on_object_destroyed-based id
---@class unit_number : integer
---@class player_index : integer

---@class ModStorage
---@field vaults table<obj_id, Vault>
---@field friend_end_tick integer?
---@field poll_vaults table
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---@field active_vaults table<obj_id, Vault>
---@field viz table<player_index, LuaRenderObject[]>
--@field marked_military LuaEntity[]

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

---@class Vault
---@field entity LuaEntity
---@field id obj_id
---@field deco_near_wall LuaEntity?
---@field prev_wave_start_ore_amount integer?
---@field targets LuaEntity[] -- NOTE: entities can end up in two vaults target list!
---@field waypoints LuaEntity[]
---@field wave_rng number?
---@field wave_rng2 number?
---@field wave_start_tick integer?
---@field wave_end_tick integer?
-- TODO: track sorted into buckets by tick or sort list?
---@field wave_emerging table<integer, Emerging> -- current attack wave emerging bots (queues projectiles, not active projectiles)
--@field wave_emerging_projectiles table<obj_id, LuaEntity> -- current attack wave active bots
---@field wave_emerging_projectiles table<integer, LuaEntity> -- current attack wave active bots
---@field wave_bots table<integer, LuaEntity> -- current attack wave active bots
--@field next_bot_id integer?

---@class Emerging
--@field id integer
---@field tick integer
---@field name string -- emerging projectile name
---@field final_pos MapPosition
