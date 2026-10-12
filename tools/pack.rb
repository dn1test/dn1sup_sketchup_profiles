#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/pack.rb — сборка .rbz-релиза из рабочей копии репозитория.
#
#   ruby tools/pack.rb
#
# Результат: dist/<id>-<version>.rbz со структурой SketchUp-плагина:
#   <id>.rb                    — loader-файл (корень архива)
#   <id>/                      — код расширения без dev-файлов
# dn1sup_updater.rb добавляется из shared/, версия в registry.json
# выравнивается по ext.version регистратора.
# ZIP собирается без внешних зависимостей (STORE-метод, zlib.crc32).

require 'fileutils'
require 'tmpdir'
require 'zlib'

CONFIG = {
  id:         'dn1sup_sketchup_profiles',
  loader:     'dn1sup_sketchup_profiles.rb',
  dir:        'dn1sup_sketchup_profiles',
  target_dir: 'dn1sup_sketchup_profiles'
}.freeze

EXCLUDE_FILES = %w[
  dev_updater.rb .sketchup_dev.json README.md README.MD
  .gitignore package.json package-lock.json CHANGELOG.md NOTES.md
].map(&:downcase).freeze

EXCLUDE_DIRS = %w[
  test tests archive dist frontend node_modules .git .zcode _old _tmp
].map(&:downcase).freeze

def dos_parts(t)
  [(t.year - 1980) << 9 | t.month << 5 | t.day, t.hour << 11 | t.min << 5 | t.sec / 2]
end

# Минимальный ZIP-writer (STORE): entries = [[name, data], ...]
def write_zip(path, entries)
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

root = File.expand_path('..', __dir__)
cfg = CONFIG
src_loader = File.join(root, cfg[:loader])
src_dir    = File.join(root, cfg[:dir])
target_dir_name = cfg[:target_dir]

raise "Нет loader-файла #{src_loader}" unless File.file?(src_loader)
raise "Нет директории плагина #{src_dir}" unless File.directory?(src_dir)
raise "Нет HTML-интерфейса: соберите frontend (npm run build)" unless File.file?(File.join(src_dir, 'html', 'index.html'))
raise "Нет хелпера #{File.join(src_dir, 'helper', 'su_profiles_helper.ps1')}" unless File.file?(File.join(src_dir, 'helper', 'su_profiles_helper.ps1'))

# --- версия из loader или profile_core -----------------------------------------
version = nil
content = File.read(src_loader)
version = $1 if content =~ /(?:extension|ext)\.version\s*=\s*['"]([^'"]+)['"]/i
if version.nil?
  %w[dn1sup_sketchup_profiles/profile_core.rb dn1sup_sketchup_profiles/main.rb].each do |rel|
    path = File.join(root, rel)
    next unless File.file?(path)

    c = File.read(path)
    if (m = c.match(/^\s*VERSION\s*=\s*['"]([^'"]+)['"]/))
      version = m[1]
      break
    end
  end
end
raise 'Не удалось определить версию расширения' unless version

# --- registry.json: выравнивание версии по коду ----------------------------------
require 'json'
registry_path = File.join(root, 'registry.json')
registry_data = nil
if File.file?(registry_path)
  registry_data = begin
    JSON.parse(File.read(registry_path))
  rescue StandardError
    nil
  end
  if registry_data.is_a?(Array)
    registry_data.each do |e|
      e['version'] = version if e.is_a?(Hash) && e['id'].to_s == cfg[:id].to_s
    end
    File.write(registry_path, JSON.pretty_generate(registry_data) + "\n")
  else
    warn 'ВНИМАНИЕ: registry.json в корне имеет неожиданный формат'
  end
else
  warn 'ВНИМАНИЕ: нет registry.json в корне репозитория'
end

# --- сборка staging ---------------------------------------------------------------
Dir.mktmpdir do |tmp|
  stage = File.join(tmp, 'stage')
  FileUtils.mkdir_p(stage)

  loader_text = File.read(src_loader)
  File.write(File.join(stage, "#{cfg[:id]}.rb"), loader_text)

  dest = File.join(stage, target_dir_name)
  FileUtils.mkdir_p(dest)
  entries = []

  copy_dir = lambda do |src, dst, rel|
    Dir.each_child(src) do |name|
      child = File.join(src, name)
      rel_name = rel.empty? ? name : File.join(rel, name)
      base = name.downcase
      next if File.directory?(child) && EXCLUDE_DIRS.include?(base)
      next if File.file?(child) && EXCLUDE_FILES.include?(base)
      if File.directory?(child)
        FileUtils.mkdir_p(File.join(dst, name))
        copy_dir.call(child, File.join(dst, name), rel_name)
      else
        FileUtils.mkdir_p(File.join(dst, name))
        FileUtils.cp(child, File.join(dst, name))
        entries << [File.join(target_dir_name, rel_name).tr('\\', '/'), File.binread(child)]
      end
    end
  end
  copy_dir.call(src_dir, dest, '')

  entries << ["#{cfg[:id]}.rb", loader_text.b]

  # Общий updater (только если своего нет)
  updater_name = File.join(target_dir_name, 'dn1sup_updater.rb').tr('\\', '/')
  unless entries.any? { |n, _| n == updater_name }
    shared = File.join(root, 'shared', 'dn1sup_updater.rb')
    if File.file?(shared)
      FileUtils.cp(shared, File.join(dest, 'dn1sup_updater.rb'))
      entries << [updater_name, File.binread(shared)]
    else
      warn 'ВНИМАНИЕ: нет ни своего, ни shared/dn1sup_updater.rb'
    end
  end

  # registry.json внутрь пакета (самоописание .rbz)
  if registry_data.is_a?(Array)
    FileUtils.cp(registry_path, File.join(dest, 'registry.json'))
    entries << [File.join(target_dir_name, 'registry.json').tr('\\', '/'),
                File.binread(File.join(dest, 'registry.json'))]
  end

  out_dir = File.join(root, 'dist')
  FileUtils.mkdir_p(out_dir)
  out = File.join(out_dir, "#{cfg[:id]}-#{version}.rbz")
  FileUtils.rm_f(out)
  write_zip(out, entries.sort_by(&:first))
  puts "Собран #{out} (v#{version}, файлов: #{entries.size})"
end
