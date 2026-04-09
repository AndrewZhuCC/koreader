local Document = require("document/document")
local DocCache = require("document/doccache")
local DrawContext = require("ffi/drawcontext")
local CanvasContext = require("document/canvascontext")
local Geom = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local Mupdf = require("ffi/mupdf")
local logger = require("logger")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local Screen = require("device").screen

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

--- Wrap a MuPDF page so that closing it also drops the backing MuPDF document.
local function wrapMupdfPage(mupdf_doc, mupdf_page)
    -- Proxy: delegate everything to the real MuPDF page, but override close.
    local wrapper = {}
    setmetatable(wrapper, {
        __index = function(_, k)
            if k == "close" then
                return function(self)
                    mupdf_page:close()
                    mupdf_doc:close()
                end
            end
            return mupdf_page[k]
        end,
    })
    return wrapper
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
    self.render_mode = 0

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
    self._page_fail_ts = {}  -- pageno -> os.time() of last failure, prevents rapid retry

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

    -- Try cached page 1 data first (no network).
    local cached = self.page_data_cache[1]
    if cached then
        self.cover_image_data = cached
        return RenderImage:renderImageData(cached, #cached, false)
    end

    -- Schedule a background download so the cover will be ready next time.
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        if self.is_open and not self.cover_image_data then
            local data = self:getOrDownloadPageData(1)
            if data then
                self.cover_image_data = data
            end
        end
    end)
    return nil
end

function OPDSPSEDocument:openPage(pageno)
    local image_data = self:getOrDownloadPageData(pageno)

    -- Opportunistically remember page 1 as cover (no extra download).
    if pageno == 1 and image_data then
        self.cover_image_data = image_data
    end

    if image_data then
        -- Use MuPDF to open the image data as a single-page document.
        -- This gives us native C implementations of draw, getPagePix, getSize,
        -- identical to what CBZ uses, for better cropping and rendering quality.
        local ok, mupdf_doc = pcall(Mupdf.openDocumentFromText, image_data, "image/jpeg")
        if ok and mupdf_doc then
            mupdf_doc.color = self.render_color
            local ok2, mupdf_page = pcall(mupdf_doc.openPage, mupdf_doc, 1)
            if ok2 and mupdf_page then
                return wrapMupdfPage(mupdf_doc, mupdf_page)
            end
            mupdf_doc:close()
        end
        -- Fallback: if MuPDF can't handle this image format, use RenderImage.
        logger.warn("OPDSPSEDocument: MuPDF failed for page", pageno, "- falling back to RenderImage")
    end

    -- Download failed or MuPDF fallback failed — show placeholder.
    logger.err("OPDSPSEDocument: Failed to get page image for page", pageno)
    local placeholder_bb = RenderImage:renderImageFile("resources/koreader.png", false)
    -- Wrap placeholder as a minimal MuPDF-compatible page via pic module.
    local pic_page = {
        image_bb = placeholder_bb,
    }
    -- Provide the methods koptinterface expects.
    function pic_page:getSize(dc)
        local zoom = dc:getZoom()
        return self.image_bb:getWidth() * zoom, self.image_bb:getHeight() * zoom
    end
    function pic_page:draw(dc, bb)
        local scaled_bb = self.image_bb:scale(bb:getWidth(), bb:getHeight())
        bb:blitFullFrom(scaled_bb, 0, 0)
        scaled_bb:free()
    end
    function pic_page:getUsedBBox()
        return 0.01, 0.01, -0.01, -0.01
    end
    function pic_page:getPagePix()
        -- No-op for placeholder pages.
    end
    function pic_page:close()
        if self.image_bb then
            self.image_bb:free()
            self.image_bb = nil
        end
    end

    -- Show retry button only for the currently visible page.
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        if not self.is_open then return end
        local ReaderUI = require("apps/reader/readerui")
        local paging = ReaderUI.instance and ReaderUI.instance.paging
        if not paging or paging.current_page ~= pageno then return end
        if self._retry_dialog and self._retry_dialog_page == pageno then return end
        self:showRetryDialog(pageno)
    end)

    return pic_page
end

