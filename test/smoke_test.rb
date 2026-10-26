$stdout.sync = true
$stderr.sync = true

# =============================================================================
# test/smoke_test.rb — тесты ядра dn1sup_sketchup_profiles (v2) в песочнице.
#
# Схема v2: реальный Plugins (реальные .rb + junction-папки на хранилище
# профиля), Prefs-снимок настроек, переключение заменой содержимого Plugins.
# Работает и в CI: junction-примитивы подменяются фейками (реальные проверяют
# test/probe_win.rb и test/helper_sandbox_test.rb на Windows).
#
#   ruby test/smoke_test.rb
# =============================================================================

require 'fileutils'
require 'tmpdir'
require 'zlib'
require 'json'

REPO = File.expand_path('..', __dir__)
PLUGIN_DIR = File.join(REPO, 'dn1sup_sketchup_profiles')

$failed = 0
def assert(label, cond, details = '')
  passed = !!cond
  puts format('%s %s%s', passed ? 'PASS' : 'FAIL', label, details.to_s.empty? ? '' : " — #{details}")
  $failed += 1 unless passed
end

# ---- мини-ZIP (STORE, как tools/pack.rb) --------------------------------------

module MiniZip
  module_function

  def dos_parts(t)
    [(t.year - 1980) << 9 | t.month << 5 | t.day, t.hour << 11 | t.min << 5 | t.sec / 2]
  end

  def write(path, entries)
    date, time = dos_parts(Time.now)
    body = +''.b
    central = +''.b
    entries.each do |name, data|
      name_b = name.dup.force_encoding(Encoding::BINARY)
      data_b = data.b
      offset = body.bytesize
      crc = Zlib.crc32(data_b)
      body << [0x04034b50, 20, 0, 0, time, date, crc, data_b.bytesize, data_b.bytesize,
               name_b.bytesize, 0].pack('VvvvvvVVVvv') << name_b << data_b
      central << [0x02014b50, 20, 20, 0, 0, time, date, crc, data_b.bytesize, data_b.bytesize,
                  name_b.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVVvvvvvVV') << name_b
    end
    eocd = [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize,
            body.bytesize, 0].pack('VvvvvVVv')
    File.binwrite(path, body << central << eocd)
  end

  def read(path)
    buf = File.binread(path)
    eocd = buf.rindex([0x06054b50].pack('V'))
    raise 'нет EOCD' unless eocd

    count = buf[eocd + 10, 2].unpack1('v')
    pos = buf[eocd + 16, 4].unpack1('V')
    entries = {}
    count.times do
      raise 'битый central' unless buf[pos, 4] == [0x02014b50].pack('V')

      nlen, elen, clen = buf[pos + 28, 6].unpack('vvv')
      lho = buf[pos + 42, 4].unpack1('V')
      name = buf[pos + 46, nlen]
      lnlen, lelen = buf[lho + 26, 4].unpack('vv')
      csize = buf[pos + 20, 4].unpack1('V')
      entries[name.force_encoding('UTF-8')] = buf[lho + 30 + lnlen + lelen, csize]
      pos += 46 + nlen + elen + clen
    end
    entries
  end
end

# ---- песочница -----------------------------------------------------------------

SANDBOX = Dir.mktmpdir('sp_smoke')
APPDATA   = File.join(SANDBOX, 'Roaming')
LOCALAPP  = File.join(SANDBOX, 'Local')
ENV['DN1SUP_PROFILES_YEAR'] = '2026'
REAL_PLUGINS = File.join(APPDATA, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'Plugins')
PREFS_ROAM = File.join(APPDATA, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'SharedPreferences.json')
PREFS_LOC  = File.join(LOCALAPP, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'PrivatePreferences.json')

def build_sandbox_data!
  FileUtils.mkdir_p(REAL_PLUGINS)
  [['dn1sup_ext_manager', 'DN1Sup Extension Store', '0.11.2'],
   ['dn1sup_sketchup_profiles', 'DN1Sup SketchUp Profiles', '0.1.0']].each do |id, name, ver|
    File.write(File.join(REAL_PLUGINS, "#{id}.rb"),
               "# loader\nextension = SketchupExtension.new('#{name}', 'x')\nextension.version = '#{ver}'\n")
    FileUtils.mkdir_p(File.join(REAL_PLUGINS, id))
    File.write(File.join(REAL_PLUGINS, id, 'main.rb'), '# code')
    if id == 'dn1sup_sketchup_profiles'
      File.write(File.join(REAL_PLUGINS, id, 'profile_core.rb'), '# core')
      FileUtils.mkdir_p(File.join(REAL_PLUGINS, id, 'helper'))
      File.write(File.join(REAL_PLUGINS, id, 'helper', 'su_profiles_helper.ps1'), '# helper')
    end
  end
  %w[curic_deep_select ladb_opencutlist s4u_weld].each do |id|
    File.write(File.join(REAL_PLUGINS, "#{id}.rb"), "# #{id}\n")
    FileUtils.mkdir_p(File.join(REAL_PLUGINS, id))
    File.write(File.join(REAL_PLUGINS, id, 'main.rb'), '# code')
  end
  File.write(File.join(REAL_PLUGINS, 'fillet.rb'), '## single script')
  File.write(File.join(REAL_PLUGINS, 'extension_manifest.txt'), 'manifest junk')
  File.write(PREFS_ROAM, '{"template":"roam"}')
  FileUtils.mkdir_p(File.dirname(PREFS_LOC))
  File.write(PREFS_LOC, '{"ui":"layout-roam"}')
end
build_sandbox_data!

# ---- загрузка ядра с подменой путей ----------------------------------------------

require_relative '../dn1sup_sketchup_profiles/profile_core'

Core = Dn1sup::SketchupProfiles
Win  = Dn1sup::SketchupProfiles::Win

Core.define_singleton_method(:env_appdata) { APPDATA }
Core.define_singleton_method(:env_localappdata) { LOCALAPP }
Core.plugins_root_of_current_session = REAL_PLUGINS

# ---- подмены Windows-примитивов -----------------------------------------------------

# Фейк junction-а: реестр точек; create делает symlink (Linux/DevMode) или маркер.
FAKE_JUNCTIONS = {}
norm = ->(p) { p.to_s.tr('\\', '/').downcase.sub(%r{/+\z}, '') }

Win.define_singleton_method(:junction?) { |p| FAKE_JUNCTIONS.key?(norm.call(p)) }
Win.define_singleton_method(:junction_target) { |p| FAKE_JUNCTIONS[norm.call(p)] }
Win.define_singleton_method(:create_junction) do |point, target|
  raise "уже существует: #{point}" if File.exist?(point)

  FAKE_JUNCTIONS[norm.call(point)] = target
  begin
    File.symlink(target, point)
  rescue StandardError
    Dir.mkdir(point) # маркер: чтение «через junction» проверяется только на Windows
  end
  true
end
Win.define_singleton_method(:remove_junction) do |p|
  FAKE_JUNCTIONS.delete(norm.call(p))
  if File.symlink?(p)
    File.unlink(p)
  elsif File.directory?(p)
    Dir.rmdir(p)
  end
  true
end

# Предполётный strict_solo: по умолчанию чужих SketchUp нет.
Win.define_singleton_method(:sketchup_pids) { [] }

Win.define_singleton_method(:robocopy) do |src, dst, exclude_names: []|
  next false unless File.directory?(src.to_s)

  ex = Array(exclude_names).map(&:to_s)
  copy_rec = lambda do |s, d|
    FileUtils.mkdir_p(d)
    Dir.children(s).each do |name|
      next if ex.include?(name)
      next if name.start_with?('.')

      child = File.join(s, name)
      if File.directory?(child)
        copy_rec.call(child, File.join(d, name))
      else
        FileUtils.cp(child, File.join(d, name))
      end
    end
  end
  copy_rec.call(src.to_s, dst.to_s)
  true
end

Win.define_singleton_method(:zip_create) do |out_zip, chdir, inner_names|
  entries = []
  Array(inner_names).each do |inner|
    base = File.join(chdir, inner)
    if File.directory?(base)
      Dir.glob(File.join(base, '**', '*')).each do |f|
        next unless File.file?(f)

        rel = f.sub(%r{\A#{Regexp.escape(base)}/}, '')
        entries << ["#{inner}/#{rel}".tr('\\', '/'), File.binread(f)]
      end
    elsif File.file?(base)
      entries << [inner.to_s, File.binread(base)]
    end
  end
  FileUtils.mkdir_p(File.dirname(out_zip))
  MiniZip.write(out_zip, entries)
  true
end

Win.define_singleton_method(:zip_extract) do |zip_path, dest|
  FileUtils.mkdir_p(dest)
  MiniZip.read(zip_path).each do |name, data|
    out = File.join(dest, name.tr('\\', '/'))
    raise "path traversal в архиве: #{name}" if out.sub(%r{\A#{Regexp.escape(dest)}/}, '').split('/').include?('..')

    FileUtils.mkdir_p(File.dirname(out))
    File.binwrite(out, data)
  end
  true
end

$helper_cmdlines = []
Core.define_singleton_method(:launch_helper_process) do |cmdline|
  $helper_cmdlines << cmdline
  true
end
Core.define_singleton_method(:current_pid) { 4242 }

# ---- Ruby-реплика хелпера v2 (контракт job-файла) --------------------------------------

def simulate_helper!(job)
  core = Dn1sup::SketchupProfiles
  win = core::Win
  if job['kind'] == 'migrate'
    main_store = job['store_main_plugins']
    FileUtils.mkdir_p(main_store)
    dir_children_real = Dir.children(job['real_plugins']).reject { |n| n.start_with?('.') }
    dir_children_real.each do |name|
      src = File.join(job['real_plugins'], name)
      target = File.join(main_store, name)
      next if win.junction?(src)

      if File.directory?(src)
        FileUtils.mv(src, target)
        win.create_junction(src, target)
      else
        FileUtils.mv(src, target)
        FileUtils.cp(target, src)
      end
    end
    prefs = job['store_main_prefs']
    FileUtils.mkdir_p(prefs)
    FileUtils.cp(job['prefs_roaming'], File.join(prefs, 'SharedPreferences.json')) if File.file?(job['prefs_roaming'])
    FileUtils.cp(job['prefs_local'], File.join(prefs, 'PrivatePreferences.json')) if File.file?(job['prefs_local'])
    job['create_profiles'].each do |cp|
      win.robocopy(cp['source'], cp['target'], exclude_names: cp['exclude_names'])
      dst_prefs = File.join(File.dirname(cp['target']), 'Prefs')
      FileUtils.mkdir_p(dst_prefs)
      %w[SharedPreferences.json PrivatePreferences.json].each do |f|
        FileUtils.cp(File.join(prefs, f), File.join(dst_prefs, f)) if File.file?(File.join(prefs, f))
      end
      # самоинъекция менеджера (живой Plugins после переноса — junction; в
      # песочнице без symlink там пустой маркер — фолбэк на хранилище main)
      self_dir_src = File.file?(File.join(job['self']['dir'], 'profile_core.rb')) ? job['self']['dir'] : File.join(job['store_main_plugins'], job['self']['dir_name'])
      inject = File.join(cp['target'], job['self']['dir_name'])
      FileUtils.rm_rf(inject)
      FileUtils.cp_r(self_dir_src, inject)
      FileUtils.rm_rf(File.join(inject, 'test'))
      self_rb_src = File.file?(job['self']['rb']) ? job['self']['rb'] : File.join(job['store_main_plugins'], job['self']['rb_name'])
      FileUtils.cp(self_rb_src, File.join(cp['target'], job['self']['rb_name']))
    end
  elsif job['kind'] == 'switch'
    # сохранение уходящего
    if job['store_from_plugins']
      FileUtils.mkdir_p(job['store_from_plugins'])
      Dir.children(job['real_plugins']).grep(/\.rb\z/i).each do |f|
        FileUtils.cp(File.join(job['real_plugins'], f), File.join(job['store_from_plugins'], f))
      end
      FileUtils.mkdir_p(job['store_from_prefs'])
      FileUtils.cp(job['prefs_roaming'], File.join(job['store_from_prefs'], 'SharedPreferences.json')) if File.file?(job['prefs_roaming'])
      FileUtils.cp(job['prefs_local'], File.join(job['store_from_prefs'], 'PrivatePreferences.json')) if File.file?(job['prefs_local'])
    end
    # очистка реального Plugins
    Dir.children(job['real_plugins']).reject { |n| n.start_with?('.') }.each do |name|
      p = File.join(job['real_plugins'], name)
      if win.junction?(p)
        win.remove_junction(p)
      elsif File.directory?(p)
        FileUtils.rm_rf(p)
      else
        FileUtils.rm_f(p)
      end
    end
    # наполнение из целевого
    to = job['store_to_plugins']
    Dir.children(to).reject { |n| n.start_with?('.') }.each do |name|
      src = File.join(to, name)
      dst = File.join(job['real_plugins'], name)
      if File.file?(src)
        FileUtils.cp(src, dst)
      else
        win.create_junction(dst, src)
      end
    end
    # настройки целевого
    tp = job['store_to_prefs']
    if File.directory?(tp)
      FileUtils.cp(File.join(tp, 'SharedPreferences.json'), job['prefs_roaming']) if File.file?(File.join(tp, 'SharedPreferences.json'))
      FileUtils.cp(File.join(tp, 'PrivatePreferences.json'), job['prefs_local']) if File.file?(File.join(tp, 'PrivatePreferences.json'))
    end
  end
  core.save_state('store_version' => 2, 'year' => job['year'], 'su_exe' => job['su_exe'],
                  'active_profile' => job['target_profile'], 'initialized_at' => Time.now.to_i,
                  'updated_at' => Time.now.to_i)
  data = core.load_profiles
  data['profiles'].each { |p| p['last_launch'] = Time.now.to_i if p['id'] == job['target_profile'] }
  core.save_profiles(data)
  File.delete(core.pending_job_path) if File.file?(core.pending_job_path)
end

def dir_children(path)
  return [] unless File.directory?(path)

  Dir.children(path).reject { |n| n.start_with?('.') }.sort
end

# =============================================================================
# 1. Стартовое состояние
# =============================================================================
assert 'su_year из ENV', Core.su_year == '2026'
assert 'real_plugins определён', Core.real_plugins_dir == REAL_PLUGINS
assert 'prefs-пути определены', Core.prefs_roaming_path == PREFS_ROAM && Core.prefs_local_path == PREFS_LOC
assert 'до инициализации initialized? false', !Core.initialized?
assert 'стор изолирован по году версии', Core.store_root == File.join(LOCALAPP, 'dn1sup_sketchup_profiles', 'SU2026'), Core.store_root
live_plugins = dir_children(REAL_PLUGINS)

# Живое окружение приоритетнее stale state: state с чужим годом не сбивает su_year.
Core.save_state('store_version' => 2, 'year' => '2024', 'active_profile' => 'main', 'initialized_at' => Time.now.to_i)
assert 'su_year не берётся из state чужой версии', Core.su_year == '2026', Core.su_year
File.delete(Core.state_json_path)

# Год ниже минимального отклоняется.
old_env = ENV['DN1SUP_PROFILES_YEAR']
ENV['DN1SUP_PROFILES_YEAR'] = '2023'
begin
  Core.prepare_migration
  assert 'prepare_migration: SketchUp 2023 отклонён', false
rescue RuntimeError => e
  assert 'prepare_migration: SketchUp 2023 отклонён', e.message.include?('2024'), e.message
end
ENV['DN1SUP_PROFILES_YEAR'] = old_env

# Старый плоский стор 0.3.x переезжает в папку версии.
legacy_base = File.join(LOCALAPP, 'dn1sup_sketchup_profiles')
FileUtils.mkdir_p(legacy_base)
File.write(File.join(legacy_base, 'profiles.json'), JSON.generate('profiles' => []))
FileUtils.mkdir_p(File.join(legacy_base, 'profiles', 'main', 'Plugins'))
File.write(File.join(legacy_base, 'profiles', 'main', 'Plugins', 'keep.rb'), '# keep')
FileUtils.mkdir_p(File.join(legacy_base, 'logs'))
assert 'legacy-стор мигрирует в SU2026', Core.store_root == File.join(legacy_base, 'SU2026')
assert 'legacy profiles.json переехал', File.file?(File.join(legacy_base, 'SU2026', 'profiles.json'))
assert 'legacy profiles переехал', File.file?(File.join(legacy_base, 'SU2026', 'profiles', 'main', 'Plugins', 'keep.rb'))
assert 'мостик profiles: старое место — junction на новое',
       Win.junction?(File.join(legacy_base, 'profiles')) &&
       File.directory?(File.join(legacy_base, 'profiles')) &&
       Win.junction_target(File.join(legacy_base, 'profiles')).to_s.tr('\\', '/').downcase ==
         File.join(legacy_base, 'SU2026', 'profiles').tr('\\', '/').downcase
FileUtils.rm_rf(File.join(legacy_base, 'SU2026'))
FileUtils.rm_rf(File.join(legacy_base, 'profiles'))
FileUtils.rm_rf(File.join(legacy_base, 'logs'))
FileUtils.rm_f(File.join(legacy_base, 'profiles.json'))

# =============================================================================
# 2. prepare_migration: job v2
# =============================================================================
res = Core.prepare_migration
assert 'prepare_migration запускает хелпер', res['ok'] == true && res['quitting'] == true, res.inspect
assert 'хелпер со staging-копией',
       $helper_cmdlines.last.to_s.include?('powershell.exe') &&
       $helper_cmdlines.last.to_s.include?(Win.to_win(Core.helper_staged_path))
assert 'хелпер застейджен', File.file?(Core.helper_staged_path)

job = Core.load_json(Core.pending_job_path, {})
assert 'job: kind=migrate, real_plugins, strict_solo',
       job['kind'] == 'migrate' && job['real_plugins'] == REAL_PLUGINS &&
       job['strict_solo'] == true && job['wait_pid'] == 4242
assert 'job: хранилища main и prefs',
       job['store_main_plugins'] == Core.profile_store_plugins('main') &&
       job['store_main_prefs'] == Core.profile_store_prefs('main') &&
       job['prefs_roaming'] == PREFS_ROAM && job['prefs_local'] == PREFS_LOC
specs = job['create_profiles']
assert 'job: без клонов (только main)', specs.is_a?(Array) && specs.empty?, specs.inspect
assert 'профили.json: только main (защищён)',
       Core.profile_list.map { |p| p['id'] } == %w[main] &&
       Core.find_profile('main')['protected'] == true
assert 'job: self — файлы менеджера',
       File.file?(job['self']['rb']) && File.directory?(job['self']['dir'])

# Повторная инициализация после успешного хелпера (state создан) — запрещена.
Core.save_state('store_version' => 2, 'year' => '2026', 'active_profile' => 'main',
                'initialized_at' => Time.now.to_i)
begin
  Core.prepare_migration
  assert 'повторная prepare_migration отклонена', false
rescue RuntimeError => e
  assert 'повторная prepare_migration отклонена', !e.message.empty?, e.message
end
File.delete(Core.state_json_path) # возвращаем «хелпер ещё не завершался»

# =============================================================================
# 3. Симуляция хелпера (migrate)
# =============================================================================
simulate_helper!(job)

assert 'после миграции initialized? true', Core.initialized?
assert 'активный — main', Core.detect_active_profile == 'main'
main_store = Core.profile_store_plugins('main')
assert 'хранилище main: полный набор', dir_children(main_store) == live_plugins
assert 'реальный Plugins: набор не изменился (rb-копии + junction-папки)',
       dir_children(REAL_PLUGINS) == live_plugins
assert 'реальный Plugins: .rb — реальные файлы',
       File.file?(File.join(REAL_PLUGINS, 'dn1sup_ext_manager.rb'))
assert 'Prefs main: оба файла настроек',
       File.file?(File.join(Core.profile_store_prefs('main'), 'SharedPreferences.json')) &&
       File.file?(File.join(Core.profile_store_prefs('main'), 'PrivatePreferences.json'))

# Клоны dev/drafting с фильтрами dn1sup_* удалены (0.4.0): дополнительные
# профили создаются через create_profile(mode: clone/clean) ниже.

# =============================================================================
# 4. state_payload
# =============================================================================
payload = Core.state_payload
assert 'payload: initialized/active/store_version',
       payload['initialized'] == true && payload['active_profile'] == 'main' && payload['store_version'] == 2
assert 'payload: 1 профиль, счётчик',
       payload['profiles'].size == 1 &&
       payload['profiles'].find { |p| p['id'] == 'main' }['extensions_count'] == live_plugins.size &&
       payload['profiles'].find { |p| p['id'] == 'main' }['is_active'] == true

Core.save_json(Core.job_result_path, { 'ok' => true, 'phases' => %w[waited switched done] })
assert 'job_result читается один раз', Core.state_payload['job_result']['ok'] == true
assert 'job_result удалён', Core.state_payload['job_result'].nil?

# =============================================================================
# 5. list_extensions
# =============================================================================
exts = Core.list_extensions('main')
assert 'list: пары склеены, версия/имя из регистратора',
       (e = exts.find { |x| x['id'] == 'dn1sup_ext_manager' }) &&
       e['has_rb'] && e['has_dir'] && e['version'] == '0.11.2' && e['name'] == 'DN1Sup Extension Store'
assert 'list: типы',
       exts.find { |e| e['id'] == 'dn1sup_sketchup_profiles' }['kind'] == 'self' &&
       exts.find { |e| e['id'] == 'dn1sup_ext_manager' }['kind'] == 'dn1sup' &&
       exts.find { |e| e['id'] == 'curic_deep_select' }['kind'] == 'third_party'
assert 'list: одиночный .rb', (e = exts.find { |x| x['id'] == 'fillet' }) && e['has_rb'] && !e['has_dir']

# =============================================================================
# 6. install_rbz (в неактивный и в активный)
# =============================================================================
rbz = File.join(SANDBOX, 'demo_ext.rbz')
MiniZip.write(rbz, [
                ['demo_ext.rb', "# demo\nextension.version = '9.9.9'\n"],
                ['demo_ext/main.rb', '# code']
              ])
res = Core.create_profile(id: 'second', name: 'Второй', source_id: 'main', mode: 'clone')
second_store = Core.profile_store_plugins('second')
assert 'clone для install-теста создан', res['ok'] == true && res['mode'] == 'clone'
res = Core.install_rbz('second', rbz)
assert 'install_rbz в неактивный: только store',
       res['ok'] == true && File.file?(File.join(second_store, 'demo_ext.rb')) &&
       !File.exist?(File.join(REAL_PLUGINS, 'demo_ext.rb'))
res = Core.install_rbz('main', rbz)
assert 'install_rbz в активный: store + зеркало в реальный Plugins',
       res['ok'] == true && File.file?(File.join(REAL_PLUGINS, 'demo_ext.rb')) &&
       Win.junction?(File.join(REAL_PLUGINS, 'demo_ext'))
assert 'install_rbz: счётчик профиля вырос',
       Core.state_payload['profiles'].find { |p| p['id'] == 'main' }['extensions_count'] ==
       dir_children(main_store).size

bad = File.join(SANDBOX, 'bad.rbz')
MiniZip.write(bad, [['docs/readme.txt', 'нет регистратора']])
begin
  Core.install_rbz('second', bad)
  assert 'install_rbz: архив без .rb отклонён', false
rescue RuntimeError => e
  assert 'install_rbz: архив без .rb отклонён', e.message.include?('.rb')
end

# =============================================================================
# 7. uninstall_extension
# =============================================================================
begin
  Core.uninstall_extension('main', 'dn1sup_sketchup_profiles')
  assert 'uninstall: менеджера удалить нельзя', false
rescue RuntimeError
  assert 'uninstall: менеджера удалить нельзя', true
end
['..', '../evil', '.'].each do |badname|
  begin
    Core.uninstall_extension('main', badname)
    assert "uninstall: отклоняет #{badname.inspect}", false
  rescue RuntimeError
    assert "uninstall: отклоняет #{badname.inspect}", true
  end
end
res = Core.uninstall_extension('main', 'demo_ext')
assert 'uninstall из активного: store и реальный Plugins почищены',
       res['ok'] == true &&
       !File.exist?(File.join(main_store, 'demo_ext.rb')) &&
       !File.exist?(File.join(main_store, 'demo_ext')) &&
       !File.exist?(File.join(REAL_PLUGINS, 'demo_ext.rb')) &&
       !Win.junction?(File.join(REAL_PLUGINS, 'demo_ext'))

# =============================================================================
# 8. снимки
# =============================================================================
res = Core.backup_profile('second')
assert 'backup: создан', res['ok'] == true
zip_entries = MiniZip.read(File.join(Core.backups_dir, res['file'])).keys
assert 'backup: Plugins и Prefs внутри',
       zip_entries.any? { |k| k.start_with?('Plugins/') } && zip_entries.any? { |k| k.start_with?('Prefs/') }
File.delete(File.join(second_store, 'ladb_opencutlist.rb'))
res = Core.restore_backup('second', Core.list_backups.first['file'])
assert 'restore: файл вернулся', res['ok'] == true && File.file?(File.join(second_store, 'ladb_opencutlist.rb'))
begin
  Core.restore_backup('main', Core.list_backups.first['file'])
  assert 'restore: активный отклонён', false
rescue RuntimeError
  assert 'restore: активный отклонён', true
end
assert 'delete_backup', Core.delete_backup(Core.list_backups.first['file'])['ok'] == true && Core.list_backups.empty?

# =============================================================================
# 9. create_profile / meta / delete
# =============================================================================
res = Core.create_profile(id: 'training', name: 'Обучение', source_id: 'main', mode: 'clone')
tr_store = Core.profile_store_plugins('training')
assert 'create clone: полный набор источника, менеджер на месте',
       res['ok'] == true && res['mode'] == 'clone' &&
       dir_children(tr_store).sort == dir_children(main_store).sort &&
       File.file?(File.join(tr_store, 'dn1sup_sketchup_profiles.rb'))
assert 'create clone: Prefs наследуются',
       File.file?(File.join(Core.profile_store_prefs('training'), 'SharedPreferences.json'))
begin
  Core.create_profile(id: 'training', name: 'Дубль', mode: 'clone')
  assert 'create_profile: дубль id отклонён', false
rescue RuntimeError
  assert 'create_profile: дубль id отклонён', true
end
assert 'create_profile: откат дубля не трогает оригинал',
       !Core.find_profile('training').nil? && File.directory?(Core.profile_store_root('training'))
begin
  Core.create_profile(id: 'training_bad', name: 'x', mode: 'dn1sup')
  assert 'create_profile: удалённый режим отклонён', false
rescue RuntimeError
  assert 'create_profile: удалённый режим отклонён', true
end
begin
  Core.create_profile(id: 'Bad Id!', name: 'x')
  assert 'create_profile: некорректный id отклонён', false
rescue RuntimeError
  assert 'create_profile: некорректный id отклонён', true
end
assert 'rename_profile', Core.update_profile_meta('training', 'Обучение 2', 'новое')['ok'] == true &&
                         Core.find_profile('training')['name'] == 'Обучение 2'

# --- чистый профиль: только менеджер, без наследования Prefs ---
# (в источнике лежит Save Settings — в чистый профиль он попасть не должен)
File.write(File.join(main_store, 'dn1sup_save_settings.rb'), "# save settings\n")
FileUtils.mkdir_p(File.join(main_store, 'dn1sup_save_settings'))
File.write(File.join(main_store, 'dn1sup_save_settings', 'main.rb'), '# code')
res = Core.create_profile(id: 'clean', name: 'Чистый', source_id: 'main', mode: 'clean')
cl_store = Core.profile_store_plugins('clean')
assert 'clean: создан', res['ok'] == true, res.inspect
assert 'clean: состав (только менеджер)',
       dir_children(cl_store).sort == ['dn1sup_sketchup_profiles', 'dn1sup_sketchup_profiles.rb'],
       dir_children(cl_store).inspect
assert 'clean: Save Settings из источника не копируется',
       !File.exist?(File.join(cl_store, 'dn1sup_save_settings.rb')) &&
       !File.exist?(File.join(cl_store, 'dn1sup_save_settings'))
# Примечание: в песочнице fake-junction папки менеджера — пустой маркер, поэтому
# self_inject оставляет папку менеджера пустой (в живом SketchUp через junction
# копируются реальные файлы; rb-регистратор гарантируется self_inject всегда).
assert 'clean: менеджер на месте (rb + папка)',
       File.file?(File.join(cl_store, 'dn1sup_sketchup_profiles.rb')) &&
       File.directory?(File.join(cl_store, 'dn1sup_sketchup_profiles'))
assert 'clean: стороннее не копируется',
       !File.exist?(File.join(cl_store, 'curic_deep_select.rb')) &&
       !File.exist?(File.join(cl_store, 'dn1sup_ext_manager.rb'))
assert 'clean: Prefs не наследуются',
       !File.directory?(Core.profile_store_prefs('clean'))
assert 'clean: счётчик профиля', Core.state_payload['profiles'].find { |p| p['id'] == 'clean' }['extensions_count'] == dir_children(cl_store).size

# --- legacy-алиас empty: работает как clean (только менеджер, Prefs с нуля) ---
res = Core.create_profile(id: 'empt', name: 'Пустой', source_id: 'main', mode: 'empty')
em_store = Core.profile_store_plugins('empt')
assert 'empty-алиас: только менеджер',
       res['ok'] == true && dir_children(em_store) == ['dn1sup_sketchup_profiles', 'dn1sup_sketchup_profiles.rb'],
       dir_children(em_store).inspect
assert 'empty-алиас: Prefs не наследуются',
       !File.directory?(Core.profile_store_prefs('empt'))

# откат при сбое и для clean-профиля
saved_robocopy = Core::Win.method(:robocopy)
Core::Win.define_singleton_method(:robocopy) { |*args, **kw| false }
begin
  Core.create_profile(id: 'rollback_clean', name: 'x', source_id: 'main', mode: 'clean')
  assert 'create clean: откат при сбое', false
rescue RuntimeError
  assert 'create clean: откат при сбое',
         !File.directory?(Core.profile_store_root('rollback_clean')) &&
         Core.find_profile('rollback_clean').nil?
end
Core::Win.define_singleton_method(:robocopy, saved_robocopy)
assert 'delete: чистый и legacy-empty профили удаляются',
       Core.delete_profile('clean')['ok'] == true && Core.delete_profile('empt')['ok'] == true &&
       !File.directory?(Core.profile_store_root('clean')) && !File.directory?(Core.profile_store_root('empt'))
begin
  Core.delete_profile('main')
  assert 'delete: main отклонён', false
rescue RuntimeError
  assert 'delete: main отклонён', true
end
assert 'delete: неактивный удаляется', Core.delete_profile('second')['ok'] == true &&
                                       !File.directory?(Core.profile_store_root('second')) &&
                                       Core.find_profile('second').nil?

# =============================================================================
# 10. switch_profile + симуляция
# =============================================================================
$helper_cmdlines.clear
res = Core.switch_profile('training')
assert 'switch: хелпер запущен', res['ok'] == true && res['quitting'] == true, res.inspect
job = Core.load_json(Core.pending_job_path, {})
assert 'switch job: from/to/хранилища/prefs',
       job['kind'] == 'switch' && job['from_profile'] == 'main' && job['target_profile'] == 'training' &&
       job['store_to_plugins'] == tr_store && job['store_to_prefs'] == Core.profile_store_prefs('training')

begin
  Core.switch_profile('main')
  assert 'switch: активный отклонён', false
rescue RuntimeError
  assert 'switch: активный отклонён', true
end

simulate_helper!(job)

assert 'после свитча активный — training', Core.detect_active_profile == 'training'
assert 'реальный Plugins = набор training',
       dir_children(REAL_PLUGINS) == dir_children(tr_store)
assert 'реальный Plugins: junction-папки расширений',
       Win.junction?(File.join(REAL_PLUGINS, 'ladb_opencutlist')),
       "junction?=#{Win.junction?(File.join(REAL_PLUGINS, 'ladb_opencutlist'))} " \
       "real=#{File.directory?(File.join(REAL_PLUGINS, 'ladb_opencutlist'))} " \
       "registry=#{FAKE_JUNCTIONS.keys.size} " \
       "tr_store=#{dir_children(tr_store).inspect} real_now=#{dir_children(REAL_PLUGINS).inspect}"
assert 'настройки интерфейса — из Prefs целевого профиля',
       File.file?(PREFS_ROAM) &&
       File.read(PREFS_ROAM) == File.read(File.join(Core.profile_store_prefs('training'), 'SharedPreferences.json'))

# сохранение уходящего main: .rb-файлы обновились в его хранилище
assert 'уходящий профиль: .rb сохранены',
       File.file?(File.join(main_store, 'dn1sup_ext_manager.rb'))

# созданный «в реальном Plugins после миграции» файл сохранился в уходящий профиль
File.write(File.join(REAL_PLUGINS, 'zz_new_after.rb'), '# новый скрипт')
Core.switch_profile('main')
job2 = Core.load_json(Core.pending_job_path, {})
simulate_helper!(job2)
assert 'новый .rb из реального Plugins ушёл в хранилище training',
       File.file?(File.join(tr_store, 'zz_new_after.rb'))
assert 'после возврата активный — main, набор восстановлен',
       Core.detect_active_profile == 'main' &&
       dir_children(REAL_PLUGINS) == dir_children(main_store)

# --- предполётный strict_solo: отказ ДО закрытия SketchUp ---
saved_pids = Core::Win.method(:sketchup_pids)
Core::Win.define_singleton_method(:sketchup_pids) { [4242, 9999] } # 4242 — свой (current_pid), 9999 — чужой
$helper_cmdlines.clear
begin
  Core.switch_profile('training')
  assert 'switch: чужой SketchUp отклонён до запуска хелпера', false
rescue RuntimeError => e
  assert 'switch: чужой SketchUp отклонён до запуска хелпера',
         e.message.include?('9999') && e.message.include?('одном экземпляре'), e.message
end
assert 'switch: хелпер не запускался, pending_job не создан',
       $helper_cmdlines.empty? && !File.file?(Core.pending_job_path)
Core::Win.define_singleton_method(:sketchup_pids, saved_pids)
assert 'solo-валидатор пропускает без чужих процессов',
       Core.validate_solo_instance!('тест') == true

# =============================================================================
# 11. main.rb: диспетчер (фейки)
# =============================================================================
module Sketchup
  $prefs = { 'Dn1supUpdater' => {} }
  $sketchup_extensions = []
  $quit_count = 0
  module_function

  def read_default(section, key, default = nil)
    $prefs.fetch(section, {}).fetch(key, default)
  end

  def write_default(section, key, value)
    $prefs[section] ||= {}
    $prefs[section][key] = value
    true
  end

  def require(path)
    cands = [path, path + '.rb', File.join(PLUGIN_DIR, path), File.join(PLUGIN_DIR, path + '.rb')]
    cands.each do |c|
      c += '.rb' unless File.extname(c) == '.rb'
      return Kernel.require(c) if File.file?(c)
    end
    nil
  end

  def version
    '26.0.000'
  end

  def temp_dir
    SANDBOX
  end

  def find_support_file(name)
    name == 'Plugins' ? REAL_PLUGINS : nil
  end

  def register_extension(ext, _flag = true)
    $sketchup_extensions << ext
    true
  end

  def extensions
    {}
  end

  def quit
    $quit_count += 1
  end
end

module UI
  IDYES = 6
  IDNO = 7
  MB_OK = 0
  MB_YESNO = 4
  $ui_log = []
  module_function

  def messagebox(msg, type = 0)
    $ui_log << [:messagebox, msg, type]
    $messagebox_answer || IDYES
  end

  def openpanel(title, _dir, _pattern)
    $ui_log << [:openpanel, title]
    $openpanel_answer
  end

  def start_timer(_interval = 0, _repeat = false, &blk)
    blk&.call(:timer) unless _repeat
    0
  end

  def stop_timer(_id); end

  def menu(*)
    Class.new do
      def add_submenu(*); self; end
      def add_item(*); self; end
      def add_separator(*); self; end
    end.new
  end

  def openURL(url); $ui_log << [:openURL, url]; end

  class Command
    def initialize(*); end
    %w[menu_text tooltip status_bar_text small_icon large_icon].each { |a| define_method("#{a}=") { |_v| self } }
  end

  class Toolbar
    def initialize(*); end
    def any?(*); false; end
    def add_item(*); $ui_log << [:toolbar_item]; self; end
    def restore(*); $ui_log << [:toolbar_restore]; self; end
  end
end

IDYES  = 6
IDNO   = 7
MB_OK  = 0
MB_YESNO = 4

def file_loaded?(_); false; end
def file_loaded(_); true; end
SKETCHUP_CONSOLE = Object.new
def SKETCHUP_CONSOLE.clear; end

File.write(File.join(SANDBOX, 'sketchup.rb'), '# fake sketchup.rb (smoke)')
File.write(File.join(SANDBOX, 'extensions.rb'), '# fake extensions.rb (smoke)')
$LOAD_PATH.unshift(SANDBOX)

require_relative '../dn1sup_sketchup_profiles/dn1sup_updater'
Dn1sup::Updater.define_singleton_method(:check!) { |_cfg| nil }
Dn1sup::Updater.define_singleton_method(:async_ui?) { false }

Sketchup.require(File.join(PLUGIN_DIR, 'main'))
Main = Dn1sup::SketchupProfiles

assert 'main: тулбар зарегистрирован', $ui_log.any? { |e| e[0] == :toolbar_item }
assert 'main: VERSION совпадает', Main::VERSION == Core::VERSION

loader_src = File.read(File.join(REPO, 'dn1sup_sketchup_profiles.rb'))
loader_ver = loader_src[/(?:extension|ext)\.version\s*=\s*['"]([^'"]+)['"]/i, 1].to_s
registry_ver = begin
  JSON.parse(File.read(File.join(REPO, 'registry.json'))).find { |e| e.is_a?(Hash) && e['id'].to_s == Core::ID }&.fetch('version', '').to_s
rescue StandardError
  ''
end
assert 'версия: profile_core == регистратору', Core::VERSION == loader_ver, "core=#{Core::VERSION} loader=#{loader_ver}"
assert 'версия: profile_core == registry.json', Core::VERSION == registry_ver, "core=#{Core::VERSION} registry=#{registry_ver}"

class FakeStoreDialog
  attr_reader :scripts

  def initialize
    @scripts = []
  end

  def add_action_callback(*); true; end
  def visible?; true; end
  def execute_script(s); @scripts << s; end
end

dlg = FakeStoreDialog.new
Main.instance_variable_set(:@dialog, dlg)

dlg.scripts.clear
Main.dispatch(dlg, 'ready', '')
pushed = dlg.scripts.grep(/\Awindow\.pushState\(/).last
assert 'dispatch ready → pushState', !!pushed && pushed.include?('"active_profile":"main"')

dlg.scripts.clear
Main.dispatch(dlg, 'get_extensions', JSON.generate('profile' => 'main'))
assert 'dispatch get_extensions → pushResult',
       dlg.scripts.grep(/"extensions"/).any? { |s| s.include?('dn1sup_ext_manager') }

dlg.scripts.clear
$messagebox_answer = IDYES
$openpanel_answer = rbz
Main.dispatch(dlg, 'install_rbz', JSON.generate('profile' => 'main'))
assert 'dispatch install_rbz (активный профиль) → ok + зеркало',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":true') } &&
       File.file?(File.join(REAL_PLUGINS, 'demo_ext.rb'))
$openpanel_answer = nil

dlg.scripts.clear
$quit_count = 0
Core.switch_profile('training')
dlg.scripts.clear
$messagebox_answer = IDYES
Main.dispatch(dlg, 'switch_profile', JSON.generate('id' => 'training'))
assert 'dispatch switch → quitting + quit',
       dlg.scripts.grep(/"quitting"/).any? && $quit_count == 1
$messagebox_answer = IDNO
dlg.scripts.clear
Main.dispatch(dlg, 'switch_profile', JSON.generate('id' => 'training'))
assert 'dispatch switch: отказ — без quitting', dlg.scripts.grep(/"quitting"/).empty? && $quit_count == 1
# откат: вернуть main активным без хелпера (job симулирован не был — просто state)
state = Core.load_state
state['active_profile'] = 'main'
Core.save_state(state)

dlg.scripts.clear
Main.dispatch(dlg, 'begin_migration', JSON.generate({}))
assert 'dispatch begin_migration (инициализировано) → ok:false',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":false') }

dlg.scripts.clear
Main.dispatch(dlg, 'create_profile', JSON.generate('id' => 'via_ui', 'name' => 'Через UI',
                                                   'description' => '', 'source' => 'main', 'mode' => 'clean'))
assert 'dispatch create_profile (mode clean) → ok',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":true') } &&
       !Core.find_profile('via_ui').nil?
Core.delete_profile('via_ui')

dlg.scripts.clear
Main.dispatch(dlg, 'sync_self', '')
assert 'dispatch sync_self → ok', dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":true') }

dlg.scripts.clear
Main.dispatch(dlg, 'check_update', '')
assert 'dispatch check_update (рабочая копия) → тост в диалог, а не тишина',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('рабочая копия') }

# ---- task-оверлей / confirm-поток / get_progress -----------------------------------

dlg.scripts.clear
Main.dispatch(dlg, 'get_progress', '')
assert 'dispatch get_progress → push progress', dlg.scripts.grep(/"progress"/).any?

dlg.scripts.clear
Main.dispatch(dlg, 'delete_profile', JSON.generate('id' => 'no_such'))
assert 'dispatch delete_profile: неизвестный → ошибка без confirm',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":false') } &&
       dlg.scripts.grep(/"confirm"/).empty?

dlg.scripts.clear
Main.dispatch(dlg, 'delete_profile', JSON.generate('id' => 'training'))
confirm_script = dlg.scripts.grep(/pushResult\("confirm"/).last
assert 'dispatch delete_profile → confirm push (без messagebox)',
       !!confirm_script && $ui_log.none? { |e| e[0] == :messagebox && e[1].to_s.include?('Удалить профиль') }
token = JSON.parse(confirm_script[/pushResult\("confirm", (.*)\);/, 1])['token']

dlg.scripts.clear
Main.dispatch(dlg, 'confirm_answer', JSON.generate('token' => token, 'yes' => false))
assert 'confirm_answer: отказ → Отменено, профиль жив',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('Отменено') } &&
       !Core.find_profile('training').nil?

dlg.scripts.clear
Main.dispatch(dlg, 'delete_profile', JSON.generate('id' => 'training'))
token2 = JSON.parse(dlg.scripts.grep(/pushResult\("confirm"/).last[/pushResult\("confirm", (.*)\);/, 1])['token']
dlg.scripts.clear
Main.dispatch(dlg, 'confirm_answer', JSON.generate('token' => token2, 'yes' => true))
assert 'confirm_answer: да → профиль удалён',
       dlg.scripts.grep(/"action_result"/).any? { |s| s.include?('"ok":true') } &&
       Core.find_profile('training').nil? && !File.directory?(Core.profile_store_root('training'))

dlg.scripts.clear
Main.dispatch(dlg, 'confirm_answer', JSON.generate('token' => 'deadbeef', 'yes' => false))
assert 'confirm_answer: неизвестный токен игнорируется', dlg.scripts.grep(/"action_result"/).empty?

# откат создания при сбое посреди операции
begin
  Core.create_profile(id: 'training2', name: 'x', source_id: 'train_no_such')
  assert 'create_profile: откат при сбое после копирования', false
rescue RuntimeError
  assert 'create_profile: откат при сбое после копирования', true
end

win_robocopy_backup = Core::Win.method(:robocopy)
Core::Win.define_singleton_method(:robocopy) { |*args, **kw| false }
out = nil
begin
  Core.create_profile(id: 'rollback_test', name: 'x', source_id: 'main')
rescue RuntimeError
  out = File.directory?(Core.profile_store_root('rollback_test'))
end
Core::Win.define_singleton_method(:robocopy, win_robocopy_backup)
assert 'create_profile: сбой robocopy → хранилище не осталось',
       !File.directory?(Core.profile_store_root('rollback_test')) && Core.find_profile('rollback_test').nil?

# verify_profile_store!: целый клон проходит, усечённый отклоняется
require 'tmpdir'
Dir.mktmpdir do |tmp|
  vsrc = File.join(tmp, 'src')
  vdst = File.join(tmp, 'dst')
  FileUtils.mkdir_p(File.join(vsrc, 'dn1sup_export_3d'))
  FileUtils.mkdir_p(File.join(vdst, 'dn1sup_export_3d'))
  File.write(File.join(vsrc, 'dn1sup_export_3d.rb'), 'x')
  File.write(File.join(vdst, 'dn1sup_export_3d.rb'), 'x')
  File.write(File.join(vsrc, 'dn1sup_export_3d', 'version.rb'), 'x')
  File.write(File.join(vdst, 'dn1sup_export_3d', 'version.rb'), 'x')
  assert 'verify_profile_store!: целый клон проходит',
         Core.verify_profile_store!(vsrc, vdst, []) == true
  FileUtils.rm_rf(File.join(vdst, 'dn1sup_export_3d'))
  begin
    Core.verify_profile_store!(vsrc, vdst, [])
    assert 'verify_profile_store!: битый клон (.rb без папки) отклоняется', false
  rescue RuntimeError => e
    assert 'verify_profile_store!: битый клон (.rb без папки) отклоняется',
           e.message.include?('dn1sup_export_3d')
  end
end

# mirror_item_to_real: сбой junction — исключение, а не молчаливый полуклон
fake_dir = File.join(Core.profile_store_plugins('main'), 'dn1sup_broken_fake')
FileUtils.mkdir_p(fake_dir)
saved_junction = Core::Win.method(:create_junction)
Core::Win.define_singleton_method(:create_junction) { |*| false }
begin
  Core.mirror_item_to_real('main', 'dn1sup_broken_fake')
  assert 'mirror_item_to_real: сбой junction → исключение', false
rescue RuntimeError => e
  assert 'mirror_item_to_real: сбой junction → исключение',
         e.message.include?('dn1sup_broken_fake')
ensure
  Core::Win.define_singleton_method(:create_junction, saved_junction)
  FileUtils.rm_rf(fake_dir)
end

assert 'прогресс сбрасывается после операций', Core.progress_snapshot.nil?

# регистратор
class SketchupExtension
  attr_accessor :description, :version, :creator, :copyright, :id
  def initialize(name, _path); @name = name; end
end
load File.join(REPO, 'dn1sup_sketchup_profiles.rb')
assert 'регистратор: зарегистрирован',
       $sketchup_extensions.any? { |e| e.respond_to?(:id) && e.id == 'dn1sup_sketchup_profiles' } ||
       $sketchup_extensions.first.is_a?(SketchupExtension)

puts "\n#{$failed.zero? ? 'ALL TESTS PASSED' : "#{$failed} FAILED"}"
exit($failed.zero? ? 0 : 1)
