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

local mod_storage = minetest.get_mod_storage()
local modpath = minetest.get_modpath('mapchunk_shepherd')
local dimensions = dofile(modpath.."/chunk_dimensions.lua")

local mapchunk_offset = dimensions.mapchunk_offset
local chunk_side = dimensions.chunk_side
local old_chunksize = mod_storage:get_int("chunksize")
local blocks_per_chunk = dimensions.blocks_per_chunk

function ms.chunk_side()
    return chunk_side
end

-- Converts node coordinates to mapchunk coordinates
function ms.node_pos_to_mapchunk_pos(pos)
    pos = vector.subtract(pos, mapchunk_offset)
    pos = vector.divide(pos, chunk_side)
    pos = vector.floor(pos)
    return pos
end

-- A global function to get hash from pos
function ms.mapchunk_hash(pos)
    pos = ms.node_pos_to_mapchunk_pos(pos)
    pos = vector.multiply(pos, chunk_side)
    pos = vector.add(pos, mapchunk_offset)
    return minetest.hash_node_position(pos)
end

function ms.save_time(hash)
    local time = minetest.get_gametime()
    mod_storage:set_int(hash.."_time", time)
end

function ms.reset_time(hash)
    mod_storage:set_int(hash"_time", 0)
end

function ms.time_since_last_change(hash)
    local current_time = minetest.get_gametime()
    return current_time - mod_storage:get_int(hash.."_time")
end

-- A global function to get mapchunk borders
function ms.mapchunk_borders(hash)
    local pos_min = minetest.get_position_from_hash(hash)
    local pos_max = vector.add(pos_min, chunk_side - 1)
    return pos_min, pos_max
end

function ms.chunksize_changed()
    if old_chunksize == 0 then
        mod_storage:set_int("chunksize", blocks_per_chunk)
        return false
    elseif old_chunksize ~= blocks_per_chunk then
        return true
    else
        return false
    end
end

local function bump_counter()
    local counter = mod_storage:get_int("counter")
    counter = counter + 1
    mod_storage:set_int("counter", counter)
end

local function debump_counter()
    local counter = mod_storage:get_int("counter")
    counter = counter - 1
    if counter < 0 then
        counter = 0
    end
    mod_storage:set_int("counter", counter)
end

function ms.tracked_chunk_counter()
    return mod_storage:get_int("counter")
end

function ms.labels_to_position(pos, labels_to_add, labels_to_remove)
    local hash = ms.mapchunk_hash(pos)
    local ls = ms.label_store.new(hash)
    ls:add_labels(labels_to_add)
    ls:remove_labels(labels_to_remove)
    ls:save_to_disk()
end
