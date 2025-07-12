-- synbangumi.lua
-- 引入工具
local mp = require 'mp'
local msg = require "mp.msg"
local utils = require 'mp.utils'
local options = require "mp.options"
input_available, input = pcall(require, "mp.input")
local json = require 'bin/json'

-- 读取配置文件
local opts = {
    access_token = "", -- Bangumi Access Token
    debug_mode = false, -- 是否开启调试模式
    username = "witcheng" -- Bangumi用户名
}
options.read_options(opts, _, function() end)

local current_subject_id = nil
local current_ep_id = nil
local current_collection_status = nil -- 新增：用于缓存收藏状态

local is_sync_enabled = false
local is_marked_as_watched = false -- 可能删除
local is_current_ep_marked = false -- 新变量：用于标记当前集是否已被处理过


local subject_status_map = {
    [1] = "想看",
    [2] = "看过",
    [3] = "在看",
    [4] = "搁置",
    [5] = "抛弃"
}
local ep_status_map = {
    [0] = "未看",
    [1] = "想看",
    [2] = "看过",
    [3] = "抛弃"
}

-- 检查access_token是否配置
if opts.access_token == "" or opts.access_token == "YOUR_ACCESS_TOKEN_HERE" then
    msg.error("Bangumi Access Token 未配置! 请在 script-opts/synbangumi.conf 中设置。")
    -- 退出脚本
    return
end

msg.info("synbangumi.lua 脚本已加载，配置读取成功。")

-- 后面我们将在这里添加功能代码
-- API 请求函数
-- method: "GET", "POST", "PATCH" 等
-- url: 完整的 API URL
-- data: (可选) 对于 POST/PATCH 请求，需要发送的 Lua table 数据


-- function api_request(method, url, data)
--     debug_log("发送 API 请求: " .. method .. " " .. url)

--     local headers = {
--         'Authorization: Bearer ' .. opts.access_token,
--         'User-Agent: witcheng/mpv-sync-script',
--         'Content-Type: application/json'
--     }

--     local args = { "curl", "-s", "-X", method }

--     for _, h in ipairs(headers) do
--         table.insert(args, "-H")
--         table.insert(args, h)
--     end

--     -- 使用特殊分隔符来定位 HTTP 状态码
--     local status_marker = "__HTTP_STATUS__:"
--     table.insert(args, "-w")
--     table.insert(args, "\n" .. status_marker .. "%{http_code}")

--     table.insert(args, url)

--     if data then
--         table.insert(args, "-d")
--         table.insert(args, json.encode(data))
--     end

--     -- 执行 curl 命令
--     local res = mp.command_native({
--         name = "subprocess",
--         args = args,
--         capture_stdout = true
--     })

--     -- 检查命令是否执行成功
--     if res.status ~= 0 then
--         msg.error("API 请求失败 (curl 命令退出码非0): " .. (res.stderr or "未知错误"))
--         return nil, nil
--     end

--     local output = res.stdout
--     local http_status_code = nil
--     local json_body_str = ""

--     -- 使用分隔符匹配状态码与 JSON
--     json_body_str, status_code_str = output:match("^(.-)\n" .. status_marker .. "(%d%d%d)$")
--     if not json_body_str or not status_code_str then
--         msg.error("API 响应未能解析出有效的HTTP状态码或响应格式异常。原始输出: " .. output)
--         return nil, nil
--     end

--     http_status_code = tonumber(status_code_str)

--     msg.info("API 请求成功. HTTP状态码: " .. http_status_code)
--     msg.info("API 响应体: " .. json_body_str)

--     -- 解析 JSON 响应体
--     local json_data = json.decode(json_body_str)
--     if not json_data and json_body_str ~= "" then
--         msg.warn("API 响应体解析失败或为空: " .. json_body_str)
--     end

--     return json_data, http_status_code
-- end
function debug_log(message)
    if opts.debug_mode then
        -- 为了确保在默认控制台就能看到，我们还是用 msg.info
        msg.info("[DEBUG] " .. message)
    end
end

