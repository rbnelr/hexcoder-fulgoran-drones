local g = require("common")
local util = require("util")
local dmg = require("disable_on_damage")
local Vault = require("vault")
require("spawning")
local movement = require("bot_movement")

local TINT = {0.80, 0.05, 0.05}
local TINT_FILL = {TINT[1]*0.1,TINT[2]*0.1,TINT[3]*0.1,0.1}

---@param surface LuaSurface
---@param area BoundingBox
local function init_chunk(surface, area)
	local vaults = surface.find_entities_filtered{name=g.VAULT_NAME, area=area}
	if next(vaults) then
		for _,e in pairs(surface.find_entities_filtered{name=g.VAULT_NAME, area=area}) do
			init_vault(e)
		end
	elseif g.TRY_SPAWN_MISSING_VAULTS then
		Vault.try_place_missing_vault_ruin(surface, area)
	end
end

function init()
	-- create enemy drone force
	if game.forces[g.DRONE_FORCE] == nil then
		local force = game.create_force(g.DRONE_FORCE)
		--force.custom_color = {255,215,0}
		force.custom_color = {230,50,255}
	end
	
	local s = storage
	local init = s == nil
	if s == nil then
		s = {} ---@diagnostic disable-line
		storage = s
	end
	if s.vaults == nil then s.vaults = {} end
	if s.poll_vaults == nil then s.poll_vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.active_vaults == nil then s.active_vaults = {} end
	if s.viz == nil then s.viz = {} end
	--if s.marked_military == nil then s.marked_military = {} end
	
	if init then
		local surface = game.get_surface("fulgora")
		if surface then
			for _,e in pairs(surface.find_entities_filtered{name=g.VAULT_NAME}) do
				init_vault(e)
			end
			
			if g.TRY_SPAWN_MISSING_VAULTS then
				for cpos in surface.get_chunks() do
					if surface.is_chunk_generated(cpos) then
						Vault.try_place_missing_vault_ruin(surface, {{cpos.x*32,cpos.y*32}, {cpos.x*32+32,cpos.y*32+32}})
					end
				end
			end
		end
	end
end
local function reset()
	local surface = game.get_surface("fulgora")
	if surface then
		for _,e in pairs(surface.find_entities_filtered{name={g.VAULT_NEAR_WALL_NAME,g.WAYPOINT}}) do
			e.destroy()
		end
	end
	
	rendering.clear(g.MOD_NAME)
	
	game.merge_forces(game.forces[g.DRONE_FORCE], game.forces["player"]) -- can't delete forces directly (?)
	
	local s = storage
	if s and s.poll_repaired then
		for _,e in pairs(s.poll_repaired) do
			if e.entity and e.entity.valid then
				dmg.fix_building(e.entity.unit_number, e.entity)
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
	
	local count = init_vault(selected):get_ore_remaining()
	
	local diff = _prev_ore and count - _prev_ore or nil
	_prev_ore = count
	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..selected.position.x..", "..selected.position.y..")")
end)

commands.add_command("fulg-attack", "", function(command)
	init()
	
	local size = command.parameter and tonumber(command.parameter) or 1
	
	-- vault for testing
	local sel = game.get_player(command.player_index).selected
	if sel and sel.valid and sel.name == g.VAULT_NAME then
		init_vault(sel):spawn_wave(size)
	end
end)

local _was_reset
script.on_event(defines.events.on_tick, function(event)
	--local prof = helpers.create_profiler()
	
	--if g.DEBUG then
	--	if not _was_reset then reset() _was_reset = true end -- for dev
	--	init()
	--end
	
	-- TODO: could skip expensive checks by checking something like (last-get_resource_counts())>1000 first for whole planet?
	-- how? pause until condition met, then scan every chunk once, then pause again?
	
	g.stagger_tick(storage.poll_vaults, storage.vaults, g.ORE_POLL_PERIOD, function(vault)
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

local deathrattles = { ---@type function(EventData.on_object_destroyed)[]
	[defines.target_type.entity] = function(event)
		if storage.vaults ~= nil then
			local vault = storage.vaults[event.registration_number]
			if vault ~= nil then
				vault:destroy()
			end
		end
	end,
	[defines.target_type.player] = function(event)
		for _,v in pairs(storage.viz[event.useful_id]) do
			v.destroy()
		end
		storage.viz[event.useful_id] = nil
	end,
}
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if storage ~= nil and handler ~= nil then
		handler(event)
	end
end)

local function append(tbl1, tbl2)
	local t = util.table.deepcopy(tbl1)
	for k,v in pairs(tbl2) do
		table.insert(t, v)
	end
	return t
end
local built_filter = append(dmg.event_filter, {
	{filter="type", type="simple-entity"},
	{filter="name", name=g.VAULT_NAME, mode="and"}
})
local died_filter = append(dmg.event_filter, {
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[1], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[2], mode="and"},
	{filter="type", type="combat-robot"},
	{filter="name", name=g.DRONES[3], mode="and"}
})
	
