# frozen_string_literal: true
$stdout.sync = true
$stderr.sync = true

# =============================================================================
# test/helper_sandbox_test.rb — E2E тест внешнего PowerShell-хелпера (v2).
#
#   ruby test/helper_sandbox_test.rb   (только Windows)
#
# В песочнице выполняет НАСТОЯЩИЙ su_profiles_helper.ps1: перенос содержимого
# Plugins в хранилище (реальные .rb + junction-папки), клоны с фильтром,
# переключение профилей (сохранение уходящего → очистка → наполнение → свап
# настроек). Ничего вне песочницы не трогает (wait_pid=0, strict_solo=false,
# relaunch=false).
# =============================================================================

require 'fileutils'
require 'tmpdir'
require 'json'

unless RUBY_PLATFORM =~ /mingw|mswin|cygwin/
  puts 'SKIP: тест только для Windows'
  exit 0
end

REPO = File.expand_path('..', __dir__)
HELPER = File.join(REPO, 'dn1sup_sketchup_profiles', 'helper', 'su_profiles_helper.ps1')

$failed = 0
def assert(label, cond, details = '')
  puts format('%s %s%s', cond ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}")
  $failed += 1 unless cond
end

def run_helper!(job_path)
  out = `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "#{HELPER}" -JobPath "#{job_path}" 2>&1`
  [out.force_encoding('UTF-8').scrub, $?.exitstatus.to_i]
end

Sandbox = Dir.mktmpdir('sp_helper_e2e')
AppdataRoam = File.join(Sandbox, 'Roaming')
AppdataLocal = File.join(Sandbox, 'Local')
Store = File.join(AppdataLocal, 'dn1sup_sketchup_profiles')
Year = '2026'
RealPlugins = File.join(AppdataRoam, 'SketchUp', "SketchUp #{Year}", 'SketchUp', 'Plugins')
PrefsRoam = File.join(AppdataRoam, 'SketchUp', "SketchUp #{Year}", 'SketchUp', 'SharedPreferences.json')
PrefsLoc = File.join(AppdataLocal, 'SketchUp', "SketchUp #{Year}", 'SketchUp', 'PrivatePreferences.json')

def junction_in_dir?(path)
  listing = `cmd.exe /c dir "#{File.dirname(path.tr('/', '\\'))}"`.to_s.force_encoding('UTF-8').scrub
  listing.lines.any? { |l| l.include?('JUNCTION') && l.include?(File.basename(path)) }
end

