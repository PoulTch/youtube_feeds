class AddPlaylistIdToVideos < ActiveRecord::Migration[8.0]
  def change
    # ИСПРАВЛЕНО: Разрешаем null: true, чтобы старые видео не ломали базу данных!
    add_reference :videos, :playlist, null: true, foreign_key: true
  end
end
