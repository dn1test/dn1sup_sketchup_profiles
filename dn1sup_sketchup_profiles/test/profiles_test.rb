# frozen_string_literal: true
# =============================================================================
# dn1sup_sketchup_profiles/test/profiles_test.rb — живые тесты в SketchUp (v2).
#
# Все операции — ТОЛЬКО в песочнице (tmp): подменяются пути ядра, ручной
# прогон хелпера идёт на обезвреженном job-файле песочницы (run_helper_sync!
# принудительно ставит wait_pid=0, strict_solo=false, relaunch=false,
# su_exe=''). Живые данные пользователя не трогаются, новые копии SketchUp
# не поднимаются.
# =============================================================================

require_relative 'test_helper'

module Dn1sup::SketchupProfiles::Test
  Core = Dn1sup::SketchupProfiles unless defined?(Core)

  # Вне живого SketchUp (plain `ruby test/profiles_test.rb` с заглушками
  # test_helper.rb) тесты, требующие рантайма SketchUp, уходят в skip.
  # У настоящего API метода stubbed? нет — внутри SketchUp всё работает
  # как раньше.
  def self.outside_sketchup?
    !defined?(Sketchup) ||
      (Sketchup.respond_to?(:stubbed?) && Sketchup.stubbed?)
  end

  def self.with_sandbox!
    skip('только Windows') unless Core::Win.windows?

    sandbox = Dir.mktmpdir('sp_live')
    roam = File.join(sandbox, 'Roaming')
    local = File.join(sandbox, 'Local')
    ENV['DN1SUP_PROFILES_YEAR'] = '2026'
    plugins = File.join(roam, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'Plugins')
    FileUtils.mkdir_p(plugins)
    ['dn1sup_ext_manager', 'dn1sup_sketchup_profiles', 'curic_select'].each do |id|
      File.write(File.join(plugins, "#{id}.rb"), "# #{id}\nextension.version = '1.0.0'\n")
      FileUtils.mkdir_p(File.join(plugins, id))
      File.write(File.join(plugins, id, 'main.rb'), '# code')
    end
    File.write(File.join(plugins, 'solo.rb'), '# solo')
    prefs_roam = File.join(roam, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'SharedPreferences.json')
    prefs_loc = File.join(local, 'SketchUp', 'SketchUp 2026', 'SketchUp', 'PrivatePreferences.json')
    FileUtils.mkdir_p(File.dirname(prefs_roam))
    FileUtils.mkdir_p(File.dirname(prefs_loc))
    File.write(prefs_roam, '{"template":"x"}')
    File.write(prefs_loc, '{"ui":"x"}')

    orig = {
      appdata: Core.method(:env_appdata), local: Core.method(:env_localappdata),
      session: Core.plugins_root_of_current_session,
      solo: Core.method(:strict_solo_flag)
    }
    Core.define_singleton_method(:env_appdata) { roam }
    Core.define_singleton_method(:env_localappdata) { local }
    Core.plugins_root_of_current_session = plugins
    Core.define_singleton_method(:strict_solo_flag) { false }

    begin
      yield sandbox
    ensure
      Core.define_singleton_method(:env_appdata, orig[:appdata])
      Core.define_singleton_method(:env_localappdata, orig[:local])
      Core.plugins_root_of_current_session = orig[:session]
      Core.define_singleton_method(:strict_solo_flag, orig[:solo])
      ENV.delete('DN1SUP_PROFILES_YEAR')
      FileUtils.remove_entry(sandbox) if File.directory?(sandbox)
    end
  end

  # Ручной прогон хелпера на job-файле песочницы. Перед запуском job
  # ОБЕЗВРЕЖИВАЕТСЯ (relaunch=false, su_exe='', wait_pid=0): хелперу запрещено
  # поднимать новые копии SketchUp — разрешён только рестарт из живого
  # приложения, а тесты работают без рестарта.
  def self.run_helper_sync!
    require 'json'
    job_path = Core.pending_job_path
    if File.file?(job_path)
      job = JSON.parse(File.read(job_path, encoding: 'UTF-8'))
      job['relaunch'] = false
      job['su_exe'] = ''
      job['wait_pid'] = 0
      File.write(job_path, JSON.generate(job))
    end
    `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "#{Core.helper_staged_path}" -JobPath "#{job_path}" 2>&1`
    $?.exitstatus.to_i
  end

  test 'версия расширения согласована' do
    assert(Core::VERSION =~ /\A\d+\.\d+\.\d+\z/, "VERSION=#{Core::VERSION}")
    # Регистратор — один (`dn1sup_sketchup_profiles.rb` рядом с папкой плагина).
    parent_name = File.basename(File.dirname(Core::PLUGIN_DIR))
    candidates = [
      File.join(Core::PLUGIN_DIR, '..', '..', "#{parent_name}.rb"),
      File.join(File.dirname(Core::PLUGIN_DIR), "#{parent_name}.rb"),
      File.join(Core::PLUGIN_DIR, '..', '..', 'dn1sup_sketchup_profiles.rb')
    ]
    registrar = candidates.find { |c| File.file?(c) }
    if registrar
      m = File.read(registrar).match(/(?:ext\.|extension\.)version\s*=\s*['"]([^'"]+)['"]/)
      assert(m, 'в регистраторе нет ext.version')
      assert_equal(Core::VERSION, m[1], "версия регистратора (#{File.basename(registrar)}) ≠ VERSION ядра")
    end
  end

  test 'живое окружение определяется (read-only)' do
    skip('вне SketchUp: нет активной модели') if outside_sketchup?
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.respond_to?(:version)

    year = (2000 + Sketchup.version.to_i).to_s
    assert_equal(year, Core.su_year, "su_year=#{Core.su_year}")
    assert(Core.real_plugins_dir.end_with?('Plugins'), Core.real_plugins_dir)
    assert(File.directory?(Core.real_plugins_dir), 'реальный Plugins не найден')
  end

  test 'хелпер v2: живая миграция и переключение в песочнице' do
    skip('вне SketchUp: нет активной модели') if outside_sketchup?
    with_sandbox! do |_sandbox|
      orig_launch = Core.method(:launch_helper_process)
      orig_pid = Core.method(:current_pid)
      cmdlines = []
      Core.define_singleton_method(:launch_helper_process) do |cmdline|
        cmdlines << cmdline
        true
      end
      Core.define_singleton_method(:current_pid) { 0 }

      res = Core.prepare_migration
      assert_equal(true, res['ok'], res.inspect)
      assert(!cmdlines.empty? && cmdlines.first.include?('powershell.exe'), cmdlines.inspect)
      assert(File.file?(Core.helper_staged_path), 'хелпер не застейджен')

      code = run_helper_sync!
      assert_equal(0, code, "helper exit=#{code}")
      assert_equal(true, Core.initialized?)
      assert_equal('main', Core.detect_active_profile)

      main_store = Core.profile_store_plugins('main')
      assert(File.file?(File.join(main_store, 'dn1sup_sketchup_profiles.rb')), 'менеджер не инъектирован')

      # новый профиль — клон источника
      res = Core.create_profile(id: 'second', name: 'Второй', source_id: 'main', mode: 'clone')
      assert_equal(true, res['ok'], res.inspect)
      assert(File.file?(File.join(Core.profile_store_plugins('second'), 'dn1sup_sketchup_profiles.rb')))

      # переключение на второй
      res = Core.switch_profile('second')
      assert_equal(true, res['ok'], res.inspect)
      code2 = run_helper_sync!
      assert_equal(0, code2, "helper switch exit=#{code2}")
      assert_equal('second', Core.detect_active_profile)

      result = Core.load_json(File.join(Core.store_root, 'pending_job.result.json'), {})
      assert_equal(true, result['ok'], result.inspect)

      Core.define_singleton_method(:launch_helper_process, orig_launch)
      Core.define_singleton_method(:current_pid, orig_pid)
    end
  end

  test 'ядро v2: установка .rbz и снимок в песочнице' do
    skip('вне SketchUp: нет активной модели') if outside_sketchup?
    with_sandbox! do |_sandbox|
      orig_launch = Core.method(:launch_helper_process)
      orig_pid = Core.method(:current_pid)
      Core.define_singleton_method(:launch_helper_process) { |_cmdline| true }
      Core.define_singleton_method(:current_pid) { 0 }
      begin
        Core.prepare_migration
        run_helper_sync!

        exts = Core.list_extensions('main')
        assert(exts.any? { |e| e['id'] == 'dn1sup_ext_manager' }, exts.inspect)
        assert_equal('self', exts.find { |e| e['id'] == 'dn1sup_sketchup_profiles' }['kind'])

        rbz = File.join(Dir.tmpdir, "sp_test_#{Time.now.to_i}.rbz")
        ZipStub.write_demo_rbz(rbz)
        res = Core.install_rbz('main', rbz)
        assert_equal(true, res['ok'], res.inspect)
        assert(File.file?(File.join(Core.real_plugins_dir, 'demo_ext.rb')), 'в активный профиль не зеркалировано')
        assert(File.file?(File.join(Core.profile_store_plugins('main'), 'demo_ext.rb')))

        res = Core.backup_profile('main')
        assert_equal(true, res['ok'], res.inspect)
        assert(!Core.list_backups.empty?)
      ensure
        Core.define_singleton_method(:launch_helper_process, orig_launch)
        Core.define_singleton_method(:current_pid, orig_pid)
        FileUtils.rm_f(rbz) if rbz.is_a?(String)
      end
    end
  end

  # Мини-zip (STORE) для тестовой .rbz — без внешних гемов.
  module ZipStub
    require 'zlib'
    module_function

    def write_demo_rbz(path)
      entries = [
        ['demo_ext.rb', "# demo\nextension.version = '9.9.9'\n"],
        ['demo_ext/main.rb', '# code']
      ]
      date = (Time.now.year - 1980) << 9 | Time.now.month << 5 | Time.now.day
      time = Time.now.hour << 11 | Time.now.min << 5 | Time.now.sec / 2
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
  end
end

# Прямой запуск (ruby test/profiles_test.rb) печатает отчёт в stdout и
# возвращает ненулевой код при провалах. Внутри SketchUp тесты запускает
# сам ext_test через Test.run! — здесь молчим.
if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
  report = Dn1sup::SketchupProfiles::Test.run!
  puts '————————————————————————————————————'
  puts "Тестов: #{report['total']}  Прошло: #{report['passed']}  " \
       "Провалено: #{report['failures'].size}  Пропущено: #{report['skipped'].size}  " \
       "за #{report['duration_ms']} мс"
  report['failures'].each do |failure|
    puts "\n✗ #{failure['name']}\n  #{failure['error']}"
    Array(failure['backtrace']).each { |line| puts "    #{line}" }
  end
  report['skipped'].each { |s| puts "  ⊘ #{s['name']}: #{s['reason']}" }
  exit(report['failures'].empty? ? 0 : 1)
end
