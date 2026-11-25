local suites = {
    require('./work_queue_spec'),
    require('./platform_spec'),
    require('./onboarding_spec'),
    require('./window_spec'),
    require('./pair_import_spec'),
}
local total = 0
for _, suite in ipairs(suites) do total += suite.run() end
print('Luau 行为测试通过：' .. tostring(total))
