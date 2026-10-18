# frozen_string_literal: true

# =============================================================================
# dn1sup_sketchup_profiles/profile_core.rb — ядро менеджера профилей (v2).
#
# СХЕМА ИЗОЛЯЦИИ (выведена на живом SketchUp 2026.2, работает в 2024+):
# SketchUp 2024+ НЕ регистрирует расширения, если каталог версии или сам
# Plugins — NTFS-junction. Поэтому junction ставится НЕ на системные
# каталоги, а на ПАПККИ ОТДЕЛЬНЫХ РАСШИРЕНИЙ:
#
#   Plugins (реальный)          → *.rb-регистраторы (общие копии)
#                                + <ext_id>/ — junction на хранилище профиля
#   profiles\<id>\Plugins\      → полный образ Plugins профиля (*.rb + папки)
#   profiles\<id>\Prefs\        → SharedPreferences.json + PrivatePreferences.json
#                                 (настройки интерфейса; свап при переключении)
#
# Переключение профиля (внешний хелпер, SketchUp закрыт): сохранить .rb и
# настройки уходящего профиля, очистить реальный Plugins (файлы удалить,
# junction-ы снять — оригиналы в хранилище не трогаются), наполнить из
# хранилища целевого (.rb копией, папки junction-ами), скопировать его
# настройки. Так каждый профиль имеет свой набор и версии расширений и свою
# раскладку интерфейса, а SketchUp видит обычный реальный каталог Plugins.
#
# Все пути — методы-хуки (подменяются тестами). Sketchup API ядро не зовёт.
# =============================================================================

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'win_helpers'

