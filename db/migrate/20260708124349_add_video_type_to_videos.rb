class AddVideoTypeToVideos < ActiveRecord::Migration[8.0]
  def change
    # По умолчанию все ролики считаются обычными видео
    add_column :videos, :video_type, :string, default: "regular", null: false
  end
end
