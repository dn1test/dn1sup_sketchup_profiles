# probe_win.rb — razovaya proverka Windows-mekhanik dlya yadra profiley.
# Zapusk: ruby test/probe_win.rb
require 'fileutils'
require 'tmpdir'
require 'win32ole'

puts "RUBY #{RUBY_VERSION} #{RUBY_PLATFORM}"

$nf = 0
def check(label, cond, extra = '')
  puts format('%s %s%s', cond ? 'PASS' : 'FAIL', label, extra.to_s.empty? ? '' : " — #{extra}")
  ($nf += 1) unless cond
end

def win(path)
  path.to_s.tr('/', '\\')
end

Dir.mktmpdir('sp_probe') do |t|
  target = File.join(t, 'store')
  point  = File.join(t, 'link')
  Dir.mkdir(target)
  File.write(File.join(target, 'marker.txt'), 'x')

  # 1) junction: edinaya stroka s obratnymi sleshami
  ok = system("cmd.exe /c mklink /J \"#{win(point)}\" \"#{win(target)}\"")
  check 'mklink /J sozdaet junction', File.directory?(point), "ok=#{ok.inspect}"

  norm = ->(s) { win(s).downcase.sub(%r{\\+\z}, '') }
  is_j = File.directory?(point) && norm.call(File.realpath(point)) != norm.call(File.expand_path(point))
  check 'junction detektiruetsya cherez realpath', is_j
  check 'realpath vedet v store', norm.call(File.realpath(point)) == norm.call(File.expand_path(target))
  check 'realdir NE detektiruetsya kak junction',
        norm.call(File.realpath(target)) == norm.call(File.expand_path(target))

  system("cmd.exe /c rmdir \"#{win(point)}\"")
  check 'cmd rmdir udalyaet junction, tsel ziva', !File.directory?(point) && File.file?(File.join(target, 'marker.txt'))

  system("cmd.exe /c mklink /J \"#{win(point)}\" \"#{win(target)}\"")
  begin
    Dir.rmdir(point)
    check 'Dir.rmdir udalyaet junction, tsel ziva', !File.directory?(point) && File.file?(File.join(target, 'marker.txt'))
  rescue StandardError => e
    check 'Dir.rmdir udalyaet junction', false, "#{e.class}: #{e.message}"
  end

  # 2) tar zip create/extract
  zs = File.join(t, 'src')
  Dir.mkdir(zs)
  File.write(File.join(zs, 'demo.rb'), '# demo')
  Dir.mkdir(File.join(zs, 'demo'))
  File.write(File.join(zs, 'demo', 'x.rb'), 'x')
  z = File.join(t, 'a.zip')
  system('tar.exe -a -cf ' + "\"#{win(z)}\" -C \"#{win(zs)}\" .")
  check 'tar -a -cf sozdaet zip', File.file?(z) && File.size(z).positive?
  xd = File.join(t, 'x')
  Dir.mkdir(xd)
  system('tar.exe -xf ' + "\"#{win(z)}\" -C \"#{win(xd)}\"")
  check 'tar -xf raspakovyvaet zip', File.file?(File.join(xd, 'demo.rb')) && File.file?(File.join(xd, 'demo', 'x.rb'))

  # 3) robocopy
  dst = File.join(t, 'dst')
  pid = spawn('robocopy.exe', zs.tr('/', '\\'), dst.tr('/', '\\'), '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
  Process.wait(pid)
  check 'robocopy kopiruet (exit<8)', $?.exitstatus.to_i < 8 && File.file?(File.join(dst, 'demo.rb')), "exit=#{$?.exitstatus}"

  # 4) skrytyy zapusk powershell cherez WScript.Shell (bez morganiya konsoli)
  log = File.join(t, 'ps.log')
  ps_script = File.join(t, 'probe.ps1')
  File.write(ps_script, "param([string]\$Out)\nStart-Sleep -Milliseconds 300\n'ps-ok' | Out-File -FilePath \$Out -Encoding utf8\n")
  shell = WIN32OLE.new('WScript.Shell')
  cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"#{win(ps_script)}\" -Out \"#{win(log)}\""
  shell.Run(cmd, 0, false)
  waited = 0
  waited += 1 while !File.file?(log) && waited < 80 && sleep(0.1)
  content = File.file?(log) ? File.read(log, encoding: 'UTF-8') : ''
  check 'WScript.Run skryto zapuskaet powershell', content.include?('ps-ok'), "waited=#{waited * 0.1}s"

  check 'LOCALAPPDATA zadan', !ENV['LOCALAPPDATA'].to_s.empty?
end

puts $nf.to_i.zero? ? 'ALL PROBES PASSED' : "#{$nf} PROBES FAILED"
exit($nf.to_i.zero? ? 0 : 1)