function api_request(method, url, data)
    debug_log("发送 API 请求: " .. method .. " " .. url)

    local headers = {
        'Authorization: Bearer ' .. opts.access_token,
        'User-Agent: witcheng/mpv-sync-script',
        'Content-Type: application/json'
    }

    -- 为了健壮性，我们使用一个几乎不可能出现在JSON中的复杂分隔符
    local separator = "\n--BGM_SYNC_SEPARATOR--\n"
    
    local args = { "curl", "-s", "-X", method }

    for _, h in ipairs(headers) do
        table.insert(args, "-H")
        table.insert(args, h)
    end

    -- 使用新的、更健壮的分隔符来写入HTTP状态码
    table.insert(args, "-w")
    table.insert(args, separator .. "%{http_code}")

    table.insert(args, url)

    if data then
        table.insert(args, "-d")
        -- 修正：如果data已经是json字符串，就不需要再encode了
        -- 但为了函数通用性，假设传入的是lua table
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
    -- 【核心修正】使用 string.find 和 string.sub 来分割，不再使用 regex
    local split_pos = output:find(separator, 1, true) -- plain search

    if not split_pos then
        msg.error("API 响应未能解析出有效的HTTP状态码或响应格式异常。原始输出: " .. output)
        return nil, nil
    end

    local json_body_str = output:sub(1, split_pos - 1)
    local http_code_str = output:sub(split_pos + #separator)
    
    local http_status_code = tonumber(http_code_str)

    -- 现在，这些日志可以被正确打印出来了
    debug_log("API 请求成功. HTTP状态码: " .. http_status_code)
    debug_log("API 响应体: " .. json_body_str)

    if json_body_str == "" then
        return {}, http_status_code -- 对于空响应体，返回一个空table而不是nil
    end

    local json_data, err = json.decode(json_body_str)
    if not json_data then
        msg.warn("API 响应体解析失败: " .. (err or "未知错误") .. ". 原始响应体: " .. json_body_str)
        return nil, http_status_code
    end

    return json_data, http_status_code
end

--- 一些基础功能，判断路径是否为协议，URL编码和解码等
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


function parse_title(title)
    if not title then return nil, nil end

    local original_title = title
    local anime_name, ep_number

    -- 预处理：移除常见的文件标签，提高匹配精度
    title = title:gsub("%[([%w%s-]+%]%s*)", "") -- 移除字幕组标签
    title = title:gsub("%b[]", "") -- 移除所有中括号内容 (如 [1080p], [HEVC])
    title = title:gsub("%b()", "") -- 移除所有小括号内容

    -- 匹配模式列表，从最精确到最模糊
    local patterns = {
        -- 格式: ... 第01话 / 第 1 集 ...
        "^(.*)%s*[第 ](%d+)[ ]?[话話集]",
        -- 格式: ... [01] / [01v2] ...
        "^(.*)%s*%[?(%d+)[vV]?%d*%]?%s",
        -- 格式: ... - 01 / _01 / S01E01
        "^(.*)%s*[-_ ]%s*[sS]?%d*[%s_.]?[eE]?(%d+)"
    }

    for _, pattern in ipairs(patterns) do
        anime_name, ep_number = title:match(pattern)
        if anime_name and ep_number then
            -- 清理番剧名
            anime_name = anime_name:gsub("[_.]", " "):gsub("%s*$", "")
            mp.osd_message("匹配成功: " .. anime_name .. " - 第 " .. ep_number .. " 集")
            msg.info("标题解析成功 -> 番名: '" .. anime_name .. "', 集数: '" .. ep_number .. "'")
            return anime_name, ep_number
        end
    end

    msg.warn("无法从标题解析番名和集数: " .. original_title)
    return nil, nil
end

-- 获取指定条目的收藏状态
function get_subject_status(subject_id)
    if not subject_id then return "error" end

    msg.info("get_subject_status: 开始查询 subject_id: " .. subject_id)
    -- 使用 "-" 占位符，这是个人脚本的正确做法
    local url = "https://api.bgm.tv/v0/users/" .. opts.username .. "/collections/" .. subject_id

    -- 1. 确保使用 "GET" 方法
    local result, http_code = api_request("GET", url)
    msg.warn("检测到subject收藏情况.type= " .. result.type .. " http_code= " .. tostring(http_code))

    -- 2. 优先处理 "未收藏" 的情况
    if http_code == 404 then
        msg.info("查询到收藏状态: uncollected (HTTP 404)")
        return "uncollected"
    end
    
    -- 3. 处理其他请求失败的情况
    if not result then
        msg.warn("get_subject_status: API 请求失败或返回空结果 (HTTP Code: " .. tostring(http_code) .. ")")
        return "error"
    end

    -- 4. 成功响应且包含预期的状态信息
    if http_code == 200 and result.type then
        local current_status = result.type
        debug_log("查询到收藏状态: " .. current_status)
        return current_status
    end
    
    -- 如果成功响应，但结构不符合预期，则打印警告
    msg.warn("get_subject_status: 未能从成功响应中解析收藏状态。收到的数据: " .. utils.to_string(result))
    return "uncollected"
end

-- 通用函数：获取作品(subject)或章节(episode)的收藏状态
-- @param item_type (string): 要查询的类型，必须是 "subject" 或 "episode"
-- @param item_id   (number): 对应类型的ID (subject_id 或 ep_id)
-- @return          (string): 返回状态码，如 "1", "2", "3", 或 "error"
function get_status(item_type, item_id)
    -- 1. 输入参数校验
    if not item_id or not (item_type == "subject" or item_type == "episode") then
        msg.warn("get_status: 参数错误。请提供正确的 item_type ('subject'或'episode') 和 item_id。")
        return "error"
    end

    debug_log(string.format("get_status: 开始查询 %s (ID: %s) 的状态...", item_type, item_id))

    -- 2. 根据 item_type 准备不同的配置
    local url
    local status_map
    local not_found_status -- 定义 404 错误对应的状态

    if item_type == "subject" then
        -- 注意：使用 "-" 代表当前登录用户，这比写死用户名 'witcheng' 更具通用性
        url = "https://api.bgm.tv/v0/users/witcheng/collections/" .. item_id
        status_map = subject_status_map
        not_found_status = "未收藏"
    else -- item_type == "episode"
        url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. item_id
        status_map = ep_status_map
        not_found_status = "未看"
    end

    -- 3. 发起 API 请求 (这部分逻辑是共用的)
    local result, http_code = api_request("GET", url)

    -- 4. 处理返回结果 (这部分逻辑也是共用的)
    if http_code == 404 then
        debug_log(string.format("查询到 %s (ID: %s) 的状态: %s (HTTP 404)", item_type, item_id, not_found_status))
        return not_found_status
    end

    if not result then
        msg.warn(string.format("get_status: %s (ID: %s) API 请求失败 (HTTP Code: %s)", item_type, item_id, tostring(http_code)))
        return "error"
    end

    if http_code == 200 and result.type then
        local current_status = result.type
        if current_status then
            debug_log(string.format("查询到 %s (ID: %s) 的状态: %s", item_type, item_id, status_map[current_status]))
            return current_status
        else
            -- API返回了一个我们映射表里没有的type码
            msg.warn(string.format("get_status: %s (ID: %s) 收到未知的状态 type: %s", item_type, item_id, tostring(result.type)))
            return "未知状态"
        end
    end
    
    -- 兜底错误处理
    msg.warn(string.format("get_status: 未能从 %s (ID: %s) 的响应中解析状态。收到的数据: %s", item_type, item_id, utils.to_string(result)))
    return "error"
end

-- 检查指定条目的所有正片是否已看完，如果是，则将其状态更新为"看过"
-- @param subject_id (number): 要检查的条目ID
function check_subject_all_watched(subject_id)
    if not subject_id then return end

    debug_log("check_subject_all_watched: 开始检查条目 " .. subject_id .. " 是否已全部看完")

    -- 【重要】这里的URL路径是 collections (复数)
    local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id .. "/episodes"
    local ep_list_result, http_code = api_request("GET", url)

    if not ep_list_result or not ep_list_result.data or http_code ~= 200 then
        msg.warn("无法获取章节列表来检查完成状态，操作中止。")
        return
    end

    local all_main_eps_watched = true -- 先假设所有都看完了
    for _, ep_info in ipairs(ep_list_result.data) do
        -- 【核心修正】我们现在检查的是 ep_info.episode.type 和 ep_info.type
        -- 1. 检查是否为正片 (ep_info.episode.type == 0)
        -- 2. 检查你对它的观看状态 (ep_info.type ~= 2)
        
        -- 首先确保 ep_info.episode 存在，增加代码健壮性
        if ep_info.episode and ep_info.episode.type == 0 then
            -- "看过" 对应的状态码是 2
            if ep_info.type ~= 2 then
                all_main_eps_watched = false
                debug_log("发现未看完的正片: " .. (ep_info.episode.name_cn or ep_info.episode.name or ep_info.episode.id) .. "，无需更新条目状态。")
                break
            end
        end
    end

    if all_main_eps_watched then
        mp.osd_message("所有正片已看完，正在更新条目状态为 [看过]...")
        debug_log("所有正片已看完，准备将条目 " .. subject_id .. " 更新为'看过'")
        
        local update_url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
        local payload = { type = 2 }
        local result, update_code = api_request("POST", update_url, payload)

        if update_code and update_code >= 200 and update_code < 300 then
            mp.osd_message("成功标记为 [看过]")
            debug_log("成功将条目 " .. subject_id .. " 标记为 [看过]")
        else
            mp.osd_message("更新条目为 [看过] 失败")
            msg.warn("更新条目为 [看过] 失败，HTTP Code: " .. tostring(update_code))
        end
    end
end

-- 更新条目状态
-- @param subject_id (number): 要更新的条目ID
-- @param status_type (string): 要更新的状态类型，
function update_subject_status(subject_id, status_type)
    if not subject_id then return end

    debug_log("update_subject_status: 开始更新条目 " .. subject_id .. " 的状态为 " .. status_type)

    local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
    local payload = { type = status_type }

    local result, http_code = api_request("POST", url, payload)
    -- local result, http_code = api_request("POST", url, {type = 2})

    if http_code and http_code >= 200 and http_code < 300 then
        mp.osd_message("成功更新条目状态为 [" .. subject_status_map[status_type] .. "]")
        debug_log("成功将条目 " .. subject_id .. " 更新为 ".. subject_status_map[status_type] .."["  .. status_type .. "]")
    else
        mp.osd_message("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败")
        msg.warn("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败，HTTP Code: " .. tostring(http_code))
    end
end

-- 更新章节状态
-- @param ep_id (number): 要更新的章节ID
-- @param status_type (string): 要更新的状态类型
function update_episode_status(ep_id, status_type)
    if not ep_id then return false end

    local url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. ep_id
    local payload = { type = status_type }

    local result, http_code = api_request("PUT", url, payload)
    -- local result, http_code = api_request("PUT", url, {type = 2})

    if http_code and http_code >= 200 and http_code < 300 then
        mp.osd_message("成功更新章节状态为 [" .. ep_status_map[status_type] .. "]")
        debug_log("成功将章节 " .. ep_id .. " 更新为 " .. ep_status_map[status_type] .."["  .. status_type .. "]")
        return true
    else
        mp.osd_message("更新章节状态为 [" .. ep_status_map[status_type] .. "] 失败")
        msg.warn("更新章节状态为 [" .. ep_status_map[status_type] .. "] 失败，HTTP Code: " .. tostring(http_code))
        return false
    end
end


-- 异步查找剧集 (接受回调函数)
function find_episode_async(media_title, on_success)
    mp.add_timeout(0, function()
        local anime_name, ep_number = parse_title(media_title)
        if not anime_name or not ep_number then
            mp.osd_message("无法从标题解析番名和集数")
            return
        end
        
        mp.osd_message("正在搜索: " .. anime_name)
        local search_url = "https://api.bgm.tv/search/subject/" .. url_encode(anime_name) .. "?type=2"
        local search_result, http_code = api_request("GET", search_url)

        if not search_result or not search_result.list or #search_result.list == 0 then
            mp.osd_message("搜索失败，未找到番剧: " .. anime_name)
            return
        end

        -- 取第一个结果，假设它是最相关的，之后再修改
        local subject = search_result.list[1]   
        current_subject_id = subject.id
        msg.info("找到条目: " .. subject.name_cn .. " (ID: " .. current_subject_id .. ")")

        local ep_list_url = "https://api.bgm.tv/v0/episodes?subject_id=" .. current_subject_id
        local ep_list_result, http_code = api_request("GET", ep_list_url)

        local found_ep = nil
        if ep_list_result and ep_list_result.data then
            for _, ep in ipairs(ep_list_result.data) do
                if ep.type == 0 and ep.sort == tonumber(ep_number) then
                    found_ep = ep
                    break
                end
            end
        end

        if found_ep then
            current_ep_id = found_ep.id
            mp.osd_message("匹配成功: " .. subject.name_cn .. " - " .. (found_ep.name_cn or found_ep.name))
            if on_success and type(on_success) == "function" then
                on_success()
            end
        else
            mp.osd_message("找到番剧但未匹配到第 " .. ep_number .. " 集")
            current_subject_id = nil -- 匹配失败，重置
        end
    end)
end

-- function on_file_load()
--     msg.info("on_file_load: 文件加载事件触发")
--     -- 重置状态,当视频文件加载时，触发查找函数。后面再修改
--     current_subject_id = nil
--     current_ep_id = nil
--     is_sync_enabled = false
--     is_marked_as_watched = false

--     local media_title = mp.get_property("media-title")
--     -- find_episode_async(media_title)
-- end

-- -- 文件切换，正在重置所有同步状态
-- function reset_script_state()
    
--     current_subject_id = nil
--     current_ep_id = nil
--     current_collection_status = nil
--     is_sync_enabled = false
--     is_marked_as_watched = false
    
--     msg.info("synbangumi状态已重置。")
--     msg.info("--------------------------------------------------")
-- end

-- 文件切换，正在重置所有同步状态
function on_path_change(name, new_path)
    -- 这可以防止在 mpv 启动时 (path为nil) 或关闭文件时 (path变为nil) 触发重置。
    if new_path then
        current_subject_id = nil
        current_ep_id = nil
        current_collection_status = nil
        is_sync_enabled = false
        is_marked_as_watched = false
        is_current_ep_marked = false -- 重置当前集标记状态
        msg.info("synbangumi状态已重置。")
        msg.info("--------------------------------------------------")
    end
end


-------- 使用快捷键切换同步状态  --------
-- 这里我们使用 "r" 键来切换同步状态

-- function toggle_sync()
--     if not current_subject_id then
--         mp.osd_message("未匹配到番剧，无法同步")
--         return
--     end

--     is_sync_enabled = not is_sync_enabled

--     if is_sync_enabled then
--         mp.osd_message("同步已开启")
--         -- 开启同步时，标记为“在看”
--         local _, ep_number = parse_title(mp.get_property("media-title"))
--         update_progress(current_subject_id, ep_number, "do")
--         is_marked_as_watched = false -- 重置标记状态
--     else
--         mp.osd_message("同步已关闭")
--     end
-- end

-- function toggle_sync()
--     if is_sync_enabled then
--         is_sync_enabled = false
--         mp.osd_message("同步已关闭")
--         return
--     end

--     -- 这个子函数现在只负责根据一个已知的状态来执行操作
--     local function process_status_and_sync(status)
--         msg.info("开始处理状态: " .. tostring(status))
--         if status == "error" then
--             mp.osd_message("查询收藏状态失败，请检查控制台日志")
--             return
--         end

--         if status == "collect" then
--             is_sync_enabled = true
--             is_marked_as_watched = true
--             mp.osd_message("同步已开启 (状态: 已看过)")
--             return
--         end
        
--         is_sync_enabled = true
--         update_collection_status(current_subject_id, nil, "do")
--         is_marked_as_watched = false
--     end
    
--     -- 主逻辑：决定是查本地还是查服务器
--     local function start_sync_logic()
--         -- 【关键修改】优先检查本地缓存
--         if current_collection_status then
--             msg.info("使用本地缓存的状态: " .. current_collection_status)
--             process_status_and_sync(current_collection_status)
--         else
--             -- 如果本地没有缓存，才去查询服务器
--             mp.osd_message("正在查询收藏状态...")
--             local server_status = get_subject_status(current_subject_id)
--             current_collection_status = server_status -- 查询后，立即存入本地缓存
--             msg.info("从服务器获取状态并存入本地缓存: " .. tostring(current_collection_status))
--             process_status_and_sync(server_status)
--         end
--     end

--     if current_subject_id then
--         start_sync_logic()
--     else
--         mp.osd_message("首次同步，正在匹配番剧...")
--         local media_title = mp.get_property("media-title")
--         find_episode_async(media_title, start_sync_logic)
--     end
-- end

function toggle_sync()
    if is_sync_enabled then
        is_sync_enabled = false
        mp.osd_message("同步已关闭")
        msg.info("同步功能已手动关闭")
        return
    end

    -- 核心同步逻辑，在获取到 subject_id 后执行
    local function start_sync()
        mp.osd_message("正在查询收藏状态...")
        -- 查询当前条目的收藏状态
        local current_status = get_status("subject", current_subject_id)

        if current_status == "error" then
            mp.osd_message("查询状态失败，请检查日志")
            return
        end
        
        -- 根据当前状态决定操作，如果当前状态是 "看过" 或 "在看"，则开启同步
        if current_status == 2 or current_status == 3 then
            is_sync_enabled = true
            mp.osd_message("同步已开启 (状态: " .. current_status .. ")")
            msg.info("同步已开启，当前状态为: " .. current_status)
        else
            -- 对于 "未收藏", "想看", "搁置", "抛弃" 等状态，都更新为"在看"
            is_sync_enabled = true
            mp.osd_message("状态为[" .. current_status .. "]，正在标记为[在看]...")
            -- "在看" 对应的 type 码是 3
            update_subject_status(current_subject_id, 3)
        end
    end

    -- 检查是否已有番剧信息，没有则先查找
    if current_subject_id then
        start_sync()
    else
        mp.osd_message("首次同步，正在匹配番剧...")
        local media_title = mp.get_property("media-title")
        -- 将 start_sync 作为成功匹配后的回调函数
        find_episode_async(media_title, start_sync)
    end
end

-- -- 监听播放进度变化
-- -- 当进度超过 80% 时，自动标记为“看过”
-- function on_progress_change(name, value)
--     -- value 是播放进度百分比 (0-100)
--     if is_sync_enabled and not is_marked_as_watched and value > 80 then
--         mp.osd_message("进度超过 80%，自动标记为看过...")
--         local _, ep_number = parse_title(mp.get_property("media-title"))
--         update_collection_status(current_subject_id, current_ep_id, "collect")
--         is_marked_as_watched = true -- 标记完成，避免重复调用
--     end
-- end

-- 监听播放进度变化
-- 当进度超过 80% 时，自动标记为“看过”
function on_progress_change(name, value)
    -- value 是播放进度百分比 (0-100)
    -- 检查：同步是否开启？当前集是否还未被标记？进度是否达标？
    if is_sync_enabled and not is_current_ep_marked and value and value > 80 then
        
        -- 立即设置标志，防止因进度条抖动或重复触发而多次调用
        is_current_ep_marked = true 
        
        if not current_subject_id or not current_ep_id then
            mp.osd_message("警告: 进度达标但未获取番剧信息，无法自动标记")
            msg.warn("进度达标但 current_subject_id 或 current_ep_id 为空")
            return
        end

        mp.osd_message("进度超过 80%，自动标记本集为 [看过]...")
        msg.info("进度达标，准备自动标记...")

        -- "看过" 对应的 type 码是 2
        local success = update_episode_status(current_ep_id, 2)

        -- 【关键联动】如果标记成功，立即触发“检查整部剧是否完结”的逻辑
        if success then
            -- 延迟0.5秒执行，避免OSD消息重叠，提升用户体验
            mp.add_timeout(0.5, function()
                check_subject_all_watched(current_subject_id)
            end)
        end
    end
end


mp.observe_property("path", "string", on_path_change)
mp.observe_property("percent-pos", "number", on_progress_change)

mp.add_key_binding("ctrl+g", "toggle-sync", toggle_sync)

function test_get_status()
    local subject_id = 424663
    local status = get_status("subject", subject_id) 
    msg.info("测试获取状态: " .. subject_id .. " -> " .. status)

    local episode_id = 1277148
    local status = get_status("episode", episode_id)
    msg.info("测试获取状态: " .. episode_id .. " -> " .. status)
end
-- mp.add_key_binding("ctrl+g", "toggle-sync", test_get_status)


function test_update_status()
    local subject_id = 424663
    local ep_id = 1277148
    local status_type = 2 -- 假设我们要标记为“看过”
    -- test_get_status()
    -- msg.info("========================")
    -- update_subject_status(subject_id, status_type)
    -- msg.info("========================")
    -- update_episode_status(ep_id, status_type)
    check_subject_all_watched(subject_id)
end

-- mp.add_key_binding("ctrl+g", "toggle-sync", test_update_status)






-- 测试 API 请求，判断是否能成功获取用户信息
function test_api()
    local user_info = api_request("GET", "https://api.bgm.tv/v0/me")
    if user_info and user_info.username then
        mp.osd_message("Bangumi 登录成功: " .. user_info.username)
    else
        mp.osd_message("Bangumi API 测试失败!")
    end
end

-- 测试 API 请求，判断是否能成功获取用户信息
mp.register_script_message("test-api", function()
    test_api()
end)