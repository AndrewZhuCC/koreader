local Document = require("document/document")
local DocCache = require("document/doccache")
local DrawContext = require("ffi/drawcontext")
local CanvasContext = require("document/canvascontext")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local logger = require("logger")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local Screen = require("device").screen
local KOPTContext = require("ffi/koptcontext")

local OPDSPSEDocument = Document:extend{
    _document = false,
    is_pic = true,
    dc_null = DrawContext.new(),
    provider = "opdspse",
    provider_name = "OPDS Page Stream Document",

    remote_url = nil,
    count = 0,
    username = nil,
    password = nil,
    title = nil,
    -- NOTE: table fields here are shared across all instances via the class prototype.
    -- They are re-initialized per-instance in init().
    koptinterface = nil,
}

local OPDSPSEPage = {}

function OPDSPSEPage:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
OPDSPSEPage.new = OPDSPSEPage.extend

function OPDSPSEPage:draw(dc, bb, x_offset, y_offset)
    if not self.image_bb then
        logger.err("OPDSPSEPage: No image to draw")
        return
    end

    x_offset = x_offset or 0
    y_offset = y_offset or 0

    local target_w = bb:getWidth()
    local target_h = bb:getHeight()
    local zoom = dc:getZoom()
    local src_w = self.image_bb:getWidth()
    local src_h = self.image_bb:getHeight()

    local scaled_bb
    if x_offset == 0 and y_offset == 0 then
        -- Full-page render: scale the whole image to the target BB size.
        if self.image_data and (target_w ~= src_w or target_h ~= src_h) then
            scaled_bb = RenderImage:renderImageData(
                self.image_data, #self.image_data, false, target_w, target_h)
        end
        if not scaled_bb then
            scaled_bb = self.image_bb:scale(target_w, target_h)
        end
    else
        -- Partial render (e.g. panel zoom from drawPagePart):
        -- x_offset/y_offset are in *zoomed* coordinates.  Map back to
        -- original image coordinates, crop, then scale up to target size.
        local crop_x = math.max(0, math.floor(x_offset / zoom))
        local crop_y = math.max(0, math.floor(y_offset / zoom))
        local crop_w = math.min(src_w - crop_x, math.ceil(target_w / zoom))
        local crop_h = math.min(src_h - crop_y, math.ceil(target_h / zoom))
        if crop_w > 0 and crop_h > 0 then
            local cropped = self.image_bb:viewport(crop_x, crop_y, crop_w, crop_h)
            scaled_bb = cropped:scale(target_w, target_h)
        else
            scaled_bb = self.image_bb:scale(target_w, target_h)
        end
    end

    local gamma = dc:getGamma()
    if gamma >= 0.0 and gamma ~= 1.0 then
        self:applyGamma(scaled_bb, gamma)
    end

    bb:blitFullFrom(scaled_bb, 0, 0)
    scaled_bb:free()
end

function OPDSPSEPage:applyGamma(bb, gamma)
    local ffi = require("ffi")
    local uint8pt = ffi.typeof("uint8_t*")

    local lut = ffi.new("uint8_t[256]")
    for i = 0, 255 do
        local v = math.floor(((i / 255.0) ^ gamma) * 255.0 + 0.5)
        lut[i] = v < 0 and 0 or (v > 255 and 255 or v)
    end

    local w, h = bb.w, bb.h
    local stride = tonumber(bb.stride)
    local data = ffi.cast(uint8pt, bb.data)
    local bb_type = bb:getType()

    if bb_type == 5 then -- TYPE_BBRGB32
        for y = 0, h - 1 do
            local row = data + y * stride
            for x = 0, w - 1 do
                local off = x * 4
                row[off]     = lut[row[off]]
                row[off + 1] = lut[row[off + 1]]
                row[off + 2] = lut[row[off + 2]]
            end
        end
    elseif bb_type == 1 then -- TYPE_BB8
        for y = 0, h - 1 do
            local row = data + y * stride
            for x = 0, w - 1 do
                row[x] = lut[row[x]]
            end
        end
    elseif bb_type == 4 then -- TYPE_BBRGB24
        for y = 0, h - 1 do
            local row = data + y * stride
            for x = 0, w - 1 do
                local off = x * 3
                row[off]     = lut[row[off]]
                row[off + 1] = lut[row[off + 1]]
                row[off + 2] = lut[row[off + 2]]
            end
        end
    else
        logger.warn("OPDSPSEPage:applyGamma: unsupported BB type", bb_type)
    end
end

function OPDSPSEPage:getSize(dc)
    local zoom = dc:getZoom()
    return self.image_bb:getWidth() * zoom, self.image_bb:getHeight() * zoom
end

function OPDSPSEPage:getUsedBBox()
    return 0.01, 0.01, -0.01, -0.01
end

function OPDSPSEPage:close()
    if self.image_bb ~= nil then
        self.image_bb:free()
        self.image_bb = nil
    end
    self.image_data = nil
end

function OPDSPSEPage:getPagePix(kopt_context)
    if not self.image_bb then
        logger.err("OPDSPSEPage: No image for getPagePix")
        return
    end

    local bbox = kopt_context.bbox
    local zoom = kopt_context.zoom

    local img_width = self.image_bb:getWidth()
    local img_height = self.image_bb:getHeight()

    local crop_x0 = math.max(0, math.floor(bbox.x0))
    local crop_y0 = math.max(0, math.floor(bbox.y0))
    local crop_x1 = math.min(img_width, math.ceil(bbox.x1))
    local crop_y1 = math.min(img_height, math.ceil(bbox.y1))

    local crop_width = crop_x1 - crop_x0
    local crop_height = crop_y1 - crop_y0

    if crop_width <= 0 or crop_height <= 0 then
        logger.warn("OPDSPSEPage: Invalid crop dimensions", crop_width, crop_height)
        crop_x0, crop_y0 = 0, 0
        crop_width, crop_height = img_width, img_height
    end

    local final_width = math.max(1, math.floor(crop_width * zoom + 0.5))
    local final_height = math.max(1, math.floor(crop_height * zoom + 0.5))

    logger.dbg("OPDSPSEPage: getPagePix - bbox:", bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    logger.dbg("OPDSPSEPage: getPagePix - crop:", crop_x0, crop_y0, crop_width, crop_height)
    logger.dbg("OPDSPSEPage: getPagePix - final size:", final_width, final_height, "zoom:", zoom)

    -- Crop via a sub-BlitBuffer view (no allocation), then scale
    local working_bb
    if crop_x0 > 0 or crop_y0 > 0 or crop_width < img_width or crop_height < img_height then
        working_bb = self.image_bb:viewport(crop_x0, crop_y0, crop_width, crop_height)
    else
        working_bb = self.image_bb
    end

    local final_bb
    if final_width ~= working_bb:getWidth() or final_height ~= working_bb:getHeight() then
        final_bb = working_bb:scale(final_width, final_height)
    else
        final_bb = working_bb:copy()
    end

    KOPTContext.k2pdfopt.bmp_init(kopt_context.src)
    self:blitbufferToWillusBitmap(final_bb, kopt_context.src)

    kopt_context.page_width = final_bb:getWidth()
    kopt_context.page_height = final_bb:getHeight()

    final_bb:free()

    logger.dbg("OPDSPSEPage: getPagePix completed - size:", kopt_context.page_width, kopt_context.page_height)
end

function OPDSPSEPage:blitbufferToWillusBitmap(bb, willusbitmap)
    local ffi = require("ffi")
    local uint8pt = ffi.typeof("uint8_t*")

    local width = bb:getWidth()
    local height = bb:getHeight()

    willusbitmap.width = width
    willusbitmap.height = height

    if bb:isRGB() then
        willusbitmap.bpp = 24
    else
        willusbitmap.bpp = 8
    end

    if KOPTContext.k2pdfopt.bmp_alloc(willusbitmap) == 0 then
        logger.err("OPDSPSEPage: Failed to allocate WILLUSBITMAP memory")
        return
    end

    -- Use bmp_bytewidth for the actual row stride (4-byte aligned)
    local bmp_stride = KOPTContext.k2pdfopt.bmp_bytewidth(willusbitmap)
    local data_ptr = ffi.cast(uint8pt, willusbitmap.data)

    local bb_stride = tonumber(bb.stride)
    local bb_data = ffi.cast(uint8pt, bb.data)
    local bb_type = bb:getType()

    if willusbitmap.bpp == 8 then
        for i = 0, 255 do
            willusbitmap.red[i] = i
            willusbitmap.green[i] = i
            willusbitmap.blue[i] = i
        end

        if bb_type == 1 then -- TYPE_BB8: direct memcpy per row
            for y = 0, height - 1 do
                ffi.copy(data_ptr + y * bmp_stride, bb_data + y * bb_stride, width)
            end
        else
            for y = 0, height - 1 do
                local dst_row = data_ptr + y * bmp_stride
                local src_row = bb_data + y * bb_stride
                for x = 0, width - 1 do
                    dst_row[x] = src_row[x]
                end
            end
        end
    else -- bpp == 24
        if bb_type == 5 then -- TYPE_BBRGB32: R,G,B,A -> B,G,R
            for y = 0, height - 1 do
                local dst_row = data_ptr + y * bmp_stride
                local src_row = bb_data + y * bb_stride
                for x = 0, width - 1 do
                    local si = x * 4
                    local di = x * 3
                    dst_row[di]     = src_row[si + 2] -- B
                    dst_row[di + 1] = src_row[si + 1] -- G
                    dst_row[di + 2] = src_row[si]     -- R
                end
            end
        elseif bb_type == 4 then -- TYPE_BBRGB24: R,G,B -> B,G,R
            for y = 0, height - 1 do
                local dst_row = data_ptr + y * bmp_stride
                local src_row = bb_data + y * bb_stride
                for x = 0, width - 1 do
                    local si = x * 3
                    local di = x * 3
                    dst_row[di]     = src_row[si + 2] -- B
                    dst_row[di + 1] = src_row[si + 1] -- G
                    dst_row[di + 2] = src_row[si]     -- R
                end
            end
        else
            -- Fallback: use getPixel (slow but correct for any BB type)
            for y = 0, height - 1 do
                local dst_row = data_ptr + y * bmp_stride
                for x = 0, width - 1 do
                    local pixel = bb:getPixel(x, y)
                    local di = x * 3
                    dst_row[di]     = pixel:getB()
                    dst_row[di + 1] = pixel:getG()
                    dst_row[di + 2] = pixel:getR()
                end
            end
        end
    end
end

function OPDSPSEDocument:init()
    self:updateColorRendering()

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

    self._document = self

    self.is_open = true
    self.info.has_pages = true
    self.info.configurable = true
    self.info.number_of_pages = self.count

    if CanvasContext:hasEinkScreen() then
        if CanvasContext:canHWDither() then
            self.hw_dithering = true
        elseif CanvasContext.fb_bpp == 8 then
            self.sw_dithering = true
        end
    end

    -- Per-instance caches (avoid sharing via class prototype)
    self.page_data_cache = {}
    self.page_data_cache_count = 0
    self.size_cache = {}
    self.size_cache_count = 0
    self.cover_image_data = nil
    self._next_chapter_count = nil
    self._next_chapter_probed = false

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

    local config = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
            key = key:gsub("^%s*(.-)%s*$", "%1")
            value = value:gsub("^%s*(.-)%s*$", "%1")

            if key == "count" then
                config[key] = tonumber(value)
            else
                config[key] = value
            end
        end
    end

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

--- Override: only cache dimensions when the real image has been downloaded.
--- Placeholder images must never pollute the pgdim DocCache or size_cache,
--- otherwise a later successful retry would still render at the wrong size.
function OPDSPSEDocument:getNativePageDimensions(pageno)
    local hash = "pgdim|"..self.file.."|"..self.mod_time.."|"..pageno
    local cached = DocCache:check(hash)
    if cached then
        return cached[1]
    end
    local page = self._document:openPage(pageno)
    local page_size_w, page_size_h = page:getSize(self.dc_null)
    local page_size = Geom:new{ w = page_size_w, h = page_size_h }
    -- Only persist to DocCache when we have real image data for this page.
    if self.page_data_cache[pageno] then
        local CacheItem = require("cacheitem")
        DocCache:insert(hash, CacheItem:new{ page_size })
    end
    page:close()
    return page_size
end

function OPDSPSEDocument:getOriginalPageSize(pageno)
    local cached_size = self.size_cache[pageno]
    if cached_size ~= nil then
        return cached_size.width, cached_size.height, 4
    end
    local pageImage = self:getPageImage(pageno)
    if not pageImage then
        logger.warn("OPDSPSEDocument: No image for page", pageno)
        return Screen:getWidth(), Screen:getHeight(), 4
    end
    local w, h = pageImage:getWidth(), pageImage:getHeight()
    pageImage:free()
    return w, h, 4
end

function OPDSPSEDocument:getUsedBBox(pageno)
    local width, height = self:getOriginalPageSize(pageno)
    return { x0 = 0, y0 = 0, x1 = width, y1 = height }
end

function OPDSPSEDocument:getDocumentProps()
    return {
        title = self.title,
        pages = self.count,
    }
end

function OPDSPSEDocument:getCoverPageImage()
    if self.cover_image_data then
        return RenderImage:renderImageData(self.cover_image_data, #self.cover_image_data, false)
    end

    local data = self:getOrDownloadPageData(1)
    if data then
        self.cover_image_data = data
        return RenderImage:renderImageData(data, #data, false)
    end
    return nil
end

function OPDSPSEDocument:openPage(pageno)
    local image_data = self:getOrDownloadPageData(pageno)

    if pageno == 1 then
        self.cover_image_data = image_data
    elseif self.cover_image_data == nil then
        self.cover_image_data = self:getOrDownloadPageData(1)
    end

    local page_bb
    if image_data then
        page_bb = RenderImage:renderImageData(image_data, #image_data, false)
    end
    if not page_bb then
        logger.err("OPDSPSEDocument: Failed to get page image for page", pageno)
        page_bb = RenderImage:renderImageFile("resources/koreader.png", false)
        image_data = nil
    end

    return OPDSPSEPage:new{
        image_bb = page_bb,
        image_data = image_data,
        width = page_bb and page_bb:getWidth() or 0,
        height = page_bb and page_bb:getHeight() or 0,
        doc = self,
    }
end

function OPDSPSEDocument:getPageImage(pageno)
    if pageno <= 0 or pageno > self.count then
        logger.warn("OPDSPSEDocument: Invalid page number", pageno)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end

    local page_bb = self:downloadPage(pageno)
    if not page_bb then
        logger.err("OPDSPSEDocument: Failed to download page", pageno)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end

    -- Only cache the size when we have real image data (not a placeholder).
    if self.page_data_cache[pageno] then
        if self.size_cache_count > 10 then
            for k in pairs(self.size_cache) do
                self.size_cache[k] = nil
                self.size_cache_count = self.size_cache_count - 1
                break
            end
        end
        self.size_cache[pageno] = { width = page_bb:getWidth(), height = page_bb:getHeight() }
        self.size_cache_count = self.size_cache_count + 1
    end

    return page_bb
end

function OPDSPSEDocument:getOrDownloadPageData(pageno)
    if self.page_data_cache[pageno] then
        logger.dbg("OPDSPSEDocument: Using cached page", pageno)
        return self.page_data_cache[pageno]
    end

    local index = pageno - 1
    local page_url = self.remote_url:gsub("{pageNumber}", tostring(index))
    page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
    local page_data = {}

    logger.dbg("OPDSPSEDocument: Downloading page from", page_url)
    local parsed = url.parse(page_url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        logger.err("OPDSPSEDocument: Invalid protocol", parsed.scheme)
        return nil
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request {
        url         = page_url,
        headers     = {
            ["Accept-Encoding"] = "identity",
        },
        sink        = ltn12.sink.table(page_data),
        user        = self.username,
        password    = self.password,
    })
    socketutil:reset_timeout()

    local data = table.concat(page_data)
    if code == 200 then
        if self.page_data_cache_count > 3 then
            for k in pairs(self.page_data_cache) do
                self.page_data_cache[k] = nil
                self.page_data_cache_count = self.page_data_cache_count - 1
                break
            end
            collectgarbage()
            collectgarbage()
        end
        self.page_data_cache[pageno] = data
        self.page_data_cache_count = self.page_data_cache_count + 1
        logger.dbg("OPDSPSEDocument: Successfully downloaded page", pageno)

        -- When approaching the last page, prefetch next-chapter metadata
        -- so the EndOfBook dialog can show the button without delay.
        if self._next_chapter_count == nil
                and self._next_chapter_probed ~= true
                and pageno >= self.count - 2 then
            self:probeNextChapter()
            self._next_chapter_probed = true
        end

        return data
    else
        logger.dbg("OPDSPSEDocument: Request failed:", status or code)
        -- Only shrink page count on definitive 404 (page truly doesn't exist).
        -- Timeouts, network errors, and transient failures (code is nil or
        -- not a number) must NOT shrink the count — the page may still exist
        -- and the user can retry by flipping back and forth.
        if code == 404 and pageno > 1 and pageno <= self.count then
            self:adjustPageCount(pageno - 1)
        else
            -- Invalidate the tile cache so the placeholder image won't be
            -- permanently cached in DocCache.  Next time the user navigates
            -- to this page, renderPage will discard the stale tile and call
            -- openPage again, which re-triggers the HTTP download.
            self:resetTileCacheValidity()
        end
        -- Purge any stale dimension caches that may have been written from
        -- a placeholder image, so a successful retry picks up the real size.
        self.size_cache[pageno] = nil
        local pgdim_hash = "pgdim|"..self.file.."|"..self.mod_time.."|"..pageno
        DocCache.cache:delete(pgdim_hash)
        return nil
    end
end

function OPDSPSEDocument:adjustPageCount(real_count)
    logger.info("OPDSPSEDocument: Adjusting page count from", self.count, "to", real_count)
    self.count = real_count
    self.info.number_of_pages = real_count
    -- Sync ReaderPaging's cached number_of_pages so progress bar and
    -- EndOfBook detection use the correct value.
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        local paging = ReaderUI.instance.paging
        if paging then
            paging.number_of_pages = real_count
        end
    end
end

function OPDSPSEDocument:downloadPage(pageno)
    local data = self:getOrDownloadPageData(pageno)
    if pageno == 1 then
        self.cover_image_data = data
    elseif self.cover_image_data == nil then
        self.cover_image_data = self:getOrDownloadPageData(1)
    end
    if not data then
        -- If count was just shrunk past this page, the page simply doesn't
        -- exist.  Return nil so the caller can handle it (e.g. trigger
        -- EndOfBook) instead of showing a placeholder image.
        if pageno > self.count then
            return nil
        end
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end
    local page_bb = RenderImage:renderImageData(data, #data, false)
    if not page_bb then
        logger.err("OPDSPSEDocument: Failed to render page", pageno)
        return RenderImage:renderImageFile("resources/koreader.png", false)
    end
    return page_bb
end

function OPDSPSEDocument:close()
    if self.is_open then
        self.is_open = false
        self.page_data_cache = {}
        self.page_data_cache_count = 0
        self.size_cache = {}
        self.size_cache_count = 0
        self.cover_image_data = nil
        if self.file then
            local util = require("util")
            util.removeFile(self.file)
        end
        logger.dbg("OPDSPSEDocument: Document closed")
    end
end

--- Extract (prefix, chapter_id_str, page_suffix) from remote_url.
--- prefix ends with "/chapter/", page_suffix starts from "/page/...".
--- Returns nil when the URL doesn't match any known pattern.
function OPDSPSEDocument:parseChapterUrl(a_url)
    a_url = a_url or self.remote_url
    if not a_url then return nil end
    -- /series/1559/chapter/28/page/{pageNumber}?...
    local prefix, id_str, suffix = a_url:match("^(.*/chapter/)(%d+)(/.*)$")
    if not prefix then
        -- chapterId=28
        prefix, id_str, suffix = a_url:match("^(.*chapterId=)(%d+)(.*)$")
    end
    if prefix and id_str then
        return prefix, id_str, suffix
    end
    return nil
end

--- Build the remote_url for the next chapter (chapter ID + 1).
function OPDSPSEDocument:getNextChapterUrl()
    local prefix, id_str, suffix = self:parseChapterUrl()
    if not prefix then
        logger.dbg("OPDSPSEDocument: Cannot extract chapter ID from URL:", self.remote_url)
        return nil, nil
    end
    local next_id = tonumber(id_str) + 1
    return prefix .. tostring(next_id) .. suffix, next_id
end

--- Build a metadata URL from a page-stream URL.
--- The stream URL uses /api/v1/manga/{id}/chapter/{ch}/page/...
--- but metadata lives at  /api/opds/v1.2/series/{id}/chapter/{ch}/metadata
--- Also handles the case where the URL already uses the OPDS path.
function OPDSPSEDocument:buildMetadataUrl(chapter_url)
    local base = chapter_url:match("^(.*/chapter/%d+/)")
    if not base then return nil end
    -- Rewrite /api/v1/manga/ → /api/opds/v1.2/series/ if needed
    base = base:gsub("/api/v1/manga/", "/api/opds/v1.2/series/")
    return base .. "metadata"
end

--- Fetch chapter metadata from the OPDS server.
--- The metadata endpoint returns an Atom/XML feed with pse:count in the
--- stream link.  Returns (count, true) on success, (nil, false) on failure.
function OPDSPSEDocument:fetchChapterMetadata(chapter_url)
    local meta_url = self:buildMetadataUrl(chapter_url)
    if not meta_url then return nil, false end

    logger.dbg("OPDSPSEDocument: Fetching chapter metadata:", meta_url)
    local parsed = url.parse(meta_url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil, false
    end

    local resp_data = {}
    socketutil:set_timeout(5, 10)
    local code = socket.skip(1, http.request {
        url      = meta_url,
        headers  = { ["Accept-Encoding"] = "identity" },
        sink     = ltn12.sink.table(resp_data),
        user     = self.username,
        password = self.password,
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.dbg("OPDSPSEDocument: Metadata request returned", code)
        return nil, false
    end

    local body = table.concat(resp_data)
    -- The response is Atom XML; extract pse:count="N" from the PSE stream link
    local count = tonumber(body:match('pse:count="(%d+)"'))
                  or tonumber(body:match(':count="(%d+)"'))
    if count and count > 0 then
        return count, true
    end
    logger.dbg("OPDSPSEDocument: No pse:count found in metadata response")
    return nil, false
end

--- Probe the next chapter via its metadata endpoint.
--- Returns (count_of_next_chapter) on success, nil if it doesn't exist.
function OPDSPSEDocument:probeNextChapter()
    local next_url = self:getNextChapterUrl()
    if not next_url then return nil end

    -- Try metadata API first (gives us the real page count)
    local count, ok = self:fetchChapterMetadata(next_url)
    if ok and count then
        logger.dbg("OPDSPSEDocument: Next chapter exists, pages:", count)
        self._next_chapter_count = count
        return count
    end

    -- Fallback: probe by requesting the first page with minimal data
    local test_url = next_url:gsub("{pageNumber}", "0")
    test_url = test_url:gsub("{maxWidth}", "1")
    logger.dbg("OPDSPSEDocument: Metadata failed, probing first page:", test_url)
    local parsed = url.parse(test_url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil
    end
    socketutil:set_timeout(5, 10)
    local code = socket.skip(1, http.request {
        url     = test_url,
        headers = { ["Accept-Encoding"] = "identity" },
        sink    = ltn12.sink.null(),
        user    = self.username,
        password = self.password,
    })
    socketutil:reset_timeout()
    if code == 200 then
        logger.dbg("OPDSPSEDocument: Next chapter exists (via page probe), using current count as fallback")
        self._next_chapter_count = self.count
        return self.count
    end

    logger.dbg("OPDSPSEDocument: Next chapter does not exist, probe returned", code)
    self._next_chapter_count = nil
    return nil
end

--- Open the next chapter as a new streaming document.
function OPDSPSEDocument:openNextChapter()
    local next_url = self:getNextChapterUrl()
    if not next_url then return false end

    local count = self._next_chapter_count or self.count
    local OPDSPSE = require("opdspse")
    return OPDSPSE:streamPages(next_url, count, false, self.username, self.password)
end

-- KoptInterface delegate methods

function OPDSPSEDocument:getPageTextBoxes()
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

function OPDSPSEDocument:register(registry)
    registry:addProvider("opdspse", "application/opdspse", self, 100)
end

return OPDSPSEDocument
