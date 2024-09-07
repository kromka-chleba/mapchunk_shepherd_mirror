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

ms.label_store = {}
local label_store = ms.label_store
label_store.__index = label_store

function label_store.new(hash)
    local w = setmetatable({}, label_store)
    w.hash = hash
    w.scanners = {}
    w.added_labels = {}
    w.removed_labels = {}
    w:reset_labels()
    return w
end

function label_store:reset_labels()
    self.added_labels = {}
    self.removed_labels = {}
end

function label_store:set_hash(hash)
    self.hash = hash
    self:reset_labels()
end

-- Allows functions to accept both normal tables and multiple unpacked arguments.
function ms.unpack_args(...)
    local args = {...}
    if type(args[1]) == "table" then
        return args[1]
    end
    return args
end

function label_store:push_added_labels(...)
    local labels = ms.unpack_args(...)
    for _, label in ipairs(labels) do
        self.added_labels[label] = true
    end
end

function label_store:push_removed_labels(...)
    local labels = ms.unpack_args(...)
    for _, label in ipairs(labels) do
        self.removed_labels[label] = true
    end
end

function label_store:pop_added_labels(...)
    local labels = ms.unpack_args(...)
    for _, label in ipairs(labels) do
        self.added_labels[label] = nil
    end
end

function label_store:pop_removed_labels(...)
    local labels = ms.unpack_args(...)
    for _, label in ipairs(labels) do
        self.removed_labels[label] = nil
    end
end
