--[[
synbangumi.lua
================================================================================
一个用于 mpv 播放器的脚本，旨在将本地视频播放进度与 Bangumi (bgm.tv) 网站同步。
主要功能包括：
1. 自动或手动将正在播放的视频匹配到 Bangumi 上的番剧条目和章节。
2. 当播放进度超过阈值（如80%）时，自动将对应章节标记为“看过”。
3. 当一部番剧的所有正片章节都被标记为“看过”后，自动将整个番剧条目更新为“看过”。
4. 支持通过快捷键开启/关闭同步功能，以及手动搜索和关联番剧。
================================================================================
--]]

-- 模块导入区
local mp = require 'mp'
local msg = require "mp.msg"
local utils = require 'mp.utils'
local options = require "mp.options"
-- 使用 pcall 安全地引入 mp.input, 兼容不支持该模块的旧版 mpv
local input_available, input = pcall(require, "mp.input")
-- 引入内置的 JSON 处理库
local json = require 'bin/json'

-- 用户配置项
-- 这些配置将从 script-opts/synbangumi.conf 文件中读取
local opts = {
    access_token = "", -- Bangumi Access Token, 用于 API 认证，必须填写
    debug_mode = false, -- 是否开启调试模式，开启后会在控制台输出详细的 API 请求和响应信息
    username = "" -- Bangumi 用户名，用于查询用户收藏状态
}
options.read_options(opts, _, function() end)

-- 全局状态变量
-- 用于在脚本的整个生命周期内跟踪当前同步状态
local current_subject_name = nil -- 当前匹配到的番剧中文或日文名
local current_ep_name = nil -- 当前匹配到的章节名
local current_ep_number = nil -- 当前匹配到的集数 (e.g., 1, 2, 3)
local current_subject_id = nil -- 当前番剧在 Bangumi 上的唯一 ID
local current_ep_id = nil -- 当前章节在 Bangumi 上的唯一 ID

local is_sync_enabled = false -- 同步功能的总开关，由用户通过快捷键控制
local is_current_ep_marked = false -- 标记当前播放的章节是否已经被提交过“看过”状态，防止重复提交


-- 状态码映射表
-- 将从 Bangumi API 获取的数字状态码转换为人类可读的文本
local subject_status_map = {
    [1] = "想看",
    [2] = "看过",
    [3] = "在看",
    [4] = "搁置",
    [5] = "抛弃",
    ["uncollected"] = "未收藏" -- 自定义状态，用于表示 API 返回 404 (未收藏) 的情况
}
local ep_status_map = {
    [0] = "未看",
    [1] = "想看",
    [2] = "看过",
    [3] = "抛弃",
    ["uncollected"] = "未看" -- 自定义状态，用于表示 API 返回 404 (未观看) 的情况
}

-- 初始化检查
-- 检查核心配置 access_token 是否已设置
if opts.access_token == "" or opts.access_token == "YOUR_ACCESS_TOKEN_HERE" then
    msg.error("Bangumi Access Token 未配置! 请在 script-opts/synbangumi.conf 中设置。")
    -- 如果未配置，则脚本无法工作，直接退出
    return
end

msg.info("synbangumi.lua 脚本已加载，配置读取成功。")

--- 调试日志函数
-- @param message (string) 需要打印的调试信息
function debug_log(message)
    if opts.debug_mode then
        -- 使用 [DEBUG] 前缀，方便在日志中筛选
        msg.info("[DEBUG] " .. message)
    end
end

