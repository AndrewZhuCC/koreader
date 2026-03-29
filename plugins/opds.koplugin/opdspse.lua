local http = require("socket.http")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local ltn12 = require("ltn12")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local url = require("socket.url")
local Event = require("ui/event")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSPSE = {}

function OPDSPSE:getLastPage(remote_url, username, password)
    local last_page = 0

    local chapter = string.match(remote_url, "chapterId=(%w+)")
    local api_key = string.match(remote_url, "opds/(.+)/image")
    local progress_url = string.match(remote_url, "(.+)/api").."/api/Reader/get-progress?chapterId="..chapter
    local auth_url = string.match(remote_url, "(.+)/api").."/api/Plugin/authenticate?apiKey="..api_key.."&pluginName=KOReader-OPDS"

    local auth_parsed = url.parse(auth_url)
    local auth_data = {}
    local auth_code, auth_headers, auth_status
    if auth_parsed.scheme == "http" or auth_parsed.scheme == "https" then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        auth_code, auth_headers, auth_status = socket.skip(1, http.request {
            method = "POST",
            url         = auth_url,
            headers     = {
                ["Accept-Encoding"] = "identity",
                ["Authentication"] = api_key,
            },
            sink        = ltn12.sink.table(auth_data),
            user        = username,
            password    = password,
        })
        socketutil:reset_timeout()
    else
        UIManager:show(InfoMessage:new {
            text = T(_("Invalid protocol:\n%1"), auth_parsed.scheme),
        })
    end

    if auth_code == 200 then
        local ok, json = pcall(require, "dkjson")
        local bearer_token
        if ok then
            local parsed = json.decode(table.concat(auth_data))
            if parsed then bearer_token = parsed.token end
        end
        if not bearer_token then
            bearer_token = auth_data[1] and auth_data[1]:match('"token"%s*:%s*"([^"]+)"')
        end

        if not bearer_token then
            logger.dbg("OPDSPSE:getLastPage: Failed to extract bearer token")
            return last_page
        end

        local progress_parsed = url.parse(progress_url)
        local progress_data = {}
        local progress_code, progress_headers, progress_status
        if progress_parsed.scheme == "http" or progress_parsed.scheme == "https" then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            progress_code, progress_headers, progress_status = socket.skip(1, http.request {
                url         = progress_url,
                headers     = {
                    ["Accept-Encoding"] = "identity",
                    ["Authorization"] = "Bearer "..bearer_token,
                },
                sink        = ltn12.sink.table(progress_data),
                user        = username,
                password    = password,
            })
            socketutil:reset_timeout()
        else
            UIManager:show(InfoMessage:new {
                text = T(_("Invalid protocol:\n%1"), progress_parsed.scheme),
            })
        end

        if progress_code == 200 then
            if ok then
                local parsed = json.decode(table.concat(progress_data))
                if parsed then last_page = parsed.pageNum or 0 end
            else
                local num = progress_data[1] and progress_data[1]:match('"pageNum"%s*:%s*(%d+)')
                if num then last_page = tonumber(num) or 0 end
            end
        else
            logger.dbg("OPDSPSE:getLastPage: Progress Request failed:", progress_status or progress_code)
            logger.dbg("OPDSPSE:getLastPage: Progress Response headers:", progress_headers)
        end
    else
        logger.dbg("OPDSPSE:getLastPage: Authentication Request failed:", auth_status or auth_code)
        logger.dbg("OPDSPSE:getLastPage: Authentication Response headers:", auth_headers)
    end

    return last_page
end

function OPDSPSE:streamPages(remote_url, count, continue, username, password, last_page_read)
    local suc = self:createStreamingDocument(remote_url, count, username, password, "Streaming Comic")
    if not suc then
        return false
    end

    UIManager:nextTick(function()
        local reader = UIManager:getTopmostVisibleWidget()
        if continue then
            logger.dbg("OPDSPSE: gotoPage")
            self:jumpToPageReader(reader, count)
        elseif last_page_read then
            logger.dbg("OPDSPSE: handleEvent GotoPage", last_page_read)
            reader:handleEvent(Event:new("GotoPage", last_page_read))
        end
    end)

    return true
end

function OPDSPSE:jumpToPageReader(reader, count)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter page number"),
        input_type = "number",
        input_hint = "(" .. "1 - " .. count .. ")",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Stream"),
                    is_enter_default = true,
                    callback = function()
                        local page_num = input_dialog:getInputValue()
                        if page_num then
                            UIManager:close(input_dialog)
                            reader:handleEvent(Event:new("GotoPage", math.min(math.max(1, page_num), count)))
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function OPDSPSE:createStreamingDocument(remote_url, count, username, password, title)
    local temp_dir = "/tmp/koreader_streaming"
    local lfs = require("libs/libkoreader-lfs")

    if not lfs.attributes(temp_dir) then
        lfs.mkdir(temp_dir)
    end

    local filename = (title or "streaming"):gsub("[^%w%-_.]", "_")
    local opdspse_path = temp_dir .. "/" .. filename .. "_" .. os.time() .. ".opdspse"

    local file = io.open(opdspse_path, "w")
    if not file then
        UIManager:show(InfoMessage:new{
            text = _("Failed to create streaming document file"),
        })
        return false
    end

    file:write("remote_url=" .. remote_url .. "\n")
    file:write("count=" .. tostring(count) .. "\n")
    if username then
        file:write("username=" .. username .. "\n")
    end
    if password then
        file:write("password=" .. password .. "\n")
    end
    if title then
        file:write("title=" .. title .. "\n")
    end
    file:close()

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(opdspse_path)

    return true
end

return OPDSPSE
