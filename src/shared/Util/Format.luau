--!strict
--[[
	Format
	Text formatting shared by both places (server and client).

	Format.money(1750)            -> "$1,750"
	Format.duration(372)          -> "6:12"
	Format.clock(use24?, t?)      -> time "4:31 PM" / "16:31", short time "4:31", date "Wed, Oct 7, 2026",
	                                 long date "Wednesday, October 7"
	Format.code(text)             -> letters and digits only, upper case ("7kx-2qd" -> "7KX2QD")
]]

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local LONG_WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local LONG_MONTHS = {
	"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
	"December",
}

local Format = {}

function Format.money(amount: number): string
	local negative = amount < 0
	local text = tostring(math.floor(math.abs(amount)))
	while true do
		local replaced, count = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
		text = replaced
		if count == 0 then
			break
		end
	end
	return (if negative then "-$" else "$") .. text
end

function Format.duration(seconds: number): string
	local whole = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

-- time, short time (no AM/PM), date, long date
function Format.clock(use24: boolean?, at: number?): (string, string, string, string)
	local now = os.date("*t", at) :: any
	local time, short
	if use24 then
		time = string.format("%02d:%02d", now.hour, now.min)
		short = time
	else
		local hour = now.hour % 12
		short = string.format("%d:%02d", if hour == 0 then 12 else hour, now.min)
		time = `{short} {if now.hour < 12 then "AM" else "PM"}`
	end
	local date = string.format("%s, %s %d, %d", WEEKDAYS[now.wday], MONTHS[now.month], now.day, now.year)
	local longDate = `{LONG_WEEKDAYS[now.wday]}, {LONG_MONTHS[now.month]} {now.day}`
	return time, short, date, longDate
end

function Format.code(text: string): string
	return string.upper((string.gsub(text, "[^%w]", "")))
end

return table.freeze(Format)
