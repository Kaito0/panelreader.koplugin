--[[
PanelViewer - A custom image viewer designed specifically for panel navigation

This viewer is built from scratch using KOReader's widget system and APIs,
inspired by modern image rendering patterns. It provides optimized panel
viewing with custom padding, gesture handling, and smooth transitions.
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")

-- Bayer 8x8 Threshold Map
local BAYER_8x8 = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 68, 20, 62, 30, 70, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 71, 23, 61, 29, 69, 21}
}

-- Optimization: Pre-scale matrix to 0-255 range with white headroom
local white_headroom = 20 -- Increase this to clear more white space
for y = 1, 8 do
    for x = 1, 8 do
        -- Thresholds now range from 20 to 272 (capped at 255)
        BAYER_8x8[y][x] = math.min(255, (BAYER_8x8[y][x] * 4) + white_headroom)
    end
end

local function applyBayer8x8(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local data = ffi.cast("unsigned char*", bb.data)
    local stride = bb.stride
    local bb_type = bb:getType()
    
    -- CONFIG: Pixels above this value (0-255) will be forced to pure white
    -- This removes dithering artifacts from "dirty" white backgrounds
    local white_point = 235 

    -- Handle different blitbuffer types
    if bb_type == Blitbuffer.TYPE_BB8 then
        -- Grayscale: Apply dithering directly
        for y = 0, h - 1 do
            local y_offset = y * stride
            local matrix_row = BAYER_8x8[(y % 8) + 1]
            for x = 0, w - 1 do
                local idx = y_offset + x
                local val = data[idx]
                
                -- Force clean whites
                if val >= white_point then
                    data[idx] = 255
                else
                    data[idx] = val > matrix_row[(x % 8) + 1] and 255 or 0
                end
            end
        end
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 then
        -- RGB32: Convert to grayscale first, then dither
        for y = 0, h - 1 do
            local y_offset = y * stride
            local matrix_row = BAYER_8x8[(y % 8) + 1]
            for x = 0, w - 1 do
                local pixel_offset = y_offset + (x * 4)
                local r = data[pixel_offset]
                local g = data[pixel_offset + 1] 
                local b = data[pixel_offset + 2]
                -- Convert to grayscale using standard weights
                local gray = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
                
                -- Force clean whites
                if gray >= white_point then
                    gray = 255
                else
                    gray = gray > matrix_row[(x % 8) + 1] and 255 or 0
                end
                
                -- Write back as grayscale RGB
                data[pixel_offset] = gray
                data[pixel_offset + 1] = gray
                data[pixel_offset + 2] = gray
            end
        end
    elseif bb_type == Blitbuffer.TYPE_BBRGB24 then
        -- RGB24: Convert to grayscale first, then dither
        for y = 0, h - 1 do
            local y_offset = y * stride
            local matrix_row = BAYER_8x8[(y % 8) + 1]
            for x = 0, w - 1 do
                local pixel_offset = y_offset + (x * 3)
                local r = data[pixel_offset]
                local g = data[pixel_offset + 1]
                local b = data[pixel_offset + 2]
                -- Convert to grayscale using standard weights
                local gray = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
                
                -- Force clean whites
                if gray >= white_point then
                    gray = 255
                else
                    gray = gray > matrix_row[(x % 8) + 1] and 255 or 0
                end
                
                -- Write back as grayscale RGB
                data[pixel_offset] = gray
                data[pixel_offset + 1] = gray
                data[pixel_offset + 2] = gray
            end
        end
    else
        -- For other types, skip dithering to avoid artifacts
        logger.warn(string.format("PanelViewer: Unsupported blitbuffer type %d for Bayer dithering", bb_type))
        return
    end
end
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local PanelViewer = InputContainer:extend{
    -- Core properties
    name = "PanelViewer",
    
    -- Image source (BlitBuffer or file path)
    image = nil,
    file = nil,
    
    -- Display properties
    fullscreen = true,
    buttons_visible = false,
    
    -- Panel-specific properties
    reading_direction = "ltr",
    bayer_dithering_enabled = true, -- Toggle between Bayer and built-in dithering
    
    -- Callbacks for navigation
    onNext = nil,
    onPrev = nil,
    onClose = nil,
    
    -- Internal state
    _image_bb = nil,
    _original_size = nil,
    _display_rect = nil,
    _scaled_image_bb = nil, -- Cached scaled image for display
    _is_dirty = false,
}

function PanelViewer:init()
    -- Initialize touch zones for navigation
    self:setupTouchZones()
    
    -- Load and process the image
    self:loadImage()
    
    -- Calculate display dimensions
    self:calculateDisplayRect()
    
    logger.info(string.format("PanelViewer: Initialized with image %dx%d", 
        self._original_size and self._original_size.w or 0,
        self._original_size and self._original_size.h or 0))
end

function PanelViewer:setupTouchZones()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    
    -- Define tap zones: Left 30% (prev), Right 30% (next), Center 40% (close)
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = screen_width,
                    h = screen_height
                }
            }
        }
    }
