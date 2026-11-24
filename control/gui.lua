local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local depth_scaling = require("control.depth_scaling")
local spawning = require("control.spawning")
local gui_util = require("lib.gui_util")
local GUI = gui_util.GUI

local gui = {}

-- gui captions, locale section [hexcoder-fulgoran-drones-gui]
---@return LocalisedString
local function L(key, ...)
	return {const.MOD_NAME.."-gui."..key, ...}
end

--#region Radius visualisation
local VIS_RADIUS_TINT = {0.80, 0.05, 0.05}
local VIS_RADIUS_TINT_FILL = {VIS_RADIUS_TINT[1]*0.1,VIS_RADIUS_TINT[2]*0.1,VIS_RADIUS_TINT[3]*0.1,0.1}

-- Show vault radius on hover
---@param player LuaPlayer
function gui.update_viz(player)
	init()
	
	script.register_on_object_destroyed(player)
	
	---@type LuaRenderObject[]?
	local draws = storage.render_objs[player.index]
	if draws then -- remove previous rendering
		for _,d in pairs(draws) do
			d.destroy()
		end
		draws = nil
	end
	
	local selected = player.selected
	if selected and selected.name == const.VAULT_NAME then
		draws = {}
		
		local surf = selected.surface
		local r = const.VAULT_DEFENSE_RADIUS
		local pl = {player}
		draws[1] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=VIS_RADIUS_TINT_FILL, render_mode="chart"}
		draws[2] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=80, color=VIS_RADIUS_TINT, render_mode="chart"}
		
		draws[3] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, filled=true, color=VIS_RADIUS_TINT_FILL}
		draws[4] = rendering.draw_circle{target=selected, radius=r, surface=surf, players=pl, width=5, color=VIS_RADIUS_TINT}
		
		--local p = selected.position
		--local sr = r*0.71
		--rendering.draw_rectangle{left_top={p.x-sr, p.y-sr}, right_bottom={p.x+sr, p.y+sr}, surface=surf, filled=true, color=TINT_FILL}
	end
	
	storage.render_objs[player.index] = draws
end

function gui.update_all_viz()
	for _,player in pairs(game.players) do
		gui.update_viz(player)
		gui.update_info_gui(player)
		gui.refresh_pinned(player)
	end
end
--#endregion

--#region Vault GUI

local WAVE_TABLE_BOTS = {"fulgoran-defender", "fulgoran-distractor", "fulgoran-destroyer"}
local WAVE_ROWS = {"next", "active", "last"} -- future to past
-- header icons as sprites (rich text icons all have the same size, entity icons have more empty space than quality icons)
local HEADER_HEIGHT = 24 -- all header rows, so the header lines of the three tables line up
local HEADER_BOT_ICON = 22
local HEADER_QUALITY_ICON = 18
local MIN_COLUMN_WIDTH = 26 -- bot and quality columns, empty columns would shrink to the icon width, was 28
local COLUMN_SPACING = 10 -- was 12
local SIZE_COLUMN_WIDTH = 48 -- fits "~1000%" without the table resizing
-- dark header strip like the logistic request sections (subheader_frame is 36 by default)
local SUBHEADER_PAD = 4
local SUBHEADER_HEIGHT = HEADER_HEIGHT + 2*SUBHEADER_PAD
local SUBHEADER_VALUE_OFFSET = -1 -- top_margin of values next to subheader captions (heading-2 font is 15, values 14), so the text lines up
local PART_SPACING = 8 -- between the frames
local PART_FRAME_STYLE = "inside_shallow_frame" -- lighter than the dark subheader on top, like the logistic request sections, was inside_deep_frame

-- hover preview in gui.left, the cursor passes through it
-- pinned: left click on a vault toggles it, also in gui.left (stays at the side, above a hover preview of another vault)
-- both are built once with all elements (all qualities, mark pools), updates only set captions, styles and visible
-- state in the window tags (no storage): vault id, layout version
local WINDOW_NAME = "hexcoder_fulgoran_drones_vault"
local WINDOW_VERSION = 2 -- in the tags, windows of another layout (saved) are recreated
local PINNED_NAME = WINDOW_NAME.."_pinned"
local PINNED_CLOSE_NAME = PINNED_NAME.."_close"

