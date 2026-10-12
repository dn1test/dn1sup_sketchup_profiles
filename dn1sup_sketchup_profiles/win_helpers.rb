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
# =============================================================================

require 'fileutils'

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

        system("cmd.exe /c mklink /J \"#{to_win(point)}\" \"#{to_win(target)}\"")
        File.directory?(point.to_s)
      rescue StandardError
        false
      end

      # Удаляет ТОЛЬКО junction (точку связи): [IO.Directory]::Delete(path,false)
      # через cmd rmdir не заходит в цель. Вызов безопасен только после
      # junction? — реальный каталог не трогаем никогда.
      def remove_junction(point)
        return false unless junction?(point)

        system("cmd.exe /c rmdir \"#{to_win(point)}\"")
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

        pid = spawn(*args)
        Process.wait(pid)
        $?.exitstatus.to_i < 8
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

        system("tar.exe -a -cf \"#{to_win(out_zip)}\" -C \"#{to_win(chdir)}\" #{names.map { |n| "\"#{n}\"" }.join(' ')}")
        File.file?(out_zip.to_s)
      rescue StandardError
        false
      end

      def zip_extract(zip_path, dest)
        return false unless windows? && File.file?(zip_path.to_s)

        FileUtils.mkdir_p(dest.to_s)
        system("tar.exe -xf \"#{to_win(zip_path)}\" -C \"#{to_win(dest)}\"")
        File.directory?(dest.to_s)
      rescue StandardError
        false
      end

      # -- процессы -------------------------------------------------------------------

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
      def process_alive?(pid)
        return false unless windows? && pid.to_i.positive?

        out = `tasklist /FI "PID eq #{pid.to_i}" 2>nul`.to_s
        out.match?(/\A\s*Image Name/) && out.include?(pid.to_i.to_s)
      rescue StandardError
        false
      end
    end
  end
end
