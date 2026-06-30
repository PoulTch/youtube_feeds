class AddAvatarUrlToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :avatar_url, :string
  end
end
