class Video < ApplicationRecord
  belongs_to :channel

  # Метод возвращает процент просмотра от 0 до 100
  def progress_percentage
    return 0 if duration_seconds.nil? || duration_seconds.zero?
    return 0 if watched_seconds.nil? || watched_seconds.zero?

    # Высчитываем процент и следим, чтобы он не превысил 100%
    percent = (watched_seconds.to_f / duration_seconds * 100).round
    [ percent, 100 ].min
  end
end
