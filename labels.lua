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

ms.label = {}
local label = ms.label
label.__index = ms.label

local function check_tag(tag)
    assert(ms.tag.check(tag),
           string.format(
               "Mapchunk Shepherd:"..
               "Trying to create a label with tag '%s', "..
               "which is not a registered tag.", tag))
end

-- Creates an instance of the 'label' class. 'tag' is a label tag
-- string registered that was registered with 'ms.tag.register'.
function label.new(tag)
    check_tag(tag)
    local l = {}
    l.name = tag
    l.timestamp = minetest.get_gametime()
    return setmetatable(l, label)
end

-- Creates an instance of the 'label' class using a "raw" label format
-- used in mod storage.
function label.from_raw(raw)
    local l = {}
    l.name = raw[1]
    l.timestamp = raw[2]
    return setmetatable(l, label)
end

-- Formats a label to the "raw" label mod storage format.
function label:format()
    return {self.name, self.timestamp}
end

function label:refresh_timestamp()
    self.timestamp = minetest.get_gametime()
end

function label:elapsed_time()
    return minetest.get_gametime() - self.timestamp
end

function label:description()
    return string.format("{%s, %s}", self.name, self.timestamp)
end

function label.encode(...)
    local labels = ms.unpack_args(...)
    local formatted = {}
    for _, lab in pairs(labels) do
        table.insert(formatted, lab:format())
    end
    return minetest.serialize(formatted)
end

function label.decode(encoded)
    return minetest.deserialize(encoded) or {}
end
