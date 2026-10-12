# frozen_string_literal: true

begin
  require 'sketchup.rb'
rescue LoadError
  # Вне SketchUp (smoke-тесты)
end
require 'json'
require 'fileutils'
# Апдейтер — из папки расширения (PLUGIN_DIR-относительный путь): в dev-варианте
# (<id>_dev/) иначе загрузился бы апдейтер прод-установки из Plugins/<id>/.
Sketchup.require File.join(File.dirname(__FILE__), 'dn1sup_updater')
Sketchup.require File.join(File.dirname(__FILE__), 'profile_core')
# win_helpers загружается profile_core через require_relative.

module Dn1sup
  def self.common_menu
    @common_menu ||= begin
      legacy = (defined?($dn1sup_common_menu) && $dn1sup_common_menu) || (defined?($dn1sup_menu) && $dn1sup_menu)
      legacy || UI.menu('Extensions').add_submenu('DN1Sup')
    end
  end

  module SketchupProfiles
    # Константы ID / VERSION / PLUGIN_DIR — в profile_core.rb.
    REPO        = 'dn1test/dn1sup_sketchup_profiles'
    ASSET       = "#{ID}.rbz"
    HTML_PATH   = File.join(PLUGIN_DIR, 'html', 'index.html').freeze
    ICON_DIR    = File.join(PLUGIN_DIR, 'icons').freeze
    TOOLBAR_NAME = 'DN1Sup SketchUp Profiles'
    CMD_TOOLTIP = 'DN1Sup Профили SketchUp — переключение профилей, установка расширений в профиль'

    @dialog = nil

    module_function

    # Папка Plugins фиксируется на главном потоке: фоновые операции (defer_async)
    # не имеют права вызывать Sketchup API (в т.ч. find_support_file).
    def capture_session_paths!
      Core.plugins_root_of_current_session = begin
        defined?(Sketchup) && Sketchup.respond_to?(:find_support_file) ? Sketchup.find_support_file('Plugins').to_s : ''
      end
    end

    # Ядро вынесено в константу для коротких обращений (и подмены в тестах).
    Core = SketchupProfiles

    def log(message)
      Dn1sup::Updater.log_info("Profiles: #{message}")
    end

    # ---- HtmlDialog --------------------------------------------------------------

    def open_dialog
      capture_session_paths!
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      unless File.file?(HTML_PATH)
        UI.messagebox("HTML-интерфейс не найден: #{HTML_PATH}", MB_OK) if defined?(UI)
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title:    'DN1Sup Профили SketchUp',
        preferences_key: 'dn1sup_sketchup_profiles_window',
        scrollable:      true,
        resizable:       true,
        width:           880,
        height:          640,
        left:            160,
        top:             120,
        min_width:       620,
        min_height:      440
      )
      @dialog.set_file(HTML_PATH)
      register_callbacks(@dialog)
      @dialog.show
      log("диалог открыт (v#{VERSION})")
    end

    def register_callbacks(dlg)
      dlg.add_action_callback('call_ruby') do |_context, name, param|
        dispatch(dlg, name.to_s, param.to_s)
      end
    end

    # ---- пуш в диалог --------------------------------------------------------------

    def push_state(dlg = @dialog)
      return unless dlg

      payload = Core.state_payload
      dlg.execute_script("window.pushState(#{JSON.generate(payload)});")
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    def push_result(dlg, kind, payload)
      return unless dlg

      dlg.execute_script("window.pushResult(#{JSON.generate(kind)}, #{JSON.generate(payload || {})});")
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    def notify_result(dlg, action, res, id = nil)
      push_result(dlg, 'action_result',
                  'id' => id.to_s, 'action' => action.to_s,
                  'ok' => !!(res && res['ok']),
                  'message' => res && res['message'],
                  'error' => res && res['error'])
    end

    # Тяжёлая файловая операция — в фоне (defer_async: сеть/файлы в потоке,
    # результат — на главном потоке). Ядро Sketchup API не трогает.
    def run_async(dlg, action, id = nil)
      Dn1sup::Updater.defer_async(
        lambda { yield },
        lambda do |res|
          res ||= { 'ok' => false, 'error' => 'Операция не выполнена (см. лог)' }
          notify_result(dlg, action, res, id)
          push_state(dlg)
        end
      )
    end

    # ---- закрытие SketchUp после запуска хелпера -----------------------------------

    def schedule_quit(dlg, res)
      push_result(dlg, 'quitting', 'message' => res['message'])
      log('хелпер запущен — закрываю SketchUp')
      UI.start_timer(0.8, false) { Sketchup.quit }
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    # ---- диспетчер команд (единый колбэк 'call_ruby') -------------------------------

    def dispatch(dlg, name, param)
      data = parse_json(param)
      log("команда '#{name}'#{data['id'] && !data['id'].to_s.empty? ? " (#{data['id']})" : ''}")
      case name
      when 'ready', 'get_state'
        inject_error_hook(dlg)
        push_state(dlg)
      when 'get_extensions'
        id = data['profile'].to_s
        items = begin
          Core.list_extensions(id)
        rescue StandardError => e
          Dn1sup::Updater.log_error(e)
          []
        end
        push_result(dlg, 'extensions', 'profile' => id, 'items' => items)
      when 'get_backups'
        push_result(dlg, 'backups', 'items' => Core.list_backups)
      when 'begin_migration'
        create = Array(data['create']).map(&:to_s)
        extras = create.map { |c| c == 'dev' ? 'Разработка' : 'Черчение' }.join(', ')
        msg = "Инициализация профилей SketchUp.\n\n" \
              "Текущие данные (расширения, настройки интерфейса) станут профилем «Основной» — " \
              "ничего не потеряется и не изменится.\n" \
              "SketchUp закроется и перезапустится автоматически.\n" \
              "#{'Дополнительно будут созданы профили: ' + extras + ".\n" unless extras.empty?}" \
              'Продолжить?'
        if UI.messagebox(msg, MB_YESNO) == IDYES
          res = begin
            Core.prepare_migration(create_ids: create)
          rescue StandardError => e
            { 'ok' => false, 'error' => e.message }
          end
          if res['ok']
            notify_result(dlg, 'begin_migration', res)
            schedule_quit(dlg, res)
          else
            notify_result(dlg, 'begin_migration', res)
          end
        else
          notify_result(dlg, 'begin_migration', { 'ok' => false, 'error' => 'Отменено пользователем' })
        end
      when 'switch_profile'
        id = data['id'].to_s
        p = Core.find_profile(id)
        unless p
          notify_result(dlg, 'switch_profile', { 'ok' => false, 'error' => "Профиль «#{id}» не найден" }, id)
          return
        end
        msg = "Переключиться на профиль «#{p['name']}»?\n\n" \
              "SketchUp закроется и перезапустится уже с этим профилем " \
              '(его расширения и настройки интерфейса). ' \
              "Несохранённые модели SketchUp предложит сохранить.\n\nПродолжить?"
        if UI.messagebox(msg, MB_YESNO) == IDYES
          res = begin
            Core.switch_profile(id)
          rescue StandardError => e
            { 'ok' => false, 'error' => e.message }
          end
          if res['ok']
            notify_result(dlg, 'switch_profile', res, id)
            schedule_quit(dlg, res)
          else
            notify_result(dlg, 'switch_profile', res, id)
          end
        else
          notify_result(dlg, 'switch_profile', { 'ok' => false, 'error' => 'Отменено пользователем' }, id)
        end
      when 'create_profile'
        run_async(dlg, 'create_profile', data['id']) do
          Core.create_profile(id: data['id'], name: data['name'], description: data['description'],
                              source_id: data['source'],
                              include: Array(data['include']), exclude: Array(data['exclude']))
        end
      when 'rename_profile'
        res = begin
          Core.update_profile_meta(data['id'], data['name'], data['description'])
        rescue StandardError => e
          { 'ok' => false, 'error' => e.message }
        end
        notify_result(dlg, 'rename_profile', res, data['id'])
        push_state(dlg)
      when 'delete_profile'
        id = data['id'].to_s
        p = Core.find_profile(id)
        if p && UI.messagebox("Удалить профиль «#{p['name']}» вместе со всеми его расширениями и настройками?", MB_YESNO) == IDYES
          run_async(dlg, 'delete_profile', id) { Core.delete_profile(id) }
        else
          notify_result(dlg, 'delete_profile', { 'ok' => false, 'error' => 'Отменено' }, id)
        end
      when 'install_rbz'
        profile = data['profile'].to_s
        path = UI.openpanel('Выберите расширение для установки (.rbz)', '', 'Расширения SketchUp|*.rbz||')
        if path.to_s.empty?
          notify_result(dlg, 'install_rbz', { 'ok' => false, 'error' => 'Файл не выбран' }, profile)
        else
          run_async(dlg, 'install_rbz', profile) { Core.install_rbz(profile, path) }
        end
      when 'uninstall_extension'
        profile = data['profile'].to_s
        ext = data['ext'].to_s
        if UI.messagebox("Удалить расширение «#{ext}» из профиля «#{Core.find_profile(profile)&.fetch('name', profile)}»?", MB_YESNO) == IDYES
          run_async(dlg, 'uninstall_extension', ext) { Core.uninstall_extension(profile, ext) }
        else
          notify_result(dlg, 'uninstall_extension', { 'ok' => false, 'error' => 'Отменено' }, ext)
        end
      when 'backup_profile'
        run_async(dlg, 'backup_profile', data['id']) { Core.backup_profile(data['id']) }
      when 'restore_backup'
        id = data['id'].to_s
        file = data['file'].to_s
        if UI.messagebox("Восстановить профиль «#{Core.find_profile(id)&.fetch('name', id)}» из снимка #{file}?\n" \
                         'Текущее содержимое профиля будет заменено.', MB_YESNO) == IDYES
          run_async(dlg, 'restore_backup', id) { Core.restore_backup(id, file) }
        else
          notify_result(dlg, 'restore_backup', { 'ok' => false, 'error' => 'Отменено' }, id)
        end
      when 'delete_backup'
        res = begin
          Core.delete_backup(data['file'])
        rescue StandardError => e
          { 'ok' => false, 'error' => e.message }
        end
        notify_result(dlg, 'delete_backup', res)
        push_result(dlg, 'backups', 'items' => Core.list_backups)
      when 'sync_self'
        run_async(dlg, 'sync_self') { Core.sync_self_all }
      when 'log_js_error'
        log_js_error(param)
      else
        Dn1sup::Updater.log_error(RuntimeError.new("Неизвестная команда диалога: #{name}"))
      end
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      push_result(dlg, 'error', 'message' => "#{e.class}: #{e.message}")
    end

    def parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      {}
    end

    # ---- перехват ошибок JS (как в dn1sup_ext_manager) --------------------------------

    JS_ERROR_HOOK = <<~'JS'.freeze
      (function () {
        if (window.__dn1supErrorHook) { return; }
        window.__dn1supErrorHook = true;
        function report(payload) {
          try {
            var bridge = (typeof sketchup !== 'undefined' && sketchup) || window.sketchup;
            if (bridge && typeof bridge.call_ruby === 'function') {
              bridge.call_ruby('log_js_error', JSON.stringify(payload));
            }
          } catch (e) { }
        }
        window.addEventListener('error', function (event) {
          var err = event && event.error;
          report({
            message: err && err.message ? String(err.message) : String((event && event.message) || 'JS error'),
            source: String((event && event.filename) || ''),
            lineno: (event && event.lineno) || 0,
            stack: err && err.stack ? String(err.stack) : ''
          });
        });
        window.addEventListener('unhandledrejection', function (event) {
          var reason = event && event.reason;
          report({
            message: 'Unhandled rejection: ' + (reason && reason.message ? String(reason.message) : String(reason)),
            source: '',
            lineno: 0,
            stack: reason && reason.stack ? String(reason.stack) : ''
          });
        });
      })();
    JS

    def inject_error_hook(dlg)
      dlg.execute_script(JS_ERROR_HOOK)
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    def log_js_error(param)
      data = parse_json(param)
      message = "JS: #{data['message']}"
      source = [data['source'].to_s, data['lineno'].to_s].reject(&:empty?).join(':')
      message += " (#{source})" unless source.empty?
      Dn1sup::Updater.log_error(RuntimeError.new(message))
    rescue StandardError
      nil
    end

    # ---- UI: команда, меню, тулбар ------------------------------------------------------

    def profiles_command
      cmd = UI::Command.new('Профили SketchUp') { open_dialog }
      cmd.menu_text       = 'Профили SketchUp…'
      cmd.tooltip         = CMD_TOOLTIP
      cmd.status_bar_text = 'Профили SketchUp: переключение, расширения, снимки'
      cmd.small_icon      = icon_path
      cmd.large_icon      = icon_path
      cmd
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
      nil
    end

    # SVG-иконка поддерживается тулбарами начиная с SketchUp 2020.1; цель — 2026.
    def icon_path
      File.join(ICON_DIR, 'profiles.svg')
    end

    def setup_toolbar
      toolbar = UI::Toolbar.new(TOOLBAR_NAME)
      return if toolbar.any? { |c| c.respond_to?(:tooltip) && c.tooltip == CMD_TOOLTIP }

      cmd = profiles_command
      return unless cmd

      toolbar.add_item(cmd)
      toolbar.restore
    rescue StandardError => e
      Dn1sup::Updater.log_error(e)
    end

    unless file_loaded?(__FILE__)
      capture_session_paths!

      common = Dn1sup.common_menu
      menu = common.add_submenu('Профили SketchUp')
      menu.add_item(profiles_command)
      menu.add_item('Проверить обновления менеджера') do
        Dn1sup::Updater.check!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, force: true, async: true })
      end

      setup_toolbar

      timer_id = nil
      timer_id = UI.start_timer(25, false) do
        UI.stop_timer(timer_id) if timer_id
        Dn1sup::Updater.check!({ id: ID, repo: REPO, version: VERSION, asset: ASSET, async: true })
      end

      file_loaded(__FILE__)
    end
  end
end
