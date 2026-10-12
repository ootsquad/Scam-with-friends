--[[
	ScamGames (client)
	The mini-games behind the scam apps (ScamConfig.Apps[].Game), one function per kind. Each one draws into
	the game window's Arena with plain GUI objects, runs until ScamGameApp stops it, and keeps reporting how
	well it's going as a share from 0 to 1. They're all easy on purpose: mouse (or one finger) only, big
	targets, and nothing to lose.

	ScamGames[kind](ctx) -> { stop: () -> () }
		ctx = {
			arena = Frame,            -- draw in here (cleared for you afterwards)
			seconds = number,         -- how long the game runs
			random = Random,          -- seeded, so a replay lays out the same
			easier = boolean,         -- Pro and up: bigger targets, slower spawns
			helper = boolean,         -- Elite: a helper that plays along a little
			report = (raw) -> (),     -- how it's going, 0..1 (called whenever it changes)
			done = (raw, perfect) -> (),   -- finish early (the game's over)
			pointer = () -> Vector2,  -- where the mouse / finger is, in the arena's own pixels (before UIScale)
		}
	Everything is laid out in the arena's own pixels (its Size offsets); the desktop's UIScale is divided out
	of screen measurements (scaleOf).
	ScamGames.Kinds -> { string }    every kind here (ScamConfig is checked against it in tests)
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("Ui").Theme)

local ScamGames = {}

type Ctx = {
	arena: Frame,
	seconds: number,
	random: Random,
	easier: boolean,
	helper: boolean,
	report: (number) -> (),
	done: (number, boolean) -> (),
	pointer: () -> Vector2,
}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local COLORS = {
	Color3.fromHex("#2F80ED"), Color3.fromHex("#22C55E"), Color3.fromHex("#F97316"), Color3.fromHex("#DB2777"),
	Color3.fromHex("#8B5CF6"), Color3.fromHex("#EAB308"),
}
local CASH = Color3.fromHex("#1E8E3E")
local INK = Color3.fromHex("#1A1A1A")
local SILVER = Color3.fromHex("#B8BEC6")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(class)
	for key, value in props do
		(instance :: any)[key] = value
	end
	instance.Parent = parent
	return instance
end

local function round(parent: Instance, radius: number)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function label(parent: Instance, text: string, size: number, color: Color3, props: { [string]: any }?): TextLabel
	local out = make("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = text,
		TextSize = size,
		TextColor3 = color,
		FontFace = FONT,
		TextWrapped = true,
	}, parent)
	for key, value in props or {} do
		(out :: any)[key] = value
	end
	return out
end

local function frame(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, radius: number?): Frame
	local out = make("Frame", {
		Name = name,
		Size = size,
		Position = position,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, parent)
	if radius then
		round(out, radius)
	end
	return out
end

local function button(parent: Instance, name: string, size: UDim2, position: UDim2, color: Color3, text: string, radius: number?): TextButton
	local out = make("TextButton", {
		Name = name,
		Size = size,
		Position = position,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Text = text,
		TextSize = 22,
		TextColor3 = Theme.White,
		FontFace = FONT,
		AutoButtonColor = false,
	}, parent)
	if radius then
		round(out, radius)
	end
	return out
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

-- A bag of connections and loops that stop() clears.
local function bag()
	local connections: { RBXScriptConnection } = {}
	local alive = true
	return {
		add = function(connection: RBXScriptConnection)
			table.insert(connections, connection)
		end,
		alive = function()
			return alive
		end,
		-- A loop on Heartbeat with the frame time.
		every = function(fn: (number) -> ())
			table.insert(connections, RunService.Heartbeat:Connect(function(dt)
				if alive then
					fn(dt)
				end
			end))
		end,
		stop = function()
			alive = false
			for _, connection in connections do
				connection:Disconnect()
			end
			connections = {}
		end,
	}
end

-- Pops an element in with a little scale tween.
local function popIn(instance: GuiObject)
	local scale = make("UIScale", { Scale = 0.4 }, instance)
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- The arena in its own pixels (the desktop's UIScale doesn't count).
local function arenaSize(ctx: Ctx): Vector2
	local size = ctx.arena.Size
	if size.X.Offset < 10 or size.Y.Offset < 10 then
		return Vector2.new(728, 360)
	end
	return Vector2.new(size.X.Offset, size.Y.Offset)
end

-- Screen pixels per arena pixel.
local function scaleOf(arena: GuiObject): number
	local wanted = arena.Size.X.Offset
	local actual = arena.AbsoluteSize.X
	if wanted <= 0 or actual <= 0 then
		return 1
	end
	return actual / wanted
end

local function centreAt(instance: GuiObject, position: Vector2)
	instance.AnchorPoint = Vector2.new(0.5, 0.5)
	instance.Position = UDim2.fromOffset(position.X, position.Y)
end

-- An element's centre in the arena's own pixels.
local function centreOf(instance: GuiObject, arena: GuiObject): Vector2
	return (instance.AbsolutePosition - arena.AbsolutePosition + instance.AbsoluteSize / 2) / scaleOf(arena)
end

local function overlaps(a: GuiObject, b2: GuiObject): boolean
	local ap, as = a.AbsolutePosition, a.AbsoluteSize
	local bp, bs = b2.AbsolutePosition, b2.AbsoluteSize
	return ap.X < bp.X + bs.X and bp.X < ap.X + as.X and ap.Y < bp.Y + bs.Y and bp.Y < ap.Y + as.Y
end

-- Drags `handle` with the pointer while it's held. onMove(position) with the handle's centre in arena pixels,
-- onDrop() when let go.
local function draggable(ctx: Ctx, b, handle: GuiObject, onMove: (Vector2) -> (), onDrop: (() -> ())?)
	local dragging = false
	local offset = Vector2.zero
	b.add(handle.InputBegan:Connect(function(input)
		if isPress(input) then
			dragging = true
			offset = centreOf(handle, ctx.arena) - ctx.pointer()
		end
	end))
	b.add(UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then
			onMove(ctx.pointer() + offset)
		end
	end))
	b.add(UserInputService.InputEnded:Connect(function(input)
		if dragging and isPress(input) then
			dragging = false
			if onDrop then
				onDrop()
			end
		end
	end))
end

-- ---------------------------------------------------------------------------
-- 1. Card Swiper: slide the card through the slot
-- ---------------------------------------------------------------------------

function ScamGames.Swipe(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local terminal = frame(ctx.arena, "Terminal", UDim2.new(1, -80, 0, 110), UDim2.fromOffset(40, size.Y / 2 - 55), Color3.fromHex("#22262C"), 16)
	frame(terminal, "Slot", UDim2.new(1, -40, 0, 8), UDim2.fromOffset(20, 51), Color3.fromHex("#0A0B0D"), 4)
	label(terminal, "SLIDE THE CARD THROUGH  ›››", 14, Theme.DarkMuted, { Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 20) })
	local card = frame(ctx.arena, "Card", UDim2.fromOffset(120, 76), UDim2.fromOffset(0, 0), Theme.Accent, 10)
	label(card, "CHAOS BANK", 12, Theme.White, { Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 16) })
	frame(card, "Stripe", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 32), INK)
	local startX = 100
	local endX = size.X - 100
	local lineY = size.Y / 2
	centreAt(card, Vector2.new(startX, lineY - 70))
	local tolerance = if ctx.easier then 70 else 50
	local wobble, samples, began, finished = 0, 0, 0, false

	local function finish(raw: number)
		if finished then
			return
		end
		finished = true
		centreAt(card, Vector2.new(endX, lineY))
		ctx.done(raw, raw >= 0.98)
	end

	draggable(ctx, b, card, function(position)
		if finished then
			return
		end
		if began == 0 then
			began = os.clock()
		end
		local y = position.Y
		if ctx.helper then
			y = lineY + (y - lineY) * 0.3 -- the helper steadies your hand
		end
		centreAt(card, Vector2.new(math.clamp(position.X, 40, size.X - 40), math.clamp(y, 40, size.Y - 40)))
		if position.X > startX and position.X < endX then
			wobble += math.abs(y - lineY)
			samples += 1
		end
		if position.X >= endX then
			local steadiness = 1 - math.clamp((wobble / math.max(samples, 1)) / tolerance, 0, 1)
			local took = os.clock() - began
			local pace = if took < 0.25 then 0.6 elseif took > 3 then 0.7 else 1
			local raw = math.clamp(steadiness * pace, 0, 1)
			ctx.report(raw)
			finish(raw)
		else
			ctx.report(math.clamp((position.X - startX) / (endX - startX), 0, 1) * 0.5)
		end
	end, function()
		if not finished and centreOf(card, ctx.arena).X < endX then
			centreAt(card, Vector2.new(startX, lineY - 70)) -- let go early: start again
			wobble, samples, began = 0, 0, 0
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 2. WalletDrop: drag the card into the wallet three times
-- ---------------------------------------------------------------------------

function ScamGames.Drop(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local goal = 3
	local drops = 0
	local wallet = frame(ctx.arena, "Wallet", UDim2.fromOffset(150, 110), UDim2.fromOffset(0, 0), Color3.fromHex("#92400E"), 14)
	frame(wallet, "Flap", UDim2.new(1, -20, 0, 30), UDim2.fromOffset(10, -12), Color3.fromHex("#B45309"), 8)
	label(wallet, "WALLET", 16, Theme.White)
	local card = frame(ctx.arena, "Card", UDim2.fromOffset(110, 70), UDim2.fromOffset(0, 0), Theme.Accent, 10)
	label(card, "💳", 30, Theme.White)
	local function placeWallet()
		centreAt(wallet, Vector2.new(ctx.random:NextNumber(size.X * 0.5, size.X - 90), ctx.random:NextNumber(70, size.Y - 70)))
		popIn(wallet)
	end
	local function placeCard()
		centreAt(card, Vector2.new(ctx.random:NextNumber(70, size.X * 0.35), ctx.random:NextNumber(60, size.Y - 60)))
		popIn(card)
	end
	placeWallet()
	placeCard()
	local function nudge()
		-- the wallet shuffles a little while you drag (not with the helper)
		if ctx.helper then
			return
		end
		local centre = centreOf(wallet, ctx.arena)
		local target = centre + Vector2.new(ctx.random:NextNumber(-60, 60), ctx.random:NextNumber(-40, 40))
		target = Vector2.new(math.clamp(target.X, size.X * 0.45, size.X - 80), math.clamp(target.Y, 60, size.Y - 60))
		TweenService:Create(wallet, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Position = UDim2.fromOffset(target.X, target.Y) }):Play()
	end
	local moves = 0
	draggable(ctx, b, card, function(position)
		centreAt(card, Vector2.new(math.clamp(position.X, 40, size.X - 40), math.clamp(position.Y, 30, size.Y - 30)))
		moves += 1
		if moves % (if ctx.easier then 40 else 25) == 0 then
			nudge()
		end
	end, function()
		if overlaps(card, wallet) then
			drops += 1
			ctx.report(drops / goal)
			if drops >= goal then
				card.Visible = false
				ctx.done(1, true)
			else
				placeWallet()
				placeCard()
			end
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 3. RemoteDesk: a clicker on their desktop
-- ---------------------------------------------------------------------------

local function spawner(ctx: Ctx, b, options: {
	every: number, -- seconds between spawns
	lifetime: number,
	target: number, -- spawns that count as a full score
	spawn: (Vector2) -> (GuiObject, GuiObject), -- builds the thing at a centre; returns (clickable, whole thing)
	size: number,
})
	local size = arenaSize(ctx)
	local hits, clock = 0, 0
	local alive: { [GuiObject]: number } = {}
	local wholes: { [GuiObject]: GuiObject } = {}
	local every = if ctx.easier then options.every * 1.25 else options.every
	local lifetime = if ctx.easier then options.lifetime * 1.3 else options.lifetime
	local function remove(thing: GuiObject)
		local whole = wholes[thing]
		wholes[thing] = nil
		if whole then
			whole:Destroy()
		end
	end
	local function hit(thing: GuiObject)
		if not alive[thing] then
			return
		end
		alive[thing] = nil
		hits += 1
		ctx.report(math.clamp(hits / options.target, 0, 1))
		local whole = wholes[thing]
		if whole then
			TweenService:Create(whole, TweenInfo.new(0.15), { Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1 }):Play()
		end
		task.delay(0.16, function()
			remove(thing)
		end)
	end
	local function spawnOne()
		local margin = options.size / 2 + 6
		local centre = Vector2.new(ctx.random:NextNumber(margin, size.X - margin), ctx.random:NextNumber(margin, size.Y - margin))
		local thing, whole = options.spawn(centre)
		alive[thing] = os.clock()
		wholes[thing] = whole
		popIn(whole)
		b.add(thing.InputBegan:Connect(function(input)
			if isPress(input) then
				hit(thing)
			end
		end))
	end
	local helperClock = 0
	b.every(function(dt)
		clock += dt
		if clock >= every then
			clock -= every
			spawnOne()
		end
		local now = os.clock()
		for thing, born in alive do
			if now - born > lifetime then
				alive[thing] = nil
				remove(thing)
			end
		end
		if ctx.helper then
			helperClock += dt
			if helperClock >= 2 then
				helperClock = 0
				local oldest, oldestBorn = nil, math.huge
				for thing, born in alive do
					if born < oldestBorn then
						oldest, oldestBorn = thing, born
					end
				end
				if oldest then
					hit(oldest)
				end
			end
		end
	end)
	return b
end

function ScamGames.Clicker(ctx: Ctx)
	local b = bag()
	-- their desktop: a few dull icons in the background
	for i = 1, 6 do
		local icon = frame(ctx.arena, `Icon{i}`, UDim2.fromOffset(44, 44), UDim2.fromOffset(20, 16 + (i - 1) * 52), Color3.fromHex("#CBD5E1"), 10)
		label(icon, ({ "📁", "🗑", "📄", "🖥", "📁", "📷" })[i], 20, INK)
	end
	spawner(ctx, b, {
		every = 0.55,
		lifetime = 1.6,
		target = math.floor(ctx.seconds / 0.65),
		size = 64,
		spawn = function(centre)
			local cash = button(ctx.arena, "Cash", UDim2.fromOffset(64, 64), UDim2.fromOffset(0, 0), CASH, "$", 32)
			centreAt(cash, centre)
			cash.TextSize = 30
			return cash, cash
		end,
	})
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 4. PopUp Palace: close the pop-ups
-- ---------------------------------------------------------------------------

local POPUP_TITLES = { "WARNING!!!", "47 VIRUSES FOUND", "YOUR PC IS SLOW", "CLAIM YOUR PRIZE", "UPDATE REQUIRED", "ALERT" }

function ScamGames.PopUps(ctx: Ctx)
	local b = bag()
	spawner(ctx, b, {
		every = 0.8,
		lifetime = 2.6,
		target = math.floor(ctx.seconds / 0.95),
		size = 150,
		spawn = function(centre)
			local popup = frame(ctx.arena, "PopUp", UDim2.fromOffset(170, 96), UDim2.fromOffset(0, 0), Theme.White, 8)
			centreAt(popup, centre)
			make("UIStroke", { Color = Color3.fromHex("#D6313B"), Thickness = 2 }, popup)
			local bar = frame(popup, "Bar", UDim2.new(1, 0, 0, 26), UDim2.fromOffset(0, 0), Color3.fromHex("#D6313B"), 8)
			label(bar, POPUP_TITLES[ctx.random:NextInteger(1, #POPUP_TITLES)], 11, Theme.White, { Size = UDim2.new(1, -36, 1, 0), Position = UDim2.fromOffset(8, 0), TextXAlignment = Enum.TextXAlignment.Left })
			label(popup, "Click OK to install cleaner", 11, Theme.NativeMuted, { Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 40) })
			local x = button(bar, "Close", UDim2.fromOffset(if ctx.easier then 44 else 32, 22), UDim2.new(1, if ctx.easier then -46 else -34, 0, 2), INK, "✕", 4)
			x.TextSize = 14
			return x, popup -- the ✕ is what you click; the whole pop-up goes with it
		end,
	})
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 5. Worm: snake through their files eating coins (walls only stop you)
-- ---------------------------------------------------------------------------

function ScamGames.Snake(ctx: Ctx)
	local b = bag()
	local cols, rows = 16, 8
	local size = arenaSize(ctx)
	local cell = math.floor(math.min(size.X / cols, size.Y / rows))
	local ox = (size.X - cell * cols) / 2
	local oy = (size.Y - cell * rows) / 2
	local board = frame(ctx.arena, "Board", UDim2.fromOffset(cell * cols, cell * rows), UDim2.fromOffset(ox, oy), Color3.fromHex("#E2E8F0"), 8)
	local function at(x: number, y: number): UDim2
		return UDim2.fromOffset((x - 1) * cell + 2, (y - 1) * cell + 2)
	end
	local coins: { [string]: Frame } = {}
	local walls: { [string]: boolean } = {}
	local function key(x: number, y: number): string
		return `{x},{y}`
	end
	for _ = 1, 8 do
		local x, y = ctx.random:NextInteger(3, cols), ctx.random:NextInteger(1, rows)
		if not walls[key(x, y)] then
			walls[key(x, y)] = true
			local wall = frame(board, "File", UDim2.fromOffset(cell - 4, cell - 4), at(x, y), Color3.fromHex("#94A3B8"), 4)
			label(wall, "📄", math.floor(cell * 0.5), INK)
		end
	end
	local total = 10
	local eaten = 0
	for _ = 1, total do
		local x, y
		repeat
			x, y = ctx.random:NextInteger(2, cols), ctx.random:NextInteger(1, rows)
		until not walls[key(x, y)] and not coins[key(x, y)] and not (y == 4 and x <= 3)
		local coin = frame(board, "Coin", UDim2.fromOffset(cell - 10, cell - 10), at(x, y) + UDim2.fromOffset(3, 3), Theme.Gold, 99)
		label(coin, "$", math.floor(cell * 0.45), INK)
		coins[key(x, y)] = coin
	end
	local body = { { 3, 4 }, { 2, 4 }, { 1, 4 } }
	local segments: { Frame } = {}
	for i = 1, #body do
		local seg = frame(board, "Worm", UDim2.fromOffset(cell - 4, cell - 4), at(body[i][1], body[i][2]), if i == 1 then Color3.fromHex("#15803D") else Color3.fromHex("#22C55E"), 8)
		if i == 1 then
			label(seg, "•‿•", math.floor(cell * 0.4), Theme.White)
		end
		segments[i] = seg
	end
	local dir, nextDir = { 1, 0 }, { 1, 0 }
	local step = if ctx.easier then 0.42 else 0.34
	local clock = 0
	local function setDir(dx: number, dy: number)
		if dx == -dir[1] and dy == -dir[2] then
			return
		end
		nextDir = { dx, dy }
	end
	b.add(UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType ~= Enum.UserInputType.Gamepad1 then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.Up or k == Enum.KeyCode.W or k == Enum.KeyCode.DPadUp then
			setDir(0, -1)
		elseif k == Enum.KeyCode.Down or k == Enum.KeyCode.S or k == Enum.KeyCode.DPadDown then
			setDir(0, 1)
		elseif k == Enum.KeyCode.Left or k == Enum.KeyCode.A or k == Enum.KeyCode.DPadLeft then
			setDir(-1, 0)
		elseif k == Enum.KeyCode.Right or k == Enum.KeyCode.D or k == Enum.KeyCode.DPadRight then
			setDir(1, 0)
		end
	end))
	-- mouse / touch: steer toward the pointer when it's held down, or by swiping
	local pressing = false
	b.add(UserInputService.InputBegan:Connect(function(input)
		if isPress(input) then
			pressing = true
		end
	end))
	b.add(UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			pressing = false
		end
	end))
	b.every(function(dt)
		if pressing then
			local head = body[1]
			local target = ctx.pointer() - Vector2.new(ox, oy)
			local hx, hy = (head[1] - 0.5) * cell, (head[2] - 0.5) * cell
			local dx, dy = target.X - hx, target.Y - hy
			if math.abs(dx) > math.abs(dy) then
				setDir(if dx > 0 then 1 else -1, 0)
			elseif math.abs(dy) > cell * 0.3 then
				setDir(0, if dy > 0 then 1 else -1)
			end
		end
		if ctx.helper and not pressing then
			-- the helper steers toward the nearest coin when you're not steering
			local head = body[1]
			local best, bestDistance = nil, math.huge
			for k in coins do
				local x, y = string.match(k, "(%d+),(%d+)")
				local cx, cy = tonumber(x) :: number, tonumber(y) :: number
				local d = math.abs(cx - head[1]) + math.abs(cy - head[2])
				if d < bestDistance then
					best, bestDistance = { cx, cy }, d
				end
			end
			if best then
				local dx, dy = best[1] - head[1], best[2] - head[2]
				if dx ~= 0 and (dy == 0 or math.abs(dx) >= math.abs(dy)) then
					setDir(if dx > 0 then 1 else -1, 0)
				elseif dy ~= 0 then
					setDir(0, if dy > 0 then 1 else -1)
				end
			end
		end
		clock += dt
		if clock < step then
			return
		end
		clock -= step
		dir = nextDir
		local head = body[1]
		local nx, ny = head[1] + dir[1], head[2] + dir[2]
		if nx < 1 or nx > cols or ny < 1 or ny > rows or walls[key(nx, ny)] then
			return -- walls and edges just stop the worm
		end
		for i = #body, 2, -1 do
			body[i] = body[i - 1]
		end
		body[1] = { nx, ny }
		for i, seg in segments do
			seg.Position = at(body[i][1], body[i][2])
		end
		local coin = coins[key(nx, ny)]
		if coin then
			coins[key(nx, ny)] = nil
			coin:Destroy()
			eaten += 1
			ctx.report(eaten / total)
			if eaten >= total then
				ctx.done(1, true)
			end
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 6. ScratchIt: scratch off the silver
-- ---------------------------------------------------------------------------

function ScamGames.Scratch(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local cols, rows = 12, 5
	local cardW, cardH = math.min(600, size.X - 40), 220
	local card = frame(ctx.arena, "GiftCard", UDim2.fromOffset(cardW, cardH), UDim2.fromOffset((size.X - cardW) / 2, (size.Y - cardH) / 2), Color3.fromHex("#A16207"), 16)
	label(card, "SCAMAZON GIFT CARD", 14, Theme.White, { Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 20) })
	local codeChars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	local code = {}
	for i = 1, 12 do
		local n = ctx.random:NextInteger(1, #codeChars)
		code[i] = string.sub(codeChars, n, n)
	end
	label(card, `{table.concat(code, "", 1, 4)}-{table.concat(code, "", 5, 8)}-{table.concat(code, "", 9, 12)}`, 30, Theme.White,
		{ Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 140) })
	local panelW, panelH = cardW - 40, 140
	local panel = frame(card, "Silver", UDim2.fromOffset(panelW, panelH), UDim2.fromOffset(20, 44), Color3.new(1, 1, 1), 8)
	panel.BackgroundTransparency = 1
	local tw, th = panelW / cols, panelH / rows
	local tiles: { Frame } = {}
	for y = 1, rows do
		for x = 1, cols do
			table.insert(tiles, frame(panel, "Tile", UDim2.fromOffset(tw + 1, th + 1), UDim2.fromOffset((x - 1) * tw, (y - 1) * th), SILVER))
		end
	end
	local left = #tiles
	local total = #tiles
	local pressing = false
	local radius = if ctx.easier then 34 else 24
	local function scratchAt(point: Vector2)
		for i = #tiles, 1, -1 do
			local tile = tiles[i]
			local centre = centreOf(tile, ctx.arena)
			if (centre - point).Magnitude <= radius then
				table.remove(tiles, i)
				tile:Destroy()
				left -= 1
			end
		end
		ctx.report((total - left) / total)
		if left <= math.floor(total * 0.04) then
			for _, tile in tiles do
				tile:Destroy()
			end
			tiles = {}
			ctx.done(1, true)
		end
	end
	b.add(UserInputService.InputBegan:Connect(function(input)
		if isPress(input) then
			pressing = true
			scratchAt(ctx.pointer())
		end
	end))
	b.add(UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			pressing = false
		end
	end))
	b.add(UserInputService.InputChanged:Connect(function(input)
		if pressing and isMove(input) then
			scratchAt(ctx.pointer())
		end
	end))
	if ctx.helper then
		local clock = 0
		b.every(function(dt)
			clock += dt
			if clock > 0.5 and #tiles > 0 then
				clock = 0
				scratchAt(centreOf(tiles[ctx.random:NextInteger(1, #tiles)], ctx.arena))
			end
		end)
	end
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 7. PrizeWheelz: hold to charge, release to spin
-- ---------------------------------------------------------------------------

function ScamGames.Wheel(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local wedges = if ctx.helper then { 1, 0.8, 0.9, 0.7, 1, 0.6, 0.9, 0.8 } else { 1, 0.4, 0.8, 0.3, 1, 0.6, 0.9, 0.5 }
	local n = #wedges
	local radius = math.min(size.Y / 2 - 20, 150)
	local wheel = frame(ctx.arena, "Wheel", UDim2.fromOffset(radius * 2, radius * 2), UDim2.fromOffset(0, 0), Theme.White, radius)
	centreAt(wheel, Vector2.new(size.X * 0.4, size.Y / 2))
	make("UIStroke", { Color = INK, Thickness = 4 }, wheel)
	for i, value in wedges do
		local angle = (i - 1) / n * 360
		local marker = frame(wheel, `Wedge{i}`, UDim2.fromOffset(60, 34), UDim2.fromOffset(0, 0), COLORS[(i - 1) % #COLORS + 1], 8)
		local r = math.rad(angle - 90)
		centreAt(marker, Vector2.new(radius + math.cos(r) * radius * 0.68, radius + math.sin(r) * radius * 0.68))
		marker.Rotation = angle
		label(marker, `{math.round(value * 100)}%`, 14, Theme.White)
	end
	local pointer = frame(ctx.arena, "Pointer", UDim2.fromOffset(22, 34), UDim2.fromOffset(0, 0), Theme.Red, 4)
	centreAt(pointer, Vector2.new(size.X * 0.4, size.Y / 2 - radius - 6))
	local barBack = frame(ctx.arena, "Power", UDim2.fromOffset(200, 24), UDim2.fromOffset(size.X * 0.68, size.Y / 2 - 12), Color3.fromHex("#E5E7EB"), 12)
	local fill = frame(barBack, "Fill", UDim2.fromScale(0, 1), UDim2.fromOffset(0, 0), Theme.Accent, 12)
	label(ctx.arena, "HOLD to charge, RELEASE to spin", 16, INK, { Position = UDim2.fromOffset(size.X * 0.68 - 40, size.Y / 2 + 24), Size = UDim2.fromOffset(280, 40) })
	local charging, power, dirn, spinning, done = false, 0, 1, false, false
	b.add(UserInputService.InputBegan:Connect(function(input)
		if isPress(input) and not spinning and not done then
			charging = true
		end
	end))
	local rotation, speed = 0, 0
	b.add(UserInputService.InputEnded:Connect(function(input)
		if isPress(input) and charging then
			charging = false
			spinning = true
			speed = 540 + power * 900 + ctx.random:NextNumber(0, 120)
		end
	end))
	b.every(function(dt)
		if charging then
			power += dt * 1.4 * dirn
			if power >= 1 then
				power, dirn = 1, -1
			elseif power <= 0 then
				power, dirn = 0, 1
			end
			fill.Size = UDim2.fromScale(power, 1)
		end
		if spinning then
			rotation += speed * dt
			speed = math.max(0, speed - dt * (if ctx.easier then 260 else 320))
			wheel.Rotation = rotation % 360
			if speed <= 0 then
				spinning = false
				done = true
				-- the wedge under the pointer (top): wedge i covers [(i-1)/n, i/n) of a turn, read backwards
				local turn = (360 - (rotation % 360)) % 360
				local index = math.floor(turn / 360 * n) + 1
				local value = wedges[math.clamp(index, 1, n)]
				ctx.report(value)
				ctx.done(value, value >= 1)
			end
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 8. CryptoCoinz: sell at the top
-- ---------------------------------------------------------------------------

function ScamGames.Crypto(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local chart = frame(ctx.arena, "Chart", UDim2.new(1, -40, 1, -90), UDim2.fromOffset(20, 20), Theme.White, 10)
	make("UIStroke", { Color = Color3.fromHex("#E5E7EB"), Thickness = 1 }, chart)
	local price, best, sold = 0.3, 0.3, false
	local sell = button(ctx.arena, "Sell", UDim2.fromOffset(220, 48), UDim2.fromOffset(size.X / 2 - 110, size.Y - 60), CASH, "SELL NOW", 24)
	local readout = label(ctx.arena, "", 18, INK, { Position = UDim2.fromOffset(size.X - 200, size.Y - 60), Size = UDim2.fromOffset(180, 48) })
	local t, lastBar, bars = 0, 0, 0
	-- the price climbs for most of the run, with dips, and peaks somewhere past the middle
	local peakAt = ctx.random:NextNumber(0.5, 0.85) * ctx.seconds
	local wiggleSeed = ctx.random:NextNumber(0, 100)
	local function priceAt(time: number): number
		local trend = if time <= peakAt then 0.3 + 0.6 * (time / peakAt) else 0.9 - 0.5 * ((time - peakAt) / math.max(ctx.seconds - peakAt, 1))
		local wiggle = math.sin(time * 2.1 + wiggleSeed) * 0.05 + math.sin(time * 5.3 + wiggleSeed * 2) * 0.03
		return math.clamp(trend + wiggle, 0.05, 1)
	end
	local function finish()
		if sold then
			return
		end
		sold = true
		sell.Text = "SOLD"
		sell.BackgroundColor3 = Theme.NativeMuted
		local raw = math.clamp(price / 0.95, 0, 1)
		ctx.report(raw)
		ctx.done(raw, raw >= 0.98)
	end
	b.add(sell.MouseButton1Click:Connect(finish))
	b.every(function(dt)
		if sold then
			return
		end
		t += dt
		price = priceAt(t)
		best = math.max(best, price)
		readout.Text = `C${math.round(price * 1000)}`
		readout.TextColor3 = if price >= best - 0.02 then CASH else Theme.Red
		ctx.report(math.clamp(price / 0.95, 0, 1))
		if t - lastBar >= ctx.seconds / 80 then
			lastBar = t
			bars += 1
			local w = (size.X - 40) / 80
			local h = math.max(2, price * (size.Y - 100))
			frame(chart, "Bar", UDim2.fromOffset(math.max(w - 1, 2), h), UDim2.new(0, (bars - 1) * w, 1, -h - 5), if price >= best - 0.01 then CASH else Theme.Accent, 2)
		end
		if ctx.helper and t > peakAt and price < best - 0.03 then
			finish() -- the helper sells right after the top
		end
		if t >= ctx.seconds - 0.1 then
			finish()
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 9. RefundMe: stamp the forms
-- ---------------------------------------------------------------------------

function ScamGames.Stamp(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local zoneW = if ctx.easier then 140 else 100
	local zone = frame(ctx.arena, "Zone", UDim2.fromOffset(zoneW, size.Y - 40), UDim2.fromOffset(size.X / 2 - zoneW / 2, 20), Color3.fromHex("#DCFCE7"), 10)
	make("UIStroke", { Color = CASH, Thickness = 2 }, zone)
	label(zone, "STAMP HERE", 12, CASH, { Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 16) })
	local total = 8
	local hits, shown = 0, 0
	local forms: { Frame } = {}
	local speed = if ctx.easier then 150 else 200
	local gap = 190
	local function spawnForm()
		shown += 1
		local form = frame(ctx.arena, "Form", UDim2.fromOffset(120, 150), UDim2.fromOffset(size.X + 10, size.Y / 2 - 75), Theme.White, 6)
		make("UIStroke", { Color = Color3.fromHex("#CBD5E1"), Thickness = 1 }, form)
		for i = 1, 4 do
			frame(form, "Line", UDim2.new(1, -24, 0, 6), UDim2.fromOffset(12, 14 + (i - 1) * 16), Color3.fromHex("#E2E8F0"), 3)
		end
		local box = frame(form, "Box", UDim2.fromOffset(60, 40), UDim2.fromOffset(30, 96), Theme.White, 4)
		make("UIStroke", { Color = Color3.fromHex("#94A3B8"), Thickness = 2 }, box)
		table.insert(forms, form)
	end
	local function stamp()
		for i, form in forms do
			if form:GetAttribute("Stamped") then
				continue
			end
			local box = form.Box
			local bx = box.AbsolutePosition.X + box.AbsoluteSize.X / 2
			local zx, zw = zone.AbsolutePosition.X, zone.AbsoluteSize.X
			if bx >= zx and bx <= zx + zw then
				form:SetAttribute("Stamped", true)
				local mark = frame(box, "Mark", UDim2.fromOffset(70, 30), UDim2.fromOffset(-5, 5), Theme.Red, 4)
				mark.BackgroundTransparency = 1
				make("UIStroke", { Color = Theme.Red, Thickness = 3 }, mark)
				label(mark, "PAID", 14, Theme.Red)
				mark.Rotation = -12
				hits += 1
				ctx.report(hits / total)
				if hits >= total then
					ctx.done(1, true)
				end
				return
			end
		end
	end
	b.add(UserInputService.InputBegan:Connect(function(input)
		if isPress(input) then
			stamp()
		end
	end))
	local spawnClock = 0
	local helperClock = 0
	b.every(function(dt)
		spawnClock += dt
		if shown < total and spawnClock >= gap / speed then
			spawnClock = 0
			spawnForm()
		end
		for i = #forms, 1, -1 do
			local form = forms[i]
			form.Position = form.Position - UDim2.fromOffset(speed * dt, 0)
			if form.Position.X.Offset < -140 then
				table.remove(forms, i)
				form:Destroy()
			end
		end
		if ctx.helper then
			helperClock += dt
			if helperClock > 0.1 then
				helperClock = 0
				for _, form in forms do
					if not form:GetAttribute("Stamped") then
						local bx = form.Box.AbsolutePosition.X + form.Box.AbsoluteSize.X / 2
						local zx = zone.AbsolutePosition.X + zone.AbsoluteSize.X / 2
						if math.abs(bx - zx) < 12 then
							stamp()
						end
					end
				end
			end
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 10. ParcelPal: swipe parcels into the right truck
-- ---------------------------------------------------------------------------

function ScamGames.Parcels(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local total = 10
	local sorted, correct = 0, 0
	local leftColor, rightColor = COLORS[1], COLORS[3]
	local function truck(name: string, x: number, color: Color3, text: string)
		local t = button(ctx.arena, name, UDim2.fromOffset(150, 110), UDim2.fromOffset(x, size.Y / 2 - 55), color, text, 12)
		t.TextSize = 16
		frame(t, "Wheel1", UDim2.fromOffset(28, 28), UDim2.fromOffset(20, 96), INK, 14)
		frame(t, "Wheel2", UDim2.fromOffset(28, 28), UDim2.fromOffset(100, 96), INK, 14)
		return t
	end
	local leftTruck = truck("LeftTruck", 20, leftColor, "◀ TRUCK")
	local rightTruck = truck("RightTruck", size.X - 170, rightColor, "TRUCK ▶")
	local parcel: TextButton? = nil
	local parcelColor: Color3 = leftColor
	local function nextParcel()
		if sorted >= total then
			ctx.done(correct / total, correct >= total)
			return
		end
		parcelColor = if ctx.random:NextNumber() < 0.5 then leftColor else rightColor
		local p = button(ctx.arena, "Parcel", UDim2.fromOffset(90, 90), UDim2.fromOffset(0, 0), parcelColor, "📦", 10)
		p.TextSize = 36
		centreAt(p, Vector2.new(size.X / 2, size.Y / 2))
		popIn(p)
		parcel = p
	end
	local function sortTo(side: string)
		local p = parcel
		if not p then
			return
		end
		parcel = nil
		sorted += 1
		local wanted = if parcelColor == leftColor then "left" else "right"
		if side == wanted then
			correct += 1
		end
		ctx.report(correct / total)
		local targetX = if side == "left" then 95 else size.X - 95
		TweenService:Create(p, TweenInfo.new(0.2), { Position = UDim2.fromOffset(targetX, size.Y / 2), Size = UDim2.fromOffset(20, 20) }):Play()
		task.delay(0.22, function()
			p:Destroy()
			if b.alive() then
				nextParcel()
			end
		end)
	end
	b.add(leftTruck.MouseButton1Click:Connect(function()
		sortTo("left")
	end))
	b.add(rightTruck.MouseButton1Click:Connect(function()
		sortTo("right")
	end))
	-- swipe: press on the parcel, move 60px sideways
	local pressAt: Vector2? = nil
	b.add(UserInputService.InputBegan:Connect(function(input)
		if isPress(input) and parcel then
			local point = ctx.pointer()
			local centre = centreOf(parcel, ctx.arena)
			if (point - centre).Magnitude < 70 then
				pressAt = point
			end
		end
	end))
	b.add(UserInputService.InputChanged:Connect(function(input)
		if pressAt and isMove(input) then
			local dx = ctx.pointer().X - pressAt.X
			if parcel then
				centreAt(parcel, Vector2.new(size.X / 2 + dx, size.Y / 2))
			end
			if math.abs(dx) > 60 then
				pressAt = nil
				sortTo(if dx < 0 then "left" else "right")
			end
		end
	end))
	b.add(UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			pressAt = nil
			if parcel then
				centreAt(parcel, Vector2.new(size.X / 2, size.Y / 2))
			end
		end
	end))
	b.add(UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Left or input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.DPadLeft then
			sortTo("left")
		elseif input.KeyCode == Enum.KeyCode.Right or input.KeyCode == Enum.KeyCode.D or input.KeyCode == Enum.KeyCode.DPadRight then
			sortTo("right")
		end
	end))
	if ctx.helper then
		-- the helper colours the parcel's shadow with an arrow toward the right truck
		b.every(function()
			local p = parcel
			if p and p.Text == "📦" then
				p.Text = if parcelColor == leftColor then "◀📦" else "📦▶"
			end
		end)
	end
	nextParcel()
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 11. LoveLetter: match the hearts
-- ---------------------------------------------------------------------------

function ScamGames.Memory(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local cols, rows = 4, 3
	local pairs = cols * rows / 2
	local values = {}
	for i = 1, pairs do
		table.insert(values, i)
		table.insert(values, i)
	end
	for i = #values, 2, -1 do
		local j = ctx.random:NextInteger(1, i)
		values[i], values[j] = values[j], values[i]
	end
	local cw, ch = 110, 90
	local ox = (size.X - cols * (cw + 10)) / 2
	local oy = (size.Y - rows * (ch + 10)) / 2
	local cards: { TextButton } = {}
	local open: { number } = {}
	local found = 0
	local busy = false
	local function show(i: number, on: boolean)
		local card = cards[i]
		card.Text = if on then "♥" else "?"
		card.TextColor3 = if on then COLORS[values[i]] else Theme.White
		card.BackgroundColor3 = if on then Theme.White else Color3.fromHex("#DB2777")
	end
	for i = 1, #values do
		local x = (i - 1) % cols
		local y = (i - 1) // cols
		local card = button(ctx.arena, `Card{i}`, UDim2.fromOffset(cw, ch), UDim2.fromOffset(ox + x * (cw + 10), oy + y * (ch + 10)), Color3.fromHex("#DB2777"), "?", 10)
		card.TextSize = 40
		cards[i] = card
		b.add(card.MouseButton1Click:Connect(function()
			if busy or card:GetAttribute("Done") or table.find(open, i) then
				return
			end
			show(i, true)
			table.insert(open, i)
			if #open == 2 then
				local a, c = open[1], open[2]
				open = {}
				if values[a] == values[c] then
					cards[a]:SetAttribute("Done", true)
					cards[c]:SetAttribute("Done", true)
					cards[a].BackgroundColor3 = Color3.fromHex("#FCE7F3")
					cards[c].BackgroundColor3 = Color3.fromHex("#FCE7F3")
					found += 1
					ctx.report(found / pairs)
					if found >= pairs then
						ctx.done(1, true)
					end
				else
					busy = true
					task.delay(if ctx.easier then 0.9 else 0.6, function()
						if b.alive() then
							show(a, false)
							show(c, false)
						end
						busy = false
					end)
				end
			end
		end))
	end
	if ctx.helper then
		-- the helper shows one pair from the start
		for i = 1, #values do
			if values[i] == 1 then
				cards[i]:SetAttribute("Done", true)
				show(i, true)
				cards[i].BackgroundColor3 = Color3.fromHex("#FCE7F3")
			end
		end
		found = 1
		ctx.report(found / pairs)
	end
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 12. GiveHope: catch the hearts
-- ---------------------------------------------------------------------------

function ScamGames.Hearts(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local total = math.floor(ctx.seconds / 0.7)
	local caught, spawned, clock = 0, 0, 0
	local hearts: { [TextButton]: number } = {}
	local rise = if ctx.easier then 70 else 95
	b.every(function(dt)
		clock += dt
		if clock >= 0.7 and spawned < total then
			clock = 0
			spawned += 1
			local heart = button(ctx.arena, "Heart", UDim2.fromOffset(if ctx.easier then 70 else 56, if ctx.easier then 70 else 56), UDim2.fromOffset(0, 0), Color3.fromHex("#E11D48"), "♥", 28)
			heart.TextSize = 30
			centreAt(heart, Vector2.new(ctx.random:NextNumber(50, size.X - 50), size.Y + 30))
			hearts[heart] = ctx.random:NextNumber(-20, 20)
			b.add(heart.MouseButton1Click:Connect(function()
				if hearts[heart] then
					hearts[heart] = nil
					caught += 1
					ctx.report(math.clamp(caught / total, 0, 1))
					TweenService:Create(heart, TweenInfo.new(0.15), { Size = UDim2.fromOffset(0, 0) }):Play()
					task.delay(0.16, function()
						heart:Destroy()
					end)
				end
			end))
		end
		local helped = false
		for heart, drift in hearts do
			local centre = centreOf(heart, ctx.arena)
			centreAt(heart, centre + Vector2.new(drift * dt, -rise * dt))
			if centre.Y < -40 then
				hearts[heart] = nil
				heart:Destroy()
			elseif ctx.helper and not helped and centre.Y < 30 then
				helped = true
				hearts[heart] = nil
				caught += 1
				ctx.report(math.clamp(caught / total, 0, 1))
				heart:Destroy()
			end
		end
	end)
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 13. BankOfNowhere: repeat the padlocks
-- ---------------------------------------------------------------------------

function ScamGames.Padlocks(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local count = 6
	local rounds = 3
	local locks: { TextButton } = {}
	local lw = 90
	local ox = (size.X - count * (lw + 12)) / 2
	for i = 1, count do
		local lock = button(ctx.arena, `Lock{i}`, UDim2.fromOffset(lw, 100), UDim2.fromOffset(ox + (i - 1) * (lw + 12), size.Y / 2 - 50), Color3.fromHex("#334155"), "🔒", 12)
		lock.TextSize = 36
		locks[i] = lock
	end
	local status = label(ctx.arena, "Watch...", 18, INK, { Position = UDim2.fromOffset(0, size.Y / 2 + 70), Size = UDim2.new(1, 0, 0, 30) })
	local sequence: { number } = {}
	local round, position, showing, finished = 0, 1, false, false
	local function light(i: number, on: boolean)
		locks[i].BackgroundColor3 = if on then Theme.Gold else Color3.fromHex("#334155")
		locks[i].Text = if on then "🔓" else "🔒"
	end
	local function playRound()
		round += 1
		position = 1
		showing = true
		status.Text = `Round {round} of {rounds}: watch...`
		local length = 2 + round
		sequence = {}
		for _ = 1, length do
			table.insert(sequence, ctx.random:NextInteger(1, count))
		end
		task.spawn(function()
			task.wait(0.5)
			for _, i in sequence do
				if not b.alive() then
					return
				end
				light(i, true)
				task.wait(if ctx.easier then 0.6 else 0.45)
				light(i, false)
				task.wait(0.2)
			end
			if b.alive() then
				showing = false
				status.Text = "Your turn: click them in the same order"
			end
		end)
	end
	for i, lock in locks do
		b.add(lock.MouseButton1Click:Connect(function()
			if showing or finished then
				return
			end
			light(i, true)
			task.delay(0.15, function()
				if b.alive() then
					light(i, false)
				end
			end)
			if sequence[position] == i then
				position += 1
				ctx.report(math.clamp(((round - 1) + (position - 1) / #sequence) / rounds, 0, 1))
				if position > #sequence then
					if round >= rounds then
						finished = true
						status.Text = "You're in!"
						ctx.done(1, true)
					else
						showing = true
						task.delay(0.6, function()
							if b.alive() then
								playRound()
							end
						end)
					end
				end
			else
				status.Text = "Not that one. Watch again..."
				showing = true
				task.delay(0.6, function()
					if b.alive() then
						round -= 1
						playRound()
					end
				end)
			end
		end))
	end
	if ctx.helper then
		-- the helper keeps the lit lock glowing faintly, so you can't forget the first one
		b.every(function()
			if not showing and not finished and sequence[position] then
				locks[sequence[position]].BackgroundColor3 = Color3.fromHex("#64748B")
			end
		end)
	end
	playRound()
	return { stop = b.stop }
end

-- ---------------------------------------------------------------------------
-- 14. TechSupport Pro: connect the cables
-- ---------------------------------------------------------------------------

function ScamGames.Cables(ctx: Ctx)
	local b = bag()
	local size = arenaSize(ctx)
	local n = 4
	local orderR = { 1, 2, 3, 4 }
	for i = n, 2, -1 do
		local j = ctx.random:NextInteger(1, i)
		orderR[i], orderR[j] = orderR[j], orderR[i]
	end
	local rowH = size.Y / (n + 1)
	local ports: { Frame } = {}
	local connected = 0
	for i = 1, n do
		local port = frame(ctx.arena, `Port{i}`, UDim2.fromOffset(90, 50), UDim2.fromOffset(size.X - 130, rowH * i - 25), Theme.White, 8)
		make("UIStroke", { Color = COLORS[orderR[i]], Thickness = 4 }, port)
		port:SetAttribute("Color", orderR[i])
		ports[i] = port
	end
	for i = 1, n do
		local home = Vector2.new(85, rowH * i)
		local plug = frame(ctx.arena, `Plug{i}`, UDim2.fromOffset(80, 44), UDim2.fromOffset(0, 0), COLORS[i], 8)
		centreAt(plug, home)
		label(plug, "⚡", 20, Theme.White)
		local cable = frame(ctx.arena, `Cable{i}`, UDim2.fromOffset(0, 6), UDim2.fromOffset(home.X, home.Y - 3), COLORS[i], 3)
		cable.ZIndex = 0
		if ctx.helper then
			-- the helper labels the port with the plug's number
			label(ports[table.find(orderR, i) :: number], `#{i}`, 14, COLORS[i])
			label(plug, `#{i}`, 12, Theme.White, { Position = UDim2.fromOffset(0, -18), Size = UDim2.new(1, 0, 0, 16) })
		end
		local placed = false
		draggable(ctx, b, plug, function(position)
			if placed then
				return
			end
			centreAt(plug, Vector2.new(math.clamp(position.X, 40, size.X - 40), math.clamp(position.Y, 22, size.Y - 22)))
			local p = centreOf(plug, ctx.arena)
			cable.Size = UDim2.fromOffset(math.max(0, p.X - home.X), 6)
			cable.Position = UDim2.fromOffset(home.X, p.Y - 3)
		end, function()
			if placed then
				return
			end
			for _, port in ports do
				if overlaps(plug, port) then
					if port:GetAttribute("Color") == i and not port:GetAttribute("Used") then
						placed = true
						port:SetAttribute("Used", true)
						centreAt(plug, centreOf(port, ctx.arena))
						connected += 1
						ctx.report(connected / n)
						if connected >= n then
							ctx.done(1, true)
						end
					else
						centreAt(plug, home)
						cable.Size = UDim2.fromOffset(0, 6)
					end
					return
				end
			end
			centreAt(plug, home)
			cable.Size = UDim2.fromOffset(0, 6)
		end)
	end
	return { stop = b.stop }
end

ScamGames.Kinds = {
	"Swipe", "Drop", "Clicker", "PopUps", "Snake", "Scratch", "Wheel", "Crypto", "Stamp", "Parcels", "Memory",
	"Hearts", "Padlocks", "Cables",
}

return ScamGames
