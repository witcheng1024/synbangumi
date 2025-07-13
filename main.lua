-- synbangumi.lua
-- 引入工具
local mp = require 'mp'
local msg = require "mp.msg"
local utils = require 'mp.utils'
local options = require "mp.options"
local input_available, input = pcall(require, "mp.input")

local json = require 'bin/json'

-- 读取配置文件
local opts = {
    access_token = "", -- Bangumi Access Token
    debug_mode = false, -- 是否开启调试模式
    username = "" -- Bangumi用户名
}
options.read_options(opts, _, function() end)

local current_subject_name = nil -- 当前匹配的番剧名
local current_ep_name = nil -- 当前匹配的集名
local current_ep_number = nil -- 当前匹配的集数
local current_subject_id = nil
local current_ep_id = nil

local is_sync_enabled = false
local is_current_ep_marked = false -- 新变量：用于标记当前集是否已被处理过


local subject_status_map = {
    [1] = "想看",
    [2] = "看过",
    [3] = "在看",
    [4] = "搁置",
    [5] = "抛弃",
    ["uncollected"] = "未收藏" -- 新增：未收藏状态
}
local ep_status_map = {
    [0] = "未看",
    [1] = "想看",
    [2] = "看过",
    [3] = "抛弃",
    ["uncollected"] = "未看" -- 新增：未看状态
}

-- 检查access_token是否配置
if opts.access_token == "" or opts.access_token == "YOUR_ACCESS_TOKEN_HERE" then
    msg.error("Bangumi Access Token 未配置! 请在 script-opts/synbangumi.conf 中设置。")
    -- 退出脚本
    return
end

msg.info("synbangumi.lua 脚本已加载，配置读取成功。")

-- 调试日志函数

function debug_log(message)
    if opts.debug_mode then
        -- 为了确保在默认控制台就能看到，我们还是用 msg.info
        msg.info("[DEBUG] " .. message)
    end
end

-- API 请求函数
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

-- 步骤 4 (最终选择): 这个函数现在由消息触发，并且负责启动同步
function on_episode_selected(ep_info)
    msg.info("4. [on_episode_selected] 用户已手动选定章节。")

    -- 1. 为全局变量赋值
    current_subject_id = ep_info.subject_id
    current_ep_id = ep_info.id
    current_ep_name = ep_info.name_cn or ep_info.name or ""
    current_ep_number = ep_info.sort
    current_subject_name = ep_info.subject_name

    -- 2. 直接调用核心同步引擎
    -- 因为我们已经手动拿到了所有信息
    execute_core_sync()
end


-- 步骤 3: 获取章节列表，现在需要把 subject_name 也传进来
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
        if ep.type == 0 then
            -- 【关键修正】在这里决定最终使用的名字
            local ep_name = ep.name_cn and ep.name_cn:match("%S") and ep.name_cn or ep.name or ""
            -- ep.name_cn:match("%S") 是为了确保中文名不是空的或只包含空格

            -- 创建信息包，只使用一个 name 字段
            local full_ep_info = {
                id = ep.id,
                sort = ep.sort,
                name = ep_name, -- <--- 只使用这一个 name
                subject_id = subject_id,
                subject_name = subject_name
            }
            debug_log("章节信息：" .. utils.to_string(full_ep_info)) -- 调试日志

            table.insert(items, {
                title = string.format("EP.%d %s", ep.sort, ep_name), -- 显示时也用统一后的名字
                value = {
                    "script-message-to",
                    mp.get_script_name(),
                    "bangumi-episode-selected",
                    utils.to_string(full_ep_info)
                }
            })
        end
    end
    
    mp.add_timeout(0.1, function()
        open_menu_select("选择一个章节:", items)
    end)
end

