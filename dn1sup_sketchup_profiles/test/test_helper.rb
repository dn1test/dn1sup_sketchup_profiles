# frozen_string_literal: true
# =============================================================================
# dn1sup_sketchup_profiles/test/test_helper.rb — мини-харнесс тестов
# «DN1Sup SketchUp Profiles» (шаблон sketchup-dev-mcp).
#
#   • внутри SketchUp — запуск через ext_test MCP-сервера sketchup-dev;
#   • в обычном Ruby — ruby test/profiles_test.rb (модельные части в skip).
# =============================================================================

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
