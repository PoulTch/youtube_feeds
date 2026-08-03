class MakeYoutubeVideoIdUnique < ActiveRecord::Migration[8.0]
  def change
    # На всякий случай удаляем старый обычный индекс, если он есть
    remove_index :videos, :youtube_video_id, if_exists: true

    # Добавляем жесткий УНИКАЛЬНЫЙ индекс, который требует Rails 8
    add_index :videos, :youtube_video_id, unique: true
  end
end
