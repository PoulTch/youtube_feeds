class CreatePlaylists < ActiveRecord::Migration[8.0]
  def change
    create_table :playlists do |t|
      t.references :channel, null: false, foreign_key: true
      t.string :youtube_playlist_id
      t.string :title
      t.string :thumbnail_url
      t.integer :video_count

      t.timestamps
    end
  end
end
