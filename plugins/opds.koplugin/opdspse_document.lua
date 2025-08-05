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
        bb:blitFullFrom(scaled_bb, 0, 0)
        scaled_bb:free()
    else
        logger.err("OPDSPSEPage: No image to draw")
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

function OPDSPSEDocument:init()
    self:updateColorRendering()
    
    -- Read the .opdspse file to get configuration
    local config = self:readConfig()
    if not config then
        error("Failed to read OPDSPSE configuration")
    end
    
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
    self.info.configurable = false
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

function OPDSPSEDocument:getCacheSize()
    return self.page_data_cache and #self.page_data_cache or 0
end

function OPDSPSEDocument:cleanCache()
    self.page_data_cache = {}
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
    return OPDSPSEPage:new{
        image_bb = page_bb,
        width = page_bb:getWidth(),
        height = page_bb:getHeight(),
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

    if #self.size_cache > 10 then
        -- Simple cache eviction: remove first item
        for k, v in pairs(self.size_cache) do
            self.size_cache[k] = nil
            break
        end
    end
    self.size_cache[pageno] = { width = page_bb:getWidth(), height = page_bb:getHeight() }
    
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

function OPDSPSEDocument:register(registry)
    registry:addProvider("opdspse", "application/opdspse", self, 100)
end

return OPDSPSEDocument
