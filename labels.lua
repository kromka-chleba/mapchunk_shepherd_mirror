--[[
    This is a part of "Mapchunk Shepherd".
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

--[[
    Labels are lua objects that store metadata that describes a
    mapblock. Each label has a tag (see tags.lua) which is a string
    that describes contents or a property of the mapblock and a
    timestamp that describes the time of last modification stated in
    seconds since the world was created as returned by
    'core.get_gametime()'. Other types of metadata could be
    supported in the future.

    Multiple labels can be assigned to a mapblock in mod storage - the
    lua object gets encoded/serialized in a specific way. Using the
    below 'label' class only affects lua objects, for modifying the
    state of a mapblock you need to use 'label_store' (see label_store.lua).
--]]

ms.label = {}
local label = ms.label
label.__index = ms.label

-- Table for label utility functions.
-- Contains helper functions for working with labels, such as
-- ms.labels.oldest_elapsed_time() for finding the oldest label age.
-- Use ms.label for creating and manipulating individual label objects,
-- and ms.labels for batch operations and utilities.
ms.labels = {}

-- Checks if the tag was registered, asserts if not.
local function check_tag(tag)
    assert(ms.tag.check(tag),
           string.format(
               "Mapchunk Shepherd:"..
               "Trying to create a label with tag '%s', "..
               "which is not a registered tag.", tag))
end

-- Creates an instance of the 'label' class. 'tag' is a label tag
-- string that was registered with 'ms.tag.register'. The label gets a
-- timestamp with current game time.
function label.new(tag)
    check_tag(tag)
    local l = {}
    l.name = tag
    l.timestamp = core.get_gametime()
    return setmetatable(l, label)
end

-- Creates an instance of the 'label' class using a "raw" label format
-- used in mod storage. 'raw' is a table as returned by 'label:format'.
function label.from_raw(raw)
    local l = {}
    l.name = raw[1]
    l.timestamp = raw[2]
    return setmetatable(l, label)
end

-- Formats a label to the "raw" label format used in mod storage.
-- Returns the formatted label object.
function label:format()
    return {self.name, self.timestamp}
end

-- Updates the label's timestamp to the
function label:refresh_timestamp()
    self.timestamp = core.get_gametime()
end

-- Gets the elapsed time since the label had it's timestamp changed
-- (creation/modification).
function label:elapsed_time()
    return core.get_gametime() - self.timestamp
end

-- Returns a short formatted note for the label (its name and
-- timestamp). This is used for shepherd /chunk_labels command.
function label:description()
    return string.format("{%s, %s}", self.name, self.timestamp)
end

-- Encodes label/labels into the mod storage string format. '...' is a
-- list of labels (either a table or an unpacked table). Returns a
-- serialized string with encoded labels.
function label.encode(...)
    local labels = ms.unpack_args(...)
    local formatted = {}
    for _, lab in pairs(labels) do
        table.insert(formatted, lab:format())
    end
    return core.serialize(formatted)
end

-- Decodes 'encoded' - the serialized label string from mod storage
-- into objects of the 'label' class. Returns a table of label
-- objects. Or an emtpy table if there were no labels.
function label.decode(encoded)
    local raw_labels = core.deserialize(encoded) or {}
    local labels = {}
    for _, raw in ipairs(raw_labels) do
        table.insert(labels, ms.label.from_raw(raw))
    end
    return labels
end

-- Helper function to get labels for a block
function ms.get_labels(blockpos)
    local ls = ms.label_store.new(blockpos)
    return ls:get_labels()
end

-- Returns the oldest elapsed time from a list of labels that match given tags
function ms.labels.oldest_elapsed_time(labels, tags)
    if not labels or #labels == 0 then
        return 0
    end
    local oldest_time = 0
    for _, label in pairs(labels) do
        for _, tag in pairs(tags) do
            if label.name == tag then
                local elapsed = label:elapsed_time()
                if elapsed > oldest_time then
                    oldest_time = elapsed
                end
            end
        end
    end
    return oldest_time
end
