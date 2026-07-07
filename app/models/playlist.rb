class Playlist < ApplicationRecord
  belongs_to :channel

  # ДОБАВЛЕНО: Один плейлист содержит в себе коллекцию роликов
  has_many :videos, dependent: :nullify

  # Проверим валидность, чтобы в базу не залетал мусор
  validates :youtube_playlist_id, presence: true, uniqueness: { scope: :channel_id }
end
