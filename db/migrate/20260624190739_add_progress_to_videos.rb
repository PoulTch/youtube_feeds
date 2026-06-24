class AddProgressToVideos < ActiveRecord::Migration[8.0]
  def change
    add_column :videos, :watched_seconds, :integer
    add_column :videos, :duration_seconds, :integer
  end
end
