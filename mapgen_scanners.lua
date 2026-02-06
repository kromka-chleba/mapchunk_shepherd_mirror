--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2023-2024 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

-- Inherit methods from the 'ms.label_store' class.
function mapgen_watchdog.__index(object, key)
    if mapgen_watchdog[key] then
        return mapgen_watchdog[key]
    elseif ms.label_store[key] then
        return ms.label_store[key]
    end
end

local private = setmetatable({}, {__mode = "k"})

function mapgen_watchdog.new(blockpos)
    local w = ms.label_store.new(blockpos)
    w.scanners = {}
    private[w] = {}
    return setmetatable(w, mapgen_watchdog)
end

-- Adds multiple scanner functions given by '...' into the mapgen
-- watchdog instance.  Each scanner function has to be a function that
-- takes two arguments - 'blockpos' (mapblock position)
-- and 'mapgen_args' - a table of arguments {'vm', 'minp', 'maxp',
-- 'blockseed'} obtained from 'core.register_on_generated'. 'func'
-- returns two tables: 'added_labels', 'removed_labels' that contain
-- respectively labels that should be added to the mapblock and labels
-- that should be removed from it.
function mapgen_watchdog:add_scanners(...)
    local scanners = ms.unpack_args(...)
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
        local added_labels, removed_labels = scanner(self.blockpos, mapgen_args)
        self:mark_for_addition(added_labels)
        self:mark_for_removal(removed_labels)
    end
end

local biome_finders = {}

-- Creates a biome finder function that labels mapblocks during mapgen.
-- Detects specific biomes in generated mapblocks and adds labels.
-- args: Configuration table:
--   - biome_list (table): List of biome names to detect
--   - add_labels (table): Labels to add when biome is found
--   - remove_labels (table): Labels to remove when biome is found
function ms.create_biome_finder(args)
    local args = table.copy(args)
    local biome_list = args.biome_list
    local added_labels = args.add_labels or {}
    local removed_labels = args.remove_labels or {}
    table.insert(
        biome_finders, 
        function(blockpos, mapgen_args)
            local vm, minp, maxp, blockseed = unpack(mapgen_args)
            local biomemap = core.get_mapgen_object("biomemap")
            local present_biomes = {}
            for i = 1, #biomemap do
                present_biomes[biomemap[i]] = true
            end
            for _, biome in pairs(biome_list) do
                local id = core.get_biome_id(biome)
                if present_biomes[id] then
                    return added_labels, removed_labels
                end
            end
        end
    )
end

-- Main mapgen watchdog instance for coordinating scanners.
-- Initialized with dummy blockpos, will be set properly during mapgen.
local main_watchdog = mapgen_watchdog.new({x=0, y=0, z=0})

-- Mapgen scanner callback that runs all registered scanners on generated mapblocks.
-- Called automatically by Luanti during mapgen.
-- vm: VoxelManip object for the generated area.
-- minp: Minimum position of the generated area.
-- maxp: Maximum position of the generated area.
-- blockseed: Seed for this mapblock.
local function mapgen_scanner(vm, minp, maxp, blockseed)
    local mapgen_args = {vm, minp, maxp, blockseed}
    local t1 = core.get_us_time()
    local blockpos = ms.units.mapblock_coords(minp)
    main_watchdog:set_blockpos(blockpos)
    main_watchdog:add_scanners(biome_finders)
    main_watchdog:run_scanners(mapgen_args)
    main_watchdog:save_gen_notify()
    --core.log("error", string.format("elapsed time: %g ms", (core.get_us_time() - t1) / 1000))
end

core.register_on_generated(mapgen_scanner)
