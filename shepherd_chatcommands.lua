--[[
    This is a part of "Mapchunk Shepherd".
    Copyright (C) 2023-2025 Jan Wielkiewicz <tona_kosmicznego_smiecia@interia.pl>

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

local ms = mapchunk_shepherd
local S = ms.S

local function serialize_worker_names(workers)
    local worker_names = {}
    for _, worker in pairs(workers) do
        table.insert(worker_names, worker.name)
    end
    local serialized = core.serialize(worker_names)
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
    local tag, target_hash = param:match("^%s*(%S+)%s*(%S*)%s*$")
    if not tag or tag == "" then
        return nil, nil, S("Usage: <label> [chunk_hash]")
    end
    return tag, target_hash
end

local function parse_label_command_target(name, target_hash)
    if target_hash and target_hash ~= "" then
        return target_hash
    end
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

local function add_chunk_label(hash, tag)
    local ls = ms.label_store.new(hash)
    ls:add_labels(tag)
    ls:save_to_disk()
end

local function remove_chunk_label(hash, tag)
    local ls = ms.label_store.new(hash)
    ls:remove_labels(tag)
    ls:save_to_disk()
end

function ms.register_shepherd_chatcommands(args)
    core.register_chatcommand(
        "shepherd_status", {
            description = S("Prints status of the Mapchunk Shepherd."),
            privs = {},
            func = function(name, param)
                local worker_names = serialize_worker_names(args.get_workers())
                local nr_of_chunks = ms.tracked_chunk_counter()
                local tracked_chunks_status = S("Tracked chunks: ")..nr_of_chunks
                local work_queue_status = S("Work queue: ")..args.get_work_queue_size()
                local work_time_status = S("Working time: ")..
                    S("Min: ")..math.ceil(args.get_min_working_time()).." ms | "..
                    S("Max: ")..math.ceil(args.get_max_working_time()).." ms | "..
                    S("Moving median: ")..args.get_median_working_time().." ms | "..
                    S("Moving average: ")..args.get_average_working_time().." ms"
                local worker_status = S("Workers: ")..worker_names
                return true, tracked_chunks_status.."\n"..
                    work_queue_status.."\n"..work_time_status.."\n"..
                    worker_status.."\n"
            end,
    })

    core.register_chatcommand(
        "chunk_labels", {
            description = S("Prints labels of the chunk where the player stands."),
            privs = {},
            func = function(name, param)
                local player = core.get_player_by_name(name)
                if not player then
                    return false, S("Player not found.")
                end
                local pos = player:get_pos()
                if not pos then
                    return false, S("Could not get player position.")
                end
                local hash = ms.mapchunk_hash(pos)
                local ls = ms.label_store.new(hash)
                local labels = ls:get_labels()
                local last_changed = ms.time_since_last_change(hash)
                local label_string = labels_to_string(labels)
                return true, S("hash: ")..hash.."\n"
                    ..S("last changed: ")..last_changed..S(" seconds ago").."\n"
                    ..S("labels: ")..label_string.."\n "
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
                add_chunk_label(hash, tag)
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
                remove_chunk_label(hash, tag)
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
end