-- 步骤 2: 搜索番剧，现在打包的信息更完整
function search_bangumi_and_show(query)
    msg.info("2. [search_bangumi_and_show] 正在搜索: " .. query)
    send_message("正在搜索: " .. query)

    local search_url = "https://api.bgm.tv/search/subject/" .. url_encode(query) .. "?type=2"
    local search_result, http_code = api_request("GET", search_url)

    if not search_result or not search_result.list or #search_result.list == 0 then
        send_message("搜索失败: " .. query)
        return
    end

    local items = {}
    for i = 1, math.min(8, #search_result.list) do
        local subject = search_result.list[i]
        -- 【重要调整】打包番剧ID和番剧名
        local subject_info = {
            id = subject.id,
            name = subject.name_cn or subject.name
        }
        table.insert(items, {
            title = subject_info.name,
            value = {
                "script-message-to",
                mp.get_script_name(),
                "bangumi-show-selected",
                utils.to_string(subject_info) -- 序列化后发送
            }
        })
    end
    
    mp.add_timeout(0.1, function()
        open_menu_select("选择一个番剧:", items)
    end)
end

-- -- 步骤 1 (入口): 这里也使用“组合拳”
function start_manual_sync()
     -- 【关键新增】检查总开关是否开启
    if not is_sync_enabled then
        send_message("同步功能未开启，请先按 Ctrl+G 开启")
        msg.warn("用户尝试手动同步，但总开关未开启。")
        return -- 直接退出，不执行后续操作
    end

    msg.info("手动同步流程启动 (总开关已开启)...")
    local default_search = mp.get_property("media-title", "")
    local anime_name, _ = parse_title(default_search)
    
    input.get({
        prompt = "搜索番剧:",
        text = anime_name,
        submit = function(query)
            if query and query ~= "" then
                input.terminate() -- 强行关闭
                -- 发送信件，而不是直接调用函数
                mp.commandv("script-message-to", mp.get_script_name(), "bangumi-search-requested", query)
            end
        end
    })
end

-- -- 这是您的 open_menu_select，它现在负责发送“信件”
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
                -- 发送信件
                mp.commandv(unpack(item_values[id]))
            end
        end,
    })
end

-- -- 收到“请求搜索”的信
mp.register_script_message("bangumi-search-requested", function(query)
    -- 使用一个微小延迟，给UI足够的时间从 terminate 中恢复
    mp.add_timeout(0.1, function()
        search_bangumi_and_show(query)
    end)
end)

-- 收到“选择了番剧”的信
mp.register_script_message("bangumi-show-selected", function(subject_info_str)
    local subject_info = utils.parse_json(subject_info_str) -- 反序列化
    get_and_show_episodes(subject_info.id, subject_info.name)
end)

-- 收到“选择了章节”的信
mp.register_script_message("bangumi-episode-selected", function(ep_info_str)
    local ep_info = utils.parse_json(ep_info_str) -- 反序列化
    on_episode_selected(ep_info)
end)


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



message_overlay = mp.create_osd_overlay('ass-events')
message_timer = mp.add_timeout(3, function ()
    message_overlay:remove()
end, true)

mp.observe_property('osd-width', 'number', function(_, value) osd_width = value or osd_width end)
mp.observe_property('osd-height', 'number', function(_, value) osd_height = value or osd_height end)
function send_message(text, time)
    message_timer.timeout = time or 3
    message_timer:kill()
    message_overlay:remove()
    local message = string.format("{\\an%d\\pos(%d,%d)}%s", 7,30,30, text)
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