-- threats: drones currently out as odometer digits (each in its own slot, leading zeros dimmed, all of them at 0)
-- updated every GUI_FAST_UPDATE_PERIOD ticks (update_info_gui_fast), the rest of the window every GUI_UPDATE_PERIOD (both on_nth_tick in events.lua)
local ALIVE_WIDTH = 96
local ALIVE_DIGITS = 3 -- capped at 999
-- custom font if defined in data (from="scenario-message-dialog" is IBM Plex Mono, like a terminal), else the largest vanilla one
local ALIVE_FONT = const.MOD_NAME.."-counter"
local ALIVE_FONT_FALLBACK = "default-large-bold"
local ALIVE_DIGIT_SIZE = {26, 40} -- slot w, h with the custom font (prototypes/misc.lua, size 32), was 24
local ALIVE_DIGIT_SIZE_FALLBACK = {18, 28}
local ALIVE_SLOT_STYLE = "deep_frame_in_shallow_frame" -- dark digit slots on the lighter part frame, was inside_shallow_frame (looked like buttons)
local ALIVE_DIGIT_SPACING = 2
local ALIVE_COLOR = {1, 0.35, 0.2}
local ALIVE_COLOR_DIM = {0.3, 0.3, 0.3}

-- gauge marks are positioned in px, so the width is fixed, about the width of wave table + alive frame with all 5 qualities
-- gauge content is centered in its frame if the frame ends up wider
local GAUGE_WIDTH = 584
local GAUGE_PADDING = 4 -- left and right, outside the overhang
local GAUGE_BADGE = 24 -- sprite-button with quality badge
local GAUGE_OVERHANG = GAUGE_BADGE / 2 -- marks may stick out past the bar ends, so badges at 0 and 100% are centered on them
local GAUGE_SCRAP_GAP = 9 -- scrap badges to the bar, clear of the cursor arrow (GAUGE_CURSOR_H + GAUGE_CURSOR_GAP), was 4
local GAUGE_BOT_GAP = 0 -- drone badges to the tick row
local GAUGE_BAR_HEIGHT = 12 -- progressbar bar_width, vanilla 8
local GAUGE_BAR_COLOR = {0.75, 0.45, 0.2} -- scrap brown/orange, vanilla green
local GAUGE_BOT = "defender" -- stands for all drones on the badges, the most common type, player version icon (no skull)
-- ruler: tick every 1M drainable, taller every 10M (fixed, no labels, density shows the total)
local GAUGE_TICK_HEIGHT = 4
local GAUGE_TICK_HEIGHT_10M = 8
local GAUGE_MAX_TICKS = 100 -- pool, more millions are not shown
-- depth cursor: arrows above and below the bar with the tier next to them
-- hint arrows are 16x12 at scale 0.5, TODO: own graphic?
local GAUGE_CURSOR_W = 10 -- was 12x9
local GAUGE_CURSOR_H = 7
local GAUGE_CURSOR_GAP = 1 -- to the bar
local GAUGE_TIER_W = 20 -- tier label, estimated "4.3" in default-small
local GAUGE_TIER_H = 14
-- all rows of a marks flow as tall as its tallest mark, so the flow ends up that tall (it ends at the last row)
local SCRAP_ROW_H = math.max(GAUGE_BADGE + GAUGE_SCRAP_GAP, GAUGE_CURSOR_H + GAUGE_CURSOR_GAP, GAUGE_TIER_H + GAUGE_CURSOR_GAP)
local TICK_ROW_H = math.max(GAUGE_TICK_HEIGHT_10M, GAUGE_CURSOR_H + GAUGE_CURSOR_GAP, GAUGE_TIER_H + GAUGE_CURSOR_GAP)
local BOT_ROW_H = GAUGE_BADGE + GAUGE_BOT_GAP

local QUALITIES = const.QUALITY_IDS -- filled by control.common at load