--- 封装的 API 请求函数
-- 使用 curl 子进程发起 HTTP 请求，并处理响应
-- @param method (string) HTTP 方法 (e.g., "GET", "POST", "PUT")
-- @param url (string) 请求的 URL
-- @param data (table or string) 对于 POST/PUT 请求，这是要发送的请求体 (Lua table 会被自动编码为 JSON)
-- @return (table, number) 返回解码后的 JSON 数据 (如果成功) 和 HTTP 状态码
function api_request(method, url, data)
    debug_log("发送 API 请求: " .. method .. " " .. url)

    local headers = {
        'Authorization: Bearer ' .. opts.access_token,
        'User-Agent: witcheng/mpv-sync-script', -- 设置 User-Agent 是一个好习惯
        'Content-Type: application/json',
    }

    -- 使用一个复杂的分隔符，以在 curl 的输出中同时捕获响应体和 HTTP 状态码
    local separator = "\n--BGM_SYNC_SEPARATOR--\n"
    
    local args = { "curl", "-s", "-X", method }

    for _, h in ipairs(headers) do
        table.insert(args, "-H")
        table.insert(args, h)
    end

    -- curl 的 -w/--write-out 选项可以在请求结束后输出额外信息
    -- 这里我们用它来输出分隔符和 http_code
    table.insert(args, "-w")
    table.insert(args, separator .. "%{http_code}")

    table.insert(args, url)

    if data then
        table.insert(args, "-d")
        -- 如果传入的是 table，则编码为 JSON 字符串
        if type(data) == "table" then
            table.insert(args, json.encode(data))
        else
            table.insert(args, data)
        end
    end

    local res = mp.command_native({ name = "subprocess", args = args, capture_stdout = true })
    if res.status ~= 0 then
        msg.error("API 请求失败 (curl 命令退出码非0): " .. (res.stderr or "未知错误"))
        return nil, nil
    end

    local output = res.stdout
    -- 使用普通字符串查找来分割响应体和状态码，比正则表达式更高效、更稳定
    local split_pos = output:find(separator, 1, true)

    if not split_pos then
        msg.error("API 响应未能解析出有效的HTTP状态码或响应格式异常。原始输出: " .. output)
        return nil, nil
    end

    local json_body_str = output:sub(1, split_pos - 1)
    local http_code_str = output:sub(split_pos + #separator)
    
    local http_status_code = tonumber(http_code_str)

    debug_log("API 请求成功. HTTP状态码: " .. http_status_code)
    debug_log("API 响应体: " .. json_body_str)
    
    if not http_status_code or http_status_code < 200 or http_status_code >= 300 then
        msg.warn("API 请求返回非成功状态码: " .. tostring(http_status_code) .. ". 响应体可能不是有效的 JSON。")
        return nil, http_status_code
    end

    if json_body_str == "" then
        return {}, http_status_code -- 对空响应体返回空表，避免后续处理出错
    end

    local ok, json_data = pcall(json.decode, json_body_str)

    -- 如果 pcall 返回 false，说明解码失败
    if not ok then
        -- 此时 json_data 变量里存放的是错误信息
        msg.warn("API 响应体解析失败，它可能不是有效的JSON格式。错误: " .. tostring(json_data))
        return nil, http_status_code
    end

    local json_data, err = json.decode(json_body_str)
    if not json_data then
        msg.warn("API 响应体解析失败: " .. (err or "未知错误") .. ". 原始响应体: " .. json_body_str)
        return nil, http_status_code
    end

    return json_data, http_status_code
end

-- ============================================================================
-- 手动同步流程 (通过 script-message 驱动的事件模型)
-- 这个流程允许用户通过菜单手动选择番剧和章节。
-- 步骤 4: 最终选择处理函数
-- 当用户在章节选择菜单中做出选择后，此函数被触发。
-- @param ep_info (table) 包含所选章节完整信息的包
-- ============================================================================
function on_episode_selected(ep_info)
    msg.info("4. [on_episode_selected] 用户已手动选定章节。")

    -- 1. 将选择的结果赋值给全局状态变量
    current_subject_id = ep_info.subject_id
    current_ep_id = ep_info.id
    current_ep_name = ep_info.name_cn or ep_info.name or ""
    current_ep_number = ep_info.sort
    current_subject_name = ep_info.subject_name

    -- 2. 调用核心同步逻辑，开始同步
    execute_core_sync()
end


--- 步骤 3: 获取并显示章节列表
-- @param subject_id (number) 番剧的 ID
-- @param subject_name (string) 番剧的名称 (用于显示)
function get_and_show_episodes(subject_id, subject_name)
    msg.info("3. [get_and_show_episodes] 正在获取 '" .. subject_name .. "' (ID: " .. subject_id .. ") 的章节。")
    send_message("正在获取章节列表...")
    
    local ep_list_url = "https://api.bgm.tv/v0/episodes?subject_id=" .. subject_id
    local ep_list_result, http_code = api_request("GET", ep_list_url)
    
    if not ep_list_result or not ep_list_result.data or #ep_list_result.data == 0 then
        send_message("未找到任何章节。")
        return
    end

    local items = {}
    for _, ep in ipairs(ep_list_result.data) do
        -- 只处理正片 (type == 0)
        if ep.type == 0 then
            -- 优先使用非空的中文名，否则使用原名
            local ep_name = ep.name_cn and ep.name_cn:match("%S") and ep.name_cn or ep.name or ""

            -- 创建一个包含所有必要信息的信息包
            local full_ep_info = {
                id = ep.id,
                sort = ep.sort,
                name = ep_name,
                subject_id = subject_id,
                subject_name = subject_name
            }
            debug_log("章节信息：" .. utils.to_string(full_ep_info))

            table.insert(items, {
                title = string.format("EP.%d %s", ep.sort, ep_name),
                -- value 是一个 mpv 命令数组，当用户选择此项时将被执行
                -- 这里我们发送一个 script-message，将完整信息包传递给 on_episode_selected
                value = {
                    "script-message-to",
                    mp.get_script_name(),
                    "bangumi-episode-selected",
                    utils.to_string(full_ep_info) -- 将 table 序列化为字符串进行传递
                }
            })
        end
    end
    
    -- 使用微小延迟确保UI响应流畅
    mp.add_timeout(0.1, function()
        open_menu_select("选择一个章节:", items)
    end)
end

--- 步骤 2: 搜索番剧并显示结果
-- @param query (string) 用户输入的搜索关键词
function search_bangumi_and_show(query)
    msg.info("2. [search_bangumi_and_show] 正在搜索: " .. query)
    send_message("正在搜索: " .. query)

    -- type=2 表示只搜索“动画”类型
    local search_url = "https://api.bgm.tv/search/subject/" .. url_encode(query) .. "?type=2"
    local search_result, http_code = api_request("GET", search_url)

    if not search_result or not search_result.list or #search_result.list == 0 then
        send_message("搜索失败，未找到番剧: " .. query)
        return
    end

    local items = {}
    -- 最多显示前 8 个结果
    for i = 1, math.min(8, #search_result.list) do
        local subject = search_result.list[i]
        -- 将番剧 ID 和名称打包
        local subject_info = {
            id = subject.id,
            name = subject.name_cn or subject.name
        }
        table.insert(items, {
            title = subject_info.name,
            -- 当用户选择此项时，发送消息触发 get_and_show_episodes
            value = {
                "script-message-to",
                mp.get_script_name(),
                "bangumi-show-selected",
                utils.to_string(subject_info)
            }
        })
    end
    
    mp.add_timeout(0.1, function()
        open_menu_select("选择一个番剧:", items)
    end)
end

--- 步骤 1 (入口): 启动手动同步流程
-- 由 alt+g 快捷键触发
function start_manual_sync()
     -- 检查总开关，如果同步功能未开启，则不允许手动同步
    if not is_sync_enabled then
        send_message("同步功能未开启，请先按 Ctrl+G 开启")
        msg.warn("用户尝试手动同步，但总开关未开启。")
        return
    end

    msg.info("手动同步流程启动 (总开关已开启)...")
    -- 尝试从当前视频标题中解析出番剧名作为默认搜索词
    local default_search = mp.get_property("media-title", "")
    local anime_name, _ = parse_title(default_search)
    
    input.get({
        prompt = "搜索番剧:",
        text = anime_name, -- 将解析出的番剧名作为默认文本
        submit = function(query)
            if query and query ~= "" then
                input.terminate()
                -- 发送消息请求，而不是直接调用函数，实现解耦
                mp.commandv("script-message-to", mp.get_script_name(), "bangumi-search-requested", query)
            end
        end
    })
end

--- 通用菜单选择器
-- @param prompt (string) 菜单的提示语
-- @param items (table) 菜单项的数组，每个项包含 title 和 value
function open_menu_select(prompt, items)
    local item_titles, item_values = {}, {}
    for i, v in ipairs(items) do
        item_titles[i] = v.title
        item_values[i] = v.value
    end
    input.select({
        prompt = prompt,
        items = item_titles,
        submit = function(id)
            if id then
                -- 当用户做出选择后，执行预设的 mpv 命令
                mp.commandv(unpack(item_values[id]))
            end
        end,
    })
end

-- 注册 script-message 监听器，响应手动同步流程中的各个事件
mp.register_script_message("bangumi-search-requested", function(query)
    mp.add_timeout(0.1, function()
        search_bangumi_and_show(query)
    end)
end)

mp.register_script_message("bangumi-show-selected", function(subject_info_str)
    local subject_info = utils.parse_json(subject_info_str) -- 反序列化
    get_and_show_episodes(subject_info.id, subject_info.name)
end)

mp.register_script_message("bangumi-episode-selected", function(ep_info_str)
    local ep_info = utils.parse_json(ep_info_str)
    on_episode_selected(ep_info)
end)


--- URL 编码/解码工具函数
local function is_protocol(path)
    return type(path) == "string" and (path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil)
end

local function hex_to_char(x)
    return string.char(tonumber(x, 16))
end

function url_encode(str)
    if str then
        str = str:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    end
    return str
end

function url_decode(str)
    if str ~= nil then
        str = str:gsub("^%a[%a%d-_]+://", "")
              :gsub("^%a[%a%d-_]+:\\?", "")
              :gsub("%%(%x%x)", hex_to_char)
        if str:find("://localhost:?") then
            str = str:gsub("^.*/", "")
        end
        str = str:gsub("%?.+", "")
              :gsub("%+", " ")
        return str
    else
        return
    end
end


-- ============================================================================
-- OSD 屏幕消息显示系统
-- ============================================================================
message_overlay = mp.create_osd_overlay('ass-events')
message_timer = mp.add_timeout(3, function ()
    message_overlay:remove()
end, true)

mp.observe_property('osd-width', 'number', function(_, value) osd_width = value or osd_width end)
mp.observe_property('osd-height', 'number', function(_, value) osd_height = value or osd_height end)

--- 在屏幕左上角显示一条消息
-- @param text (string) 要显示的文本内容
-- @param time (number, optional) 消息显示的持续时间（秒），默认为 3 秒
function send_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    -- 使用 ASS 格式化标签来定位和样式化文本
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", 7, 30, 30, text)
    local width, height = 1920, 1080
    local ratio = osd_width / osd_height
    if width / height < ratio then
        height = width / ratio
    end
    message_overlay.res_x = width
    message_overlay.res_y = height
    message_overlay.data = message
    message_overlay:update()
    message_timer:resume()
end


-- ============================================================================
-- 标题解析模块
-- ============================================================================
--- 从媒体标题（通常是文件名）中解析出番剧名和集数
-- @param title (string) 媒体标题
-- @return (string, string) 解析出的番剧名和集数。如果失败则返回 (nil, nil)
function parse_title(title)
    if not title then
        msg.warn("parse_title 被调用，但标题为 nil。")
        return nil, nil
    end

    local original_title = title

    -- 解析器列表，每个解析器包含一个正则表达式和一个处理函数
    local parsers = {
        { regex = "^(.-)%s*[sS](%d+):[eE](%d+)%-?.*", handler = function(name, season, episode) return name, episode, season end },
        { regex = "^(.-)%s*[sS](%d+)[%s_.-]*[eE](%d+)", handler = function(name, season, episode) return name, episode, season end },
        { regex = "^(.-)[%s_.]*第%s*(%d+)[%s_.]*[话話集]", handler = function(name, episode) return name, episode, "1" end },
        { regex = "^(.-)%s*%[(%d+)[vV]?%d*%]", handler = function(name, episode) return name, episode, "1" end },
        { regex = "^(.-)%s*[-_]%s*(%d+)%s*[^%d%.]", handler = function(name, episode) return name, episode, "1" end },
        { regex = "^(.-)%.(%d%d%d%d)%.(%d+)$", handler = function(name, year, episode) return name .. " " .. year, episode, "1" end }
    }

    -- 独立的清理函数，用于移除番剧名中的常见干扰项
    local function clean_anime_name(name)
        if not name then return "" end
        name = name:gsub('%b[]', ''):gsub('%b()', '') -- 移除方括号和圆括号及其内容
        name = name:gsub('[._-]', ' ') -- 将点、下划线、破折号替换为空格
        name = name:gsub('%s*[sS]%d+$', '') -- 移除末尾的 S1, S2 等
        name = name:gsub('^%s*(.-)%s*$', '%1') -- 去除首尾空格
        return name
    end

    -- 按顺序尝试所有解析器
    for _, parser in ipairs(parsers) do
        local matches = { original_title:match(parser.regex) }
        
        if #matches > 0 then
            local raw_name, episode, season = parser.handler(unpack(matches))
            local final_name = clean_anime_name(raw_name)

            if final_name and final_name ~= "" then
                msg.info("标题解析成功 -> 模式: '" .. parser.regex .. "', 番名: '" .. final_name .. "', 集数: '" .. episode .. "'")
                return final_name, tostring(episode)
            end
        end
    end

    msg.warn("所有模式均无法从标题解析番名和集数: " .. original_title)
    return nil, nil
end


-- ============================================================================
-- Bangumi API 交互核心功能
-- ============================================================================

--- 通用函数：获取作品(subject)或章节(episode)的收藏状态
-- @param item_type (string) 查询类型，必须是 "subject" 或 "episode"
-- @param item_id (number) 对应类型的 ID (subject_id 或 ep_id)
-- @return (string) 返回状态码(如"2")或自定义状态(如"uncollected", "error")
function get_status(item_type, item_id)
    if not item_id or not (item_type == "subject" or item_type == "episode") then
        msg.warn("get_status: 参数错误。")
        return "error"
    end

    debug_log(string.format("get_status: 开始查询 %s (ID: %s) 的状态...", item_type, item_id))

    local url
    local status_map
  
    if item_type == "subject" then
        url = "https://api.bgm.tv/v0/users/" .. opts.username .. "/collections/" .. item_id
        status_map = subject_status_map
    else -- item_type == "episode"
        url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. item_id
        status_map = ep_status_map
    end

    local result, http_code = api_request("GET", url)

    if http_code == 404 then
        debug_log(string.format("查询到 %s (ID: %s) 的状态: %s (HTTP 404)", item_type, item_id, status_map["uncollected"]))
        return "uncollected"
    end

    if not result then
        msg.warn(string.format("get_status: %s (ID: %s) API 请求失败 (HTTP Code: %s)", item_type, item_id, tostring(http_code)))
        return "error"
    end

    if http_code == 200 and result.type then
        local current_status = result.type
        debug_log(string.format("查询到 %s (ID: %s) 的状态: %s", item_type, item_id, status_map[current_status]))
        return current_status
    else
        msg.warn(string.format("get_status: %s (ID: %s) 收到未知的状态 type: %s", item_type, item_id, tostring(result.type)))
        return "未知状态"
    end
    
    msg.warn(string.format("get_status: 未能从 %s (ID: %s) 的响应中解析状态。收到的数据: %s", item_type, item_id, utils.to_string(result)))
    return "error"
end

--- 检查指定条目的所有正片是否已看完，如果是，则自动将该条目状态更新为"看过"
-- @param subject_id (number) 要检查的条目ID
function check_subject_all_watched(subject_id)
    if not subject_id then return end

    debug_log("check_subject_all_watched: 开始检查条目 " .. subject_id .. " 是否已全部看完")

    local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id .. "/episodes"
    local ep_list_result, http_code = api_request("GET", url)

    if not ep_list_result or not ep_list_result.data or http_code ~= 200 then
        msg.warn("无法获取章节列表来检查完成状态，操作中止。")
        return
    end

    local all_main_eps_watched = true -- 乐观假设：所有正片都看完了
    for _, ep_info in ipairs(ep_list_result.data) do
        -- 检查条件: 1. 是正片 (ep_info.episode.type == 0) 2. 观看状态不是“看过”(ep_info.type ~= 2)
        if ep_info.episode and ep_info.episode.type == 0 then
            if ep_info.type ~= 2 then
                all_main_eps_watched = false -- 发现一个没看完的，假设不成立
                msg.info("发现未看完的正片: " .. (ep_info.episode.name_cn or ep_info.episode.name or ep_info.episode.id) .. " ，无需更新条目状态。")
                break -- 无需继续检查
            end
        end
    end

    if all_main_eps_watched then
        send_message("所有正片已看完，正在更新 " .. current_subject_name .. " 状态为 [看过]...")
        msg.info("所有正片已看完，准备将条目 " .. subject_id .. " 更新为'看过'")
        
        -- 调用 API 将整个条目状态更新为 2 (看过)
        local update_url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
        local payload = { type = 2 }
        local result, update_code = api_request("POST", update_url, payload)

        if update_code and update_code >= 200 and update_code < 300 then
            send_message(current_subject_name .. "条目成功标记为 [看过]")
            debug_log("成功将条目 " .. subject_id .. " 标记为 [看过]")
        else
            send_message(current_subject_name .. "更新条目为 [看过] 失败")
            msg.warn("更新条目为 [看过] 失败，HTTP Code: " .. tostring(update_code))
        end
    end
end

--- 更新番剧条目的收藏状态
-- @param subject_id (number) 要更新的条目ID
-- @param status_type (number) 目标状态码 (e.g., 3 for "在看")
function update_subject_status(subject_id, status_type)
    if not subject_id then return end

    debug_log("update_subject_status: 开始更新条目 " .. subject_id .. " 的状态为 " .. status_type)

    local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
    local payload = { type = status_type }
    local result, http_code = api_request("POST", url, payload)

    if http_code and http_code >= 200 and http_code < 300 then
        debug_log("成功将条目 " .. subject_id .. " 更新为 ".. subject_status_map[status_type] .."["  .. status_type .. "]")
    else
        send_message("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败")
        msg.warn("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败，HTTP Code: " .. tostring(http_code))
    end
end

--- 更新单个章节的观看状态
-- @param ep_id (number) 要更新的章节ID
-- @param status_type (number) 目标状态码 (e.g., 2 for "看过")
-- @return (boolean) 返回是否更新成功
function update_episode_status(ep_id, status_type)
    if not ep_id then return false end

    local url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. ep_id
    local payload = { type = status_type }
    local result, http_code = api_request("PUT", url, payload)

    if http_code and http_code >= 200 and http_code < 300 then
        send_message(current_subject_name .. "第 " .. current_ep_number .. " 集\\N Bangumi已 [" .. ep_status_map[status_type] .. "]")
        debug_log("成功将章节 " .. ep_id .. " 更新为 " .. ep_status_map[status_type] .."["  .. status_type .. "]")
        return true
    else
        send_message("更新章节状态为 [" .. ep_status_map[status_type] .. "] 失败")
        msg.warn("更新章节状态为 [" .. ep_status_map[status_type] .. "] 失败，HTTP Code: " .. tostring(http_code))
        return false
    end
end


--- 异步查找剧集和章节 (自动同步的核心)
-- 此函数在后台执行，不会阻塞播放器
-- @param media_title (string) 当前播放文件的标题
-- @param on_success (function) 查找成功后的回调函数，接收一个包含完整信息的 ep_info_package 参数
function find_episode_async(media_title, on_success)
    -- 使用 mp.add_timeout(0, ...) 将任务放入事件循环，实现异步执行
    mp.add_timeout(0, function()
        local anime_name, ep_number_str = parse_title(media_title)
        if not anime_name or not ep_number_str then
            send_message("无法从标题解析番名和集数")
            return
        end
        
        send_message("正在搜索: " .. anime_name)
        local search_url = "https://api.bgm.tv/search/subject/" .. url_encode(anime_name) .. "?type=2"
        local search_result, http_code = api_request("GET", search_url)

        if not search_result or not search_result.list or #search_result.list == 0 then
            send_message("搜索失败，未找到番剧: " .. anime_name)
            return
        end

        -- 默认取第一个搜索结果
        local subject = search_result.list[1]
        local subject_id = subject.id
        local subject_name = subject.name_cn or subject.name or " "

        msg.info("找到条目: " .. subject_name .. " (ID: " .. subject_id .. ")")

        local ep_list_url = "https://api.bgm.tv/v0/episodes?subject_id=" .. subject_id
        local ep_list_result, http_code = api_request("GET", ep_list_url)

        local found_ep = nil
        if ep_list_result and ep_list_result.data then
            for _, ep in ipairs(ep_list_result.data) do
                -- 匹配条件：是正片 (type==0) 且集数 (sort) 与解析出的集数相同
                if ep.type == 0 and ep.sort == tonumber(ep_number_str) then
                    found_ep = ep
                    break
                end
            end
        end

        if found_ep then
            local ep_name = found_ep.name_cn or found_ep.name or " "
            local ep_id = found_ep.id
            msg.info("找到章节: 第 " .. ep_number_str .. " 集: " .. ep_name .. " (ID: " .. ep_id .. ")")

            if on_success and type(on_success) == "function" then
                -- 将所有找到的信息打包成一个 table
                local ep_info_package = {
                    subject_id = subject_id,
                    subject_name = subject_name,
                    id = ep_id,
                    name = ep_name,
                    sort = tonumber(ep_number_str)
                }
                -- 调用成功回调，并将信息包传递出去
                on_success(ep_info_package)
            end
        else
            send_message("找到番剧但未匹配到第 " .. ep_number_str .. " 集")
        end
    end)
end


-- ============================================================================
-- MPV 事件监听与处理
-- ============================================================================

--- 监听 'path' 属性变化，即文件切换事件
-- @param name (string) 属性名, "path"
-- @param new_path (string) 新的文件路径
function on_path_change(name, new_path)
    -- 当加载新文件时 (new_path 不为 nil)，重置所有状态变量
    if new_path then
        current_subject_name = nil
        current_ep_name = nil
        current_ep_number = nil
        current_subject_id = nil
        current_ep_id = nil
        
        is_sync_enabled = false -- 每个新文件都需要重新开启同步
        is_current_ep_marked = false
        
        debug_log("文件已切换，synbangumi 状态已重置。")
        debug_log("--------------------------------------------------")
    end
end

--- 同步核心逻辑引擎
-- 无论是自动还是手动匹配，最终都会调用此函数来启动同步
function execute_core_sync()
    local current_status = get_status("subject", current_subject_id)

    if current_status == "error" then
        send_message("查询状态失败，请检查日志")
        return
    end

    -- 成功获取信息后，才正式开启同步开关
    is_sync_enabled = true
    send_message(current_subject_name .. "第 " .. current_ep_number .. "集: " .. current_ep_name .. " \\N Bangumi同步中...")

    -- 如果条目状态已经是“看过”或“在看”，则无需操作
    if current_status == 2 or current_status == 3 then
        msg.info("同步已开启，当前条目状态为: " .. subject_status_map[current_status])
    else
        -- 否则，将条目状态更新为“在看” (type=3)
        msg.info("第 " .. current_ep_number .. "集: " .. current_ep_name .. " 状态为 " .. subject_status_map[current_status] .. "，正在标记为 [在看]...")
        update_subject_status(current_subject_id, 3)
    end
end

--- 同步功能的总开关函数
-- 绑定到 Ctrl+G
function master_toggle_sync()
    if is_sync_enabled then
        -- 如果当前是开启状态，则关闭
        is_sync_enabled = false
        send_message("同步已关闭")
        msg.info("同步功能已手动关闭")
        return
    end

    -- 如果当前是关闭状态，则开启并尝试自动匹配
    send_message("同步功能已开启，正在尝试自动匹配...")
    msg.info("同步功能已开启，正在尝试自动匹配...")
    local media_title = mp.get_property("media-title")

    -- 定义一个成功回调，当自动匹配成功后执行
    local function on_auto_sync_success(ep_info)
        -- 将匹配到的信息赋值给全局变量
        current_subject_id = ep_info.subject_id
        current_ep_id = ep_info.id
        current_ep_name = ep_info.name_cn or ep_info.name or ""
        current_ep_number = ep_info.sort
        current_subject_name = ep_info.subject_name
        
        -- 调用核心同步引擎
        execute_core_sync()
    end
    
    -- 启动异步查找，并传入我们的回调函数
    find_episode_async(media_title, on_auto_sync_success)
end


--- 监听播放进度变化 (Scrobbler)
-- 当进度超过 80% 时，自动标记为“看过”
-- @param name (string) 属性名, "percent-pos"
-- @param value (number) 播放进度的百分比 (0-100)
function on_progress_change(name, value)
    -- 检查所有条件：总开关已开？本集尚未标记？进度有效且大于80？
    if is_sync_enabled and not is_current_ep_marked and value and value > 80 then
        
        -- **重要**: 立即设置标志位，防止因进度条小范围波动导致重复触发
        is_current_ep_marked = true 
        
        if not current_subject_id or not current_ep_id then
            send_message("警告: 进度达标但未获取番剧信息，无法自动标记")
            msg.warn("进度达标但 current_subject_id 或 current_ep_id 为空")
            return
        end

        send_message("进度超过 80%，自动标记本集为 [看过]...")
        msg.info("进度达标,标记本集为 [看过]...")

        -- 调用 API 将本集状态更新为 2 (看过)
        local success = update_episode_status(current_ep_id, 2)

        -- **联动**: 如果本集成功标记为“看过”，则检查整部剧是否已经全部看完
        if success then
            mp.add_timeout(0.5, function()
                check_subject_all_watched(current_subject_id)
            end)
        end
    end
end

-- ============================================================================
-- 注册监听器和快捷键
-- ============================================================================

-- 监听文件变化
mp.observe_property("path", "string", on_path_change)
-- 监听播放进度百分比
mp.observe_property("percent-pos", "number", on_progress_change)

-- 绑定快捷键
-- Ctrl+G: 总开关，用于开启/关闭整个同步功能
mp.add_key_binding("ctrl+g", "master_toggle_sync", master_toggle_sync)
-- Alt+G: 手动同步，用于在自动匹配失败或不准确时手动指定番剧
mp.add_key_binding("alt+g", "start_manual_sync", start_manual_sync)