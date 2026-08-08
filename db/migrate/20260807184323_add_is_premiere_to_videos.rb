class AddIsPremiereToVideos < ActiveRecord::Migration[8.0]
  def change
    add_column :videos, :is_premiere, :boolean, default: false
  end
end