for _, name in pairs({
	defines.events.on_built_entity, -- also triggered by editor
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
}) do
	script.on_event(name, function(event)
		local entity = event.entity or event.destination --[[@as LuaEntity]]
		if entity.type == "simple-entity" then
			-- can't actually be built in game, but still do generic built events
			if entity.name == g.VAULT_NAME then
				init_vault(entity)
			end
		else
			dmg.on_entity_event(entity)
		end
	end, built_filter)
end
script.on_event(defines.events.on_entity_died, function(event)
	if event.entity.type == "combat-robot" then
		Vault.on_drone_died(event)
	else
		dmg.on_entity_event(event.entity)
	end
end, died_filter)

script.on_event(defines.events.on_chunk_generated, function(event)
	if event.surface.name == "fulgora" then
		init_chunk(event.surface, event.area)
	end
end)

script.on_event(defines.events.on_entity_damaged, dmg.on_entity_damaged, dmg.on_dmg_filter)

-- Show linked entity on hover
---@param player LuaPlayer
local function update_viz(player)
	init()
	
	local draws = storage.viz[player.index]
	if draws then -- remove previous rendering
		for _,d in pairs(draws) do
			d.destroy()
		end
		draws = nil
	end
	
	local selected = player.selected
	if selected and selected.name == g.VAULT_NAME then
		draws = {}
		
		local surf = selected.surface
		local r = g.VAULT_DEFENSE_RADIUS()
		draws[1] = rendering.draw_circle{target=selected, radius=r, surface=surf, filled=true, color=TINT_FILL, render_mode="chart"}
		draws[2] = rendering.draw_circle{target=selected, radius=r, surface=surf, width=80, color=TINT, render_mode="chart"}
		
		draws[3] = rendering.draw_circle{target=selected, radius=r, surface=surf, filled=true, color=TINT_FILL}
		draws[4] = rendering.draw_circle{target=selected, radius=r, surface=surf, width=5, color=TINT}
		
		--local p = selected.position
		--local sr = r*0.71
		--rendering.draw_rectangle{left_top={p.x-sr, p.y-sr}, right_bottom={p.x+sr, p.y+sr}, surface=surf, filled=true, color=TINT_FILL}
	end
	
	storage.viz[player.index] = draws
end
local function dbg_vaults()
	for _,player in pairs(game.players) do
		local selected = player.selected
		if selected and selected.valid and selected.name == g.VAULT_NAME then
			init_vault(selected):dbg_print(player)
		end
		--if p.selected and p.selected.valid and p.selected.position ~= nil then
		--	local res = p.selected.surface.calculate_tile_properties({"fulgora_spots", "fulgora_vaults_and_starting_vault"}, {p.selected.position})
		--	p.print("props: "..serpent.line(res))
		--end
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
	if (selected and selected.name == g.VAULT_NAME) or (prev and prev.name == g.VAULT_NAME) then
		if g.DEBUG and selected and selected.name == g.VAULT_NAME then
			init_vault(player.selected):dbg_print(player)
		end
		update_viz(player)
	end
end)
-- on_selected_entity_changed viz can get stuck sometimes
-- seemingly on_selected_entity_changed does not handle going into map view, an there's no event?
-- so poll as well
script.on_nth_tick(20, function(event)
	update_all_viz()
end)
if g.DEBUG then
	script.on_nth_tick(120, function(event)
		dbg_vaults()
	end)
end

script.on_init(init)

script.register_metatable("Vault", Vault)

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
---@field viz table<player_index, LuaRenderObject[]?>
--@field marked_military LuaEntity[]

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

---@class Vault
---@field entity LuaEntity
---@field id obj_id
---@field near_wall LuaEntity?
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