end

function PanelViewer:loadImage()
    if not self.image and not self.file then
        logger.warn("PanelViewer: No image or file provided")
        return false
    end
    
    local image_bb = nil
    
    -- Load from BlitBuffer
    if self.image then
        image_bb = self.image
        logger.info("PanelViewer: Using provided BlitBuffer")
    -- Load from file with screen-size decoding for sharp rendering
    elseif self.file then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        logger.info(string.format("PanelViewer: Loading image file at screen size %dx%d with dithering: %s", screen_w, screen_h, self.file))
        -- Pass screen dimensions to MuPDF for high-quality scaling during decode
        -- Force grayscale (TYPE_BB8) to prevent color artifacts
        image_bb = RenderImage:renderImageFile(self.file, false, screen_w, screen_h)
        if not image_bb then
            logger.error("PanelViewer: Failed to load image file")
            return false
        end
        
        -- Convert to grayscale if not already
        if image_bb:getType() ~= Blitbuffer.TYPE_BB8 then
            logger.info(string.format("PanelViewer: Converting image from type %d to grayscale (TYPE_BB8)", image_bb:getType()))
            local gray_bb = Blitbuffer.new(image_bb:getWidth(), image_bb:getHeight(), Blitbuffer.TYPE_BB8)
            gray_bb:blitFrom(image_bb)
            image_bb:free()
            image_bb = gray_bb
        end
    end
    
    self._image_bb = image_bb
    self._original_size = {
        w = image_bb:getWidth(),
        h = image_bb:getHeight()
    }
    
    return true
end

function PanelViewer:calculateDisplayRect()
    if not self._image_bb then return end
    
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local img_w = self._original_size.w
    local img_h = self._original_size.h
    
    
    -- Helper function for round-half-up (pixel-perfect symmetric centering)
    local function round(x)
        return math.floor(x + 0.5)
    end
    
    -- Calculate scale to fit screen while maintaining aspect ratio
    local scale_w = screen_w / img_w
    local scale_h = screen_h / img_h
    local scale = math.min(scale_w, scale_h)
    
    -- Calculate display dimensions (final screen size)
    local display_w = math.floor(img_w * scale)
    local display_h = math.floor(img_h * scale)
    
    -- Center the image on screen with pixel-perfect symmetric centering
    -- Use round-half-up instead of floor to prevent left/top bias
    local display_x = round((screen_w - display_w) / 2)
    local display_y = round((screen_h - display_h) / 2)
    
    self._display_rect = {
        x = display_x,
        y = display_y,
        w = display_w,
        h = display_h
    }
    
    -- Create dithered buffer for display if Bayer is enabled
    -- Free existing dithered buffer if different from original
    if self._scaled_image_bb and self._scaled_image_bb ~= self._image_bb then
        self._scaled_image_bb:free()
    end
    
    if self.bayer_dithering_enabled then
        -- Create a copy and apply Bayer dithering
        self._scaled_image_bb = self._image_bb:copy()
        applyBayer8x8(self._scaled_image_bb)
        logger.info("PanelViewer: Bayer dithering applied")
    else
        -- Use original image for built-in dithering
        self._scaled_image_bb = self._image_bb
        logger.info("PanelViewer: Using built-in dithering")
    end
    
    logger.info(string.format("PanelViewer: Display rect %dx%d at (%d,%d) scale=%.3f (%s)", 
        display_w, display_h, display_x, display_y, scale,
        self.bayer_dithering_enabled and "Bayer" or "built-in"))
end

