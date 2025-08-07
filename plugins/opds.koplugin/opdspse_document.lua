local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local CanvasContext = require("document/canvascontext")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local Screen = require("device").screen
local KOPTContext = require("ffi/koptcontext")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSPSEDocument = Document:extend{
    _document = false,
    is_pic = true,
    dc_null = DrawContext.new(),
    provider = "opdspse",
    provider_name = "OPDS Page Stream Document",
    
    -- OPDSPSE specific properties
    remote_url = nil,
    count = 0,
    username = nil,
    password = nil,
    title = nil,
    page_data_cache = {},
    size_cache = {},
    cover_image_data = nil,
    koptinterface = nil,
}

local OPDSPSEPage = {}

function OPDSPSEPage:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
-- Keep to our usual semantics (extend for class definitions, new for new instances)
OPDSPSEPage.new = OPDSPSEPage.extend

function OPDSPSEPage:draw(dc, bb)
    if self.image_bb then
        local scaled_bb = self.image_bb:scale(bb:getWidth(), bb:getHeight())
        
        -- Apply gamma correction if needed
        local gamma = dc:getGamma()
        if gamma >= 0.0 and gamma ~= 1.0 then
            self:applyGamma(scaled_bb, gamma)
        end
        
        bb:blitFullFrom(scaled_bb, 0, 0)
        scaled_bb:free()
    else
        logger.err("OPDSPSEPage: No image to draw")
    end
end

-- Simple gamma correction implementation using BlitBuffer API
function OPDSPSEPage:applyGamma(bb, gamma)
    -- Build gamma lookup table - use gamma directly, not inverse
    local gamma_table = {}
    for i = 0, 255 do
        local normalized = i / 255.0
        local corrected = normalized ^ gamma  -- Use gamma directly, not inv_gamma
        gamma_table[i] = math.floor(corrected * 255.0 + 0.5)
    end
    
    -- Get the BlitBuffer ffi types we need
    local ffi = require("ffi")
    local Color8 = ffi.typeof("Color8")
    local ColorRGB32 = ffi.typeof("ColorRGB32")
    
    -- Apply gamma correction to each pixel using proper BlitBuffer API
    for y = 0, bb.h - 1 do
        for x = 0, bb.w - 1 do
            local pixel = bb:getPixel(x, y)
            local corrected_pixel
            
            if bb:isRGB() then
                -- For RGB images, apply gamma to each color component
                local r = gamma_table[pixel:getR()]
                local g = gamma_table[pixel:getG()]  
                local b = gamma_table[pixel:getB()]
                local alpha = pixel:getAlpha()
                corrected_pixel = ColorRGB32(r, g, b, alpha)
            else
                -- For grayscale images
                local gray = gamma_table[pixel:getAlpha()]
                corrected_pixel = Color8(gray)
            end
            
            bb:setPixel(x, y, corrected_pixel)
        end
    end
end

function OPDSPSEPage:getSize(dc)
    local zoom = dc:getZoom()
    return self.image_bb:getWidth() * zoom, self.image_bb:getHeight() * zoom
end

function OPDSPSEPage:getUsedBBox()
    return 0.01, 0.01, -0.01, -0.01 -- Minimal bbox
end

function OPDSPSEPage:close()
    if self.image_bb ~= nil then
        self.image_bb:free()
        self.image_bb = nil
    end
end

