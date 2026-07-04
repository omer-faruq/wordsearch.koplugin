-- Plain-Lua unit test (no busted, no KOReader deps).
-- Run from the plugin dir:  lua tests/test_wordsearch_gridfont.lua
package.path = "./?.lua;" .. package.path
local GridFont = require("wordsearch_gridfont")

local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

-- normalizeFontSize
check(GridFont.normalizeFontSize("small") == "small", "known key kept")
check(GridFont.normalizeFontSize("bogus") == "medium", "unknown -> medium")
check(GridFont.normalizeFontSize(nil) == "medium", "nil -> medium")

-- getFill
check(GridFont.getFill("large") == 0.80, "large fill = 0.80")
check(GridFont.getFill("bogus") == 0.65, "bogus fill -> medium 0.65")

-- computeFontSize: simulate DPI double-scaling where a glyph is 1.8x the
-- passed size tall and 0.6x wide. cell_inner=60, fill=0.80 -> start=48.
-- Must shrink until 1.8*size <= 60  => size <= 33 (33*1.8=59.4).
local function measure(size) return size * 0.6, size * 1.8 end
local s = GridFont.computeFontSize(measure, 60, 0.80, 6)
check(s == 33, "computeFontSize shrinks to 33, got " .. tostring(s))
local w, h = measure(s)
check(h <= 60, "fitted glyph height <= cell_inner, got " .. h)
check(w <= 60, "fitted glyph width <= cell_inner, got " .. w)

-- Never below min_size, even if nothing fits.
local function huge(size) return size * 100, size * 100 end
check(GridFont.computeFontSize(huge, 60, 0.80, 6) == 6, "clamps to min_size")

-- A glyph that already fits at the start size is not shrunk.
local function tiny(size) return size * 0.1, size * 0.1 end
check(GridFont.computeFontSize(tiny, 60, 0.80, 6) == 48, "no shrink when it fits")

-- FONT_SIZE_ORDER contents and order (the font-size menu iterates this)
check(#GridFont.FONT_SIZE_ORDER == 3, "FONT_SIZE_ORDER has 3 entries")
check(GridFont.FONT_SIZE_ORDER[1] == "small", "order[1] = small")
check(GridFont.FONT_SIZE_ORDER[2] == "medium", "order[2] = medium")
check(GridFont.FONT_SIZE_ORDER[3] == "large", "order[3] = large")

if failures == 0 then
    print("ALL TESTS PASSED")
    os.exit(0)
else
    print(failures .. " TEST(S) FAILED")
    os.exit(1)
end
