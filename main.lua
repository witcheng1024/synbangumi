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
    access_token = ""
}
options.read_options(opts, _, function() end)

local current_subject_id = nil
local current_ep_id = nil
local current_collection_status = nil -- 新增：用于缓存收藏状态

local is_sync_enabled = false
local is_marked_as_watched = false


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
--     msg.info("发送 API 请求: " .. method .. " " .. url)
    
--     local headers = {
--         'Authorization: Bearer ' .. opts.access_token,
--         'User-Agent: witcheng/mpv-sync-script', -- 推荐写一个User-Agent
--         'Content-Type: application/json'
--     }

--     local args = { "curl", "-s", "-X", method }

--     for _, h in ipairs(headers) do
--         table.insert(args, "-H")
--         table.insert(args, h)
--     end
    
--     table.insert(args, url)

--     if data then
--         table.insert(args, "-d")
--         table.insert(args, json.encode(data)) -- 将 Lua table 转为 JSON 字符串
--     end

--     -- mp.commandv 会执行外部命令
--     local res = mp.command_native({
--         name = "subprocess",
--         args = args,
--         capture_stdout = true -- 捕获输出
--     })

--     if res.status ~= 0 then
--         msg.error("API 请求失败: " .. (res.stderr or "未知错误"))
--         return nil
--     end
--     msg.info("API 请求成功: " .. res.status )
--     msg.info("API 响应: " .. res.stdout)
--     -- msg.info("API 响应: 成功" )
--     return json.decode(res.stdout) -- 将返回的 JSON 字符串转为 Lua table
-- end

function api_request(method, url, data)
    msg.info("发送 API 请求: " .. method .. " " .. url)

    local headers = {
        'Authorization: Bearer ' .. opts.access_token,
        'User-Agent: witcheng/mpv-sync-script',
        'Content-Type: application/json'
    }

    local args = { "curl", "-s", "-X", method }

    for _, h in ipairs(headers) do
        table.insert(args, "-H")
        table.insert(args, h)
    end

    -- 使用特殊分隔符来定位 HTTP 状态码
    local status_marker = "__HTTP_STATUS__:"
    table.insert(args, "-w")
    table.insert(args, "\n" .. status_marker .. "%{http_code}")

    table.insert(args, url)

    if data then
        table.insert(args, "-d")
        table.insert(args, json.encode(data))
    end

    -- 执行 curl 命令
    local res = mp.command_native({
        name = "subprocess",
        args = args,
        capture_stdout = true
    })

    -- 检查命令是否执行成功
    if res.status ~= 0 then
        msg.error("API 请求失败 (curl 命令退出码非0): " .. (res.stderr or "未知错误"))
        return nil, nil
    end

    local output = res.stdout
    local http_status_code = nil
    local json_body_str = ""

    -- 使用分隔符匹配状态码与 JSON
    json_body_str, status_code_str = output:match("^(.-)\n" .. status_marker .. "(%d%d%d)$")
    if not json_body_str or not status_code_str then
        msg.error("API 响应未能解析出有效的HTTP状态码或响应格式异常。原始输出: " .. output)
        return nil, nil
    end

    http_status_code = tonumber(status_code_str)

    msg.info("API 请求成功. HTTP状态码: " .. http_status_code)
    msg.info("API 响应体: " .. json_body_str)

    -- 解析 JSON 响应体
    local json_data = json.decode(json_body_str)
    if not json_data and json_body_str ~= "" then
        msg.warn("API 响应体解析失败或为空: " .. json_body_str)
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
            msg.info("标题解析成功 -> 番名: '" .. anime_name .. "', 集数: '" .. ep_number .. "'")
            return anime_name, ep_number
        end
    end

    msg.warn("无法从标题解析番名和集数: " .. original_title)
    return nil, nil
end

-- 获取指定条目的收藏状态
-- function get_collection_status(subject_id)
--     if not subject_id then return "error" end

--     msg.info("get_collection_status: 开始查询 subject_id: " .. subject_id)
--     local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
--     local result = api_request("GET", url)

--     -- API 请求本身就失败了 (网络问题、Token错等)
--     if not result then
--         msg.warn("get_collection_status: api_request 返回 nil，请求失败")
--         return "error"
--     end

--     -- API 返回了有效数据，且包含状态信息
--     if result.status and result.status.type then
--         local status_map = {
--             watching = "do",
--             completed = "collect",
--             wished = "wish",
--             dropped = "dropped",
--             on_hold = "on_hold"
--         }
--         return status_map[result.status.type] or "uncollected"
--     end
    
