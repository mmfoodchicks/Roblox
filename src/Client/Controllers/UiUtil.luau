--!strict
--[[
	UiUtil
	------
	Client helper module (StarterPlayerScripts.Controllers.UiUtil).

	Tiny, dependency-free helpers for hand-building GUIs in code so the UI
	controllers stay terse and visually consistent. Not a controller — it has no
	:Init() and is simply required by the others.
]]

local UiUtil = {}

-- Shared palette so every window reads as one app.
UiUtil.Palette = {
	Panel = Color3.fromRGB(28, 32, 40),
	PanelLight = Color3.fromRGB(40, 46, 56),
	Accent = Color3.fromRGB(64, 156, 255),
	Positive = Color3.fromRGB(88, 196, 120),
	Negative = Color3.fromRGB(220, 110, 110),
	Warn = Color3.fromRGB(232, 196, 96),
	Text = Color3.fromRGB(236, 240, 245),
	SubText = Color3.fromRGB(170, 178, 190),
	Disabled = Color3.fromRGB(70, 76, 86),
}

UiUtil.Rarity = {
	Common = Color3.fromRGB(170, 178, 184),
	Uncommon = Color3.fromRGB(88, 196, 120),
	Rare = Color3.fromRGB(64, 156, 255),
	Legendary = Color3.fromRGB(190, 96, 255),
}

-- Rounds a corner of `instance`.
function UiUtil.corner(instance: Instance, radius: number): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = instance
	return c
end

-- Adds uniform padding (in pixels) to a GuiObject.
function UiUtil.padding(instance: Instance, px: number): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.Parent = instance
	return p
end

-- Adds a thin stroke.
function UiUtil.stroke(instance: Instance, color: Color3, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Transparency = 0.3
	s.Parent = instance
	return s
end

-- Creates a styled Frame.
function UiUtil.frame(props: {
	Name: string?,
	Size: UDim2,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Color: Color3?,
	Transparency: number?,
	Parent: Instance?,
}): Frame
	local f = Instance.new("Frame")
	f.Name = props.Name or "Frame"
	f.Size = props.Size
	f.Position = props.Position or UDim2.fromScale(0, 0)
	f.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	f.BackgroundColor3 = props.Color or UiUtil.Palette.Panel
	f.BackgroundTransparency = props.Transparency or 0
	f.BorderSizePixel = 0
	f.Parent = props.Parent
	return f
end

-- Creates a styled TextLabel.
function UiUtil.label(props: {
	Name: string?,
	Size: UDim2,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Text: string,
	TextColor: Color3?,
	TextScaled: boolean?,
	TextSize: number?,
	Font: Enum.Font?,
	Align: Enum.TextXAlignment?,
	Parent: Instance?,
}): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = props.Name or "Label"
	l.Size = props.Size
	l.Position = props.Position or UDim2.fromScale(0, 0)
	l.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	l.BackgroundTransparency = 1
	l.Text = props.Text
	l.TextColor3 = props.TextColor or UiUtil.Palette.Text
	l.Font = props.Font or Enum.Font.GothamMedium
	l.TextXAlignment = props.Align or Enum.TextXAlignment.Center
	if props.TextScaled then
		l.TextScaled = true
	else
		l.TextSize = props.TextSize or 16
	end
	l.Parent = props.Parent
	return l
end

-- Creates a styled TextButton.
function UiUtil.button(props: {
	Name: string?,
	Size: UDim2,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Text: string,
	Color: Color3?,
	TextColor: Color3?,
	TextSize: number?,
	Font: Enum.Font?,
	Parent: Instance?,
}): TextButton
	local b = Instance.new("TextButton")
	b.Name = props.Name or "Button"
	b.Size = props.Size
	b.Position = props.Position or UDim2.fromScale(0, 0)
	b.AnchorPoint = props.AnchorPoint or Vector2.new(0, 0)
	b.BackgroundColor3 = props.Color or UiUtil.Palette.Accent
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Text = props.Text
	b.TextColor3 = props.TextColor or UiUtil.Palette.Text
	b.Font = props.Font or Enum.Font.GothamBold
	b.TextSize = props.TextSize or 16
	b.Parent = props.Parent
	UiUtil.corner(b, 6)
	return b
end

-- Formats an integer with thousands separators (e.g. 12345 -> "12,345").
function UiUtil.comma(n: number): string
	local s = tostring(math.floor(n))
	local formatted = s
	while true do
		local replaced: number
		formatted, replaced = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return formatted
end

return UiUtil
