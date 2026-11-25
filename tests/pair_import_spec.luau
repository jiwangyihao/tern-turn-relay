local install = require('../window')
local platform = require('../platform')
local cases = {}

-- Drive the installed window through the SDK: a remote-focused pane, no TURN
-- configuration, a local process table, and independently deliverable callbacks.
local function window(osName, installed)
    local f = { commands = {}, events = {}, picks = {}, children = {}, timers = {}, toasts = {}, time = 0, replies = {}, writes = {} }
    local plugin = { data = '/Users/test/Private Data', dir = '/Users/test/Plugin Files' }
    local runtime = { os = osName }
    local binary = platform.new(runtime, plugin).binary
    local cx = {
        hosts = { current = function() return { id = 'remote-session', kind = 'remote' } end },
        canvas = { list = function() return {} end, open = function(_, page) f.page = page; return 1 end },
        toast = function(_, level, title, detail) table.insert(f.toasts, { level, title, detail }) end,
        pick = function(_, opts)
            local picker = { items = opts.items }
            table.insert(f.picks, picker)
            function picker:next(callback) self.reply = callback end
            return picker
        end,
    }
    f.cx = cx
    function f:flush()
        for _, t in ipairs(self.timers) do
            if not t.cancelled and t.due <= self.time then t:cancel(); t.fn(cx) end
        end
    end
    function f:command(id) self.commands[id].run(cx); self:flush() end
    function f:choose(value, picker)
        picker = picker or self.picks[#self.picks]
        for _, item in ipairs(picker.items) do
            if item.value == value then picker.reply(item, nil, cx); self:flush(); return end
        end
        error('missing choice: ' .. value)
    end
    function f:receipt(child, ok, code, status, extra)
        local raw = 'result-' .. code
        self.replies[raw] = { ok = ok, code = code, extra = extra }
        child.opts.stdout(raw, cx); child.opts.exit({ status = status }, cx); self:flush()
    end
    f.replies.runtime = { ok = true, version = platform.version, runtime_ready = true, binary = binary }
    install({
        plugin = plugin, runtime = runtime, chrome = { refresh = function() end },
        command = function(c) f.commands[c.id] = c end,
        on = function(event, handler) f.events[event] = handler end,
        kv = { get = function() return nil end, set = function(k, v) f.writes[k] = v end },
        fs = { exists = function(path) return path == binary and installed end },
        now = function() return f.time end,
        timer = function(ms, fn)
            local timer = { due = f.time + ms, fn = fn, cancel = function(self) self.cancelled = true end }
            table.insert(f.timers, timer); return timer
        end,
        json = { decode = function(raw) return assert(f.replies[raw], 'invalid JSON') end },
        process = {
            run = function(argv, opts) table.insert(f.children, { argv = argv, opts = opts }) end,
            spawn = function(argv, opts)
                if f.missing then error('unavailable executable') end
                local child = { argv = argv, opts = opts }
                function child:close_stdin() self.stdinClosed = true end
                function child:kill(signal) self.signal = signal or 'terminate' end
                table.insert(f.children, child)
                return child
            end,
        },
    })
    return f
end

local function button(node)
    if node.k == 'button' and node.p.text == '连接另一台 Tern…' then return node.p end
    for _, child in ipairs(node.c or {}) do
        local found = button(child)
        if found then return found end
    end
    return nil
end

function cases.unconfigured_remote_window_has_a_working_local_button_and_command()
    local f = window('macos', true)
    assert(#f.picks == 0 and #f.children == 0)
    f:command('status')
    local header = f.page.view.c[1]
    local b = assert(button(header), 'expected a pairing button in the unconfigured header')
    local click = { owner = 'tern-turn-relay', about = f.page.about, pane = 1, node = b.key, act = b.actions.click }
    assert(f.events.canvas_action(click, f.cx) == true); f:flush()
    f:command('pair-import') -- same request even across entry points
    assert(#f.picks == 1 and #f.children == 0)
    local first = f.picks[1]
    f:choose('text', first)
    f:choose('image', first) -- stale second answer cannot change source
    f.events.canvas_action(click, f.cx); f:flush()
    assert(#f.children == 1 and #f.picks == 1)
    local c = f.children[1]
    assert(c.stdinClosed and table.concat(c.argv, '|') == '/bin/sh|/Users/test/Plugin Files/bootstrap-runtime.sh|/Users/test/Private Data|--exec|pair-import|text')
    f:receipt(c, true, 'handed-off', 0)
    assert(f.toasts[#f.toasts][1] == 'success' and next(f.writes) == nil)
    f:command('pair-import'); f:choose('image')
    assert(f.children[2].argv[6] == 'image')
end

function cases.clipboard_image_requires_explicit_selection_and_never_falls_back_to_text()
    local f = window('macos', true)
    f:command('pair-import')
    assert(#f.children == 0)
    f.picks[1].reply(nil, nil, f.cx); f:flush()
    assert(#f.children == 0)
    f:command('pair-import'); f:choose('clipboard')
    local child = assert(f.children[1])
    assert(child.stdinClosed and child.argv[5] == 'pair-import' and child.argv[6] == 'clipboard')
    f:receipt(child, false, 'no-clipboard-image', 1)
    assert(f.toasts[#f.toasts][3] == 'no-clipboard-image' and #f.children == 1 and next(f.writes) == nil)
end

function cases.only_macos_offers_pairing()
    for _, osName in ipairs({ 'linux', 'windows', 'ios' }) do
        local f = window(osName, true)
        assert(f.commands['pair-import'] == nil)
        f:command('status')
        assert(not button(f.page.view) and #f.children == 0 and #f.picks == 0)
    end
end

function cases.no_preparation_without_explicit_consent()
    local f = window('macos', false)
    f:flush()
    assert(#f.children == 0 and #f.picks == 0)
    f:command('pair-import')
    f.picks[1].reply(nil, nil, f.cx); f:flush()
    f:choose('image', f.picks[1])
    assert(#f.children == 0 and #f.picks == 1)
    f:command('pair-import'); f:choose('image'); f:choose('cancel')
    f:choose('prepare', f.picks[3])
    assert(#f.children == 0)
    f:command('pair-import')
    f.picks[#f.picks].reply({ value = 'not-a-public-source' }, nil, f.cx); f:flush()
    assert(#f.children == 0 and #f.picks == 4)
end

local function preparing()
    local f = window('macos', false)
    f:command('pair-import'); f:choose('image'); f:choose('prepare')
    local c = assert(f.children[1])
    assert(c.stdinClosed and table.concat(c.argv, '|') == '/bin/sh|/Users/test/Plugin Files/bootstrap-runtime.sh|/Users/test/Private Data|--prepare')
    return f, c
end

function cases.only_verified_preparation_continues_once()
    for _, fault in ipairs({ 'version', 'binary', 'runtime_ready', 'ok', 'exit', 'clean' }) do
        local f, prep = preparing()
        local status = fault == 'exit' and 1 or 0
        if fault ~= 'exit' and fault ~= 'clean' then f.replies.runtime[fault] = false end
        f:command('pair-import')
        prep.opts.stdout('run', f.cx); prep.opts.stdout('time', f.cx)
        prep.opts.exit({ status = status }, f.cx); f:flush()
        prep.opts.exit({ status = 0 }, f.cx); f:flush()
        if fault == 'clean' then
            local c = assert(f.children[2])
            assert(#f.children == 2 and c.stdinClosed and c.argv[4] == '--exec' and c.argv[5] == 'pair-import' and c.argv[6] == 'image')
            local before = #f.toasts
            f:receipt(c, true, 'cancelled', 0)
            f:receipt(c, true, 'handed-off', 0)
            assert(#f.toasts == before)
        else
            assert(#f.children == 1 and f.toasts[#f.toasts][3] == 'prepare-failed')
        end
    end
end

function cases.picker_and_child_leases_expire_even_when_a_timer_is_delayed()
    local f = window('macos', false)
    f:command('pair-import')
    f.time += 600000
    f:choose('text') -- deliver the click before the overdue timer hook
    assert(#f.children == 0 and #f.picks == 1)
    f:command('pair-import'); f:choose('text')
    f.time += 600000
    f:choose('prepare')
    assert(#f.children == 0)

    local g, prep = preparing()
    g.time += 600000
    g:flush()
    assert(prep.signal == 'terminate', 'let bootstrap clean up its in-flight download')
    prep.opts.stdout('runtime', g.cx)
    prep.opts.exit({ status = 0 }, g.cx); g:flush()
    assert(prep.signal and #g.children == 1 and g.toasts[#g.toasts][3] == 'timeout')
    g:command('pair-import'); g:choose('image'); g:choose('prepare')
    prep.opts.exit({ status = 0 }, g.cx); g:flush()
    assert(#g.children == 2 and g.children[2].argv[4] == '--prepare' and not g.children[2].signal)

    local h = window('macos', true)
    h:command('pair-import'); h:choose('text')
    local old = h.children[1]
    h.time += 600000; h:flush()
    assert(old.signal and h.toasts[#h.toasts][3] == 'timeout')
    h:command('pair-import'); h:choose('image')
    local before = #h.toasts
    h:receipt(old, true, 'handed-off', 0)
    assert(#h.children == 2 and not h.children[2].signal and #h.toasts == before)
    h:receipt(h.children[2], true, 'handed-off', 0)
    assert(h.toasts[#h.toasts][1] == 'success')
end

function cases.unload_stops_only_this_windows_worker_and_disarms_all_callbacks()
    local other = window('macos', true)
    other:command('pair-import'); other:choose('text')
    for _, phase in ipairs({ 'source', 'consent', 'prepare', 'import' }) do
        local f = window('macos', phase == 'import')
        f:command('pair-import')
        if phase ~= 'source' then f:choose('image') end
        if phase == 'prepare' then f:choose('prepare') end
        local before = #f.children
        f.events.unload(f.cx)
        if phase == 'source' then f:choose('text')
        elseif phase == 'consent' then f:choose('prepare')
        else
            local c = f.children[1]
            assert(c.signal)
            c.opts.stdout('runtime', f.cx); c.opts.exit({ status = 0 }, f.cx)
        end
        f.time += 600000; f:flush()
        assert(#f.children == before and #f.toasts == 0 and not other.children[1].signal)
    end
    other:receipt(other.children[1], true, 'handed-off', 0)
    assert(other.toasts[#other.toasts][1] == 'success')
end

function cases.reports_only_allowlisted_failures_without_secret_echo_or_retry()
    local f = window('macos', true)
    local canary = 'SYNTHETIC-PRIVATE-FIELD'
    for _, case in ipairs({
        { false, 'delivery-failed', 2, 'delivery-failed' },
        { false, 'unsupported-invite', 2, 'unsupported-invite' },
        { false, 'no-invite', 2, 'no-invite' },
        { false, 'invalid-image', 2, 'invalid-image' },
        { false, 'image-too-large', 2, 'image-too-large' },
        { false, 'unsupported-platform', 2, 'unsupported-platform' },
        { true, 'handed-off', 1 }, { false, 'handed-off', 0 },
        { false, 'delivery-failed', 0 }, { true, 'delivery-failed', 1 },
        { true, 'cancelled', 1 }, { false, 'cancelled', 0 },
        { false, 'delivery-failed', -1 }, { false, canary, 2 },
        { true, 'handed-off', 0, 'import-failed', canary },
    }) do
        f:command('pair-import'); f:choose('image')
        local n = #f.children
        local child = f.children[n]
        child.opts.stderr(canary, f.cx)
        f:receipt(child, case[1], case[2], case[3], case[5])
        f.time += 600000; f:flush()
        local last = f.toasts[#f.toasts]
        assert(last[1] == 'error' and last[3] == (case[4] or 'import-failed') and #f.children == n)
        assert(not table.concat(last, '|'):find(canary, 1, true))
    end
    for _, raw in ipairs({ canary, string.rep('x', 16384) }) do
        f:command('pair-import'); f:choose('text')
        local c = f.children[#f.children]
        c.opts.stdout(raw, f.cx); c.opts.stderr(canary, f.cx)
        c.opts.exit({ status = 0, stderr = canary }, f.cx); f:flush()
        local last = f.toasts[#f.toasts]
        assert(last[1] == 'error' and last[3] == 'import-failed' and not table.concat(last, '|'):find(canary, 1, true))
    end
    f.missing = true
    f:command('pair-import'); f:choose('text')
    assert(f.toasts[#f.toasts][3] == 'import-failed' and next(f.writes) == nil)
    f.missing = false
    f:command('pair-import'); f:choose('text')
    f:receipt(f.children[#f.children], true, 'handed-off', 0)
    assert(f.toasts[#f.toasts][1] == 'success')
end

return { run = function()
    local count = 0
    for name, test in pairs(cases) do
        local ok, err = pcall(test); assert(ok, name .. ': ' .. tostring(err)); count += 1
    end
    return count
end }