module Dn1sup
  module SketchupProfiles
    ID            = 'dn1sup_sketchup_profiles'
    VERSION       = '0.6.7'
    STORE_VERSION = 2
    MAIN_ID       = 'main'
    BACKUPS_KEEP  = 10
    # Поддерживаются SketchUp 2024 и новее: год версии определяется динамически
    # (su_year), пути Plugins/Prefs/EXE строятся от него.
    MIN_SUPPORTED_YEAR = 2024

    PLUGIN_DIR = File.dirname(__FILE__).freeze

    # Состав «Чистого профиля»: только менеджер профилей. Настройки
    # интерфейса (Prefs) не наследуются — SketchUp генерирует их заново.
    # Базовые имена; в фильтр превращаются вместе с парой «имя.rb».
    CLEAN_KEEP = %w[dn1sup_sketchup_profiles].freeze

    PROFILE_ID_RE = /\A[a-z][a-z0-9_]{0,31}\z/.freeze
    EXT_NAME_RE   = /\A[A-Za-z0-9_][A-Za-z0-9_.\-]*\z/.freeze

    module_function

    # Паттерны фильтра из keep-list: базовое имя + его .rb (fnmatch —
    # точка в патерне литеральная, поэтому обе формы отдельно).
    def clean_keep_patterns
      CLEAN_KEEP.flat_map { |n| [n, "#{n}.rb"] }
    end

    # ---- пути (хуки для тестов) --------------------------------------------------

    def env_appdata
      ENV['APPDATA'].to_s
    end

    def env_localappdata
      ENV['LOCALAPPDATA'].to_s
    end

    # База хранилища (общая), профили лежат в подпапке версии SU<год>:
    # у каждого SketchUp (2024+) свои Plugins/Prefs, поэтому и хранилище
    # изолировано по году. Старый плоский стор 0.3.x (файлы прямо в базе)
    # один раз переезжает в папку текущей версии.
    def store_base
      File.join(env_localappdata, 'dn1sup_sketchup_profiles')
    end

    def store_root
      year = su_year
      dir = year.match?(/\A\d{4}\z/) ? File.join(store_base, "SU#{year}") : File.join(store_base, 'SUunknown')
      maybe_migrate_legacy_store(dir)
      dir
    end

    def maybe_migrate_legacy_store(dir)
      base_has_legacy = File.file?(File.join(store_base, 'profiles.json'))
      return false unless base_has_legacy
      return true if store_base == dir

      # Переезд 0.3.x → SU<год>: двигаем только отсутствующие в цели файлы
      # (цель уже может существовать — например, state записан раньше).
      # Для перенесённых КАТАЛОГОВ оставляем junction-мостик старое место →
      # новое: живые junction-ы реального Plugins, указывающие в старый стор,
      # продолжают резолвиться до следующего переключения профиля, которое
      # перестроит их напрямую в новое место.
      FileUtils.mkdir_p(dir)
      moved = false
      Dir.children(store_base).each do |name|
        next if name =~ /\ASU\d{4}\z/ || name == 'SUunknown'

        from = File.join(store_base, name)
        to = File.join(dir, name)
        next if File.exist?(to) || Win.junction?(to)

        is_dir = File.directory?(from) && !Win.junction?(from)
        FileUtils.mv(from, to)
        moved = true
        Win.create_junction(from, to) if is_dir
      end
      moved
    rescue StandardError
      nil
    end

    def profiles_root
      File.join(store_root, 'profiles')
    end

    def backups_dir
      File.join(store_root, 'backups')
    end

    def logs_dir
      File.join(store_root, 'logs')
    end

    def profiles_json_path
      File.join(store_root, 'profiles.json')
    end

    def state_json_path
      File.join(store_root, 'state.json')
    end

    def pending_job_path
      File.join(store_root, 'pending_job.json')
    end

    def job_result_path
      File.join(store_root, 'pending_job.result.json')
    end

    def helper_src_path
      File.join(PLUGIN_DIR, 'helper', 'su_profiles_helper.ps1')
    end

    def helper_staged_path
      File.join(store_root, 'su_profiles_helper.ps1')
    end

    def plugins_root_of_current_session
      if defined?(@session_plugins_dir) && @session_plugins_dir
        return @session_plugins_dir
      end
      if defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)
        Sketchup.find_support_file('Plugins')
      end.to_s
    end

    # Фиксация пути Plugins на главном потоке (фоновые операции не зовут Sketchup API).
    def plugins_root_of_current_session=(path)
      @session_plugins_dir = path.to_s
    end

    # Реальный (общий) каталог Plugins SketchUp.
    def real_plugins_dir
      plugins_root_of_current_session.to_s.empty? ? default_real_plugins_dir : plugins_root_of_current_session
    end

    def default_real_plugins_dir
      File.join(env_appdata, 'SketchUp', "SketchUp #{su_year}", 'SketchUp', 'Plugins')
    end

    # Файлы настроек (интерфейс, флаги расширений) — реальные, свапаются копированием.
    def prefs_roaming_path
      File.join(env_appdata, 'SketchUp', "SketchUp #{su_year}", 'SketchUp', 'SharedPreferences.json')
    end

    def prefs_local_path
      File.join(env_localappdata, 'SketchUp', "SketchUp #{su_year}", 'SketchUp', 'PrivatePreferences.json')
    end

    def su_year
      env = ENV['DN1SUP_PROFILES_YEAR'].to_s
      return env if env.match?(/\A\d{4}\z/)

      # Живое окружение — в приоритете: расширение работает в любом
      # SketchUp 2024+ (в т.ч. после смены версии SketchUp). Хранилище
      # изолировано по году (store_root), поэтому сохранённый state для
      # определения года не используется — иначе версии делили бы стор.
      if defined?(Sketchup) && Sketchup.respond_to?(:version) &&
         (m = Sketchup.version.to_s.match(/\A(\d+)\./))
        return (2000 + m[1].to_i).to_s
      end
      # Сырой путь сессии без default-фолбэка: default_real_plugins_dir сам
      # зовёт su_year, через real_plugins_dir здесь была бы рекурсия.
      if (m = plugins_root_of_current_session.to_s.match(/SketchUp (\d{4})/i))
        return m[1]
      end

      ''
    end

    def validate_su_year!
      year = su_year
      raise 'Не удалось определить версию SketchUp (год)' unless year.match?(/\A\d{4}\z/)
      raise "Требуется SketchUp #{MIN_SUPPORTED_YEAR} или новее (определён #{year})" if year.to_i < MIN_SUPPORTED_YEAR

      year
    end

    # ---- хранилище профиля -----------------------------------------------------------

    def profile_store_root(profile_id)
      File.join(profiles_root, profile_id.to_s)
    end

    def profile_store_plugins(profile_id)
      File.join(profile_store_root(profile_id), 'Plugins')
    end

    def profile_store_prefs(profile_id)
      File.join(profile_store_root(profile_id), 'Prefs')
    end

    # ---- SketchUp.exe ------------------------------------------------------------------

    def su_exe_candidates
      [
        load_state['su_exe'].to_s,
        "C:\\Program Files\\SketchUp\\SketchUp #{su_year}\\SketchUp\\SketchUp.exe",
        "C:\\Program Files\\SketchUp\\SketchUp #{su_year}\\SketchUp.exe"
      ].reject(&:empty?)
    end

    def su_exe_path
      su_exe_candidates.find { |p| p.include?('SketchUp') && File.file?(p) }
    rescue StandardError
      nil
    end

    # ---- json ----------------------------------------------------------------------------

    def load_json(path, default)
      return default unless File.file?(path.to_s)

      raw = File.read(path, encoding: 'UTF-8')
      raw = raw.sub(/\A\xEF\xBB\xBF/, '')
      JSON.parse(raw)
    rescue JSON::ParserError, StandardError
      default
    end

    def save_json(path, obj)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(obj) + "\n", encoding: 'UTF-8')
      true
    end

    # ---- profiles.json --------------------------------------------------------------------

    def load_profiles
      data = load_json(profiles_json_path, {})
      data.is_a?(Hash) && data['profiles'].is_a?(Array) ? data : { 'profiles' => [] }
    end

    def save_profiles(data)
      save_json(profiles_json_path, data)
    end

    def profile_list
      load_profiles['profiles']
    end

    def find_profile(id)
      profile_list.find { |p| p['id'].to_s == id.to_s }
    end

    def profile_exists?(id)
      !find_profile(id).nil?
    end

    # ---- прогресс фоновых операций -------------------------------------------------------------
    # Фазовая сводка долгой операции: пишет фоновый поток (только данные, без
    # Sketchup API), читает главный поток (команда get_progress). Один активный
    # слот: диалог стартует операции последовательно, оверлей не пускает вторую.

    def progress_lock
      @progress_lock ||= Mutex.new
      @progress_lock.synchronize { yield }
    end

    def progress_start(action, id: '', phases: [])
      progress_lock do
        @progress = { 'action' => action.to_s, 'id' => id.to_s,
                      'phases' => Array(phases).map(&:to_s),
                      'current' => nil, 'started_at' => Time.now.to_i }
      end
      true
    end

    def progress_step(name)
      progress_lock { @progress['current'] = name.to_s if @progress }
      true
    end

    def progress_finish
      progress_lock { @progress = nil }
      true
    end

    def progress_snapshot
      progress_lock { @progress && @progress.dup }
    end

    def upsert_profile_meta(meta)
      data = load_profiles
      data['profiles'].reject! { |p| p['id'] == meta['id'] }
      data['profiles'] << meta
      data['profiles'].sort_by! { |p| p['id'] == MAIN_ID ? 0 : 1 }
      save_profiles(data)
    end

    # ---- state.json -------------------------------------------------------------------------

    def load_state
      s = load_json(state_json_path, {})
      s.is_a?(Hash) ? s : {}
    end

    def save_state(state)
      save_json(state_json_path, state)
    end

    # ---- статус --------------------------------------------------------------------------------

    def initialized?
      load_state['initialized_at'].to_i.positive?
    end

    def detect_active_profile
      load_state['active_profile'].to_s
    end

    # Имена элементов верхнего уровня каталога (без скрытых).
    def dir_children(path)
      return [] unless File.directory?(path.to_s)

      Dir.children(path).reject { |n| n.start_with?('.') }.sort
    end

    def extensions_count(profile_id)
      dir_children(profile_store_plugins(profile_id)).size
    rescue StandardError
      0
    end

    def state_payload
      profiles = profile_list.map do |p|
        pid = p['id'].to_s
        {
          'id' => pid,
          'name' => p['name'].to_s.empty? ? pid : p['name'].to_s,
          'description' => p['description'].to_s,
          'is_active' => false,
          'protected' => pid == MAIN_ID,
          'extensions_count' => File.directory?(profile_store_root(pid)) ? extensions_count(pid) : nil,
          'created_at' => p['created_at'],
          'last_launch' => p['last_launch']
        }
      end
      active = detect_active_profile
      profiles.each { |p| p['is_active'] = (p['id'] == active) }
      {
        'version' => VERSION,
        'store_version' => STORE_VERSION,
        'initialized' => initialized?,
        'active_profile' => active,
        'year' => su_year,
        'store_root' => store_root,
        'su_exe_found' => !su_exe_path.to_s.empty?,
        'profiles' => profiles,
        'job_result' => take_job_result
      }
    end

    # ---- валидация -------------------------------------------------------------------------------

    def validate_profile_id!(id)
      return if id.to_s =~ PROFILE_ID_RE

      raise "Некорректный id профиля «#{id}»: только строчные латинские буквы, цифры и _ (до 32 символов)"
    end

    def validate_initialized!
      raise 'Профили не инициализированы: сначала выполните инициализацию' unless initialized?
    end

    def validate_not_active!(id)
      raise 'Профиль сейчас активен — операция недоступна' if detect_active_profile == id.to_s
    end

    # Целостность клона хранилища после robocopy: все ожидаемые элементы
    # (источник минус excludes) на месте; у каждого dn1sup_*.rb, чья папка
    # была в источнике, папка есть и в клоне — иначе лоадер упадёт с LoadError
    # (require version/main) при следующем запуске профиля.
    def verify_profile_store!(src_plugins, dst_plugins, excludes)
      expected = dir_children(src_plugins) - Array(excludes).map(&:to_s)
      actual = dir_children(dst_plugins)
      missing = expected - actual
      unless missing.empty?
        raise "Клон профиля неполный: нет #{missing.size} эл.: #{missing.first(5).join(', ')}"
      end

      broken = actual.select do |name|
        next false unless name =~ /\Adn1sup_.+\.rb\z/i

        base = name.sub(/\.rb\z/i, '')
        File.directory?(File.join(src_plugins, base)) && !File.directory?(File.join(dst_plugins, base))
      end
      raise "Клон профиля битый: нет папки для #{broken.join(', ')}" unless broken.empty?

      true
    end

    # ---- список расширений профиля -----------------------------------------------------------------

    def list_extensions(profile_id)
      raise "Профиль «#{profile_id}» не найден" unless profile_exists?(profile_id)

      dir = profile_store_plugins(profile_id)
      children = dir_children(dir)
      used_dirs = []
      items = []
      children.each do |name|
        next unless name =~ /\.rb\z/i

        base = name.sub(/\.rb\z/i, '')
        dir_name = children.include?(base) && File.directory?(File.join(dir, base)) ? base : nil
        used_dirs << dir_name if dir_name
        items << extension_item(base, File.join(dir, name), dir_name ? File.join(dir, dir_name) : nil)
      end
      children.each do |name|
        next unless File.directory?(File.join(dir, name))
        next if used_dirs.include?(name)

        items << extension_item(name, nil, File.join(dir, name))
      end
      items
    end

    def extension_item(ext_id, rb_path, dir_path)
      version = ''
      display = ext_id
      if rb_path && File.file?(rb_path)
        content = begin
          File.read(rb_path, encoding: 'UTF-8', invalid: :replace, undef: :replace)
        rescue StandardError
          ''
        end
        if (m = content.match(/SketchupExtension\.new\(\s*['"]([^'"]+)['"]/))
          display = m[1]
        end
        if (m = content.match(/(?:extension|ext)\.version\s*=\s*['"]([^'"]+)['"]/i)) ||
           (m = content.match(/^\s*VERSION\s*=\s*['"]([^'"]+)['"]/))
          version = m[1]
        end
      end
      {
        'id' => ext_id,
        'name' => display,
        'version' => version,
        'kind' => extension_kind(ext_id),
        'has_rb' => !rb_path.nil?,
        'has_dir' => !dir_path.nil?
      }
    end

    def extension_kind(ext_id)
      name = ext_id.to_s
      return 'self' if name == ID
      return 'dn1sup' if name.start_with?('dn1sup_', 'dn1c_')

      'third_party'
    end

    # ---- зеркалирование в реальный Plugins (для активного профиля) -----------------------------------

    # Кладёт элемент (rb-файл или папку-junction) профиля в реальный Plugins.
    def mirror_item_to_real(profile_id, name)
      src = File.join(profile_store_plugins(profile_id), name)
      dst = File.join(real_plugins_dir, name)
      FileUtils.mkdir_p(real_plugins_dir)
      if File.file?(src)
        # remove_real_entry, а не rm_f: dst может быть каталогом или
        # (висячим) junction от прежней установки — rm_f на каталоге
        # падает с EISDIR.
        remove_real_entry(dst)
        FileUtils.cp(src, dst)
      elsif File.directory?(src)
        remove_real_entry(dst)
        # create_junction молча возвращает false при неудаче (mklink не
        # сработал) — дальше шёл бы полуклон: .rb без папки и модальные
        # ошибки при старте. Роняем операцию сразу с понятной причиной.
        raise "Не удалось подключить папку «#{name}» (junction #{dst} -> #{src})" unless Win.create_junction(dst, src)
      end
      true
    end

    # Удаляет элемент реального Plugins: junction снимается, реальный каталог/файл
    # удаляется. Обрабатывает и висячий junction (exist? за ним false).
    def remove_real_entry(path)
      return unless Win.fs_entry?(path.to_s)

      if Win.junction?(path)
        Win.remove_junction(path)
      elsif File.directory?(path)
        FileUtils.rm_rf(path)
      else
        FileUtils.rm_f(path)
      end
    end

    # ---- установка .rbz в профиль -------------------------------------------------------------------

    def install_rbz(profile_id, rbz_path)
      raise "Профиль «#{profile_id}» не найден" unless profile_exists?(profile_id)
      raise "Файл не найден: #{rbz_path}" unless File.file?(rbz_path.to_s)
      unless rbz_path.to_s =~ /\.(rbz|zip)\z/i
        raise 'Ожидался файл .rbz (или .zip с той же структурой)'
      end

      Dir.mktmpdir('sp_rbz') do |tmp|
        unless Win.zip_extract(rbz_path, tmp)
          raise "Не удалось распаковать архив: #{File.basename(rbz_path.to_s)}"
        end

        src = tmp
        children = Dir.children(src).reject { |n| n.start_with?('.') }
        if children.size == 1 && File.directory?(File.join(src, children.first)) &&
           Dir.children(File.join(src, children.first)).any? { |n| n =~ /\.rb\z/i }
          src = File.join(src, children.first)
        end
        unless Dir.children(src).any? { |n| n =~ /\.rb\z/i }
          raise 'В архиве нет .rb-файлов в корне — это не расширение SketchUp (.rbz)'
        end

        target = profile_store_plugins(profile_id)
        FileUtils.mkdir_p(target)
        installed = []
        Dir.children(src).each do |name|
          next if name.start_with?('.')

          from = File.join(src, name)
          to = File.join(target, name)
          remove_real_entry(to) if File.exist?(to) || Win.junction?(to)
          if File.directory?(from)
            FileUtils.cp_r(from, to)
          else
            FileUtils.cp(from, to)
          end
          installed << name
        end

        active = detect_active_profile == profile_id.to_s
        progress_step('mirror')
        installed.each { |name| mirror_item_to_real(profile_id, name) } if active

        { 'ok' => true, 'installed' => installed,
          'message' => if active
                         "Установлено в активный профиль (#{installed.size} эл.): загрузится при следующем запуске SketchUp. Профиль сохранён."
                       else
                         "Установлено в профиль «#{find_profile(profile_id)['name']}» (#{installed.size} эл.): загрузится при запуске этого профиля. Профиль сохранён."
                       end }
      end
    end

    # ---- удаление расширения из профиля ----------------------------------------------------------------

    def uninstall_extension(profile_id, ext_id)
      progress_start('uninstall_extension', id: ext_id.to_s, phases: %w[mirror delete])
      begin
        progress_step('mirror')
        raise "Профиль «#{profile_id}» не найден" unless profile_exists?(profile_id)
        unless ext_id.to_s =~ EXT_NAME_RE && !ext_id.to_s.include?('..')
          raise "Некорректное имя расширения: #{ext_id.inspect}"
        end
        if ext_id.to_s == ID
          raise 'Менеджер профилей нельзя удалить из профиля: без него нечем переключаться'
        end

        store_dir = profile_store_plugins(profile_id)
        rb = File.join(store_dir, "#{ext_id}.rb")
        sub = File.join(store_dir, ext_id.to_s)
        removed = []
        # зеркало в реальном Plugins снимаем ДО удаления хранилища: junction ещё
        # жив, после rm_rf хранилища он стал бы висячим
        if detect_active_profile == profile_id.to_s
          FileUtils.rm_f(File.join(real_plugins_dir, "#{ext_id}.rb"))
          remove_real_entry(File.join(real_plugins_dir, ext_id.to_s))
        end
        progress_step('delete')
        if File.file?(rb)
          FileUtils.rm_f(rb)
          removed << "#{ext_id}.rb"
        end
        if File.directory?(sub)
          FileUtils.rm_rf(sub)
          removed << ext_id.to_s
        end
        raise "Расширение «#{ext_id}» в профиле не найдено" if removed.empty?

        { 'ok' => true, 'removed' => removed,
          'message' => "Удалено из профиля «#{find_profile(profile_id)['name']}»: #{removed.join(', ')}#{detect_active_profile == profile_id.to_s ? '. Из меню исчезнет после перезапуска SketchUp.' : '.'}" }
      ensure
        progress_finish
      end
    end

    # ---- самоинъекция менеджера -----------------------------------------------------------------------

    def self_source
      plugins = plugins_root_of_current_session
      prod_rb = File.join(plugins, "#{ID}.rb")
      prod_dir = File.join(plugins, ID)
      if !plugins.empty? && File.file?(prod_rb) && (File.directory?(prod_dir) || Win.junction?(prod_dir))
        { 'rb' => prod_rb, 'dir' => prod_dir, 'rb_name' => "#{ID}.rb", 'dir_name' => ID }
      else
        own_dir = PLUGIN_DIR
        own_rb = File.join(File.dirname(own_dir), "#{File.basename(own_dir)}.rb")
        { 'rb' => own_rb, 'dir' => own_dir,
          'rb_name' => File.basename(own_rb), 'dir_name' => File.basename(own_dir) }
      end
    end

    # Кладёт менеджер в хранилище профиля (и в реальный Plugins, если профиль активен).
    def self_inject(profile_id)
      src = self_source
      raise 'Файлы менеджера не найдены для копирования' unless File.file?(src['rb']) && File.directory?(src['dir'])

      target = profile_store_plugins(profile_id)
      FileUtils.mkdir_p(target)
      dest_rb = File.join(target, src['rb_name'])
      dest_dir = File.join(target, src['dir_name'])
      FileUtils.rm_f(dest_rb)
      FileUtils.rm_rf(dest_dir)
      FileUtils.cp(src['rb'], dest_rb)
      FileUtils.mkdir_p(dest_dir)
      Dir.glob(File.join(src['dir'], '*')).each do |child|
        next if File.basename(child) == 'test'

        FileUtils.cp_r(child, File.join(dest_dir, File.basename(child)))
      end

      if detect_active_profile == profile_id.to_s
        mirror_item_to_real(profile_id, src['rb_name'])
        mirror_item_to_real(profile_id, src['dir_name'])
      end
      true
    end

    def sync_self_all
      active = detect_active_profile
      done = []
      skipped = []
      profile_list.map { |p| p['id'].to_s }.each do |pid|
        if pid == active
          skipped << pid # в активном уже работает текущая версия
          next
        end

        self_inject(pid)
        done << pid
      end
      msg = done.empty? ? 'Нет профилей для синхронизации.' : "Менеджер синхронизирован в профили: #{done.join(', ')}."
      msg += " Активный профиль «#{active}» пропущен (в нём работает текущая версия)." unless skipped.empty?
      { 'ok' => true, 'synced' => done, 'skipped' => skipped, 'message' => msg }
    end

    # ---- создание/удаление профилей (внутри хранилища) ---------------------------------------------------

    # Какие элементы верхнего уровня Plugins источника НЕ попадают в клон.
    def plan_plugins_excludes_for_dir(plugins_dir, include_patterns, exclude_patterns)
      return [] unless File.directory?(plugins_dir)

      inc = Array(include_patterns).map(&:to_s).reject(&:empty?)
      exc = Array(exclude_patterns).map(&:to_s).reject(&:empty?)
      dir_children(plugins_dir).select do |name|
        if inc.empty?
          exc.any? { |pat| File.fnmatch(pat, name, File::FNM_CASEFOLD) }
        else
          !inc.any? { |pat| File.fnmatch(pat, name, File::FNM_CASEFOLD) }
        end
      end
    end

    # Режимы создания профиля:
    #   clone — всё как в источнике (расширения + настройки интерфейса);
    #   clean — только менеджер профилей, настройки интерфейса с нуля.
    # («empty» оставлен как legacy-алиас clean: только менеджер.)
    CREATE_MODES = %w[clone clean].freeze

    def create_profile(id:, name:, description: '', source_id: nil, mode: 'clone')
      progress_start('create_profile', id: id.to_s, phases: %w[check copy prefs meta self])
      created_store = false
      created_meta = false
      begin
        progress_step('check')
        validate_initialized!
        validate_profile_id!(id)
        raise "Профиль «#{id}» уже существует" if profile_exists?(id)
        raise "Хранилище профиля уже есть на диске: #{profile_store_root(id)}" if File.directory?(profile_store_root(id))

        mode = mode.to_s.empty? ? 'clone' : mode.to_s
        mode = 'clean' if mode == 'empty'
        raise "Неизвестный режим создания «#{mode}» (clone/clean)" unless CREATE_MODES.include?(mode)

        source = source_id.to_s.empty? ? (detect_active_profile.empty? ? MAIN_ID : detect_active_profile) : source_id.to_s
        raise "Источник «#{source}» не найден" unless profile_exists?(source)
        src_plugins = profile_store_plugins(source)
        raise "Хранилище источника не найдено: #{src_plugins}" unless File.directory?(src_plugins)

        clean = (mode == 'clean')
        include_patterns = case mode
                           when 'clean' then clean_keep_patterns
                           else []
                           end
        excludes = plan_plugins_excludes_for_dir(src_plugins, include_patterns, [])
        dst_plugins = profile_store_plugins(id)
        progress_step('copy')
        ok = Win.robocopy(src_plugins, dst_plugins, exclude_names: excludes)
        raise 'Копирование профиля не удалось (robocopy)' unless ok
        created_store = true
        verify_profile_store!(src_plugins, dst_plugins, excludes)

        # настройки интерфейса наследуются от источника (кроме clean-профиля:
        # пустой Prefs → SketchUp при первом запуске сгенерирует дефолтный)
        progress_step('prefs')
        unless clean
          src_prefs = profile_store_prefs(source)
          if File.directory?(src_prefs)
            FileUtils.mkdir_p(profile_store_prefs(id))
            Dir.children(src_prefs).each { |f| FileUtils.cp(File.join(src_prefs, f), File.join(profile_store_prefs(id), f)) }
          end
        end

        progress_step('meta')
        upsert_profile_meta('id' => id.to_s, 'name' => name.to_s.empty? ? id.to_s : name.to_s,
                            'description' => description.to_s, 'protected' => false,
                            'created_at' => Time.now.to_i, 'last_launch' => nil)
        created_meta = true
        progress_step('self')
        self_inject(id)
        { 'ok' => true, 'id' => id.to_s, 'mode' => mode, 'excluded' => excludes,
          'message' => if clean
                         "Создан чистый профиль «#{name}»: только менеджер профилей, настройки интерфейса по умолчанию (#{extensions_count(id)} расширений). Профиль сохранён."
                       else
                         "Профиль «#{name}» создан на основе «#{source}»: #{extensions_count(id)} расширений. Профиль сохранён."
                       end }
      rescue StandardError, ScriptError
        rollback_profile_creation!(id, store: created_store, meta: created_meta)
        raise
      ensure
        progress_finish
      end
    end

    # Откат неудачного создания: удаляет только то, что создала сама
    # операция (флаги store/meta). Проверки до копирования (дубль id,
    # плохой режим, нет источника) ничего не создают — трогать существующие
    # данные запрещено.
    def rollback_profile_creation!(id, store: true, meta: true)
      id = id.to_s
      if store
        prefs_store = profile_store_prefs(id)
        FileUtils.rm_rf(prefs_store) if File.directory?(prefs_store)
        FileUtils.rm_rf(profile_store_root(id)) if File.directory?(profile_store_root(id))
      end
      if meta
        data = load_profiles
        if data['profiles'].any? { |p| p['id'].to_s == id }
          data['profiles'].reject! { |p| p['id'].to_s == id }
          save_profiles(data)
        end
      end
    rescue StandardError
      nil
    end

    def delete_profile(id)
      progress_start('delete_profile', id: id.to_s, phases: %w[delete backups meta])
      begin
        progress_step('delete')
        validate_initialized!
        raise 'Основной профиль удалить нельзя' if id.to_s == MAIN_ID
        raise "Профиль «#{id}» не найден" unless profile_exists?(id)
        validate_not_active!(id)

        FileUtils.rm_rf(profile_store_root(id))
        progress_step('backups')
        removed_backups = delete_profile_backups(id)
        progress_step('meta')
        data = load_profiles
        data['profiles'].reject! { |p| p['id'].to_s == id.to_s }
        save_profiles(data)
        swept = cleanup_orphan_backups
        message = "Профиль «#{id}» удалён."
        message += " Удалено снимков профиля: #{removed_backups}." if removed_backups.positive?
        message += " Удалено сиротских снимков: #{swept.size}." unless swept.empty?
        { 'ok' => true, 'removed_backups' => removed_backups, 'removed_orphans' => swept, 'message' => message }
      ensure
        progress_finish
      end
    end

    def update_profile_meta(id, name, description)
      p = find_profile(id)
      raise "Профиль «#{id}» не найден" unless p

      p['name'] = name.to_s unless name.to_s.empty?
      p['description'] = description.to_s
      upsert_profile_meta(p)
      { 'ok' => true, 'message' => 'Описание профиля обновлено.' }
    end

    # ---- снимки --------------------------------------------------------------------------------------------

    def backup_profile(id)
      progress_start('backup_profile', id: id.to_s, phases: %w[zip])
      begin
        progress_step('zip')
        raise "Профиль «#{id}» не найден" unless profile_exists?(id)

        root = profile_store_root(id)
        inner = %w[Plugins Prefs].select { |s| File.directory?(File.join(root, s)) }
        raise 'В профиле нет данных для снимка' if inner.empty?

        FileUtils.mkdir_p(backups_dir)
        out = File.join(backups_dir, "#{id}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.zip")
        raise 'Не удалось создать архив снимка' unless Win.zip_create(out, root, inner)

        cleanup_backups(id)
        { 'ok' => true, 'file' => File.basename(out), 'size' => File.size(out),
          'message' => "Снимок профиля «#{id}» создан: #{File.basename(out)}" }
      ensure
        progress_finish
      end
    end

    def list_backups
      return [] unless File.directory?(backups_dir)

      Dir.children(backups_dir)
         .select { |f| f =~ /\A[a-z0-9_]+-\d{8}-\d{6}\.zip\z/i }
         .sort.reverse
         .map do |f|
           full = File.join(backups_dir, f)
           { 'file' => f, 'profile' => f.sub(/-\d{8}-\d{6}\.zip\z/i, ''),
             'size' => File.size(full), 'mtime' => File.mtime(full).to_i }
         end
    end

    def cleanup_backups(profile_id)
      mine = list_backups.select { |b| b['profile'] == profile_id.to_s }
      mine.drop(BACKUPS_KEEP).each { |b| FileUtils.rm_f(File.join(backups_dir, b['file'])) }
    end

    # Снимки конкретного профиля (строгое равенство id — префиксы вроде
    # «test» не задевают «test_extra»). Возвращает число удалённых файлов.
    def delete_profile_backups(profile_id)
      pid = profile_id.to_s
      mine = list_backups.select { |b| b['profile'] == pid }
      mine.each { |b| FileUtils.rm_f(File.join(backups_dir, b['file'])) }
      mine.size
    rescue StandardError
      0
    end

    # Сиротские снимки — файлы, чей профиль уже отсутствует в profiles.json
    # (удалён раньше без чистки, стёрт вручную). Возвращает список удалённых имён.
    def cleanup_orphan_backups
      known = profile_list.map { |p| p['id'].to_s }
      orphans = list_backups.reject { |b| known.include?(b['profile']) }
      orphans.each { |b| FileUtils.rm_f(File.join(backups_dir, b['file'])) }
      orphans.map { |b| b['file'] }
    rescue StandardError
      []
    end

    def delete_backup(filename)
      f = File.basename(filename.to_s)
      raise 'Некорректное имя снимка' unless f =~ /\A[a-z0-9_]+-\d{8}-\d{6}\.zip\z/i
      raise 'Снимок не найден' unless File.file?(File.join(backups_dir, f))

      FileUtils.rm_f(File.join(backups_dir, f))
      { 'ok' => true, 'message' => "Снимок #{f} удалён." }
    end

    def restore_backup(profile_id, filename)
      progress_start('restore_backup', id: profile_id.to_s, phases: %w[extract replace])
      begin
        progress_step('extract')
        raise "Профиль «#{profile_id}» не найден" unless profile_exists?(profile_id)
        validate_not_active!(profile_id)
        f = File.basename(filename.to_s)
        raise 'Некорректное имя снимка' unless f =~ /\A[a-z0-9_]+-\d{8}-\d{6}\.zip\z/i
        full = File.join(backups_dir, f)
        raise 'Снимок не найден' unless File.file?(full)

        Dir.mktmpdir('sp_restore') do |tmp|
          raise 'Не удалось распаковать снимок' unless Win.zip_extract(full, tmp)
          unless Dir.children(tmp).any? { |n| %w[Plugins Prefs].include?(n) }
            raise 'В снимке нет данных профиля (ожидались каталоги Plugins/Prefs)'
          end

          progress_step('replace')
          root = profile_store_root(profile_id)
          FileUtils.rm_rf(root)
          FileUtils.mkdir_p(root)
          %w[Plugins Prefs].each do |side|
            src = File.join(tmp, side)
            FileUtils.cp_r(src, File.join(root, side)) if File.directory?(src)
          end
        end
        { 'ok' => true, 'message' => "Профиль «#{profile_id}» восстановлен из снимка #{f}." }
      ensure
        progress_finish
      end
    end

    # ---- хелпер: job / запуск / результат ---------------------------------------------------------------------

    def stage_helper!
      raise "Хелпер не найден: #{helper_src_path}" unless File.file?(helper_src_path)

      FileUtils.mkdir_p(store_root)
      return true if File.file?(helper_staged_path) &&
                     File.read(helper_staged_path, encoding: 'UTF-8') == File.read(helper_src_path, encoding: 'UTF-8')

      FileUtils.cp(helper_src_path, helper_staged_path)
      true
    end

    def current_pid
      Process.pid
    end

    def strict_solo_flag
      true
    end

    def launch_helper_process(cmdline)
      Win.hidden_run(cmdline)
    end

    def launch_helper(job)
      stage_helper!
      save_json(pending_job_path, job)
      cmdline = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' \
                "-File \"#{Win.to_win(helper_staged_path)}\" -JobPath \"#{Win.to_win(pending_job_path)}\""
      raise 'Не удалось запустить внешний хелпер (PowerShell)' unless launch_helper_process(cmdline)

      true
    end

    def common_job_fields
      {
        'created_at' => Time.now.to_i,
        'wait_pid' => current_pid,
        'wait_timeout_sec' => 300,
        'relaunch' => true,
        'strict_solo' => strict_solo_flag,
        'su_exe' => su_exe_path,
        'store_root' => store_root,
        'state_path' => state_json_path,
        'profiles_path' => profiles_json_path,
        'year' => su_year,
        'real_plugins' => real_plugins_dir,
        'prefs_roaming' => prefs_roaming_path,
        'prefs_local' => prefs_local_path,
        'self' => self_source
      }
    end

    # ---- первичная инициализация ----------------------------------------------------------------------------------

    def main_meta
      { 'id' => MAIN_ID, 'name' => 'Основной',
        'description' => 'Все расширения и настройки на момент разделения профилей',
        'protected' => true, 'created_at' => Time.now.to_i, 'last_launch' => nil }
    end

    def prepare_migration
      raise 'Профили уже инициализированы' if initialized?

      year = validate_su_year!
      raise "Каталог Plugins не найден: #{real_plugins_dir}" unless File.directory?(real_plugins_dir)

      meta = { 'store_version' => STORE_VERSION, 'profiles' => [main_meta] }
      save_profiles(meta)

      main_store = profile_store_root(MAIN_ID)
      raise "Хранилище «Основного» уже существует: #{main_store}" if File.directory?(main_store)

      job = common_job_fields.merge(
        'kind' => 'migrate',
        'target_profile' => MAIN_ID,
        'store_main_plugins' => profile_store_plugins(MAIN_ID),
        'store_main_prefs' => profile_store_prefs(MAIN_ID),
        'create_profiles' => []
      )
      launch_helper(job)
      { 'ok' => true, 'quitting' => true,
        'message' => 'Инициализация запущена: SketchUp закроется, данные станут профилем «Основной», SketchUp перезапустится.' }
    end

    # ---- переключение профиля ---------------------------------------------------------------------------------------

    def switch_profile(id)
      validate_initialized!
      raise "Профиль «#{id}» не найден" unless profile_exists?(id)
      active = detect_active_profile
      raise 'Этот профиль уже активен' if active == id.to_s

      target_store = profile_store_plugins(id)
      raise "Хранилище профиля не найдено: #{target_store}" unless File.directory?(target_store)

      job = common_job_fields.merge(
        'kind' => 'switch',
        'from_profile' => active,
        'target_profile' => id.to_s,
        'store_from_plugins' => active.empty? ? nil : profile_store_plugins(active),
        'store_from_prefs' => active.empty? ? nil : profile_store_prefs(active),
        'store_to_plugins' => target_store,
        'store_to_prefs' => profile_store_prefs(id)
      )
      launch_helper(job)
      { 'ok' => true, 'quitting' => true,
        'message' => "Переключение на «#{find_profile(id)['name']}»: SketchUp закроется и перезапустится с профилем." }
    end

    # ---- результат последнего запуска хелпера -------------------------------------------------------------------------

    def take_job_result
      res = load_json(job_result_path, nil)
      if res.is_a?(Hash)
        FileUtils.rm_f(job_result_path)
        FileUtils.rm_f(pending_job_path) if res['ok']
      end
      res
    end
  end
end
