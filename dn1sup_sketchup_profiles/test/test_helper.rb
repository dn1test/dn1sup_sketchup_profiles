# frozen_string_literal: true
# =============================================================================
# dn1sup_sketchup_profiles/test/test_helper.rb — мини-харнесс тестов
# «DN1Sup SketchUp Profiles» (шаблон sketchup-dev-mcp).
#
#   • внутри SketchUp — запуск через ext_test MCP-сервера sketchup-dev;
#   • в обычном Ruby — ruby test/profiles_test.rb (модельные части в skip).
# =============================================================================

# Локальный запуск вне SketchUp (plain `ruby test/profiles_test.rb`):
# минимальные заглушки SketchUp API, чтобы main.rb загрузился (аналог
# tools/test_stub в dn1sup_comp_add_view, но инлайн). Внутри живого
# SketchUp (Sketchup определён) заглушки не подключаются никогда.
# Объектов модели нет: Sketchup.active_model возвращает nil, и тесты,
# требующие живого SketchUp, уходят в skip («вне SketchUp: нет активной
# модели»). Маркер stubbed? отличает заглушку от настоящего API.
unless defined?(Sketchup)
  module Sketchup
    def self.require(path)
      file = path.to_s
      file += '.rb' unless File.extname(file) == '.rb'
      return Kernel.require(file) if File.file?(file)

      Kernel.require(path.to_s)
    end

    def self.find_support_file(_name)
      nil
    end

    def self.active_model
      nil
    end

    def self.stubbed?
      true
    end
  end

  module UI
    MB_OK = 0
    MB_YESNO = 4
    IDYES = 6
    IDNO = 7

    class Command
      def initialize(_name, &_block); end

      %w[menu_text tooltip status_bar_text small_icon large_icon].each do |a|
        define_method("#{a}=") { |_v| self }
      end
    end

    class Toolbar
      def initialize(_name); end
      def any?(*); false; end
      def add_item(*); self; end
      def restore(*); self; end
    end

    class Menu
      def add_submenu(*); self; end
      def add_item(*); self; end
      def add_separator(*); self; end
    end

    def self.menu(_name)
      @menu ||= Menu.new
    end

    def self.messagebox(*)
      IDNO
    end

    # Таймеры не исполняются: single-shot в main.rb (проверка обновлений)
    # не должен ходить в сеть из plain-ruby прогона.
    def self.start_timer(*)
      0
    end

    def self.stop_timer(*); end
  end

  IDYES = 6 unless defined?(IDYES)
  IDNO = 7 unless defined?(IDNO)
  MB_OK = 0 unless defined?(MB_OK)
  MB_YESNO = 4 unless defined?(MB_YESNO)

  $dn1sup_stub_loaded_files ||= {}

  def file_loaded?(path)
    $dn1sup_stub_loaded_files[path.to_s] ? true : false
  end

  def file_loaded(path)
    $dn1sup_stub_loaded_files[path.to_s] = true
  end
end

require_relative '../main' unless defined?(Dn1sup::SketchupProfiles::VERSION)

module Dn1sup
  module SketchupProfiles
    module Test
      class Failure < StandardError; end
      class Skip    < StandardError; end

      @tests = []

      class << self
        attr_reader :tests

        def test(name, &block)
          @tests << [name, block]
        end

        def assert(condition, msg = 'утверждение ложно')
          raise Failure, msg unless condition
        end

        def assert_equal(expected, actual, msg = nil)
          return if expected == actual

          raise Failure, "#{msg ? "#{msg}: " : ''}ожидали #{expected.inspect}, получили #{actual.inspect}"
        end

        def assert_raises(*klasses)
          yield
          raise Failure, "ожидали исключение #{klasses.map(&:inspect).join('|')}, но блок завершился без ошибок"
        rescue Failure
          raise
        rescue StandardError => e
          assert(klasses.any? { |k| e.is_a?(k) },
                 "ожидали #{klasses.map(&:inspect).join('|')}, получили #{e.class}: #{e.message}")
        end

        def skip(reason = 'пропуск')
          raise Skip, reason
        end

        def run!
          results = { 'total' => @tests.size, 'failures' => [], 'skipped' => [] }
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @tests.each do |name, block|
            begin
              block.call
            rescue Skip => e
              results['skipped'] << { 'name' => name, 'reason' => e.message }
            rescue Failure => e
              results['failures'] << { 'name' => name, 'error' => e.message }
            rescue Exception => e # rubocop:disable Lint/RescueException
              results['failures'] << { 'name' => name, 'error' => "#{e.class}: #{e.message}",
                                       'backtrace' => Array(e.backtrace).first(5) }
            end
          end
          results['duration_ms'] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          results['passed'] = results['total'] - results['failures'].size - results['skipped'].size
          reset!
          results
        end

        def reset!
          @tests = []
        end
      end
    end
  end
end
