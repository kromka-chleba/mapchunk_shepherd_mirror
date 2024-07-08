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

-- Labels are binary flags stored in 48-bit ints.
-- This means you can register up to 48 labels.
-- Each label is identified by its name or 1-48 number
-- Changing label meaning between releases may break
-- mapchunk record on existing worlds so it is
-- not recommended.

-- Globals
local ms = mapchunk_shepherd
ms.labels = {}

local registered_labels = {}

function ms.labels.get_registered()
    return table.copy(registered_labels)
end

function ms.labels.is_label(name)
    if registered_labels[name] then
        return true
    end
    return false
end

function ms.labels.register(name)
    if registered_labels[name] then
        minetest.log("error", "Mapchunk shepherd: Label with name \""..name.."\" already exists!")
        return
    else
        registered_labels[name] = {name = name}
    end
end

function ms.labels.is_valid(labels)
    for _, label in pairs(labels) do
        if not ms.labels.is_label(label) then
            minetest.log("error", "Mapchunk shepherd: "..label.." is not a valid label!")
            return false
        end
    end
    return true
end

function ms.labels.add_timestamp(labels)
    local labels = table.copy(labels)
    local with_timestamp = {}
    local time = minetest.get_gametime()
    for _, label in pairs(labels) do
        table.insert(with_timestamp, {label, time})
    end
    return with_timestamp
end

function ms.labels.encode(labels_with_timestamp)
    local to_encode = {}
    for _, label in pairs(labels_with_timestamp) do
        local name = label[1]
        -- Only uses valid labels
        if ms.labels.is_valid({name}) then
            table.insert(to_encode, label)
        else
            minetest.log("error", "Mapchunk shepherd: Label \""..name.."\" is not a valid label!")
        end
    end
    return minetest.serialize(to_encode)
end

function ms.labels.decode(encoded)
    return minetest.deserialize(encoded)
end

-- Checks if table labels1 contains all labels from labels2
function ms.labels.contains(labels1, labels2)
    if #labels2 == 0 then
        return true
    end
    for _, label2 in pairs(labels2) do
        local pass = false
        for _, label1 in pairs(labels1) do
            if label1 == label2 then
                pass = true
                break
            end
        end
        if not pass then
            return false
        end
    end
    return true
end

function ms.labels.has_one_of(labels1, labels2)
    if #labels2 == 0 then
        return true
    end
    for _, label2 in pairs(labels2) do
        for _, label1 in pairs(labels1) do
            if label1 == label2 then
                return true
            end
        end
    end
    return false
end

local function get_paired_labels(labels)
    local paired = {}
    for _, label in pairs(labels) do
        local name = label[1]
        if not name then
	   minetest.log("error", dump(labels))
	else
	   paired[name] = label
	end
    end
    return paired
end

function ms.labels.delete_duplicates(old_labels, new_labels)
    local old_labels = table.copy(old_labels)
    local new_labels = table.copy(new_labels)
    local paired_old = get_paired_labels(old_labels)
    local paired_new = get_paired_labels(new_labels)
    local clean = {}
    for name, old_label in pairs(paired_old) do
        if not paired_new[name] then
            table.insert(clean, old_label)
        end
    end
    for _, new_label in pairs(paired_new) do
        table.insert(clean, new_label)
    end
    return clean
end

function ms.labels.remove(old_labels, removed_labels)
    local old_labels = table.copy(old_labels)
    local removed_labels = table.copy(removed_labels)
    local paired_old = get_paired_labels(old_labels)
    --local paired_removed = get_paired_labels(removed_labels)
    local clean = {}
    for _, name in pairs(removed_labels) do
        if paired_old[name] then
            paired_old[name] = nil
        end
    end
    for _, label in pairs(paired_old) do
        table.insert(clean, label)
    end
    return clean
end

function ms.labels.extract_names(labels)
    table.copy(labels)
    local label_names = {}
    for _, label in pairs(labels) do
        local name = label[1]
        table.insert(label_names, name)
    end
    return label_names
end

function ms.labels.time_elapsed(label)
    local time = label[2]
    return minetest.get_gametime() - time
end

function ms.labels.oldest_elapsed_time(all_labels, needed_names)
    local elapsed = 0
    for _, name in pairs(needed_names) do
        for _, label in pairs(all_labels) do
            if label[1] == name then
                local t = ms.labels.time_elapsed(label)
                if t > elapsed then
                    -- by default picking time of the oldest label
                    elapsed = t
                end
            end
        end
    end
    return elapsed
end

ms.labels.register("chunk_tracked")
ms.labels.register("scanned")
ms.labels.register("scanner_failed")
ms.labels.register("worker_failed")
ms.labels.register("mapgen_scanned")
