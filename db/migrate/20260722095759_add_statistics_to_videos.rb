class AddStatisticsToVideos < ActiveRecord::Migration[8.0]
  def change
    add_column :videos, :views_count, :integer
    add_column :videos, :likes_count, :integer
  end
end
