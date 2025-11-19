local _ = require("gettext")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local InfoMessage = require("ui/widget/infomessage")
local GestureRange = require("ui/gesturerange")
local Device = require("device")
local Screen = Device.screen
local Menu = require("ui/widget/menu")
local RenderText = require("ui/rendertext")
local Font = require("ui/font")
local T = require("ffi/util").template
local json = require("json")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local Utf8Proc = require("ffi/utf8proc")

local DEFAULT_WORDLIST = "word_lists/english_basic.txt"
local DEFAULT_GRID_SIZE = 12
local GRID_SIZE_CHOICES = { 8, 10, 12, 14, 16 }
local GRID_SIZE_LOOKUP = {}
for _idx, size in ipairs(GRID_SIZE_CHOICES) do
    GRID_SIZE_LOOKUP[size] = true
end
local DEFAULT_MAX_WORDS = 12
local function normalizeGridSize(size)
    size = tonumber(size)
    if size then
        size = math.floor(size)
        if GRID_SIZE_LOOKUP[size] then
            return size
        end
    end
    return DEFAULT_GRID_SIZE
end
local GRID_SCALES = {
    compact = { key = "compact", label = _("Compact"), width = 0.8, height = 0.5 },
    normal = { key = "normal", label = _("Normal"), width = 0.9, height = 0.6 },
    large = { key = "large", label = _("Large"), width = 0.98, height = 0.7 },
}
local GRID_SCALE_ORDER = { "compact", "normal", "large" }
local DEFAULT_GRID_SCALE = "normal"
local DIRECTIONS = {
    { name = "E",  dx =  1, dy =  0 },
    { name = "W",  dx = -1, dy =  0 },
    { name = "S",  dx =  0, dy =  1 },
    { name = "N",  dx =  0, dy = -1 },
    { name = "SE", dx =  1, dy =  1 },
    { name = "NW", dx = -1, dy = -1 },
    { name = "NE", dx =  1, dy = -1 },
    { name = "SW", dx = -1, dy =  1 },
}

local STRIKE_CHAR = "\204\182" -- UTF-8 U+0336 combining long stroke overlay

local function safeUpper(text)
    if not text then
        return ""
    end

    if type(text) ~= "string" then
        return text
    end
    if Utf8Proc and Utf8Proc.uppercase then
        return Utf8Proc.uppercase(text)
    end
    return text:upper()
end

