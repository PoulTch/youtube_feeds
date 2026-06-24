class CreateChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :channels do |t|
      t.string :title
      t.string :youtube_channel_id
      t.string :rss_url

      t.timestamps
    end
  end
end
