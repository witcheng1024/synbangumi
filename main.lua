-- synbangumi.lua

-- 引入工具
local mp = require 'mp'
local msg = require "mp.msg"
local utils = require 'mp.utils'
local options = require "mp.options"
input_available, input = pcall(require, "mp.input")


-- 引入我们下载的json库
local json = require 'bin/json'

-- 读取配置文件
local opts = {
    -- 默认值
    access_token = "CYgKuDwLb60j3489AOkXjOKJsP5i11Y3pBEcoMIQ"
}
options.read_options(opts, _, function() end)

local current_subject_id = nil
local current_ep_id = nil
local is_sync_enabled = false

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
function api_request(method, url, data)
    msg.info("发送 API 请求: " .. method .. " " .. url)
    
    local headers = {
        'Authorization: Bearer ' .. opts.access_token,
        'User-Agent: witcheng/mpv-sync-script', -- 推荐写一个User-Agent
        'Content-Type: application/json'
    }

    local args = { "curl", "-s", "-X", method }

    for _, h in ipairs(headers) do
        table.insert(args, "-H")
        table.insert(args, h)
    end
    
    table.insert(args, url)

    if data then
        table.insert(args, "-d")
        table.insert(args, json.encode(data)) -- 将 Lua table 转为 JSON 字符串
    end

    -- mp.commandv 会执行外部命令
    local res = mp.command_native({
        name = "subprocess",
        args = args,
        capture_stdout = true -- 捕获输出
    })

    if res.status ~= 0 then
        msg.error("API 请求失败: " .. (res.stderr or "未知错误"))
        return nil
    end
    
    msg.info("API 响应: " .. res.stdout)
    return json.decode(res.stdout) -- 将返回的 JSON 字符串转为 Lua table
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

----------------------------------

-- 解析媒体标题，返回番名和集数
-- function parse_title(title)
--     local name, episode
--     -- 匹配 [字幕组][番名][集数]
--     name, episode = title:match("%[([^]]+)%]%s*%[([^]]+)%]%s*%[?(%d+)")
--     if name and episode then return name, episode end

--     -- 匹配 番名 S2 - 集数
--     name, episode = title:match("^(.*)%s*[sS]%d%d?%s*[-_ ]%s*(%d+)")
--     if name and episode then return name, episode end
    
--     -- 匹配 番名 - 集数 或 番名 集数
--     name, episode = title:match("^(.*)[-_ ](%d+)")
--     if name and episode then return name:gsub("%s*$", ""), episode end -- 移除末尾空格

--     return nil, nil
-- end
local function parse_title(title)
    -- local dir = get_parent_dir(path)
    -- local filename = mp.get_property_native("filename/no-ext")
    -- local title = mp.get_property_native("media-title"):gsub("%.[^%.]+$", "")
    -- local thin_space = string.char(0xE2, 0x80, 0x89)
    -- local fname = filename
    -- if is_protocol(path) then
    --     title = url_decode(title)
    --     fname = title
    -- elseif #title < #filename then
    --     title = filename
    -- end
    -- title = title:gsub(thin_space, " ")
    -- title = format_filename(title)
    local name, season, episode = title:match("^(.-)%s*[sS](%d+)[eE](%d+)")

    -- if not season then
    --     local media_title, episode = title:match("^(.-)%s*[eE](%d+)")
    --     if episode and dir then
    --         local season = dir:match("[sS](%d+)") or dir:match("[sS]eason%s*(%d+)")
    --             or dir:match("(%d+)[nrdsth]+[_%.%s]%s*[sS]eason")
    --         if season then
    --             title = media_title .. " S" .. season .. "E" .. episode
    --         else
    --             title = media_title .. " S01" .. "E" .. episode
    --         end
    --     end
    -- end
    -- if not dir then
    --     if season then
    --         dir = title .. " S" .. season
    --     else
    --         dir = title
    --     end
    -- end
    -- return dir, fname, title

    if name and episode then return name, episode end

    -- 匹配 番名 S2 - 集数
    name, episode = title:match("^(.*)%s*[sS]%d%d?%s*[-_ ]%s*(%d+)")
    if name and episode then return name, episode end
    
    -- 匹配 番名 - 集数 或 番名 集数
    name, episode = title:match("^(.*)[-_ ](%d+)")
    if name and episode then return name:gsub("%s*$", ""), episode end -- 移除末尾空格

    return nil, nil
end


