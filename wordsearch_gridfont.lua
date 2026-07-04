-- Pure, dependency-free helpers for sizing grid letters to their cell.
-- No KOReader requires here so this stays unit-testable with a plain Lua
-- interpreter.
local GridFont = {}

GridFont.FONT_SIZE_LEVELS = {
    small  = { key = "small",  fill = 0.50 },
    medium = { key = "medium", fill = 0.65 },
    large  = { key = "large",  fill = 0.80 },
}
GridFont.FONT_SIZE_ORDER = { "small", "medium", "large" }
GridFont.DEFAULT_FONT_SIZE = "medium"
GridFont.MIN_FONT_SIZE = 6

function GridFont.normalizeFontSize(key)
    if key and GridFont.FONT_SIZE_LEVELS[key] then
        return key
    end
    return GridFont.DEFAULT_FONT_SIZE
end

function GridFont.getFill(key)
    local level = GridFont.FONT_SIZE_LEVELS[GridFont.normalizeFontSize(key)]
    return level.fill
end

-- Largest integer size, starting from floor(cell_inner*fill) and shrinking by
-- 1, whose measured glyph box (widest/tallest glyph, in device pixels) fits
-- within cell_inner. min_size is a hard lower bound: if no size down to and
-- including min_size fits, min_size is returned (and may still overflow the
-- cell — callers must keep min_size small enough that this only happens for
-- pathologically tiny cells). measure(size) must return (glyph_w, glyph_h).
function GridFont.computeFontSize(measure, cell_inner, fill, min_size)
    min_size = min_size or GridFont.MIN_FONT_SIZE
    local size = math.max(min_size, math.floor(cell_inner * fill))
    while true do
        local w, h = measure(size)
        if w <= cell_inner and h <= cell_inner then
            return size
        end
        if size <= min_size then
            return size
        end
        size = size - 1
    end
end

return GridFont
