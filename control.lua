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
		force.custom_color = {1,0,1,1}
	end
	
	local s = storage
	if s == nil then s = {} storage = s end ---@diagnostic disable-line
	if s.vaults == nil then s.vaults = {} end
	if s.poll_repaired == nil then s.poll_repaired = {} end
	if s.viz == nil then s.viz = {} end
	--if s.marked_military == nil then s.marked_military = {} end
	
	-- How to do this in practice?
	for _,v in pairs(s.vaults) do
		if v.shaft_near_wall == nil then
			v.entity.destructible = false
			
			v.shaft_near_wall = v.entity.surface.create_entity{
				name = "fulgoran-ruin-vault-near-wall", position = v.entity.position,
			}
			v.shaft_near_wall.destructible = false
		end
	end
end
local function reset()
	local s = storage
	if s and s.poll_repaired then
		for _,e in pairs(s.poll_repaired) do
			if e and e.valid then
				dmg.fix_building(e.unit_number, e)
			end
		end
	end
	rendering.clear(mod_name)
	storage = {}
end

---@param vault Vault
function check_ore_depletion(vault)
	-- TODO: profile, and if at all significant, split it into smaller chunks to rotate through
	local circ_r = VAULT_DEFENSE_RADIUS()
	local square_r = circ_r * 0.71 -- can only check rectangle, don't check outside visual circle, so radius*cos(pi/4)
	local count = 0
	for _,ore_tile in pairs(vault.entity.surface.find_entities_filtered{
		position=vault.entity.position, radius=square_r, type="resource", name="scrap"}) do
		count = count + ore_tile.amount
	end
	return count
end

local _prev_ore = nil
commands.add_command("fulg-ore", "", function(command)
	init()
	local player = game.get_player(command.player_index) ---@cast player -nil
	
	local selected = player.selected
	if selected == nil then return end
	
	local count = check_ore_depletion(selected)
	
	local diff = _prev_ore and count - _prev_ore or nil
	_prev_ore = count
	game.print("ore: ".. count .."  (".. (diff or "nil") ..") at ("..selected.position.x..", "..selected.position.y..")")
end)

commands.add_command("fulg-attack", "", function(command)
	init()

	-- vault for testing
	local TEST_POS = {x=-42.5, y=31.9375}
	
	local fulg = game.surfaces["fulgora"]
	local entity = fulg.find_entity("fulgoran-ruin-vault", TEST_POS)
	if entity and entity.valid then
		init_vault(entity):start_wave()
	end
end)

local _reset = false

script.on_event(defines.events.on_tick, function(event)
	if not _reset then reset() _reset = true end -- for dev
	init()
	
	dmg.on_tick(event)
	
	for id,v in pairs(storage.vaults) do
		if v.entity.valid then -- and v:wave_active()
			v:spawn_all_emerging()
			
			movement.update(v)
		end
	end
	--if _bots then
	--	_bots = movement.update(nil, _bots)
	--end
end)

-- Not really needed
--local deathrattles = {} ---@type function(EventData.on_object_destroyed)[]
--deathrattles[defines.target_type.entity] = function(event) ---@param event EventData.on_object_destroyed
--	storage.marked_military[event.useful_id] = nil
--	storage.poll_repaired[event.useful_id] = nil
--end
--script.on_event(defines.events.on_object_destroyed, function(event)
--	local handler = deathrattles[event.type]
--	if handler then handler(event) end
--end)

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
	if selected and selected.name == "fulgoran-ruin-vault" then
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
function update_all_viz()
	for _,p in pairs(game.players) do
		update_viz(p)
	end
end
script.on_event(defines.events.on_selected_entity_changed, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	local prev = event.last_entity
	if (selected and selected.name == "fulgoran-ruin-vault") or (prev and prev.name == "fulgoran-ruin-vault") then
		update_viz(player)
	end
end)
script.on_nth_tick(30, function(event)
	update_all_viz()
end)

script.on_init(init)

---@class unit_number : integer
---@class player_index : integer

---@class ModStorage
---@field vaults table<unit_number, Vault>
---@field friend_end_tick integer?
---@field poll_repaired Damaged[]
---@field poll_prev unit_number?
---@field viz table<player_index, LuaRenderObject[]>
--@field marked_military LuaEntity[]

---@class Vault
---@field entity LuaEntity
---@field deco_near_wall LuaEntity?
---@field prev_wave_ore_amount integer?
---@field targets LuaEntity[] -- NOTE: entities can end up in two vaults target list!
---@field waypoints LuaEntity[]
---@field wave_bots LuaEntity[] -- current attack wave active bots
-- TODO: track sorted into buckets by tick or somehow sort?
---@field wave_emerging Emerging[] -- current attack wave emerging bots (queues projectiles, not active projectiles)

---@class Damaged
---@field entity LuaEntity
---@field icon LuaRenderObject

---@class Emerging
---@field name string -- emerging projectile name
---@field final_pos MapPosition
---@field tick integer

