class Video < ApplicationRecord
  belongs_to :channel
  # ЖЕЛЕЗНЫЙ МОСТ: Привязываем ролик к плейлисту (опционально!)
  belongs_to :playlist, optional: true

  # Метод возвращает честный процент просмотра от 0 до 100
  def progress_percentage
    return 0 if duration_seconds.nil? || duration_seconds.zero?
    return 0 if watched_seconds.nil? || watched_seconds.zero?

    percent = (watched_seconds.to_f / duration_seconds * 100).floor
    [ percent, 100 ].min
  end
end
