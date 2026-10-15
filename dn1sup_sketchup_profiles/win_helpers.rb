# frozen_string_literal: true

# =============================================================================
# dn1sup_sketchup_profiles/win_helpers.rb — Windows-примитивы ядра профилей:
# junction-операции, robocopy, zip через tar (bsdtar), скрытый запуск внешних
# процессов. Всё проверено пробой test/probe_win.rb на живой машине.
#
# Особенности (важно):
#  * cmd.exe получает команды ЕДИНОЙ СТРОКОЙ с ОБРАТНЫМИ слэшами: раздельные
#    аргументы/прямые слэши cmd трактует как свои ключи («Недопустимый ключ»).
#  * junction-детекция — сравнением File.realpath с исходным путём (реальные
#    каталоги realpath не меняет; junction — резолвится в цель). Висячий
#    junction (цель удалена) распознаётся по отказу realpath при живой записи
#    в родительском каталоге — см. fs_entry?/junction?.
#  * скрытый запуск (без моргания консоли) — WScript.Shell.Run(cmd, 0):
#    GUI-подсистема wscript, консольному ребёнку прячется окно.
#    spawn/system/backticks запрещены — моргают консолью. Синхронный вариант
#    hidden_wait_exit возвращает exit-код, hidden_capture_out — [вывод, код].
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1sup
  module SketchupProfiles
    module Win
      WINDOWS = RUBY_PLATFORM =~ /mingw|mswin|cygwin/ ? true : false

      module_function

      def windows?
        WINDOWS
      end

      # Обратные слэши для cmd/robocopy-команд.
      def to_win(path)
        path.to_s.tr('/', '\\')
      end

      # -- junction -----------------------------------------------------------------

      # Элемент «на месте» (или висячая ссылка): File.exist? следует за целью и
      # возвращает false для junction/symlink с несуществующей целью — а такая
      # запись числится в родительском каталоге и её надо уметь удалять.
      def fs_entry?(path)
        return false if path.to_s.empty?
        return true if File.exist?(path.to_s)

        parent = File.dirname(path.to_s)
        File.directory?(parent) && Dir.children(parent).include?(File.basename(path.to_s))
      rescue StandardError
        false
      end

      def junction?(path)
        return false unless windows? && fs_entry?(path.to_s)

        norm = ->(p) { to_win(p).downcase.sub(%r{[\\/]+\z}, '') }
        begin
          norm.call(File.realpath(path)) != norm.call(File.expand_path(path))
        rescue Errno::ENOENT, StandardError
          true # запись есть, realpath не резолвится — битая ссылка (junction без цели)
        end
      end

      # Цель junction (реальный каталог) либо nil для реального каталога.
      def junction_target(path)
        return nil unless junction?(path)

        File.realpath(path)
      rescue StandardError
        nil
      end

      def create_junction(point, target)
        return false unless windows?
        return false if fs_entry?(point.to_s)
        return false unless File.directory?(target.to_s)

        hidden_wait_exit("cmd.exe /c mklink /J \"#{to_win(point)}\" \"#{to_win(target)}\"")
        File.directory?(point.to_s)
      rescue StandardError
        false
      end

      # Удаляет ТОЛЬКО junction (точку связи): Dir.rmdir снимает reparse-point
      # без захода в цель (проверено probe_win.rb) — внешнего процесса вообще
      # нет, окно консоли не моргает. cmd rmdir — только фолбэк, скрыто.
      def remove_junction(point)
        return false unless junction?(point)

        begin
          Dir.rmdir(point.to_s)
          return !File.exist?(point.to_s)
        rescue SystemCallError, StandardError
          # ниже — скрытый cmd-фолбэк
        end
        hidden_wait_exit("cmd.exe /c rmdir \"#{to_win(point)}\"")
        !File.exist?(point.to_s)
      rescue StandardError
        false
      end

      # -- копирование --------------------------------------------------------------

      # robocopy src → dst (рекурсивно). exclude_names — имена элементов ВЕРХНЕГО
      # уровня src, которые не копируются (файлы и каталоги различаются по типу
      # в источнике). Возврат true при exit-коде < 8 (robocopy: 0..7 — успех).
      def robocopy(src, dst, exclude_names: [])
        return false unless windows?
        return false unless File.directory?(src.to_s)

        FileUtils.mkdir_p(dst.to_s)
        ex_files = []
        ex_dirs = []
        Array(exclude_names).each do |name|
          next if name.to_s.empty?

          child = File.join(src, name.to_s)
          # Имена верхнего уровня: файл — точно /XF; остальное — /XD по имени
          # (robocopy матчит имя каталога на любой глубине: «Plugins» и т.п.).
          if File.file?(child)
            ex_files << name.to_s
          else
            ex_dirs << name.to_s
          end
        end

        args = ['robocopy.exe', to_win(src), to_win(dst), '/E', '/R:1', '/W:1',
                '/NFL', '/NDL', '/NJH', '/NJS', '/NP']
        args += ['/XD', *ex_dirs.map { |d| to_win(d) }] unless ex_dirs.empty?
        args += ['/XF', *ex_files.map { |f| to_win(f) }] unless ex_files.empty?

        # spawn/system моргают консольным окном — запускаем скрыто через
        # WScript.Shell.Run(..., 0, true), код выхода возвращает сам Run.
        exitcode = hidden_wait_exit(cmdline_join(args))
        !exitcode.nil? && exitcode.to_i < 8
      rescue StandardError
        false
      end

      # -- zip (bsdtar из состава Windows) ------------------------------------------

      # Создать zip: внутрь попадают inner_names относительно chdir.
      # tar -a сам выбирает формат по расширению .zip.
      def zip_create(out_zip, chdir, inner_names)
        return false unless windows?

        FileUtils.mkdir_p(File.dirname(out_zip))
        names = Array(inner_names).map { |n| to_win(n) }
        return false if names.empty?

        # system() моргает консолью — скрытый запуск, успех по exit-коду.
        exitcode = hidden_wait_exit("tar.exe -a -cf \"#{to_win(out_zip)}\" -C \"#{to_win(chdir)}\" #{names.map { |n| "\"#{n}\"" }.join(' ')}")
        exitcode.to_i.zero? && File.file?(out_zip.to_s)
      rescue StandardError
        false
      end

      def zip_extract(zip_path, dest)
        return false unless windows? && File.file?(zip_path.to_s)

        # Успех проверяем по exit-коду tar: dest создаётся mkdir_p заранее,
        # поэтому только наличие папки маскировало частичную распаковку
        # битого архива.
        FileUtils.mkdir_p(dest.to_s)
        exitcode = hidden_wait_exit("tar.exe -xf \"#{to_win(zip_path)}\" -C \"#{to_win(dest)}\"")
        File.directory?(dest.to_s) && exitcode.to_i.zero?
      rescue StandardError
        false
      end

      # -- процессы (всё скрыто, без моргания консоли) -------------------------------

      # Сборка командной строки из массива: каждый аргумент с пробелами/
      # кавычками — в двойных кавычках (для WScript.Shell.Run одной строкой).
      def cmdline_join(args)
        Array(args).map do |a|
          s = a.to_s
          s.match?(/[\s"]/) ? "\"#{s.gsub('"', '""')}\"" : s
        end.join(' ')
      end

      # Скрытый синхронный запуск (без окна консоли): WScript.Shell.Run(cmd, 0).
      # Возвращает exit-код процесса либо nil при неудаче запуска.
      def hidden_wait_exit(cmdline)
        return nil unless windows?

        require 'win32ole'
        shell = WIN32OLE.new('WScript.Shell')
        shell.Run(cmdline.to_s, 0, true)
      rescue StandardError
        nil
      end

      # Скрытый запуск с перехватом stdout+stderr через временный файл
      # (WScript.Run вывод не возвращает; перенаправляет cmd.exe).
      # Возвращает [текст, exit-код].
      def hidden_capture_out(cmdline)
        return ['', nil] unless windows?

        Dir.mktmpdir('sp_cap') do |tmp|
          out_file = File.join(tmp, 'out.txt')
          wrapped = "cmd.exe /c #{cmdline} > \"#{to_win(out_file)}\" 2>&1"
          exitcode = hidden_wait_exit(wrapped)
          # Вывод консольных программ — в OEM-кодировке (CP866 на RU-Windows):
          # читаем как бинарный и чистим до валидного UTF-8, иначе regex
          # падает с ArgumentError (invalid byte sequence).
          text = File.file?(out_file) ? File.binread(out_file).force_encoding('UTF-8').scrub : ''
          return [text, exitcode]
        end
      rescue StandardError
        ['', nil]
      end

      # Скрытый запуск командной строки (без окна консоли): WScript.Shell.Run.
      # Требует win32ole (есть в SketchUp Ruby). fire-and-forget — без PID,
      # результат процесс пишет в свои файлы.
      def hidden_run(cmdline)
        return false unless windows?

        require 'win32ole'
        shell = WIN32OLE.new('WScript.Shell')
        shell.Run(cmdline, 0, false)
        true
      rescue StandardError
        false
      end

      # Жив ли процесс с данным PID (tasklist, только Windows).
      # Backticks здесь запрещены — моргают консолью; вывод через temp-файл.
      # Проверка локаль-независимая: в строке процесса есть "<имя>.exe <pid>",
      # при отсутствии — строка INFO/ИНФОРМАЦИЯ. Заголовок tasklist локализован,
      # поэтому по нему не матчим.
      def process_alive?(pid)
        return false unless windows? && pid.to_i.positive?

        out, _code = hidden_capture_out("tasklist /FI \"PID eq #{pid.to_i}\"")
        out = out.to_s
        out.match?(/\.exe\s+#{pid.to_i}\b/i)
      rescue StandardError
        false
      end
    end
  end
end