begin
  # --- исходные данные --------------------------------------------------------
  FileUtils.mkdir_p(RealPlugins)
  %w[dn1sup_ext_manager dn1sup_ext_manager_dev dn1sup_sketchup_profiles
     curic_select ladb_opencutlist].each do |id|
    File.write(File.join(RealPlugins, "#{id}.rb"), "# #{id}\nextension.version = '1.0.0'\n")
    FileUtils.mkdir_p(File.join(RealPlugins, id))
    File.write(File.join(RealPlugins, id, 'main.rb'), '# code')
  end
  File.write(File.join(RealPlugins, 'solo.rb'), '# одиночный скрипт')
  File.write(PrefsRoam, '{"template":"roam-main"}')
  FileUtils.mkdir_p(File.dirname(PrefsLoc))
  File.write(PrefsLoc, '{"ui":"layout-main"}')

  self_rb = File.join(RealPlugins, 'dn1sup_sketchup_profiles.rb')
  self_dir = File.join(RealPlugins, 'dn1sup_sketchup_profiles')

  FileUtils.mkdir_p(Store)
  profiles_path = File.join(Store, 'profiles.json')
  File.write(profiles_path, JSON.pretty_generate({
    'store_version' => 2,
    'profiles' => [
      { 'id' => 'main', 'name' => 'Основной', 'protected' => true, 'last_launch' => nil },
      { 'id' => 'dev', 'name' => 'Разработка', 'protected' => false, 'last_launch' => nil }
    ]
  }))

  live = Dir.children(RealPlugins).reject { |n| n.start_with?('.') }
  dev_excludes = live.reject { |n| n.start_with?('dn1sup_') }

  job = {
    'kind' => 'migrate', 'target_profile' => 'main',
    'created_at' => Time.now.to_i, 'wait_pid' => 0, 'wait_timeout_sec' => 30,
    'relaunch' => false, 'strict_solo' => false, 'su_exe' => '',
    'store_root' => Store,
    'state_path' => File.join(Store, 'state.json'),
    'profiles_path' => profiles_path,
    'year' => Year,
    'real_plugins' => RealPlugins,
    'prefs_roaming' => PrefsRoam,
    'prefs_local' => PrefsLoc,
    'store_main_plugins' => File.join(Store, 'profiles', 'main', 'Plugins'),
    'store_main_prefs' => File.join(Store, 'profiles', 'main', 'Prefs'),
    'create_profiles' => [
      {
        'id' => 'dev', 'name' => 'Разработка',
        'source' => File.join(Store, 'profiles', 'main', 'Plugins'),
        'target' => File.join(Store, 'profiles', 'dev', 'Plugins'),
        'exclude_names' => dev_excludes
      }
    ],
    'self' => { 'rb' => self_rb, 'dir' => self_dir,
                'rb_name' => 'dn1sup_sketchup_profiles.rb',
                'dir_name' => 'dn1sup_sketchup_profiles' }
  }
  job_path = File.join(Store, 'pending_job.json')
  File.write(job_path, JSON.generate(job))

  # --- миграция -----------------------------------------------------------------
  out, code = run_helper!(job_path)
  assert 'миграция завершена без ошибок', code.zero?, "exit=#{code} out=#{out[0, 500]}"

  main_store = job['store_main_plugins']
  assert 'хранилище main: полный набор', Dir.children(main_store).map(&:downcase).sort == live.map(&:downcase).sort
  assert 'реальный Plugins: .rb — реальные файлы (не junction)',
         File.file?(File.join(RealPlugins, 'dn1sup_ext_manager.rb')) &&
         !junction_in_dir?(File.join(RealPlugins, 'dn1sup_ext_manager.rb'))
  assert 'реальный Plugins: папка расширения — junction',
         junction_in_dir?(File.join(RealPlugins, 'dn1sup_ext_manager'))
  assert 'через junction читается содержимое расширения',
         File.file?(File.join(RealPlugins, 'dn1sup_ext_manager', 'main.rb'))
  assert 'Prefs main: оба файла',
         File.file?(File.join(job['store_main_prefs'], 'SharedPreferences.json')) &&
         File.file?(File.join(job['store_main_prefs'], 'PrivatePreferences.json'))

  dev_store = job['create_profiles'].first['target']
  assert 'dev-клон: только dn1sup_*',
         Dir.children(dev_store).all? { |n| n.start_with?('dn1sup_') } &&
         Dir.children(dev_store).include?('dn1sup_ext_manager')
  assert 'dev-клон: содержимое папок скопировано (не пустые)',
         File.file?(File.join(dev_store, 'dn1sup_ext_manager', 'main.rb'))
  assert 'dev-клон: менеджер самоинъектирован',
         File.file?(File.join(dev_store, 'dn1sup_sketchup_profiles.rb')) &&
         File.file?(File.join(dev_store, 'dn1sup_sketchup_profiles', 'main.rb'))
  assert 'dev-клон: Prefs унаследованы',
         File.file?(File.join(Store, 'profiles', 'dev', 'Prefs', 'SharedPreferences.json'))

  state = JSON.parse(File.read(File.join(Store, 'state.json'), encoding: 'UTF-8'))
  assert 'state: активен main, store_version 2',
         state['active_profile'] == 'main' && state['store_version'] == 2
  result = JSON.parse(File.read(File.join(Store, 'pending_job.result.json'), encoding: 'UTF-8'))
  assert 'result: ok, фазы',
         result['ok'] == true && result['phases'].include?('migrated') && result['phases'].include?('done'),
         result.inspect
  assert 'job-файл удалён', !File.exist?(job_path)

  # --- переключение на dev --------------------------------------------------------
  # сначала «поработали» в main: новый скрипт в реальном Plugins
  File.write(File.join(RealPlugins, 'zz_live_script.rb'), '# поставлен в main')
  File.write(PrefsLoc, '{"ui":"layout-main-CHANGED"}')

  # и висячий junction (цель удалена) — хелпер обязан его снять, иначе
  # очистка Plugins его пропустит и наполнение упадёт на New-Junction
  gone_dir = File.join(Sandbox, 'gone_target')
  FileUtils.mkdir_p(gone_dir)
  dang = File.join(RealPlugins, 'zz_dangling')
  system("cmd.exe /c mklink /J \"#{dang.tr('/', '\\')}\" \"#{gone_dir.tr('/', '\\')}\"") or raise 'mklink не сработал'
  FileUtils.remove_entry(gone_dir)
  raise 'висячий junction не создан' unless junction_in_dir?(dang) && !File.exist?(dang)

  job_switch = job.merge(
    'kind' => 'switch', 'from_profile' => 'main', 'target_profile' => 'dev',
    'store_from_plugins' => main_store,
    'store_from_prefs' => job['store_main_prefs'],
    'store_to_plugins' => dev_store,
    'store_to_prefs' => File.join(Store, 'profiles', 'dev', 'Prefs'),
    'create_profiles' => []
  )
  File.write(job_path, JSON.generate(job_switch))
  out2, code2 = run_helper!(job_path)
  assert 'свитч завершён без ошибок', code2.zero?, "exit=#{code2} out=#{out2[0, 500]}"

  real_now = Dir.children(RealPlugins).reject { |n| n.start_with?('.') }.map(&:downcase).sort
  assert 'реальный Plugins = набор dev',
         real_now == Dir.children(dev_store).reject { |n| n.start_with?('.') }.map(&:downcase).sort,
         "real=#{real_now.inspect}"
  assert 'сторонние расширения исчезли из реального Plugins',
         !File.exist?(File.join(RealPlugins, 'curic_select.rb')) &&
         !File.exist?(File.join(RealPlugins, 'solo.rb'))
  assert 'новый .rb сохранён в уходящий профиль main',
         File.file?(File.join(main_store, 'zz_live_script.rb'))
  assert 'изменённые настройки сохранены в Prefs main',
         File.read(File.join(job['store_main_prefs'], 'PrivatePreferences.json')).include?('CHANGED')
  assert 'настройки целевого профиля применены (layout-main)',
         File.read(PrefsLoc).include?('layout-main"') && !File.read(PrefsLoc).include?('CHANGED')
  assert 'висячий junction снят из реального Plugins',
         !junction_in_dir?(File.join(RealPlugins, 'zz_dangling')),
         junction_in_dir?(File.join(RealPlugins, 'zz_dangling')).inspect
  state2 = JSON.parse(File.read(File.join(Store, 'state.json'), encoding: 'UTF-8'))
  assert 'state: активен dev', state2['active_profile'] == 'dev'
  profiles = JSON.parse(File.read(profiles_path, encoding: 'UTF-8'))
  assert 'profiles.json: last_launch у dev',
         profiles['profiles'].find { |p| p['id'] == 'dev' }['last_launch'].to_i.positive?

  # --- ошибка: несуществующее хранилище цели --------------------------------------
  bad = job_switch.merge('store_to_plugins' => File.join(Store, 'nope'))
  File.write(job_path, JSON.generate(bad))
  _out3, code3 = run_helper!(job_path)
  result3 = JSON.parse(File.read(File.join(Store, 'pending_job.result.json'), encoding: 'UTF-8'))
  assert 'ошибка фиксируется в result.json', code3 != 0 && result3['ok'] == false && !result3['error'].to_s.empty?,
         "exit=#{code3} result=#{result3.inspect[0, 200]}"
  # --- Win.zip_extract: успех по exit-коду tar, а не по наличию папки -------------
  require_relative File.join(REPO, 'dn1sup_sketchup_profiles', 'win_helpers')
  w = Dn1sup::SketchupProfiles::Win
  zsrc = File.join(Sandbox, 'zip_src')
  FileUtils.mkdir_p(zsrc)
  File.write(File.join(zsrc, 'a.rb'), '# zip probe')
  good_zip = File.join(Sandbox, 'good.zip')
  bad_zip = File.join(Sandbox, 'bad.zip')
  File.write(bad_zip, 'NOT A ZIP AT ALL')
  d_ok = File.join(Sandbox, 'ex_ok')
  d_bad = File.join(Sandbox, 'ex_bad')
  assert 'zip_create: валидный архив создан', w.zip_create(good_zip, zsrc, ['a.rb']) && File.file?(good_zip)
  assert 'zip_extract: валидный распакован',
         w.zip_extract(good_zip, d_ok) && File.file?(File.join(d_ok, 'a.rb'))
  assert 'zip_extract: битый архив отклонён (exit-код tar)', !w.zip_extract(bad_zip, d_bad)

ensure
  FileUtils.remove_entry(Sandbox) if File.directory?(Sandbox)
end

puts "\n#{$failed.zero? ? 'ALL HELPER TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
