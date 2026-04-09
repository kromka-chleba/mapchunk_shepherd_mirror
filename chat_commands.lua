--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2026 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

-- Internationalization
local S = mapchunk_shepherd.S

-- Globals
local ms = mapchunk_shepherd

local function serialize_worker_names(workers)
    local names = {}
    for _, worker in pairs(workers) do
        table.insert(names, worker.name)
    end
    local serialized = core.serialize(names)
    return serialized:gsub("return ", "")
end

local function labels_to_string(labels)
    local descriptions = {}
    for _, label in pairs(labels) do
        table.insert(descriptions, label:description())
    end
    if #descriptions == 0 then
        return ""
    end
    return table.concat(descriptions, ", ")..", "
end

local function parse_label_command_param(param)
    local tag, target_hash = (param or ""):match("^%s*(%S+)%s*(%S*)%s*$")
    if not tag or tag == "" then
        return nil, nil, S("Usage: <label> [chunk_hash]")
    end
    return tag, target_hash
end

local function player_chunk_hash(name)
    local player = core.get_player_by_name(name)
    if not player then
        return nil, S("Player not found.")
    end
    local pos = player:get_pos()
    if not pos then
        return nil, S("Could not get player position.")
    end
    return ms.mapchunk_hash(pos)
end

local function parse_label_command_target(name, target_hash)
    if target_hash and target_hash ~= "" then
        return target_hash
    end
    return player_chunk_hash(name)
end

core.register_chatcommand(
    "shepherd_status", {
        description = S("Prints status of the Mapchunk Shepherd."),
        privs = {},
        func = function(name, param)
            local tracked_chunks_status = S("Tracked chunks: ")..
                ms.tracked_chunk_counter()
            local queue_size = ms.get_work_queue_size and ms.get_work_queue_size() or 0
            local work_queue_status = S("Work queue: ")..queue_size
            local workers = ms.get_workers and ms.get_workers() or {}
            local worker_status = S("Workers: ")..serialize_worker_names(workers)
            local min_time = ms.get_min_working_time()
            local max_time = ms.get_max_working_time()
            local median_time = ms.get_median_working_time()
            local average_time = ms.get_average_working_time()
            local time_status = S("Working time: ")..
                S("Min: ")..math.ceil(min_time).." ms | "..
                S("Max: ")..math.ceil(max_time).." ms | "..
                S("Moving median: ")..median_time.." ms | "..
                S("Moving average: ")..average_time.." ms"
            return true, tracked_chunks_status.."\n"..
                work_queue_status.."\n"..time_status.."\n"..
                worker_status.."\n"
        end,
})
core.register_chatcommand(
    "chunk_labels", {
        description = S("Prints labels of the chunk where the player stands."),
        privs = {},
        func = function(name, param)
            local hash, hash_err = player_chunk_hash(name)
            if hash_err then
                return false, hash_err
            end
            local ls = ms.label_store.new(hash)
            local labels = ls:get_labels()
            local last_changed = ms.time_since_last_change(hash)
            return true, S("hash: ")..hash.."\n"
                ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                ..S("labels: ")..labels_to_string(labels).."\n "
        end,
})
core.register_chatcommand(
    "chunk_label_add", {
        description = S("Adds a label to the current chunk (or [chunk_hash])."),
        params = S("<label> [chunk_hash]"),
        privs = {server = true},
        func = function(name, param)
            local tag, target_hash, err = parse_label_command_param(param)
            if err then
                return false, err
            end
            if not ms.tag.check(tag) then
                return false, S("Label is not a registered tag: ")..tag
            end
            local hash, hash_err = parse_label_command_target(name, target_hash)
            if hash_err then
                return false, hash_err
            end
            local ls = ms.label_store.new(hash)
            ls:add_labels(tag)
            ls:save_to_disk()
            return true, S("Added label '")..tag..S("' to chunk ")..hash
        end,
})
core.register_chatcommand(
    "chunk_label_remove", {
        description = S("Removes a label from the current chunk (or [chunk_hash])."),
        params = S("<label> [chunk_hash]"),
        privs = {server = true},
        func = function(name, param)
            local tag, target_hash, err = parse_label_command_param(param)
            if err then
                return false, err
            end
            if not ms.tag.check(tag) then
                return false, S("Label is not a registered tag: ")..tag
            end
            local hash, hash_err = parse_label_command_target(name, target_hash)
            if hash_err then
                return false, hash_err
            end
            local ls = ms.label_store.new(hash)
            ls:remove_labels(tag)
            ls:save_to_disk()
            return true, S("Removed label '")..tag..S("' from chunk ")..hash
        end,
})
core.register_chatcommand(
    "registered_labels", {
        description = S("Lists all registered labels (tags)."),
        privs = {},
        func = function(name, param)
            local tags = ms.tag.get_registered()
            table.sort(tags)
            if #tags == 0 then
                return true, S("No labels are registered.")
            end
            return true, S("Registered labels: ")..table.concat(tags, ", ")
        end,
})