--     -- API 返回了有效数据，但不包含状态 (通常是404，表示从未收藏过)
--     msg.info("get_collection_status: 未找到收藏状态")
--     return "uncollected"
-- end
function get_collection_status(subject_id)
    if not subject_id then return "error" end

    msg.info("get_collection_status: 开始查询 subject_id: " .. subject_id)
    -- 使用 "-" 占位符，这是个人脚本的正确做法
    local url = "https://api.bgm.tv/v0/users/witcheng/collections/" .. subject_id
    
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
        msg.warn("get_collection_status: API 请求失败或返回空结果 (HTTP Code: " .. tostring(http_code) .. ")")
        return "error"
    end

    -- 4. 成功响应且包含预期的状态信息
    if http_code == 200 and result.type then
        local current_status = result.type
        msg.info("查询到收藏状态: " .. current_status)
        return current_status
    end
    
    -- 如果成功响应，但结构不符合预期，则打印警告
    msg.warn("get_collection_status: 未能从成功响应中解析收藏状态。收到的数据: " .. utils.to_string(result))
    return "uncollected"
end

-- 更新收藏状态 
function update_collection_status(subject_id, ep_id, status_type)
    if not subject_id then return end

    -- 修复 #1: 删除了那一行无效的旧API调用。

    local success = false -- 用于跟踪API调用是否成功

    if status_type == "do" then
        local url = "https://api.bgm.tv/v0/users/-/collections/" .. subject_id
        local result, http_code = api_request("POST", url, { type = "do" })
        -- 修复 #2: 增加了基本的成功判断
        if http_code and http_code >= 200 and http_code < 300 then
            mp.osd_message("已标记为 [在看]")
            msg.info("已标记为 [在看]")
            success = true
        else
            mp.osd_message("标记 [在看] 失败")
        end

    elseif status_type == "collect" and ep_id then
        local url = string.format("https://api.bgm.tv/v0/users/-/collections/%d/ep/%d", subject_id, ep_id)
        local result, http_code = api_request("PATCH", url, { type = "watched" })
        -- 修复 #2: 增加了基本的成功判断
        if http_code and http_code == 204 then
            mp.osd_message("已标记为 [看过]")
            msg.info("已标记为 [看过]")
            success = true
        else
            mp.osd_message("标记 [看过] 失败")
        end
    end

    -- 修复 #3: 只有在API调用成功时，才更新本地状态
    if success then
        current_collection_status = status_type
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

function toggle_sync()
    if is_sync_enabled then
        is_sync_enabled = false
        mp.osd_message("同步已关闭")
        return
    end

    -- 这个子函数现在只负责根据一个已知的状态来执行操作
    local function process_status_and_sync(status)
        msg.info("开始处理状态: " .. tostring(status))
        if status == "error" then
            mp.osd_message("查询收藏状态失败，请检查控制台日志")
            return
        end

        if status == "collect" then
            is_sync_enabled = true
            is_marked_as_watched = true
            mp.osd_message("同步已开启 (状态: 已看过)")
            return
        end
        
        is_sync_enabled = true
        update_collection_status(current_subject_id, nil, "do")
        is_marked_as_watched = false
    end
    
    -- 主逻辑：决定是查本地还是查服务器
    local function start_sync_logic()
        -- 【关键修改】优先检查本地缓存
        if current_collection_status then
            msg.info("使用本地缓存的状态: " .. current_collection_status)
            process_status_and_sync(current_collection_status)
        else
            -- 如果本地没有缓存，才去查询服务器
            mp.osd_message("正在查询收藏状态...")
            local server_status = get_collection_status(current_subject_id)
            current_collection_status = server_status -- 查询后，立即存入本地缓存
            msg.info("从服务器获取状态并存入本地缓存: " .. tostring(current_collection_status))
            process_status_and_sync(server_status)
        end
    end

    if current_subject_id then
        start_sync_logic()
    else
        mp.osd_message("首次同步，正在匹配番剧...")
        local media_title = mp.get_property("media-title")
        find_episode_async(media_title, start_sync_logic)
    end
end



-- 监听播放进度变化
-- 当进度超过 80% 时，自动标记为“看过”
function on_progress_change(name, value)
    -- value 是播放进度百分比 (0-100)
    if is_sync_enabled and not is_marked_as_watched and value > 80 then
        mp.osd_message("进度超过 80%，自动标记为看过...")
        local _, ep_number = parse_title(mp.get_property("media-title"))
        update_collection_status(current_subject_id, current_ep_id, "collect")
        is_marked_as_watched = true -- 标记完成，避免重复调用
    end
end


mp.observe_property("path", "string", on_path_change)
mp.observe_property("percent-pos", "number", on_progress_change)

mp.add_key_binding("ctrl+g", "toggle-sync", toggle_sync)









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