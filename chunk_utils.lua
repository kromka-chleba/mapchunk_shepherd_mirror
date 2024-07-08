--[[
    This is a part of "Perfect City".
    Copyright (C) 2023 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

-- Mapchunk Shepherd
-- License: GNU GPLv3
-- Copyright © Jan Wielkiewicz 2023

-- Globals
local ms = mapchunk_shepherd

local mod_storage = minetest.get_mod_storage()
local modpath = minetest.get_modpath('mapchunk_shepherd')
local dimensions = dofile(modpath.."/chunk_dimensions.lua")

local mapchunk_offset = dimensions.mapchunk_offset
local chunk_side = dimensions.chunk_side
local old_chunksize = dimensions.old_chunksize
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

function ms.is_tracked(hash)
    local value = mod_storage:get_string(hash)
    local labels = ms.labels.decode(value)
    return labels
end

function ms.get_labels(hash)
    local encoded = mod_storage:get_string(hash)
    if encoded == "" then
        return {}
    end
    local value = minetest.deserialize(encoded)
    if value then
        return value
    else
        minetest.log("error", "Get_labels failed for hash: "..
                     dump(hash).." / "..dump(encoded))
        return {}
    end
end

function ms.add_labels(hash, new_labels)
    -- new_labels - label names without timestamps
    local new_labels = table.copy(new_labels)
    local old_labels = ms.get_labels(hash)
    local to_add = {}
    if ms.labels.is_valid(new_labels) then
        new_labels = ms.labels.add_timestamp(new_labels)
        to_add = ms.labels.delete_duplicates(old_labels, new_labels)
        mod_storage:set_string(hash, ms.labels.encode(to_add))
        ms.save_time(hash)
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

function ms.save_mapchunk(hash, force)
    if not ms.is_tracked(hash) then
        ms.add_labels(hash, {"chunk_tracked"})
        bump_counter()
        ms.save_time(hash)
    end
    if force then
        local label = ms.labels.add_timestamp({"chunk_tracked"})
        mod_storage:set_string(hash, ms.labels.encode(label))
        ms.save_time(hash)
    end
end

-- Clears labels other than "chunk_tracked"
function ms.reset_mapchunk(hash)
    if is_tracked(hash) then
        local label = ms.labels.add_timestamp({"chunk_tracked"})
        mod_storage:set_string(hash, ms.labels.encode(label))
        ms.reset_time(hash)
    end
end

-- Removes the hash from history
function ms.remove_mapchunk(hash)
    if ms.is_tracked(hash) then
        debump_counter()
    end
    mod_storage:set_string(hash, "")
    ms.reset_time(hash)
end

function ms.was_scanned(hash)
    local labels = ms.get_labels(hash)
    local label_names = ms.labels.extract_names(labels)
    return ms.labels.contains(label_names, {"scanned"})
end

function ms.remove_labels(hash, removed_labels)
    -- copy to avoid modifying the table somewhere far far away
    local removed_labels = table.copy(removed_labels)
    local old_labels = ms.get_labels(hash)
    if not ms.is_tracked(hash) then
        minetest.log("error", "Mapchunk shepherd: "..hash.." is not tracked!")
        minetest.log("error", "Mapchunk shepherd: tried to remove labels: "..dump(removed_labels))
        ms.save_mapchunk(hash, true)
        return
    end
    if ms.labels.is_valid(removed_labels) then
        local labels = ms.labels.remove(old_labels, removed_labels)
        mod_storage:set_string(hash, ms.labels.encode(labels))
    end
end

function ms.handle_labels(hash, labels_added, labels_removed)
    if labels_added then
        local labels_added = table.copy(labels_added)
        ms.add_labels(hash, labels_added)
    end
    if labels_removed then
        local labels_removed = table.copy(labels_removed)
        ms.remove_labels(hash, labels_removed)
    end
end

function ms.contains_labels(hash, labels)
    local chunk_labels = ms.get_labels(hash)
    local label_names = ms.labels.extract_names(chunk_labels)
    return ms.labels.contains(label_names, labels)
end

function ms.has_one_of(hash, labels)
    local chunk_labels = ms.get_labels(hash)
    local label_names = ms.labels.extract_names(chunk_labels)
    return ms.labels.has_one_of(label_names, labels)
end

function ms.labels_to_position(pos, labels_to_add, labels_to_remove)
    local hash = ms.mapchunk_hash(pos)
    local labels_to_add = labels_to_add or {}
    local labels_to_remove = labels_to_remove or {}
    if not ms.contains_labels(hash, labels_to_add) then
        ms.save_mapchunk(hash)
        ms.handle_labels(hash, labels_to_add, labels_to_remove)
        ms.add_labels(hash, {"scanned"})
    end
end