function parse_title(title)
    if not title then
        msg.warn("parse_title 被调用，但标题为 nil。")
        return nil, nil
    end

    local original_title = title

    -- 每个解析器包含一个正则表达式和一个处理函数
    local parsers = {
        -- 解析器1: 专为 Emby 格式 (番名 S1:E1-集名)
        {
            regex = "^(.-)%s*[sS](%d+):[eE](%d+)%-?.*",
            handler = function(name, season, episode)
                return name, episode, season
            end
        },
        -- 解析器2: 专为标准季/集格式 (S01E01)
        {
            regex = "^(.-)%s*[sS](%d+)[%s_.-]*[eE](%d+)",
            handler = function(name, season, episode)
                return name, episode, season
            end
        },
        -- 解析器3: 专为中文格式 (第01话)
        {
            regex = "^(.-)[%s_.]*第%s*(%d+)[%s_.]*[话話集]",
            handler = function(name, episode)
                return name, episode, "1" -- 默认季数为1
            end
        },
        -- 解析器4: 专为方括号格式 ([01])
        {
            regex = "^(.-)%s*%[(%d+)[vV]?%d*%]",
            handler = function(name, episode)
                return name, episode, "1"
            end
        },
        -- 解析器5: 专为独立剧集格式 ( - 01)
        {
            regex = "^(.-)%s*[-_]%s*(%d+)%s*[^%d%.]",
            handler = function(name, episode)
                return name, episode, "1"
            end
        },
        -- 解析器6: 专为年份+集数格式 (Fate.2014.09)
        {
            regex = "^(.-)%.(%d%d%d%d)%.(%d+)$",
            handler = function(name, year, episode)
                -- 可以在这里选择是否将年份附加到名字后面
                return name .. " " .. year, episode, "1"
            end
        }
    }

    -- 【借鉴 guess.lua】独立的清理函数
    local function clean_anime_name(name)
        if not name then return "" end
        name = name:gsub('%b[]', ''):gsub('%b()', '')
        name = name:gsub('[._-]', ' ')
        name = name:gsub('%s*[sS]%d+$', '')
        name = name:gsub('^%s*(.-)%s*$', '%1')
        return name
    end

    -- 遍历所有解析器
    for _, parser in ipairs(parsers) do
        local matches = { original_title:match(parser.regex) }
        
        if #matches > 0 then
            -- 如果匹配成功，调用对应的处理函数
            local raw_name, episode, season = parser.handler(unpack(matches))
            
            -- 对处理函数返回的原始名称进行最终清理
            local final_name = clean_anime_name(raw_name)

            if final_name and final_name ~= "" then
                msg.info("标题解析成功 -> 模式: '" .. parser.regex .. "', 番名: '" .. final_name .. "', 集数: '" .. episode .. "'")
                -- 只返回我们需要的番名和集数
                return final_name, tostring(episode)
            end
        end
    end

    msg.warn("所有模式均无法从标题解析番名和集数: " .. original_title)
    return nil, nil
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
  

    if item_type == "subject" then

        url = "https://api.bgm.tv/v0/users/" .. opts.username .. "/collections/" .. item_id
        status_map = subject_status_map
        -- not_found_status = "未收藏"
    else -- item_type == "episode"
        url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. item_id
        status_map = ep_status_map
        -- not_found_status = "未看"
    end

    -- 3. 发起 API 请求 (这部分逻辑是共用的)
    local result, http_code = api_request("GET", url)

    -- 4. 处理返回结果 (这部分逻辑也是共用的)
    if http_code == 404 then
        debug_log(string.format("查询到 %s (ID: %s) 的状态: %s (HTTP 404)", item_type, item_id, status_map["uncollected"]))
        return "uncollected" -- 或 "unwatched" 取决于 item_type
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
                msg.info("发现未看完的正片: " .. (ep_info.episode.name_cn or ep_info.episode.name or ep_info.episode.id) .. " ，无需更新条目状态。")
                break
            end
        end
    end

    if all_main_eps_watched then
        send_message("所有正片已看完，正在更新 " .. current_subject_name .. " 状态为 [看过]...")
        msg.info("所有正片已看完，准备将条目 " .. subject_id .. " 更新为'看过'")
        
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
        -- send_message("成功更新条目状态为 [" .. subject_status_map[status_type] .. "]")
        debug_log("成功将条目 " .. subject_id .. " 更新为 ".. subject_status_map[status_type] .."["  .. status_type .. "]")
    else
        send_message("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败")
        msg.warn("更新条目状态为 [" .. subject_status_map[status_type] .. "] 失败，HTTP Code: " .. tostring(http_code))
    end
end

-- 更新章节状态
-- @param ep_id (number): 要更新的章节ID
-- @param status_type (string): 要更新的状态类型
-- @return (boolean): 返回是否更新成功
function update_episode_status(ep_id, status_type)
    if not ep_id then return false end

    local url = "https://api.bgm.tv/v0/users/-/collections/-/episodes/" .. ep_id
    local payload = { type = status_type }

    local result, http_code = api_request("PUT", url, payload)
    -- local result, http_code = api_request("PUT", url, {type = 2})

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


-- 异步查找剧集 (现在会打包信息并传递给回调)
function find_episode_async(media_title, on_success)
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

        local subject = search_result.list[1]
        local subject_id = subject.id
        local subject_name = subject.name_cn or subject.name or " " -- 使用中文名或原名，确保不为nil

        msg.info("找到条目: " .. subject_name .. " (ID: " .. subject_id .. ")")

        local ep_list_url = "https://api.bgm.tv/v0/episodes?subject_id=" .. subject_id
        local ep_list_result, http_code = api_request("GET", ep_list_url)

        local found_ep = nil
        if ep_list_result and ep_list_result.data then
            for _, ep in ipairs(ep_list_result.data) do
                -- 确保在比较前将字符串转换为数字
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
                -- 【关键修正】
                -- 1. 创建一个信息包 (ep_info)，就像我们手动选择时做的那样
                local ep_info_package = {
                    subject_id = subject_id,
                    subject_name = subject_name,
                    id = ep_id,
                    name = ep_name,
                    sort = tonumber(ep_number_str) -- 确保集数是数字
                }
                
                -- 2. 将这个信息包作为参数传递给回调函数
                on_success(ep_info_package)
            end
        else
            send_message("找到番剧但未匹配到第 " .. ep_number_str .. " 集")
        end
    end)
