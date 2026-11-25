-- Window-only. The native process owns the input UI and the invite; this VM
-- only chooses a public source and receives a bounded, redacted receipt.
local M = {}
local PICK_MS, PREPARE_MS, IMPORT_MS = 300000, 320000, 300000
local MAX_RECEIPT = 4096
local failures = {
    ['unsupported-invite'] = '仅支持 Tern 配对邀请链接。',
    ['no-invite'] = '图片中没有找到 Tern 配对邀请。',
    ['invalid-image'] = '图片损坏或格式不支持，无法识别二维码。',
    ['no-clipboard-image'] = '剪贴板中没有可读取的图片。请先复制二维码图片或截图。',
    ['image-too-large'] = '图片过大，请裁剪二维码区域后再试。',
    ['delivery-failed'] = '无法将邀请交给本机 Tern。',
    ['import-failed'] = '无法完成导入，请检查本机插件运行时。',
    ['unsupported-platform'] = '仅支持 macOS 桌面 Tern。',
}
local function notify(cx, code)
    if not cx or code == 'cancelled' then return end
    if code == 'handed-off' then cx:toast('success', '已交给 Tern，请查看原生配对提示'); return end
    local message = failures[code] or (code == 'prepare-failed' and '未能准备已校验的本机运行时。' or '导入操作已超时，不会自动重试。')
    cx:toast('error', message, code)
end

local function receipt(status, value)
    if type(value) == 'table' then
        for k in pairs(value) do if k ~= 'ok' and k ~= 'code' then return 'import-failed' end end
        local code = value.code
        if status == 0 and value.ok == true and (code == 'handed-off' or code == 'cancelled') then return code end
        if type(status) == 'number' and status > 0 and value.ok == false and failures[code] then return code end
    end
    return 'import-failed'
end

function M.new(tern, platform)
    local active, unloaded
    -- Stage identity is also a single-use lease. Invalidate it before signalling
    -- the child: a queued exit/picker response can never dispatch the next stage.
    local function retire(stage, stop)
        if active ~= stage then return false end
        active = nil
        if stop and stage.child then pcall(stage.child.kill, stage.child, stage.signal) end
        if stage.timer then stage.timer:cancel() end
        return true
    end
    local function expire(stage, cx)
        if retire(stage, true) then notify(cx, 'timeout') end
    end
    local function begin(ms, cx, signal)
        local stage = { deadline = tern.now() + ms, signal = signal }
        active = stage
        local ok, timer = pcall(tern.timer, ms, function(fresh) expire(stage, fresh) end)
        if not ok then retire(stage, false); notify(cx, 'import-failed'); return nil end
        stage.timer = timer
        return stage
    end
    local function current(stage, cx)
        if active ~= stage then return false end
        if tern.now() >= stage.deadline then expire(stage, cx); return false end
        return true
    end
    local function pick(cx, title, items, selected)
        local stage = begin(PICK_MS, cx)
        if not stage then return end
        local ok = pcall(function()
            cx:pick({ placeholder = title, action = '选择', items = items }):next(function(answer, err, fresh)
                if not current(stage, fresh) then return end
                retire(stage, false)
                if err or not fresh then notify(fresh, 'import-failed'); return end
                if answer then selected(answer.value, fresh) end
            end)
        end)
        if not ok and retire(stage, false) then notify(cx, 'import-failed') end
    end
    local function spawn(cx, mode, args, complete)
        local prepare = mode == '--prepare'
        -- The bootstrap traps TERM during preparation to reap its downloader
        -- and remove partial files. --exec replaces itself with the native UI.
        local stage = begin(prepare and PREPARE_MS or IMPORT_MS, cx, prepare and 'terminate' or 'kill')
        if not stage then return end
        local chunks, size = {}, 0
        local ok = pcall(function()
            stage.child = tern.process.spawn(platform.bootstrap(mode, args), {
                split = 'chunks',
                stdout = function(chunk)
                    if active ~= stage or not chunks then return end
                    size += #chunk
                    if size > MAX_RECEIPT then chunks = nil else table.insert(chunks, chunk) end
                end,
                stderr = function() end, -- discard diagnostics, including the SDK's default stderr tail
                exit = function(result, fresh)
                    if not current(stage, fresh) then return end
                    retire(stage, false)
                    if not fresh then return end
                    local parsed, value = false, nil
                    if chunks then parsed, value = pcall(tern.json.decode, table.concat(chunks)) end
                    chunks = nil
                    complete(fresh, result and result.status, parsed and value or nil)
                end,
            })
            stage.child:close_stdin()
        end)
        if not ok and retire(stage, true) then notify(cx, prepare and 'prepare-failed' or 'import-failed') end
    end
    local function import(source, cx)
        spawn(cx, '--exec', { 'pair-import', source }, function(fresh, status, value)
            notify(fresh, receipt(status, value))
        end)
    end
    local function chooseSource(source, cx)
        if source ~= 'text' and source ~= 'image' and source ~= 'clipboard' then notify(cx, 'import-failed'); return end
        -- Existence is only a hint for offering preparation. --exec verifies the
        -- binary on every call and never repairs or downloads it implicitly.
        local ok, exists = pcall(tern.fs.exists, platform.binary)
        if not ok then notify(cx, 'import-failed'); return end
        if exists then import(source, cx); return end
        pick(cx, '首次导入需要下载并校验本机插件运行时', {
            { label = '取消', value = 'cancel' },
            { label = '下载、校验并继续', detail = '仅准备本机插件程序，不配置 SSH、Cloudflare 或 TURN。', value = 'prepare' },
        }, function(consent, fresh)
            if consent ~= 'prepare' then return end
            spawn(fresh, '--prepare', nil, function(currentCx, status, value)
                if status ~= 0 or not platform.ready(value) then notify(currentCx, 'prepare-failed'); return end
                import(source, currentCx)
            end)
        end)
    end
    return {
        open = function(cx)
            if unloaded then return end
            if active and current(active, cx) then cx:toast('info', '请先完成或取消当前导入。'); return end
            pick(cx, '连接另一台 Tern：选择邀请来源', {
                { label = '粘贴完整邀请链接', detail = '在本机原生窗口中粘贴。', value = 'text' },
                { label = '使用剪贴板中的二维码图片', detail = '仅读取这一次复制的图片，在本机识别。', value = 'clipboard' },
                { label = '选择二维码图片', detail = '在本机离线识别 PNG / JPEG。', value = 'image' },
            }, chooseSource)
        end,
        unload = function()
            unloaded = true
            if active then retire(active, true) end
        end,
    }
end
return M