function OPDSPSEPage:getPagePix(kopt_context)
    if not self.image_bb then
        logger.err("OPDSPSEPage: No image for getPagePix")
        return
    end
    
    -- Get bbox from kopt_context
    local bbox = kopt_context.bbox
    local zoom = kopt_context.zoom
    
    -- Calculate the region to extract based on bbox and zoom
    local img_width = self.image_bb:getWidth()
    local img_height = self.image_bb:getHeight()
    
    -- Apply bbox coordinates (in page coordinates)
    local crop_x0 = math.max(0, math.floor(bbox.x0))
    local crop_y0 = math.max(0, math.floor(bbox.y0))
    local crop_x1 = math.min(img_width, math.ceil(bbox.x1))
    local crop_y1 = math.min(img_height, math.ceil(bbox.y1))
    
    -- Calculate cropped dimensions
    local crop_width = crop_x1 - crop_x0
    local crop_height = crop_y1 - crop_y0
    
    if crop_width <= 0 or crop_height <= 0 then
        logger.warn("OPDSPSEPage: Invalid crop dimensions", crop_width, crop_height)
        crop_x0, crop_y0 = 0, 0
        crop_width, crop_height = img_width, img_height
    end
    
    -- Apply zoom to get final dimensions
    local final_width = math.floor(crop_width * zoom + 0.5)
    local final_height = math.floor(crop_height * zoom + 0.5)
    
    -- Ensure minimum dimensions
    if final_width < 1 then final_width = 1 end
    if final_height < 1 then final_height = 1 end
    
    logger.dbg("OPDSPSEPage: getPagePix - bbox:", bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    logger.dbg("OPDSPSEPage: getPagePix - crop:", crop_x0, crop_y0, crop_width, crop_height)
    logger.dbg("OPDSPSEPage: getPagePix - final size:", final_width, final_height, "zoom:", zoom)
    
    -- Create cropped and scaled version of the image
    local working_bb
    
    -- First crop the image if needed
    if crop_x0 > 0 or crop_y0 > 0 or crop_width < img_width or crop_height < img_height then
        working_bb = self.image_bb:crop(crop_x0, crop_y0, crop_width, crop_height)
    else
        working_bb = self.image_bb
    end
    
    -- Then scale if needed
    local final_bb
    if zoom ~= 1.0 or final_width ~= crop_width or final_height ~= crop_height then
        final_bb = working_bb:scale(final_width, final_height)
        if working_bb ~= self.image_bb then
            working_bb:free() -- Free the cropped version
        end
    else
        final_bb = working_bb
    end
    
    -- Initialize the destination bitmap in kopt_context.src
    KOPTContext.k2pdfopt.bmp_init(kopt_context.src)
    
    -- Convert BlitBuffer to WILLUSBITMAP
    self:blitbufferToWillusBitmap(kopt_context, final_bb, kopt_context.src)
    
    -- Set the page dimensions in kopt_context
    kopt_context.page_width = final_bb:getWidth()
    kopt_context.page_height = final_bb:getHeight()
    
    -- Clean up temporary buffers
    if final_bb ~= self.image_bb then
        final_bb:free()
    end
    
    logger.dbg("OPDSPSEPage: getPagePix completed - size:", kopt_context.page_width, kopt_context.page_height)
end

-- Helper function to convert BlitBuffer to WILLUSBITMAP
function OPDSPSEPage:blitbufferToWillusBitmap(kopt_context, bb, willusbitmap)
    local ffi = require("ffi")
    
    local width = bb:getWidth()
    local height = bb:getHeight()
    local bb_type = bb:getType()
    
    -- Set up WILLUSBITMAP structure
    willusbitmap.width = width
    willusbitmap.height = height
    
    -- Determine bits per pixel based on BlitBuffer type
    if bb:isRGB() then
        willusbitmap.bpp = 24 -- RGB format
    else
        willusbitmap.bpp = 8  -- Grayscale format
    end
    
    -- Allocate memory for the bitmap
    if KOPTContext.k2pdfopt.bmp_alloc(willusbitmap) == 0 then
        logger.err("OPDSPSEPage: Failed to allocate WILLUSBITMAP memory")
        return
    end
    
    -- Set up color palette for grayscale images
    if willusbitmap.bpp == 8 then
        for i = 0, 255 do
            willusbitmap.red[i] = i
            willusbitmap.green[i] = i  
            willusbitmap.blue[i] = i
        end
    end
    
    -- Copy pixel data from BlitBuffer to WILLUSBITMAP
    local data_ptr = ffi.cast("unsigned char*", willusbitmap.data)
    local bytes_per_pixel = willusbitmap.bpp / 8
    local bytes_per_line = width * bytes_per_pixel
    
    for y = 0, height - 1 do
        local line_offset = y * bytes_per_line
        for x = 0, width - 1 do
            local pixel = bb:getPixel(x, y)
            local pixel_offset = line_offset + x * bytes_per_pixel
            
            if willusbitmap.bpp == 24 then
                -- RGB format - note: WILLUSBITMAP expects BGR order
                data_ptr[pixel_offset] = pixel:getB()     -- Blue
                data_ptr[pixel_offset + 1] = pixel:getG() -- Green  
                data_ptr[pixel_offset + 2] = pixel:getR() -- Red
            else
                -- Grayscale format
                local gray = pixel:getAlpha() -- For grayscale BlitBuffer
                data_ptr[pixel_offset] = gray
            end
        end
    end
end

function OPDSPSEDocument:init()
    self:updateColorRendering()
    
    -- Read the .opdspse file to get configuration
    local config = self:readConfig()
    if not config then
        error("Failed to read OPDSPSE configuration")
    end
    
    self.koptinterface = require("document/koptinterface")
    self.koptinterface:setDefaultConfigurable(self.configurable)

    self.remote_url = config.remote_url
    self.count = config.count
    self.username = config.username
    self.password = config.password
    self.title = config.title or "OPDS Streaming Document"
    
    -- Create a mock document object for compatibility
    self._document = self
    
    -- Set up document properties
    self.is_open = true
    self.info.has_pages = true
    self.info.configurable = true
    self.info.number_of_pages = self.count
    
    -- Enforce dithering like PicDocument
    if CanvasContext:hasEinkScreen() then
        if CanvasContext:canHWDither() then
            self.hw_dithering = true
        elseif CanvasContext.fb_bpp == 8 then
            self.sw_dithering = true
        end
    end

    self:_readMetadata()
    self.page_data_cache = {}
    self.size_cache = {}
    self.cover_image_data = nil
    logger.info("OPDSPSEDocument: Initialized with", self.count, "pages")
end

function OPDSPSEDocument:readConfig()
    local file = io.open(self.file, "r")
    if not file then
        logger.err("OPDSPSEDocument: Cannot open file", self.file)
        return nil
    end
    
    local content = file:read("*all")
    file:close()
    
    -- Parse the simple config format
    local config = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
            key = key:gsub("^%s*(.-)%s*$", "%1") -- trim
            value = value:gsub("^%s*(.-)%s*$", "%1") -- trim
            
            if key == "count" then
                config[key] = tonumber(value)
            else
                config[key] = value
            end
        end
    end
    
    -- Validate required fields
    if not config.remote_url or not config.count then
        logger.err("OPDSPSEDocument: Missing required fields in config")
        return nil
    end
    
    return config
end

function OPDSPSEDocument:getToc()
    return {}
end

function OPDSPSEDocument:getPages()
    return self.count
end

function OPDSPSEDocument:getOriginalPageSize(pageno)
    local cached_size = self.size_cache[pageno]
    if cached_size ~= nil then
        return cached_size.width, cached_size.height, 4 -- width, height, components
    end
    -- Fallback to actual image size if not cached
    local pageImage = self:getPageImage(pageno)
    if not pageImage then
        logger.warn("OPDSPSEDocument: No image for page", pageno)
        return Screen:getWidth(), Screen:getHeight(), 4 -- Default to zero size if no image
    end
    return pageImage:getWidth(), pageImage:getHeight(), 4 -- width, height, components
end

function OPDSPSEDocument:getUsedBBox(pageno)
    local width, height, _ = self:getOriginalPageSize(pageno)
    return { x0 = 0, y0 = 0, x1 = width, y1 = height }
end

function OPDSPSEDocument:getDocumentProps()
    return {
        title = self.title,
        pages = self.count,
    }
end

function OPDSPSEDocument:getCoverPageImage()
    -- Return the first page as cover
    if self.cover_image_data then
        return RenderImage:renderImageData(self.cover_image_data, #self.cover_image_data, false)
    end

    local first_page = self:openPage(1)
    if first_page and first_page.image_bb then
        return first_page.image_bb:copy()
    end
    return nil
end

-- This mimics the PicDocument API
function OPDSPSEDocument:openPage(pageno)
    local page_bb = self:getPageImage(pageno)
    if not page_bb then
        logger.err("OPDSPSEDocument: Failed to get page image for page", pageno)
        page_bb = RenderImage:renderImageFile("resources/koreader.png", false)
    end
    
    local width = page_bb and page_bb:getWidth() or 0
    local height = page_bb and page_bb:getHeight() or 0
    
    return OPDSPSEPage:new{
        image_bb = page_bb,
        width = width,
        height = height,
        doc = self,
    }
end

function OPDSPSEDocument:getPageImage(pageno)
    if pageno <= 0 or pageno > self.count then
        logger.warn("OPDSPSEDocument: Invalid page number", pageno)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end
    
    -- Download and render the page
    local page_bb = self:downloadPage(pageno)
    if not page_bb then
        logger.err("OPDSPSEDocument: Failed to download page", pageno)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end

    if #self.size_cache > 10 then
        -- Simple cache eviction: remove first item
        for k, v in pairs(self.size_cache) do
            self.size_cache[k] = nil
            break
        end
    end
    
    if page_bb then
        self.size_cache[pageno] = { width = page_bb:getWidth(), height = page_bb:getHeight() }
    end

    return page_bb
end

function OPDSPSEDocument:getOrDownloadPageData(pageno)
    -- Check cache first
    if self.page_data_cache[pageno] then
        logger.dbg("OPDSPSEDocument: Using cached page", pageno)
        return self.page_data_cache[pageno]
    end

    local code, headers, status
    local index = pageno - 1 -- Convert to zero-based index
    local page_url = self.remote_url:gsub("{pageNumber}", tostring(index))
    page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
    local page_data = {}

    logger.dbg("OPDSPSEDocument: Downloading page from", page_url)
    local parsed = url.parse(page_url)
    if parsed.scheme == "http" or parsed.scheme == "https" then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        code, headers, status = socket.skip(1, http.request {
            url         = page_url,
            headers     = {
                ["Accept-Encoding"] = "identity",
            },
            sink        = ltn12.sink.table(page_data),
            user        = self.username,
            password    = self.password,
        })
        socketutil:reset_timeout()
    else
        logger.err("OPDSPSEDocument: Invalid protocol", parsed.scheme)
        return nil
    end

    local data = table.concat(page_data)
    if code == 200 then
        if #self.page_data_cache > 3 then
            -- Simple cache eviction: remove first item
            for k, v in pairs(self.page_data_cache) do
                self.page_data_cache[k] = nil
                break
            end
            collectgarbage()
            collectgarbage()
        end
        self.page_data_cache[pageno] = data -- Cache the downloaded data
        logger.dbg("OPDSPSEDocument: Successfully downloaded page", pageno)
        return data
    else
        logger.dbg("OPDSPSEDocument: Request failed:", status or code)
        logger.dbg("OPDSPSEDocument: Response headers:", headers)
        return nil
    end
end

function OPDSPSEDocument:downloadPage(pageno)
    local data = self:getOrDownloadPageData(pageno)
    if pageno == 1 then
        self.cover_image_data = data -- Cache cover image data
    elseif self.cover_image_data == nil then
        self.cover_image_data = self:getOrDownloadPageData(1)
    end
    if not data then
        return RenderImage:renderImageFile("resources/koreader.png", false)
    else
        local page_bb = RenderImage:renderImageData(data, #data, false)
        if not page_bb then
            logger.err("OPDSPSEDocument: Failed to render page", pageno)
            return RenderImage:renderImageFile("resources/koreader.png", false)
        end
        return page_bb
    end
end

function OPDSPSEDocument:close()
    if self.is_open then
        self.is_open = false
        -- Clear cache
        self.page_data_cache = {}
        self.size_cache = {}
        self.cover_image_data = nil
        if self.file then
            local util = require("util")
            util.removeFile(self.file)
        end
        logger.dbg("OPDSPSEDocument: Document closed")
    end
end

-- 

function OPDSPSEDocument:getPageTextBoxes(pageno)
    return ""
end

function OPDSPSEDocument:comparePositions(pos1, pos2)
    return self.koptinterface:comparePositions(self, pos1, pos2)
end

function OPDSPSEDocument:getPanelFromPage(pageno, pos)
    return self.koptinterface:getPanelFromPage(self, pageno, pos)
end

function OPDSPSEDocument:getWordFromPosition(spos)
    return self.koptinterface:getWordFromPosition(self, spos)
end

function OPDSPSEDocument:getTextFromPositions(spos0, spos1)
    return self.koptinterface:getTextFromPositions(self, spos0, spos1)
end

function OPDSPSEDocument:getTextBoxes(pageno)
    return self.koptinterface:getTextBoxes(self, pageno)
end

function OPDSPSEDocument:getPageBoxesFromPositions(pageno, ppos0, ppos1)
    return self.koptinterface:getPageBoxesFromPositions(self, pageno, ppos0, ppos1)
end

function OPDSPSEDocument:nativeToPageRectTransform(pageno, rect)
    return self.koptinterface:nativeToPageRectTransform(self, pageno, rect)
end

function OPDSPSEDocument:getSelectedWordContext(word, nb_words, pos)
    return self.koptinterface:getSelectedWordContext(word, nb_words, pos)
end

function OPDSPSEDocument:getOCRWord(pageno, wbox)
    return self.koptinterface:getOCRWord(self, pageno, wbox)
end

function OPDSPSEDocument:getOCRText(pageno, tboxes)
    return self.koptinterface:getOCRText(self, pageno, tboxes)
end

function OPDSPSEDocument:getPageBlock(pageno, x, y)
    return self.koptinterface:getPageBlock(self, pageno, x, y)
end

function OPDSPSEDocument:getPageBBox(pageno)
    return self.koptinterface:getPageBBox(self, pageno)
end

function OPDSPSEDocument:getPageDimensions(pageno, zoom, rotation)
    return self.koptinterface:getPageDimensions(self, pageno, zoom, rotation)
end

function OPDSPSEDocument:findText(pattern, origin, reverse, case_insensitive, page)
    return self.koptinterface:findText(self, pattern, origin, reverse, case_insensitive, page)
end

function OPDSPSEDocument:findAllText(pattern, case_insensitive, nb_context_words, max_hits)
    return self.koptinterface:findAllText(self, pattern, case_insensitive, nb_context_words, max_hits)
end

function OPDSPSEDocument:renderPage(pageno, rect, zoom, rotation, gamma, hinting)
    return self.koptinterface:renderPage(self, pageno, rect, zoom, rotation, gamma, hinting)
end

function OPDSPSEDocument:hintPage(pageno, zoom, rotation, gamma)
    return self.koptinterface:hintPage(self, pageno, zoom, rotation, gamma)
end

function OPDSPSEDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma)
    return self.koptinterface:drawPage(self, target, x, y, rect, pageno, zoom, rotation, gamma)
end

-- 

function OPDSPSEDocument:register(registry)
    registry:addProvider("opdspse", "application/opdspse", self, 100)
end

return OPDSPSEDocument