end


-- 文件切换，正在重置所有同步状态
function on_path_change(name, new_path)
    -- 这可以防止在 mpv 启动时 (path为nil) 或关闭文件时 (path变为nil) 触发重置。
    if new_path then
        current_subject_name = nil -- 重置当前匹配的番剧名
        current_ep_name = nil -- 重置当前匹配的集名
        current_ep_number = nil -- 重置当前匹配的集数
        current_subject_id = nil
        current_ep_id = nil
        
        is_sync_enabled = false
        is_current_ep_marked = false -- 重置当前集标记状态
        -- toggle_sync()

        debug_log("synbangumi状态已重置。")
        debug_log("--------------------------------------------------")
    end
end



-- 这是同步的核心逻辑，不绑定任何快捷键
function execute_core_sync()
    -- 查询当前条目的收藏状态
    local current_status = get_status("subject", current_subject_id)

    if current_status == "error" then
        send_message("查询状态失败，请检查日志")
        return
    end

    -- 只有在成功获取信息后，才正式将总开关置为 true
    is_sync_enabled = true
    send_message(current_subject_name .. "第 " .. current_ep_number .. "集: " .. current_ep_name .. " \\N Bangumi同步中...")

    if current_status == 2 or current_status == 3 then
        msg.info("同步已开启，当前条目状态为: " .. subject_status_map[current_status])
    else
        msg.info("第 " .. current_ep_number .. "集: " .. current_ep_name .. " 状态为 " .. subject_status_map[current_status] .. "，正在标记为 [在看]...")
        update_subject_status(current_subject_id, 3)
    end
end

-- 绑定到 Ctrl+G 的总开关函数
function master_toggle_sync()
    if is_sync_enabled then
        -- 如果同步已开启，则关闭它
        is_sync_enabled = false
        send_message("同步已关闭")
        msg.info("同步功能已手动关闭")
        -- 这里可以添加停止 scrobble 的逻辑（如果需要）
        return
    end

    -- 如果同步是关闭的，则开启它，并立即尝试自动同步
    send_message("同步功能已开启，正在尝试自动匹配...")
    msg.info("同步功能已开启，正在尝试自动匹配...")
    local media_title = mp.get_property("media-title")

    -- 这是一个回调函数，当 find_episode_async 成功后会被调用
    local function on_auto_sync_success(ep_info)
        -- 1. 为全局变量赋值
        current_subject_id = ep_info.subject_id
        current_ep_id = ep_info.id
        current_ep_name = ep_info.name_cn or ep_info.name or ""
        current_ep_number = ep_info.sort
        current_subject_name = ep_info.subject_name
        
        -- 2. 调用核心同步引擎
        execute_core_sync()
    end
    
    -- 调用您原有的异步查找函数，并将我们的新回调传给它
    find_episode_async(media_title, on_auto_sync_success)
end



-- 监听播放进度变化
-- 当进度超过 80% 时，自动标记为“看过”
function on_progress_change(name, value)
    -- value 是播放进度百分比 (0-100)
    -- 检查：同步是否开启？当前集是否还未被标记？进度是否达标？
    if is_sync_enabled and not is_current_ep_marked and value and value > 80 then
        
        -- 立即设置标志，防止因进度条抖动或重复触发而多次调用
        is_current_ep_marked = true 
        
        if not current_subject_id or not current_ep_id then
            send_message("警告: 进度达标但未获取番剧信息，无法自动标记")
            msg.warn("进度达标但 current_subject_id 或 current_ep_id 为空")
            return
        end

        send_message("进度超过 80%，自动标记本集为 [看过]...")
        msg.info("进度达标,标记本集为 [看过]...")

        -- "看过" 对应的 type 码是 2
        local success = update_episode_status(current_ep_id, 2)

        -- 【关键联动】如果标记成功，立即触发“检查整部剧是否完结”的逻辑
        if success then
            -- 延迟0.5秒执行
            mp.add_timeout(0.5, function()
                check_subject_all_watched(current_subject_id)
            end)
        end
    end
end


mp.observe_property("path", "string", on_path_change)
mp.observe_property("percent-pos", "number", on_progress_change)


-- 总开关，负责开启/关闭同步
mp.add_key_binding("ctrl+g", "master_toggle_sync", master_toggle_sync)

-- 手动同步的入口，现在有了前置检查
mp.add_key_binding("alt+g", "start_manual_sync", start_manual_sync)
