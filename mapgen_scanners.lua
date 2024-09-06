--[[
    This is a part of "Perfect City".
    Copyright (C) 2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
--]]

-- Globals
local ms = mapchunk_shepherd

ms.mapgen_watchdog = {}
local mapgen_watchdog = ms.mapgen_watchdog
mapgen_watchdog.__index = mapgen_watchdog

local private = setmetatable({}, {__mode = "k"})

function mapgen_watchdog.new(hash)
    local w = setmetatable({}, mapgen_watchdog)
    w.hash = hash
    w.scanners = {}
    w.added_labels = {}
    w.removed_labels = {}
    w:reset_labels()
    private[w] = {}
    return w
end

function mapgen_watchdog:reset_labels()
    self.added_labels = {}
    self.removed_labels = {}
end

local function convert_labels(labels)
    local converted = {}
    for k, v in pairs(labels) do
        table.insert(converted, k)
    end
    return converted
end

function mapgen_watchdog:save_gen_notify()
    local added_labels = convert_labels(self.added_labels)
    local removed_labels = convert_labels(self.removed_labels)
    local gennotify = minetest.get_mapgen_object("gennotify")
    local obj = gennotify.custom["mapchunk_shepherd:labeler"] or {}
    local change = {
        self.hash,
        added_labels,
        removed_labels,
    }
    table.insert(obj, change)
    minetest.save_gen_notify("mapchunk_shepherd:labeler", obj)
end

-- Allows functions to accept both normal tables and multiple unpacked arguments.
local function validate_input(...)
    local args = {...}
    if type(args[1]) == "table" then
        return args[1]
    end
    return args
end

function mapgen_watchdog:push_added_labels(...)
    local labels = validate_input(...)
    for _, label in ipairs(labels) do
        self.added_labels[label] = true
    end
end

function mapgen_watchdog:push_removed_labels(...)
    local labels = validate_input(...)
    for _, label in ipairs(labels) do
        self.removed_labels[label] = true
    end
end

function mapgen_watchdog:pop_added_labels(...)
    local labels = validate_input(...)
    for _, label in ipairs(labels) do
        self.added_labels[label] = nil
    end
end

function mapgen_watchdog:pop_removed_labels(...)
    local labels = validate_input(...)
    for _, label in ipairs(labels) do
        self.removed_labels[label] = nil
    end
end

function mapgen_watchdog:set_hash(hash)
    self.hash = hash
    self:reset_labels()
end

-- Adds multiple scanner functions given by '...' into the mapgen
-- watchdog instance.  Each scanner function has to be a function that
-- takes two arguments - 'hash' that is the mapchunk hash and
-- 'mapgen_args' - a table of arguments {'vm', 'minp', 'maxp',
-- 'blockseed'} obtained from 'minetest.register_on_generated'. 'func'
-- returns two tables: 'added_labels', 'removed_labels' that contain
-- respectively labels that should be added to the mapchunk and labels
-- that should be removed from it.
function mapgen_watchdog:add_scanners(...)
    local scanners = validate_input(...)
    for _, func in ipairs(scanners) do
        if not private[self][func] then
            -- make sure only unique scanners get registered
            table.insert(self.scanners, func)
            private[self][func] = func
        end
    end
end

function mapgen_watchdog:run_scanners(mapgen_args)
    for _, scanner in ipairs(self.scanners) do
        local added_labels, removed_labels = scanner(self.hash, mapgen_args)
        self:push_added_labels(added_labels)
        self:push_removed_labels(removed_labels)
    end
end

local biome_finders = {}

function ms.create_biome_finder(args)
    local args = table.copy(args)
    local biome_list = args.biome_list
    local added_labels = args.add_labels or {}
    local removed_labels = args.remove_labels or {}
    table.insert(
        biome_finders, 
        function(hash, mapgen_args)
            local vm, minp, maxp, blockseed = unpack(mapgen_args)
            local biomemap = minetest.get_mapgen_object("biomemap")
            local present_biomes = {}
            for i = 1, #biomemap do
                present_biomes[biomemap[i]] = true
            end
            for _, biome in pairs(biome_list) do
                local id = minetest.get_biome_id(biome)
                if present_biomes[id] then
                    return added_labels, removed_labels
                end
            end
        end
    )
end

local main_watchdog = mapgen_watchdog.new()

local function mapgen_scanner(vm, minp, maxp, blockseed)
    local mapgen_args = {vm, minp, maxp, blockseed}
    local t1 = minetest.get_us_time()
    local hash = ms.mapchunk_hash(minp)
    main_watchdog:set_hash(hash)
    main_watchdog:add_scanners(biome_finders)
    main_watchdog:run_scanners(mapgen_args)
    main_watchdog:save_gen_notify()
    --minetest.log("error", string.format("elapsed time: %g ms", (minetest.get_us_time() - t1) / 1000))
end

minetest.register_on_generated(mapgen_scanner)