---@param sprite string
---@param size integer -- px, centered in HEADER_HEIGHT
---@return GuiDef
local function header_icon(sprite, size)
	local pad = (HEADER_HEIGHT - size) / 2
	return GUI{type="sprite", sprite=sprite, style={stretch_image_to_widget_size=true, width=size, height=size,
		top_margin=math.floor(pad), bottom_margin=math.ceil(pad),
		left_margin=math.max(MIN_COLUMN_WIDTH - size, 0)}} -- columns are right aligned
end

-- dark strip on top of a deep frame
---@param children GuiDef[]?
---@return GuiDef
local function subheader(children)
	return GUI{type="frame", style={base="subheader_frame", height=SUBHEADER_HEIGHT, horizontally_stretchable=true}}:add(children or {})
end

-- gauge mark, w x h, gap px to the bar side of its row (bottom: row below the bar), left_margin and visible set in update
---@param def GuiDef
---@return GuiDef
local function mark(def, w, h, row_h, gap, bottom)
	local s = def.style or {}
	s.width, s.height = w, h
	s.top_margin = bottom and row_h - h - gap or gap
	def.style = s
	return def
end

-- gui has no absolute positioning (only screen elements have a location) and negative left_margin doesn't overlap
-- so every mark gets its own row with left_margin from the gauge start (rounded once, no drift at ui scale != 1)
-- and the rows are stacked onto the same line with negative top_margin, which works, later rows on top
-- only the marks are hidden, a hidden row would break the stacking
---@param marks GuiDef[]
---@return GuiDef
local function marks_flow(row_h, marks)
	local rows = {}
	for i,m in ipairs(marks) do
		rows[i] = GUI{type="flow", style={height=row_h, top_margin=i > 1 and -row_h or 0}}:add{m}
	end
	return GUI{type="flow", direction="vertical", style={vertical_spacing=0, width=GAUGE_WIDTH + 2*GAUGE_OVERHANG}}:add(rows)
end