function PanelViewer:onTap(_, ges)
    if not ges or not ges.pos then return false end
    
    local screen_w = Screen:getWidth()
    local x_pct = ges.pos.x / screen_w
    
    -- Determine direction based on reading direction
    local is_rtl = self.reading_direction == "rtl"
    
    -- Zone Logic: In RTL, Left is "Forward". In LTR, Right is "Forward".
    local is_forward = (is_rtl and x_pct < 0.3) or (not is_rtl and x_pct > 0.7)
    local is_backward = (is_rtl and x_pct > 0.7) or (not is_rtl and x_pct < 0.3)
    
    if is_forward then
        logger.info("PanelViewer: Forward tap detected")
        if self.onNext then self.onNext() end
        return true
    elseif is_backward then
        logger.info("PanelViewer: Backward tap detected")
        if self.onPrev then self.onPrev() end
        return true
    end
    
    -- Center tap: Close the viewer
    logger.info("PanelViewer: Center tap detected, closing viewer")
    if self.onClose then self.onClose() end
    return true
end

function PanelViewer:paintTo(bb, x, y)
    if not self._image_bb or not self._scaled_image_bb then return end
    
    -- Get screen-space rectangle (single source of truth)
    local screen_rect = self:getScreenRect()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local white_color = Blitbuffer.Color8(255)
    
    -- Background painting: pure screen coordinates
    -- Paint top area above image
    if screen_rect.y > 0 then
        bb:paintRect(0, 0, screen_w, screen_rect.y, white_color)
    end
    
    -- Paint bottom area below image
    if screen_rect.y + screen_rect.h < screen_h then
        bb:paintRect(0, screen_rect.y + screen_rect.h, screen_w, screen_h - (screen_rect.y + screen_rect.h), white_color)
    end
    
    -- Paint left area
    if screen_rect.x > 0 then
        bb:paintRect(0, screen_rect.y, screen_rect.x, screen_rect.h, white_color)
    end
    
    -- Paint right area
    if screen_rect.x + screen_rect.w < screen_w then
        bb:paintRect(screen_rect.x + screen_rect.w, screen_rect.y, screen_w - (screen_rect.x + screen_rect.w), screen_rect.h, white_color)
    end
    
    -- Use appropriate blitting method based on dithering mode
    if self.bayer_dithering_enabled then
        -- Use standard blit because we've already manually dithered the buffer
        bb:blitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
    else
        -- Use KOReader's built-in dithering
        if Screen.sw_dithering then
            bb:ditherblitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
        else
            bb:blitFrom(self._scaled_image_bb, screen_rect.x, screen_rect.y, 0, 0, screen_rect.w, screen_rect.h)
        end
    end
    
    self._is_dirty = false
end

function PanelViewer:getScreenRect()
    -- Single source of truth for screen-space coordinates
    -- Future-proof: supports animations, transforms, partial redraws
    if not self._display_rect then
        -- Fallback: full screen
        return {
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight()
        }
    end
    
    return {
        x = self._display_rect.x,
        y = self._display_rect.y,
        w = self._display_rect.w,
        h = self._display_rect.h
    }
end

function PanelViewer:getSize()
    return Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight()
    }
end

function PanelViewer:updateImage(new_image)
    -- Update the image source
    if self._image_bb and self._image_bb ~= self.image then
        self._image_bb:free()
    end
    
    self.image = new_image
    self._image_bb = new_image
    self:loadImage()
    self:calculateDisplayRect()
    self._is_dirty = true
    
    logger.info("PanelViewer: Image updated")
end

function PanelViewer:update()
    -- KOADER MUFPDF LOGIC: Use proper refresh types like ImageViewer
    -- For panel viewing, we want "ui" refresh for smooth transitions
    -- and "flashui" for initial display to ensure crisp rendering
    self._is_dirty = true
    UIManager:setDirty(self, function()
        return "ui", self.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    logger.info("PanelViewer: Update called with KOReader refresh logic")
end

function PanelViewer:updateReadingDirection(direction)
    self.reading_direction = direction or "ltr"
    logger.info(string.format("PanelViewer: Reading direction set to %s", self.reading_direction))
end

function PanelViewer:freeResources()
    -- Free the original if it's not externally managed
    if self._image_bb and self._image_bb ~= self.image then
        self._image_bb:free()
        self._image_bb = nil
    end
    -- Free the dithered clone buffer only if using Bayer and it's different
    if self.bayer_dithering_enabled and self._scaled_image_bb and self._scaled_image_bb ~= self._image_bb then
        self._scaled_image_bb:free()
    end
    self._scaled_image_bb = nil
    logger.info(string.format("PanelViewer: Resources freed (%s dithering mode)", 
        self.bayer_dithering_enabled and "Bayer" or "built-in"))
end

function PanelViewer:close()
    self:freeResources()
    UIManager:close(self)
end

return PanelViewer
