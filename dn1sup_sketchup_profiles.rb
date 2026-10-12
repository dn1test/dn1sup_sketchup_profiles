require 'sketchup.rb'
require 'extensions.rb'

# Регистратор менеджера профилей SketchUp. В .rbz лежит в корне архива как
# dn1sup_sketchup_profiles.rb.
#
# Author: DN1Sup <dn1codegen@gmail.com>
# License: MIT
module Dn1sup
  module SketchupProfiles
    PLUGIN_ROOT = File.dirname(__FILE__).freeze

    extension = SketchupExtension.new('DN1Sup SketchUp Profiles', File.join(PLUGIN_ROOT, 'dn1sup_sketchup_profiles', 'main'))
    extension.description = 'Профили SketchUp: у каждого профиля своя папка расширений и настройки интерфейса. Переключение профилей с перезапуском SketchUp, установка .rbz в выбранный профиль, снимки-резервные копии.'
    extension.version     = '0.1.0'
    extension.creator     = 'DN1Sup'
    extension.copyright   = '2026 DN1Sup <dn1codegen@gmail.com> (MIT)'
    extension.id          = 'dn1sup_sketchup_profiles' if extension.respond_to?(:id=)

    Sketchup.register_extension(extension, true)
  end
end
