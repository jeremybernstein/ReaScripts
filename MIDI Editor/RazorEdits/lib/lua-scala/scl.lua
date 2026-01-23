--- Scala tuning file module
--
-- References:
--   http://www.huygens-fokker.org/scala/scl_format.html
--
-- @module scl
--

local io = require('io')
local math = require('math')

---
--- Pitch
---

local Pitch = {}
Pitch.__index = Pitch

--- Create a Pitch ratio object.
--
-- Represents a pitch a ratio relative to a reference frequency. Passing
-- negative values will result in an error.
--
-- @tparam number n Numerator, required.
-- @tparam number d Denominator, defaults to 1.
--
-- @treturn Pitch instance.
function Pitch.new(n, d)
  d = d or 1
  if n < 0 then error("Negative pitch numerator: " .. tostring(n)) end
  if d < 0 then error("Negative pitch denominator: " .. tostring(d)) end
  local o = { n, d }
  return setmetatable(o, Pitch)
end

--- Create a Pitch by parsing scala format pitch notation.
-- @tparam string str Textural pitch notation.
-- @treturn Pitch|nil if unable to parse
function Pitch.parse(str)
  -- try full ratio syntax
  local n, d = string.match(str, "([%d.-]+)%s*/%s*([%d.-]+)")
  if n ~= nil then
    return Pitch.new(tonumber(n), tonumber(d))
  end

  -- try individual number
  local p = string.match(str, "([%d-.]+)")
  if p ~= nil then
    -- determine if in cents or ratio
    if string.find(p, "[.]") ~= nil then
      return Pitch.new(tonumber(p), 1200) -- cents
    end
    return Pitch.new(tonumber(p), 1)
  end

  -- not recognized
  return nil
end

--- Return a string representation of the ratio.
-- @treturn string
function Pitch:__tostring()
  return tostring(self[1]) .. '/' .. tostring(self[2])
end

--- Return the ratio as a decimal number
-- @treturn number
function Pitch:__call()
  return self[1] / self[2]
end

--
-- Scale
--

local Scale = {}
Scale.__index = Scale

--- Create a Scale object given a list of pitches.
-- @tparam {Pitch} pitches List of pitches for each degree in the scale.
-- @tparam string description Description of the scale, defaults to "".
-- @treturn Scale
function Scale.new(pitches, description)
  local o = setmetatable({}, Scale)
  o.degrees = #pitches
  o.pitches = pitches
  o.pitches[0] = Pitch.new(1, 1) -- unison
  o.octave_interval = pitches[o.degrees]()
  o.description = description or ""
  return o
end

--- Create a Scale object from a given set of decimal ratios.
-- @tparam {number|{number,number}} Ratio as decimal or interger pair
-- @treturn Scale
function Scale.of(ratios)
  local pitches = {}
  for _, r in ipairs(ratios) do
    if type(r) == 'table' then
      table.insert(pitches, Pitch.new(r[1], r[2]))
    else
      table.insert(pitches, Pitch.new(r))
    end
  end
  return Scale.new(pitches, ratios.description)
end

local function is_comment(line)
  return string.find(line, "^!")
end

--- Create a Scale by loading a Scala .scl file.
--
-- Invalid scl files will generally result in an error.
--
-- @tparam string path Path to .scl file
-- @treturn Scale
function Scale.load(path)
  local pitches = {}
  local lines = io.lines(path)
  local l = nil

  -- skip initial comments
  repeat l = lines() until not is_comment(l)

  -- header
  local description = l
  local pitch_count = tonumber(lines())

  -- intermediate comments
  repeat l = lines() until not is_comment(l)

  -- pitches
  repeat
    local p = Pitch.parse(l)
    if p ~= nil then
      table.insert(pitches, p)
    end
    l = lines()
  until l == nil

  return Scale.new(pitches, description)
end

--- Create an equal temperment scale with the given number of degrees.
-- @tparam number degrees Number of degrees/steps in the scale
-- @treturn Scale
function Scale.equal_temperment(degrees)
  local pitches = {}
  local interval = 1 / degrees
  for d = 1, degrees do
    pitches[d] = Pitch.new(1 + (d * interval))
  end
  local description = tostring(degrees) .. "-TET"
  return Scale.new(pitches, description)
end

--- Return the Pitch for the given scale degree.
--
-- Negative or positive degree values >= the number of degrees in the scale are
-- wrapped to the pitch within the scale (octave is discarded). For direct
-- access to the pitches themselves index into the pitches property on the
-- instance.
--
-- @tparam number degree
-- @treturn Pitch
function Scale:pitch_class(degree)
  return self.pitches[degree % self.degrees]
end

--- Return the ratio relative to reference frequency for the given degree.
--
-- The ratio will reflect the appropriate octave when given negative or positive
-- degree values greater than the number of degrees in the scale.
--
-- @tparam number degree
-- @treturn number
function Scale:ratio(degree)
  local octave = math.floor(degree / self.degrees)
  local r = self:pitch_class(degree)()
  return (self.octave_interval ^ octave) * r
end

--- Return a table of the pitch classes in decimal ratio form.
-- @treturn {number}
function Scale:as_decimals()
  local rs = {}
  for _, r in ipairs(self.pitches) do
    table.insert(rs, r())
  end
  return rs
end

--
-- Mapping
--

local Mapping = {}
Mapping.__index = Mapping

local DEFAULT_MAPPING = {}
for i=0,11 do table.insert(DEFAULT_MAPPING, i) end

function Mapping.new(props)
  props = props or {}
  local o = setmetatable(props, Mapping)
  o.size = props.size or 12
  o.low = props.low or 0
  o.high = props.high or 127
  o.base = props.base or 60
  o.ref_note = props.ref_note or 69
  o.ref_hz = props.ref_hz or 440.0
  o.map = props.map or DEFAULT_MAPPING
  -- computed?
  o.scale_degree = #o.map -- FIXME: update on mapping change?
  o.baze_hz = 1111
  return o
end

function Mapping.load(path)
end

function Mapping:to_hz(note, scale)
  local degree = (note - self.base) % self.size
  local r = scale.pitches[degree + 1] -- 1's baseds
end

return {
  Scale = Scale,
  Pitch = Pitch,
  Mapping = Mapping,
}