local function applyStrikethrough(word)
    local parts = {}
    for glyph in word:gmatch(util.UTF8_CHAR_PATTERN) do
        parts[#parts + 1] = glyph .. STRIKE_CHAR
    end
    return table.concat(parts)
end

local function getPluginPath()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local dir = source:match("(.*/)main%.lua$") or source:match("(.*\\)main%.lua$")
    if dir then
        dir = dir:gsub("\\", "/")
        return dir:sub(-1) == "/" and dir:sub(1, -2) or dir
    end
    return DataStorage:getDataDir() .. "/plugins/wordsearch.koplugin"
end

local PLUGIN_PATH = getPluginPath()

local function readWordList(path)
    local metadata = {
        lang = "en",
        letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        title = _("Default list"),
    }
    local words = {}
    local abs_path = path
    if not abs_path:match("^/") and not abs_path:match("^[A-Z]:") then
        abs_path = PLUGIN_PATH .. "/" .. path
    end
    local file = io.open(abs_path, "r")
    if not file then
        logger.warn("WordSearch: cannot open word list", abs_path)
        return metadata, words
    end
    for line in file:lines() do
        line = util.trim(line)
        if line ~= "" then
            if #words == 0 and line:find("lang=") then
                for key, value in line:gmatch("([%w_]+)=([%w_%-]+)") do
                    if metadata[key] then
                        metadata[key] = value
                    elseif key == "title" then
                        metadata.title = value
                    elseif key == "letters" then
                        metadata.letters = value
                    end
                end
            else
                words[#words + 1] = safeUpper(line)
            end
        end
    end
    file:close()
    return metadata, words
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
end

local function createEmptyGrid(size)
    local grid = {}
    for y = 1, size do
        grid[y] = {}
        for x = 1, size do
            grid[y][x] = ""
        end
    end
    return grid
end

local function createMaskGrid(size, initial)
    local grid = {}
    for y = 1, size do
        grid[y] = {}
        for x = 1, size do
            grid[y][x] = initial or false
        end
    end
    return grid
end

local function canPlaceWord(grid, word, start_x, start_y, dir)
    local size = #grid
    local x, y = start_x, start_y
    for i = 1, #word do
        if x < 1 or x > size or y < 1 or y > size then
            return false
        end
        local cell = grid[y][x]
        local ch = word:sub(i, i)
        if cell ~= "" and cell ~= ch then
            return false
        end
        x = x + dir.dx
        y = y + dir.dy
    end
    return true
end

local function placeWord(grid, word, start_x, start_y, dir)
    local x, y = start_x, start_y
    for i = 1, #word do
        grid[y][x] = word:sub(i, i)
        x = x + dir.dx
        y = y + dir.dy
    end
end

local function fillEmptyCells(grid, letters)
    for y = 1, #grid do
        for x = 1, #grid do
            if grid[y][x] == "" then
                local idx = math.random(#letters)
                grid[y][x] = letters:sub(idx, idx)
            end
        end
    end
end

local function generatePuzzle(words, letters, max_words, grid_size)
    grid_size = normalizeGridSize(grid_size)
    local grid = createEmptyGrid(grid_size)
    local solution_mask = createMaskGrid(grid_size, false)
    local placed = {}
    shuffle(words)
    local placed_count = 0
    local limit = math.max(1, max_words or DEFAULT_MAX_WORDS)
    local direction_usage = {}
    for _, dir in ipairs(DIRECTIONS) do
        direction_usage[dir.name] = 0
    end
    local start_points = {}
    for y = 1, grid_size do
        for x = 1, grid_size do
            start_points[#start_points + 1] = { x = x, y = y }
        end
    end
    shuffle(start_points)
    local start_cursor = 1
    local function nextStartPoint()
        local point = start_points[start_cursor]
        start_cursor = start_cursor + 1
        if start_cursor > #start_points then
            start_cursor = 1
            shuffle(start_points)
        end
        return point.x, point.y
    end
    for _, word in ipairs(words) do
        if placed_count >= limit then
            break
        end
        local upper_word = safeUpper(word)
        local word_stripped = upper_word:gsub("[^" .. letters .. "]", "")
        if #word_stripped >= 3 and #word_stripped <= grid_size then
            local tries = 0
            local success = false
            local direction_candidates = {}
            for idx, dir in ipairs(DIRECTIONS) do
                direction_candidates[idx] = {
                    dir = dir,
                    usage = direction_usage[dir.name] or 0,
                    bias = math.random(),
                }
            end
            table.sort(direction_candidates, function(a, b)
                if a.usage == b.usage then
                    return a.bias < b.bias
                end
                return a.usage < b.usage
            end)
            local start_attempts = 0
            while tries < 100 and not success do
                local dir = direction_candidates[((tries) % #direction_candidates) + 1].dir
                local start_x, start_y
                if start_attempts < #start_points then
                    start_x, start_y = nextStartPoint()
                    start_attempts = start_attempts + 1
                else
                    start_x = math.random(grid_size)
                    start_y = math.random(grid_size)
                end
                if canPlaceWord(grid, word_stripped, start_x, start_y, dir) then
                    local entry = { word = word_stripped, positions = {} }
                    local x, y = start_x, start_y
                    for i = 1, #word_stripped do
                        local ch = word_stripped:sub(i, i)
                        grid[y][x] = ch
                        solution_mask[y][x] = true
                        entry.positions[#entry.positions + 1] = { row = y, col = x }
                        x = x + dir.dx
                        y = y + dir.dy
                    end
                    placed[#placed + 1] = entry
                    placed_count = placed_count + 1
                    direction_usage[dir.name] = (direction_usage[dir.name] or 0) + 1
                    success = true
                end
                tries = tries + 1
            end
        end
    end
    fillEmptyCells(grid, letters)
    return grid, placed, solution_mask
end

local WordSearchBoard = {}
WordSearchBoard.__index = WordSearchBoard

function WordSearchBoard:new(wordlist_path, opts)
    opts = opts or {}
    local metadata, words = readWordList(wordlist_path or DEFAULT_WORDLIST)
    local letters = safeUpper(metadata.letters or "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    local grid_size = normalizeGridSize(opts.grid_size or DEFAULT_GRID_SIZE)
    local board = {
        metadata = metadata,
        words = words,
        letters = letters,
        grid = createEmptyGrid(grid_size),
        placed_words = {},
        found_words = {},
        solved = false,
        show_solution = false,
        solution_mask = createMaskGrid(grid_size, false),
        max_words = opts.max_words or DEFAULT_MAX_WORDS,
        grid_size = grid_size,
    }
    setmetatable(board, self)
    if opts.state then
        board:loadState(opts.state)
    else
        board:generate()
    end
    return board
end

function WordSearchBoard:generate()
    local grid, placed, mask = generatePuzzle(self.words, self.letters, self.max_words, self.grid_size)
    self.grid = grid
    self.placed_words = placed
    self.solution_mask = mask
    self.found_words = {}
    self.solved = false
    self.show_solution = false
end

function WordSearchBoard:serializeState()
    local found = {}
    for word in pairs(self.found_words) do
        found[#found + 1] = word
    end
    return {
        grid = self.grid,
        placed_words = self.placed_words,
        found_words = found,
        solved = self.solved,
        show_solution = self.show_solution,
        solution_mask = self.solution_mask,
        letters = self.letters,
        metadata = self.metadata,
        max_words = self.max_words,
        grid_size = self.grid_size,
    }
end

function WordSearchBoard:loadState(state)
    if not state or not state.grid then
        self:generate()
        return
    end
    self.grid = state.grid
    self.placed_words = state.placed_words or {}
    local state_grid_size = #state.grid
    self.grid_size = normalizeGridSize(state.grid_size or state_grid_size or self.grid_size)
    self.solution_mask = state.solution_mask or createMaskGrid(self.grid_size, false)
    self.found_words = {}
    if state.found_words then
        for _, word in ipairs(state.found_words) do
            self.found_words[word] = true
        end
    end
    self.solved = state.solved and true or false
    self.show_solution = state.show_solution and true or false
    self.max_words = state.max_words or self.max_words or DEFAULT_MAX_WORDS
    self.metadata = state.metadata or self.metadata
    self.letters = state.letters or self.letters
end

function WordSearchBoard:getSize()
    return self.grid_size or (#self.grid)
end

function WordSearchBoard:getGrid()
    return self.grid
end

function WordSearchBoard:isSolved()
    return self.solved or (self:getFoundCount() == #self.placed_words)
end

function WordSearchBoard:markSolved()
    self.solved = true
end

function WordSearchBoard:getMetadata()
    return self.metadata
end

function WordSearchBoard:getWordStatuses()
    local statuses = {}
    for _, entry in ipairs(self.placed_words) do
        statuses[#statuses + 1] = {
            word = entry.word,
            found = self.found_words[entry.word] and true or false,
        }
    end
    table.sort(statuses, function(a, b) return a.word < b.word end)
    return statuses
end

function WordSearchBoard:findWordByEndpoints(r1, c1, r2, c2)
    if not (r1 and c1 and r2 and c2) then
        return nil
    end
    for _, entry in ipairs(self.placed_words) do
        local first = entry.positions[1]
        local last = entry.positions[#entry.positions]
        if first and last then
            local same_dir = first.row == r1 and first.col == c1 and last.row == r2 and last.col == c2
            local reverse_dir = first.row == r2 and first.col == c2 and last.row == r1 and last.col == c1
            if same_dir or reverse_dir then
                return entry
            end
        end
    end
    return nil
end

function WordSearchBoard:findWordContainingCell(row, col)
    if not (row and col) then
        return nil
    end
    for _, entry in ipairs(self.placed_words) do
        for _, pos in ipairs(entry.positions) do
            if pos.row == row and pos.col == col then
                return entry
            end
        end
    end
    return nil
end

function WordSearchBoard:getFoundEntries()
    local list = {}
    for _, entry in ipairs(self.placed_words) do
        if self.found_words[entry.word] then
            list[#list + 1] = entry
        end
    end
    return list
end

function WordSearchBoard:getFoundCount()
    local count = 0
    for _ in pairs(self.found_words) do
        count = count + 1
    end
    return count
end

function WordSearchBoard:setWordFound(word, value)
    if not word then
        return
    end
    word = safeUpper(word)
    if value then
        self.found_words[word] = true
    else
        self.found_words[word] = nil
    end
end

function WordSearchBoard:toggleWord(word)
    word = safeUpper(word)
    if self.found_words[word] then
        self.found_words[word] = nil
    else
        self.found_words[word] = true
    end
end

function WordSearchBoard:toggleSolution()
    self.show_solution = not self.show_solution
end

function WordSearchBoard:isShowingSolution()
    return self.show_solution
end

function WordSearchBoard:isSolutionCell(row, col)
    return self.solution_mask and self.solution_mask[row] and self.solution_mask[row][col]
end

local function drawThickPoint(bb, cx, cy, thickness, color)
    local half = math.floor(thickness / 2)
    bb:paintRect(cx - half, cy - half, thickness, thickness, color)
end

local function drawThickLine(bb, x1, y1, x2, y2, thickness, color)
    local dx = x2 - x1
    local dy = y2 - y1
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps == 0 then
        drawThickPoint(bb, x1, y1, thickness, color)
        return
    end
    local step_x = dx / steps
    local step_y = dy / steps
    for i = 0, steps do
        local px = math.floor(x1 + step_x * i)
        local py = math.floor(y1 + step_y * i)
        drawThickPoint(bb, px, py, thickness, color)
    end
end

local WordGridWidget = InputContainer:extend{
    board = nil,
    scale = nil,
}

function WordGridWidget:getGridSize()
    if self.board and self.board.getSize then
        return self.board:getSize()
    end
    return DEFAULT_GRID_SIZE
end

function WordGridWidget:updateDimensions(scale)
    self.scale = scale or self.scale or GRID_SCALES[DEFAULT_GRID_SCALE]
    local grid_size = math.max(1, self:getGridSize())
    local width_factor = self.scale.width or 0.9
    local height_factor = self.scale.height or 0.6
    local max_width = math.floor(Screen:getWidth() * width_factor)
    local max_height = math.floor(Screen:getHeight() * height_factor)
    self.size = math.min(max_width, max_height)
    self.cell_size = math.max(4, math.floor(self.size / grid_size))
    self.dimen = Geom:new{ w = self.cell_size * grid_size, h = self.cell_size * grid_size }
    self.face = Font:getFace("cfont", math.max(24, math.floor(self.cell_size * 0.6)))
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }
end

function WordGridWidget:setScale(scale)
    self:updateDimensions(scale)
end

function WordGridWidget:setBoard(board)
    self.board = board
    self:updateDimensions(self.scale)
end

function WordGridWidget:init()
    self:updateDimensions(self.scale or GRID_SCALES[DEFAULT_GRID_SCALE])
    self.highlight_cell = nil
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.paint_rect end,
            }
        },
        Hold = {
            GestureRange:new{
                ges = "hold",
                range = function() return self.paint_rect end,
            }
        }
    }
end

function WordGridWidget:getCellFromPoint(x, y)
    local rect = self.paint_rect
    local local_x = x - rect.x
    local local_y = y - rect.y
    if local_x < 0 or local_y < 0 or local_x > rect.w or local_y > rect.h then
        return nil
    end
    local col = math.floor(local_x / self.cell_size) + 1
    local row = math.floor(local_y / self.cell_size) + 1
    local grid_size = self:getGridSize()
    if row < 1 or row > grid_size or col < 1 or col > grid_size then
        return nil
    end
    return row, col
end

function WordGridWidget:onTap(_, ges)
    if not (ges and ges.pos and self.onCellTapped) then
        return false
    end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then
        return false
    end
    self.onCellTapped(row, col, false)
    return true
end

function WordGridWidget:onHold(_, ges)
    if not (ges and ges.pos and self.onCellTapped) then
        return false
    end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then
        return false
    end
    self.onCellTapped(row, col, true)
    return true
end

function WordGridWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local grid = self.board and self.board:getGrid()
    if not grid then
        return
    end
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local grid_size = self:getGridSize()

    local highlight = self.highlight_cell
    for row = 1, grid_size do
        for col = 1, grid_size do
            local cell_x = x + (col - 1) * self.cell_size
            local cell_y = y + (row - 1) * self.cell_size
            local color = Blitbuffer.COLOR_WHITE
            if highlight and highlight.row == row and highlight.col == col then
                color = Blitbuffer.COLOR_GRAY
            end
            bb:paintRect(cell_x, cell_y, self.cell_size - 1, self.cell_size - 1, color)
            -- draw border
            bb:paintRect(cell_x, cell_y, self.cell_size, 1, Blitbuffer.COLOR_GRAY_8)
            bb:paintRect(cell_x, cell_y + self.cell_size - 1, self.cell_size, 1, Blitbuffer.COLOR_GRAY_8)
            bb:paintRect(cell_x, cell_y, 1, self.cell_size, Blitbuffer.COLOR_GRAY_8)
            bb:paintRect(cell_x + self.cell_size - 1, cell_y, 1, self.cell_size, Blitbuffer.COLOR_GRAY_8)
        end
    end

    -- overlay lines for found words and (optionally) solution hints (above grid, below letters)
    local highlight_color = Blitbuffer.COLOR_GRAY_B
    local line_thickness = math.max(2, math.floor(self.cell_size / 4))
    local function drawEntryLines(entries)
        for _, entry in ipairs(entries) do
            local first = entry.positions[1]
            local last = entry.positions[#entry.positions]
            if first and last then
                local start_x = x + (first.col - 1) * self.cell_size + math.floor(self.cell_size / 2)
                local start_y = y + (first.row - 1) * self.cell_size + math.floor(self.cell_size / 2)
                local end_x = x + (last.col - 1) * self.cell_size + math.floor(self.cell_size / 2)
                local end_y = y + (last.row - 1) * self.cell_size + math.floor(self.cell_size / 2)
                drawThickLine(bb, start_x, start_y, end_x, end_y, line_thickness, highlight_color)
            end
        end
    end
    local found_entries = self.board:getFoundEntries()
    drawEntryLines(found_entries)
    if self.board:isShowingSolution() then
        local found_lookup = {}
        for _, entry in ipairs(found_entries) do
            found_lookup[entry.word] = true
        end
        local missing_entries = {}
        for _, entry in ipairs(self.board.placed_words) do
            if not found_lookup[entry.word] then
                missing_entries[#missing_entries + 1] = entry
            end
        end
        drawEntryLines(missing_entries)
    end

    for row = 1, grid_size do
        for col = 1, grid_size do
            local char = grid[row][col]
            if char and char ~= "" then
                local cell_x = x + (col - 1) * self.cell_size
                local cell_y = y + (row - 1) * self.cell_size
                local text = char
                local metrics = RenderText:sizeUtf8Text(0, self.cell_size, self.face, text, true, false)
                local text_x = cell_x + math.floor((self.cell_size - metrics.x) / 2)
                local baseline = cell_y + math.floor((self.cell_size + metrics.y_top - metrics.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, text_x, baseline, self.face, text, true, false, Blitbuffer.COLOR_BLACK)
            end
        end
    end

end

function WordGridWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

function WordGridWidget:setHighlightCell(row, col)
    if row and col then
        local current = self.highlight_cell
        if current and current.row == row and current.col == col then
            return
        end
        self.highlight_cell = { row = row, col = col }
    else
        self.highlight_cell = nil
    end
    self:refresh()
end

function WordGridWidget:clearHighlightCell()
    if not self.highlight_cell then
        return
    end
    self.highlight_cell = nil
    self:refresh()
end

local WordSearchScreen = InputContainer:extend{}

function WordSearchScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.selection_start = nil
    self.board = self.plugin:getBoard()
    self.word_list_lines = nil
    self.completion_shown = false
    self.grid_widget = WordGridWidget:new{
        board = self.board,
        scale = GRID_SCALES[self.plugin:getGridScale()] or GRID_SCALES[DEFAULT_GRID_SCALE],
        onCellTapped = function(row, col, is_hold)
            self:onCellTapped(row, col, is_hold)
        end,
    }
    self.stats_label = TextWidget:new{ face = Font:getFace("smallinfofont"), text = "" }
    self:rebuildLayout()
    self:updateStatus()
    self:updateWordList()
end

function WordSearchScreen:paintTo(bb, x, y)
    if self.dimen then
        bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    end
    InputContainer.paintTo(self, bb, x, y)
end

function WordSearchScreen:rebuildLayout()
    local grid_scale = GRID_SCALES[self.plugin:getGridScale()] or GRID_SCALES[DEFAULT_GRID_SCALE]
    self.grid_widget:setScale(grid_scale)
    local grid_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.grid_widget,
    }

    local counter_box = FrameContainer:new{
        padding = Size.padding.small,
        margin = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.stats_label,
    }

    local top_button_table = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.9),
        buttons = {
            {
                {
                    text = _("Word count"),
                    callback = function()
                        self:showWordCountMenu()
                    end,
                },
                {
                    text = _("Word lists"),
                    callback = function()
                        self:chooseWordList()
                        self:refreshScreen()
                    end,
                },
                {
                    text = _("Grid size"),
                    callback = function()
                        self:showGridSizeMenu()
                    end,
                },
                {
                    text = _("Grid zoom"),
                    callback = function()
                        self:showGridScaleMenu()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        self:onClose()
                    end,
                },
            },
        },
    }

    local bottom_button_table = ButtonTable:new{
        shrink_unneeded_width = true,
        width = math.floor(Screen:getWidth() * 0.9),
        buttons = {
            {
                {
                    text = _("New puzzle"),
                    callback = function()
                        self:onNewPuzzle()
                    end,
                },
                {
                    id = "solution_button",
                    text = _("Show solution"),
                    callback = function()
                        self:showSolution()
                    end,
                },
                {
                    text = _("Words"),
                    callback = function()
                        self:showWordListOverlay()
                        self:refreshScreen()
                    end,
                },
            },
        },
    }
    self.solution_button = bottom_button_table:getButtonById("solution_button")

    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.span.vertical_small },
        top_button_table,
        VerticalSpan:new{ width = Size.span.vertical_small },
        grid_frame,
        VerticalSpan:new{ width = Size.span.vertical_small },
        counter_box,
        VerticalSpan:new{ width = Size.span.vertical_small },
        bottom_button_table,
        VerticalSpan:new{ width = Size.span.vertical_small },
    }

    self.layout = CenterContainer:new{
        dimen = self.dimen,
        content,
    }

    self[1] = self.layout
    self:updateSolutionButton()
end

function WordSearchScreen:updateStatus()
    local found = self.board:getFoundCount()
    local remaining = math.max(0, #self.board.placed_words - found)
    local text = T(_("Found: %1 · Remaining: %2"), found, remaining)
    self.stats_label:setText(text)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function WordSearchScreen:updateWordList()
    local lines = {}
    local meta = self.board:getMetadata() or {}
    lines[#lines + 1] = T(_("List: %1"), meta.title or _("Unknown"))
    lines[#lines + 1] = T(_("Language: %1"), meta.lang or "-" )
    for _, status in ipairs(self.board:getWordStatuses()) do
        local prefix = status.found and "✓" or "•"
        local display_word = status.word
        if status.found then
            display_word = applyStrikethrough(display_word)
        end
        lines[#lines + 1] = prefix .. " " .. display_word
    end
    self.word_list_lines = lines
end

function WordSearchScreen:refreshScreen()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function WordSearchScreen:refreshGridArea()
    local rect = self.grid_widget and self.grid_widget.paint_rect
    if rect then
        UIManager:setDirty(self, function()
            return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        end)
    else
        self:refreshScreen()
    end
end

function WordSearchScreen:getWordListText()
    if not self.word_list_lines then
        self:updateWordList()
    end
    return table.concat(self.word_list_lines or {}, "\n")
end

function WordSearchScreen:showWordListOverlay()
    local statuses = self.board:getWordStatuses()
    if #statuses == 0 then
        local info = InfoMessage:new{ text = _("This list has no words."), timeout = 3 }
        info.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(info)
        return
    end
    local items = {}
    for _, status in ipairs(statuses) do
        local display_word = status.word
        if status.found then
            display_word = applyStrikethrough(display_word)
        end
        items[#items + 1] = {
            text = display_word,
            checked = status.found,
        }
    end
    local meta = self.board:getMetadata() or {}
    local title = T(_("Words · %1"), meta.title or _("Unknown"))
    local menu = Menu:new{
        title = title,
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.65),
        height = math.floor(Screen:getHeight() * 0.8),
        show_parent = self,
    }
    menu.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(menu)
end

function WordSearchScreen:showWordCountMenu()
    local counts = { 6, 8, 10, 12, 14, 16, 18, 20, 22, 24 }
    local current = self.plugin.getMaxWords and self.plugin:getMaxWords() or self.plugin.max_words or DEFAULT_MAX_WORDS
    local menu
    local function closeMenu()
        if menu then
            UIManager:close(menu)
        end
    end
    local items = {}
    for _idx, count in ipairs(counts) do
        items[#items + 1] = {
            text = T(_("Max words: %1"), count),
            checked = (count == current),
            callback = function()
                if self.plugin.setMaxWords then
                    self.plugin:setMaxWords(count)
                end
                self:onNewPuzzle()
                closeMenu()
                return true
            end,
        }
    end
    menu = Menu:new{
        title = _("Select word count"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.6),
        height = math.floor(Screen:getHeight() * 0.7),
        show_parent = self,
    }
    menu.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(menu)
end

function WordSearchScreen:showGridSizeMenu()
    local current = self.plugin:getGridSize()
    local menu
    local function closeMenu()
        if menu then
            UIManager:close(menu)
        end
    end
    local items = {}
    for _idx, size in ipairs(GRID_SIZE_CHOICES) do
        items[#items + 1] = {
            text = T(_("Grid: %1 x %1"), size),
            checked = (size == current),
            callback = function()
                self.plugin:setGridSize(size)
                self.board = self.plugin:getBoard()
                self.grid_widget:setBoard(self.board)
                self:onNewPuzzle()
                closeMenu()
                return true
            end,
        }
    end
    menu = Menu:new{
        title = _("Select grid size"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.6),
        height = math.floor(Screen:getHeight() * 0.6),
        show_parent = self,
    }
    menu.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(menu)
end

function WordSearchScreen:showGridScaleMenu()
    local current = self.plugin:getGridScale()
    local menu
    local function closeMenu()
        if menu then
            UIManager:close(menu)
        end
    end
    local items = {}
    for _idx, key in ipairs(GRID_SCALE_ORDER) do
        local scale = GRID_SCALES[key]
        items[#items + 1] = {
            text = scale and scale.label or key,
            checked = (key == current),
            callback = function()
                if key ~= current then
                    self.plugin:setGridScale(key)
                    self:rebuildLayout()
                    self:refreshScreen()
                end
                closeMenu()
                return true
            end,
        }
    end
    menu = Menu:new{
        title = _("Select grid size"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.6),
        height = math.floor(Screen:getHeight() * 0.6),
        show_parent = self,
    }
    menu.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(menu)
end

function WordSearchScreen:onNewPuzzle()
    self.board:generate()
    self.grid_widget:refresh()
    self:updateStatus()
    self:updateWordList()
    self:updateSolutionButton()
    self.selection_start = nil
    self.completion_shown = false
    self:refreshScreen()
    self.plugin:saveBoardState()
end

function WordSearchScreen:showSolution()
    self.board:toggleSolution()
    self.grid_widget:refresh()
    self:updateSolutionButton()
    self:refreshScreen()
    self.plugin:saveBoardState()
end

function WordSearchScreen:updateSolutionButton()
    if not self.solution_button then
        return
    end
    local text = self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
    self.solution_button:setText(text, self.solution_button.width)
end

function WordSearchScreen:chooseWordList()
    local lists = self.plugin:listWordLists()
    if #lists == 0 then
        local info = InfoMessage:new{ text = _("No word lists found."), timeout = 3 }
        info.close_callback = function()
            self:refreshScreen()
        end
        UIManager:show(info)
        return
    end
    local menu
    local function closeMenu()
        if menu then
            UIManager:close(menu)
        end
    end
    local items = {}
    for _, entry in ipairs(lists) do
        items[#items + 1] = {
            text = entry.title,
            checked = (entry.path == self.plugin:getWordListPath()),
            callback = function()
                self.plugin:setWordList(entry.path)
                self.board = self.plugin:getBoard()
                self.grid_widget.board = self.board
                self:onNewPuzzle()
                closeMenu()
                return true
            end,
        }
    end
    menu = Menu:new{
        title = _("Select word list"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.7),
        height = math.floor(Screen:getHeight() * 0.8),
        show_parent = self,
    }
    menu.close_callback = function()
        self:refreshScreen()
    end
    UIManager:show(menu)
end

function WordSearchScreen:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    self.plugin:onScreenClosed()
end

function WordSearchScreen:onCellTapped(row, col, is_hold)
    self.grid_widget:setHighlightCell(row, col)
    self:refreshGridArea()
    if is_hold and self:markWordAtCell(row, col) then
        return
    end
    if not self.selection_start then
        self.selection_start = { row = row, col = col }
        return
    end
    if self.selection_start.row == row and self.selection_start.col == col then
        self.selection_start = nil
        return
    end
    local entry = self.board:findWordByEndpoints(self.selection_start.row, self.selection_start.col, row, col)
    if entry then
        self:handleWordFound(entry)
    else
        self.selection_start = { row = row, col = col }
    end
end

function WordSearchScreen:markWordAtCell(row, col)
    local entry = self.board:findWordContainingCell(row, col)
    if not entry then
        return false
    end
    self:handleWordFound(entry)
    return true
end

function WordSearchScreen:handleWordFound(entry)
    if not entry then
        return
    end
    self.board:setWordFound(entry.word, true)
    self.selection_start = nil
    self.grid_widget:clearHighlightCell()
    self:refreshGridArea()
    self:updateStatus()
    self:updateWordList()
    self.plugin:saveBoardState()
    if self.board:getFoundCount() == #self.board.placed_words then
        self:onAllWordsFound()
    end
end

function WordSearchScreen:onAllWordsFound()
    if self.completion_shown then
        return
    end
    self.board:markSolved()
    self.completion_shown = true
    local msg = InfoMessage:new{
        text = _("Congratulations! You found all words."),
        timeout = 7,
    }
    msg.close_callback = function()
        self.completion_shown = false
        self:refreshScreen()
    end
    UIManager:show(msg)
end

local WordSearch = InputContainer:extend{
    name = "wordsearch",
    is_doc_only = false,
}

function WordSearch:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/wordsearch.lua"
    self.settings = LuaSettings:open(self.settings_file)
    self.wordlist_path = self.settings:readSetting("wordlist_path") or DEFAULT_WORDLIST
    self.max_words = tonumber(self.settings:readSetting("max_words")) or DEFAULT_MAX_WORDS
    self.grid_scale = self.settings:readSetting("grid_scale") or DEFAULT_GRID_SCALE
    self.grid_size = normalizeGridSize(self.settings:readSetting("grid_size") or DEFAULT_GRID_SIZE)
    self.state_file = DataStorage:getSettingsDir() .. "/wordsearch_state.json"
    self._cached_state = self:loadBoardState()
    self.ui.menu:registerToMainMenu(self)
end

function WordSearch:addToMainMenu(menu_items)
    menu_items.wordsearch = {
        text = _("Word search"),
        sorting_hint = "tools",
        callback = function()
            self:showGame()
        end,
    }
end

function WordSearch:getWordListPath()
    return self.wordlist_path or DEFAULT_WORDLIST
end

function WordSearch:setWordList(path)
    if not path or path == "" then
        return
    end
    self.wordlist_path = path
    self.settings:saveSetting("wordlist_path", path)
    self.settings:flush()
    self.board = WordSearchBoard:new(self.wordlist_path, { max_words = self.max_words, grid_size = self.grid_size })
    self:saveBoardState()
end

function WordSearch:listWordLists()
    local dir = PLUGIN_PATH .. "/word_lists"
    local entries = {}
    local function addEntry(file)
        local rel_path = "word_lists/" .. file
        local meta = select(1, readWordList(rel_path))
        entries[#entries + 1] = {
            path = rel_path,
            title = meta.title or file,
        }
    end
    if lfs.attributes(dir, "mode") == "directory" then
        for file in lfs.dir(dir) do
            if file:sub(1, 1) ~= "." and file:sub(-4) == ".txt" then
                addEntry(file)
            end
        end
    end
    table.sort(entries, function(a, b) return a.title < b.title end)
    if #entries == 0 then
        entries[#entries + 1] = { path = DEFAULT_WORDLIST, title = _("Default list") }
    end
    return entries
end

function WordSearch:getBoard()
    if not self.board then
        local state = self._cached_state
        if state and state.wordlist_path == self:getWordListPath() then
            local state_grid_size = normalizeGridSize(state.grid_size or DEFAULT_GRID_SIZE)
            if state_grid_size == self.grid_size then
                self.board = WordSearchBoard:new(self:getWordListPath(), {
                    max_words = state.max_words or self.max_words,
                    grid_size = self.grid_size,
                    state = state.board,
                })
                self.max_words = state.max_words or self.max_words
                self.grid_scale = state.grid_scale or self.grid_scale
            end
        end
        if not self.board then
            self.board = WordSearchBoard:new(self:getWordListPath(), { max_words = self.max_words, grid_size = self.grid_size })
        end
    end
    return self.board
end

function WordSearch:showGame()
    if self.screen then
        return
    end
    self.screen = WordSearchScreen:new{
        plugin = self,
    }
    UIManager:show(self.screen)
    self:saveBoardState()
end

function WordSearch:onScreenClosed()
    self.screen = nil
    self:saveBoardState()
end

function WordSearch:getMaxWords()
    return self.max_words or DEFAULT_MAX_WORDS
end

function WordSearch:setMaxWords(count)
    count = math.max(4, math.min(24, math.floor(count or DEFAULT_MAX_WORDS)))
    if self.max_words == count then
        return
    end
    self.max_words = count
    self.settings:saveSetting("max_words", count)
    self.settings:flush()
    if self.board then
        self.board.max_words = count
    end
    self:saveBoardState()
end

function WordSearch:getGridSize()
    return self.grid_size or DEFAULT_GRID_SIZE
end

function WordSearch:setGridSize(size)
    size = normalizeGridSize(size)
    if self.grid_size == size then
        return
    end
    self.grid_size = size
    self.settings:saveSetting("grid_size", size)
    self.settings:flush()
    self.board = WordSearchBoard:new(self:getWordListPath(), { max_words = self.max_words, grid_size = self.grid_size })
    self:saveBoardState()
end

function WordSearch:saveBoardState()
    if not self.board then
        return
    end
    local payload = {
        version = 1,
        wordlist_path = self.wordlist_path,
        max_words = self.max_words,
        grid_scale = self.grid_scale,
        grid_size = self.grid_size,
        board = self.board:serializeState(),
    }
    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        logger.err("WordSearch: failed to encode state", encoded)
        return
    end
    local file = io.open(self.state_file, "w")
    if not file then
        logger.err("WordSearch: cannot write state file", self.state_file)
        return
    end
    file:write(encoded)
    file:close()
    self._cached_state = payload
end

function WordSearch:loadBoardState()
    local file = io.open(self.state_file, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return nil
    end
    local ok, data = pcall(json.decode, content)
    if not ok then
        logger.err("WordSearch: failed to decode state", data)
        return nil
    end
    return data
end

function WordSearch:getGridScale()
    if not GRID_SCALES[self.grid_scale] then
        self.grid_scale = DEFAULT_GRID_SCALE
    end
    return self.grid_scale
end

function WordSearch:setGridScale(key)
    if not GRID_SCALES[key] then
        return
    end
    if self.grid_scale == key then
        return
    end
    self.grid_scale = key
    self.settings:saveSetting("grid_scale", key)
    self.settings:flush()
    self:saveBoardState()
end

return WordSearch
