local const = require("const")
local common = require("control.common")
---@class Vault
local Vault = require("control.vault")
local depth_scaling = require("control.depth_scaling")
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

local WINDOW_NAME = "hexcoder_fulgoran_drones_vault"

-- threats: drones currently out as odometer digits (each in its own slot, leading zeros dimmed, all of them at 0)
-- updated every tick (update_info_gui_fast), the rest of the window in on_nth_tick (events.lua)
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
-- depth cursor: arrows above and below the bar with the tier next to them
-- hint arrows are 16x12 at scale 0.5, TODO: own graphic?
local GAUGE_CURSOR_W = 10 -- was 12x9
local GAUGE_CURSOR_H = 7
local GAUGE_CURSOR_GAP = 1 -- to the bar
local GAUGE_TIER_W = 20 -- tier label, estimated "4.3" in default-small
local GAUGE_TIER_H = 14

---@class BotCounts
---@field bot_types table<string, integer>
---@field bot_qualities table<string, integer>

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

-- quality columns up to the max bot quality setting, more if a shown wave has higher ones (setting lowered)
---@param vault Vault
---@return integer
local function quality_columns(vault)
	local qualities = const.QUALITY_IDS
	local num_q = math.ceil(common.MAX_BOT_QUALITY)
	for _,wave in pairs({vault.active_wave, vault.prev_wave}) do
		---@cast wave WaveInfo
		for i,qn in ipairs(qualities) do
			if wave.bot_qualities[qn] then num_q = math.max(num_q, i) end
		end
	end
	return math.min(num_q, #qualities)
end

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

-- fixed rows next / active / last (future to past), -- if none, icons only in the header
-- three tables (wave, bots, qualities) side by side for vertical lines between the groups, rows line up as long as all cells are single line labels
-- header row sits on a subheader strip drawn before it (negative top_margin overlay, like vanilla negative_subheader_frame)
-- cells named <row>_label/_time/_size/_bot<i>/_q<i>
---@param num_q integer
---@return GuiDef[]
local function wave_table_def(num_q)
	local function tbl(cols, right_from)
		local align = {}
		for i=right_from,cols do align[i] = "right" end
		return GUI{type="table", column_count=cols, style={horizontal_spacing=COLUMN_SPACING, column_alignments=align}}
	end
	local function vline() -- below the header strip
		return GUI{type="line", direction="vertical", style={vertically_stretchable=true, top_margin=SUBHEADER_HEIGHT - SUBHEADER_PAD}}
	end

	-- header
	local wave_cells = {
		GUI{type="label", caption=L("waves"), style={base="subheader_caption_label", left_padding=0, height=HEADER_HEIGHT, vertical_align="center"}},
		GUI{type="label", caption="", style={left_margin=4}}, -- small gap after the label column
		GUI{type="label", caption=L("size"), style={height=HEADER_HEIGHT, vertical_align="center", minimal_width=SIZE_COLUMN_WIDTH, horizontal_align="right"}},
	}
	local bot_cells, qual_cells = {}, {}
	for _,n in ipairs(WAVE_TABLE_BOTS) do
		table.insert(bot_cells, header_icon("entity/"..n:gsub("^fulgoran%-", ""), HEADER_BOT_ICON)) -- player version icon (no skull), easier to read
	end
	for i=1,num_q do
		table.insert(qual_cells, header_icon("quality/"..const.QUALITY_IDS[i], HEADER_QUALITY_ICON))
	end

	local labels = {next=L("next"), active=L("active"), last=L("last")}
	for _,row in ipairs(WAVE_ROWS) do
		local style = row == "next" and "grey_label" or nil -- active label style is set in update
		table.insert(wave_cells, GUI{type="label", name=row.."_label", caption=labels[row], style=style})
		table.insert(wave_cells, GUI{type="label", name=row.."_time", caption="", style={base=style, left_margin=4}})
		table.insert(wave_cells, GUI{type="label", name=row.."_size", caption="", style=style})
		for i=1,#WAVE_TABLE_BOTS do
			table.insert(bot_cells, GUI{type="label", name=row.."_bot"..i, caption=""})
		end
		for i=1,num_q do
			table.insert(qual_cells, GUI{type="label", name=row.."_q"..i, caption=""})
		end
	end

	return {
		subheader(),
		GUI{type="flow", direction="horizontal", style={horizontal_spacing=COLUMN_SPACING, top_margin=-SUBHEADER_HEIGHT + SUBHEADER_PAD,
			left_padding=8, right_padding=8, bottom_padding=4}}:add{
			tbl(3, 3):add(wave_cells), -- label, time, size
			vline(),
			tbl(#WAVE_TABLE_BOTS, 1):add(bot_cells),
			vline(),
			tbl(num_q, 1):add(qual_cells),
		},
	}
end

---@param num_q integer -- quality columns of the wave table
---@return GuiDef
local function get_window_def(num_q)
	local window = GUI{type="frame", name=WINDOW_NAME, direction="vertical"}:add{
		GUI{type="flow", style={horizontal_spacing=8}}:add{
			GUI{type="label", caption=L("title"), style={base="frame_title", top_margin=-3, bottom_margin=3}, ignored_by_interaction=true}
		},
	}

	--[[
		Prev/active wave: size %, freq/m  bots: 5 A  6 B  12 C
		Mining: Since last (rate/m)
		ETA  size %, freq/m
		Mining Depth: total mined, "depth" in m, <bar for depth with quality indicator?
	]]

	-- depth gauge rows: scrap quality badges + top cursor, bar, million ticks + bottom cursor, drone quality badges
	-- marks are placed in update (positions depend on depth, settings and amounts)
	-- tier numbers next to the cursors, were "Scrap 1.0" / "Drones 2.8" labels left of the gauge
	local function marks_flow(name)
		return GUI{type="flow", name=name, direction="vertical", style={vertical_spacing=0, width=GAUGE_WIDTH + 2*GAUGE_OVERHANG}}
	end
	local custom_font = prototypes.font[ALIVE_FONT] ~= nil
	local digit_size = custom_font and ALIVE_DIGIT_SIZE or ALIVE_DIGIT_SIZE_FALLBACK
	local digits = {}
	for i=1,ALIVE_DIGITS do
		table.insert(digits, GUI{type="frame", style={base=ALIVE_SLOT_STYLE, padding=0, width=digit_size[1], height=digit_size[2]}}:add{
			GUI{type="label", name="alive_d"..i, caption="0", style={font=custom_font and ALIVE_FONT or ALIVE_FONT_FALLBACK,
				width=digit_size[1], height=digit_size[2], horizontal_align="center", vertical_align="center"}},
		})
	end

	-- all frames horizontally stretchable, so both parts have the window width
	window:add{
		GUI{type="flow", name="top", direction="horizontal", style={horizontal_spacing=PART_SPACING, horizontally_stretchable=true}}:add{
			GUI{type="frame", direction="vertical", style={base=PART_FRAME_STYLE, horizontally_stretchable=true}}:add(wave_table_def(num_q)),
			-- drones currently out, all waves mixed
			-- named path top > threats > content, the fast update finds the digits through it
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
				GUI{type="label", name="mining_rate", caption="", style={base="bold_label", top_margin=SUBHEADER_VALUE_OFFSET}},
				GUI{type="empty-widget", style={horizontally_stretchable=true}},
				GUI{type="label", caption=L("depth"), style={base="subheader_caption_label", left_padding=0}},
				GUI{type="label", name="mining_depth", caption="", style={base="bold_label", top_margin=SUBHEADER_VALUE_OFFSET}},
				GUI{type="empty-widget", style={horizontally_stretchable=true}},
				GUI{type="label", name="mining_drained", caption="", style={font="default", right_padding=4}},
			},
			GUI{type="flow", direction="vertical", style={vertical_spacing=0, horizontally_stretchable=true, horizontal_align="center",
				left_padding=GAUGE_PADDING, right_padding=GAUGE_PADDING, top_padding=6, bottom_padding=4}}:add{
				marks_flow("scrap_marks"),
				GUI{type="progressbar", name="depth_bar", value=0, style={width=GAUGE_WIDTH, bar_width=GAUGE_BAR_HEIGHT, color=GAUGE_BAR_COLOR,
					left_margin=GAUGE_OVERHANG, right_margin=GAUGE_OVERHANG}},
				marks_flow("tick_marks"),
				marks_flow("bot_marks"),
			},
		},
	}

	return window
end
local window_defs = {} ---@type table<integer, GuiDef> -- per quality column count, same result every time, so no storage needed

---@param refs GuiRefs
---@param row string
---@param time LocalisedString
---@param size string
---@param counts BotCounts? -- bots and qualities of a wave, nil for the next wave
---@param num_q integer
local function set_wave_row(refs, row, time, size, counts, num_q)
	refs[row.."_time"].caption = time
	refs[row.."_size"].caption = size
	local types = counts and counts.bot_types or {}
	for i,n in ipairs(WAVE_TABLE_BOTS) do
		local count = types[n]
		refs[row.."_bot"..i].caption = count and count > 0 and tostring(count) or ""
	end
	local quals = counts and counts.bot_qualities or {}
	local total = 0
	for _,count in pairs(quals) do total = total + count end
	for i=1,num_q do
		local count = quals[const.QUALITY_IDS[i]]
		refs[row.."_q"..i].caption = count and string.format("%.0f%%", count / total * 100) or ""
	end
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

---@class GaugeMark
---@field x number -- px along the bar, center of the mark
---@field width integer
---@field height integer
---@field sprite string?
---@field quality string? -- shown as badge, sprite-button instead of sprite
---@field caption string? -- label instead of sprite
---@field align "left"|"right"|nil -- label text alignment
---@field valign "top"|"bottom"|nil -- in the row, default top
---@field gap integer? -- px to the row edge it is aligned to
---@field on_top boolean? -- drawn after the other marks

---@param x number
---@param sprite string
---@param width integer
---@param height integer
---@param quality string?
---@return GaugeMark
local function mark(x, sprite, width, height, quality)
	return {x=x, sprite=sprite, width=width, height=height, quality=quality}
end

-- gui has no absolute positioning (only screen elements have a location) and negative left_margin doesn't overlap
-- so every mark gets its own row with left_margin from the gauge start (rounded once, no drift at ui scale != 1)
-- and the rows are stacked onto the same line with negative top_margin, which works
-- marks are clamped to the bar plus overhang, may overlap, later (further right, on_top) ones on top
---@param flow LuaGuiElement -- vertical flow, GAUGE_OVERHANG wider than the bar on both sides
---@param marks GaugeMark[]
local function place_marks(flow, marks)
	table.sort(marks, function(a, b)
		if (a.on_top or false) ~= (b.on_top or false) then return not a.on_top end
		return a.x < b.x
	end)
	-- all rows as tall as the tallest mark, so the flow ends up that tall (it ends at the last row)
	local height = 0
	for _,m in ipairs(marks) do
		height = math.max(height, m.height + (m.gap or 0))
	end
	for i,m in ipairs(marks) do
		local left = math.floor(GAUGE_OVERHANG + m.x - m.width/2 + 0.5)
		left = math.max(math.min(left, GAUGE_WIDTH + 2*GAUGE_OVERHANG - m.width), 0)

		local row = flow.add{type="flow", direction="horizontal"}
		row.style.height = height
		row.style.top_margin = i > 1 and -height or 0

		local elem
		if m.caption then
			elem = row.add{type="label", caption=m.caption}
			elem.style.font = "default-small"
			elem.style.horizontal_align = m.align or "left"
			elem.style.vertical_align = "center" -- same distance to the bar above and below
		elseif m.quality then
			elem = row.add{type="sprite-button", sprite=m.sprite, style="transparent_slot", ignored_by_interaction=true}
			elem.quality = m.quality
			elem.style.padding = 0
		else
			elem = row.add{type="sprite", sprite=m.sprite}
			elem.style.stretch_image_to_widget_size = true
		end
		elem.style.width = m.width
		elem.style.height = m.height
		elem.style.left_margin = left
		if m.valign == "bottom" then
			elem.style.top_margin = height - m.height - (m.gap or 0)
		else
			elem.style.top_margin = m.gap or 0
		end
	end
end

-- icon with quality badge where each quality becomes the base quality (tier = level-1), up to the max quality setting
-- a fractional max (2.5) only reaches part of the next quality at the end, not shown
---@param marks GaugeMark[]
---@param max_quality number
---@param sprite string
---@param valign "top"|"bottom" -- towards the bar
---@param gap integer -- to the bar
local function add_quality_badges(marks, max_quality, sprite, valign, gap)
	for i,qn in ipairs(const.QUALITY_IDS) do
		local d = tier_depth(i-1, max_quality)
		if not d then break end
		local m = mark(d * GAUGE_WIDTH, sprite, GAUGE_BADGE, GAUGE_BADGE, qn)
		m.valign = valign
		m.gap = gap
		table.insert(marks, m)
	end
end

-- depth cursor: arrow pointing at the bar
---@param marks GaugeMark[]
---@param x number
---@param sprite string
---@param valign "top"|"bottom" -- towards the bar
local function add_cursor_arrow(marks, x, sprite, valign)
	table.insert(marks, {x=x, sprite=sprite, width=GAUGE_CURSOR_W, height=GAUGE_CURSOR_H,
		valign=valign, gap=GAUGE_CURSOR_GAP, on_top=true})
end

-- tier number next to the cursor (right of it, left near the end), 1 based like the settings
---@param marks GaugeMark[]
---@param x number
---@param tier number -- 0 based
---@param valign "top"|"bottom" -- towards the bar
---@return number left, number right -- px along the bar
local function add_tier_label(marks, x, tier, valign)
	local half = GAUGE_CURSOR_W/2 + 2
	local right = x + half + GAUGE_TIER_W <= GAUGE_WIDTH + GAUGE_OVERHANG
	local center = right and x + half + GAUGE_TIER_W/2 or x - half - GAUGE_TIER_W/2
	table.insert(marks, {x=center, width=GAUGE_TIER_W, height=GAUGE_TIER_H, caption=string.format("%.1f", tier + 1),
		align=right and "left" or "right", valign=valign, gap=GAUGE_CURSOR_GAP, on_top=true})
	return center - GAUGE_TIER_W/2, center + GAUGE_TIER_W/2
end

-- threat counter, every tick
---@param vault Vault
---@param content LuaGuiElement -- top > threats > content
function gui.update_info_gui_fast_content(vault, content)
	local count = count_alive(vault)

	local str = string.format("%0"..ALIVE_DIGITS.."d", math.min(count, 10^ALIVE_DIGITS - 1))
	local leading = true
	for i=1,ALIVE_DIGITS do
		local c = str:sub(i, i)
		leading = leading and c == "0" and (i < ALIVE_DIGITS or count == 0) -- 000 all grey
		local label = content.digits.children[i]["alive_d"..i]
		label.caption = c
		label.style.font_color = leading and ALIVE_COLOR_DIM or ALIVE_COLOR
	end
end

---@param player LuaPlayer
function gui.update_info_gui_fast(player)
	local window = player.gui.left[WINDOW_NAME]
	local selected = player.selected
	if window and selected and selected.valid and selected.name == const.VAULT_NAME then
		local vault = get_vault(selected)
		if vault then
			gui.update_info_gui_fast_content(vault, window.top.threats.content)
		end
	end
end

---@param vault Vault
---@param refs GuiRefs
---@param num_q integer -- quality columns of the wave table
function gui.update_info_gui_content(vault, refs, num_q)
	local time_since_start = (game.tick - vault.wave_timer_start) / 3600
	--local time_between = (game.tick - (vault.wave_end_tick)) / 3600

	local scrap = vault.scrap_tracker
	local e = vault.entity
	scrap:scan(e.surface, e.position, const.VAULT_DEFENSE_RADIUS, vault.has_drills)
	local mining_rate = scrap:mining_rate()

	-- represent per vault evolution as "depth mined" in approx 0-100 meters (really just %)
	local depth = scrap.depth

	--refs.mining1.caption = string.format("%6d (%d/m)", scrap.mined, mining_rate)
	refs.mining_rate.caption = L("per-minute", string.format("%d", mining_rate))
	-- finite: actual amounts, drainable stops at the 20% floor, inf: drainable (down to the minimum)
	-- TODO: this may be confusing, but better have a depth that seems arbitrary than a obviously wrong total
	local total = scrap.initial_total or scrap.drainable
	local drained = scrap.initial_total and (total - scrap.amount_total) or (total - scrap.remaining)
	refs.mining_drained.caption = L("drained", string.format("%4.2f", drained/1000000), string.format("%4.2f", total/1000000)) -- "[font=default-bold]%4.2fM[/font] / [font=default-bold]%4.2fM[/font]"
	refs.mining_depth.caption = L("meters", string.format("%d", depth*100))

	-- waves
	-- Note that this factors in random variation
	local trigger_wave, size, freq, eta = vault:should_spawn_wave(mining_rate, depth, time_since_start, false)
	local active, prev = vault.active_wave, vault.prev_wave
	local function wave_time(wave, key)
		return wave and L(key, string.format("%.1f", (game.tick - wave.start_tick) / 3600)) or "--"
	end
	local function wave_size(s, fmt)
		return s and string.format(fmt, s) or "--"
	end
	-- next wave also shown while one is active (waves can overlap)
	set_wave_row(refs, "next", eta and L("next-eta", string.format("%.1f", eta)) or "--", wave_size(size, "~%.0f%%"), nil, num_q)
	-- bots of the previous wave can still be around while the active one spawns
	set_wave_row(refs, "active", wave_time(active, "active-for"), wave_size(active and active.size, "%.0f%%"), active, num_q)
	set_wave_row(refs, "last", wave_time(prev, "last-ago"), wave_size(prev and prev.size, "%.0f%%"), prev, num_q)
	refs.active_label.style = active and "bold_label" or "bold_grey_label" -- same font, normal vs bold would resize the column

	gui.update_info_gui_fast_content(vault, refs.content)

	-- depth gauge
	refs.depth_bar.value = depth
	local x = depth * GAUGE_WIDTH

	local scrap_marks = {}
	add_quality_badges(scrap_marks, common.MAX_SCRAP_QUALITY, "item/scrap", "bottom", GAUGE_SCRAP_GAP)
	add_cursor_arrow(scrap_marks, x, "utility/hint_arrow_down", "bottom")
	add_tier_label(scrap_marks, x, depth_scaling.scrap_tier(depth), "bottom")
	place_marks(refs.scrap_marks, scrap_marks)

	-- bottom arrow and drone tier in the tick row, mirroring the top ones
	local tick_marks = {}
	add_cursor_arrow(tick_marks, x, "utility/hint_arrow_up", "top")
	local label_left, label_right = add_tier_label(tick_marks, x, depth_scaling.bot_tier(depth), "top")
	-- ticks in drainable units like depth (not the finite total above), none under the tier label
	local drainable = scrap.drainable
	if drainable > 0 then
		for n=1,math.floor(drainable / 1000000) do
			local tx = n * 1000000 / drainable * GAUGE_WIDTH
			if tx < label_left - 1 or tx > label_right + 1 then
				local height = n % 10 == 0 and GAUGE_TICK_HEIGHT_10M or GAUGE_TICK_HEIGHT
				table.insert(tick_marks, mark(tx, "utility/white_square", 1, height))
			end
		end
	end
	place_marks(refs.tick_marks, tick_marks)

	local bot_marks = {}
	add_quality_badges(bot_marks, common.MAX_BOT_QUALITY, "entity/"..GAUGE_BOT, "top", GAUGE_BOT_GAP)
	place_marks(refs.bot_marks, bot_marks)
end

---@param player LuaPlayer
function gui.update_info_gui(player)
	local existing = player.gui.left[WINDOW_NAME]
	if existing then
		existing.destroy()
	end

	local selected = player.selected
	if selected and selected.valid and selected.name == const.VAULT_NAME then
		local vault = get_or_init_vault(selected)

		local num_q = quality_columns(vault)
		window_defs[num_q] = window_defs[num_q] or get_window_def(num_q)
		local window, refs = window_defs[num_q]:add_to(player.gui.left)
		gui.update_info_gui_content(vault, refs, num_q)
	end
end
--#endregion

return gui
