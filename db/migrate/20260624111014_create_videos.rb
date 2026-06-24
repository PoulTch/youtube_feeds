class CreateVideos < ActiveRecord::Migration[8.0]
  def change
    create_table :videos do |t|
      t.references :channel, null: false, foreign_key: true
      t.string :title
      t.string :youtube_video_id
      t.datetime :published_at
      t.string :thumbnail_url
      t.text :description

      t.timestamps
    end
  end
end