function OPDSPSEDocument:showRetryDialog(pageno)
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")

    -- Dismiss any previous retry dialog.
    if self._retry_dialog then
        UIManager:close(self._retry_dialog)
        self._retry_dialog = nil
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self._retry_dialog_page = pageno
    self._retry_dialog = ButtonDialog:new{
        title = _("Page load failed"),
        title_align = "center",
        dismissable = true,
        buttons = {
            {
                {
                    text = _("Retry"),
                    callback = function()
                        UIManager:close(self._retry_dialog)
                        self._retry_dialog = nil
                        self._retry_dialog_page = nil
                        self:retryPage(pageno)
                    end,
                },
            },
        },
        close_callback = function()
            self._retry_dialog = nil
            self._retry_dialog_page = nil
        end,
    }
    UIManager:show(self._retry_dialog)
end

function OPDSPSEDocument:retryPage(pageno)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local Event = require("ui/event")

    -- Clear cooldown so the download is actually attempted.
    self._page_fail_ts[pageno] = nil
    -- Invalidate tile cache so the render pipeline won't serve the stale placeholder.
    self:resetTileCacheValidity()
    -- Purge stale dimension caches.
    self.size_cache[pageno] = nil
    local pgdim_hash = "pgdim|"..self.file.."|"..self.mod_time.."|"..pageno
    DocCache.cache:delete(pgdim_hash)

    -- Show a brief loading message while downloading.
    local loading = InfoMessage:new{
        text = _("Loading…"),
        timeout = 30,
    }
    UIManager:show(loading)
    UIManager:forceRePaint()

    -- Download the page (synchronous HTTP).
    local data = self:getOrDownloadPageData(pageno)

    UIManager:close(loading)

    if data then
        -- Trigger a full page redraw.
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then
            ReaderUI.instance:handleEvent(Event:new("RedrawCurrentPage"))
        end
    else
        -- Still failed — show retry dialog again, but only once.
        -- The dialog is dismissable so the user can give up.
        self:showRetryDialog(pageno)
    end
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

    -- Cooldown: skip pages that failed recently (within 30s) to avoid
    -- hammering the server and blocking the UI on repeated timeouts.
    local fail_ts = self._page_fail_ts[pageno]
    if fail_ts and (os.time() - fail_ts) < 30 then
        logger.dbg("OPDSPSEDocument: Skipping page", pageno, "- failed recently, cooldown active")
        return nil
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
        -- Run asynchronously to avoid blocking the current page render.
        if self._next_chapter_count == nil
                and self._next_chapter_probed ~= true
                and pageno >= self.count - 2 then
            self._next_chapter_probed = true
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0.1, function()
                if self.is_open then
                    self:probeNextChapter()
                end
            end)
        end

        return data
    else
        logger.dbg("OPDSPSEDocument: Request failed:", status or code)
        -- Record failure time so we don't retry this page immediately.
        self._page_fail_ts[pageno] = os.time()
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
            -- (The _page_fail_ts cooldown above prevents this from becoming
            -- an infinite retry loop — the page will be skipped for 30s.)
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
    -- Opportunistically remember page 1 as cover (no extra download).
    if pageno == 1 and data then
        self.cover_image_data = data
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
        if self._retry_dialog then
            local UIManager = require("ui/uimanager")
            UIManager:close(self._retry_dialog)
            self._retry_dialog = nil
        end
        self.page_data_cache = {}
        self.page_data_cache_count = 0
        self.size_cache = {}
        self.size_cache_count = 0
        self.cover_image_data = nil
        self._page_fail_ts = {}
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

function OPDSPSEDocument:hintPage(pageno, zoom, rotation, gamma)
    -- Override: pre-download the page data asynchronously so the built-in
    -- hinting (next-page prefetch) doesn't block the UI with a synchronous
    -- HTTP request.  The actual render into tile cache will happen when the
    -- user navigates to the page.
    if pageno <= 0 or pageno > self.count then return end
    if self.page_data_cache[pageno] then
        -- Data already cached — let the normal hintPage render the tile.
        return self.koptinterface:hintPage(self, pageno, zoom, rotation, gamma)
    end
    -- Schedule async download; the tile will be rendered on next drawPage.
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.1, function()
        if self.is_open and not self.page_data_cache[pageno] then
            self:getOrDownloadPageData(pageno)
        end
    end)
end

function OPDSPSEDocument:renderPage(pageno, rect, zoom, rotation, gamma, hinting)
    return self.koptinterface:renderPage(self, pageno, rect, zoom, rotation, gamma, hinting)
end

function OPDSPSEDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma)
    return self.koptinterface:drawPage(self, target, x, y, rect, pageno, zoom, rotation, gamma)
end

function OPDSPSEDocument:register(registry)
    registry:addProvider("opdspse", "application/opdspse", self, 100)
end

return OPDSPSEDocument
