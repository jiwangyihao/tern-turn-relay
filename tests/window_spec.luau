local install = require('../window')
local cases = {}

local function fixture(os, configured, installed, kv)
    local f = { calls = {}, commands = {}, timers = {}, time = 0, mutations = 0, toasts = {}, details = '', hosts = {}, reads = {}, kv = kv or {}, widgets = {}, events = {}, sheets = {} }
    f.config = { schema = 4, ssh_destination = 'server', listen_port = 18377,
        target = { name = 'server', host = '203.0.113.1', user = 'user', port = 22, fingerprint = 'original-pin' },
        gateway = { fingerprint = 'relay-pin', daemon_socket = '/private/daemon.sock' } }
    function f:value(state, resume)
        return { ok = true, state = state, resume_mode = resume, mode = state == 'ready' and 'tls' or nil,
            bytes_up = 0, bytes_down = 0, flows = 0, ssh_connections = 0, queued_packets = 0, queued_bytes = 0,
            queue_dropped_packets = 0, queue_dropped_bytes = 0, congested = false,
            target = self.config.target, address = 'user@127.0.0.1:18377', ssh_destination = 'server',
            relay_fingerprint = 'relay-pin', daemon_socket = '/private/daemon.sock', route_policy = 'exclusive', service_id = 'service-1' }
    end
    local host = {
        runtime = { os = os },
        plugin = { data = os == 'windows' and 'C:/用户/data' or '/Users/用户/data', dir = os == 'windows' and 'C:/用户/plugin' or '/Users/用户/plugin' },
        getenv = function() return 'C:/Windows' end,
        now = function() return f.time end,
        timer = function(ms, callback)
            local timer = { callback = callback, due = f.time + ms, active = true }
            function timer:cancel() self.active = false end
            table.insert(f.timers, timer)
            return timer
        end,
        fs = {
            exists = function(path)
                if path:sub(-12) == '/config.json' then return configured end
                return installed == true
            end,
            read = function(path)
                table.insert(f.reads, path)
                if path:sub(-12) == '/config.json' then return 'config' end
                return 'stale-status'
            end,
        },
        json = { encode = function(value) return value end, decode = function(raw)
            if f.abortDecode then
                f.abortDecode = false
                coroutine.yield('host-budget-abort')
            end
            if raw == 'config' then return f.config end
            if raw == 'stale-status' then return f:value('ready') end
            return f.response
        end },
        process = { run = function(argv, options, callback) table.insert(f.calls, { argv = argv, options = options, callback = callback }) end },
        kv = { get = function(key) return f.kv[key] end, set = function(key, value) f.kv[key] = value end },
        on = function(name, handler) f.events[name] = handler end,
        css = function(name, source) f.sheets[name] = source end,
        command = function(command) f.commands[command.id] = command end,
        chrome = { refresh = function()
            if f.interruptRefresh then
                f.interruptRefresh = false
                error('simulated interrupted timer hook')
            end
        end, widget = function(id, spec) f.widgets[id] = spec end },
    }
    function f:view() return self.widgets.turn.render(nil) end
    function f:context()
        local function mutate() self.mutations += 1; error('不应修改 Host') end
        return {
            toast = function(_, _, title, detail) table.insert(self.toasts, title .. ' ' .. tostring(detail)) end,
            hosts = { list = function() return self.hosts end, current = function() return { kind = 'local', id = 'local' } end, add = mutate, disconnect = mutate, trust = mutate, switch = mutate },
            canvas = { list = function() return {} end, open = function(_, options) self.details = options.md; return 'pane' end },
        }
    end
    function f:tick()
        for _, timer in ipairs(self.timers) do
            if timer.active and timer.due <= self.time then
                timer.active = false
                if self.abortTimerHook then
                    self.abortTimerHook = false
                    local thread = coroutine.create(timer.callback)
                    local ok, reason = coroutine.resume(thread, self:context())
                    assert(ok and reason == 'host-budget-abort' and coroutine.status(thread) == 'suspended')
                    coroutine.close(thread)
                else
                    timer.callback(self:context())
                end
                return true
            end
        end
        return false
    end
    function f:flush()
        local count = 0
        while self:tick() do count += 1; assert(count < 100, '即时队列未收敛') end
    end
    function f:command(id)
        self.commands[id].run(self:context())
        assert(self:tick())
        self:flush()
    end
    function f:complete(value, status)
        self.response = value
        self.calls[#self.calls].callback({ stdout = '{}', status = status or 0 }, { expired = true })
        assert(self:tick())
        self:flush()
    end
    install(host)
    return f
end

function cases.loading_and_status_never_download()
    for _, os in ipairs({ 'windows', 'macos' }) do
        for _, configured in ipairs({ false, true }) do
            local f = fixture(os, configured)
            assert(#f.calls == 0)
            f:command('status')
            assert(#f.calls == 0 and f.mutations == 0)
        end
    end
end

function cases.unconfigured_load_never_runs_even_with_runtime_present()
    for _, os in ipairs({ 'windows', 'macos' }) do
        local f = fixture(os, false, true)
        f:flush()
        assert(#f.calls == 0 and f.mutations == 0)
        f:command('status'); f:command('convert-tls')
        assert(#f.calls == 0 and f.mutations == 0)
    end
end

function cases.unconfigured_connect_cannot_prepare_or_change_host()
    for _, id in ipairs({ 'convert-tls', 'convert-udp' }) do
        local f = fixture('windows', false)
        f:command(id)
        assert(#f.calls == 0 and f.mutations == 0)
    end
end

function cases.stop_preparation_failure_is_not_success()
    for _, os in ipairs({ 'windows', 'macos' }) do
        local f = fixture(os, true)
        f:command('disconnect')
        assert(#f.calls == 1 and f.calls[1].argv[#f.calls[1].argv] == '--prepare')
        f:complete({ ok = false }, 1)
        assert(#f.calls == 1 and f.mutations == 0 and f:view().tone == 'error')
        f:command('status')
        assert(#f.calls == 1 and f.mutations == 0)
        for _, toast in ipairs(f.toasts) do assert(not toast:find('TURN stopped for ALL', 1, true)) end
    end
end

function cases.stop_bad_runtime_identity_and_timeout_preserve_hosts()
    for _, scenario in ipairs({ 'path', 'timeout' }) do
        local f = fixture('windows', true)
        f:command('disconnect')
        if scenario == 'timeout' then
            f.time = 322001
            assert(f:tick())
        else
            f:complete({ ok = true, runtime_ready = true, version = '0.5.17', binary = 'C:/wrong.exe' })
        end
        assert(#f.calls == 1 and f.mutations == 0 and f:view().tone == 'error')
        f:command('status')
        assert(#f.calls == 1 and f.mutations == 0)
    end
end

function cases.successful_prepare_still_requires_real_stop_result()
    local f = fixture('windows', true)
    f:command('disconnect')
    f:complete({ ok = true, runtime_ready = true, version = '0.5.17', binary = 'C:/用户/data/native-runtime/0.5.17/tern-turn-relay.exe' })
    assert(#f.calls == 2 and f.calls[2].argv[10] == '--exec' and f.calls[2].argv[11] == 'relay' and f.calls[2].argv[12] == 'stop')
    assert(f.mutations == 0)
    f:complete({ ok = true, state = 'stopped' }) -- 缺失状态 schema，不能伪报成功。
    assert(f.mutations == 0)
    for _, toast in ipairs(f.toasts) do assert(not toast:find('TURN stopped for ALL', 1, true)) end
end

function cases.existing_runtime_is_never_execution_authority()
    for _, os in ipairs({ 'windows', 'macos' }) do
        local f = fixture(os, true, true)
        local argv = f.calls[1].argv
        local offset = os == 'windows' and 10 or 4
        assert(argv[offset] == '--exec' and argv[offset + 1] == 'relay' and argv[offset + 2] == 'status')
        f:complete({ ok = false, error = 'verification failed' }, 1)
        assert(f.mutations == 0 and f:view().tone == 'error')
        f:command('disconnect')
        assert(f.calls[2].argv[offset] == '--exec' and f.calls[2].argv[offset + 2] == 'stop')
        f:complete({ ok = false }, 1)
        assert(f.mutations == 0)
    end
end

function cases.startup_resume_requires_intent_matching_config_and_exact_host()
    for _, os in ipairs({ 'windows', 'macos' }) do
        for _, missing in ipairs({ 'none', 'intent', 'config', 'host', 'pin' }) do
            local f = fixture(os, true, true)
            f.hosts = { { kind = 'remote', id = 'relay', address = missing == 'host' and 'user@127.0.0.1:18378' or 'user@127.0.0.1:18377',
                state = 'disconnected', detail = { fingerprint = missing == 'pin' and 'wrong' or 'relay-pin' } } }
            local value = f:value('stopped', missing ~= 'intent' and 'tls' or nil)
            if missing == 'config' then value.ssh_destination = 'other-server' end
            f:complete(value)
            assert(#f.calls == (missing == 'none' and 2 or 1), missing)
            assert(f.mutations == 0)
            if missing == 'none' then
                local offset = os == 'windows' and 10 or 4
                assert(f.calls[2].argv[offset + 2] == 'resume')
                f:complete(f:value('ready'))
                assert(f.mutations == 0)
            end
        end
    end
end

function cases.periodic_status_is_live_deduplicated_and_failure_invalidates_ready()
    local f = fixture('windows', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } } }
    f:complete(f:value('ready'))
    f.time = 3000; f:flush()
    assert(#f.calls == 2 and f.calls[2].argv[12] == 'status')
    f:command('status'); f:command('status')
    assert(#f.calls == 2, '并发 Status 不得重复查询')
    f:complete({ ok = false, error = 'control unavailable' }, 1)
    assert(f:view().text:find('不可用') and not f:view().text:find('已连接'))
    assert(f.details:find('error', 1, true), '等待中的详情订阅应显示实时失败结果')
    assert(f.mutations == 0)
    for _, path in ipairs(f.reads) do assert(not path:find('status.json', 1, true)) end
    f:command('status'); f:complete(f:value('ready'))
    assert(f:view().text:find('已连接'))
end

function cases.disconnected_host_does_not_freeze_recovery_status()
    for _, os in ipairs({ 'macos', 'windows' }) do
        local f = fixture(os, true, true)
        f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377',
            state = 'disconnected', detail = { fingerprint = 'relay-pin' } } }
        local recovering = f:value('ready')
        recovering.recovering_flows = 1
        f:complete(recovering)
        assert(f:view().text:find('恢复中'))
        -- Native Tern reconnects independently; no plugin command wakes polling.
        f.hosts[1].state = 'connected'
        f.time = 3000; f:flush()
        assert(#f.calls == 2, '断开期间不能停止读取后台状态，否则恢复文字会永久冻结')
        f:complete(f:value('ready'))
        assert(f:view().text:find('已连接') and not f:view().text:find('恢复中'))
        assert(f.mutations == 0, '观察恢复不能修改原生 Host')
    end
end

function cases.interrupted_refresh_does_not_stop_future_status_observation()
    local f = fixture('macos', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377',
        state = 'connected', detail = { fingerprint = 'relay-pin' } } }
    f:complete(f:value('ready'))
    f.time = 3000; f:flush()
    f.interruptRefresh = true
    f:complete(f:value('ready'))
    f.time = 6000; f:flush()
    assert(#f.calls == 3, '刷新回调被中断后，下一次状态观察仍必须发生')
    local recovering = f:value('ready')
    recovering.recovering_flows = 1
    f:complete(recovering)
    assert(f:view().text:find('恢复中'), '中断后必须继续反映真实状态变化')
    f.time = 9000; f:flush()
    f:complete(f:value('ready'))
    assert(f:view().text:find('已连接') and not f:view().text:find('恢复中'))
    assert(f.mutations == 0)
end

function cases.live_status_timeout_discards_late_ready()
    local f = fixture('windows', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } } }
    f:complete(f:value('ready'))
    f.time = 3000; f:flush()
    local late = f.calls[2].callback
    f.time = 20001; f:flush()
    assert(f:view().text:find('不可用'))
    f.response = f:value('ready'); late({ stdout = '{}', status = 0 }, {})
    f:flush()
    assert(f:view().text:find('不可用') and f.mutations == 0)
end

function cases.failed_observation_recovers_without_user_command()
    for _, os in ipairs({ 'windows', 'macos' }) do
        for _, initiallyReady in ipairs({ false, true }) do
            local f = fixture(os, true, true)
            f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } } }
            if initiallyReady then
                f:complete(f:value('ready'))
                f.time = 3000; f:flush()
            end
            for _ = 1, 2 do
                f:complete({ ok = false, error = 'control unavailable' }, 1)
                assert(f:view().text:find('不可用'))
                local previous = #f.calls
                f.time += 3000; f:flush()
                assert(#f.calls == previous + 1, '状态查询失败后必须继续观察，不依赖手工 Status')
            end
            f:complete(f:value('ready'))
            assert(f:view().text:find('已连接') and not f:view().text:find('异常'))
            assert(f.mutations == 0, '查询恢复不能启动后台或修改 Host')
        end
    end
end

function cases.stop_generation_discards_previous_status()
    local f = fixture('windows', true, true)
    local late = f.calls[1].callback
    f:command('disconnect')
    assert(#f.calls == 2 and f.calls[2].argv[12] == 'stop')
    f:complete(f:value('stopped'))
    f.response = f:value('ready'); late({ stdout = '{}', status = 0 }, {})
    f:flush()
    assert(f:view().text:find('已停止') and f.mutations == 0)
end

function cases.aborted_status_delivery_expires_without_reload_or_user_command()
    local f = fixture('macos', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377',
        state = 'connected', detail = { fingerprint = 'relay-pin' } } }
    local recovering = f:value('ready')
    recovering.gateway_recovering = true
    f:complete(recovering)
    assert(f:view().text:find('恢复中'))
    f.time = 3000; f:flush()
    f.abortDecode = true
    f.abortTimerHook = true
    f:complete(f:value('ready'))
    for _ = 1, 8 do f.time += 3000; f:flush() end
    assert(#f.calls >= 3, '宿主中断结果交付后必须自动过期悬挂查询，不能永远冻结恢复状态')
    f:complete(f:value('ready'))
    assert(f:view().text:find('已连接') and not f:view().text:find('恢复中'))
    assert(f.mutations == 0, '恢复观察不能修改 Host 或重启后台')
end

function cases.clean_restore_revokes_auto_recovery_only_after_alias_detaches()
    for _, detachFails in ipairs({ false, true }) do
        local f = fixture('macos', true, true)
        local alias = { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } }
        f.hosts = { alias }
        local current = alias
        local base = f.context
        function f:context()
            local cx = base(self)
            cx.hosts = {
                list = function() return self.hosts end,
                current = function() return current end,
                add = function(_, address)
                    local host = { kind = 'remote', id = 'direct', address = address, state = 'connected', detail = { fingerprint = 'original-pin' } }
                    table.insert(self.hosts, host)
                    return { next = function(_, callback) callback(host, nil, cx) end }
                end,
                switch = function(_, id) for _, host in ipairs(self.hosts) do if host.id == id then current = host end end end,
                disconnect = function(_, id)
                    if detachFails then error('rejected') end
                    for index, host in ipairs(self.hosts) do if host.id == id then table.remove(self.hosts, index); break end end
                end,
                trust = function() error('restore must not trust') end,
            }
            return cx
        end
        f:complete(f:value('ready', 'tls'))
        local before = #f.calls
        f:command('restore-direct')
        assert(current.id == 'direct', 'restore must switch to the original direct Host')
        local released = false
        for index = before + 1, #f.calls do
            if f.calls[index].argv[6] == 'release' then released = true end
        end
        if detachFails then
            assert(not released, 'alias still attached: TURN stays the selected route')
        else
            assert(released and f.calls[#f.calls].argv[6] == 'release', 'clean restore must revoke auto-recovery')
            f:complete(f:value('ready'))
            assert(f:view().tone ~= 'error')
        end
    end
end

function cases.widget_graphs_tern_rtt_and_reconnects_only_a_host_tern_gave_up()
    assert(fixture('macos', false):view().command == 'plugin.tern-turn-relay.setup')
    local f = fixture('macos', true, true)
    local host = { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', rtt_ms = 300, detail = { fingerprint = 'relay-pin' } }
    f.hosts = { host }
    f:complete(f:value('ready', 'tls'))
    for _, ms in ipairs({ 1500, 450 }) do
        host.rtt_ms = ms
        f.time += 3000; f:flush()
        f:complete(f:value('ready', 'tls'))
    end
    local view = f:view()
    assert(#view.series == 3 and view.series[1] == 0.15 and view.series[2] == 0.75 and view.series[3] == 0.225,
        'RTT graph keeps samples oldest first, scaled to the peak rounded up to 1/2/5 (1500 → 2000)')
    assert(view.text == '450 ms', 'a connected bar shows only its latency')
    assert(view.title:find('中位 450 · 峰值 1500 ms', 1, true))
    assert(view.command == nil, 'a connected Host is never reconnected by a click')
    for _, case in ipairs({ { 'stalled', 'plugin.tern-turn-relay.reconnect' }, { 'reconnecting', nil } }) do
        host.state = case[1]; host.rtt_ms = nil
        f.time += 3000; f:flush()
        f:complete(f:value('ready', 'tls'))
        assert(f:view().command == case[2], case[1] .. ': a lost entry re-attaches on click, Tern\'s own reconnect is left alone')
        assert(not f:view().text:find(' ms', 1, true), 'no stale RTT while ' .. case[1])
    end
    host.state = 'stalled'
    f.time += 3000; f:flush()
    f:complete(f:value('ready', 'tls'))
    assert(f:view().text:find('卡住', 1, true) and f:view().tone == 'warn')
    host.state = 'failed'
    f.time += 3000; f:flush()
    f:complete(f:value('ready', 'tls'))
    assert(f:view().command == 'plugin.tern-turn-relay.reconnect', 'an entry Tern gave up on is re-attached')
    f.hosts = {}
    f.time += 3000; f:flush()
    f:complete(f:value('ready', 'tls'))
    assert(f:view().command == 'plugin.tern-turn-relay.convert-tls', 'a missing entry is added in the saved mode')
    assert(f.mutations == 0, 'nothing reconnects automatically within the grace periods')
end

function cases.card_sheet_styles_the_rows_it_describes()
    local f = fixture('macos', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', rtt_ms = 1200, detail = { fingerprint = 'relay-pin' } } }
    f:complete(f:value('ready', 'tls'))
    local sheet = f.sheets.card
    assert(sheet and sheet:find('.wgc-head::after { content: "已连接"', 1, true), 'the head pill names the phase')
    assert(sheet:find('radial-gradient(circle at 9px 50%, var(--warn)', 1, true), 'a slow connection tints the pill')
    assert(f:view().title:match('^1200: TLS · server\n'), 'the hero pairs the latency figure with mode and target')
    assert(sheet:find('.wgc-row:nth-child(2) { position: relative; padding-top: 62px', 1, true) and sheet:find('data:image/svg+xml', 1, true),
        'the graph row carries the chart')
    assert(sheet:find('.wgc-row:nth-child(2)::before { content: "2000 ms"', 1, true), 'the chart labels its rounded-up top')
    assert(f:view().tone == 'warn', 'a slow connection warns in the bar')
    f.time += 3000; f:flush()
    f:complete({ ok = false, error = 'control unavailable' }, 1)
    local problem
    local index = 0
    for line in (f:view().title .. '\n'):gmatch('(.-)\n') do
        index += 1
        if line:find('^异常: ') then problem = index end
    end
    assert(problem and f.sheets.card:find('.wgc-row:nth-child(' .. problem .. ') .wgc-v { color: var(--bad); }', 1, true),
        'the error value is red on its own row')
    assert(f:view().tone == 'error')
end

function cases.lost_poll_is_rearmed_by_window_events_and_budget_resume()
    for _, trigger in ipairs({ 'focus', 'budget' }) do
        local f = fixture('macos', true, true)
        f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } } }
        f:complete(f:value('ready'))
        for _, armed in ipairs(f.timers) do armed.active = false end
        f.time = 12000; f:flush()
        local before = #f.calls
        assert(before == 1, 'a poll that never fires stops observation')
        if trigger == 'focus' then
            f.events.focus({ pane = 1, tab = 1 }, f:context())
        else
            f.events.budget({ hook = 'timer', state = 'resumed' }, f:context())
        end
        f.time = 15000; f:flush()
        assert(#f.calls == before + 1, trigger .. ' must re-arm the overdue poll')
    end
end

function cases.rtt_history_survives_a_new_vm_and_expires()
    local now = os.time()
    local f = fixture('macos', true, true, { ['rtt-history'] = { { t = now - 1000, ms = 999 }, { t = now - 30, ms = 400 }, { t = now - 27, ms = 500 } } })
    local view = f:view()
    assert(view.series and #view.series == 2, 'recent history graphs at once; expired samples are dropped')
    assert(view.title:find('中位 400 · 峰值 500 ms', 1, true))
    local host = { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', rtt_ms = 350, detail = { fingerprint = 'relay-pin' } }
    f.hosts = { host }
    f:complete(f:value('ready'))
    for _ = 1, 9 do
        f.time += 3000; f:flush()
        f:complete(f:value('ready'))
    end
    local saved = f.kv['rtt-history']
    assert(saved and #saved == 12 and saved[#saved].ms == 350, 'ten new samples are saved for the next VM')
end

function cases.throughput_is_counter_delta_and_restarts_after_a_reset()
    local f = fixture('macos', true, true)
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', detail = { fingerprint = 'relay-pin' } } }
    local function poll(down, up)
        f.time += 3000; f:flush()
        local value = f:value('ready', 'tls')
        value.bytes_down, value.bytes_up = down, up
        f:complete(value)
    end
    f:complete(f:value('ready', 'tls'))
    assert(f.widgets.rate.render(nil).text == '↓— ↑—', 'one answer is only a baseline')
    poll(3 * 1024 * 1024, 3 * 1024)
    assert(f.widgets.rate.render(nil).text == '↓1.0M ↑1.0K')
    assert(f:view().title:find('\n吞吐: ↓1.0 MiB/s · ↑1.0 KiB/s\n', 1, true), 'the card shows the current rates')
    poll(1024, 0)
    assert(f.widgets.rate.render(nil).text == '↓— ↑—', 'a counter that went back is a new baseline, not a negative rate')
    poll(1024 + 3 * 512 * 1024, 0)
    assert(f.widgets.rate.render(nil).text == '↓512K ↑0B')
    assert(f:view().title:find('峰值 ↓1.0 MiB/s · ↑1.0 KiB/s', 1, true), 'the peak spans the whole history')
    assert(f.sheets.card:find('content: "1 MiB/s"', 1, true), 'the throughput chart tops at the rounded-up peak')
end

-- A working cx.hosts: disconnect removes, add appends (connected unless log.addState
-- says otherwise), switch moves the window. `current` is what the window shows.
local function liveHosts(f, current)
    local log = { disconnects = 0, adds = 0, switches = 0, addTimes = {} }
    local base = f.context
    function f:context()
        local cx = base(self)
        cx.hosts = {
            list = function() return self.hosts end,
            current = function() return current end,
            add = function(_, address)
                log.adds += 1
                table.insert(log.addTimes, self.time)
                local host = { kind = 'remote', id = 'relay-' .. log.adds, address = address,
                    state = log.addState or 'connected', detail = { fingerprint = 'relay-pin' } }
                table.insert(self.hosts, host)
                return { next = function(_, callback)
                    if host.state == 'connected' then callback(host, nil, cx) else callback(nil, 'failed', cx) end
                end }
            end,
            switch = function(_, id)
                log.switches += 1
                for _, host in ipairs(self.hosts) do if host.id == id then current = host end end
            end,
            disconnect = function(_, id)
                log.disconnects += 1
                for index, host in ipairs(self.hosts) do if host.id == id then table.remove(self.hosts, index); break end end
            end,
            trust = function() error('a pinned entry is never re-trusted') end,
        }
        return cx
    end
    return log
end

local function aliasHost(state)
    return { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = state, detail = { fingerprint = 'relay-pin' } }
end

-- One poll interval: answer the status query only when the plugin actually made one (a
-- reconnect retires the generation, so the next timer re-arms without querying).
local function poll(f, value)
    local before = #f.calls
    f.time += 3000; f:flush()
    if #f.calls > before then f:complete(value or f:value('ready', 'tls')) end
    f:flush()
end

function cases.stalled_entry_is_reattached_in_the_background_after_a_grace_period()
    local f = fixture('macos', true, true)
    local alias = aliasHost('connected')
    f.hosts = { alias }
    local log = liveHosts(f, { kind = 'local', id = 'local' })
    f:complete(f:value('ready', 'tls'))
    alias.state = 'stalled'
    poll(f)
    local stalledAt = f.time
    while f.time - stalledAt < 18000 do poll(f) end
    assert(log.disconnects == 0 and log.adds == 0, 'a stall shorter than 20 s is left to Tern')
    while log.adds == 0 and f.time - stalledAt < 30000 do poll(f) end
    assert(f.time - stalledAt >= 20000 and log.disconnects == 1 and log.adds == 1,
        'after 20 s the stalled entry is detached and the same address re-added')
    assert(log.switches == 0, 'a window showing another Host is not moved')
    assert(#f.hosts == 1 and f.hosts[1].address == 'user@127.0.0.1:18377' and f.hosts[1].state == 'connected')
    assert(f:view().text ~= '卡住')
end

function cases.connected_but_silent_session_is_reattached_and_its_window_follows()
    local f = fixture('macos', true, true)
    local alias = aliasHost('connected')
    f.hosts = { alias }
    local log = liveHosts(f, alias)
    local function silent()
        local value = f:value('ready', 'tls')
        value.flows, value.bytes_down = 1, 4096
        return value
    end
    f:complete(silent())
    while f.time < 27000 do poll(f, silent()) end
    assert(log.adds == 0, 'under 30 s of silence nothing happens')
    while log.adds == 0 and f.time < 40000 do poll(f, silent()) end
    assert(f.time >= 30000 and log.disconnects == 1 and log.adds == 1, '30 s without a downstream byte is a dead session')
    assert(log.switches == 1, 'the window that showed the entry shows it again')
end

function cases.removed_entry_is_left_alone_and_failing_reconnects_back_off()
    local f = fixture('macos', true, true)
    local log = liveHosts(f, { kind = 'local', id = 'local' })
    f:complete(f:value('ready', 'tls'))
    for _ = 1, 20 do poll(f) end
    assert(log.disconnects == 0 and log.adds == 0, 'an entry the user removed is never re-added')
    local g = fixture('macos', true, true)
    g.hosts = { aliasHost('failed') }
    local failing = liveHosts(g, { kind = 'local', id = 'local' })
    failing.addState = 'failed'
    g:complete(g:value('ready', 'tls'))
    while #failing.addTimes < 3 and g.time < 200000 do poll(g) end
    local at = failing.addTimes
    assert(#at == 3, 'retries keep going while the entry stays lost')
    assert(at[1] >= 5000 and at[2] - at[1] >= 30000 and at[2] - at[1] < 36000
        and at[3] - at[2] >= 60000 and at[3] - at[2] < 66000, 'retries wait 30 s, then 60 s: ' .. table.concat(at, ','))
end

function cases.multi_second_round_trips_are_stall_artifacts_not_samples()
    local now = os.time()
    local f = fixture('macos', true, true, { ['rtt-history'] = { { t = now - 20, ms = 55102 }, { t = now - 10, ms = 400 } } })
    assert(#f:view().series == 1, 'a saved 55 s round trip is dropped on load')
    f.hosts = { { kind = 'remote', id = 'relay', address = 'user@127.0.0.1:18377', state = 'connected', rtt_ms = 30000, detail = { fingerprint = 'relay-pin' } } }
    f:complete(f:value('ready', 'tls'))
    assert(#f:view().series == 1 and f:view().text == '已连接', 'a 30 s estimate is neither graphed nor shown')
end

function cases.relay_between_allocations_is_starting_not_unavailable()
    local f = fixture('macos', true, true)
    local value = f:value('ready', 'tls')
    value.ok, value.state = false, 'starting'
    f:complete(value)
    assert(f:view().text == '启动中' and f:view().tone ~= 'error', f:view().text)
end

return { run = function()
    local count = 0
    for name, test in pairs(cases) do
        local ok, err = pcall(test)
        assert(ok, name .. ': ' .. tostring(err))
        count += 1
    end
    return count
end }