-- 异步查找剧集，防止播放器卡顿
function find_episode_async(media_title)
    mp.add_timeout(0, function()
        local anime_name, ep_number = parse_title(media_title)
        if not anime_name or not ep_number then
            msg.warn("无法从标题解析番名和集数: " .. media_title)
            return
        end
        
        mp.osd_message("正在搜索: " .. anime_name .. " 第 " .. ep_number .. " 集")
        msg.info("正在搜索: " .. anime_name .. " 第 " .. ep_number .. " 集")

        -- 1. 搜索条目
        local search_url = "https://api.bgm.tv/search/subject/" .. url_encode(anime_name) .. "?type=2" -- type=2 表示动画
        msg.info("搜索 URL: " .. search_url)

        local search_result = api_request("GET", search_url)


       if not search_result or not search_result.list or #search_result.list == 0 then
            mp.osd_message("搜索失败，未找到番剧: " .. anime_name)
            return
        end
        
        -- 简单起见，我们先取第一个结果
        local subject = search_result.list[1]
        current_subject_id = subject.id
        msg.info("找到条目: " .. subject.name_cn .. " (ID: " .. current_subject_id .. ")")

        -- 2. 获取章节列表 (这步也可以省略，因为更新进度API不需要章节列表)
        -- 直接在后续操作中使用 ep_number
        -- 这里只为了确认章节存在

        local subject_detail_url = "https://api.bgm.tv/v0/episodes?subject_id=" .. current_subject_id

        local ep_list_result = api_request("GET", subject_detail_url)
        
        local found_ep = nil

        if ep_list_result and ep_list_result.data then
            for _, ep in ipairs(ep_list_result.data) do
                -- 【关键修改】
                -- 1. 确保匹配的是本篇 (type == 0)
                -- 2. 使用 ep.sort 来匹配集数
                if ep.type == 0 and ep.sort == tonumber(ep_number) then
                    found_ep = ep
                    break -- 找到就跳出循环
                end
            end
        end

        if found_ep then
            -- 现在 found_ep 是一个包含完整信息的 table
            current_ep_id = found_ep.id -- 我们成功获取到了章节ID！
            -- 还可以优化提示信息，显示中文标题
            mp.osd_message("匹配成功: " .. subject.name_cn .. " - " .. (found_ep.name_cn or found_ep.name))
        else
            mp.osd_message("找到番剧但未匹配到第 " .. ep_number .. " 集")
            current_subject_id = nil -- 匹配失败，重置
        end
    end)
end

function on_file_load()
    -- 重置状态,当视频文件加载时，触发查找函数。后面再修改
    current_subject_id = nil
    current_ep_id = nil
    is_sync_enabled = false
    is_marked_as_watched = false

    local media_title = mp.get_property("media-title")
    find_episode_async(media_title)
end

mp.register_event("file-loaded", on_file_load)




---- 实现同步逻辑 -----
-- status_type: "do" (在看), "collect" (看过)
function update_progress(subject_id, ep_number, status_type)
    if not subject_id or not ep_number then
        msg.error("缺少 subject_id 或 ep_number")
        return
    end

    -- Bangumi 新版 API 推荐使用这个来更新单集收视进度
    -- PATCH /v0/users/-/collections/{subject_id}/ep/{ep_id}
    -- 但这需要 ep_id，如果只有 ep_number，可以使用旧的 API
    -- POST /ep/{ep_id}/status/{status}
    -- 这里我们用一个更通用的 API，它同时更新总收藏和单集进度
    
    -- 更新总收藏状态为“在看”
    api_request("POST", "https://api.bgm.tv/collection/"..subject_id.."/update", {status = "do"})

    -- 更新单集进度
    -- 注意：这个 API 更新的是 “看到第几集”，而不是单集状态
    api_request("POST", "https://api.bgm.tv/subject/"..subject_id.."/update/watched_eps", "ep=" .. ep_number)
    
    -- 如果要精确标记单集状态为“看过”，需要ep_id
    if status_type == "collect" and current_ep_id then
        api_request("POST", "https://api.bgm.tv/ep/"..current_ep_id.."/status/watched")
        mp.osd_message("已标记为 [看过]")
    elseif status_type == "do" then
        mp.osd_message("已标记为 [在看]")
    end
end

-------- 使用快捷键切换同步状态  --------
-- 这里我们使用 "r" 键来切换同步状态
local is_marked_as_watched = false -- 防止重复标记

function toggle_sync()
    if not current_subject_id then
        mp.osd_message("未匹配到番剧，无法同步")
        return
    end

    is_sync_enabled = not is_sync_enabled

    if is_sync_enabled then
        mp.osd_message("同步已开启")
        -- 开启同步时，标记为“在看”
        local _, ep_number = parse_title(mp.get_property("media-title"))
        update_progress(current_subject_id, ep_number, "do")
        is_marked_as_watched = false -- 重置标记状态
    else
        mp.osd_message("同步已关闭")
    end
end

mp.add_key_binding("ctrl+g", "toggle-sync", toggle_sync)

-- 监听播放进度变化
-- 当进度超过 80% 时，自动标记为“看过”
function on_progress_change(name, value)
    -- value 是播放进度百分比 (0-100)
    if is_sync_enabled and not is_marked_as_watched and value > 80 then
        mp.osd_message("进度超过 80%，自动标记为看过...")
        local _, ep_number = parse_title(mp.get_property("media-title"))
        update_progress(current_subject_id, ep_number, "collect")
        is_marked_as_watched = true -- 标记完成，避免重复调用
    end
end

mp.observe_property("percent-pos", "number", on_progress_change)










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