local window_defs ---@type {hover: GuiDef, pinned: GuiDef}?
-- built on first use (prototypes.font)
local function get_window_defs()
	if window_defs then return window_defs end

	-- wave table: fixed rows next / active / last (future to past), -- if none
	-- tables side by side for vertical lines between the groups, rows line up as long as all cells are single line labels
	-- one single column table per quality, so unused qualities can be hidden as a whole
	-- header row sits on a subheader strip drawn before it (negative top_margin overlay, like vanilla negative_subheader_frame)
	-- cells named <row>_time/_size/_threat/_bot<i>/_q<i>, <row>_label
	local function tbl(cols, right_from, name)
		local align = {}
		for i=right_from,cols do align[i] = "right" end
		return GUI{type="table", name=name, column_count=cols, style={horizontal_spacing=COLUMN_SPACING, column_alignments=align}}
	end
	local header_style = {height=HEADER_HEIGHT, vertical_align="center", minimal_width=SIZE_COLUMN_WIDTH, horizontal_align="right"}
	local wave_cells = {
		GUI{type="label", caption=L("waves"), style={base="subheader_caption_label", left_padding=0, height=HEADER_HEIGHT, vertical_align="center"}},
		GUI{type="label", caption="", style={left_margin=4}}, -- small gap after the label column
		GUI{type="label", caption=L("size"), style=header_style},
		GUI{type="label", caption=L("threat"), style=header_style},
	}
	local bot_cells = {}
	for _,n in ipairs(WAVE_TABLE_BOTS) do
		table.insert(bot_cells, header_icon("entity/"..n:gsub("^fulgoran%-", ""), HEADER_BOT_ICON)) -- player version icon (no skull), easier to read
	end
	local qual_tables = {}
	for i,qn in ipairs(QUALITIES) do
		qual_tables[i] = tbl(1, 1, "q"..i):add{header_icon("quality/"..qn, HEADER_QUALITY_ICON)}
	end
	for _,row in ipairs(WAVE_ROWS) do
		local style = row == "next" and "grey_label" or nil -- active label style is set in update
		table.insert(wave_cells, GUI{type="label", name=row.."_label", caption=L(row), style=style})
		table.insert(wave_cells, GUI{type="label", name=row.."_time", style={base=style, left_margin=4}})
		table.insert(wave_cells, GUI{type="label", name=row.."_size", style=style})
		table.insert(wave_cells, GUI{type="label", name=row.."_threat", style=style})
		for i=1,#WAVE_TABLE_BOTS do
			table.insert(bot_cells, GUI{type="label", name=row.."_bot"..i})
		end
		for i=1,#QUALITIES do
			qual_tables[i]:add{GUI{type="label", name=row.."_q"..i}}
		end
	end
	local function vline() -- below the header strip
		return GUI{type="line", direction="vertical", style={vertically_stretchable=true, top_margin=SUBHEADER_HEIGHT - SUBHEADER_PAD}}
	end

	local custom_font = prototypes.font[ALIVE_FONT] ~= nil
	local digit_size = custom_font and ALIVE_DIGIT_SIZE or ALIVE_DIGIT_SIZE_FALLBACK
	local digits = {}
	for i=1,ALIVE_DIGITS do
		digits[i] = GUI{type="frame", style={base=ALIVE_SLOT_STYLE, padding=0, width=digit_size[1], height=digit_size[2]}}:add{
			GUI{type="label", name="alive_d"..i, caption="0", style={font=custom_font and ALIVE_FONT or ALIVE_FONT_FALLBACK,
				width=digit_size[1], height=digit_size[2], horizontal_align="center", vertical_align="center"}},
		}
	end

	-- depth gauge rows: scrap quality badges + top cursor, bar, million ticks + bottom cursor, drone quality badges
	-- tier numbers next to the cursors, were "Scrap 1.0" / "Drones 2.8" labels left of the gauge
	-- names <scrap|bot>_q<i>, <scrap|bot>_cursor, <scrap|bot>_tier, tick<n>
	local scrap_marks, tick_marks, bot_marks = {}, {}, {}
	for i,qn in ipairs(QUALITIES) do
		local function badge(side, sprite) return GUI{type="sprite-button", name=side.."_q"..i, sprite=sprite, quality=qn, style={base="transparent_slot", padding=0}} end
		table.insert(scrap_marks, mark(badge("scrap", "item/scrap"), GAUGE_BADGE, GAUGE_BADGE, SCRAP_ROW_H, GAUGE_SCRAP_GAP, true))
		table.insert(bot_marks, mark(badge("bot", "entity/"..GAUGE_BOT), GAUGE_BADGE, GAUGE_BADGE, BOT_ROW_H, GAUGE_BOT_GAP))
	end
	for n=1,GAUGE_MAX_TICKS do
		local h = n % 10 == 0 and GAUGE_TICK_HEIGHT_10M or GAUGE_TICK_HEIGHT
		table.insert(tick_marks, mark(GUI{type="sprite", name="tick"..n, sprite="utility/white_square", style={stretch_image_to_widget_size=true}}, 1, h, TICK_ROW_H, 0))
	end
	-- cursor arrow and tier number, last so they are on top
	local function cursor(marks, side, sprite, row_h, bottom)
		table.insert(marks, mark(GUI{type="sprite", name=side.."_cursor", sprite=sprite, style={stretch_image_to_widget_size=true}},
			GAUGE_CURSOR_W, GAUGE_CURSOR_H, row_h, GAUGE_CURSOR_GAP, bottom))
		-- vertical_align center: same distance to the bar above and below
		table.insert(marks, mark(GUI{type="label", name=side.."_tier", style={font="default-small", vertical_align="center"}},
			GAUGE_TIER_W, GAUGE_TIER_H, row_h, GAUGE_CURSOR_GAP, bottom))
	end
	cursor(scrap_marks, "scrap", "utility/hint_arrow_down", SCRAP_ROW_H, true)
	cursor(tick_marks, "bot", "utility/hint_arrow_up", TICK_ROW_H, false)

	-- all frames horizontally stretchable, so both parts have the window width
	-- named path top > threats > content > digits, the fast update finds the digits through it
	local body = {
		GUI{type="flow", name="top", direction="horizontal", style={horizontal_spacing=PART_SPACING, horizontally_stretchable=true}}:add{
			GUI{type="frame", direction="vertical", style={base=PART_FRAME_STYLE, horizontally_stretchable=true}}:add{
				subheader(),
				GUI{type="flow", direction="horizontal", style={horizontal_spacing=COLUMN_SPACING, top_margin=-SUBHEADER_HEIGHT + SUBHEADER_PAD,
					left_padding=8, right_padding=8, bottom_padding=4}}:add{
					tbl(4, 3):add(wave_cells), -- label, time, size, threat
					vline(),
					tbl(#WAVE_TABLE_BOTS, 1):add(bot_cells),
					vline(),
					GUI{type="flow", direction="horizontal", style={horizontal_spacing=COLUMN_SPACING}}:add(qual_tables),
				},
			},
			-- drones currently out, all waves mixed
			GUI{type="frame", name="threats", direction="vertical", style={base=PART_FRAME_STYLE, width=ALIVE_WIDTH, vertically_stretchable=true}}:add{
				subheader{GUI{type="label", caption=L("threats"), style="subheader_caption_label"}},
				GUI{type="flow", name="content", direction="vertical", style={horizontally_stretchable=true, vertically_stretchable=true,
					horizontal_align="center", vertical_align="center", vertical_spacing=4}}:add{
					GUI{type="flow", name="digits", direction="horizontal", style={horizontal_spacing=ALIVE_DIGIT_SPACING}}:add(digits),
				},
			},
		},
		GUI{type="frame", direction="vertical", style={base=PART_FRAME_STYLE, horizontally_stretchable=true}}:add{
			-- mining left, depth in the middle, drained right (stretching spacers)
			subheader{
				GUI{type="label", caption=L("mining"), style="subheader_caption_label"},
				GUI{type="label", name="mining_rate", style={base="bold_label", top_margin=SUBHEADER_VALUE_OFFSET}},
				GUI{type="empty-widget", style={horizontally_stretchable=true}},
				GUI{type="label", caption=L("depth"), style={base="subheader_caption_label", left_padding=0}},
				GUI{type="label", name="mining_depth", style={base="bold_label", top_margin=SUBHEADER_VALUE_OFFSET}},
				GUI{type="empty-widget", style={horizontally_stretchable=true}},
				GUI{type="label", name="mining_drained", style={font="default", right_padding=4}},
			},
			GUI{type="flow", direction="vertical", style={vertical_spacing=0, horizontally_stretchable=true, horizontal_align="center",
				left_padding=GAUGE_PADDING, right_padding=GAUGE_PADDING, top_padding=6, bottom_padding=4}}:add{
				marks_flow(SCRAP_ROW_H, scrap_marks),
				GUI{type="progressbar", name="depth_bar", value=0, style={width=GAUGE_WIDTH, bar_width=GAUGE_BAR_HEIGHT, color=GAUGE_BAR_COLOR,
					left_margin=GAUGE_OVERHANG, right_margin=GAUGE_OVERHANG}},
				marks_flow(TICK_ROW_H, tick_marks),
				marks_flow(BOT_ROW_H, bot_marks),
			},
		},
	}

	local function title() return GUI{type="label", caption=L("title"), style={base="frame_title", top_margin=-3, bottom_margin=3}} end
	window_defs = {
		hover = GUI{type="frame", name=WINDOW_NAME, direction="vertical"}:add{
			GUI{type="flow", style={horizontal_spacing=8}}:add{ title() },
		}:add(body),
		pinned = GUI{type="frame", name=PINNED_NAME, direction="vertical"}:add{
			GUI{type="flow", style={horizontal_spacing=8}}:add{
				title(),
				GUI{type="empty-widget", style={horizontally_stretchable=true}},
				GUI{type="sprite-button", name=PINNED_CLOSE_NAME, style="close_button", sprite="utility/close"},
			},
		}:add(body),
	}
	return window_defs
end

---@param elem LuaGuiElement
---@param key string
local function set_recursive(elem, key, value)
	elem[key] = value
	for _,child in pairs(elem.children) do
		set_recursive(child, key, value)
	end
end

-- drones of this vault currently out (all waves mixed): alive or flying out of the shaft (queued ones not counted)
---@param vault Vault
---@return integer
local function count_alive(vault)
	local count = 0
	for _,bot in pairs(vault.active_bots) do
		if bot.valid then count = count + 1 end
	end
	for _,proj in pairs(vault.emerging_projectiles) do
		if proj.valid then count = count + 1 end
	end
	return count
	--return count + table_size(vault.emerging_queued) -- queued spawns too
end

-- threat counter, every GUI_FAST_UPDATE_PERIOD ticks
---@param vault Vault
---@param window LuaGuiElement
local function update_threats(vault, window)
	local count = count_alive(vault)
	local str = string.format("%0"..ALIVE_DIGITS.."d", math.min(count, 10^ALIVE_DIGITS - 1))
	local leading = true
	for i,slot in ipairs(window.top.threats.content.digits.children) do
		local c = str:sub(i, i)
		leading = leading and c == "0" and (i < ALIVE_DIGITS or count == 0) -- 000 all grey
		local label = slot["alive_d"..i]
		label.caption = c
		label.style.font_color = leading and ALIVE_COLOR_DIM or ALIVE_COLOR
	end
end

-- quality columns up to the max bot quality setting, more if a shown wave has higher ones (setting lowered)
---@param vault Vault
---@return integer
local function quality_columns(vault)
	local num_q = math.ceil(common.MAX_BOT_QUALITY)
	for _,wave in pairs({vault.active_wave, vault.prev_wave}) do
		---@cast wave WaveInfo
		for i,qn in ipairs(QUALITIES) do
			if wave.bot_qualities[qn] then num_q = math.max(num_q, i) end
		end
	end
	return math.min(num_q, #QUALITIES)
end

-- depth at which a tier is reached, inverse of the progression curve in depth_scaling (tier = depth^(1/curve) * (max-1))
---@param tier number
---@param max_quality number -- setting, 1-5
---@return number? depth 0-1, nil if above the max
local function tier_depth(tier, max_quality)
	if max_quality <= 1 then
		return tier <= 0 and 0 or nil
	end
	local frac = tier / (max_quality - 1)
	if frac > 1 then return nil end
	return frac ^ common.PROGRESSION_CURVE
end

-- gauge mark centered on x px along the bar, clamped to the bar plus overhang, nil hides it
---@param elem LuaGuiElement
---@param x number?
---@param w integer
local function place(elem, x, w)
	elem.visible = x ~= nil
	if x then
		elem.style.left_margin = math.max(math.min(math.floor(GAUGE_OVERHANG + x - w/2 + 0.5), GAUGE_WIDTH + 2*GAUGE_OVERHANG - w), 0)
	end
end

-- tier number next to the cursor (right of it, left near the end), 1 based like the settings
---@param label LuaGuiElement
---@param x number
---@param tier number -- 0 based
---@return number left, number right -- px along the bar
local function place_tier(label, x, tier)
	local half = GAUGE_CURSOR_W/2 + 2
	local right = x + half + GAUGE_TIER_W <= GAUGE_WIDTH + GAUGE_OVERHANG
	local center = right and x + half + GAUGE_TIER_W/2 or x - half - GAUGE_TIER_W/2
	label.caption = string.format("%.1f", tier + 1)
	label.style.horizontal_align = right and "left" or "right"
	place(label, center, GAUGE_TIER_W)
	return center - GAUGE_TIER_W/2, center + GAUGE_TIER_W/2
end

---@param vault Vault
---@param window LuaGuiElement
local function update_content(vault, window)
	local refs = gui_util.get_refs(window)

	-- scans if needed
	-- represent per vault evolution as "depth mined" in approx 0-100 meters (really just %)
	local mining_rate, depth = vault:find_current_mining_rate_and_depth()
	local scrap = vault.scrap_tracker
	refs.mining_rate.caption = L("per-minute", string.format("%d", mining_rate))
	-- finite: actual amounts, drainable stops at the 20% floor, inf: drainable (down to the minimum)
	-- TODO: this may be confusing, but better have a depth that seems arbitrary than a obviously wrong total
	local total = scrap.initial_total or scrap.drainable
	local drained = scrap.initial_total and (total - scrap.amount_total) or (total - scrap.remaining)
	refs.mining_drained.caption = L("drained", string.format("%4.2f", drained/1000000), string.format("%4.2f", total/1000000))
	refs.mining_depth.caption = L("meters", string.format("%d", depth*100))

	-- waves, the next one also while one is active (waves can overlap), bots of the previous wave can still be around
	-- Note that this factors in random variation
	local _, size, _, eta = spawning.should_spawn_wave(vault, false)
	-- threat of the next wave without the per type variation (actual counts are rolled at spawn)
	local next_threat = size and select(2, spawning.estimate_bot_counts(size, depth))
	local waves = {active=vault.active_wave, last=vault.prev_wave}
	local num_q = quality_columns(vault)
	for i=1,#QUALITIES do
		refs["q"..i].visible = i <= num_q
	end
	-- size is a multiplier on the depth bot counts (x100 for %), threat is already in %
	local function pct(v, fmt) return v and string.format(fmt or "%.0f%%", v) or "--" end
	for _,row in ipairs(WAVE_ROWS) do
		local wave = waves[row]
		if row == "next" then
			refs.next_time.caption = eta and L("next-eta", string.format("%.1f", eta)) or "--"
			refs.next_size.caption = pct(size and size*100, "~%.0f%%")
			refs.next_threat.caption = pct(next_threat, "~%.0f%%")
		else
			refs[row.."_time"].caption = wave and L(row == "active" and "active-for" or "last-ago", string.format("%.1f", (game.tick - wave.start_tick) / 3600)) or "--"
			refs[row.."_size"].caption = pct(wave and wave.size and wave.size*100)
			refs[row.."_threat"].caption = pct(wave and wave.threat)
		end
		local types, quals = wave and wave.bot_types or {}, wave and wave.bot_qualities or {}
		for i,n in ipairs(WAVE_TABLE_BOTS) do
			refs[row.."_bot"..i].caption = (types[n] or 0) > 0 and tostring(types[n]) or ""
		end
		local sum = 0
		for _,c in pairs(quals) do sum = sum + c end
		for i,qn in ipairs(QUALITIES) do
			refs[row.."_q"..i].caption = quals[qn] and string.format("%.0f%%", quals[qn] / sum * 100) or ""
		end
	end
	refs.active_label.style = waves.active and "bold_label" or "bold_grey_label" -- same font, normal vs bold would resize the column

	-- depth gauge
	refs.depth_bar.value = depth
	local x = depth * GAUGE_WIDTH
	-- icon with quality badge where each quality becomes the base quality (tier = level-1), up to the max quality setting
	-- a fractional max (2.5) only reaches part of the next quality at the end, not shown
	for i=1,#QUALITIES do
		local ds, db = tier_depth(i-1, common.MAX_SCRAP_QUALITY), tier_depth(i-1, common.MAX_BOT_QUALITY)
		place(refs["scrap_q"..i], ds and ds * GAUGE_WIDTH, GAUGE_BADGE)
		place(refs["bot_q"..i], db and db * GAUGE_WIDTH, GAUGE_BADGE)
	end
	place(refs.scrap_cursor, x, GAUGE_CURSOR_W)
	place(refs.bot_cursor, x, GAUGE_CURSOR_W)
	place_tier(refs.scrap_tier, x, depth_scaling.scrap_tier(depth))
	local label_left, label_right = place_tier(refs.bot_tier, x, depth_scaling.bot_tier(depth))
	-- ticks in drainable units like depth (not the finite total above), none under the drone tier label
	local drainable = scrap.drainable
	for n=1,GAUGE_MAX_TICKS do
		local tx = drainable > 0 and n * 1000000 / drainable * GAUGE_WIDTH or math.huge
		place(refs["tick"..n], tx <= GAUGE_WIDTH and (tx < label_left - 1 or tx > label_right + 1) and tx or nil, 1)
	end

	update_threats(vault, window)
end

-- the pinned panel closes once its vault is offscreen, in map view (could get stuck there) or when the view is on another surface
local PINNED_CLOSE_MARGIN = 0 -- tiles inside the screen edge, 0: closes once the vault center leaves the screen

---@param player LuaPlayer
---@param pos MapPosition
---@param margin number -- tiles inside the screen edge
---@return boolean
local function is_on_screen(player, pos, margin)
	-- 32 px per tile at zoom 1, player.position is the view center (physical_position is the character)
	local res, z = player.display_resolution, player.zoom
	local p = player.position
	return math.abs(pos.x - p.x) < res.width / (64*z) - margin
		and math.abs(pos.y - p.y) < res.height / (64*z) - margin
end

-- pinned window and its vault, destroys the window if the vault is gone
---@param player LuaPlayer
---@return LuaGuiElement? window, Vault? vault
local function get_pinned(player)
	local window = player.gui.left[PINNED_NAME]
	if not window then return nil, nil end
	local vault = storage.vaults and storage.vaults[window.tags.vault]
	if not (vault and vault.entity.valid) or window.tags.v ~= WINDOW_VERSION then
		window.destroy()
		return nil, nil
	end
	return window, vault
end

-- every GUI_FAST_UPDATE_PERIOD ticks: threat counters, pinned panel closing
---@param player LuaPlayer
function gui.update_info_gui_fast(player)
	local window = player.gui.left[WINDOW_NAME]
	local vault = window and storage.vaults and storage.vaults[window.tags.vault]
	if vault and vault.entity.valid then
		update_threats(vault, window)
	end

	local pinned, pinned_vault = get_pinned(player)
	if pinned and pinned_vault then
		local e = pinned_vault.entity
		if e.surface.index ~= player.surface.index or player.render_mode ~= defines.render_mode.game
			or not is_on_screen(player, e.position, PINNED_CLOSE_MARGIN) then
			pinned.destroy()
		else
			update_threats(pinned_vault, pinned)
		end
	end
end

-- hover preview of the selected vault, none for the pinned one, every GUI_UPDATE_PERIOD ticks and on selection change
---@param player LuaPlayer
function gui.update_info_gui(player)
	local window = player.gui.left[WINDOW_NAME]
	local selected = player.selected
	local vault = selected and selected.valid and selected.name == const.VAULT_NAME and get_or_init_vault(selected)
	local _, pinned_vault = get_pinned(player)
	if window and (not vault or vault == pinned_vault or window.tags.v ~= WINDOW_VERSION) then
		window.destroy()
		window = nil
	end
	if not vault or vault == pinned_vault then return end
	if not window then
		window = get_window_defs().hover:add_to(player.gui.left)
		-- the cursor over the panel clears player.selected, which closed the panel, then the vault behind it got selected again (flicker)
		-- the panel has nothing to click, so let the cursor pass through to the world (set on all elements, the docs don't say whether children inherit it)
		set_recursive(window, "ignored_by_interaction", true)
	end
	window.tags = {vault=vault.id, v=WINDOW_VERSION}
	update_content(vault, window)
end

---@param player LuaPlayer
function gui.refresh_pinned(player)
	local window, vault = get_pinned(player)
	if window and vault then
		update_content(vault, window)
	end
end

-- left click (custom input linked to open-gui) on a vault: pin it, unpin if already pinned, switch if another one is
---@param event EventData.CustomInputEvent
function gui.on_pin_input(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local selected = player.selected
	if not (selected and selected.valid and selected.name == const.VAULT_NAME) then return end
	init()
	local vault = get_or_init_vault(selected)

	local window, pinned_vault = get_pinned(player)
	if window and vault == pinned_vault then
		window.destroy()
	else
		window = window or get_window_defs().pinned:add_to(player.gui.left)
		window.tags = {vault=vault.id, v=WINDOW_VERSION}
		update_content(vault, window)
	end
	gui.update_info_gui(player) -- hover preview off while pinned, back on when unpinned
end

---@param event EventData.on_gui_click
function gui.on_gui_click(event)
	local elem = event.element
	if elem.valid and elem.name == PINNED_CLOSE_NAME then
		local player = game.get_player(event.player_index) ---@cast player -nil
		local window = player.gui.left[PINNED_NAME]
		if window then
			window.destroy()
		end
	end
end

--#endregion

return gui
