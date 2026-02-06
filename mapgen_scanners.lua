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

-- Cached biomemap data for current mapchunk to avoid redundant processing
-- Reset for each mapchunk in mapgen_scanner
local cached_biomemap_data = nil

-- Creates a biome finder function that labels mapblocks during mapgen.
-- Detects specific biomes in generated mapchunks and adds labels to mapblocks.
--
-- IMPORTANT: The biomemap from core.get_mapgen_object("biomemap") covers the
-- ENTIRE mapchunk (typically 80x80x80 nodes), not just one mapblock (16x16x16).
-- This function checks if any of the target biomes exist anywhere in the mapchunk,
-- and if so, applies labels to ALL mapblocks in that mapchunk.
--
-- OPTIMIZATION: Since the biomemap is the same for all mapblocks in a mapchunk,
-- we cache it at the mapchunk level to avoid redundant processing.
--
-- For more precise per-mapblock biome detection, you would need to:
-- 1. Calculate which portion of the biomemap corresponds to each mapblock
-- 2. Check only that portion for the target biomes
-- (This is not currently implemented)
--
-- args: Configuration table:
--   - biome_list (table): List of biome names to detect
--   - add_labels (table): Labels to add when biome is found
--   - remove_labels (table): Labels to remove when biome is found
function ms.create_biome_finder(args)
    local args = table.copy(args)
    local biome_list = args.biome_list
    local added_labels = args.add_labels or {}
    local removed_labels = args.remove_labels or {}
    
    -- Pre-convert biome names to IDs once at registration time
    -- This avoids repeated core.get_biome_id() calls during mapgen
    local biome_ids = {}
    for _, biome in pairs(biome_list) do
        table.insert(biome_ids, core.get_biome_id(biome))
    end
    
    table.insert(
        biome_finders, 
        function(blockpos, mapgen_args)
            -- Use cached biomemap data if available (set per mapchunk)
            local present_biomes = cached_biomemap_data
            
            if not present_biomes then
                -- Should never happen if mapgen_scanner sets it properly
                local vm, minp, maxp, blockseed = unpack(mapgen_args)
                local biomemap = core.get_mapgen_object("biomemap")
                present_biomes = {}
                for i = 1, #biomemap do
                    present_biomes[biomemap[i]] = true
                end
            end
            
            -- Check if any of our target biomes are present (using pre-converted IDs)
            for _, biome_id in ipairs(biome_ids) do
                if present_biomes[biome_id] then
                    return added_labels, removed_labels
                end
            end
        end
    )
end

-- Main mapgen watchdog instance for coordinating scanners.
-- Initialized with dummy blockpos, will be set properly during mapgen.
local main_watchdog = mapgen_watchdog.new({x=0, y=0, z=0})

-- Mapgen scanner callback that runs all registered scanners on generated mapchunks.
-- Called automatically by Luanti during mapgen.
-- vm: VoxelManip object for the generated mapchunk area.
-- minp: Minimum position of the generated mapchunk (in nodes).
-- maxp: Maximum position of the generated mapchunk (in nodes).
-- blockseed: Seed for this mapchunk.
--
-- IMPORTANT: on_generated returns a MAPCHUNK (typically 5x5x5 mapblocks = 80x80x80 nodes),
-- NOT a single mapblock! We need to iterate over all mapblocks in the mapchunk
-- and process each one separately, since our system works on a per-mapblock basis.
local function mapgen_scanner(vm, minp, maxp, blockseed)
    local mapgen_args = {vm, minp, maxp, blockseed}
    local t1 = core.get_us_time()
    
    -- Get biomemap for the entire mapchunk once and cache it
    -- The biomemap covers the whole mapchunk, not just one mapblock
    -- This is used by biome finders to avoid redundant processing
    local biomemap = core.get_mapgen_object("biomemap")
    if biomemap then
        -- Build present_biomes set once for the entire mapchunk
        cached_biomemap_data = {}
        for i = 1, #biomemap do
            cached_biomemap_data[biomemap[i]] = true
        end
    else
        cached_biomemap_data = nil
    end
    
    -- Calculate mapblock boundaries within the mapchunk
    local minblock = ms.units.mapblock_coords(minp)
    local maxblock = ms.units.mapblock_coords(maxp)
    
    -- Iterate over all mapblocks in the mapchunk
    for z = minblock.z, maxblock.z do
        for y = minblock.y, maxblock.y do
            for x = minblock.x, maxblock.x do
                local blockpos = {x = x, y = y, z = z}
                main_watchdog:set_blockpos(blockpos)
                main_watchdog:add_scanners(biome_finders)
                main_watchdog:run_scanners(mapgen_args)
                main_watchdog:save_gen_notify()
            end
        end
    end
    
    -- Clear cache after processing mapchunk
    cached_biomemap_data = nil
    
    --core.log("error", string.format("elapsed time: %g ms", (core.get_us_time() - t1) / 1000))
end

core.register_on_generated(mapgen_scanner)
